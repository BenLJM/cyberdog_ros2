#!/usr/bin/env python3
"""变体 H 注入器：csi5 stream 消息按 R32 语义发（零帧墙的最后一块）。

2026-07-28 定位（全部实测）：传感器在流出、MIPI 校准 rc=0、prod applied、
0x10 setup accepted —— 但 R35 的 csi5 stream 路径与 R32 有三处根本不同：
  1. R35 走 per-VI-channel 请求-应答(csi5_send_control_message 等回包)；
     **R32 是 tegra_capture_ivc_control_submit() 发射后不管**(TEMP_CHANNEL_ID=65)。
     R32 固件不回包 → R35 的 close 等回包必然报错，open/set_config 行为未定义。
  2. R35 填 nvcsi_error_config(11 字段+csimux)；**R32 布局是 9 字段 40B 且全零**
     → R32 固件按错位布局解析错误掩码 = 0725「静默乱掉」模式的 CSI 侧同款。
  3. CIL 数值语义：R32 硬编码 cil_clock_rate=204000、DPHY t_clk_settle=33、
     lp_bypass_mode=!discontinuous_clk —— 这些直接决定 PHY 锁不锁。

修法：门控(与电源契约同一个 r32_camera_power)下三个函数整体走 R32 忠实实现，
gate 关闭时 R35 路径一字不动。全部带 dev_info(内核没编 CONFIG_DYNAMIC_DEBUG，
dev_dbg 不可见——这也是至今看不到任何 csi5 诊断的原因)。
"""
import sys

F = ("/work/src/Linux_for_Tegra/source/public/kernel_src/kernel/nvidia/"
     "drivers/media/platform/tegra/camera/nvcsi/csi5_fops.c")

src = open(F).read()
if "r32-csi5" in src:
    print("FATAL: csi5 已注入过")
    sys.exit(1)


def rep(anchor, repl, name):
    global src
    n = src.count(anchor)
    assert n == 1, "锚点[%s]命中 %d 次" % (name, n)
    src = src.replace(anchor, repl, 1)


