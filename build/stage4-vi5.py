#!/usr/bin/env python3
"""变体 I 注入器：把帧缓冲 IOVA 补写进描述符内联字段（零帧真凶）。

2026-07-28 定位：R35 的 vi5_setup_surface 把地址写进 **memoryinfo 表**
（R32 固件根本不知道这张表的存在），`ch_cfg.atomp.surface[0].offset` 恒为 0
→ R32 固件把帧 DMA 向空地址 → 永远等不到完成 → 2500ms request timeout。
这正是 0725「每帧内存模型换范式(reloc vs buffer-table)」在 v4l2 路径的具体形态。

修法：门控下把同一个 offset 按 R32 范式补写进 atomp.surface[]（内联），
memoryinfo 照旧写（R32 固件无视它，零冲突）。
"""
import sys

F = ("/work/src/Linux_for_Tegra/source/public/kernel_src/kernel/nvidia/"
     "drivers/media/platform/tegra/camera/vi/vi5_fops.c")

src = open(F).read()
if "r32-vi5" in src:
    print("FATAL: vi5 已注入过")
    sys.exit(1)


def rep(anchor, repl, name):
    global src
    n = src.count(anchor)
    assert n == 1, "锚点[%s]命中 %d 次" % (name, n)
    src = src.replace(anchor, repl, 1)


# ── ① extern 声明（挂在 include 区末尾）─────────────────────────────────────
# 找一个稳定 include 锚：vi5_fops.c 的最后一个 #include 行
import re
incs = re.findall(r"(?m)^#include .*$", src)
assert incs, "找不到 include"
last_inc = incs[-1] + "\n"
DECL = last_inc + (
    "\n#if IS_ENABLED(CONFIG_TEGRA_CAPTURE_R32_ABI)\n"
    "/* exported by tegra-camera-rtcpu.c (shared runtime gate) */\n"
    "bool tegra_camrtc_r32_camera_power_enabled(void);\n"
    "#endif\n")
rep(last_inc, DECL, "extern")

# ── ② surface[0] 内联地址 ────────────────────────────────────────────────────
A2 = ("\tdesc_memoryinfo->surface[0].base_address = offset;\n"
      "\tdesc_memoryinfo->surface[0].size = chan->format.bytesperline * height;\n"
      "\tdesc->ch_cfg.atomp.surface_stride[0] = bpl;\n")
R2 = A2 + (
    "\n#if IS_ENABLED(CONFIG_TEGRA_CAPTURE_R32_ABI)\n"
    "\t/*\n"
    "\t * r32-vi5: the R32 firmware reads the surface IOVA INLINE from the\n"
    "\t * descriptor (ch_cfg.atomp.surface[]) -- it has never heard of the\n"
    "\t * R35 memoryinfo table filled above.  Without these two lines the fw\n"
    "\t * sees offset 0, DMAs the frame into nowhere, and every request dies\n"
    "\t * with the exact \"timed out after 2500 ms\" we chased all day.\n"
    "\t */\n"
    "\tif (tegra_camrtc_r32_camera_power_enabled()) {\n"
    "\t\tdesc->ch_cfg.atomp.surface[0].offset = (u32)offset;\n"
    "\t\tdesc->ch_cfg.atomp.surface[0].offset_hi = (u32)((u64)offset >> 32);\n"
    "\t\tdev_info_once(chan->vi->dev,\n"
    "\t\t\t      \"r32-vi5: inline surface IOVA active (%pad)\\n\",\n"
    "\t\t\t      &offset);\n"
    "\t}\n"
    "#endif\n")
rep(A2, R2, "surface0")

# ── ③ 嵌入数据 surface 内联地址 ──────────────────────────────────────────────
A3 = ("\t\tdesc->ch_cfg.atomp.surface_stride[VI_ATOMP_SURFACE_EMBEDDED]\n"
      "\t\t\t= chan->embedded_data_width * BPP_MEM;\n")
R3 = A3 + (
    "\n#if IS_ENABLED(CONFIG_TEGRA_CAPTURE_R32_ABI)\n"
    "\t\t/* r32-vi5: same inline-IOVA contract for the embedded-data plane */\n"
    "\t\tif (tegra_camrtc_r32_camera_power_enabled()) {\n"
    "\t\t\tdesc->ch_cfg.atomp.surface[VI_ATOMP_SURFACE_EMBEDDED]\n"
    "\t\t\t\t.offset = (u32)chan->emb_buf;\n"
    "\t\t\tdesc->ch_cfg.atomp.surface[VI_ATOMP_SURFACE_EMBEDDED]\n"
    "\t\t\t\t.offset_hi = (u32)((u64)chan->emb_buf >> 32);\n"
    "\t\t}\n"
    "#endif\n")
rep(A3, R3, "embedded")

open(F, "w").write(src)
print("  ✅ vi5_fops.c (3 处)")
print("     r32-vi5 %d 处" % src.count("r32-vi5"))
