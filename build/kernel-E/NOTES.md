# Kernel E batch — build report + deployment instructions

**2026-07-26** · builder: task F · **NOT DEPLOYED, NOT REBOOTED** (both forbidden for this task)

Artifacts: `build/kernel-E/out/`
Build log: `build/kernel-E/out/full-build.log`
Tree state at build time: `build/kernel-E/out/TREE-STATE-PREBUILD.txt`
DTB diff vs the running DTB: `build/kernel-E/out/DTB-DIFF-vs-deployed.txt`

```
KREL      5.10.216-tegra          (identical to what is running — no module dir rename)
Image     34155008 B  sha256 8f7838d6a96805a430388961e50c2473858c24f6194ff70506213d389f38fe3d
DTB         317840 B  sha256 3c80b4876fa89b0b8e7a7e4915387882dc763d7c63b49870634fd2c15e03b008
modules   88404266 B  sha256 9f57856f6244ba7eed10c33c25f15c63fde36442aa7cfd980707e16dcdb73aa8
8821cu.ko  4321168 B  sha256 7f5d820921fe8dee4553ded41528d486fd7a11774bfb70f280382c95bec7e812
```

---

## 1. What is IN this build

| # | Change | Source | DTB impact | Image impact |
|---|---|---|---|---|
| F3 | H2 split — `map3` delete + `aonclk` trim + `adsp_audio` disable moved out of `tegra194-mi-k91-audio.dtsi` into new `tegra194-mi-k91-fixups.dtsi` | this task | **zero** (proven, §3) | none |
| — | Synaptics DSX back touchpad: 4.9→5.10 driver + `synaptics_dsx@20` enabled | `build/touchpad-port/` (its NOTES asks for the E-batch build) | 3 lines in `synaptics_dsx@20` | +113 symbols, driver `=y` |
| — | NVCSI/VI/ISP power-domain + clock + reset restore (Stage 1) | `build/nvcsi-power-fix/patches/0001..0004` (its NOTES §4 says "主控在 E 批次统一构建时执行") | 4 nodes, 24 lines | 3 C files |
| — | everything already in the tree from previous batches (nvmap handle-as-fd, R32 capture ABI, ZRAM=m, GPS, audio codecs, ADMA) | earlier batches | — | unchanged |

## 2. What is NOT in this build

* **F1 (ramoops)** — deliberately zero kernel/DTB change. It is a **kernel command-line
  change only**: see `build/kernel-E/f1-ramoops/README.md`. Deploy it independently of
  the kernel if you want (it works on the currently running kernel too).
* **F2 (hardware watchdog)** — **recommendation: do not enable now.**
  Draft fragment + full risk analysis in
  `build/kernel-E/f2-watchdog-OPTIONAL-NOT-BUILT/`. Summary of the reasoning:
  the DT node carries `nvidia,enable-on-init` (arms at probe, not at open), the
  final expiry is a **system POR** which very likely wipes the ramoops black box,
  the first userspace open of `/dev/watchdog` permanently kills the kernel's own
  petting IRQ (`CONFIG_WATCHDOG_NOWAYOUT=y`), and — importantly — **factory JP4
  had it disabled too** (NVIDIA gates the node on odm-data `enable-denver-wdt`),
  so this is new unvalidated behaviour, not a port regression. Black box first,
  auto-resetter second.
* **initrd** — **not rebuilt, do not touch `/boot-jp5/initrd`.** Nothing in this batch
  needs it (same KREL, no modules in the initrd), and the deployed one was verified
  this session to carry the authoritative counter-based
  `sbin/jp5-autorevert-hook` (7418 B, the post-2026-07-19-retrospective rewrite),
  i.e. the safety net is intact. Rebuilding it only risks silently downgrading it.

## 3. F3 equivalence proof (the thing that had to be exactly zero)

Built the DTB from the tree *immediately before* and *immediately after* the split,
with no other change in between:

```
diff -u pre-split.dts post-split.dts
-  nvidia,dtbbuildtime = "Jul 26 2026\003:35:59";
+  nvidia,dtbbuildtime = "Jul 26 2026\003:37:34";
```

**That is the entire diff.** No node reordering, no property reordering, no phandle
renumbering. The three blocks were moved byte-for-byte (verified by normalising
comments away and comparing the DT statements: identical), and the new
`#include "tegra194-mi-k91-fixups.dtsi"` sits at exactly the token-stream position
the blocks used to occupy — immediately after the audio include.

