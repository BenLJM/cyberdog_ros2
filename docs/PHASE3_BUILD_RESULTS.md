# Phase 3 build results — L4T r35.6.4 / kernel 5.10.216 (2026-07-19)

First JP5 kernel for CyberDog built and verification-gated. Native arm64 build
on the owner's Apple-silicon Mac (colima + docker, `cyberdog-kbuild` image);
sources = `public_sources_r35.6.4.tbz2` unpacked, zbwu's r35.1 deltas rebased.

## Artifacts (`build/out/final/`, KREL `5.10.216+`)

| File | Size | Verified |
|---|---|---|
| `Image` | 33 MB | `file` → ARM64 kernel boot executable ✅ |
| `tegra194-p3668-0001-p2151-0000.dtb` | 316 KB | `dtc -I dtb` round-trips (exit 0); sound node has rt5680/tas5805 (5 refs) ✅ |
| `8821cu.ko` | 4.3 MB | ARM aarch64, vermagic `5.10.216+ SMP preempt … aarch64` (matches Image) ✅ |
| `modules-5.10.216+.tar.gz` | 89 MB | full module set incl. `snd-soc-rt5680.ko` + `snd-soc-tas5805m.ko` ✅ |

## What landed (git branches `cyberdog-humble-r35.6.4` in the three trees)

- **Rebase**: zbwu's 12 deltas (kernel/defconfig/cameras, DTS, 5 out-of-tree
  drivers incl. rtl8821cu 5.10 fix + ov7251/ov13b10) onto r35.6.4. The DTS set
  was restructured into r35.6.4's `kernel-dts/` layout (r35.1 had them at repo
  root). All patches in `tools/phase3/zbwu-patches/`.
- **defconfig** (`athena_defconfig`): added the two scope-doc must-fixes —
  `CAN_RAW`/`CAN_BCM`/`CAN_GW`/`CAN_DEV` (motor bus SocketCAN; silent gap that
  would have failed Phase 5) and the r35 audio-graph/tegra stack — plus
  `BMI160_I2C`, `GPIO_TEGRA186`, and the RT5680/TAS5805M codec configs.
- **Audio drivers**: rt5680 (2884 lines) + tas5805m converted from the
  removed-in-4.18 `snd_soc_codec` API to the 5.10 component API
  (multi-agent, cross-reviewed, each compiles to a clean `.ko`). All register
  tables, DAPM widgets/routes, and the 1740-line tas5805m DSP tuning table are
  byte-for-byte unchanged.
- **Audio DT**: `tegra194-mi-k91-audio.dtsi` ported to the r35 generic
  `nvidia,tegra-audio-t186ref` tegra-alt machine driver (r35 keeps tegra-alt
  next to audio-graph → far smaller job than the feared audio-graph rewrite).
  rt5680 6-mic on I2S3, tas5805m amp on I2S5; codecs on gen1_i2c@3160000; GPIO
  expanders reconciled against zbwu's p2151 dtsi + the live DT dump.
- **8821cu Wi-Fi**: morrownr out-of-tree module built against the r35.6.4
  headers, vermagic-matched.
- **Auto-revert hook** (`tools/phase3/jp5-autorevert-hook.sh`): for the JP5
  initramfs — probes `/dev/nvme0n1p2` read-only before the real root mount;
  on failure restores `extlinux.conf` from the jp4-saved copy (atomic rename)
  and reboots. Turns the likely Phase-4 failure into a self-healing power-cycle.
  Pair with `panic=15` in the JP5 APPEND. Rehearse deliberately in Phase 4.

## Known follow-ups for Phase 4/5 (none block staging)

- **tegra-alt machine-driver Kconfig gap**: `tegra_t186ref_alt.c` is gated by
  `SND_SOC_TEGRA_T186REF_FPGA_ALT`, which has **no Kconfig entry** (Makefile-only)
  — `olddefconfig` strips it, so the machine-driver `.ko` is not yet in the set.
  Add a Kconfig stub (or repoint the Makefile gate to `SND_SOC_TEGRA_T186REF_ALT`)
  before audio bring-up. The codecs + DTB are ready; only the card-binding
  driver config is pending.
- **Audio route/mic-channel tuning**: `nvidia,audio-routing` carried verbatim
  from the live DT; DAPM route-name binding + 6-mic channel order need the real
  hardware (`dmesg`/`aplay -l`/`amixer` loop) — Phase 5.6, as scoped.
- **tegra-alt vs mainline SND_SOC_TEGRA210_* co-existence** in the defconfig is
  a bring-up decision; both stacks are currently enabled.

## Reproduce

`build/full-build.sh` inside the `cyberdog-kbuild` container builds Image + dtbs
+ modules + the 8821cu `.ko` and stages everything to `out/final/`.
