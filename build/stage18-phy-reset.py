#!/usr/bin/env python3
"""Stage-18：PHY_STREAM_OPEN 之前先发一条 PHY_STREAM_RESET。

这是软件侧唯一还没试过的东西。

`CAPTURE_PHY_STREAM_RESET_REQ (0x3A)` 在 R32 与 R35 的消息集里都有，
但**上游内核从不使用它**（全树 grep 无调用）。R35 不需要是因为它的 RCE 固件
自己管 PHY 的上电/复位；出厂 R32 固件则可能期待客户端在 open 之前先 reset。

现状：软件可控的每一项都验证正确、RCE 也确认接受了 CSI 配置
（`result=0`，且与 `PHY_DUMPREGS` 的 `result=1` 形成对照，证明 0 是真接受），
但 NVCSI 在链路层依然完全静默（中断 Δ=0，VI 却有 Δ=413 的超时中断）。
⇒ 「配置被接受了但硬件没进入接收状态」，一次显式 PHY 复位正好对症。

改动：在 `csi5_stream_open_r32()` 里，OPEN 之前插一条 RESET，
用 stage16 现成的 `r32_csi_submit_wait()` 发并打出返回码。
返回码本身就是信息：
  · result=0  → 固件支持且执行了，看是否出帧
  · result≠0  → 固件不支持这条，等于排除这个方向
"""
import sys

F = ("/work/src/Linux_for_Tegra/source/public/kernel_src/kernel/nvidia/"
     "drivers/media/platform/tegra/camera/nvcsi/csi5_fops.c")

src = open(F).read()
if "r32-phyreset" in src:
    print("FATAL: 已注入过 stage18")
    sys.exit(1)
assert "r32_csi_submit_wait" in src, "必须在 stage16 之后运行"

# csi5_stream_open_r32 里填 PHY_STREAM_OPEN 消息之前插入 RESET
# ⚠️ 单看 msg_id 那行在上游 csi5_stream_open 里也有,必须带上 R32 特征行消歧
A = ("\tmsg.header.msg_id = CAPTURE_PHY_STREAM_OPEN_REQ;\n"
     "\tmsg.header.channel_id = R32_TEMP_CHANNEL_ID;\n")
n = src.count(A)
assert n == 1, "PHY_STREAM_OPEN 消息构造锚点命中 %d 次" % n

R = ('\t/*\n'
     '\t * r32-phyreset: 出厂 R32 固件可能期待 open 之前先显式复位 PHY。\n'
     '\t * 上游内核从不发这条(R35 的 RCE 自己管 PHY 上电/复位),但 R32 消息集里\n'
     '\t * 有它。这是软件侧最后一个没试过的方向 —— 配置全被接受却收不到数据,\n'
     '\t * 正对应"硬件没进入接收状态"。返回码本身就是信息:\n'
     '\t *   0  = 固件支持且执行了;  ≠0 = 固件不支持,等于排除这个方向。\n'
     '\t */\n'
     '\t{\n'
     '\t\tstruct CAPTURE_CONTROL_MSG rmsg;\n'
     '\t\tu32 rres;\n'
     '\n'
     '\t\tmemset(&rmsg, 0, sizeof(rmsg));\n'
     '\t\trmsg.header.msg_id = CAPTURE_PHY_STREAM_RESET_REQ;\n'
     '\t\trmsg.phy_stream_reset_req.stream_id = stream_id;\n'
     '\t\trmsg.phy_stream_reset_req.csi_port = csi_port;\n'
     '\t\trmsg.phy_stream_reset_req.phy_type = NVPHY_TYPE_CSI;\n'
     '\t\t(void)r32_csi_submit_wait(chan->csi->dev, &rmsg,\n'
     '\t\t\t\t\t  "PHY_RESET", &rres);\n'
     '\t}\n'
     '\n' + A)
src = src.replace(A, R, 1)

open(F, "w").write(src)
print("  ✅ csi5_fops.c: OPEN 之前追加 PHY_STREAM_RESET")
print("     r32-phyreset %d 处" % src.count("r32-phyreset"))
