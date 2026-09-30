#!/usr/bin/env python3
"""量 **v3 尺寸**下设置每一页的内容自然高（详情区宽 592、头部 52）。

```bash
P=/Users/wenbo/.workbuddy/binaries/python/versions/3.13.12/bin/python3
$P Tools/measure_settings_v3.py              # 两路都量并交叉校验
$P Tools/measure_settings_v3.py --json       # 只打 JSON
$P Tools/measure_settings_v3.py --source v2  # 只量「v2 内容 + v3 宽度」
$P Tools/measure_settings_v3.py --source v3  # 只量 v3 稿自带的帧
```

## 为什么不能直接沿用 `measure_settings_split.py`

那个脚本量的是 **v2 独立设置窗口**（720 × 440，左栏贴边 200 ⇒ 详情区 **520**）。
v3 把设置并进主窗口详情区之后，宽度变成 **592**（800 − 侧栏 200 − 浮岛左内缩 8），
说明文字**折行更少 ⇒ 每页更矮**。宽度变了，那批数就整体作废（HANDOFF §5）。

## 两路来源，以及为什么要两路

v3 稿（`screens/_10-combined-draft.html`）只画了**两帧**：磁盘页 + 设置「通用」页。
其余四页（外观 / 更新 / 诊断 / 关于）**稿里没有**。于是：

| 路 | 来源 | 覆盖 |
|---|---|---|
| `v2` | v2 的 `09-settings-split.html`，探针注入宽度覆盖 ⇒ 详情区 592 | **全部六帧**（五页 + 登录项第三态） |
| `v3` | v3 稿自带的那一帧「通用」 | **只一页**，用来**交叉校验** `v2` 路 |

`v2` 路凭什么算「设计稿口径」：v3 的 `assets/ds.css` 与 v2 **逐字相同**（令牌表整份沿用），
设置页的类名与结构也同源 ⇒ 同一段 HTML 在 592 宽下的布局是确定的，
v2 那四页在 592 宽下量出的数就是它们该有的数。

**两路对同一页（通用）给出的数必须接近** —— 差得多说明宽度覆盖没生效、
或 v3 稿那一帧的结构与 v2 不同源。这是本脚本的自证，别跳过。

## 三条纪律（与 `measure_settings_split.py` 同源）

1. **探针临时文件必须与原页面同目录** —— 否则相对的 `<link href="../assets/ds.css">`
   404，量到的是无样式布局，所有数字全错。
2. **必须在 `DOMContentLoaded` 之后量，且输出里带 `svg` 数量自证**。
3. **`.sdetail__body` 的 `flex: 1 1 auto` 必须先关掉再量**。

## 本脚本多出来的一条自证

`v2` 路注入宽度覆盖之后，**必须回读 `.sdetail` 的实际宽度**并要求它 ≈ 592。
不比这一下的话，CSS 覆盖写错（选择器没命中、被 `!important` 顶掉）会**静默**给出
「v2 老宽度下的旧数」—— 而那正是这次要作废的一批数，症状是「跑过了、数字没变」。
"""

from __future__ import annotations

import argparse
import html
import json
import pathlib
import re
import subprocess
import sys

CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
CHROME_BASE = [CHROME, "--headless=new", "--no-sandbox", "--disable-gpu", "--hide-scrollbars"]
REPO = pathlib.Path(__file__).resolve().parent.parent

V2_SCREENS = REPO / "Design/ui/v2/screens"
V2_PAGE = V2_SCREENS / "09-settings-split.html"
V3_SCREENS = REPO / "Design/ui/v3/screens"
V3_PAGE = V3_SCREENS / "_10-combined-draft.html"

# v3 详情区的**外沿**宽度：800（窗口）− 200（侧栏本体）− 8（浮岛左内缩）= 592。
# 与 `DesignTokens.Size.mainWindow.mainSidebarWidth` 的推导同一条口径，
# 也与真机实测的「侧栏外沿 x ∈ [8, 208]、详情区左缘 208」对得上。
DETAIL_WIDTH = 592
DETAIL_WIDTH_TOLERANCE = 0.5

# 探针与页面**同目录**（相对 CSS 才解析得到）。
PROBE_V2 = V2_SCREENS / "_probe_settings_v3width.html"
PROBE_V3 = V3_SCREENS / "_probe_settings_v3width.html"

# v2 路：把窗口与详情区都改成 v3 的度量。
WIDTH_OVERRIDE = f"""
<style id="v3width">
  /* 窗口宽 800（v3 主窗口），详情区锁 592（v3 实测外沿）*/
  .win--split {{ width: 800px !important; }}
  .win--split .sdetail {{ width: {DETAIL_WIDTH}px !important; flex: 0 0 {DETAIL_WIDTH}px !important; }}
</style>
"""

