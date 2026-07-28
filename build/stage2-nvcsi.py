#!/usr/bin/env python3
"""Stage-2 回移注入器：nvcsi prod settings + MIPI 校准（R32 契约的数据面那半）。

与 gate-rtcpu.py 同一套方法论：精确字符串锚定 + 断言命中次数，命中不对整体失败。
必须在 gate-rtcpu.py **之后**运行（getter 锚在它注入的文本上）。

为什么需要 Stage-2（2026-07-28 取证钉死）：
  控制面已全通（0x10 setup accepted、RCE vi5_hwinit 都跑了、传感器 I2C 应答），
  但零帧。R35 的 DTB 把 mipical@3990000 设成 disabled、nvcsi 不再做 prod/校准 ——
  因为 R35 固件自己干这些；而 R32 固件等着内核干。MIPI pad 从未校准 → PHY 收不到。
R32 原文：nvcsi-t194.c 的 nvcsi_apply_prod / nvcsi_prod_apply_thread /
  tegra194_nvcsi_finalize_poweron（rtcpu 未上电则 kthread 轮询 125ms —— 因为
  “rtcpu poweron 时会复位 nvcsi 寄存器，prod 必须在那之后写”）。
"""
import sys

BASE = "/work/src/Linux_for_Tegra/source/public/kernel_src/kernel/nvidia"
RTC = BASE + "/drivers/platform/tegra/tegra-camera-rtcpu.c"
NVC = BASE + "/drivers/video/tegra/host/nvcsi/nvcsi-t194.c"
NVH = BASE + "/drivers/video/tegra/host/nvcsi/nvcsi-t194.h"
T194 = BASE + "/drivers/video/tegra/host/t194/t194.c"


def patch(path, pairs):
    src = open(path).read()
    for anchor, repl, name in pairs:
        n = src.count(anchor)
        assert n == 1, "%s: 锚点[%s]命中 %d 次" % (path, name, n)
        src = src.replace(anchor, repl, 1)
    open(path, "w").write(src)
    print("  ✅ %s (%d 处)" % (path.split("/")[-1], len(pairs)))


# ── ① rtcpu：共享门控的 getter（锚在 gate-rtcpu.py 注入的文本上）──────────────
A = ('MODULE_PARM_DESC(r32_camera_power,\n'
     '\t"Apply R32 camera power contract (isp/vi/nvcsi busy+reset). Default off.");\n'
     '#endif')
R = ('MODULE_PARM_DESC(r32_camera_power,\n'
     '\t"Apply R32 camera power contract (isp/vi/nvcsi busy+reset). Default off.");\n'
     '\n'
     '/* Stage-2 (nvcsi prod + MIPI cal) shares this gate -- see nvcsi-t194.c. */\n'
     'bool tegra_camrtc_r32_camera_power_enabled(void)\n'
     '{\n'
     '\treturn r32_camera_power;\n'
     '}\n'
     'EXPORT_SYMBOL(tegra_camrtc_r32_camera_power_enabled);\n'
     '#endif')
patch(RTC, [(A, R, "getter")])

# ── ② nvcsi-t194.h：补回 R35 删掉的声明（t194.c 要用）────────────────────────
hdr = open(NVH).read()
assert "tegra194_nvcsi_finalize_poweron" not in hdr, "头文件已注入过"
assert hdr.rstrip().endswith("#endif"), "头文件结尾不是 #endif"
idx = hdr.rstrip().rfind("#endif")
hdr = hdr[:idx] + (
    "#if IS_ENABLED(CONFIG_TEGRA_CAPTURE_R32_ABI)\n"
    "/* R32 Stage-2: restored from R32.7; gated at runtime inside the functions. */\n"
    "int tegra194_nvcsi_finalize_poweron(struct platform_device *pdev);\n"
    "int tegra194_nvcsi_prepare_poweroff(struct platform_device *pdev);\n"
    "#endif\n\n") + hdr[idx:]
open(NVH, "w").write(hdr)
print("  ✅ nvcsi-t194.h (декl)")

# ── ③ nvcsi-t194.c：includes / struct / 机器 / probe ─────────────────────────
INC_A = "#include <media/tegra_camera_platform.h>\n"
INC_R = INC_A + (
    "#if IS_ENABLED(CONFIG_TEGRA_CAPTURE_R32_ABI)\n"
    "#include <linux/tegra_prod.h>\n"
    "#include <linux/delay.h>\n"
    "#include <media/csi.h>\n"
    "/* exported by tegra-camera-rtcpu.c */\n"
    "bool tegra_camrtc_r32_camera_power_enabled(void);\n"
    "bool tegra_camrtc_is_rtcpu_powered(void);\n"
    "#endif\n")

