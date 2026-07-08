# Off-device scoping (no-SSD session) — 2026-07-08

Four analyses done tonight without touching the dog destructively, using the local
mirrors (`~/cyberdog-mirror-2026-07/`), the live 4.9 kernel, and the closed binaries
on disk. All feed Phase 1 / Track S / Phase 3 planning. Companion:
[PHASE3_AUDIO_PORT_SCOPING.md](./PHASE3_AUDIO_PORT_SCOPING.md).

**Headline: the biggest scope surprise is good.** `cyberdog_locomotion` is **not a
ROS 2 package in any meaningful sense** — it's an LCM-based MIT-Cheetah controller
with only `CMakeLists.txt` + `package.xml` touching ROS. The feared "Galactic→Humble
locomotion port" (plan budgeted ~20-25 evenings) is largely a **non-problem**; the
real ROS seam lives in `cyberdog_ros2`'s decision/bridge layer instead.

---

## 1. `athena_defconfig` ⇄ live `/proc/config.gz` diff (Phase 3 deliverable)

Compared zbwu's r35.1 `athena_defconfig` (445 set CONFIGs) against the live 4.9
config (2,486 set CONFIGs). The defconfig is a *minimal* seed, not a full config —
expected. Critical-hardware audit:

| Subsystem | live 4.9 | zbwu 5.10 defconfig | Action for r35.6.4 build |
|---|---|---|---|
| IMU BMI160 | `BMI160_I2C=y` | **absent** | Add — but sources ARE in zbwu's tree (`nvs_bmi160.c` + iio); enable `=m`/`=y`. Note: live also uses HID-sensor path; verify which binds |
| Camera OV13B10 | `VIDEO_OV13B10=y` | `NV_VIDEO_OV13B10=m` ✅ | Present (NVIDIA-style naming) |
| Camera OV7251 | `VIDEO_OV7251_L=y` | `NV_VIDEO_OV7251=m` ✅ | Present |
| **Audio (rt5680/tas5805m/rt5659)** | all `=y` | **all absent** | Phase 3 core work — see audio scoping doc |
| **SND_SOC_TEGRA (ALT stack)** | many `_ALT=y` | **absent** | Enable the r35 audio-graph stack (not the r32 ALT stack — different framework) |
| GPIO expander | `PCA953X_IRQ=y` | `PCA953X_IRQ=y` ✅ | Present (covers TCA6424) |
| INA3221 (BMS) | `INA3221=y` | `SENSORS_INA3221=y` ✅ | Present (hwmon variant) |
| **CAN controller (MTTCAN)** | `MTTCAN=y` | `MTTCAN=y` ✅ | Present — the Tegra CAN IP |
| **CAN_RAW / SocketCAN** | `CAN_RAW=y`, full stack | only `CONFIG_CAN=y` | ⚠️ **Add `CAN_RAW`, `CAN_DEV`, `CAN_BCM`, `CAN_GW`** — motor SDK needs raw SocketCAN; zbwu's minimal defconfig has the core but not `CAN_RAW`. **Cheap fix, but a silent gap that would break motors in Phase 5.** |
| GPIO_TEGRA186 | `=y` | absent | Add (base platform GPIO) |
| Wi-Fi | `RTL8821AE=m` (wrong/PCIe variant) | `RTL8821CU=m` ✅ | zbwu already added the USB variant. Still prefer the OOT morrownr module (newer) |
| MAX20024 / VL53L1 / TCA6424(named) | not a distinct CONFIG | — | MAX20024 is via regulator DT not a codec CONFIG; VL53L1 TOF confirm from DT; TCA6424 rides PCA953X |

**Takeaway:** zbwu's defconfig is a solid seed but has **two must-fix gaps for
CyberDog function** — the full **audio stack** (known) and **`CAN_RAW`+SocketCAN
userspace** (newly caught tonight; would have surfaced as "motors don't respond" in
Phase 5). Add both to the fork's defconfig before the first Phase 3 build. Working
copies: `~/cyberdog-scoping/{athena_defconfig.r35.1,live-4.9.config,zbwu-set.config}`.

## 2. Closed-`.so` forward-compat — glibc AND ROS ABI (corrected 2026-07-09)