PROBE_JS = """
<script>
function measure() {
  // ⚠️ 量的语言必须**显式钉住**：`ds.js` 默认按 localStorage → navigator.language
  // 选语言，而 CI / 本机 / 无头 Chrome 三者可能不同 ⇒ 同一份稿子量出两个数。
  if (window.DS_LANG_OVERRIDE && window.dsSetLang) {
    window.dsSetLang(window.DS_LANG_OVERRIDE);
  }
  var out = [];
  out.push('lang=' + document.documentElement.getAttribute('lang') +
           ' readyState=' + document.readyState +
           ' svg=' + document.querySelectorAll('svg').length);
  var wins = document.querySelectorAll(SEL);
  out.push('WINS ' + wins.length);
  for (var i = 0; i < wins.length; i++) {
    var w = wins[i];
    var head = w.querySelector('.sdetail__head');
    var body = w.querySelector('.sdetail__body');
    if (!head || !body) { out.push('FRAME ' + i + ' MISSING'); continue; }
    // 纪律 3：关掉 flex 拉伸，量的才是**内容自然高**
    body.style.flex = 'none';
    body.style.height = 'auto';
    var h = head.getBoundingClientRect().height;
    var b = body.getBoundingClientRect().height;
    var d = w.querySelector('.sdetail').getBoundingClientRect().width;
    out.push('FRAME ' + i + ' HEAD ' + h.toFixed(2) + ' BODY ' + b.toFixed(2) +
             ' TOTAL ' + (h + b).toFixed(2) + ' DETAIL ' + d.toFixed(2) +
             ' WIN ' + w.getBoundingClientRect().width.toFixed(2));
  }
  var pre = document.createElement('pre');
  pre.id = 'PROBE'; pre.textContent = out.join('\\n');
  document.body.appendChild(pre);
}
if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', measure);
} else {
  measure();
}
</script>
"""


def measure(page: pathlib.Path, probe_tmp: pathlib.Path, selector: str, lang: str,
            inject: str = "") -> dict:
    if not page.exists():
        raise RuntimeError(f"设计稿页面不存在：{page}")
    probe = PROBE_JS.replace("SEL", f"'{selector}'").replace(
        "<script>", f'<script>window.DS_LANG_OVERRIDE = "{lang}";', 1
    )
    text = page.read_text(encoding="utf-8")
    if inject:
        text = text.replace("</head>", inject + "</head>", 1)
    probe_tmp.write_text(text.replace("</body>", probe + "</body>"), encoding="utf-8")
    try:
        dom = subprocess.run(
            CHROME_BASE
            + [
                "--window-size=1500,3400",
                "--virtual-time-budget=5000",
                "--dump-dom",
                "file://" + str(probe_tmp),
            ],
            capture_output=True,
            text=True,
            timeout=120,
        ).stdout
    finally:
        probe_tmp.unlink(missing_ok=True)

    m = re.search(r'<pre id="PROBE">(.*?)</pre>', dom, re.S)
    if not m:
        raise RuntimeError(
            "探针未注入（Chrome 多半是没起来）—— 别把「没输出」当成「没问题」。"
            f"--dump-dom 拿到 {len(dom)} 字节"
        )
    lines = [ln for ln in html.unescape(m.group(1)).split("\n") if ln.strip()]
    selfcheck = lines[0] if lines else ""
    flat = selfcheck.replace(" ", "")
    if "svg=0" in flat or "readyState=loading" in flat:
        raise RuntimeError(f"量到的是半成品页面（{selfcheck}）—— 本次所有数字作废")

    wins = int(lines[1].split()[1])
    frames = []
    for ln in lines[2:]:
        f = dict(re.findall(r"(\w+) ([\d.]+)", ln))
        frames.append(
            {
                "index": int(f["FRAME"]),
                "head": float(f["HEAD"]),
                "body": float(f["BODY"]),
                "total": float(f["TOTAL"]),
                "detail": float(f["DETAIL"]),
                "win": float(f["WIN"]),
            }
        )
    if not frames:
        raise RuntimeError("一帧都没量到 —— 页面结构变了，先修本脚本再读数")
    return {"selfcheck": selfcheck, "wins": wins, "frames": frames}


def measure_v2(lang: str) -> dict:
    got = measure(V2_PAGE, PROBE_V2, ".win--split", lang, inject=WIDTH_OVERRIDE)
    # 自证：宽度覆盖真的生效了。没生效的话量到的是 520 宽下的旧数 —— 那正是要作废的一批。
    bad = [f for f in got["frames"] if abs(f["detail"] - DETAIL_WIDTH) > DETAIL_WIDTH_TOLERANCE]
    if bad:
        raise RuntimeError(
            "宽度覆盖没生效：这些帧的 .sdetail 实宽 "
            + ", ".join(f"帧{f['index']}={f['detail']}" for f in bad)
            + f"，期望 {DETAIL_WIDTH}±{DETAIL_WIDTH_TOLERANCE}。"
            "拿 520 宽下的旧数当 v3 基准，比不量更糟 —— 数字看着「没变」而其实是错的。"
        )
    return got