ST_A = "\tstruct platform_device *pdev;\n\tstruct tegra_csi_device csi;\n\tstruct dentry *dir;\n};"
ST_R = ("\tstruct platform_device *pdev;\n"
        "\tstruct tegra_csi_device csi;\n"
        "\tstruct dentry *dir;\n"
        "#if IS_ENABLED(CONFIG_TEGRA_CAPTURE_R32_ABI)\n"
        "\t/* R32 Stage-2 state (prod + MIPI cal), see finalize_poweron below. */\n"
        "\tvoid __iomem *io;\n"
        "\tstruct tegra_prod *prod_list;\n"
        "\tatomic_t on;\n"
        "#endif\n"
        "};")

FN_A = "static const struct of_device_id tegra194_nvcsi_of_match[] = {"
FN_R = r'''#if IS_ENABLED(CONFIG_TEGRA_CAPTURE_R32_ABI)
/*
 * ---------------------------------------------------------------------------
 *  R32 Stage-2: NVCSI prod settings + MIPI pad calibration, restored from
 *  R32.7 nvcsi-t194.c and gated behind the SAME runtime switch as the power
 *  contract (r32_camera_power, default off -> zero boot-time behavior change).
 *
 *  WHY: with the R35 DTB, mipical@3990000 is disabled and nobody calibrates
 *  the MIPI pads or applies NVCSI prod settings -- the R35 RCE firmware does
 *  all that itself.  The factory R32 firmware does NOT: it expects the kernel
 *  to have done both.  Result observed on 2026-07-28: control plane fully up
 *  (0x10 setup accepted, RCE vi5_hwinit, sensor answering on I2C) but ZERO
 *  frames -- the PHY never locks on uncalibrated pads.
 *
 *  R32 ordering contract (comment preserved from R32 source): "rtcpu resets
 *  nvcsi registers, so we set prod settings after rtcpu has finished
 *  resetting the registers, which happens during rtcpu's poweron call" --
 *  hence the 125 ms polling kthread when the RCE is not yet powered.
 * ---------------------------------------------------------------------------
 */
static void nvcsi_apply_prod(struct platform_device *pdev)
{
	int err = -ENODEV;
	struct nvhost_device_data *pdata = platform_get_drvdata(pdev);
	struct t194_nvcsi *nvcsi = pdata->private_data;
	struct tegra_csi_channel *chan;
	u32 phy_mode;
	bool is_cphy;

	if (!nvcsi->io || !nvcsi->prod_list) {
		dev_info(&pdev->dev,
			 "r32-stage2: prod skipped (io=%d prod_list=%d)\n",
			 !!nvcsi->io, !!nvcsi->prod_list);
		return;
	}

	if (!list_empty(&nvcsi->csi.csi_chans)) {
		chan = list_first_entry(&nvcsi->csi.csi_chans,
				struct tegra_csi_channel, list);
		phy_mode = read_phy_mode_from_dt(chan);
		is_cphy = (phy_mode == CSI_PHY_MODE_CPHY);

		err = tegra_prod_set_by_name(&nvcsi->io, "prod",
					     nvcsi->prod_list);
		if (err)
			dev_err(&pdev->dev,
				"r32-stage2: prod set fail (err=%d)\n", err);
		err = tegra_prod_set_by_name(&nvcsi->io,
				is_cphy ? "prod_c_cphy_mode" : "prod_c_dphy_mode",
				nvcsi->prod_list);
		if (err)
			dev_err(&pdev->dev,
				"r32-stage2: prod mode set fail (err=%d)\n", err);
		dev_info(&pdev->dev, "r32-stage2: prod applied (cphy=%d)\n",
			 is_cphy);
	}
}

static int nvcsi_prod_apply_thread(void *data)
{
	struct platform_device *pdev = data;
	struct nvhost_device_data *pdata = platform_get_drvdata(pdev);
	struct t194_nvcsi *nvcsi = pdata->private_data;
	int rc;

	/* R32: rtcpu finishes poweron ~120ms after nvcsi_finalize_poweron */
	while (!tegra_camrtc_is_rtcpu_powered())
		usleep_range(1000*125, 1000*126);

	nvcsi_apply_prod(pdev);
	rc = tegra_csi_mipi_calibrate(&nvcsi->csi, true);
	dev_info(&pdev->dev, "r32-stage2: mipi calibrate(on) rc=%d [thread]\n", rc);
	atomic_set(&nvcsi->on, 1);
	return 0;
}

int tegra194_nvcsi_finalize_poweron(struct platform_device *pdev)
{
	struct nvhost_device_data *pdata = platform_get_drvdata(pdev);
	struct t194_nvcsi *nvcsi = pdata->private_data;
	int rc;

	if (!tegra_camrtc_r32_camera_power_enabled())
		return 0;
	if (atomic_read(&nvcsi->on) == 1)
		return 0;

	if (!tegra_camrtc_is_rtcpu_powered()) {
		kthread_run(nvcsi_prod_apply_thread, pdev, "nvcsi-t194-prod");
	} else {
		nvcsi_apply_prod(pdev);
		rc = tegra_csi_mipi_calibrate(&nvcsi->csi, true);
		dev_info(&pdev->dev,
			 "r32-stage2: mipi calibrate(on) rc=%d [direct]\n", rc);
		atomic_set(&nvcsi->on, 1);
	}
	return 0;
}
EXPORT_SYMBOL_GPL(tegra194_nvcsi_finalize_poweron);

int tegra194_nvcsi_prepare_poweroff(struct platform_device *pdev)
{
	struct nvhost_device_data *pdata = platform_get_drvdata(pdev);
	struct t194_nvcsi *nvcsi = pdata->private_data;
	int err;

	if (!tegra_camrtc_r32_camera_power_enabled())
		return 0;
	if (atomic_read(&nvcsi->on) == 0)
		return 0;

	err = tegra_csi_mipi_calibrate(&nvcsi->csi, false);
	if (err) {
		dev_err(&pdev->dev, "r32-stage2: calibration off failed\n");
		return err;
	}
	atomic_set(&nvcsi->on, 0);
	return 0;
}
EXPORT_SYMBOL_GPL(tegra194_nvcsi_prepare_poweroff);
#endif /* CONFIG_TEGRA_CAPTURE_R32_ABI */

static const struct of_device_id tegra194_nvcsi_of_match[] = {'''

