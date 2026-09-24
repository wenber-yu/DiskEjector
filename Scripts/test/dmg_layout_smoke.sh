#!/usr/bin/env bash
# =============================================================
# 冒烟：dmg 安装窗口的**布局资产** —— 从源常量一路验到「卷里真有」。
#
# 【为什么必须有这条门】
# 安装窗口「好不好看」由三处数字共同决定，而它们**分散在两个文件 + 两个生成物**里：
#   · `Tools/make_dmg_background.py` —— 画背景图（箭头画在哪个高度、文案是什么）
#   · `Tools/make_dmg_layout.sh`     —— 摆图标 / 定窗口（Finder 往 `.DS_Store` 里写什么）
#   · `Resources/dmg/background.png` —— 背景图**生成物**
#   · `Resources/dmg/DS_Store`       —— 布局模板**生成物**，入库后由 build_app.sh 直接拷
#
# 任何一处漂了，症状都是「**箭头指歪 / 背景图被裁 / 文案是旧的**」，而**四处都不报错**
# —— 这正是本仓库最贵的那类坑：**同一个事实写在两处，然后漂了**。
#
# 最隐蔽的漂法是「**改了源、忘了重跑生成脚本**」：源文件全对，只有生成物是旧的。
# 2026-09-24 实测踩到过一次（背景图里的文案）⇒ 判据必须读**生成物的实际内容**，
# 不能只比对两个源文件；而文字这种「从像素里读不回来」的东西，靠生成物**自带的
# 出处块**来比对（见 ⑧）。
#
# 【判据】
#   ① 两个源文件的常量**双向**相等（图宽/图高/图标 y/两个图标 x）；
#   ② `Resources/dmg/background.png` 的**实际像素尺寸**（读 IHDR）== 常量；
#   ③ `.DS_Store` 的 `bwsp.WindowBounds` **尺寸** == (图宽, 图高 + 标题栏高)；
#   ④ `.DS_Store` 里两个图标坐标各出现**恰好 1 次**（按 `>II` 的字节计数）；
#   ⑤ `icvp.backgroundType == 2` 且 `backgroundImageAlias` 非空
#      —— 「设了背景图」与「背景图真的挂上了」是两回事，这条把两者分开；
#   ⑥ `build_app.sh` 的 `create_dmg` 里**真的有 `cp` 这两个资产的命令**
#      —— ⚠️ 判据是「有那条命令」，不是「变量名在文件里出现过」：只定义不拷、
#      或者只做 `[ -f … ]` 存在性检查，都会被「变量名出现过」放过去；
#   ⑦ **打包链路端到端**：用与 `create_dmg` **同一串旗标**
#      （`hdiutil create -fs HFS+ -format UDZO -srcfolder`）造一个只有资产的小 dmg，
#      挂载后**按字节比对**，并配一个**阴性样本**（staging 里不放资产 ⇒ 卷里必须没有）；
#   ⑧ **背景图自带的出处块**（PNG 的 `iTXt`，键 `de.*`）与源文件里的字面量逐项相等
#      —— 覆盖 ② 查不到的那一类：**文案 / 字体 / 箭头几何**（这些从像素里读不回来）。
#
# 【⑧ 为什么不能省】② 只比像素尺寸 ⇒ 「改了文案却忘了重跑脚本」查不出来，
# 而那正是 2026-09-24 真实发生过的：仓库里的 PNG 与「无句号」版的源逐字节相同，
# 而源已经被改成带句号 ⇒ **门全绿、图是旧的**。所以生成物必须**自己记下输入**。
# ⚠️ ⑧ 的边界：**没被 `provenance()` 记下的输入**漂了照样看不见 ⇒ 所以这里还断言
# 「出处块的键集合恰好等于守卫认识的那一组」，工具新增一项而守卫没跟上就判红。
#
# 【⑦ 为什么不能省】⑥ 只是**文本断言**。`hdiutil` 到底带不带 `.DS_Store` /
# `.background/`（都是点开头的隐藏项）**只能实测** —— 而这件事一坏，症状是
# 「用户下载到的 dmg 打开后是一片空白」，`build_app.sh` **一路绿灯**。
# ⚠️ 阴性样本是**装置自证**（证明这条检查链能报出「没有」，不是恒报「有」），
# 不是「hdiutil 会做什么怪事」的证据 —— 后者由阳性样本覆盖。
#
# 【代价】⚠️ **本门不快**：实测 **13–17 秒**（两次小 dmg 的建/挂/卸）。
# `hdiutil create` 每次约 4 秒，就这么点数据也一样 —— 是**固定开销**。
# 换 `-format UDRW` 能省 1 秒，但旗标必须与 `create_dmg` 一致才叫测同一个东西。
#
# 【装置自证】
#   · 解析 `.DS_Store` 用「找 `bwspblob` → 读 4 字节长度 → `plistlib` 解」。
#     ⚠️ 格式猜错会**静默**解出空字典；而 ④ 那种**计数**型判据猜错时**恒为 0**
#     ⇒ ④ 之前先打印「结构 ID 找没找到」当阳性对照：找不到就判**装置死**。
#   · 解析 PNG 用「按 chunk 走」。⚠️ 同样会静默得到空字典 ⇒ 先判
#     「IHDR 拿没拿到」「出处块有没有键」，拿不到就判**生成物过期 / 装置死**。
#   · ⑦ 里两个 staging **都**放了 `Applications` 替身 ⇒ 挂载后若连它都不在，
#     说明**卷没挂上**（装置没跑起来），**不是**「资产没带进去」。
#     ⚠️ 这两种情况在「卷里没这个文件」这一条上**逐字相同**，必须分开报。
#
# 【不覆盖什么（**手动**步骤，别指望本门）】
# 本门**不**看渲染效果：背景图有没有被窗口裁掉、箭头两端是不是正好落在两个图标上、
# 中文有没有变成方框 —— 那需要挂载真实 dmg、截图、按像素量（见 ENGINEERING-NOTES §8.143）。
# 它只在**改布局的那一轮**做一次，本门守的是此后不再漂。
#
# 【用法】Scripts/test/dmg_layout_smoke.sh
# 退出码：0 = 通过；1 = 未通过（含「找不到能跑的解释器」「装置没挂上」）。
# =============================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# ⑦ 的工作目录路径（`mktemp -d` 出来的，见 `dmg_roundtrip`）—— **只在失败时**打印。
# 因为它在系统临时目录下、不在仓库里，红了得能找得到现场。
ROUNDTRIP_WORK=""