> **Self-correction.** The first version of this section checked only glibc symbol
> versions and declared the keystone "copy-forward safe." That was the wrong layer.
> glibc is the *least* likely thing to break (it's strongly backward-compatible);
> the real question is the **ROS 2 ABI** each closed lib links against. Re-audited
> below with `readelf -d` NEEDED.

**glibc layer (holds):** `objdump -T` maxes — keystone `libathena_utils_core.so`
GLIBC 2.17 / GLIBCXX 3.4.21, `libathena_touch_core.so` 2.17, `libContentMotionAPI.so`
2.27 — all ≪ focal's GLIBC 2.31 / GLIBCXX 3.4.28. So glibc is a non-issue. But that
is necessary, not sufficient.

**ROS-ABI layer (the real gate).** Full NEEDED audit of all 9 closed libs:

| Closed lib | Links ROS? | Copy-forward verdict |
|---|---|---|
| `libathena_utils_core.so` **(keystone, 20+ consumers)** | **Foxy** (`librclcpp`, `librcl`, `librclcpp_lifecycle`) | ❌ **NOT a simple copy-forward** — needs Foxy rclcpp ABI; Humble breaks it |
| `libaudio_assistant.so` | **Foxy** (`librclcpp`, `librcl`, …) | n/a — on the DROP list (Phase 8) |
| `libaudio_interaction.so` | **Foxy** (`librcl_action`, `librclcpp_action`, `librclcpp_lifecycle`) | n/a — DROP |
| `libaivs_sdk.so` | no ROS | DROP anyway (dead cloud) |
| `libathena_touch_core.so` | no ROS | ✅ standalone — glibc-only, copy-forward OK |
| `libaudio_base.so` / `libaudio_config.so` | no ROS | DROP (audio) |
| `libbody_detect_api.so` | no ROS | REPLACE (YOLO) — standalone if ever needed |
| `libContentMotionAPI.so` | no ROS | ✅ standalone (but dropped with body_detect) |

**Counts: 6 standalone (glibc-only, genuinely copy-forwardable), 3 Foxy-ABI-bound.**

**What this actually means:**
- The **walking MVP is unaffected** — locomotion links *no* closed lib (Phase 0
  forensics + §3 tonight), so the Foxy-ABI problem doesn't touch getting the dog to
  stand/trot. The Phase-0 thesis "minimum-viable walking needs no closed code" still
  holds.
- Of the 3 Foxy-bound libs, **2 are already slated to DROP** (audio → Phase 8 voice
  stack). Their Foxy binding is irrelevant.
- The problem collapses to **exactly one library: the keystone
  `libathena_utils_core.so`.** Its 20+ consumers (LED, touch, body_state,
  decisionmaker, tracking, obstacle/scene detection, …) are the *non-locomotion*
  behaviors. Reusing any of them on JP5 means solving the keystone's Foxy binding.

**New decision point (was hidden by the earlier optimism):** how to handle the
keystone.
- **Option A — Foxy side-by-side runtime.** Install just Foxy's rclcpp/rcl runtime
  `.so` alongside Humble (not the whole distro). The closed Foxy nodes + keystone run
  as Foxy processes; they interoperate with Humble nodes **over DDS/topics** (both
  RMW-on-DDS, so Foxy↔Humble talk at the wire level fine, even though in-process ABI
  differs). Lowest-effort way to keep the closed behaviors. **Recommended default.**
- **Option B — replace the consumers.** LED via direct TCA6424 GPIO, touch via the
  standalone `libathena_touch_core.so` (no ROS!) behind a small Humble node, body
  detection via YOLO (already planned). Drops the keystone entirely. More work, fully
  open.
- **Option C — defer.** Walking + voice + teleop need none of this; ship those first,
  decide keystone disposition later.

**Verify in Phase 5:** whether Foxy runtime `.so` load cleanly on the r35.6.4 rootfs
(they should — glibc checks above pass), and whether the closed Foxy nodes DDS-interop
with Humble nodes on the same graph. `readelf -V` chroot check as before, now with the
correct expectation (glibc OK, ROS ABI = Foxy).

## 3. `cyberdog_locomotion` port surface — MAJOR re-scope

565 files (322 C++). ROS/LCM balance is decisive:

- **LCM references: 949.** **rclcpp/ament references: 7** — and all 7 are in
  `CMakeLists.txt` + `package.xml` (build glue), **zero in `.cpp/.hpp`**.
- 28 `.lcm` type definitions; a `simbridge/` dir is the sim seam.
- `cyberdog_motor_sdk`: **0** rclcpp files, CMake finds no ament — pure CAN/C++.

**Architecture (now confirmed):** locomotion is a self-contained LCM control binary
(MIT Cheetah lineage). It talks to the rest of the system over **LCM**, not ROS
topics. The ROS 2 coupling everyone feared lives in **`cyberdog_ros2`** —
`cyberdog_decision/decision_maker/motion_manager.{hpp,cpp}` +
`cyberdog_interfaces/lcm_translate_msgs/` (the LCM↔ROS translation layer, 28 `.lcm`
types mirrored on both sides).

**Consequences for the plan:**
- **Track S shrinks dramatically.** Porting locomotion to "Humble" is mostly:
  build the LCM binary on 20.04 (LCM is distro-agnostic C++), keep it as-is. The
  actual Galactic→Humble API work is confined to `cyberdog_ros2`'s decision/bridge
  packages — a much smaller, well-bounded surface (rclcpp param API, message
  headers, launch syntax) than "port a whole gait controller."
- **The LCM boundary is a gift for incremental bring-up:** the locomotion binary can
  be validated standalone (LCM loopback, no ROS) before any ROS 2 stack exists —
  Track S can walk-in-sim with just LCM + the simbridge, deferring all ROS entirely.
- Revise plan D8/§14: the effort estimate for the locomotion *port* drops; reallocate
  budget to the `cyberdog_ros2` decision-layer Galactic→Humble port, which is the
  true long pole.

## 4. `8821cu` Wi-Fi driver build-readiness

- morrownr repo, last commit **2025-12-14** (merge fixing **linux 6.18** — actively
  maintained well past our 5.10 target). `CONFIG_PLATFORM_AUTODETECT=y` + ARM
  platform switches present → builds against arbitrary `KSRC`/`KVER` via DKMS or
  plain `make`.
- Plan: build out-of-tree against the r35.6.4 kernel headers in Phase 3, ship the
  `.ko` + a DKMS fallback. Low risk. (Confirms review §2.6 / D5.)

---

## 5. Phase 2 rescue-initrd — build materials confirmed on-dog (was "assumed")

Phase 2 v3 (review D4) hinges on building a RAM rescue initrd. The plan asserted it
was feasible; tonight confirmed **every ingredient is already on the dog**:

- **`/bin/busybox`** present (1.6 MB, single binary) — the initrd shell/utils.
- **Stock initrd is a working template** — gzip cpio with an `init` + busybox-style
  utils; a proven L4T initramfs to fork from rather than build from scratch.
- **`/opt/nvidia/l4t-usb-device-mode/`** present and complete: `nv-l4t-usb-device-mode-start.sh`
  (11 KB configfs gadget bring-up), `filesystem.img` (16 MB FAT gadget), service
  units. This is the exact RNDIS-192.168.55.1 **+ ttyGS0 serial-console** access path
  the rescue initrd (and JP5 first-boot, D6) needs — lift it wholesale.
- **`sshd`** present (openssh-server 7.6). Either embed it or swap for dropbear;
  either fits an initramfs.

**Verdict:** Phase 2's new scope carries no "can we even build this" risk — it's
assembly of parts that already exist. Downgrades D4's biggest uncertainty.

## 6. Phase 2 NVMe shrink — numbers verified (read-only)

`resize2fs -P /dev/nvme0n1p1` (read-only estimate): **minimum 4,857,478 blocks ×
4 KiB ≈ 18.5 GB**. Current: 35 GB used of 119 GB; 26.3 M free blocks. GPT is a single
`APP` partition filling the disk (sectors 40 → 250066983; only 2,664 sectors free at
tail).

**Verdict:** the plan's target — shrink p1 to 50 GB, carve p2 (50 GB) + p3 (~17 GB) —
is **comfortably feasible**: 50 GB is ~2.7× the 18.5 GB floor and well above the 35 GB
in use, so the shrink has wide margin. Confirms Phase 2 geometry is sound before any
surgery. (Actual shrink runs offline from the rescue initrd per D4; `resize2fs` here
is 1.44.1, the focal-era version that will do the real resize too.)

## Net effect on the plan

| Item | Before tonight | After |
|---|---|---|
| Audio port (unknown #3) | unscoped | bounded, medium-low, 7-12 ev (audio doc) |
| Locomotion Humble port | ~20-25 ev, feared | **mostly a non-problem** — LCM binary; ROS work is in cyberdog_ros2 decision layer |
| Keystone `.so` on focal | assumed copy-forward OK | **corrected**: glibc OK but it's Foxy-ABI-bound → needs Foxy side-by-side or consumer replacement (walking unaffected) |
| defconfig gaps | audio only | audio **+ CAN_RAW/SocketCAN** (newly caught) |
| 8821cu | plan-listed | build-ready, actively maintained |

Two would-be Phase-5 surprises (silent `CAN_RAW` gap; keystone glibc) caught at zero
cost tonight. The single biggest feared work item (locomotion port) is substantially
smaller than budgeted. Working artifacts under `~/cyberdog-scoping/`; nothing on the
dog was modified.