## 4. DTB five-gate verification (`dtc -I dtb -O dts` on the shipped DTB)

| # | Gate | Result |
|---|---|---|
| 1 | `diag@5` disabled | ✅ `diag@5 { ... status = "disabled"; }` |
| 2 | thermal `map3` occurrences == 0 | ✅ `grep -c map3` → **0** |
| 3 | `aonclk` trimmed from `clocks-init` | ✅ `disable { clocks = <0x04 0x09 0x04 0x0b>; }` = `<&bpmp 9 &bpmp 11>`, no aonclk phandle |
| 4 | `adsp_audio` disabled | ✅ `adsp_audio { ... status = "disabled"; }` |
| 5 | legacy hsp okay + four mailboxes | ✅ `tegra-hsp@3c00000 status="okay"`; rtcpu `hsp { mboxes = <0x24a 1 6  0x24a 1 0x80000007  0x24a 1 1  0x24a 1 0x80000000>; mbox-names = "cmd-rx cmd-tx ivc-rx ivc-tx"; status="okay" }` → cmd rx=SM6 / tx=SM7 / ivc rx=SM1 / tx=SM0 |

## 5. Line-by-line DTB diff vs the running DTB

`build/recovered-from-dog/deployed/tegra194-mi-k91.dtb` vs this build — **99 diff lines,
5 hunks, 27 changed DT lines**, and every one is accounted for:

| Hunk | Node | Owner | Allowed by task F? |
|---|---|---|---|
| 1 | `nvidia,dtbbuildtime` | build timestamp | ✅ explicitly allowed |
| 2 | `synaptics_dsx@20` (`status` okay, `irq-gpio` flag `0x2002`→`0x2008`, `+cap-button-codes`) | touchpad path | ⚠️ **foreign path** — flagging it explicitly |
| 3 | `vi@15c10000` + `vi-thi@15f00000` (`+power-domains VE`, `+resets vi/tsctnvi`, `+clocks vi-const/nvcsi/nvcsilp`) | nvcsi path | ⚠️ **foreign path** |
| 4 | `isp@...` (`+power-domains ISPA`, `+resets isp`) | nvcsi path | ⚠️ **foreign path** |
| 5 | `nvcsi@15a00000` (`+nvcsilp` clock, `+power-domains VE`, `+resets NVCSI`) | nvcsi path | ⚠️ **foreign path** |

**F3 itself contributes 0 lines to this diff.** The task said the diff must be
"timestamp + F3 rearrangement only"; F3 is at zero, and the remaining 4 hunks are the two
foreign paths that F4 was told to merge in. If the orchestrator does not want them,
say so — reverting is `patch -R` of `nvcsi-power-fix/patches/*` and a `git checkout` of
`common/tegra194-p2151-0000.dtsi`, plus a rebuild.

## 6. Warnings

`grep -E "warning:|error:"` over the whole build log → **12 hits, all 12 identical
pre-existing cpp macro redefinitions (`"CAM0_PWDN" redefined`) in
`hardware/nvidia/platform/t23x/prometheus/kernel-dts/` — a different SoC (Orin), an
untouched file, present in the pristine tree.**

**Zero C warnings, zero C errors.** In particular the three nvcsi C patches (which their
author flagged as "never actually compiled, watch -Werror") and the ~20 500 lines of
forward-ported Synaptics driver compiled clean. Objects verified present, not silently
skipped:
`synaptics_dsx_{core,i2c,fw_update,rmi_dev,test_reporting}.o`, `device-group.o`,
`tegra-camera-rtcpu.o`, `t194.o`, `nvmap_ioctl.o`, `bcm_gps_tty.ko`, `zram.ko`.

## 7. Deployment instructions (for the orchestrator — I did not run any of this)

Everything lives on eMMC `/dev/mmcblk0p1`, mounted at `/mnt/emmcp1` in the examples.
**Deploy Image + DTB together** (they are not independently valid).

