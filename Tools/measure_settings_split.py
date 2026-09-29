#!/usr/bin/env python3
"""量设计稿两栏设置面板（`screens/09-settings-split.html`）的**每帧内容自然高**。

```bash
P=/Users/wenbo/.workbuddy/binaries/python/versions/3.13.12/bin/python3
$P Tools/measure_settings_split.py            # 量并打印明细
$P Tools/measure_settings_split.py --json     # 只打 JSON
```

## 为什么单独一个脚本

`Tools/measure_settings_panel.py` 量的是**单栏版**（480 × 920）那一个面板，
它的口径（`.shead` 高 + `.settings__body` 关掉 flex 后的自然高）是给
`SettingsLayoutTests` 用的。两栏版有**五个**面板（每个分类一帧），
口径也不同（`.sdetail__head` + `.sdetail__body`），硬塞进旧脚本会把两件事混在一起。

## 三条纪律（与 `measure_settings_panel.py` 同源）

1. **探针临时文件必须与原页面同目录** —— 否则相对的 `<link href="../assets/ds.css">`
   404，量到的是无样式布局，所有数字全错。
2. **必须在 `DOMContentLoaded` 之后量，且输出里带 `svg` 数量自证** ——
   数量为 0 说明量的是半成品页面（图标还没注入），此时所有数字作废。
3. **`.sdetail__body` 的 `flex: 1 1 auto` 必须先关掉再量** —— 它被拉伸填满窗口，
   直接量到的是「被撑开的高度」，不是内容自然高。

## 判据

窗口高度必须 ≥ `max(每帧 TOTAL)`，否则内容会被 `overflow: hidden` **静默裁掉** ——
而「裁掉」与「本来就没那么多内容」在渲染图上长得一模一样（这正是本仓库
反反复复吃亏的那一类症状：**少了东西不会报错**）。
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
SCREENS = REPO / "Design/ui/v2/screens"
PAGE = SCREENS / "09-settings-split.html"

# ⚠️ 与 `measure_settings_panel.py` 同一条纪律：探针与页面**同目录**（相对 CSS 才解析得到）。
PROBE_TMP = SCREENS / "_probe_settings_split.html"

PROBE_JS = """
<script>
function measure() {
  // ⚠️ 量的语言必须**显式钉住**：`ds.js` 默认按 localStorage → navigator.language
  // 选语言，而 CI / 本机 / 无头 Chrome 三者可能不同 ⇒ 同一份稿子量出两个数，
  // 而两次都是「绿」的。本脚本量之前先调 `dsSetLang` 固定到 `--lang`。
  if (window.DS_LANG_OVERRIDE && window.dsSetLang) {
    window.dsSetLang(window.DS_LANG_OVERRIDE);
  }
  var out = [];
  out.push('lang=' + document.documentElement.getAttribute('lang') +
           ' readyState=' + document.readyState +
           ' svg=' + document.querySelectorAll('svg').length);
  var wins = document.querySelectorAll('.win--split');
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
    var s = w.querySelector('.sside');
    var sb = s ? s.getBoundingClientRect().height : 0;
    var sitems = s ? s.querySelectorAll('.sside__item').length : 0;
    var scontent = 0;
    if (s) {
      var its = s.querySelectorAll('.sside__item');
      for (var k = 0; k < its.length; k++) { scontent += its[k].getBoundingClientRect().height; }
    }
    out.push('FRAME ' + i + ' HEAD ' + h.toFixed(2) + ' BODY ' + b.toFixed(2) +
             ' TOTAL ' + (h + b).toFixed(2) + ' SIDE ' + sb.toFixed(2) +
             ' SITEMS ' + sitems + ' SCONTENT ' + scontent.toFixed(2) +
             ' WIN ' + w.getBoundingClientRect().height.toFixed(2));
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


def measure(page: pathlib.Path = PAGE, lang: str = "zh-Hans") -> dict:
    if not page.exists():
        raise RuntimeError(f"设计稿页面不存在：{page}")
    probe = (
        PROBE_JS.replace(
            "<script>", f'<script>window.DS_LANG_OVERRIDE = "{lang}";', 1
        )
        if lang
        else PROBE_JS
    )
    PROBE_TMP.write_text(
        page.read_text(encoding="utf-8").replace("</body>", probe + "</body>"), encoding="utf-8"
    )
    try:
        dom = subprocess.run(
            CHROME_BASE
            + [
                "--window-size=1500,3400",
                "--virtual-time-budget=5000",
                "--dump-dom",
                "file://" + str(PROBE_TMP),
            ],
            capture_output=True,
            text=True,
            timeout=120,
        ).stdout
    finally:
        PROBE_TMP.unlink(missing_ok=True)

    m = re.search(r'<pre id="PROBE">(.*?)</pre>', dom, re.S)
    if not m:
        raise RuntimeError(
            "探针未注入（Chrome 多半是没起来）—— 别把「没输出」当成「没问题」。"
            f"--dump-dom 拿到 {len(dom)} 字节"
        )
    lines = [ln for ln in html.unescape(m.group(1)).split("\n") if ln.strip()]
    selfcheck = lines[0] if lines else ""
    flat = selfcheck.replace(" ", "")
    # 与 `measure_settings_panel.py` 同一判据：`readyState` 在 DOMContentLoaded 那一刻
    # **正是 `interactive`**，写 `== complete` 会把每条正常路径都判成半成品。
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
                "side": float(f["SIDE"]),
                "sitems": int(f["SITEMS"]),
                "scontent": float(f["SCONTENT"]),
                "win": float(f["WIN"]),
            }
        )
    if not frames:
        raise RuntimeError("一帧都没量到 —— 页面结构变了，先修本脚本再读数")
    return {"selfcheck": selfcheck, "wins": wins, "frames": frames}