# 逐个**试跑**取第一个真能跑的解释器。
# ⚠️ 判据必须是「跑起来的输出」，不能是 `[ -x ]`：本机 `/usr/bin/python3` 存在且可执行，
#    但它是 `xcrun` 桩，跑起来只打印 Xcode 许可警告（同病根见 Tools/clt_swift_env.sh）。
pick_python() {
    local candidate
    for candidate in "${PYTHON:-}" \
        /usr/bin/python3 \
        /Library/Developer/CommandLineTools/usr/bin/python3 \
        "$(command -v python3 2>/dev/null || true)"; do
        [ -n "$candidate" ] && [ -x "$candidate" ] || continue
        local out
        if out="$("$candidate" -c 'import sys; print(sys.version_info[0])' 2>/dev/null)" \
            && [ "$out" = "3" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

echo "▶ dmg 布局资产冒烟"

if ! PY="$(pick_python)"; then
    echo "   ✗ 找不到**能跑的** python3（试过 \${PYTHON}、/usr/bin/python3、CLT、PATH）——"
    echo "     本次冒烟**未执行**。⚠️ \`[ -x ]\` 为真不等于跑得起来：本机上"
    echo "     /usr/bin/python3 就是被 Xcode 许可桩挡住的（只打印许可警告）。"
    exit 1
fi
echo "   [自证] 解释器：${PY}（$("$PY" --version 2>&1)）"

RC=0
"$PY" - "$REPO_ROOT" <<'PY' || RC=1
import plistlib
import re
import struct
import sys

root = sys.argv[1]

fails: list[str] = []


def fail(msg: str) -> None:
    fails.append(msg)


def read(path: str) -> str:
    with open(path, encoding="utf-8") as fh:
        return fh.read()


# ---- ① 两个源文件的常量 ----
PY_BG = f"{root}/Tools/make_dmg_background.py"
SH_LAYOUT = f"{root}/Tools/make_dmg_layout.sh"
PY_BG_SRC = read(PY_BG)


def py_const(name: str) -> int:
    m = re.search(rf"^{name}\s*=\s*(\d+)", PY_BG_SRC, re.M)
    if not m:
        fail(f"{PY_BG} 里找不到常量 {name}")
        return -1
    return int(m.group(1))


def py_literal(name: str):
    """取 `NAME = "…"` 或 `NAME = 数字` 的字面值（用于与出处块比对）。"""
    m = re.search(rf'^{name}\s*=\s*(?:"([^"]*)"|(\d+))', PY_BG_SRC, re.M)
    if not m:
        fail(f"{PY_BG} 里找不到字面量 {name}")
        return None
    return m.group(1) if m.group(1) is not None else m.group(2)


def sh_const(name: str) -> int:
    m = re.search(rf"^{name}=(\d+)", read(SH_LAYOUT), re.M)
    if not m:
        fail(f"{SH_LAYOUT} 里找不到常量 {name}")
        return -1
    return int(m.group(1))


pairs = [
    ("图宽", py_const("WIDTH"), sh_const("BG_WIDTH")),
    ("图高", py_const("HEIGHT"), sh_const("BG_HEIGHT")),
    ("图标中心 y", py_const("ICON_Y"), sh_const("ICON_Y")),
    ("app 图标 x", py_const("APP_CX"), sh_const("APP_CX")),
    ("Applications 图标 x", py_const("APPS_CX"), sh_const("APPS_CX")),
]
print("   ① 常量同源比对（make_dmg_background.py ↔ make_dmg_layout.sh）")
for label, a, b in pairs:
    if a != b:
        fail(f"常量漂了：{label} —— 背景图脚本说 {a}，布局脚本说 {b}")
    else:
        print(f"      ✓ {label} = {a}")

BG_W = pairs[0][1]
BG_H = pairs[1][1]
ICON_Y = pairs[2][1]
APP_CX = pairs[3][1]
APPS_CX = pairs[4][1]
TITLEBAR_H = sh_const("TITLEBAR_H")


# ---- ②⑧ 背景图：像素尺寸 + 自带的出处块 ----
#
# ⚠️ PNG 是**分块**格式：8 字节签名，之后每块 = 4 字节长度 + 4 字节类型 + 数据 + 4 字节 CRC。
#    走错一步会**静默**得到空字典 ⇒ 先判「IHDR 拿没拿到」，拿不到就是装置问题。
def png_chunks(data: bytes):
    pos = 8
    dims = None
    itxt: dict[str, str] = {}
    while pos + 12 <= len(data):
        (length,) = struct.unpack(">I", data[pos : pos + 4])
        ctype = data[pos + 4 : pos + 8]
        body = data[pos + 8 : pos + 8 + length]
        if ctype == b"IHDR":
            dims = struct.unpack(">II", body[0:8])
        elif ctype == b"iTXt":
            # iTXt = 关键字\0 压缩标志(1) 压缩方法(1) 语言标签\0 译名\0 文本(UTF-8)
            kw, rest = body.split(b"\0", 1)
            compressed = rest[0]
            payload = rest[2:]
            _lang, payload = payload.split(b"\0", 1)
            _tkey, text = payload.split(b"\0", 1)
            if compressed == 0:
                itxt[kw.decode("latin-1")] = text.decode("utf-8")
        pos += 12 + length
        if ctype == b"IEND":
            break
    return dims, itxt


print("   ② 背景图实际像素尺寸（读 IHDR）")
PNG = f"{root}/Resources/dmg/background.png"
with open(PNG, "rb") as fh:
    png_data = fh.read()

dims = None
prov: dict[str, str] = {}
if png_data[:8] != b"\x89PNG\r\n\x1a\n":
    fail(f"{PNG} 不是合法 PNG（签名不对）")
else:
    dims, prov = png_chunks(png_data)
    if dims is None:
        fail(f"{PNG} 里没找到 IHDR —— **判装置死**（分块解析口径不对），不是「值不对」")
    elif dims != (BG_W, BG_H):
        fail(f"背景图实际是 {dims[0]}×{dims[1]}，而常量说 {BG_W}×{BG_H} —— 重跑 make_dmg_background.py")
    else:
        print(f"      ✓ 实际 {dims[0]}×{dims[1]} == 常量 {BG_W}×{BG_H}")

# ---- ⑧ 出处块（生成物自己记下的输入）与源逐项比对 ----
# 映射表：源文件里的字面量 → PNG 出处块里的键。**两边必须一一对应**。
PROV_MAP = [
    ("WIDTH", "de.width"),
    ("HEIGHT", "de.height"),
    ("ICON_Y", "de.icon_y"),
    ("APP_CX", "de.app_cx"),
    ("APPS_CX", "de.apps_cx"),
    ("TITLE", "de.title"),
    ("HINT", "de.hint"),
    ("TITLE_TOP", "de.title_top"),
    ("HINT_BOTTOM", "de.hint_bottom"),
    ("ARROW_GAP", "de.arrow_gap"),
    ("ARROW_DY", "de.arrow_dy"),
    ("ARROW_HEAD", "de.arrow_head"),
    ("ARROW_HALF", "de.arrow_half"),
    ("ARROW_LINE_END", "de.arrow_line_end"),
    ("FONT_PATH", "de.font_path"),
    ("FONT_INDEX_REGULAR", "de.font_index_regular"),
    ("FONT_INDEX_BOLD", "de.font_index_bold"),
]
print("   ⑧ 背景图出处块 ↔ 源文件字面量")
if not prov:
    fail(
        f"{PNG} 里没有 iTXt 出处块 —— 生成物是旧版脚本出的（那时还没记出处）。"
        " 重跑 `python3 Tools/make_dmg_background.py`。"
    )
else:
    # ⚠️ 键集合必须**恰好**相等：工具新增一项而这里没跟上 ⇒ 那一项就是**没牙的**，
    #    必须判红逼着两边一起改（否则「漏记」会静默变成「不检查」）。
    want_keys = {k for _, k in PROV_MAP}
    got_keys = set(prov)
    extra = sorted(got_keys - want_keys)
    missing = sorted(want_keys - got_keys)
    if extra or missing:
        fail(
            "出处块的键集合与本门的映射表不一致 —— 多出 "
            + (", ".join(extra) or "无")
            + "；缺少 "
            + (", ".join(missing) or "无")
            + "（工具与守卫必须一起改）"
        )
    else:
        print(f"      ✓ 键集合恰好相等（{len(want_keys)} 项）")
    drift = 0
    for name, key in PROV_MAP:
        src_val = py_literal(name)
        if src_val is None:
            drift += 1
            continue
        got = prov.get(key)
        if got != src_val:
            drift += 1
            fail(
                f"「{name}」源文件说 {src_val!r}，而背景图里记的是 {got!r}"
                f" ⇒ 改了源却**没重跑** make_dmg_background.py"
            )
    if drift == 0:
        print(f"      ✓ {len(PROV_MAP)} 项输入与源逐项相等（文案 / 字体 / 箭头几何都在内）")

# ---- ③④⑤ .DS_Store 的实际内容 ----
print("   ③④⑤ .DS_Store 实际内容")
DS = f"{root}/Resources/dmg/DS_Store"
data = open(DS, "rb").read()

# 装置自证：先确认结构 ID 找得到。找不到 ⇒ **装置死**，不是「值不对」。
missing_ids = [mid for mid in (b"bwspblob", b"icvpblob", b"Ilocblob") if data.find(mid) < 0]
if missing_ids:
    fail(
        "`.DS_Store` 里找不到结构 ID "
        + "、".join(m.decode() for m in missing_ids)
        + " —— **判装置死**（解析口径不对），不是「值不对」。"
        + " 先确认 Finder 真的写出来过这个文件。"
    )
else:
    print("      [自证] bwsp / icvp / Iloc 三个结构 ID 都在")


def blob(marker: bytes) -> bytes:
    pos = data.find(marker)
    length = struct.unpack(">I", data[pos + 8 : pos + 12])[0]
    return data[pos + 12 : pos + 12 + length]


if not missing_ids:
    bwsp = plistlib.loads(blob(b"bwspblob"))
    icvp = plistlib.loads(blob(b"icvpblob"))

    bounds = bwsp.get("WindowBounds")
    if not isinstance(bounds, str):
        fail(f"bwsp 里没有 WindowBounds（实际：{bounds!r}）—— 窗口尺寸没被记进模板")
    else:
        m = re.match(r"^\{\{(-?\d+), (-?\d+)\}, \{(\d+), (\d+)\}\}$", bounds.strip())
        if not m:
            fail(f"WindowBounds 解析不了：{bounds!r}")
        else:
            w, h = int(m.group(3)), int(m.group(4))
            want = (BG_W, BG_H + TITLEBAR_H)
            if (w, h) != want:
                fail(
                    f"模板里的窗口尺寸是 {w}×{h}，期望 {want[0]}×{want[1]}"
                    f"（图高 {BG_H} + 标题栏 {TITLEBAR_H}）"
                    f" —— 多半是改了常量却**忘了重跑 make_dmg_layout.sh**"
                )
            else:
                print(f"      ✓ WindowBounds 尺寸 {w}×{h} == 图 + 标题栏 {want[0]}×{want[1]}")

    for label, x in (("app", APP_CX), ("Applications", APPS_CX)):
        n = data.count(struct.pack(">II", x, ICON_Y))
        if n != 1:
            fail(f"模板里「{label}」的坐标 ({x},{ICON_Y}) 出现 {n} 次（期望恰好 1 次）")
        else:
            print(f"      ✓ {label} 坐标 ({x},{ICON_Y}) 在模板里")

    # 「设了背景图」与「背景图真的挂上了」是两回事
    if icvp.get("backgroundType") != 2:
        fail(f"icvp.backgroundType = {icvp.get('backgroundType')!r}，期望 2（图片）—— 背景图没挂上")
    elif not icvp.get("backgroundImageAlias"):
        fail("icvp 里没有 backgroundImageAlias —— 背景图没挂上（设了但没生效）")
    else:
        print("      ✓ backgroundType=2 且 backgroundImageAlias 非空")

# ---- ⑥ build_app.sh 的 create_dmg 真的**拷**这两个资产 ----
print("   ⑥ build_app.sh 的 create_dmg 是否拷资产")
BUILD = read(f"{root}/build_app.sh")
parts = BUILD.split("create_dmg() {", 1)
if len(parts) < 2:
    fail("build_app.sh 里找不到 create_dmg() —— 静态断言的口径失效了，先修本门")
else:
    # ⚠️ 取到 create_dmg 的**函数体**：只在文件头定义、函数里不用，不算数。
    body = parts[1].split("\n}", 1)[0]
    for var, name in (("DMG_BACKGROUND", "背景图"), ("DMG_DSSTORE_TEMPLATE", ".DS_Store 模板")):
        # 判据是「有一条以该变量为源的 cp」，不是「变量名出现过」：
        # 只 `[ -f "$VAR" ]` 做存在性检查、或只定义不拷，都会被「出现过」放过去。
        if not re.search(rf'cp\s+"\$\{{?{var}\}}?"', body):
            fail(f"create_dmg 里没有 `cp \"${var}\" …`（{name}）—— 检查了却没拷进 staging")
        else:
            print(f"      ✓ create_dmg 里 `cp \"${var}\" …`")

print()
if fails:
    print("   ①–⑥⑧ 未通过：")
    for f in fails:
        print(f"     · {f}")
    sys.exit(1)
print("   ①–⑥⑧ 通过：常量同源 · 生成物（含文案/字体出处）与源一致 · create_dmg 真的会拷")
PY

# =============================================================
# ⑦ 打包链路端到端：真造 dmg、真挂载、真按字节比对（含阴性样本）
#
# 用与 `build_app.sh` 的 `create_dmg` **同一串旗标**
# （`-fs HFS+ -format UDZO -volname … -srcfolder …`）—— 换旗标就等于换了被测对象。
# =============================================================
dmg_roundtrip() {
    local bg="$REPO_ROOT/Resources/dmg/background.png"
    local ds="$REPO_ROOT/Resources/dmg/DS_Store"

    # ⚠️ **工作目录用 `mktemp -d`（系统临时目录），且本门全程不调用 `rm`。**
    #    理由（2026-09-24 实测两次）：本环境有**批量删除守卫**，按「本轮累计删除数」
    #    计数；累计超阈值后，连 `rm -f` 两个文件都会被拦下**并直接结束调用进程** ⇒
    #    门会**跑到一半静默消失**（变异脚本两次这样中断，日志停在半句话上、无 traceback）。
    #    ⇒ 本门**不许依赖删除**：
    #       ① 全新目录 ⇒ 不必删；② `hdiutil create` 不覆盖同名文件 ⇒ dmg 用唯一名；
    #       ③ 收尾**只卸载卷**，文件留给系统清 `$TMPDIR`。
    #    ⚠️ 代价：红了以后现场在 `$TMPDIR` 下、不在仓库里 ⇒ 失败时会打印它的路径。
    local work
    work="$(mktemp -d)"
    ROUNDTRIP_WORK="$work"
    local with_st="$work/with.staging"
    local without_st="$work/without.staging"
    local mp_with="$work/with.mp"
    local mp_without="$work/without.mp"

    echo "   ⑦ 打包链路（hdiutil create -fs HFS+ -format UDZO -srcfolder，与 create_dmg 同款）"

    mkdir -p "$with_st/.background" "$without_st" "$mp_with" "$mp_without"

    # 阳性样本：形状与 create_dmg 的 staging 一致
    # ⚠️ `-f` / `-sfn` 留着（目录是全新的，本不需要）：万一哪天改成复用目录，
    #    少写这两个旗标的症状是**静默建出嵌套目录**（`ln -s` 建到旧链接里面去）。
    cp -f "$bg" "$with_st/.background/background.png"
    cp -f "$ds" "$with_st/.DS_Store"
    ln -sfn /Applications "$with_st/Applications"
    # 阴性样本：同样形状，但**不放**这两个资产
    ln -sfn /Applications "$without_st/Applications"

    # dmg 名带唯一后缀：`hdiutil create` **不会**覆盖已存在的文件
    #（唯一名 + 全新目录 ⇒ 双保险，且**不需要任何删除**）
    local tag="$$-$RANDOM"
    local with_dmg="$work/with.$tag.dmg"
    local without_dmg="$work/without.$tag.dmg"

    # ⚠️ 收尾**不能挂在会失败的命令后面**：`&&` 短路会让它被跳过 ⇒ 卷留在系统里。
    #    **所有**提前 return 的路径都走这里。
    # ⚠️ 这里**只卸载、不删文件**（理由见本函数开头那段实测）：收尾里放 `rm` 的后果
    #    不是「删不掉」，而是**调用进程被杀** ⇒ 门跑到一半消失。
    # ⚠️ 卸载本身也要 `|| true`：`set -e` 下「卷本来就没挂上」这种正常情形会让门直接退出。
    cleanup_roundtrip() {
        hdiutil detach "$mp_with" -quiet 2>/dev/null || true
        hdiutil detach "$mp_without" -quiet 2>/dev/null || true
        return 0
    }

    local pair dmg st
    for pair in "with" "without"; do
        case "$pair" in
            with) st="$with_st"; dmg="$with_dmg" ;;
            without) st="$without_st"; dmg="$without_dmg" ;;
        esac
        # ⚠️ `（${pair}）` 的**花括号不能省**：全角括号 `（` 是 UTF-8 的 `EF BC 88`，
        #    bash 3.2 在多字节 locale 下会把它**算进变量名** ⇒ 走到这一行就
        #    `pair\xef: unbound variable`。2026-09-24 实测踩到，而且**只在失败路径上炸**
        #    （前 6 次全绿没暴露）⇒ 越需要这条报错的时候它越炸。
        if ! hdiutil create -fs HFS+ -format UDZO -volname "smoke-$pair" -srcfolder "$st" "$dmg" >/dev/null; then
            echo "      ✗ hdiutil create 失败（${pair}）—— **装置没跑起来**，本次判据不作数"
            cleanup_roundtrip
            return 1
        fi
    done

    if ! hdiutil attach -readonly -nobrowse -mountpoint "$mp_with" "$with_dmg" >/dev/null; then
        echo "      ✗ hdiutil attach 失败（阳性样本）—— **装置没挂上**，本次判据不作数"
        cleanup_roundtrip
        return 1
    fi
    if ! hdiutil attach -readonly -nobrowse -mountpoint "$mp_without" "$without_dmg" >/dev/null; then
        echo "      ✗ hdiutil attach 失败（阴性样本）—— **装置没挂上**，本次判据不作数"
        cleanup_roundtrip
        return 1
    fi

    # 装置自证：两个 staging 都放了 `Applications` 替身 ⇒ 若它不在，是**卷没挂上**，
    # 而不是「资产没带进去」。这两种情况在「卷里没这个文件」上**逐字相同**。
    local mp
    for mp in "$mp_with" "$mp_without"; do
        if [ ! -L "$mp/Applications" ]; then
            echo "      ✗ $mp 里连 Applications 替身都没有 —— **卷没挂上**（装置死），判据不作数"
            cleanup_roundtrip
            return 1
        fi
    done

    local bad=0

    # 阳性：卷里必须有，且**逐字节**相同
    if [ ! -f "$mp_with/.DS_Store" ]; then
        echo "      ✗ 卷里没有 .DS_Store ⇒ 打包链路把点文件丢了（用户打开 dmg 会是一片空白）"
        bad=1
    elif ! cmp -s "$mp_with/.DS_Store" "$ds"; then
        echo "      ✗ 卷里的 .DS_Store 与 Resources/dmg/DS_Store **内容不同**"
        bad=1
    else
        echo "      ✓ 卷里的 .DS_Store 与模板逐字节相同"
    fi

    if [ ! -f "$mp_with/.background/background.png" ]; then
        echo "      ✗ 卷里没有 .background/background.png ⇒ 背景图没进卷"
        bad=1
    elif ! cmp -s "$mp_with/.background/background.png" "$bg"; then
        echo "      ✗ 卷里的背景图与 Resources/dmg/background.png **内容不同**"
        bad=1
    else
        echo "      ✓ 卷里的背景图与源文件逐字节相同"
    fi

    # 阴性：没放就必须没有 —— 这是**装置自证**：证明「挂载 → 判存在 → 比字节」这条
    # 检查链**能报出「没有」**，而不是恒报「有」。⚠️ 它证明的是**装置**有分辨力，
    # 不是「hdiutil 会做什么怪事」（后者由阳性样本覆盖）。
    if [ -e "$mp_without/.DS_Store" ] || [ -e "$mp_without/.background" ]; then
        echo "      ✗ 阴性样本（staging 里没放资产）卷里却有 ⇒ 判据恒报「有」，先修本门"
        bad=1
    else
        echo "      ✓ 阴性样本卷里确实没有这两个资产（检查链能报出「没有」）"
    fi

    cleanup_roundtrip
    return "$bad"
}

dmg_roundtrip || RC=1

echo ""
if [ "$RC" != 0 ]; then
    echo "   ✗ dmg 布局冒烟未通过（明细见上）"
    # 现场在系统临时目录下（本门不删文件，见 ⑦ 的注释）⇒ 红了要能找得到
    # ⚠️ 用 `if` 不用 `[ -n … ] && echo`：后者在变量为空时返回非零，`set -e` 会提前退出
    if [ -n "$ROUNDTRIP_WORK" ]; then
        echo "   （本轮 ⑦ 的工作目录：${ROUNDTRIP_WORK}）"
    fi
    exit 1
fi
echo "   ✓ dmg 布局资产通过：常量同源 · 生成物（含出处）对得上 · 打包链路真的带得进卷"