```sh
# ---- 0. backup, suffix ".prev-kernelE" -------------------------------------
sudo cp /mnt/emmcp1/boot-jp5/Image                 /mnt/emmcp1/boot-jp5/Image.prev-kernelE
sudo cp /mnt/emmcp1/boot-jp5/tegra194-mi-k91.dtb   /mnt/emmcp1/boot-jp5/tegra194-mi-k91.dtb.prev-kernelE

# ---- 1. kernel + DTB -------------------------------------------------------
sudo cp Image               /mnt/emmcp1/boot-jp5/Image
sudo cp tegra194-mi-k91.dtb /mnt/emmcp1/boot-jp5/tegra194-mi-k91.dtb
sudo sync

# ---- 2. modules ------------------------------------------------------------
#   KREL is UNCHANGED (5.10.216-tegra) -> this overwrites the live module tree.
sudo tar xzf modules-5.10.216-tegra.tar.gz -C /            # rootfs = nvme0n1p2
#   8821cu is NOT in the tarball. Wi-Fi dies without this step.
sudo mkdir -p /lib/modules/5.10.216-tegra/extra
sudo cp modules/8821cu.ko /lib/modules/5.10.216-tegra/extra/
sudo depmod -a 5.10.216-tegra
sudo sync
```

`mkdir -p` before the `cp` matters — the `cp || mkdir` ordering trap is already
documented in the port notes.

**Do NOT touch `/boot-jp5/initrd`.**

### Optional and independent: F1 ramoops (cmdline only)

`/mnt/emmcp1/boot/extlinux/extlinux.conf`, `LABEL jp5`, append to the `APPEND` line:

```
ramoops.mem_address=0xf0800000 ramoops.mem_size=0x200000 ramoops.record_size=0x10000 ramoops.console_size=0x80000 ramoops.ftrace_size=0 ramoops.pmsg_size=0 ramoops.max_reason=3
```

Back up `extlinux.conf` first. Full derivation of `0xf0800000` and the verification
procedure: `build/kernel-E/f1-ramoops/README.md` +
`build/kernel-E/f1-ramoops/verify-ramoops.sh` (read-only, no crash trigger).

### Verification after the reboot, in order

1. `uname -a` → `5.10.216-tegra`, new build date.
2. `dmesg | grep -i "thermal zone"` and `cat /sys/class/thermal/thermal_zone*/type`
   → **6 zones** must register. If the CPU/GPU zones are missing, the F3 split broke
   something — roll back the DTB immediately, this is the thermtrip-death path.
3. `systemctl status fanboy` → still alive; `nvfancontrol` not crash-looping.
4. `aplay -l` / `arecord -l` → the `jetson-xaviernx-ape` card still registers
   (gates 3 + 4 — `aonclk`, `adsp_audio`).
5. `dmesg | grep -iE "rce|camrtc"` → RCE handshake `cmd=5` still there (gate 5).
6. `dmesg | grep -i synaptics` and `ls /sys/class/input/*/name | xargs grep -l synaptics`
   → **new**: touchpad probe result (touchpad path owns this outcome).
7. `dmesg | grep -iE "rce-noc|nvcsi"` → **new**: nvcsi path's `rce-noc: Host read
   timeout at address 303cc` should be gone (nvcsi path owns this outcome).
8. `nvidia-smi`-less sanity: `cat /sys/kernel/debug/bpmp/debug/soctherm/*` not needed;
   just confirm the dog stays up under load for 30 min (the old thermtrip window).

### Rollback

```sh
sudo cp /mnt/emmcp1/boot-jp5/Image.prev-kernelE               /mnt/emmcp1/boot-jp5/Image
sudo cp /mnt/emmcp1/boot-jp5/tegra194-mi-k91.dtb.prev-kernelE /mnt/emmcp1/boot-jp5/tegra194-mi-k91.dtb
sudo sync
```
Modules: the previous module tree is overwritten in place (same KREL) — if a rollback is
needed, re-extract the previous batch's `modules-5.10.216-tegra.tar.gz`. If the dog does
not come back: serial console on the laptop (`ben@10.0.0.176`, `/dev/ttyACM0`, 115200)
picks `rescue`/`primary` in the cboot menu, and the initrd autorevert hook falls back to
JP4 after 3 unsuccessful boots.

## 8. Loose ends noticed, not touched

* `kernel/nvidia/drivers/platform/tegra/rtcpu/Oops.rej` and `hsp-combo.c.orig` are
  untracked leftovers from an earlier patching session sitting in the shared source tree.
  Harmless (not built), but they should be cleaned up.
* `CONFIG_SOFT_WATCHDOG` is not set. Adding it as `=m` would give a zero-DT-change,
  zero-effect-until-loaded option for a future userspace-level self-heal. Not added —
  unrequested change to a batch that already carries core-memory surgery.
