# CyberDog Phase 0 Forensics — Analysis Summary

*Captured 2026-04-23 on live `k91` before any modifications.*

## Closed-source library dependency graph

| Closed lib | Cloud endpoints found | Consumers | Decision |
|---|---|---|---|
| `libaivs_sdk.so` | 108 | `libaudio_assistant`, `libaudio_config` only | **DROP** (cloud-bound) |
| `libaudio_assistant.so` | 69 | `athena_audio`, `libaudio_interaction` | **DROP** |
| `libaudio_base.so` | 2 | `libaudio_{assistant,interaction}` | **DROP** |
| `libaudio_config.so` | 26 | `libaudio_assistant` | **DROP** |
| `libaudio_interaction.so` | 49 | `athena_audio` | **DROP** |
| `libbody_detect_api.so` | 2 | `athena_camera/maincamera` only | **REPLACE** with YOLOv8-pose / MediaPipe |
| `libContentMotionAPI.so` | **0** | `libbody_detect_api` only (scope-limited) | **Drop with body_detect_api** |
| `libathena_touch_core.so` | **0** | `athena_touch` only (small scope) | **COPY-FORWARD** |
| `libathena_utils_core.so` | **0** | **20+ binaries (keystone)** | **COPY-FORWARD — critical** |
| `libapp_server_core.a` | (static) | **No .so consumers** (standalone binary) | **DROP** (replaced by Foxglove) |

### Keystone: `libathena_utils_core.so`

Consumed by: `athena_body_state`, `athena_camera/maincamera`, `athena_decisionmaker`, `athena_led`, `athena_lightsensor`, `athena_obstacle_detection`, `athena_scene_detection`, `athena_touch`, `athena_tracking`, `interactive`, `libdecisionmaker_core`, `libdecisionutils`, `librtabmap_plugins`, `librtabmap_sync`, `move_base_node`, `ov_msckf/ros_subscribe_msckf`, `libaudio_assistant`, `libaudio_interaction`.

The fact this library has **zero cloud endpoints** means it's pure-local utility/helper code. Copy-forward across glibc 2.27→2.31 is the expected path. Verify with `readelf -V` versioned-symbol check in a JP5 chroot during Phase 5.

> **Correction 2026-07-09.** "Zero cloud endpoints / pure-local" was about *network*
> behavior and is correct — but it does **not** make this lib a clean copy-forward.
> A NEEDED audit shows `libathena_utils_core.so` links **ROS 2 Foxy** ABI
> (`librclcpp`, `librcl`, `librclcpp_lifecycle`), which breaks against Humble. glibc
> is fine; the ROS ABI is the gate. See
> [PHASE1_OFFDEVICE_SCOPING_2026-07-08.md](./PHASE1_OFFDEVICE_SCOPING_2026-07-08.md)
> §2 for the corrected analysis and the keystone-disposition options.

### Clean-path insight for locomotion

Walking depends on `chassis_node`, `cyberdog_motor_sdk`, `cyberdog_locomotion`. None of these link any closed `lib*audio*`, `libaivs_sdk`, `libbody_detect_api`, `libContentMotionAPI`. **Locomotion is open-path** — no reverse-engineering required to walk the dog on Humble.

## Hardware map (confirmed)

- **eMMC partitions** (14 GPT, A/B layout for kernel/DTB/bootctrl slots). `/params` at p12 (268 MB, factory calibration) is the irreplaceable one.
- **NVMe** rootfs on `nvme0n1p1` (117 GB, 13 GB used).
- **CAN** `can0` up at 1 Mbit/s (12 motor bus).
- **I²C** 8 buses, populated at known addresses (see forensics/layer0/i2c-devices-sysfs.txt).
- **6 `/dev/video*`** devices (stereo pair + RGB + RealSense sub-devices).
- **3 USB-serial MCUs** (head/body/rear STM32).
- **Live kernel**: 4.9.201-tegra, L4T r32.5.2.

## Software inventory

- **2449 installed packages total**
- **38 CyberDog/NVIDIA-flavored packages** (see forensics/layer0/dpkg-cyberdog.txt)
- **athena-ros2**: 8 484 files — the bulk of the closed stack
- **athena-foxy-lib**: 19 954 files — ROS 2 Foxy bundled libs
- **269 ELF binaries** under `/opt/ros2/cyberdog/` analyzed
- **161 .msg / 37 .srv / 12 .action** ROS 2 interfaces defined
- **242 unique NEEDED shared libs** across the whole stack

## Kernel `.config` reconstruction

`/proc/config.gz` extracted — 6 504 lines. Contains the full authoritative set of `CONFIG_*` options Xiaomi shipped. This directly closes zbwu `athena_l4t_sdk` Issue #1 (missing `athena_defconfig`). Base for the r35.6.2 defconfig synthesis in Phase 3.

## Device tree

`dtc -I fs -O dts /proc/device-tree` → 9 396 lines. Contains every bus, sensor node, GPIO mapping, interrupt wire, clock, regulator. This is the authoritative hardware spec for porting to the r35.6.2 DTB.

## What's still pending (needs sudo + external USB SSD)

- Layer 0: `dd` of `/dev/mmcblk0p12` (`/params` partition) — factory calibration
- Layer 0: Wi-Fi credentials from `/etc/NetworkManager/system-connections/` (root-readable)
- Layer 1: `dpkg-repack` of every `athena-*` package
- Layer 2: full rootfs `tar` → external USB
- Layer 3: `dd` of each `/dev/mmcblk0p{1..14}` → external USB
- Rescue drill on x86 host (losetup + qemu-aarch64 chroot)
- Non-destructive `LABEL second` boot test on `/boot/extlinux/extlinux.conf`

## Biggest positive finding

The keystone utility lib has **zero cloud endpoints**. Combined with the clean locomotion path, this means **the minimum-viable walking dog on Humble does not require reverse-engineering any closed code** — only copying `libathena_utils_core.so` forward and replacing the audio/AI/body stacks with open alternatives.

## Captures are at

`/home/mi/cyberdog-forensics-2026-04-22/`:

- `layer0/` — kernel config, device tree, dmesg, dpkg, systemd units, i2c device map, boot files (~1 MB)
- `symbol-graph/` — 269 per-binary `readelf -d` + `ldd` + `nm -D` files (~3 MB)
- `strings-scan/` — endpoint search + top-500 strings per closed lib (~3 MB)

Total: 7.8 MB. All non-destructive, all readable without sudo.
