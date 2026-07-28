#!/usr/bin/env python3
"""Stage-17：让 RCE 自己把 NVCSI PHY 寄存器 dump 出来。

到 stage16 为止，软件可控的每一项都已验证正确、RCE 也确认接受了全部 CSI 配置
（六条消息 `result=0`），但 NVCSI 中断依然 Δ=0。问题窄到
「RCE 接受了配置，但 NVCSI 硬件没真正进入接收状态」。

要往下查就得看 PHY/CIL 的链路状态寄存器 —— 而 **T194 的 NVCSI 寄存器映射不在
本树里**（stage15 借用 csi4 的偏移，读到的是数据类型配置表）。

R32 的消息集里正好有现成的工具：

    #define CAPTURE_PHY_STREAM_DUMPREGS_REQ   U32_C(0x3C)
    struct CAPTURE_PHY_STREAM_DUMPREGS_REQ_MSG { uint32_t stream_id; uint32_t csi_port; };
    struct CAPTURE_PHY_STREAM_DUMPREGS_RESP_MSG { uint32_t result; ... };

应答只回 `result` —— **寄存器内容由 RCE 打进它自己的日志**，我们通过
`tegra_rtcpu` 的 `rtcpu_string` 事件就能读到。既不需要寄存器映射，
也不需要在内核里 mmap 任何东西。

挂在 stage3 的 `csi5_stream_open_r32()` 之后：流开起来了再让固件 dump，
这样看到的是"配置已下发、流已打开"状态下 PHY 的真实样子。
"""
import re
import sys

F = ("/work/src/Linux_for_Tegra/source/public/kernel_src/kernel/nvidia/"
     "drivers/media/platform/tegra/camera/nvcsi/csi5_fops.c")

src = open(F).read()
if "r32-dumpregs" in src:
    print("FATAL: 已注入过 stage17")
    sys.exit(1)
assert "r32_csi_submit_wait" in src, "必须在 stage16 之后运行（复用它的等应答 helper）"

# csi5_stream_open_r32 里 PHY_STREAM_OPEN 提交之后追加一次 DUMPREGS
A = ('\t{\n\t\tu32 r32_res;\n\n'
     '\t\terr = r32_csi_submit_wait(chan->csi->dev, &msg,\n'
     '\t\t\t\t\t "PHY_STREAM", &r32_res);\n\t}\n')
n = src.count(A)
assert n >= 1, "stage16 的 PHY_STREAM 提交锚点命中 %d 次" % n

R = (A +
     '\n'
     '\t/*\n'
     '\t * r32-dumpregs: 让 RCE 把这条 PHY 流的寄存器打进它自己的日志。\n'
     '\t * 本树没有 T194 的 NVCSI 寄存器映射，而固件自带这个命令 —— 内容会\n'
     '\t * 经 rtcpu_string 事件冒出来，是目前唯一能看到 PHY 真实状态的途径。\n'
     '\t */\n'
     '\t{\n'
     '\t\tstruct CAPTURE_CONTROL_MSG dmsg;\n'
     '\t\tu32 dres;\n'
     '\n'
     '\t\tmemset(&dmsg, 0, sizeof(dmsg));\n'
     '\t\tdmsg.header.msg_id = CAPTURE_PHY_STREAM_DUMPREGS_REQ;\n'
     '\t\tdmsg.phy_stream_dumpregs_req.stream_id = stream_id;\n'
     '\t\tdmsg.phy_stream_dumpregs_req.csi_port = csi_port;\n'
     '\t\t(void)r32_csi_submit_wait(chan->csi->dev, &dmsg,\n'
     '\t\t\t\t\t  "PHY_DUMPREGS", &dres);\n'
     '\t}\n')
# 只替换第一处（csi5_stream_open_r32 里的那处；close 路径不需要）
src = src.replace(A, R, 1)

open(F, "w").write(src)
print("  ✅ csi5_fops.c: PHY_STREAM_OPEN 之后追加 DUMPREGS")
print("     r32-dumpregs %d 处" % src.count("r32-dumpregs"))
