#!/usr/bin/env python3
"""量设计稿 HTML 里四种「行」的**实际渲染高度**，产出 `assets/design-row-heights.json`。

用法：
    python tools/measure_row_heights.py            # 量并写回快照
    python tools/measure_row_heights.py --check    # 只量不写（对照用）

## 为什么需要它

`DesignTokens.Size` 里的 `diskRowBusyHeight(169)` / `diskRowSafeHeight(127)` /
`diskRowUnknownHeight(133)` / `menuRowHeight(69)` / `compactRowHeight(46)`
注释都写「设计稿实测」，而 `ds.css` 里**一处都没有这几个数字** ——
行高是 `padding + 内容` 自然排出来的，没有声明处可读（清单 #17）。

⇒ 它们只能是一次性实测的快照，而**没有任何机制会去复核**。
本脚本就是那个复核动作：`RowHeightParityTests` 读它产出的 JSON，
与实现常量比对 ⇒ CI 至少能抓住「实现侧行高漂了」。

## 纪律（改这个脚本前先读）

- **自证字段必须齐全**：`readyState`（必须 complete）、每个选择器命中几个元素。
  量到「半成品页面」得出的基准值是错的（本项目为此吃过 18pt 的亏）。
- **命中 0 就退出码 1 且不写 JSON**：静默认成「这一档没有」会让快照悄悄少一档，
  而守卫那边只看到「没这个 key」—— 两种失败长得一样。
- 页面里的行有**两态**（可推出 / 未知），高度不同（127.47 / 133.47）——
  所以 `safeUnknown` 存的是**两个**数，不是取平均。
"""
import json
import os
import re
import subprocess
import sys
import tempfile
from datetime import datetime

CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
V2 = os.path.join(ROOT, "DiskEjector-UI-Design", "v2")
OUT = os.path.join(V2, "assets", "design-row-heights.json")

SELECTORS = {
    "busy": ".row--busy",
    "safeUnknown": ".row:not(.row--busy)",
    "menu": ".mrow",
    "compact": ".crow",
}

# 每一档在哪个页面量（同一个选择器在别的页面可能命中 0）
SOURCE = {
    "busy": "screens/01-main-window.html",
    "safeUnknown": "screens/01-main-window.html",
    "menu": "screens/02-menu-bar.html",
    "compact": "screens/06-states.html",
}

PROBE = """
<script>
window.addEventListener('load', function () {
  setTimeout(function () {
    var out = { readyState: document.readyState, counts: {}, rows: {} };
    var sels = %s;
    Object.keys(sels).forEach(function (k) {
      var els = document.querySelectorAll(sels[k]);
      out.counts[k] = els.length;
      out.rows[k] = Array.prototype.map.call(els, function (e) {
        var r = e.getBoundingClientRect();
        return { h: Math.round(r.height * 100) / 100, kids: e.children.length };
      });
    });
    var pre = document.createElement('pre');
    pre.id = '__probe';
    pre.textContent = JSON.stringify(out);
    document.body.appendChild(pre);
  }, 400);
});
</script>
""" % json.dumps(SELECTORS)


def cleanup_probes() -> int:
    """清掉 `screens/` 下所有残留的 `_probe_*.html`。

    ⚠️ 这不是洁癖：设计稿目录是被**守卫扫描**的（`DesignDraftIntegrityTests` 的
    `htmlFiles()` 会扫 `screens/*.html`），残留的探针页里带着 `<pre id="__probe">`
    和一份被改写过的 DOM —— 它们会被当成**真的设计稿页面**扫进去，
    让「界面文案漏接」「属性没翻译」那几条守卫报出一堆莫名其妙的数。
    而 Chrome 被中断时 `finally` 里的 `unlink` 未必跑得到，所以每次都先扫一遍。
    """
    n = 0
    for dirpath, _, names in os.walk(os.path.join(V2, "screens")):
        for name in names:
            if name.startswith("_probe_") and name.endswith(".html"):
                try:
                    os.unlink(os.path.join(dirpath, name))
                    n += 1
                except OSError:
                    pass
    return n


def measure(html_rel: str) -> dict:
    src = os.path.join(V2, html_rel)
    with open(src, encoding="utf-8") as fh:
        html = fh.read()
    # 临时文件必须放在**同一目录**（相对路径的 ds.css 才找得到），
    # 且名字唯一（Chrome 按 URL 缓存 file://）
    fd, tmp = tempfile.mkstemp(suffix=".html", prefix="_probe_", dir=os.path.dirname(src))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(html.replace("</body>", PROBE + "</body>"))
        cmd = [
            CHROME, "--headless=new", "--no-sandbox", "--disable-gpu",
            "--hide-scrollbars", "--window-size=1400,4000",
            "--virtual-time-budget=6000", "--dump-dom", "file://" + tmp,
        ]
        dom = subprocess.run(cmd, capture_output=True, text=True, timeout=120).stdout
        if not dom:
            return {"error": "Chrome 输出 0 字节（先看有没有 --no-sandbox）"}
        m = re.search(r'<pre id="__probe">(.*?)</pre>', dom, re.S)
        if not m:
            return {"error": "探针未注入（页面没到 load？加大 virtual-time-budget）"}
        return json.loads(
            m.group(1).replace("&quot;", '"').replace("&amp;", "&")
            .replace("&lt;", "<").replace("&gt;", ">"))
    finally:
        os.unlink(tmp)


def main() -> int:
    check_only = "--check" in sys.argv
    n = cleanup_probes()
    if n:
        print(f"  （清掉 {n} 个残留的 _probe_*.html）")
    rows: dict = {}
    failed = False

    for key, page in SOURCE.items():
        r = measure(page)
        if "error" in r:
            print(f"❌ {key}（{page}）：{r['error']}")
            failed = True
            continue
        if r.get("readyState") != "complete":
            print(f"❌ {key}（{page}）：readyState = {r.get('readyState')}（必须 complete）")
            failed = True
            continue
        got = r["rows"].get(key, [])
        if not got:
            print(f"❌ {key}（{page}）：选择器 `{SELECTORS[key]}` 命中 0 个元素 —— "
                  f"页面改版了就要改 SOURCE/SELECTORS")
            failed = True
            continue
        heights = sorted({x["h"] for x in got})
        rows[key] = {
            "page": page,
            "selector": SELECTORS[key],
            "count": len(got),
            "heights": heights,
        }
        print(f"  {key:<12} {page:<30} n={len(got):<2} 高度={heights}")

    cleanup_probes()
    if failed:
        print("\n❌ 有档没量到 —— **不写 JSON**（写半份快照比不写更糟）")
        return 1

    report = {
        "_comment": (
            "生成物：`tools/measure_row_heights.py` 用无头 Chrome 量出来的实测值。"
            "别手改 —— 要改就重跑脚本。由 RowHeightParityTests 读取。"),
        "measuredAt": datetime.now().strftime("%Y-%m-%d %H:%M"),
        "rows": rows,
    }
    print(f"\n实测时刻 {report['measuredAt']}")
    if check_only:
        print("--check：不写文件")
        return 0
    with open(OUT, "w", encoding="utf-8") as fh:
        json.dump(report, fh, ensure_ascii=False, indent=2)
        fh.write("\n")
    print(f"✅ 已写 {os.path.relpath(OUT, ROOT)}")
    cleanup_probes()
    return 0


if __name__ == "__main__":
    sys.exit(main())
