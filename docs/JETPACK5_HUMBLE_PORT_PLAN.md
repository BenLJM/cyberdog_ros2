# CyberDog 1 → JetPack 5.1.x / Ubuntu 20.04 / ROS 2 Humble Port

> Living plan for porting a 2021 Xiaomi CyberDog 1 (Jetson Xavier NX, board `k91`) from the stock **JetPack 4.5.1 / L4T r32.5.2 / Ubuntu 18.04 / ROS 2 Foxy** firmware to a modern **JetPack 5.1.5 / L4T r35.6.2 / Ubuntu 20.04 / ROS 2 Humble** stack with an open voice pipeline and Foxglove-based remote UI.

---

## Table of contents

- [1. Context & goals](#1-context--goals)
- [2. Hard constraints](#2-hard-constraints)
- [3. Hardware map](#3-hardware-map)
- [4. Current software inventory](#4-current-software-inventory)
- [5. Community foundations](#5-community-foundations)
- [6. Top-3 project-killing unknowns](#6-top-3-project-killing-unknowns)
- [7. Bricking-risk map](#7-bricking-risk-map)
- [8. Phase 0 — Backups & forensics](#8-phase-0--backups--forensics)
- [9. Phase 1 — x86 host dev environment](#9-phase-1--x86-host-dev-environment)
- [10. Phase 2 — NVMe dual-rootfs via extlinux LABEL](#10-phase-2--nvme-dual-rootfs-via-extlinux-label)
- [11. Phase 3 — L4T r35.6.2 BSP build](#11-phase-3--l4t-r3562-bsp-build)
- [12. Phase 4 — First JP5 boot](#12-phase-4--first-jp5-boot)
- [13. Phase 5 — Hardware bring-up](#13-phase-5--hardware-bring-up)
- [14. Phase 6 — ROS 2 Humble + locomotion port](#14-phase-6--ros-2-humble--locomotion-port)
- [15. Phase 7 — Perception, Nav2, teleop](#15-phase-7--perception-nav2-teleop)
- [16. Phase 8 — Voice stack replacement](#16-phase-8--voice-stack-replacement)
- [17. Phase 9 — Phone-app replacement](#17-phase-9--phone-app-replacement)
- [18. Phase 10 — Polish & auto-start](#18-phase-10--polish--auto-start)
- [19. Critical files to modify/create](#19-critical-files-to-modifycreate)
- [20. Project-level verification](#20-project-level-verification)
- [21. Git strategy](#21-git-strategy)
- [22. Open questions](#22-open-questions)
- [23. References](#23-references)

---

## 1. Context & goals

The target is a Xiaomi CyberDog 1 (2021), board codename `k91`, running NVIDIA Jetson Xavier NX (Tegra194, 8 GB). Stock firmware is **JetPack 4.5.1 / L4T r32.5.2 / Ubuntu 18.04 (Lubuntu desktop) / ROS 2 Foxy**, installed via Xiaomi's proprietary `athena-*` .deb packages from an OTA channel that is no longer publicly served.

Xiaomi ended the public CyberDog roadmap in 2022; the XiaoAi cloud voice service and the phone app's gRPC backend depend on services that are unreliable or dead. The goal is to modernize to **JetPack 5.1.5 / L4T r35.6.2 / Ubuntu 20.04 / ROS 2 Humble**, with XiaoAi replaced by an openWakeWord + whisper.cpp + OpenAI + Kokoro-TTS pipeline, and the phone app replaced by Foxglove Studio + a thin custom web UI over rosbridge.

**Xavier NX cannot run Ubuntu 22.04.** JetPack 6 is Orin-only. L4T r35.6.2 (Ubuntu 20.04) is the ceiling.

**Intended outcome.** Ubuntu 20.04 + ROS 2 Humble boots on a second partition of the internal NVMe. All 12 leg motors walk; all MIPI-CSI, USB, and I2C sensors work; the 3 head/body/rear STM32 MCUs communicate; Nav2 autonomy works; voice works end-to-end with a modern LLM backend; Foxglove replaces the phone app. Rollback to the factory JP4.5.1 image is always one `reboot` + extlinux label selection away.

**Calendar estimate.** **4–6 months** at nightly cadence (~3 hrs weeknights + ~6 hrs weekend days = ~27 hrs/week). Most schedule slack absorbs Phase 3 (kernel rebase) and Phase 5 (hardware bring-up).

## 2. Hard constraints

- **No physical disassembly.** The NVMe is behind a sealed enclosure with ribbon cables. Rollback must be software-only. Corrupted eMMC bootloader = unrecoverable without opening = brick.
- **x86_64 Ubuntu 22.04 host PC required** for flashing, cross-compile, and rescue (NVIDIA's tools are x86-only).
- **External USB SSD ≥256 GB** for backup storage (three layers of redundancy for critical data).
- **LLM provider**: OpenAI (API key stored in `/etc/cyberdog/llm.env`, root-only).
- **Target ROS 2 distro**: Humble Hawksbill (source-built on Ubuntu 20.04).
- **Voice**: bilingual English + Chinese via Kokoro TTS.

## 3. Hardware map

Derived from live inspection of the running system and the `tegra194-mi-k91` device tree.

| Subsystem | Interface | Chip / device |
|---|---|---|
| 12 leg motors | CAN (`can0`, 1 Mbit/s) | MIT-Cheetah-style brushless drivers |
| 3 peripheral MCUs (head / body / rear) | USB-serial | STM32 |
| Main IMU | I²C bus 4 @ 0x68 | Bosch BMI160 |
| Stereo SLAM cameras (×2) | MIPI-CSI | OmniVision OV7251 (VGA global-shutter) |
| Main RGB camera | MIPI-CSI | OmniVision OV13B10 (13 MP) |
| Depth camera | USB3 | Intel RealSense D430i |
| Audio amp | I²C bus 0 @ 0x2c | TI TAS5805M |
| Audio codec | I²C bus 0 @ 0x2d | Realtek RT5680 |
| BMS telemetry | I²C bus 7 @ 0x40 | TI INA3221 (3-channel current/voltage) |
| GPIO expanders | I²C bus 0 @ 0x22, 0x23 | TI TCA6424 ×2 |
| Touch sensor | I²C bus 8 @ 0x20 | DSX (custom) |
| PMIC | I²C bus 4 @ 0x3c | Maxim MAX20024 |
| TOF sensors | GPIO-gated | *TBD, confirmed present in DTB* |

**eMMC partition map** (`/dev/mmcblk0`, 16 GB, 14 GPT partitions):

| # | Name | Size | Notes |
|---|---|---|---|
| 1 | APP | 1.6 GB | Stock rootfs (unused — rootfs is actually on NVMe) |
| 2, 3 | kernel, kernel_b | 67 MB each | A/B kernel image slots |
| 4, 5 | kernel-dtb, kernel-dtb_b | 459 KB each | A/B DTB slots |
| 6 | recovery | 66 MB | Recovery kernel |
| 7 | recovery-dtb | 524 KB | Recovery DTB |
| 8, 9 | kernel-bootctrl, kernel-bootctrl_b | 262 KB each | A/B boot-control metadata |
| 10 | RECROOTFS | 315 MB | Recovery rootfs |
| 11 | misc | 268 MB | |
| 12 | **params** | 268 MB | **Factory calibration — irreplaceable** |
| 13 | swap | 12.9 GB | |
| 14 | UDA | 209 MB | User data area |

**NVMe** (`/dev/nvme0n1p1`, 117 GB, 13 GB used): the actual rootfs.

## 4. Current software inventory

Xiaomi's additions on top of stock NVIDIA L4T r32.5.2 ship as 6 `.deb` packages installed out-of-band:

| Package | Version | Role |
|---|---|---|
| `athena-ros2` | 1.0.173 | **The entire `/opt/ros2/cyberdog/` ROS 2 Foxy userspace** — 20+ nodes, Nav2 stack, closed `.so` libs |
| `athena-foxy-lib` | 1.0.7 | Supporting libs |
| `athena-sys-config` | 1.0.11 | systemd services, udev, `/etc/mi/` |
| `athena-ota-server` | 1.0.5 | OTA endpoint |
| `athena-factory-tool` | 1.0.16 | Factory test utility |
| `athena-version` | 1.0.0.94 | Version stamp |

**Closed-source proprietary libraries** (inside `athena-ros2`, not in any public repo):

- `libaivs_sdk.so` — XiaoAi voice SDK (cloud-dependent; backend likely dead)
- `libaudio_assistant.so`, `libaudio_base.so`, `libaudio_config.so`, `libaudio_interaction.so` — audio stack
- `libbody_detect_api.so` — person detection
- `libContentMotionAPI.so` — gesture / trick motion API
- `libathena_touch_core.so` — touch sensor driver
- `libapp_server_core.a` (static) + `app_server` binary — gRPC server the phone app connects to

Live `athena_*` package names on disk correspond to the pre-migration internal naming; the public repo uses the newer `cyberdog_*` prefix (per [architecture wiki](https://github.com/MiRoboticsLab/cyberdog_ros2/wiki/%E9%93%81%E8%9B%8BROS-2%E8%BD%AF%E4%BB%B6%E6%9E%B6%E6%9E%84-%7C-ROS-2-Software-Architecture-of-CyberDog)).

## 5. Community foundations

| Repo | Purpose | State |
|---|---|---|
| [zbwu/athena_l4t_sdk](https://github.com/zbwu/athena_l4t_sdk) (branch `athena_l4t-r35.1`) | L4T r35.1 BSP for `tegra194-mi-k91`: kernel 5.10, bootloader, DTB, build/flash scripts | Sole author zbwu, last commit Aug 2022. Two unresolved issues (#1 missing `athena_defconfig`, #2 motion controller gap) |
| [zbwu/cyberdog_misc](https://github.com/zbwu/cyberdog_misc) | `bms/`, `locomotion_wrapper/`, `mcu_proto/`, `usb_adapter/`, `parameters/` — low-level userspace glue | MIT, C + Python |
| [MiRoboticsLab/cyberdog_motor_sdk](https://github.com/MiRoboticsLab/cyberdog_motor_sdk) | 12-motor CAN SDK, source, Docker cross-compile | Official, small |
| [MiRoboticsLab/cyberdog_locomotion](https://github.com/MiRoboticsLab/cyberdog_locomotion) | Gait controller, fork of MIT Cheetah Software | Official, ROS 2 **Galactic** — needs Humble port |
| [MiRoboticsLab/cyberdog_ws](https://github.com/MiRoboticsLab/cyberdog_ws) | Aggregator meta-repo, `vcs import` driver | v1.3.0 (Jan 2024) — latest actively-maintained Xiaomi work |
| [MiRoboticsLab/cyberdog_ros2](https://github.com/MiRoboticsLab/cyberdog_ros2) | Most `cyberdog_*` packages | Foxy; **missing the ~10 closed `.so` files** |
| [MiRoboticsLab/cyberdog_vision](https://github.com/MiRoboticsLab/cyberdog_vision), [_miloc](https://github.com/MiRoboticsLab/cyberdog_miloc), [_simulator](https://github.com/MiRoboticsLab/cyberdog_simulator) | Vision, Visual SLAM, simulator | Open |

**Voice replacement stack:**

| Role | Component | License | Notes |
|---|---|---|---|
| Wake-word | [openWakeWord](https://github.com/dscripka/openWakeWord) | MIT | "Hey CyberDog" custom model possible |
| STT | [whisper.cpp](https://github.com/ggml-org/whisper.cpp) + [whisper_trt](https://github.com/NVIDIA-AI-IOT/whisper_trt) | MIT | `small` model, CUDA / TRT-accelerated |
| LLM | OpenAI Chat Completions (streaming) | proprietary API | Key in `/etc/cyberdog/llm.env` |
| TTS | [Kokoro TTS](https://github.com/nazdridoy/kokoro-tts) | Apache-2 | 82 M params, en + zh bilingual, 210× realtime on GPU |

**Remote UI:** [Foxglove Studio](https://github.com/foxglove/studio) + [rosbridge_suite](https://github.com/RobotWebTools/rosbridge_suite) + thin React/Vite web UI hosted on-dog via caddy.

## 6. Top-3 project-killing unknowns

De-risk all three in Phase 0 before any destructive step.

1. **Bootloader A/B slot behavior.** CyberDog's custom cboot may tie eMMC kernel A/B selection to ignore extlinux `LABEL` fallback. If `LABEL second` in `/boot/extlinux/extlinux.conf` does not actually influence boot, the entire dual-rootfs plan collapses. **Mitigation:** non-destructively add `LABEL second` pointing at the *same known-good JP4.5 kernel* and verify boot-menu selection works.
2. **Closed-source `.so` dependency graph.** If `libContentMotionAPI.so` or `libathena_touch_core.so` is in `cyberdog_locomotion`'s runtime path (not just app-facing surfaces), the Humble port stalls until reverse-engineering or stubbing is done. **Mitigation:** run `ldd` + `readelf -d` + `nm -D` across every binary under `/opt/ros2/cyberdog/` during Phase 0 to build a full symbol graph *before any write*. Also `strings` each blob for Xiaomi cloud endpoints — some are cloud-dependent and unusable regardless.
3. **Missing `athena_defconfig`** (zbwu Issue #1, unresolved 16 months). **Mitigation:** the running kernel exposes `/proc/config.gz` (`CONFIG_IKCONFIG_PROC=y` is on). Snapshot this plus `/sys/firmware/devicetree/base` via `dtc`. Diff against NVIDIA's stock r35.6.2 `tegra_defconfig` to synthesize the CyberDog-specific delta (BMI160_I2C, TCA6424A, MAX20024 regulator, TAS5805M, RT5680, INA3221, VL53L1X TOF, OV7251/OV13B10 cameras). This closes Issue #1 and gives a buildable kernel.

## 7. Bricking-risk map

"Brick" = unrecoverable without opening the chassis.

| Phase | Risk | Notes |
|---|---|---|
| **0** Backup | Low | Pure reads. Only risk: inconsistent tarball if ROS 2 keeps writing state — stop services during Layer 2 dump. |
| **1** x86 env | None | Host-only. |
| **2** NVMe partition surgery + `extlinux.conf` | **High** | First meaningful brick risk. Serial console (`ttyTCU0`) wired before touching anything. **Never write to eMMC partitions in this phase.** |
| **3** Kernel rebase | None | Host-only artifacts. |
| **4** First JP5 boot | **High** | Bad initrd or missing `nvme`/`ext4` driver → kernel panic. Mitigation: bake critical drivers `=y`. Serial console attached. |
| **5** CAN + motors | Medium physical | Motor misbehavior → physical danger. **Dog on a stand, legs off ground, every session.** Not a software brick. |
| **6–10** Humble + voice + UI | Low | Software-only; rollback = reboot + LABEL primary. |

## 8. Phase 0 — Backups & forensics

**Layers produced on external USB SSD** `/media/backup/cyberdog-2026-04/`:

```text
layer0/                                 # golden, ~5 MB, triple-redundant
  params-emmc-p12.img                   # dd of /dev/mmcblk0p12 — IRREPLACEABLE factory calibration
  ssh-keys.tar.gz
  wifi-creds.tar.gz                     # /etc/NetworkManager/system-connections/
  xiaomi-device-id.txt
  proc-config.gz                        # live kernel .config (closes zbwu Issue #1)
  dtb-live.dts                          # dtc -I fs -O dts /proc/device-tree
  lsmod.txt, dmesg-boot.log
  lspci.txt, lsusb.txt
  i2cdetect-bus{0..8}.txt
  symbol-graph.json                     # ldd + readelf -d + nm -D across athena_* binaries
  strings-scan.txt                      # grep for cloud endpoints in closed .so

layer1/                                 # CyberDog-specific software, ~1.5 GB
  cyberdog-debs/                        # dpkg-repack athena-ros2, athena-foxy-lib, athena-sys-config,
                                        #                athena-ota-server, athena-factory-tool, athena-version
  opt-ros2-cyberdog.tar.zst             # full /opt/ros2/cyberdog/ incl. closed .so
  boot-jp4.tar.zst                      # /boot/{Image,initrd,dtb/*}

layer2/rootfs-nvme.tar.zst              # full / tar, ~10–12 GB compressed, xattrs+acls preserved

layer3/                                 # eMMC block-level, ~8 GB compressed
  emmc-full.img.zst                     # dd of /dev/mmcblk0 entire (fallback)
  emmc-parts/p01..p14.img               # per-partition dumps for surgical restore
  gpt.bin                               # sgdisk --backup

layer4/                                 # factory-reset path from bare silicon, ~6 GB
  jp4.5.1-bsp/                          # NVIDIA Jetson-210_Linux_R32.5.1_aarch64.tbz2,
                                        #   Tegra_Linux_Sample-Root-Filesystem_R32.5.1_aarch64.tbz2
  xiaomi-flashall.tgz                   # Xiaomi's athena_foxy_*_emmc_nvme_V*.tgz + flashall.sh
                                        #   (per https://github.com/MiRoboticsLab/cyberdog_ros2/wiki/
                                        #    %E5%A6%82%E4%BD%95%E7%BA%BF%E5%88%B7%E9%93%81%E8%9B%8B)
```

**Rescue drill (non-negotiable).** Before Phase 2 starts: on x86 host, `losetup` the Layer 2 tarball onto a scratch image, chroot via `qemu-aarch64-static`, confirm `/etc/os-release` reads correctly. Write the steps down. Projects that skip this regret it.

**Recovery mode trigger** (per Xiaomi's flashing wiki): `sudo reboot --force forced-recovery` from the live dog, OR boot with the proprietary black USB cable pre-connected. Verify with `lsusb` on the x86 host showing `0955:7e19` NVIDIA APX.

**Key sub-tasks**

1. Mount USB SSD (≥256 GB, ext4, `fstrim`).
2. `sudo dd if=/dev/mmcblk0p12 of=layer0/params-emmc-p12.img bs=1M conv=fsync`, sha256, replicate to 2nd medium + cloud.
3. `zcat /proc/config.gz > layer0/proc-config.gz`; `dtc -I fs -O dts -o layer0/dtb-live.dts /proc/device-tree`.
4. Build symbol graph:

   ```bash
   find / \( -path '*athena*' -o -path '*cyberdog*' -o -path '*libaivs*' \
             -o -path '*libaudio_*' -o -path '*libbody_*' \) -name '*.so*' -print0 \
     | xargs -0 -I{} sh -c 'readelf -d "{}"; ldd "{}"; nm -D --defined-only "{}"'
   ```

5. `dpkg -l | grep -E 'cyberdog|athena|mi-'` → feed to `dpkg-repack` loop.
6. Stop ROS 2 + docker + timers. `sudo tar --xattrs --acls --numeric-owner -I 'zstd -T0 -19' -cf layer2/rootfs-nvme.tar.zst --exclude={/proc,/sys,/dev,/tmp,/run,/mnt,/media,/var/cache/apt/archives} /`.
7. `sudo dd if=/dev/mmcblk0 bs=4M status=progress | zstd -T0 > layer3/emmc-full.img.zst`; also `sgdisk --backup=layer3/gpt.bin /dev/mmcblk0`.
8. Per-partition loop: `for i in $(seq 1 14); do sudo dd if=/dev/mmcblk0p$i of=layer3/emmc-parts/p$(printf %02d $i).img bs=1M conv=fsync; done`.
9. On x86: mirror NVIDIA JP4.5.1 BSP + Xiaomi's latest public `athena_foxy_*_emmc_nvme_V*.tgz` (if still available); tag under a named release dir.
10. Rescue drill (above).
11. **Non-destructive bootloader test**: append a harmless `LABEL second` to `/boot/extlinux/extlinux.conf` pointing at the *same current* `Image`/`initrd`. Reboot, type `second` at prompt, confirm identical `uname`. Reboot again, let timeout → `primary`. Proves the dual-boot mechanism before Phase 2 depends on it.

**Verification gate**

- `sha256sum` matches across 3 copies of `layer0/params-emmc-p12.img`.
- `tar -tf layer2/rootfs-nvme.tar.zst | wc -l` ≥ 350,000 entries.
- `zstd -t layer3/emmc-full.img.zst` passes.
- Rescue-drill chroot prints valid `/etc/os-release`.
- `LABEL second` boot test passes.

**Rollback.** N/A — no writes to dog except the harmless extlinux entry (restore from saved copy if needed).

**Time: ~6 evenings (18 hrs).** `dd` + `tar` are IO-bound on USB-3; run overnight.

## 9. Phase 1 — x86 host dev environment

On Ubuntu 22.04 host:

- Install NVIDIA SDK Manager; pull JetPack 5.1.5 (L4T r35.6.2).
- Fork all repos under the owner's GitHub and clone pinned:
  - `<user>/athena_l4t_sdk` (fork of zbwu), branch `cyberdog-humble-r35.6.2` off `athena_l4t-r35.1`.
  - Submodule forks: `<user>/athena_l4t_kernel`, `athena_l4t_nvidia`, `athena_l4t_jakku_dts`.
  - `cyberdog_misc`, `cyberdog_motor_sdk`, `cyberdog_locomotion`, `cyberdog_ros2`, `cyberdog_ws`.
- Build Docker image `cyberdog-builder:r35.6` with `aarch64-linux-gnu-gcc-9/11`, `bison flex libssl-dev bc device-tree-compiler dtc`, ROS 2 Humble source-build deps.
- Install Xiaomi flashing prereqs on host: `sudo apt install device-tree-compiler nfs-common sshpass abootimg network-manager libxml2-utils`.
- `MANIFEST.yaml` records exact commit hashes of all repos.

**Verification.** `docker run cyberdog-builder:r35.6 aarch64-linux-gnu-gcc --version` prints 9.x/11.x; stock `tegra_defconfig` kernel builds clean.

**Time: ~3 evenings (9 hrs).**

## 10. Phase 2 — NVMe dual-rootfs via extlinux LABEL

**The trick that makes this safe:** keep eMMC bootloader + kernel partitions entirely untouched. Shrink `nvme0n1p1` from 117 → 50 GB, create `nvme0n1p2` (50 GB, JP5 rootfs) and `nvme0n1p3` (~17 GB, `/data` shared). Store the new JP5 kernel at `/boot-jp5/` **inside the still-working JP4.5 rootfs on p1**, so extlinux on p1 loads either:

- `LABEL primary` → `/boot/Image` (JP4.5) + `root=UUID=<p1>` → unchanged CyberDog.
- `LABEL second`  → `/boot-jp5/Image` (JP5) + `root=UUID=<p2>` → new system.

This keeps the Xiaomi bootloader chain completely untouched. Rollback = reboot + select `primary`.

**Critical files**

- `/boot/extlinux/extlinux.conf` — the pivot point
- `/boot-jp5/{Image,initrd,dtb/tegra194-mi-k91.dtb}` on p1 — staged JP5 kernel
- `/etc/fstab` on p2 — mounts p2 as `/`, p3 as `/data`

**Sub-tasks**

1. Stop ROS 2 + docker; ideally boot single-user.
2. `e2fsck -f /dev/nvme0n1p1`; `resize2fs /dev/nvme0n1p1 45G`; `parted` shrink p1 to 50 GB, create p2 and p3.
3. `mkfs.ext4 -L JP5_ROOT /dev/nvme0n1p2`; `mkfs.ext4 -L DATA /dev/nvme0n1p3`.
4. `mkdir /boot-jp5` on p1. Populate initially with a **copy of the current JP4.5 kernel** so `LABEL second` boots the *same* rootfs as `LABEL primary` — proves the dual-boot mechanism before JP5 is introduced.
5. Update `/boot/extlinux/extlinux.conf`; keep backup at `/boot/extlinux/extlinux.conf.pre-jp5`.
6. Reboot, select `second`, verify identical `uname`. Reboot, let timeout → `primary`.

**Verification.** `lsblk` shows p1 / p2 / p3. Both labels boot successfully. UUIDs recorded in `MANIFEST.yaml`.

**Rollback.** Restore `extlinux.conf.pre-jp5`. If extlinux itself is broken, fall back to Phase 0 Layer 3 restore via USB-OTG force-recovery from x86 host — USB-serial cable on `ttyTCU0` stays connected throughout this phase.

**Time: ~2 evenings (6 hrs).** Schedule on a night with the next full day free.

**Fallback if extlinux LABEL ignored:** use eMMC A/B via `nvbootctrl set-active-boot-slot 1`. Higher bricking risk (bad slot B + bad rollback counter can lock the device); use only if Phase 0 non-destructive test fails.

## 11. Phase 3 — L4T r35.6.2 BSP build

**Decision: rebase to r35.6.2, not zbwu's stale r35.1.** ~60 security/kernel fixes since r35.1; zbwu's branch is 20 months stale; starting a fork 20 months behind compounds maintenance cost forever.

**Deliverables**

- Fork branches `cyberdog-humble-r35.6.2` in all four `athena_l4t_*` repos.
- `patches/` directories capturing zbwu's deltas vs upstream r35.1, rebased onto r35.6.2.
- **Synthesized `athena_defconfig`** from Phase 0 `/proc/config.gz` diffed against r35.6.2 `tegra_defconfig`. CyberDog-specific `CONFIG_*`:
  - `CONFIG_IIO_BMI160_I2C=y` (IMU)
  - `CONFIG_GPIO_TCA6424=y` (GPIO expander)
  - `CONFIG_REGULATOR_MAX20024=y` (PMIC)
  - `CONFIG_SND_SOC_TAS5805M=y` (audio amp)
  - `CONFIG_SND_SOC_RT5680=y` (codec)
  - `CONFIG_SENSORS_INA3221=y` (current monitor)
  - `CONFIG_VL53L1X=y` (TOF) — confirm from live DTB
  - OV7251 / OV13B10 camera drivers (Xiaomi-patched)
  - `CONFIG_CAN_C_CAN_PLATFORM=y`, `CONFIG_CAN_RAW=y` (motor bus)
- Built artifacts: `Image`, `tegra194-mi-k91.dtb`, initrd with critical drivers baked `=y`, out-of-tree `*.ko`, ready for staging to `/boot-jp5/` on the dog.

**Sub-tasks**

1. Via SDK Manager or `source_sync.sh`, clone NVIDIA r35.6.2 kernel + bootloader sources.
2. Extract zbwu deltas: `git format-patch upstream-r35.1..athena_l4t-r35.1` in each submodule.
3. Rebase onto r35.6.2 in fork; resolve conflicts (expect hits in DTB fragments and camera/display drivers).
4. Synthesize `athena_defconfig` per above; commit as `arch/arm64/configs/athena_defconfig` in kernel fork.
5. Build in Docker: `make athena_defconfig && make -j Image dtbs modules`.
6. Package into tarball for staging.

**Verification.** Clean build; `file Image` arm64; DTB decompiles via `dtc`; no missing symbols from `cyberdog_motor_sdk` link.

**Time: ~20–30 evenings (60–90 hrs).** The single biggest phase.

**Risks**

- r35.1 → r35.6.x kernel API churn in out-of-tree drivers (camera subsystem especially). Port one driver at a time.
- Closed NVIDIA blobs (nvdec, nvenc, GPU FW) in `athena_l4t_nvidia` may have ABI changes. Pull fresh from r35.6.2 BSP; do not carry zbwu's forward.
- Missed driver in `athena_defconfig` → Phase 5 hardware fails. Mitigate: enable generously `=m` where unclear.

## 12. Phase 4 — First JP5 boot

**Deliverables.** Ubuntu 20.04 rootfs (JP5's sample rootfs + `apply_binaries.sh`) on `nvme0n1p2`; JP5 kernel + DTB + initrd in `/boot-jp5/` on p1; SSH accessible.

**Sub-tasks**

1. On x86: `sudo Linux_for_Tegra/apply_binaries.sh` → `Linux_for_Tegra/rootfs/`.
2. Transfer to dog: with dog booted into JP4.5 (LABEL primary), `rsync -aAXH Linux_for_Tegra/rootfs/ mi@cyberdog:/mnt/p2/`.
3. Stage kernel + DTB + initrd to `/boot-jp5/` on p1.
4. Edit `/mnt/p2/etc/fstab`: p2 as `/`, p3 as `/data`.
5. Netplan: copy Wi-Fi creds from Layer 0, configure `wlan0` via NetworkManager (20.04 default).
6. Reboot → select `LABEL second` → monitor serial console (`screen /dev/ttyUSB0 115200`). Expect: cboot → kernel load → mount p2 → systemd-journald → `sshd` up.

**Verification.** `ssh mi@cyberdog` on JP5 side works. `uname -r` shows `5.10.x-tegra`. `lsmod` shows expected drivers. `ip a` shows eth0 + wlan0.

**Rollback.** Reboot → `LABEL primary` → fully-working JP4.5.1.

**Time: ~5 evenings (15 hrs).**

## 13. Phase 5 — Hardware bring-up

**Order: CAN → motor SDK → MCUs → BMS → I²C → cameras → audio.** Safety-critical first, passive reads middle, GPU-dependent last.

### 5.1 CAN bus + motor SDK — dog on stand, legs off ground

- `modprobe can_raw c_can`; `ip link set can0 up type can bitrate 1000000`.
- `candump can0` should show motor heartbeat.
- Cross-compile `cyberdog_motor_sdk` in Docker, deploy, run `Example_MotorCtrl`: reads 12 motor positions.

### 5.2 MCU comms

- `usb_adapter` (from `cyberdog_misc`) enumerates 3 USB-serial (`/dev/ttyUSB{0,1,2}` → head/body/rear STM32s).
- `mcu_proto` parses telemetry frames; verify against Phase 0 `dmesg-boot.log` baseline.

### 5.3 BMS

- Reads battery SOC + voltage via MCU protocol; cross-check against INA3221 I²C readings.

### 5.4 I²C sensors

- `i2cdetect -y 0..7` matches Phase 0 baseline. Specifically:
  - `bus 0`: TCA6424 (0x22, 0x23), TAS5805M (0x2c), RT5680 (0x2d)
  - `bus 2`: OV13B10 (0x36), OV7251 ×2 (0x60, 0x61)
  - `bus 4`: MAX20024 (0x3c)
  - `bus 7`: INA3221 (0x40)
  - `bus 8`: DSX touch (0x20)
- `iio` sysfs exposes BMI160 accel/gyro.

### 5.5 Cameras

- `v4l2-ctl --list-devices` shows OV7251 stereo pair, OV13B10, RealSense.
- GStreamer pipeline `nvarguscamerasrc ! fakesink` succeeds for each MIPI-CSI sensor.
- RealSense via librealsense2 for JP5 r35.6.2.

### 5.6 Audio (deep integration deferred to Phase 8)

- `aplay -l` shows TAS5805M card.
- Simple `arecord` / `aplay` loop works.
- ALSA UCM configs ported from JP4.5 `/etc/alsa/`.

### Closed-source `.so` decision matrix

| Blob | Action | Rationale |
|---|---|---|
| `libaivs_sdk.so` | **Drop** | Xiaomi cloud-dependent; backend dead |
| `libaudio_{assistant,base,config,interaction}.so` | **Drop** | Replaced by Phase 8 voice stack |
| `libbody_detect_api.so` | **Replace with YOLOv8-pose or MediaPipe** | Open equivalents match functionality |
| `libContentMotionAPI.so` | **Copy-forward if glibc-compatible, else reverse-engineer** | Likely tied to trick motions (flip, handshake) |
| `libathena_touch_core.so` | **Copy-forward** | Small surface; touch-sensor glue worth preserving |
| `libapp_server_core.a` | **Drop** | Phone app replaced by Foxglove in Phase 9 |

Glibc forward-compat: `ldd --version` on 18.04 (2.27) vs 20.04 (2.31). Most cases work. Verify each with `readelf -V` versioned-symbol check in JP5 chroot.

**Time: ~25–30 evenings (75–90 hrs).**

**Risks**

- Motor runaway — **always on stand, legs off ground.**
- Camera DTB overlays are Xiaomi-specific; live in `athena_l4t_jakku_dts` fork.
- CAN termination / baud mismatch — keep USB-CAN sniffer ready.

## 14. Phase 6 — ROS 2 Humble + locomotion port

**Install strategy: source-build ROS 2 Humble on Ubuntu 20.04.** Tier-3 binary coverage gaps will bite in Nav2 + locomotion; source-build once is faster than firefighting later. `colcon --packages-up-to` for iterative builds.

**Critical files to port**

- `cyberdog_locomotion/src/fsm/FSM_State.cpp` + siblings — Galactic → Humble API shifts.
- `cyberdog_locomotion/launch/*.launch.py` — composable-node API tweaks.
- `cyberdog_motor_sdk` CAN backend — already C++, minimal ROS 2 coupling.

**Galactic → Humble port surface:** `rclcpp` parameter API (typed declarations now required), message header namespace moves, launch composable-node syntax. Budget ~10 evenings for the port alone.

**Restore `/params`:** loopback-mount `layer0/params-emmc-p12.img`, copy camera intrinsics + extrinsics, IMU biases, audio EQ into expected paths on JP5 rootfs.

**Desktop swap (Lubuntu → Ubuntu):** install `xubuntu-desktop` (~1.5 GB lighter than GNOME, better for 8 GB Xavier NX); set as LightDM default; keep LXDE as fallback.

**Smoke test:** dog on stand, `ros2 launch cyberdog_bringup locomotion.launch.py`; stand → trot-in-place → set-down. Record bag for comparison against JP4.5.1 baseline.

**Verification.** `ros2 node list` shows all expected nodes. Trot telemetry matches JP4.5 within 5 % on control-loop rate.

**Time: ~20–25 evenings (60–75 hrs).**

**Risks.** Humble's new executors have different latency profiles — audit MIT Cheetah control loop's `SCHED_FIFO` priorities.

## 15. Phase 7 — Perception, Nav2, teleop

- Nav2 Humble stack (stock).
- `slam_toolbox` with stereo odometry from OV7251 pair or RealSense depth.
- `realsense-ros` Humble branch for D430i.
- `ros2 joy` + `teleop_twist_joy` for an 8BitDo-class gamepad.
- `cyberdog_vision` / `cyberdog_miloc` ported forward (visual SLAM).

**Time: ~8 evenings (24 hrs).** Low brick risk.

## 16. Phase 8 — Voice stack replacement

Pipeline: **mic → openWakeWord ("Hey CyberDog") → VAD → whisper.cpp + TensorRT (`small`) → OpenAI streaming chat → Kokoro TTS (en+zh) → ALSA via TAS5805M → speaker.**

**Critical files (create)**

- `/opt/cyberdog_voice/` — new ROS 2 node
- `/etc/cyberdog/llm.env` — OpenAI API key, root-only (`chmod 600`)
- `/etc/systemd/system/cyberdog-voice.service`

**Time: ~10 evenings (30 hrs).**

**Risks.** TensorRT engine builds are pinned to specific TRT version (8.5 on r35.6.2). Network latency to OpenAI dominates UX — cache common responses.

## 17. Phase 9 — Phone-app replacement

- **Foxglove Studio** (browser + mobile) for visualization + control panels.
- **rosbridge_suite** websocket bridge on the dog.
- Thin custom web UI (React/Vite hosted on-dog via caddy) for one-tap actions: stand, sit, trick-1, trick-2.

**Critical files**

- `/opt/cyberdog_ui/` (static React build)
- `/etc/systemd/system/cyberdog-rosbridge.service`
- `/etc/caddy/Caddyfile`

**Time: ~5 evenings (15 hrs).**

## 18. Phase 10 — Polish & auto-start

- Systemd units for every ROS 2 node, ordered via `After=can0.service cyberdog-mcu.service`.
- Healthchecks publish to `/diagnostics` topic.
- LED status via TCA6424: green ready, amber degraded, red fault.
- OTA-style update mechanism (optional): A/B update of `/boot-jp5/Image` + `nvme0n1p2` contents via rsync.

**Time: ~5 evenings (15 hrs).**

## 19. Critical files to modify/create

**On dog (JP4.5 side, read + minimal writes):**

- `/boot/extlinux/extlinux.conf` — add `LABEL second`, keep `.pre-jp5` backup
- `/boot-jp5/{Image,initrd,dtb/tegra194-mi-k91.dtb}` — staged JP5 kernel (new dir on p1)
- `/dev/nvme0n1p1` — shrunk via `resize2fs` + `parted`
- `/dev/nvme0n1p2` — new JP5 rootfs
- `/dev/nvme0n1p3` — shared `/data`

**On dog (JP5 side, all new):**

- `/etc/fstab` — p2 rootfs + p3 data
- `/etc/cyberdog/` — project config (`llm.env`, `mcu-topology.yaml`, etc.)
- `/opt/cyberdog_voice/`, `/opt/cyberdog_ui/` — new ROS 2 nodes + web UI
- `/etc/systemd/system/cyberdog-*.service` — service units
- `/params-restored/` — calibration files from Layer 0

**On x86 host (forks under user's GitHub):**

- `<fork>/athena_l4t_sdk` branch `cyberdog-humble-r35.6.2`
- `<fork>/athena_l4t_kernel/arch/arm64/configs/athena_defconfig` — synthesized from `/proc/config.gz`
- `<fork>/athena_l4t_jakku_dts/tegra194-mi-k91.dts` — board DTB with Xiaomi sensor nodes
- `<fork>/cyberdog_locomotion/` branch `humble-port`
- `<fork>/cyberdog_ws/` branch `humble-aggregate` — meta-repo
- `~/cyberdog-dev/MANIFEST.yaml` — pinned commit hashes

## 20. Project-level verification

1. **Dual-boot works.** `reboot` then select extlinux `primary` or `second` lands on JP4.5 or JP5 respectively; both fully functional.
2. **Walking.** JP5 side, `ros2 launch cyberdog_bringup locomotion.launch.py`; dog stands, trots in place, walks forward 2 m via gamepad teleop.
3. **Sensors.** All 6 `/dev/video*` devices enumerate; BMI160 IMU publishes `/imu/data_raw` at ≥ 200 Hz; battery SOC publishes `/battery_state`.
4. **Voice.** "Hey CyberDog, sit" → dog sits. OpenAI key never leaves `/etc/cyberdog/llm.env`.
5. **Remote UI.** Phone browser → `http://cyberdog.local:8080` → Foxglove dashboard shows live cameras + gamepad control works.
6. **Rollback drill.** Deliberately corrupt `/etc/fstab` on p2, reboot, select `primary`, JP4.5 boots fine. Fix p2 from JP4.5 side.
7. **Full restore drill (quarterly).** Restore `layer2/rootfs-nvme.tar.zst` to a temporary directory, verify completeness.

## 21. Git strategy

- Fork all four `athena_l4t_*` repos + all `MiRoboticsLab/*` repos under user's GitHub.
- Per repo: branch `cyberdog-humble-r35.6.2` off zbwu's `athena_l4t-r35.1` (or upstream `main` for MiRoboticsLab).
- Cherry-pick zbwu's deltas as `git format-patch` onto r35.6.2 base.
- Each repo has `patches/` directory documenting every non-upstream commit with rationale.
- Tag known-good states: `v0.1-phase2-dualboot`, `v0.2-phase4-first-boot`, `v0.3-phase5-motors`, `v0.4-phase6-walking`, `v1.0-full`.
- Push to private-backup mirror weekly.
- Upstream PRs back to zbwu for `athena_defconfig` synthesis (good-citizen move).

## 22. Open questions

- Whether `libContentMotionAPI.so` is on the locomotion runtime path (determined in Phase 5 via symbol graph).
- Whether the CyberDog bootloader honors extlinux `LABEL` selection (determined in Phase 0 non-destructive test — pivotal).
- Whether r35.6.2 has breaking camera driver ABI changes vs r35.1 (determined in Phase 3).
- Whether OpenAI's streaming latency to Xavier NX's Wi-Fi is acceptable for conversational UX (determined in Phase 8 — fallback is local whisper + shorter cached responses).

## 23. References

- [MiRoboticsLab/cyberdog_ros2](https://github.com/MiRoboticsLab/cyberdog_ros2) — this repo's upstream
- [MiRoboticsLab/cyberdog_ros2 wiki — Flashing Guide](https://github.com/MiRoboticsLab/cyberdog_ros2/wiki/%E5%A6%82%E4%BD%95%E7%BA%BF%E5%88%B7%E9%93%81%E8%9B%8B)
- [MiRoboticsLab/cyberdog_ros2 wiki — ROS 2 Software Architecture](https://github.com/MiRoboticsLab/cyberdog_ros2/wiki/%E9%93%81%E8%9B%8BROS-2%E8%BD%AF%E4%BB%B6%E6%9E%B6%E6%9E%84-%7C-ROS-2-Software-Architecture-of-CyberDog)
- [MiRoboticsLab/cyberdog_ros2 wiki — DDS Local/Multicast](https://github.com/MiRoboticsLab/cyberdog_ros2/wiki/CyberDog-DDS%E6%9C%AC%E5%9C%B0%E5%8F%8A%E5%A4%9A%E6%92%AD%E8%AE%BE%E7%BD%AE)
- [MiRoboticsLab/cyberdog_ros2 wiki — Build from source](https://github.com/MiRoboticsLab/cyberdog_ros2/wiki/%E4%BB%8E%E6%BA%90%E7%A0%81%E5%AE%89%E8%A3%85ROS-2-%7C-Building-ROS-2-from-source)
- [MiRoboticsLab/cyberdog_ros2 wiki — Docker build](https://github.com/MiRoboticsLab/cyberdog_ros2/wiki/%E4%BD%BF%E7%94%A8Docker%E6%9E%84%E5%BB%BA%E9%93%81%E8%9B%8B%E9%A1%B9%E7%9B%AE-%7C-Building-CyberDog-Projects-with-Docker)
- [zbwu/athena_l4t_sdk](https://github.com/zbwu/athena_l4t_sdk) — L4T r35 BSP foundation
- [zbwu/cyberdog_misc](https://github.com/zbwu/cyberdog_misc) — low-level userspace glue
- [MiRoboticsLab/cyberdog_motor_sdk](https://github.com/MiRoboticsLab/cyberdog_motor_sdk)
- [MiRoboticsLab/cyberdog_locomotion](https://github.com/MiRoboticsLab/cyberdog_locomotion) — gait controller
- [MiRoboticsLab/cyberdog_ws](https://github.com/MiRoboticsLab/cyberdog_ws) — aggregator meta-repo
- [NVIDIA Jetson Linux r35.6.2 archive](https://developer.nvidia.com/embedded/jetson-linux-archive)
- [NVIDIA forum: Xavier NX from CyberDog reflash](https://forums.developer.nvidia.com/t/jetson-xavier-nx-from-cyberdog-reflash/328632)
- [Xiaomi CyberDog original white paper / Register coverage](https://www.theregister.com/2021/12/03/ubuntu_cyberdog/)
- [openWakeWord](https://github.com/dscripka/openWakeWord) · [whisper.cpp](https://github.com/ggml-org/whisper.cpp) · [whisper_trt (NVIDIA-AI-IOT)](https://github.com/NVIDIA-AI-IOT/whisper_trt) · [Kokoro TTS](https://github.com/nazdridoy/kokoro-tts)
- [Foxglove Studio](https://github.com/foxglove/studio) · [rosbridge_suite](https://github.com/RobotWebTools/rosbridge_suite)
