#!/usr/bin/env python3
"""变体 J 注入器（路线 B）：v4l2 内核内部路径补上描述符 dma_sync。

2026-07-28 定位链的终点：
  · R32 固件从描述符**内联**读帧 IOVA（stage4 已补写 atomp.surface[]）
  · 但 R32 的 reloc pass 除了改写 IOVA，最后还做了关键一步：
        dma_sync_single_range_for_device(rtcpu_dev, requests.iova,
                                         request_offset, request_size, DMA_TO_DEVICE)
    —— 让 CPU 刚打好补丁的描述符对 RCE 可见。
  · 而 reloc pass 只挂在 VI_CAPTURE_REQUEST **ioctl** 分支（argus 路径）。
    v4l2-ctl 走内核内部 vi5_capture_enqueue → vi_capture_request()，
    **完全没有这次 sync** → RCE 读到的可能是陈旧/未落盘的描述符 → 静默 2500ms 超时。

修法：在 vi_capture_request() 提交 IVC 之前，门控下补这次 sync。
    v4l2 路径 num_relocs=0，不需要 IOVA 改写（stage4 已直写），只缺可见性这一步。
"""
import sys

F = ("/work/src/Linux_for_Tegra/source/public/kernel_src/kernel/nvidia/"
     "drivers/media/platform/tegra/camera/fusa-capture/capture-vi.c")

src = open(F).read()
if "r32-sync" in src:
    print("FATAL: capture-vi.c 已注入过 stage5")
    sys.exit(1)

A = ("\tmutex_lock(&capture->reset_lock);\n"
     "\n"
     "\tmemset(&capture_desc, 0, sizeof(capture_desc));\n"
     "\tcapture_desc.header.msg_id = CAPTURE_REQUEST_REQ;\n")
n = src.count(A)
assert n == 1, "锚点命中 %d 次" % n

R = ("\tmutex_lock(&capture->reset_lock);\n"
     "\n"
     "#if IS_ENABLED(CONFIG_TEGRA_CAPTURE_R32_ABI)\n"
     "\t/*\n"
     "\t * r32-sync: make the descriptor visible to the RCE.\n"
     "\t *\n"
     "\t * The r32 firmware reads the surface IOVA INLINE from the descriptor\n"
     "\t * ring (see the atomp.surface[] fill in vi5_setup_surface).  The r32\n"
     "\t * reloc pass ends with exactly this sync -- but that pass only runs on\n"
     "\t * the VI_CAPTURE_REQUEST ioctl path (argus).  The in-kernel v4l2 path\n"
     "\t * (vi5_capture_enqueue -> here) never had it, so the CPU-side writes\n"
     "\t * were not guaranteed visible to the RCE: every request then died with\n"
     "\t * \"request timed out after 2500 ms\" and zero VINOTIFY events.\n"
     "\t */\n"
     "\tif (tegra_camrtc_r32_camera_power_enabled() &&\n"
     "\t    capture->requests.iova != 0U && capture->request_size != 0U) {\n"
     "\t\tdma_sync_single_range_for_device(capture->rtcpu_dev,\n"
     "\t\t\tcapture->requests.iova,\n"
     "\t\t\treq->buffer_index * capture->request_size,\n"
     "\t\t\tcapture->request_size, DMA_TO_DEVICE);\n"
     "\t\tdev_info_once(chan->dev,\n"
     "\t\t\t      \"r32-sync: descriptor sync active (iova=%pad size=%u)\\n\",\n"
     "\t\t\t      &capture->requests.iova, capture->request_size);\n"
     "\t}\n"
     "#endif\n"
     "\n"
     "\tmemset(&capture_desc, 0, sizeof(capture_desc));\n"
     "\tcapture_desc.header.msg_id = CAPTURE_REQUEST_REQ;\n")
src = src.replace(A, R, 1)

# extern 声明（挂在最后一个 #include 之后）
import re
incs = re.findall(r"(?m)^#include .*$", src)
assert incs, "找不到 include"
last = incs[-1] + "\n"
DECL = last + ("\n#if IS_ENABLED(CONFIG_TEGRA_CAPTURE_R32_ABI)\n"
               "/* exported by tegra-camera-rtcpu.c (shared runtime gate) */\n"
               "bool tegra_camrtc_r32_camera_power_enabled(void);\n"
               "#endif\n")
assert src.count(last) >= 1
src = src.replace(last, DECL, 1)

open(F, "w").write(src)
print("  ✅ capture-vi.c (2 处)")
print("     r32-sync %d 处" % src.count("r32-sync"))