def main() -> int:
    ap = argparse.ArgumentParser(description="量两栏设置面板每帧的内容自然高")
    ap.add_argument("--json", action="store_true", help="只打 JSON")
    ap.add_argument(
        "--lang",
        default="both",
        help="量哪门语言：zh-Hans / en / zh-Hant / both（默认 both —— "
        "「最长的那门语言」才是决定窗口高度的那个数，只量中文会取到偏小的值）",
    )
    args = ap.parse_args()

    langs = ["zh-Hans", "en"] if args.lang == "both" else [args.lang]
    results = {lg: measure(lang=lg) for lg in langs}
    if args.json:
        print(json.dumps(results, ensure_ascii=False))
        return 0

    for lg in langs:
        got = results[lg]
        print(f"  语言 {lg} · {got['selfcheck']} · 命中 {got['wins']} 帧")
    print()
    head = f"  {'帧':<4}" + "".join(f"{lg:>14}" for lg in langs) + f"{'窗口高':>10}{'最坏余量':>10}"
    print(head)
    worst = 0.0
    winh = 0.0
    for f in results[langs[0]]["frames"]:
        i = f["index"]
        cells = ""
        row_worst = 0.0
        for lg in langs:
            v = [x for x in results[lg]["frames"] if x["index"] == i][0]["total"]
            cells += f"{v:>14.2f}"
            row_worst = max(row_worst, v)
        worst = max(worst, row_worst)
        winh = f["win"]
        print(f"  {i:<4}{cells}{winh:>10.2f}{winh - row_worst:>10.2f}")
    print()
    print(f"  最高的一帧（全部语言里最坏的那个） {worst:.2f}")
    print(f"  窗口高 {winh:.2f} ⇒ 余量 {winh - worst:.2f}")
    if winh - worst < 8:
        print("  ⚠️ 余量 < 8pt：再加一行说明文字就会被 `overflow: hidden` **静默裁掉**。")
    sc = results[langs[0]]["frames"][0]
    print(f"  侧栏项合计 {sc['scontent']:.2f} + 上下内边距 64 = {sc['scontent'] + 64:.2f}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
