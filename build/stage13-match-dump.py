#!/usr/bin/env python3
"""Stage-13：把 VI 通道的包匹配条件(ch_cfg.match)打出来。

到变体 P 为止，发射侧已【彻底验证通过】（I2C 直读：chip_id=0x560D、
X_OUT=4208、Y_OUT=3120、HTS×4=4704 与 DT 一致、mode_select=0x01），
RCE 的 trace 解码也验证正常（未知类型事件 0 个 ⇒ 「三计数全 0」是真的，
RCE 确实没观察到任何 VI 活动）。⇒ 问题在接收侧。

接收侧还剩一个没测过的关键量：**VI 通道拿什么条件去筛 CSI 包**。
`struct vi_channel_config` 里的：

    match.datatype / datatype_mask   —— CSI 数据类型（RAW10 应为 0x2B）
    match.stream   / stream_mask     —— CSI 流号（ov13b10 走 serial_e ⇒ 应为 4）
    match.vc       / vc_mask         —— 虚拟通道（应为 0）

这些由 **argus 填**（R32 用户态），内核只是传声筒。只要有一项对不上传感器实际
发出来的包，RCE 就会把帧全部丢掉 —— 现象正是「配置全对、通道全建、零帧零错误」。

挂点选 stage4 已有的那条 `dev_info_once`（描述符填写路径，冷路径、每次采集只打
一次）——**刻意避开 poweron/握手这类被计时的路径**，stage12 就是栽在那儿的
（`debugfs_create_file` 挂在 finalize_poweron 里，拖慢后让 RCE 消息超时）。
"""
import sys

F = ("/work/src/Linux_for_Tegra/source/public/kernel_src/kernel/nvidia/"
     "drivers/media/platform/tegra/camera/vi/vi5_fops.c")

src = open(F).read()
if "r32-match" in src:
    print("FATAL: 已注入过 stage13")
    sys.exit(1)
assert "r32-vi5" in src, "必须在 stage4 之后运行"

A = ('\t\tdev_info_once(chan->vi->dev,\n'
     '\t\t\t      "r32-vi5: inline surface IOVA active (%pad)\\n",\n'
     '\t\t\t      &offset);\n')
n = src.count(A)
assert n == 1, "stage4 的 dev_info_once 锚点命中 %d 次" % n

R = ('\t\tdev_info_once(chan->vi->dev,\n'
     '\t\t\t      "r32-vi5: inline surface IOVA active (%pad)\\n",\n'
     '\t\t\t      &offset);\n'
     '\t\t/*\n'
     '\t\t * r32-match: argus 填的包匹配条件。发射侧已逐寄存器验证正确而仍零帧，\n'
     '\t\t * 只要 stream/vc/datatype 有一项对不上传感器实际发的包，RCE 就会\n'
     '\t\t * 静默丢掉全部帧 —— 现象与实测完全一致。ov13b10 走 serial_e ⇒\n'
     '\t\t * 期望 stream=4、vc=0、datatype=0x2B(RAW10)。\n'
     '\t\t */\n'
     '\t\tdev_info_once(chan->vi->dev,\n'
     '\t\t\t      "r32-match: dt=0x%02x/0x%02x stream=%u/0x%02x vc=%u/0x%04x\\n",\n'
     '\t\t\t      desc->ch_cfg.match.datatype,\n'
     '\t\t\t      desc->ch_cfg.match.datatype_mask,\n'
     '\t\t\t      desc->ch_cfg.match.stream,\n'
     '\t\t\t      desc->ch_cfg.match.stream_mask,\n'
     '\t\t\t      desc->ch_cfg.match.vc,\n'
     '\t\t\t      desc->ch_cfg.match.vc_mask);\n')
src = src.replace(A, R, 1)

open(F, "w").write(src)
print("  ✅ vi5_fops.c: 打印 ch_cfg.match（stream/vc/datatype）")
print("     r32-match %d 处" % src.count("r32-match"))