def measure_v3(lang: str) -> dict:
    return measure(V3_PAGE, PROBE_V3, ".win--v3", lang)


# v3 稿帧序 → 它在量什么（用于打印；v2 六帧的页名在下面 V2_FRAME_NAMES）
V3_FRAME_NAMES = {0: "磁盘页", 1: "设置·通用"}

# v2 六帧的页名（与 measure_settings_split.py 的顺序一致，被 SettingsLayoutTests 引用）
V2_FRAME_NAMES = {
    0: "通用",
    1: "通用·登录项待批准",
    2: "外观",
    3: "更新",
    4: "诊断",
    5: "关于",
}


def main() -> int:
    ap = argparse.ArgumentParser(description="量 v3 尺寸下设置每页的内容自然高")
    ap.add_argument("--json", action="store_true", help="只打 JSON")
    ap.add_argument(
        "--lang",
        default="both",
        help="量哪门语言：zh-Hans / en / zh-Hant / both（默认 both —— "
        "「最长的那门语言」才是决定窗口高度的那个数，只量中文会取到偏小的值）",
    )
    ap.add_argument(
        "--source",
        default="both",
        choices=["v2", "v3", "both"],
        help="v2 = 注入 v3 宽度量 v2 六帧（覆盖全）；v3 = 量 v3 稿自带帧（只一页，用作交叉校验）",
    )
    args = ap.parse_args()

    langs = ["zh-Hans", "en"] if args.lang == "both" else [args.lang]
    result: dict = {}

    if args.source in ("v2", "both"):
        result["v2@592"] = {lg: measure_v2(lg) for lg in langs}
    if args.source in ("v3", "both"):
        result["v3draft"] = {lg: measure_v3(lg) for lg in langs}

    if args.json:
        print(json.dumps(result, ensure_ascii=False))
        return 0

    if "v2@592" in result:
        print("═══ 来源 v2：v2 内容 + v3 宽度（详情区 592）═══")
        for lg in langs:
            got = result["v2@592"][lg]
            print(f"  语言 {lg} · {got['selfcheck']} · 命中 {got['wins']} 帧")
        print()
        header = f"  {'帧':<4}{'页面':<18}" + "".join(f"{lg:>12}" for lg in langs)
        print(header)
        worst = 0.0
        for f in result["v2@592"][langs[0]]["frames"]:
            i = f["index"]
            cells = ""
            row_worst = 0.0
            for lg in langs:
                v = [x for x in result["v2@592"][lg]["frames"] if x["index"] == i][0]["total"]
                cells += f"{v:>12.2f}"
                row_worst = max(row_worst, v)
            worst = max(worst, row_worst)
            print(f"  {i:<4}{V2_FRAME_NAMES.get(i, '?'):<18}{cells}")
        print()
        print(f"  最高的一帧（全部语言里最坏的那个）= {worst:.2f}")
        for f in result["v2@592"][langs[0]]["frames"]:
            print(f"    帧 {f['index']} {V2_FRAME_NAMES.get(f['index'], '?')}："
                  f"head {f['head']:.2f} + body {f['body']:.2f} = {f['total']:.2f}"
                  f"（.sdetail 实宽 {f['detail']:.2f}）")

    if "v3draft" in result:
        print("\n═══ 来源 v3：v3 稿自带帧（交叉校验用）═══")
        for lg in langs:
            got = result["v3draft"][lg]
            print(f"  语言 {lg} · {got['selfcheck']} · 命中 {got['wins']} 帧")
            for f in got["frames"]:
                print(f"    帧 {f['index']} {V3_FRAME_NAMES.get(f['index'], '?'):<8}"
                      f" head {f['head']:.2f} + body {f['body']:.2f} = {f['total']:.2f}"
                      f"（.sdetail 实宽 {f['detail']:.2f}）")

        if "v2@592" in result:
            print("\n  —— 交叉校验：同一页（通用）两路之差 ——")
            for lg in langs:
                a = [x for x in result["v2@592"][lg]["frames"] if x["index"] == 0][0]["total"]
                cands = [x for x in result["v3draft"][lg]["frames"] if x["index"] == 1]
                if not cands:
                    print(f"    [{lg}] v3 稿里找不到设置帧 —— 跳过（结构变了？）")
                    continue
                b = cands[0]["total"]
                flag = "✅ 一致" if abs(a - b) <= 3 else "❌ 差得太多，先查宽度覆盖与同源性"
                print(f"    [{lg}] v2@592 = {a:.2f} ｜ v3 稿 = {b:.2f} ｜ 差 {a - b:+.2f}  {flag}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
