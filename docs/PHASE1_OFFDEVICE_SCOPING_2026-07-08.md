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

## 2. Closed-`.so` glibc forward-compat pre-check (was deferred to Phase 5)

Ran `objdump -T` for the max symbol versions each keystone closed lib requires.
Target focal provides **glibc 2.31** and **libstdc++ GLIBCXX_3.4.28 / CXXABI_1.3.11**.

| Closed lib | Max GLIBC | Max GLIBCXX | Max CXXABI | Copy-forward to focal? |
|---|---|---|---|---|
| `libathena_utils_core.so` (keystone, 20+ consumers) | 2.17 | 3.4.21 | 1.3.x | ✅ **SAFE** (needs ≤ 2.17 / 3.4.21 ≪ focal's 2.31 / 3.4.28) |
| `libathena_touch_core.so` | 2.17 | 3.4 | 1.3.8 | ✅ **SAFE** |
| `libContentMotionAPI.so` | 2.27 | 3.4.21 | — | ✅ SAFE (being dropped anyway) |

**Result: the keystone copy-forward assumption is now positively verified, not just
hoped.** All required symbol versions sit comfortably below focal's. The Phase 5
`readelf -V` chroot check remains as final confirmation, but the risk is retired
early — the minimum-viable walking dog's one hard closed-lib dependency
(`libathena_utils_core.so`) will load on Ubuntu 20.04.

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

## Net effect on the plan

| Item | Before tonight | After |
|---|---|---|
| Audio port (unknown #3) | unscoped | bounded, medium-low, 7-12 ev (audio doc) |
| Locomotion Humble port | ~20-25 ev, feared | **mostly a non-problem** — LCM binary; ROS work is in cyberdog_ros2 decision layer |
| Keystone `.so` on focal | assumed OK | **verified OK** (glibc 2.17 ≪ 2.31) |
| defconfig gaps | audio only | audio **+ CAN_RAW/SocketCAN** (newly caught) |
| 8821cu | plan-listed | build-ready, actively maintained |

Two would-be Phase-5 surprises (silent `CAN_RAW` gap; keystone glibc) caught at zero
cost tonight. The single biggest feared work item (locomotion port) is substantially
smaller than budgeted. Working artifacts under `~/cyberdog-scoping/`; nothing on the
dog was modified.
