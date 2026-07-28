#!/usr/bin/env python3
"""Stage-16：CSI 配置消息改成【正规申请 trans_id + 等应答 + 查返回码】。

到目前为止最大的未验证假设：stage3 的三条 CSI 消息是 **fire-and-forget** ——
日志里的 `rc=264` 只是 IVC 写入的字节数，**从没验证 RCE 是否收到并执行了**。

更要命的是 stage3 把 `channel_id` 硬编码成 `R32_TEMP_CHANNEL_ID = 64+1 = 65`。
而 capture-ivc 的路由约定是：客户端必须先调
`tegra_capture_ivc_register_control_cb(cb, &trans_id, priv)` **申请**一个
trans_id（范围 `[NUM_CAPTURE_CHANNELS, TOTAL_CHANNELS)`），RCE 的应答才会被
路由到自己的回调。硬编码 65 意味着：
  · RCE 的应答落到 65 号槽 —— 那里没有我们的回调，应答被丢；
  · 更糟的情况是 65 号槽正被别的客户端占着，我们把人家的应答流搅了。

本 stage 把三条消息（PHY_STREAM_OPEN / STREAM_SET_CONFIG / PHY_STREAM_CLOSE）
统一改走一个 helper：
    register_control_cb → 拿真 trans_id → 填进 header → submit
    → 等 completion（250ms）→ 打印 result → unregister
拿不到 trans_id 时**退回原来的 fire-and-forget**，保证不比现状差。

这样才能回答：**RCE 到底有没有接受我们的 CSI 配置。**
"""
import re
import sys

F = ("/work/src/Linux_for_Tegra/source/public/kernel_src/kernel/nvidia/"
     "drivers/media/platform/tegra/camera/nvcsi/csi5_fops.c")

src = open(F).read()
if "r32-resp" in src:
    print("FATAL: 已注入过 stage16")
    sys.exit(1)
assert "R32_TEMP_CHANNEL_ID" in src, "必须在 stage3 之后运行"

# ---- 1. helper：申请 trans_id、提交、等应答 ----
A = "#define R32_TEMP_CHANNEL_ID"
i = src.index(A)
line_end = src.index("\n", i) + 1
HELPER = '''
/*
 * r32-resp: 正规的"申请 trans_id → 提交 → 等应答"。
 *
 * stage3 原来直接 submit 且把 channel_id 硬编码成 R32_TEMP_CHANNEL_ID，
 * 属于 fire-and-forget：rc 只是 IVC 写入字节数，RCE 有没有接受完全不知道，
 * 而且 65 号槽没有我们的回调，应答被丢（甚至可能串到别的客户端）。
 */
struct r32_csi_waiter {
	struct completion done;
	struct CAPTURE_CONTROL_MSG resp;
};

static void r32_csi_resp_cb(const void *resp_desc, const void *priv_context)
{
	struct r32_csi_waiter *w = (struct r32_csi_waiter *)priv_context;

	if (w == NULL || resp_desc == NULL)
		return;
	memcpy(&w->resp, resp_desc, sizeof(w->resp));
	complete(&w->done);
}

/* 返回 IVC 提交的返回值；*result 为 RCE 的 result（拿不到时置 U32_MAX） */
static int r32_csi_submit_wait(struct device *dev,
			       struct CAPTURE_CONTROL_MSG *msg,
			       const char *what, u32 *result)
{
	struct r32_csi_waiter w;
	u32 trans_id = 0;
	int err, reg;

	*result = U32_MAX;
	init_completion(&w.done);
	memset(&w.resp, 0, sizeof(w.resp));

	reg = tegra_capture_ivc_register_control_cb(r32_csi_resp_cb,
						   &trans_id, &w);
	if (reg != 0) {
		/* 拿不到 trans_id：退回原行为，绝不比现状差 */
		dev_warn(dev, "r32-resp: %s 申请 trans_id 失败(%d)，退回 fire-and-forget\\n",
			 what, reg);
		msg->header.channel_id = R32_TEMP_CHANNEL_ID;
		return tegra_capture_ivc_control_submit(msg, sizeof(*msg));
	}

	msg->header.channel_id = trans_id;
	err = tegra_capture_ivc_control_submit(msg, sizeof(*msg));
	if (err >= 0) {
		if (wait_for_completion_timeout(&w.done,
						msecs_to_jiffies(250)) == 0) {
			dev_warn(dev, "r32-resp: %s 超时 —— RCE 没回应答(trans_id=%u)\\n",
				 what, trans_id);
		} else {
			*result = w.resp.phy_stream_open_resp.result;
			dev_info(dev, "r32-resp: %s result=%u (0=OK) trans_id=%u\\n",
				 what, *result, trans_id);
		}
	}
	(void)tegra_capture_ivc_unregister_control_cb(trans_id);
	return err;
}
'''
src = src[:line_end] + HELPER + src[line_end:]

# ---- 2. 三处 submit 改走 helper ----
subs = [
    ('\terr = tegra_capture_ivc_control_submit(&msg, sizeof(msg));\n'
     '\tdev_info(chan->csi->dev,\n'
     '\t\t "r32-csi5: STREAM_SET_CONFIG',
     '\t{\n\t\tu32 r32_res;\n\n\t\terr = r32_csi_submit_wait(chan->csi->dev, &msg,\n'
     '\t\t\t\t\t "STREAM_SET_CONFIG", &r32_res);\n\t}\n'
     '\tdev_info(chan->csi->dev,\n'
     '\t\t "r32-csi5: STREAM_SET_CONFIG', "SET_CONFIG"),
]
for a, b, name in subs:
    n = src.count(a)
    assert n == 1, "%s 锚点命中 %d 次" % (name, n)
    src = src.replace(a, b, 1)

# 其余两处（OPEN / CLOSE）统一按模式替换
pat = re.compile(r"\terr = tegra_capture_ivc_control_submit\(&msg, sizeof\(msg\)\);\n")
rest = pat.findall(src)
assert len(rest) >= 1, "找不到剩余的 submit"
src = pat.sub('\t{\n\t\tu32 r32_res;\n\n'
              '\t\terr = r32_csi_submit_wait(chan->csi->dev, &msg,\n'
              '\t\t\t\t\t "PHY_STREAM", &r32_res);\n\t}\n', src)

# ---- 3. include ----
incs = re.findall(r"(?m)^#include .*$", src)
last = incs[-1] + "\n"
src = src.replace(last, last + "#include <linux/completion.h>\n", 1)

open(F, "w").write(src)
print("  ✅ csi5_fops.c: CSI 消息改为申请 trans_id + 等应答")
print("     r32-resp %d 处 / submit_wait %d 处"
      % (src.count("r32-resp"), src.count("r32_csi_submit_wait")))
