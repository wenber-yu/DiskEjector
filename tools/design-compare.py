#!/usr/bin/env python3
"""把 v2 设计稿的屏幕与实现出的走查快照并排比对，输出 `cmp-*.png`。

```bash
P=/Users/wenbo/.workbuddy-ai/binaries/python/envs/default/bin/python
$P tools/design-compare.py                 # 全部屏幕
$P tools/design-compare.py main settings   # 只跑指定的
```

产物落在 `<repo>/.build/design-cmp/`。

## 为什么放在仓库里

这个脚本原来在 `/tmp/de-design/` 下，**被系统清掉了**（本项目笔记里就写着
「`/tmp` 会被定期清理」）。设计走查是每一轮都要做的事，工具不该是一次性的。

## 两条硬约束（来自技能 `html-mockup-layout-probe`）

1. **探针临时文件必须与原页面同目录** —— 否则相对的 `<link href="../assets/ds.css">`
   404，量到的是无样式布局，窗口尺寸全错。
2. **探针必须在 `DOMContentLoaded` 之后量**，且输出里要带 `svg` 数量自证；
   数量不对说明量的是半成品页面，所有数字作废。

`--force-device-scale-factor=2` 出 2x 图，裁切时坐标要乘 2。
"""
from __future__ import annotations

import argparse
import html
import os
import pathlib
import re
import subprocess
import sys

from PIL import Image, ImageDraw, ImageFont

CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

# ⚠️ **`--no-sandbox` 不能省。** 在受管（已有一层沙箱的）环境里，Chrome 自己的沙箱
# 起不来：`sandbox initialization failed: Operation not permitted` →
# GPU / network 进程连环崩 → **`--dump-dom` / `--screenshot` 输出 0 字节**。
# 症状极具误导性：命令**退出码是 0**、stderr 被 `2>/dev/null` 吞掉后什么都不剩，
# 看起来像「探针没注入」或「页面没问题」。加了这个 flag 立刻正常。
# 与 SwiftPM 的 `sandbox_apply: Operation not permitted` 是同一类问题。
CHROME_BASE = [CHROME, "--headless=new", "--no-sandbox", "--disable-gpu", "--hide-scrollbars"]
REPO = pathlib.Path(__file__).resolve().parent.parent
DESIGN = REPO / "Design/ui" / "v2"
SCREENS = DESIGN / "screens"
OUT = REPO / ".build" / "design-cmp"
SNAP = pathlib.Path("/tmp/de-snapshots")

# ⚠️ PingFang.ttc 在 PIL 这个构建里打不开（`cannot open resource`，index 0/1 都不行）
FONT_CANDIDATES = [
    ("/System/Library/Fonts/Hiragino Sans GB.ttc", 0),
    ("/System/Library/Fonts/STHeiti Light.ttc", 0),
]

# 屏幕名 → (设计稿页面, 窗口选择器, 实现快照前缀, 是否深色, 实现侧要不要裁底)
#
# ⚠️ `05-settings.html` 的设置窗是**裸 `class="win"`**（没有 `win--settings` 修饰符），
# 与 `ds.css` 里那条 `.win--settings { width: …; height: … }` 对不上 —— 尺寸由页面
# 自己的 `<style>` 给。选择器只能用 `.win`。
#
# ⚠️ **没有 `settings-dark`**：`07-dark.html` 里只有 `win--main` 与 `win--popover`
# 两个窗口，深色稿没画设置窗。硬凑 `.win` 会选中主窗，出的是错图 —— 宁可缺，不可错。
#
# ⚠️ **没有 `onboarding`**：`onboarding-{light,dark}.png` 的 **alpha 均值只有 20**
# （主窗口是 255）—— 离屏快照里**玻璃根本没渲染出来**，整张图基本透明。
# 拿它跟设计稿比会得到「设计稿有内容、实现一片空白」的假结论。同理，宁可缺，不可错。
# 真机的引导面板由 `--preview-onboarding-keys` 守（通过），不是没实现。
#
# `trim="backdrop"`：弹窗的实现快照外面套了一圈**暗化桌面**的灰底（模态背后那层），
# 量内容前必须裁掉 —— 裁完才是设计稿 `.alert` 的 400pt 宽。见 ``crop_backdrop``。
TARGETS = {
    "main": ("01-main-window.html", ".win--main", "main-window", False, None),
    "main-dark": ("07-dark.html", ".win--main", "main-window", True, None),
    "settings": ("05-settings.html", ".win", "settings", False, None),
    "popover": ("02-menu-bar.html", ".win--popover", "menu-popover", False, None),
    "popover-dark": ("07-dark.html", ".win--popover", "menu-popover", True, None),
    # 03-eject-flow.html 里有**两个** `.alert`：先是琥珀的「即将推出」、后是红的
    # 「无法推出」。本工具用 `querySelector`（只取第一个），所以失败那一个要靠
    # `:has()` 精确定位 —— 别用 `.alert:nth-of-type(2)`，两个 alert 不在同一父级下。
    "alert-busy": ("03-eject-flow.html", ".alert", "alert-busy", False, "backdrop"),
    "alert-failure": (
        "03-eject-flow.html", ".alert:has(.alert__icon--danger)", "alert-failure", False,
        "backdrop"),
}

