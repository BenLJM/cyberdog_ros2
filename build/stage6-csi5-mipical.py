#!/usr/bin/env python3
"""Stage-6：把 csi5 的 MIPI 校准空桩换成真实现（零帧墙的真正元凶）。

2026-07-28 晚定位：
  传感器已确认在发（driver streaming=1 / i2c reg0x0100=0x01），VI/ISP 通道都建好，
  RCE 固件握手正常，但一帧都收不到。追进去发现 stage2 调的那次"校准"是空操作：

      int tegra_csi_mipi_calibrate(csi, on)          /* camera/csi/csi.c */
      {
          tegra_mipi_bias_pad_enable();
          list_for_each_entry(chan, &csi->csi_chans, list)
                  ret = csi->fops->mipical(chan);    ← csi5 的实现是……
      }

      static int csi5_mipi_cal(struct tegra_csi_channel *chan)
      {
              /* Camera RTCPU handles MIPI calibration */
              return 0;                              ← 空桩！
      }

  R35 把 MIPI 校准整个搬进了 RCE 固件，所以 csi5 这个钩子被掏空了；而狗跑的是
  **不做校准的 R32 固件**。于是 D-PHY 焊盘从来没被校准过 —— 传感器发得再好，
  接收端也锁不住信号，表现就是"NVCSI 零中断、VI 零帧"。
  日志里那个 `mipi calibrate(on) rc=0` 只是空桩的返回值，极具误导性。

  硬件侧是齐的：mipical@3990000 status=okay，驱动 tegra_mipi_cal 已绑定
  （实测 /sys/bus/platform/drivers/tegra_mipi_cal/3990000.mipical 存在）。

修法：照 csi4_mipi_cal（同族的 T186 实现，唯一真正干活的参考）补出 csi5 版：
  算 lane 掩码 → tegra_mipi_calibration(lanes)。
  本机 ov13b10：num_lanes=4、port-index=4(serial_e) ⇒ lanes=(CSIA|CSIB)<<4
                = CSIE|CSIF = 0x3000000。

⚠️ 不抄 csi4 的 CIL pad 寄存器写（csi5 没有 csi4_phy_write 那套 helper，
   且 T194 的 pad 配置已由 stage2 的 NVCSI prod settings 负责）。先只补校准本身，
   最小改动、可测量；不够再加。
⚠️ 与其余 r32 改动一样挂在同一个运行时门控后（默认关 ⇒ 对 good 路径零影响）。
"""
import re
import sys

F = ("/work/src/Linux_for_Tegra/source/public/kernel_src/kernel/nvidia/"
     "drivers/media/platform/tegra/camera/nvcsi/csi5_fops.c")

src = open(F).read()
if "r32-mipical" in src:
    print("FATAL: csi5_fops.c 已注入过 stage6")
    sys.exit(1)

# ---- 1. 换掉空桩 ----
A = ("static int csi5_mipi_cal(struct tegra_csi_channel *chan)\n"
     "{\n"
     "\t/* Camera RTCPU handles MIPI calibration */\n"
     "\treturn 0;\n"
     "}\n")
assert src.count(A) == 1, "空桩锚点命中 %d 次" % src.count(A)

R = '''static int csi5_mipi_cal(struct tegra_csi_channel *chan)
{
#if IS_ENABLED(CONFIG_TEGRA_CAPTURE_R32_ABI)
	/*
	 * r32-mipical: R35 把 MIPI 焊盘校准搬进了 RCE 固件，所以这个钩子在上游
	 * 是空的。狗跑的是不做校准的 R32 固件 —— 不在这里补，D-PHY 永远锁不住，
	 * 现象是 NVCSI 零中断 / VI 零帧（传感器其实在发）。
	 * 实现照 csi4_mipi_cal，只保留真正干活的那部分：lane 掩码 + 校准调用。
	 */
	unsigned int lanes = 0, num_ports = 0, csi_port, num_lanes;
	struct tegra_csi_device *csi = chan->csi;
	u32 phy_mode;
	bool is_cphy;

	if (!tegra_camrtc_r32_camera_power_enabled())
		return 0;	/* R35 固件自己会校准 */

	if (chan->pg_mode)
		return 0;	/* 测试图样不过 PHY */

	phy_mode = read_phy_mode_from_dt(chan);
	is_cphy = (phy_mode == CSI_PHY_MODE_CPHY);

	while (num_ports < chan->numports) {
		csi_port = chan->ports[num_ports].csi_port;
		num_lanes = chan->ports[num_ports].lanes;
		if (num_lanes == 0)
			num_lanes = chan->numlanes;

		if (num_lanes <= 2)
			lanes |= CSIA << csi_port;
		else
			lanes |= (CSIA | CSIB) << csi_port;
		num_ports++;
	}

	if (!lanes) {
		dev_err(csi->dev, "r32-mipical: no lane selected\\n");
		return -EINVAL;
	}

	lanes |= is_cphy ? CPHY_MASK : 0;
	dev_info(csi->dev, "r32-mipical: calibrating lanes=0x%x cphy=%d\\n",
		 lanes, is_cphy);

	return tegra_mipi_calibration(lanes);
#else
	/* Camera RTCPU handles MIPI calibration */
	return 0;
#endif
}
'''
src = src.replace(A, R, 1)

# ---- 2. include + 门控 extern（挂在最后一个 #include 之后）----
incs = re.findall(r"(?m)^#include .*$", src)
assert incs, "找不到 include"
last = incs[-1] + "\n"
DECL = last + ('\n#if IS_ENABLED(CONFIG_TEGRA_CAPTURE_R32_ABI)\n'
               '#include "mipical/mipi_cal.h"\n'
               '/* exported by tegra-camera-rtcpu.c (shared runtime gate) */\n'
               'bool tegra_camrtc_r32_camera_power_enabled(void);\n'
               '#endif\n')
assert src.count(last) >= 1
src = src.replace(last, DECL, 1)

open(F, "w").write(src)
print("  ✅ csi5_fops.c: csi5_mipi_cal 空桩 → 真实现")
print("     r32-mipical 出现 %d 处" % src.count("r32-mipical"))