PR_A = "\tpdata = platform_get_drvdata(pdev);\n\n\tnvcsi = pdata->private_data;\n"
PR_R = ("\tpdata = platform_get_drvdata(pdev);\n"
        "\n"
        "\tnvcsi = pdata->private_data;\n"
        "\n"
        "#if IS_ENABLED(CONFIG_TEGRA_CAPTURE_R32_ABI)\n"
        "\t{\n"
        "\t\t/* R32 Stage-2 plumbing: MMIO for prod (needs the DT reg we\n"
        "\t\t * restored) + the prod table.  Both OPTIONAL -- missing bits\n"
        "\t\t * degrade to \"prod skipped\", never to probe failure. */\n"
        "\t\tstruct resource *mem =\n"
        "\t\t\tplatform_get_resource(pdev, IORESOURCE_MEM, 0);\n"
        "\t\tif (mem) {\n"
        "\t\t\tnvcsi->io = devm_ioremap(&pdev->dev, mem->start,\n"
        "\t\t\t\t\t\t resource_size(mem));\n"
        "\t\t\tif (!nvcsi->io)\n"
        "\t\t\t\tdev_warn(&pdev->dev,\n"
        "\t\t\t\t\t \"r32-stage2: ioremap failed\\n\");\n"
        "\t\t} else {\n"
        "\t\t\tdev_info(&pdev->dev,\n"
        "\t\t\t\t \"r32-stage2: no reg in DT, prod disabled\\n\");\n"
        "\t\t}\n"
        "\t\tnvcsi->prod_list = devm_tegra_prod_get(&pdev->dev);\n"
        "\t\tif (IS_ERR(nvcsi->prod_list)) {\n"
        "\t\t\tdev_info(&pdev->dev,\n"
        "\t\t\t\t \"r32-stage2: no prod list (%ld)\\n\",\n"
        "\t\t\t\t PTR_ERR(nvcsi->prod_list));\n"
        "\t\t\tnvcsi->prod_list = NULL;\n"
        "\t\t}\n"
        "\t\tatomic_set(&nvcsi->on, 0);\n"
        "\t}\n"
        "#endif\n")

patch(NVC, [(INC_A, INC_R, "includes"),
            (ST_A, ST_R, "struct"),
            (FN_A, FN_R, "machinery"),
            (PR_A, PR_R, "probe")])

# ── ④ t194.c：把回调接回 t19_nvcsi_info ─────────────────────────────────────
T_A = ('\t.devfs_name\t\t= "nvcsi",\n'
       '\t.autosuspend_delay      = 500,\n'
       '\t.can_powergate = true,\n'
       '};')
T_R = ('\t.devfs_name\t\t= "nvcsi",\n'
       '\t.autosuspend_delay      = 500,\n'
       '\t.can_powergate = true,\n'
       '#if IS_ENABLED(CONFIG_TEGRA_CAPTURE_R32_ABI)\n'
       '\t/* R32 Stage-2: prod + MIPI cal on power-on.  Gated at RUNTIME inside\n'
       '\t * the callbacks (r32_camera_power, default off) -> boot unaffected. */\n'
       '\t.finalize_poweron\t= tegra194_nvcsi_finalize_poweron,\n'
       '\t.prepare_poweroff\t= tegra194_nvcsi_prepare_poweroff,\n'
       '#endif\n'
       '};')
patch(T194, [(T_A, T_R, "t19_nvcsi_info")])

# t194.c 能看到声明吗（include nvcsi-t194.h?）
t = open(T194).read()
if 'nvcsi/nvcsi-t194.h"' not in t:
    inc_a = '#include "t194.h"\n'
    n = t.count(inc_a)
    assert n == 1, "t194.h include 锚点命中 %d" % n
    t = t.replace(inc_a, inc_a + '#include "nvcsi/nvcsi-t194.h"\n', 1)
    open(T194, "w").write(t)
    print("  ✅ t194.c (+include nvcsi-t194.h)")

print("stage2 注入完成")
