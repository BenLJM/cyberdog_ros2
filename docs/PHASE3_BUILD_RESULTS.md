# Phase 3 build results — L4T r35.6.4 / kernel 5.10.216 (2026-07-19)

First JP5 kernel for CyberDog built and verification-gated. Native arm64 build
on the owner's Apple-silicon Mac (colima + docker, `cyberdog-kbuild` image);
sources = `public_sources_r35.6.4.tbz2` unpacked, zbwu's r35.1 deltas rebased.

> **2026-07-19 evening addendum**: the artifacts below were REBUILT the same
> day with `LOCALVERSION=-tegra` after the retrospective
> (docs/RETROSPECTIVE-2026-07-19.md). See "Rebuild addendum" at the end of
> this file — the morning `5.10.216+` artifacts are superseded and deleted.

## Artifacts (`build/out/final/`, KREL `5.10.216+`) — SUPERSEDED, see addendum

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
  *(2026-07-19 evening: substantially rewritten — boot-attempt counter [>3
  passes without a `jp5-boot-ok.service` clear → revert], verified writes with
  HOLD-on-failure instead of blind reboot, gadget-console shells; see the
  current file header and tools/phase4/. This paragraph describes the morning
  version.)*

## Audio machine driver — tegra-alt is a DEAD END, use audio-graph (2026-07-19)

> **Superseded later the same day**: the pivot target was re-judged against
> NVIDIA's r35 source/docs — primary path is now the **`nvidia,tegra186-ape`**
> custom card (`nvidia-audio-card,*` properties), audio-graph is fallback only
> (ships `status="disabled"` on t194; `tegra_codecs.c` hardcodes codecs). See
> plan §5.6 / PHASE3_AUDIO_PORT_SCOPING fact 4. The tegra-alt dead-end
> analysis below remains valid.

Investigated while trying to make the tegra-alt machine driver build. Chain of
findings:
1. `tegra_t186ref_alt.c` is gated by `SND_SOC_TEGRA_T186REF_FPGA_ALT`, which had
   **no Kconfig entry** (Makefile-only). Added the stub + widened the driver's
   `ARCH_TEGRA_18x_SOC` deps to also allow `ARCH_TEGRA_194_SOC` (commit in
   kernel/nvidia). Necessary but not sufficient.
2. kernel-5.10's `sound/soc/Kconfig`/`Makefile` don't source the nvidia
   `tegra-alt` overlay at all → the configs never resolved. Wired it in
   (symlink + source/obj lines) and the configs then resolved.
3. **Full `make modules` then FAILED**: the entire r35.1 tegra-alt subsystem
   (`utils/tegra_pcm_alt.c` + ~20 driver files) uses the pre-4.18 ASoC API
   removed in 5.10 — `struct snd_soc_platform`, `snd_soc_pcm_runtime.{platform,
   cpu_dai}`, `dma_mmap_writecombine`. Porting all of it is the same
   component-API surgery the two codecs got, ×20, for **downstream/legacy**
   code that mainline replaced with audio-graph. zbwu never forward-ported it.

**Decision: pivot the audio card to the mainline audio-graph stack**
(`nvidia,tegra186-audio-graph-card`), which already builds clean here
(`snd-soc-tegra-audio-graph-card.ko` is in the module set). The tegra-alt
overlay was reverted (tree builds clean again); the Kconfig stub is kept for the
record. The committed `tegra194-mi-k91-audio.dtsi` now carries a PLACEHOLDER
header — the DTB compiles (data only, **no Phase-4 boot impact**), but re-authoring
the card in audio-graph `ports`/`endpoints` form (plus adding graph OF endpoints
to the rt5680/tas5805m codec nodes+drivers) is **Phase 5.6**, where route/mic
binding needs the real hardware anyway. The two codec drivers themselves are
API-correct and reused as-is by either framework.
- **Audio route/mic-channel tuning**: `nvidia,audio-routing` carried verbatim
  from the live DT; DAPM route-name binding + 6-mic channel order need the real
  hardware (`dmesg`/`aplay -l`/`amixer` loop) — Phase 5.6, as scoped.
- **tegra-alt vs mainline SND_SOC_TEGRA210_* co-existence** in the defconfig is
  a bring-up decision; both stacks are currently enabled.

## Reproduce

`build/full-build.sh` inside the `cyberdog-kbuild` container builds Image + dtbs
+ modules + the 8821cu `.ko` and stages everything to `out/final/`. Full
from-scratch reproduction (patch series, `git am --keep-cr`, image recipe at
`tools/phase3/docker/Dockerfile`): see `tools/phase3/REPRODUCE.md`. Fixed
order: `full-build.sh` first (it wipes `out/final/`), then
`tools/phase4/build-jp5-initrd.sh`.

## Rebuild addendum (2026-07-19 evening — CURRENT artifacts)

Retrospective-driven rebuild with the hardened `full-build.sh`
(`LOCALVERSION=-tegra`, `set -euo pipefail`, KREL + vermagic assertions, clean
`out/final/`, SHA256SUMS) and defconfig delta **0009** (in-tree `RTL8821CU`
disabled — it built a `.ko` with the SAME name `8821cu.ko` as the morrownr
driver for the same USB ID 0bda:c820; morrownr is now the single Wi-Fi
driver; `CONFIG_RTK_BTUSB` Bluetooth unaffected and present).

| File | Size | Verified |
|---|---|---|
| `Image` | 33,888,768 B | KREL `5.10.216-tegra` (asserted in-build) |
| `tegra194-p3668-0001-p2151-0000.dtb` | 317,729 B | staged to `/boot-jp5/tegra194-mi-k91.dtb` (rename!) |
| `modules/8821cu.ko` | 4,321,168 B | vermagic `5.10.216-tegra SMP preempt …` (asserted) |
| `modules-5.10.216-tegra.tar.gz` | 87,989,260 B | 46 modules incl. rt5680/tas5805m codecs, nv_ov7251/nv_ov13b10, rtk_btusb; NO in-tree 8821cu |
| `jp5-initrd` | 961,042 B | dual size gates vs the 7,236,790 B cboot envelope; busybox + gadget console + auto-revert guard |

`SHA256SUMS` + `jp5-initrd.sha256` accompany the artifacts. Staged on the dog
at `/data/jp5-build-2026-07-19-tegra/` (the morning `5.10.216+` set is
deleted). BMI160 is `=y` (builtin — correctly absent from the module list).
