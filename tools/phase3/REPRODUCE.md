# Reproducing the CyberDog JP5 kernel from scratch (r35.6.4 / 5.10.216)

Everything needed to rebuild the Phase 3 kernel WITHOUT the Mac's `build/`
working tree. The kernel source deltas live here as patch series (round-trip
verified 2026-07-19: all series `git am` clean onto the pristine r35.6.4 tree —
byte-identical round-trip requires `--keep-cr`, verified 2026-07-19 evening;
nvidia series completed to 6 patches + kernel 0009 added 2026-07-19 pm).

## Inputs (on the dog at `/data/cyberdog-mirror-2026-07/`, SHA256SUMS present)
- `nvidia/public_sources_r35.6.4.tbz2` — NVIDIA L4T r35.6.4 public sources.
- `repos/8821cu-20210916.git` — morrownr out-of-tree Wi-Fi driver (the ONLY
  Wi-Fi driver; the in-tree rtl8821cu is disabled by kernel-5.10 patch 0009).

## Steps
1. **Unpack** `public_sources_r35.6.4.tbz2`, then inside it unpack
   `Linux_for_Tegra/source/public/kernel_src.tbz2`. You get
   `kernel_src/{kernel/kernel-5.10, kernel/nvidia, hardware/nvidia/...}`.

2. **git-baseline** each of the three trees we patch (so `git am` works):
   ```
   for d in kernel/kernel-5.10 hardware/nvidia/platform/t19x/jakku kernel/nvidia; do
     ( cd "$d" && git init -q && git config am.keepcr true && git add -A -f . && \
       git -c user.name=p -c user.email=p@x commit -qm "pristine r35.6.4" )
   done
   ```

3. **Apply the delta series in order** (see `cyberdog-deltas/`):
   - `cyberdog-deltas/kernel-5.10/*.patch` → `kernel/kernel-5.10`
     (0001-0005 = zbwu's r35.1 deltas rebased; 0006 = defconfig CAN_RAW +
      SocketCAN + BMI160 + GPIO_TEGRA186 + r35 audio stack; 0007 = import
      Xiaomi 4.9 rt5680/tas5805m verbatim + Kconfig/Makefile/defconfig wiring;
      0008 = convert both codecs to the 5.10 component API; 0009 = defconfig:
      disable in-tree RTL8821CU — morrownr `8821cu.ko` is the only Wi-Fi
      driver; CONFIG_RTK_BTUSB bluetooth unaffected).
   - `cyberdog-deltas/jakku-dts/*.patch` → `hardware/nvidia/platform/t19x/jakku`
     (0001 = Athena DTS restructured into r35.6.4 `kernel-dts/` layout; 0002 =
      mi-k91 audio card [tegra-alt]; 0003 = mark it PLACEHOLDER for the
      Phase 5.6 audio card — see Known-open).
   - `cyberdog-deltas/nvidia/*.patch` → `kernel/nvidia`
     (0001-0005 = zbwu's nvidia-tree patches: rtl8821cu 5.10 fix, ov7251 +
      ov13b10 sensor drivers, p2p disable, i2c address conflict fix, regulator
      fix; 0006 = tegra-alt Kconfig FPGA_ALT stub + t194 deps — kept for the
      record; tegra-alt still won't build on 5.10, see PHASE3_BUILD_RESULTS.md).
   ```
   ( cd kernel/kernel-5.10 && git am --keep-cr /path/cyberdog-deltas/kernel-5.10/*.patch )
   ( cd hardware/nvidia/platform/t19x/jakku && git am --keep-cr /path/cyberdog-deltas/jakku-dts/*.patch )
   ( cd kernel/nvidia && git am --keep-cr /path/cyberdog-deltas/nvidia/*.patch )
   ```
   `--keep-cr` is REQUIRED (kept belt-and-braces with step 2's
   `git config am.keepcr true`): kernel-5.10 delta 0007 imports two Xiaomi 4.9
   CRLF headers (`tas5805m.h`/`tas5805m_basic.h`, 3,103 CR chars) — bare
   `git am` strips the CRs silently and the reproduced tree permanently
   diverges from the real build tree. `--keep-cr` round-trips byte-identically
   and is a harmless no-op for the CR-free patches.
   (`zbwu-patches/` is the ORIGINAL upstream-r35.1 export kept for provenance;
   `cyberdog-deltas/` is what you actually apply — it already includes the
   rebased-onto-r35.6.4 forms plus our new work.)

4. **Build** (native arm64 on Apple silicon via colima/docker image
   `cyberdog-kbuild`; image recipe committed at `tools/phase3/docker/Dockerfile`
   = ubuntu:20.04 + build deps + busybox-static; see `full-build.sh`). MUST
   build to a NATIVE path (`O=/tmp/kb`), NOT a virtiofs mount, or nvidia's
   in-tree `sed -i` codegen fails with "couldn't open temporary file …
   Permission denied".
   `full-build.sh` already sets `LOCALVERSION=-tegra` and asserts
   KREL = `5.10.216-tegra` (stock KREL; plan §12 gate); it also runs
   `set -euo pipefail`, fails hard on compile errors, wipes `/work/out/final`
   before packaging, asserts the 8821cu.ko vermagic, and emits SHA256SUMS.
   If building manually, add `LOCALVERSION=-tegra` yourself:
   ```
   make -C kernel/kernel-5.10 ARCH=arm64 LOCALVERSION=-tegra O=/tmp/kb athena_defconfig
   make -C kernel/kernel-5.10 ARCH=arm64 LOCALVERSION=-tegra O=/tmp/kb -j6 Image dtbs modules
   ```
   Then out-of-tree Wi-Fi:
   `make -C /tmp/kb M=<8821cu path> KVER=<KREL> ARCH=arm64 modules`.
   Fixed order: `full-build.sh` first (it wipes `out/final`), then
   `tools/phase4/build-jp5-initrd.sh` — always re-run the initrd build after
   every full-build run.

## Verify (Phase 3 gate)
- `file Image` → ARM64 kernel boot executable.
- KREL (`include/config/kernel.release`) = `5.10.216-tegra`.
- `dtc -I dtb -O dts tegra194-p3668-0001-p2151-0000.dtb` round-trips.
- Wi-Fi `.ko` vermagic matches the Image (`modinfo -F vermagic`).
- Module set includes `snd-soc-rt5680.ko` + `snd-soc-tas5805m.ko`,
  `nv_ov7251.ko` + `nv_ov13b10.ko`. The in-tree `rtl8821cu.ko` is
  intentionally NOT built (defconfig patch 0009) — Wi-Fi is the morrownr
  `8821cu.ko` only.

## Known-open (do NOT assume done) — see PHASE3_BUILD_RESULTS.md §"Audio…"
The JP5 initramfs IS now assembled by `tools/phase4/build-jp5-initrd.sh`
(busybox shell + auto-revert guard + USB gadget console; hard size gate
< 7,236,790 B packed — this cboot silently swaps an oversized initrd for the
stock one, PHASE2_RUNBOOK §3b). Still open:
- Phase-4 rehearsal on an empty p2.
- `cyberdog_motor_sdk` link-check (Phase 5).
- Audio: Phase 5.6 pivot target is `nvidia,tegra186-ape` (r35's documented
  custom-card path); audio-graph is fallback only — the graph card ships
  `status="disabled"` on t194 and is not the standard path.