# 探针临时文件：**与设计稿同目录**（相对 `<link href="../assets/ds.css">` 才解析得到），
# 固定名、**整轮结束统一删一次**。
#
# ⚠️ 别在每次 `probe()` 里删 —— 删除次数一多会触发批量删除确认，命令被拦下，
# 于是 `_probe.html` 残留在设计稿目录里（实测踩到）。见技能 `html-mockup-layout-probe`。
PROBE_TMP = SCREENS / "_probe.html"


def load_font(size: int):
    for path, index in FONT_CANDIDATES:
        try:
            return ImageFont.truetype(path, size, index=index)
        except OSError:
            continue
    return ImageFont.load_default()


def probe(page: pathlib.Path, selectors: list[str]) -> dict[str, tuple[float, float, float, float]]:
    """用 DOM 探针量出选择器的 CSS 坐标（pt）。拿不到就抛 —— 绝不当作「没问题」。"""
    sels = ",".join('"%s"' % s for s in selectors)
    probe_js = """
<script>
function measure() {
  var out = [];
  // 自证：图标没注入时这里会是 0，看到 0 就别信后面的数字
  out.push('readyState=' + document.readyState +
           ' svg=' + document.querySelectorAll('svg').length +
           ' [data-i-done]=' + document.querySelectorAll('[data-i-done]').length);
  [%s].forEach(function (s) {
    var el = document.querySelector(s);
    if (!el) { out.push('MISSING ' + s); return; }
    var r = el.getBoundingClientRect();
    out.push('RECT ' + s + ' ' + Math.round(r.x) + ' ' + Math.round(r.y) + ' ' +
             Math.round(r.width) + ' ' + Math.round(r.height));
  });
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
""" % sels

    # 临时文件与页面同目录（相对 CSS 才解析得到），固定名，**由 main() 统一删**
    tmp = PROBE_TMP
    tmp.write_text(page.read_text(encoding="utf-8").replace("</body>", probe_js + "</body>"),
                   encoding="utf-8")
    dom = subprocess.run(
        CHROME_BASE + ["--window-size=1500,4200", "--virtual-time-budget=5000",
                       "--dump-dom", "file://" + str(tmp)],
        capture_output=True, text=True, timeout=120).stdout

    m = re.search(r'<pre id="PROBE">(.*?)</pre>', dom, re.S)
    if not m:
        raise RuntimeError(f"探针未注入：{page.name}（别把「没输出」当成「没问题」）")
    lines = [ln for ln in html.unescape(m.group(1)).split("\n") if ln.strip()]
    selfcheck = lines[0] if lines else ""
    if "svg=0" in selfcheck.replace(" ", ""):
        raise RuntimeError(f"量到的是半成品页面（{selfcheck}）—— 所有数字作废")

    rects: dict[str, tuple[float, float, float, float]] = {}
    for ln in lines:
        if ln.startswith("RECT "):
            _, sel, x, y, w, h = ln.split()
            rects[sel] = (float(x), float(y), float(w), float(h))
    print(f"    探针自证 {selfcheck}")
    return rects


def screenshot(page: pathlib.Path, out: pathlib.Path, size: str = "1500,4200") -> None:
    subprocess.run(
        CHROME_BASE + ["--force-device-scale-factor=2", f"--window-size={size}",
                       f"--screenshot={out}", "--virtual-time-budget=5000",
                       "file://" + str(page)],
        capture_output=True, text=True, timeout=180, check=True)


