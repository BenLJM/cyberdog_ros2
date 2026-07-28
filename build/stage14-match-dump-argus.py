#!/usr/bin/env python3
"""Stage-14：在【argus 真正走的那条路】上打印 VI 通道的包匹配条件。

stage13 挂在 vi5_fops.c 的 vi5_setup_surface 上 —— 实测 `r32-vi5` 计数为 0，
说明 **stage4/13 在 argus 路径下也是死代码**（`vi5_setup_surface` 属于 v4l2 路径；
argus 是自己在用户态填整个描述符的）。这已经是本工程第三次踩「改了没被走到的
路径」：stage3(csi5 消息)、stage8(R35 版 set_config)、stage4(内联 IOVA)。

argus 路径实际会走的是 fusa-capture 的 `vi_capture_request()`（ftrace 实测调用
9 次，且 stage5 的 `r32-sync` 日志确实出现过）。这里就挂在那儿，直接从请求缓冲区
里把描述符读出来。

要看的量：
    match.datatype / datatype_mask   —— RAW10 应为 0x2B
    match.stream   / stream_mask     —— ov13b10 走 serial_e ⇒ 应为 4
    match.vc       / vc_mask         —— 应为 0
只要有一项对不上传感器实际发的包，RCE 就会静默丢掉全部帧 —— 与实测
「配置全对、通道全建、零帧零错误」完全吻合。

⚠️ 只读，不改描述符；dev_info_once，不进热路径打印。
"""
import sys

F = ("/work/src/Linux_for_Tegra/source/public/kernel_src/kernel/nvidia/"
     "drivers/media/platform/tegra/camera/fusa-capture/capture-vi.c")

src = open(F).read()
if "r32-match" in src:
    print("FATAL: 已注入过 stage14")
    sys.exit(1)
assert "r32-sync" in src, "必须在 stage5 之后运行（复用它的锚点区）"

A = ("\tmemset(&capture_desc, 0, sizeof(capture_desc));\n"
     "\tcapture_desc.header.msg_id = CAPTURE_REQUEST_REQ;\n")
n = src.count(A)
assert n == 1, "vi_capture_request 锚点命中 %d 次" % n

R = ('''#if IS_ENABLED(CONFIG_TEGRA_CAPTURE_R32_ABI)
	/*
	 * r32-match: argus 在用户态填好的包匹配条件。发射侧已逐寄存器验证正确
	 * (chip_id=0x560D / 4208x3120 / HTS 与 DT 一致 / mode_select=0x01) 而仍
	 * 零帧零错误 —— 只要 stream/vc/datatype 有一项对不上传感器实际发的包，
	 * RCE 就会把帧全部丢掉，现象与实测完全吻合。
	 * 期望: stream=4(serial_e) vc=0 datatype=0x2B(RAW10)。
	 */
	if (tegra_camrtc_r32_camera_power_enabled() &&
	    capture->requests.va != NULL && capture->request_size != 0U) {
		const struct capture_descriptor *d =
			(const struct capture_descriptor *)
			((const u8 *)capture->requests.va +
			 (size_t)req->buffer_index * capture->request_size);

		dev_info_once(chan->dev,
			"r32-match: dt=0x%02x/0x%02x stream=%u/0x%02x vc=%u/0x%04x flags=0x%08x\\n",
			d->ch_cfg.match.datatype, d->ch_cfg.match.datatype_mask,
			d->ch_cfg.match.stream, d->ch_cfg.match.stream_mask,
			d->ch_cfg.match.vc, d->ch_cfg.match.vc_mask,
			*(const u32 *)&d->ch_cfg);
	}
#endif

''' + A)
src = src.replace(A, R, 1)

open(F, "w").write(src)
print("  ✅ capture-vi.c: 在 vi_capture_request 里打印 ch_cfg.match")
print("     r32-match %d 处" % src.count("r32-match"))