# ── ① 门控块：defines + 帮手 + 三个 R32 忠实实现 ──────────────────────────────
INC = "#include <media/fusa-capture/capture-vi.h>\n"
BLOCK = INC + r'''
#if IS_ENABLED(CONFIG_TEGRA_CAPTURE_R32_ABI)
/*
 * ---------------------------------------------------------------------------
 *  R32-faithful CSI5 stream control (gated; default off; see r32_camera_power)
 *
 *  The factory R32 RCE firmware expects the R32 contract for the NVCSI stream
 *  messages, which differs from R35 in three load-bearing ways:
 *    (1) transport: R32 submits over the raw control IVC with a temp channel
 *        id (fire-and-forget, tegra_capture_ivc_control_submit) -- the fw
 *        sends no response.  R35 instead round-trips through the VI channel
 *        and WAITS, which is why csi5_stream_close always logged an error.
 *    (2) CAPTURE_CSI_STREAM_SET_CONFIG payload tail: R32 nvcsi_error_config
 *        is 9xu32 (40B) and R32 left it ALL-ZERO; R35's 11xu32+csimux layout
 *        misparses from the second field on ("accepts then scrambles").
 *        Building the message R32-style zeroes that whole region.
 *    (3) CIL values: cil_clock_rate hard-coded 204000 (the field R35
 *        deprecated), DPHY t_clk_settle=33, lp_bypass_mode=!discontinuous_clk.
 * ---------------------------------------------------------------------------
 */
#define R32_TEMP_CHANNEL_ID	(64U + 1U)	/* NUM_CAPTURE_CHANNELS + 1, both gens */
#define R32_NVCSI_CIL_CLOCK_RATE	204000U

bool tegra_camrtc_r32_camera_power_enabled(void);

static u32 r32_read_discontinuous_clk(struct tegra_csi_channel *chan)
{
	struct camera_common_data *s_data = chan->s_data;
	u32 val = 1;

	if (s_data && s_data->mode_prop_idx < s_data->sensor_props.num_modes) {
		val = s_data->sensor_props.sensor_modes[s_data->mode_prop_idx]
			.signal_properties.discontinuous_clk;
	} else if (chan->of_node) {
		const char *str;

		if (!of_property_read_string(chan->of_node,
					     "discontinuous_clk", &str))
			val = !strncmp(str, "yes", sizeof("yes"));
	}
	return val;
}

static u64 r32_read_pixel_clk(struct tegra_csi_channel *chan)
{
	struct sensor_signal_properties *sig_props;
	u64 pix_clk = 0;

	if (chan && chan->s_data &&
	    chan->s_data->mode_prop_idx < chan->s_data->sensor_props.num_modes) {
		sig_props = &chan->s_data->sensor_props
			.sensor_modes[chan->s_data->mode_prop_idx]
			.signal_properties;
		if (sig_props->serdes_pixel_clock.val != 0ULL)
			pix_clk = sig_props->serdes_pixel_clock.val;
		else
			pix_clk = sig_props->pixel_clock.val;
	}
	return pix_clk;
}

static int csi5_stream_open_r32(struct tegra_csi_channel *chan, u32 stream_id,
	u32 csi_port)
{
	struct CAPTURE_CONTROL_MSG msg;
	int err;

	memset(&msg, 0, sizeof(msg));
	msg.header.msg_id = CAPTURE_PHY_STREAM_OPEN_REQ;
	msg.header.channel_id = R32_TEMP_CHANNEL_ID;
	msg.phy_stream_open_req.stream_id = stream_id;
	msg.phy_stream_open_req.csi_port = csi_port;

	err = tegra_capture_ivc_control_submit(&msg, sizeof(msg));
	dev_info(chan->csi->dev,
		 "r32-csi5: PHY_STREAM_OPEN stream=%u port=%u rc=%d\n",
		 stream_id, csi_port, err);
	return err;
}

static int csi5_stream_set_config_r32(struct tegra_csi_channel *chan,
	u32 stream_id, u32 csi_port, int csi_lanes)
{
	struct camera_common_data *s_data = chan->s_data;
	unsigned int cil_settletime = read_settle_time_from_dt(chan);
	u32 discontinuous_clk = r32_read_discontinuous_clk(chan);
	struct CAPTURE_CONTROL_MSG msg;
	struct nvcsi_brick_config brick_config;
	struct nvcsi_cil_config cil_config;
	bool is_cphy = (csi_lanes == 3);
	int err;

	/* Brick config -- R32 verbatim */
	memset(&brick_config, 0, sizeof(brick_config));
	brick_config.phy_mode = (!is_cphy) ?
		NVCSI_PHY_TYPE_DPHY : NVCSI_PHY_TYPE_CPHY;

	/* CIL config -- R32 verbatim (incl. the R35-deprecated clock field) */
	memset(&cil_config, 0, sizeof(cil_config));
	cil_config.num_lanes = csi_lanes;
	cil_config.lp_bypass_mode = is_cphy ? 0 : !discontinuous_clk;
	cil_config.t_clk_settle = is_cphy ? 1 : 33;
	cil_config.t_hs_settle = cil_settletime;
	cil_config.cil_clock_rate = R32_NVCSI_CIL_CLOCK_RATE;
	if (s_data && !chan->pg_mode)
		cil_config.mipi_clock_rate = r32_read_pixel_clk(chan) / 1000;
	else
		cil_config.mipi_clock_rate = chan->csi->clk_freq / 1000;

	/* R32 message: error_config stays ALL-ZERO via this memset */
	memset(&msg, 0, sizeof(msg));
	msg.header.msg_id = CAPTURE_CSI_STREAM_SET_CONFIG_REQ;
	msg.header.channel_id = R32_TEMP_CHANNEL_ID;
	msg.csi_stream_set_config_req.stream_id = stream_id;
	msg.csi_stream_set_config_req.csi_port = csi_port;
	msg.csi_stream_set_config_req.brick_config = brick_config;
	msg.csi_stream_set_config_req.cil_config = cil_config;

	err = tegra_capture_ivc_control_submit(&msg, sizeof(msg));
	dev_info(chan->csi->dev,
		 "r32-csi5: STREAM_SET_CONFIG stream=%u port=%u lanes=%d cphy=%d settle=%u lp_bypass=%u mipi=%ukHz rc=%d\n",
		 stream_id, csi_port, csi_lanes, is_cphy, cil_settletime,
		 cil_config.lp_bypass_mode, cil_config.mipi_clock_rate, err);
	return err;
}

static void csi5_stream_close_r32(struct tegra_csi_channel *chan, u32 stream_id,
	u32 csi_port)
{
	struct CAPTURE_CONTROL_MSG msg;
	int err;

	memset(&msg, 0, sizeof(msg));
	msg.header.msg_id = CAPTURE_PHY_STREAM_CLOSE_REQ;
	msg.header.channel_id = R32_TEMP_CHANNEL_ID;
	msg.phy_stream_close_req.stream_id = stream_id;
	msg.phy_stream_close_req.csi_port = csi_port;

	err = tegra_capture_ivc_control_submit(&msg, sizeof(msg));
	dev_info(chan->csi->dev,
		 "r32-csi5: PHY_STREAM_CLOSE stream=%u port=%u rc=%d\n",
		 stream_id, csi_port, err);
}
#endif /* CONFIG_TEGRA_CAPTURE_R32_ABI */
'''
rep(INC, BLOCK, "block")

