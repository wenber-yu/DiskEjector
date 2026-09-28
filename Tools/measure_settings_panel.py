#!/usr/bin/env python3
"""量设计稿设置面板（`05-settings.html`）的**内容自然高度**，供 `SettingsLayoutTests` 对齐。

```bash
P=/Users/wenbo/.workbuddy/binaries/python/versions/3.13.12/bin/python3
$P Tools/measure_settings_panel.py            # 量并打印明细
$P Tools/measure_settings_panel.py --json     # 只打 JSON（给脚本用）
```

## 量法（与 `SettingsLayoutTests.中文高度与设计稿几乎逐点相同()` 的注释同源）

    内容自然高 = `.shead` 的高 + `.settings__body` **关掉 flex 之后**的自然高

这个量法在旧稿上复现出 **766.44**（与当时的期望值逐点相同），在 2026-09-27 加了
「接管访达的推出」之后复现出 **841.16** —— 两次都对上了，所以它不是新编的口径。

## 三条纪律（来自技能 `html-mockup-layout-probe`）

1. **探针临时文件必须与原页面同目录** —— 否则相对的 `<link href="../assets/ds.css">`
   404，量到的是无样式布局，所有数字全错（本项目为此吃过 18pt 的亏）。
2. **必须在 `DOMContentLoaded` 之后量，且输出里带 `svg` 数量自证** ——
   数量为 0 说明量的是半成品页面（图标还没注入），此时所有数字作废。
3. **`.settings__body` 的 `flex: 1 1 auto` 必须先关掉再量** —— 它被拉伸填满面板，
   直接量到的是「被撑开的高度」（面板高 − 52），不是内容自然高。
   2026-09-18 之前设计稿写 826 就是照「撑开后」的口径抄的。

⚠️ `--no-sandbox` 不能省：在受管环境里 Chrome 自己的沙箱起不来，
`--dump-dom` 会输出 0 字节**而退出码仍是 0** —— 看起来像「探针没注入」。
（理由与 `Tools/design-compare.py` 顶部那段相同。）

## 命中 0 就退出码 1

静默认成「这一档没有」会让这个数字悄悄漂走，而读它的人只看到「测试还是绿的」。
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
PAGE = SCREENS / "05-settings.html"

# ⚠️ 探针临时文件与页面**同目录**（相对 CSS 才解析得到）。
# 固定名、用完删一次 —— **别在循环里反复删**（删除次数一多会触发批量删除确认，
# 命令被拦下，于是文件残留在设计稿目录里，实测踩到）。
PROBE_TMP = SCREENS / "_probe_settings_panel.html"

PROBE_JS = """
<script>
function measure() {
  var out = [];
  // 自证：图标没注入时 svg 会是 0 —— 看到 0 就别信后面的数字
  out.push('readyState=' + document.readyState +
           ' svg=' + document.querySelectorAll('svg').length);
  var head = document.querySelector('.shead');
  var body = document.querySelector('.settings__body');
  if (!head || !body) {
    out.push('MISSING shead=' + (head ? 1 : 0) + ' settings__body=' + (body ? 1 : 0));
  } else {
    // 纪律 3：关掉 flex 拉伸，量的才是**内容自然高**
    body.style.flex = 'none';
    body.style.height = 'auto';
    var h = head.getBoundingClientRect().height;
    var b = body.getBoundingClientRect().height;
    out.push('SHEAD ' + h.toFixed(2));
    out.push('BODY ' + b.toFixed(2));
    out.push('TOTAL ' + (h + b).toFixed(2));
    out.push('ROWS ' + body.querySelectorAll('.sline').length);
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


def measure(page: pathlib.Path = PAGE) -> dict[str, float | int | str]:
    if not page.exists():
        raise RuntimeError(f"设计稿页面不存在：{page}")
    PROBE_TMP.write_text(
        page.read_text(encoding="utf-8").replace("</body>", PROBE_JS + "</body>"), encoding="utf-8"
    )
    try:
        dom = subprocess.run(
            CHROME_BASE
            + [
                "--window-size=1500,4200",
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
    # ⚠️ **判据是 `svg>0` 且 `readyState` 已经离开 `loading`**，不是 `== complete`：
    # 探针挂在 `DOMContentLoaded` 上，而那一刻 `readyState` **正是 `interactive`**
    # （`complete` 要等所有子资源加载完，那时早就晚了）。写 `== complete` 会把
    # 每一条正常路径都判成「半成品」—— 2026-09-28 第一版就是这么写的，当场红。
    if "svg=0" in flat or "readyState=loading" in flat:
        raise RuntimeError(f"量到的是半成品页面（{selfcheck}）—— 本次所有数字作废")
    if any(ln.startswith("MISSING") for ln in lines):
        raise RuntimeError(f"选择器没命中（{lines}）—— 页面结构变了，先修本脚本再读数")

    got: dict[str, float | int | str] = {"selfcheck": selfcheck}
    for ln in lines:
        key, _, value = ln.partition(" ")
        if key in {"SHEAD", "BODY", "TOTAL"}:
            got[key.lower()] = float(value)
        elif key == "ROWS":
            got["rows"] = int(value)
    for key in ("shead", "body", "total", "rows"):
        if key not in got:
            raise RuntimeError(f"缺 {key}：{lines}")
    return got


def main() -> int:
    ap = argparse.ArgumentParser(description="量设计稿设置面板的内容自然高")
    ap.add_argument("--json", action="store_true", help="只打 JSON")
    args = ap.parse_args()

    got = measure()
    if args.json:
        print(json.dumps(got, ensure_ascii=False))
    else:
        print(f"  探针自证 {got['selfcheck']}")
        print(f"  .shead           {got['shead']}")
        print(f"  .settings__body  {got['body']}（关掉 flex 后的自然高）")
        print(f"  .sline 行数       {got['rows']}")
        print(f"  内容自然高        {got['total']}   ← 面板高度必须 ≥ 这一项 + 余量")
        print()
        print("  ⚠️ 这是**中文**口径（页面 lang=zh-CN）。实现侧的英文最坏情况另有实测，")
        print("     两者一起决定 `DesignTokens.Size.settingsPanel.height`。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
