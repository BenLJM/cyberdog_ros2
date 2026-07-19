# Reproducing the CyberDog JP5 kernel from scratch (r35.6.4 / 5.10.216)

Everything needed to rebuild the Phase 3 kernel WITHOUT the Mac's `build/`
working tree. The kernel source deltas live here as patch series (round-trip
verified 2026-07-19: all series `git am` clean onto the pristine r35.6.4 tree).

## Inputs (on the dog at `/data/cyberdog-mirror-2026-07/`, SHA256SUMS present)
- `nvidia/public_sources_r35.6.4.tbz2` — NVIDIA L4T r35.6.4 public sources.
- `repos/8821cu-20210916.git` — morrownr out-of-tree Wi-Fi driver (preferred over
  zbwu's in-tree rtl8821cu; pick ONE at staging).

## Steps
1. **Unpack** `public_sources_r35.6.4.tbz2`, then inside it unpack
   `Linux_for_Tegra/source/public/kernel_src.tbz2`. You get
   `kernel_src/{kernel/kernel-5.10, kernel/nvidia, hardware/nvidia/...}`.

2. **git-baseline** each of the three trees we patch (so `git am` works):
   ```
   for d in kernel/kernel-5.10 hardware/nvidia/platform/t19x/jakku kernel/nvidia; do
     ( cd "$d" && git init -q && git add -A -f . && \
       git -c user.name=p -c user.email=p@x commit -qm "pristine r35.6.4" )
   done
   ```

3. **Apply the delta series in order** (see `cyberdog-deltas/`):
   - `cyberdog-deltas/kernel-5.10/*.patch` → `kernel/kernel-5.10`
     (0001-0005 = zbwu's r35.1 deltas rebased; 0006 = defconfig CAN_RAW +
      SocketCAN + BMI160 + GPIO_TEGRA186 + r35 audio stack; 0007 = import
      Xiaomi 4.9 rt5680/tas5805m verbatim + Kconfig/Makefile/defconfig wiring;
      0008 = convert both codecs to the 5.10 component API).
   - `cyberdog-deltas/jakku-dts/*.patch` → `hardware/nvidia/platform/t19x/jakku`
     (0001 = Athena DTS restructured into r35.6.4 `kernel-dts/` layout; 0002 =
      mi-k91 audio card [tegra-alt]; 0003 = mark it PLACEHOLDER → audio-graph
      in Phase 5.6).
   - `cyberdog-deltas/nvidia/*.patch` → `kernel/nvidia`
     (0001 = tegra-alt Kconfig FPGA_ALT stub + t194 deps — kept for the record;
      tegra-alt still won't build on 5.10, see PHASE3_BUILD_RESULTS.md).
   ```
   ( cd kernel/kernel-5.10 && git am /path/cyberdog-deltas/kernel-5.10/*.patch )
   ( cd hardware/nvidia/platform/t19x/jakku && git am /path/cyberdog-deltas/jakku-dts/*.patch )
   ( cd kernel/nvidia && git am /path/cyberdog-deltas/nvidia/*.patch )
   ```
   (`zbwu-patches/` is the ORIGINAL upstream-r35.1 export kept for provenance;
   `cyberdog-deltas/` is what you actually apply — it already includes the
   rebased-onto-r35.6.4 forms plus our new work.)

4. **Build** (native arm64 on Apple silicon via colima/docker image
   `cyberdog-kbuild`; see `full-build.sh`). MUST build to a NATIVE path
   (`O=/tmp/kb`), NOT a virtiofs mount, or nvidia's in-tree `sed -i` codegen
   fails with "couldn't open temporary file … Permission denied".
   **Add `LOCALVERSION=-tegra`** (the reference full-build.sh omitted it →
   KREL `5.10.216+`; stock wants `5.10.216-tegra`):
   ```
   make -C kernel/kernel-5.10 ARCH=arm64 LOCALVERSION=-tegra O=/tmp/kb athena_defconfig
   make -C kernel/kernel-5.10 ARCH=arm64 LOCALVERSION=-tegra O=/tmp/kb -j6 Image dtbs modules
   ```
   Then out-of-tree Wi-Fi:
   `make -C /tmp/kb M=<8821cu path> KVER=<KREL> ARCH=arm64 modules`.

## Verify (Phase 3 gate)
- `file Image` → ARM64 kernel boot executable.
- `dtc -I dtb -O dts tegra194-p3668-0001-p2151-0000.dtb` round-trips.
- Wi-Fi `.ko` vermagic matches the Image (`modinfo -F vermagic`).
- Module set includes `snd-soc-rt5680.ko` + `snd-soc-tas5805m.ko`,
  `nv_ov7251.ko` + `nv_ov13b10.ko`.

## Known-open (do NOT assume done) — see PHASE3_BUILD_RESULTS.md §"Audio…"
Audio card = audio-graph rewrite in Phase 5.6 (tegra-alt is a dead end);
`cyberdog_motor_sdk` link-check pending; pick one Wi-Fi driver; assemble the
JP5 initramfs with the auto-revert hook + `panic=15`.