# ── ② open 入口改道（放在声明区之后，避开 -Werror=declaration-after-statement）──
A = ('\tint vi_port = 0;\n'
     '\t/* If the tegra_vi_channel is NULL')
R = ('\tint vi_port = 0;\n'
     '#if IS_ENABLED(CONFIG_TEGRA_CAPTURE_R32_ABI)\n'
     '\tif (tegra_camrtc_r32_camera_power_enabled())\n'
     '\t\treturn csi5_stream_open_r32(chan, stream_id, csi_port);\n'
     '#endif\n'
     '\t/* If the tegra_vi_channel is NULL')
rep(A, R, "open-redirect")

# ── ③ set_config 入口改道（声明区之后）───────────────────────────────────────
A = ('\tbool is_cphy = (phy_mode == CSI_PHY_MODE_CPHY);\n'
     '\tdev_dbg(csi->dev, "%s: stream_id=%u, csi_port=%u\\n",\n'
     '\t\t__func__, stream_id, csi_port);\n')
R = ('\tbool is_cphy = (phy_mode == CSI_PHY_MODE_CPHY);\n'
     '\tdev_dbg(csi->dev, "%s: stream_id=%u, csi_port=%u\\n",\n'
     '\t\t__func__, stream_id, csi_port);\n'
     '#if IS_ENABLED(CONFIG_TEGRA_CAPTURE_R32_ABI)\n'
     '\tif (tegra_camrtc_r32_camera_power_enabled())\n'
     '\t\treturn csi5_stream_set_config_r32(chan, stream_id, csi_port,\n'
     '\t\t\t\t\t\t  csi_lanes);\n'
     '#endif\n')
rep(A, R, "setconfig-redirect")

# ── ④ close 入口改道（声明区之后；err=0+vi_port 序列是 close 独有）──────────
A = ('\tint err = 0;\n'
     '\tint vi_port = 0;\n'
     '\n'
     '\tstruct CAPTURE_CONTROL_MSG msg;\n')
R = ('\tint err = 0;\n'
     '\tint vi_port = 0;\n'
     '\n'
     '\tstruct CAPTURE_CONTROL_MSG msg;\n'
     '#if IS_ENABLED(CONFIG_TEGRA_CAPTURE_R32_ABI)\n'
     '\tif (tegra_camrtc_r32_camera_power_enabled()) {\n'
     '\t\tcsi5_stream_close_r32(chan, stream_id, csi_port);\n'
     '\t\treturn;\n'
     '\t}\n'
     '#endif\n')
rep(A, R, "close-redirect")

open(F, "w").write(src)
print("  ✅ csi5_fops.c (4 处)")
for k in ("r32-csi5", "csi5_stream_open_r32", "R32_TEMP_CHANNEL_ID"):
    print("     %-26s %d 处" % (k, src.count(k)))
