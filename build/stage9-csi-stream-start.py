#!/usr/bin/env python3
"""Stage-9：argus 路径下由内核主动把 CSI 流开起来（R32 固件的硬性期待）。

2026-07-29 结构对比得出的缺口：

  R32 capture_channel_config          R35 capture_channel_config
  ─────────────────────────           ──────────────────────────
  channel_flags                       channel_flags
  channel_id                          channel_id
  vi_channel_mask        @8           vi_unit_id + __pad      @8
  requests               @16          vi_channel_mask         @16
  ...                                 vi2_channel_mask        @24
                                      **csi_stream_config csi_stream**  ← R35 新增
                                      requests / requests_memoryinfo

  R35 把 CSI 流配置塞进了通道建立消息，RCE 据此配 NVCSI。
  **R32 没有这个字段** —— R32 时代 NVCSI 由内核经独立的 IVC 消息配置
  （R32 消息头里确实有 CAPTURE_CSI_STREAM_SET_CONFIG 等）。

  而实测（ftrace）：argus 取流全程只走 vi_capture_*，**csi5_* 调用次数为 0** ——
  我们的 R35 内核在 argus 路径下从不发那些 CSI 消息，R32 argus 又假定别人已经
  配好了 ⇒ NVCSI 从头到尾没被配置过，传感器发得再好也收不到。

修法：门控下，在 NVCSI 上电并完成 prod + 校准之后，主动对每个绑定了传感器的
CSI 通道调 tegra_csi_start_streaming()（内核现成的导出函数，内部走
csi5_fops → csi5_stream_set_config/open，而那两个已由 stage3 改成 R32 语义）。

⚠️ 时机取 nvcsi_finalize_poweron 之后，与 stage2 的 prod/校准同一处 —— 这是本树
   里唯一能拿到 nvcsi->csi 通道链表且确定在采集之前的点。
⚠️ 只对 s_data 非空（真的绑了传感器）且非 pg_mode 的通道动手。
"""
import sys

F = ("/work/src/Linux_for_Tegra/source/public/kernel_src/kernel/nvidia/"
     "drivers/video/tegra/host/nvcsi/nvcsi-t194.c")

src = open(F).read()
if "r32-csistart" in src:
    print("FATAL: nvcsi-t194.c 已注入过 stage9")
    sys.exit(1)
assert "r32-stage2" in src, "必须在 stage2 之后运行"

# ---- 1. 加辅助函数（挂在 nvcsi_prod_apply_thread 之前）----
A = "static int nvcsi_prod_apply_thread(void *data)\n"
assert src.count(A) == 1, "stage2 的线程函数锚点命中 %d 次" % src.count(A)

HELPER = '''/*
 * r32-csistart: R32 固件期待 NVCSI 由内核经 IVC 消息配置好（R35 改成把 CSI 配置
 * 塞进 CAPTURE_CHANNEL_SETUP 让 RCE 自己配，所以 argus 路径下内核的 csi5 从不
 * 被调用 —— 实测 csi5_* 调用次数为 0）。这里补上：对每个真的绑了传感器的 CSI
 * 通道走一遍 tegra_csi_start_streaming()，内部经 csi5_fops 发出 R32 语义的
 * stream open / set_config（stage3 已改好）。
 */
static void nvcsi_r32_start_streams(struct platform_device *pdev)
{
	struct nvhost_device_data *pdata = platform_get_drvdata(pdev);
	struct t194_nvcsi *nvcsi = pdata->private_data;
	struct tegra_csi_channel *chan;
	unsigned int i;
	int rc;

	list_for_each_entry(chan, &nvcsi->csi.csi_chans, list) {
		if (chan->pg_mode != 0U || chan->s_data == NULL)
			continue;
		for (i = 0; i < chan->numports; i++) {
			rc = tegra_csi_start_streaming(chan, (int)i);
			dev_info(&pdev->dev,
				 "r32-csistart: port_idx=%u csi_port=%u rc=%d\\n",
				 i, chan->ports[i].csi_port, rc);
		}
	}
}

''' + A
src = src.replace(A, HELPER, 1)

# ---- 2. 两条校准路径之后各调一次 ----
pairs = [
    ('\trc = tegra_csi_mipi_calibrate(&nvcsi->csi, true);\n'
     '\tdev_info(&pdev->dev, "r32-stage2: mipi calibrate(on) rc=%d [thread]\\n", rc);\n',
     '\trc = tegra_csi_mipi_calibrate(&nvcsi->csi, true);\n'
     '\tdev_info(&pdev->dev, "r32-stage2: mipi calibrate(on) rc=%d [thread]\\n", rc);\n'
     '\tnvcsi_r32_start_streams(pdev);\n', "thread"),
    ('\t\trc = tegra_csi_mipi_calibrate(&nvcsi->csi, true);\n'
     '\t\tdev_info(&pdev->dev,\n'
     '\t\t\t "r32-stage2: mipi calibrate(on) rc=%d [direct]\\n", rc);\n',
     '\t\trc = tegra_csi_mipi_calibrate(&nvcsi->csi, true);\n'
     '\t\tdev_info(&pdev->dev,\n'
     '\t\t\t "r32-stage2: mipi calibrate(on) rc=%d [direct]\\n", rc);\n'
     '\t\tnvcsi_r32_start_streams(pdev);\n', "direct"),
]
for a, b, name in pairs:
    n = src.count(a)
    assert n == 1, "%s 路径锚点命中 %d 次" % (name, n)
    src = src.replace(a, b, 1)

open(F, "w").write(src)
print("  ✅ nvcsi-t194.c: 校准后主动开 CSI 流")
print("     r32-csistart %d 处" % src.count("r32-csistart"))