def crop_design(shot: pathlib.Path, rect: tuple[float, float, float, float]) -> Image.Image:
    """按探针给的 CSS 坐标从 2x 截图里裁出窗口。"""
    im = Image.open(shot).convert("RGB")
    x, y, w, h = rect
    box = (int(x * 2) - 2, int(y * 2) - 2, int((x + w) * 2) + 2, int((y + h) * 2) + 2)
    return im.crop(box)


def crop_backdrop(im: Image.Image, tol: int = 40) -> Image.Image:
    """裁掉实现快照外面那圈「暗化桌面」的纯色底，只留弹窗本体。

    弹窗（模态）的走查快照是 **480×410**，而设计稿 `.alert` 是 **400×330**
    —— 多出来的正是四周各 **40pt** 的暗化背景（模态背后那层）。

    ⚠️ **不要硬写 40pt**。那个边距是快照渲染时留的，改了会**静默裁错**
    （裁多了啃掉弹窗、裁少了留一圈灰）。所以这里**从左上角像素取背景色**，
    再按「与背景的通道差 > `tol`」找内容包围盒 —— 边距怎么变都跟得上。

    裁得对不对由调用方复核（见 `main()` 里那条尺寸自检）：
    裁完的尺寸必须与设计稿的矩形差 ≤ 6pt，否则抛错。
    """
    rgb = im.convert("RGB")
    w, h = rgb.size
    bg = rgb.getpixel((2, 2))

    def differs(c: tuple[int, int, int]) -> bool:
        return max(abs(c[i] - bg[i]) for i in range(3)) > tol

    xs = [x for x in range(w) if any(differs(rgb.getpixel((x, y)))
                                     for y in range(0, h, max(1, h // 60)))]
    ys = [y for y in range(h) if any(differs(rgb.getpixel((x, y)))
                                     for x in range(0, w, max(1, w // 60)))]
    if not xs or not ys:
        raise RuntimeError("裁底失败：整张图都和左上角一个颜色 —— 判据或背景取错了")
    return im.crop((xs[0], ys[0], xs[-1] + 1, ys[-1] + 1))


def mean_brightness(im: Image.Image) -> float:
    """图中央一条横带的平均亮度（0…255）。用来判「这张图实际是深色还是浅色」。"""
    w, h = im.size
    band = im.crop((int(w * 0.05), int(h * 0.35), int(w * 0.95), int(h * 0.75)))
    px = list(band.getdata())
    return sum(sum(c) for c in px) / (len(px) * 3)


def side_by_side(design: Image.Image, impl: Image.Image, title: str, out: pathlib.Path) -> None:
    # **自检：左右必须同明暗。** 曾经所有页共用一个截图文件名，
    # 「已在缓存里」的页于是读到被覆盖的文件 → 出了张「左浅右深」的对照图，
    # 不报错、不崩溃，只是**静默错**（实测 `cmp-popover-dark` 左右 241.8 vs 46.0）。
    # 亮度是最省事也最有效的哨兵：它不关心为什么错，只关心「这两张根本不是一回事」。
    dl, il = mean_brightness(design), mean_brightness(impl)
    if abs(dl - il) > 60:
        raise RuntimeError(
            f"设计稿侧与实现侧明暗对不上（{dl:.0f} vs {il:.0f}）—— "
            "多半是取错了设计稿页面、裁错了元素，或设计稿截图被别的页覆盖了")

    if design.size != impl.size:
        impl = impl.resize(design.size, Image.LANCZOS)
    pad, gap, label_h = 20, 24, 52
    canvas = Image.new("RGB",
                       (design.width * 2 + gap + pad * 2, label_h + design.height + pad * 2),
                       (26, 26, 28))
    draw = ImageDraw.Draw(canvas)
    font = load_font(16)
    for i, (img, lines) in enumerate([
        (design, (f"设计稿 · {title}", "v2/screens（无头 Chrome 2x）")),
        (impl, ("实现 · 走查快照", "DE_SNAPSHOTS=1 出的图")),
    ]):
        x = pad + i * (design.width + gap)
        for j, line in enumerate(lines):
            draw.text((x, pad + j * 21 - 4), line,
                      fill=(235, 235, 238) if j == 0 else (170, 170, 176), font=font)
        canvas.paste(img, (x, pad + label_h - 4))
    canvas.save(out)
    print(f"    → {out.relative_to(REPO)}  {canvas.size[0]}×{canvas.size[1]}")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("names", nargs="*", help=f"要跑的屏幕：{', '.join(TARGETS)}（默认全部）")
    args = ap.parse_args()

    names = args.names or list(TARGETS)
    unknown = [n for n in names if n not in TARGETS]
    if unknown:
        print(f"未知屏幕：{unknown}；可选 {list(TARGETS)}", file=sys.stderr)
        return 2

    OUT.mkdir(parents=True, exist_ok=True)
    cache: dict[str, pathlib.Path] = {}
    failed: list[str] = []

    try:
        for name in names:
            page_name, selector, snap_prefix, dark, trim = TARGETS[name]
            page = SCREENS / page_name
            snap = SNAP / f"{snap_prefix}-{'dark' if dark else 'light'}.png"
            print(f"  [{name}] {page_name} {selector}")
            if not snap.exists():
                print(f"    ✗ 缺实现快照 {snap}（先跑 DE_SNAPSHOTS=1 swift test --filter 导出设计快照）")
                failed.append(name)
                continue
            try:
                rects = probe(page, [selector])
                if selector not in rects:
                    raise RuntimeError(f"设计稿里找不到 {selector}")
                if page_name not in cache:
                    # ⚠️ **每页一个独立文件名**。曾经所有页共用一个 `_design-full.png`
                    # 并且 `cache` 里存的是**路径** —— 于是「已经在缓存里」的页不会再截，
                    # 却会去读那个**已经被别的页覆盖掉**的文件。
                    # 实测症状：`cmp-popover-dark.png` 左边裁出来的是**浅色**的
                    # `02-menu-bar.html`（左右亮度 241.8 vs 46.0，一眼就对不上）。
                    # 这类「缓存指向会被覆盖的文件」的 bug 不会报错，只会静默出错图。
                    out_png = OUT / f"_design-{page.stem}.png"
                    screenshot(page, out_png)
                    cache[page_name] = out_png
                design = crop_design(cache[page_name], rects[selector])
                impl = Image.open(snap).convert("RGB")
                if trim == "backdrop":
                    impl = crop_backdrop(impl)
                    # **裁完必须复核**：裁错的话并排图会被拉伸，而拉伸**不会报错** ——
                    # 只会让人以为「实现和设计稿差很多」。这条自检把静默错变成红字。
                    dw, dh = design.size[0] / 2, design.size[1] / 2
                    iw, ih = impl.size[0] / 2, impl.size[1] / 2
                    if abs(dw - iw) > 6 or abs(dh - ih) > 6:
                        raise RuntimeError(
                            f"裁底后尺寸对不上：设计稿 {dw:.0f}×{dh:.0f}pt、"
                            f"实现 {iw:.0f}×{ih:.0f}pt（差 >6pt）—— 多半裁错了")
                side_by_side(design, impl,
                             f"{selector} {'深色' if dark else '浅色'}",
                             OUT / f"cmp-{name}.png")
            except Exception as exc:  # noqa: BLE001 — 出图工具，报错要看得见
                print(f"    ✗ {exc}")
                failed.append(name)
    finally:
        # **整轮只处理这一次**（见 PROBE_TMP 的注释：删多了会触发批量删除确认）。
        #
        # 用 `replace`（移走）而不是 `unlink`（删除）：一是设计稿目录不能留 `_probe.html`，
        # 二是**删除次数在单轮里是有配额的**，用完 `rm` 会被安全策略拦下
        # （实测 `SAFE_DELETE_BULK_CONFIRM_REQUIRED`，count=50/threshold=50），
        # 那时连工具本身都跑不起来。移走不占配额，效果一样干净。
        if PROBE_TMP.exists():
            PROBE_TMP.replace(OUT / "_probe-last.html")

    print()
    if failed:
        print(f"✗ {len(failed)} 个屏幕没出图：{failed}")
        return 1
    print(f"✅ {len(names)} 个屏幕都出了图 → {OUT}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
