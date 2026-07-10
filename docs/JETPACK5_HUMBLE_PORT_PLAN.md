# CyberDog 1 → JetPack 5.1.x / Ubuntu 20.04 / ROS 2 Humble Port

> Living plan for porting a 2021 Xiaomi CyberDog 1 (Jetson Xavier NX, board `k91`) from the stock **JetPack 4.5.1 / L4T r32.5.2 / Ubuntu 18.04 / ROS 2 Foxy** firmware to a modern **JetPack 5.1.6 / L4T r35.6.4 / Ubuntu 20.04 / ROS 2 Humble** stack with an open voice pipeline and a Lichtblick / foxglove-bridge remote UI.
>
> **2026-07-07 — full plan review & retarget.** See [PLAN_REVIEW_2026-07-07.md](./PLAN_REVIEW_2026-07-07.md) (referenced below as "review §…/D…"): target moved r35.6.2 → r35.6.4 (final JetPack 5; **JP5 EOL Q3 2026 — mirror all artifacts now**), a new **Phase 0.5** re-tests the confounded April boot findings, Phase 2 is redesigned around a rescue initrd (online root-shrink is impossible), Phase 3's driver scope shifted from cameras (already done in zbwu's tree) to audio codecs, and **V1.0.0.94 stock firmware turned out to be publicly downloadable** — the recovery story is much stronger than previously believed.

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
- [10. Phase 2 — Rescue initrd + offline NVMe dual-rootfs](#10-phase-2--rescue-initrd--offline-nvme-dual-rootfs)
- [11. Phase 3 — L4T r35.6.4 BSP build](#11-phase-3--l4t-r3564-bsp-build)
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

Xiaomi ended the public CyberDog roadmap in 2022; the XiaoAi cloud voice service and the phone app's gRPC backend depend on services that are unreliable or dead. The goal is to modernize to **JetPack 5.1.6 / L4T r35.6.4 / Ubuntu 20.04 / ROS 2 Humble**, with XiaoAi replaced by an openWakeWord + whisper.cpp + OpenAI + Kokoro-TTS pipeline, and the phone app replaced by Lichtblick/foxglove-bridge + a thin custom web UI over rosbridge.

**Xavier NX cannot run Ubuntu 22.04.** JetPack 6 is Orin-only. L4T r35.6.4 (Ubuntu 20.04) is the ceiling — and the end of the line: **JetPack 5 reaches EOL in Q3 2026** (5.1.6 is the final release for t194) and ROS 2 Humble EOLs 2027-05-31. The end-state is a *frozen-but-modern* stack — that is the hardware's ceiling and it's fine; the post-Humble path is containers on top of the frozen base (review D10), never another base-OS port. Ubuntu Pro (free tier) carries focal security updates to 2030 (review §3.1).

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
| 3 peripheral MCUs (head / body / rear) | USB-serial — **power-gated**: zero ttyUSB at idle (review §2.7) | STM32 (motor/spine domain is GD32F303 per zbwu `athena_motorcontrol`/`GD32_SPINE`) |
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
| Wi-Fi + BT | USB (`0bda:c820`) | Realtek RTL8821CU — out-of-tree driver on 4.9 **and** on 5.10 (`morrownr/8821cu`; review §2.6) |
| Boot flash | QSPI NOR 32 MB (`/dev/mtdblock0`) | MB1/MB2/cboot/BCT — the real bootloader home, NOT eMMC; dumped as Layer 3b (review §2.2) |

**eMMC partition map** (`/dev/mmcblk0`, 16 GB, 14 GPT partitions):

| # | Name | Size | Notes |
|---|---|---|---|
| 1 | APP | 1.6 GB | **Boot island, not a rootfs** — contains only `/boot` (Image + initrd + DTB + extlinux.conf, near-identical to the NVMe copy). Possibly what cboot actually reads (review §2.3 → Phase 0.5) |
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
| [zbwu/athena_l4t_sdk](https://github.com/zbwu/athena_l4t_sdk) (branch `athena_l4t-r35.1`) | L4T r35.1 BSP: kernel 5.10 **incl. `athena_defconfig` (exists — issue #1 was a non-recursive-clone artifact)**, cameras (`nv_ov13b10.c`/`nv_ov7251.c`) + BMI160 already ported, DTS rebased onto devkit `p3668/p2151` with `model = "Xiaomi Cyberdog"` (NOT a mi-k91 port) | Frozen Aug 2022, still the only JP5 foundation (verified 2026-07). **Works per README:** Wi-Fi/BT/eth/**CAN**/GPU/CUDA/NVMe/USB3/OTG/UART/**fan**/HDMI/**RealSense/color+stereo cams**. **Missing: mic array + speaker** (no rt5680/tas5805m). Locomotion out of scope |
| [MiRoboticsLab/cyberdog_tegra_kernel](https://github.com/MiRoboticsLab/cyberdog_tegra_kernel) | **Stock 4.9 kernel source** — incl. `sound/soc/codecs/rt5680.{c,h}` + `tas5805m.{c,h}` and the stock DT trio `tegra194-mi-k91{,-audio,-camera}.dts(i)` | Open, official. The wiring oracle + the source for Phase 3's audio forward-port. *(Missing from this plan before the 2026-07 review)* |
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

**Remote UI:** [foxglove_bridge](https://github.com/foxglove/ros-foxglove-bridge) (MIT, `apt install ros-humble-foxglove-bridge`) + [Lichtblick](https://github.com/Lichtblick-Suite/lichtblick) (MPL-2.0, BMW's actively-maintained fork of Foxglove v1 — v1.26.0, 2026-06) + [rosbridge_suite](https://github.com/RobotWebTools/rosbridge_suite) for the thin React/Vite web UI hosted on-dog via caddy. *(Foxglove Studio v2 went closed + account-gated in 2024; its free tier is a usable optional extra — review D12.)*

## 6. Top-3 project-killing unknowns

De-risk all three in Phase 0.5 / early Phase 3 before any destructive step.

> **2026-07-07: the original three unknowns are all resolved.** (1) A/B slots: decorative — but the extlinux tests were *confounded*, see new #1 below. (2) Closed-`.so` graph: mapped in Phase 0 forensics — locomotion is open-path. (3) `athena_defconfig`: **exists** in zbwu's tree; issue #1 was a non-recursive-clone artifact (review §3.2). Bonus: **secure-boot fuses verified unburned** (`odm_production_mode=0x0`, review §2.1) — self-built kernels/bootloaders will boot; a never-tested killer assumption is now fact. The NEW top-3:

1. **Which extlinux.conf does cboot read — NVMe p1 or the eMMC APP p1 boot island?** Two near-identical copies exist; every April test edited only the NVMe copy, so "`DEFAULT` is ignored" may be an artifact of editing a file cboot never reads (review §2.3). If the eMMC copy is live and `DEFAULT` works there, the safer dual-LABEL switching design is resurrected. **Resolve in Phase 0.5 with marker bootargs — cheap, reversible.**
2. **Does this cboot load kernel/DTB from files (`LINUX`/`FDT` lines) at all?** Stock boots the eMMC kernel *partition* (`LABEL primary` has no `LINUX` line; p2 carries an NVDA-wrapped copy of the same 4.9.201 build — review §2.4). If `FDT`-from-file fails, JP4/JP5 cannot pair kernels with their own DTBs and Phase 2 must be redesigned. **Resolve in Phase 0.5 with the model-string FDT test.**
3. **Audio-codec forward-port complexity (`rt5680` + `tas5805m`, 4.9 → 5.10 ASoC).** The one driver area zbwu never did (his README: mic/speaker "not supported"); sources are open in `cyberdog_tegra_kernel`. Machine-driver/DT-graph churn is the risk. **Scope in early Phase 3.**

## 7. Bricking-risk map

"Brick" = unrecoverable without opening the chassis.

| Phase | Risk | Notes |
|---|---|---|
| **0** Backup | Low | Pure reads. Only risk: inconsistent tarball if ROS 2 keeps writing state — stop services during Layer 2 dump. |
| **1** x86 env | None | Host-only. |
| **0.5** Boot-path disambiguation | Low-Med | Marker bootargs + FDT-copy test; every step reversible; worst case ≈ 30-min forced-recovery revert. Schedule with the next day free. |
| **2** Rescue initrd + offline NVMe surgery + `extlinux.conf` | **High** | First meaningful brick risk. Surgery runs OFFLINE from the RAM rescue initrd (online root-shrink is impossible — review §2.5). Access path = USB-gadget console (RNDIS + ttyGS0). eMMC stays read-only *except* file-level extlinux edits on APP p1 if Phase 0.5 proves that's the live copy (p01 dd-dump in hand). |
| **3** Kernel rebase | None | Host-only artifacts. |
| **4** First JP5 boot | **High** | Bad initrd or missing `nvme`/`ext4` driver → kernel panic. Mitigations: bake critical drivers `=y`; `panic=15` bootarg; **auto-revert initrd hook** (root-mount failure → self-restore JP4 extlinux, review D5); USB-gadget console once the kernel is up. |
| **5** CAN + motors | Medium physical | Motor misbehavior → physical danger. **Dog on a stand, legs off ground, every session.** Not a software brick. |
| **6–10** Humble + voice + UI | Low | Software-only; rollback = reboot + LABEL primary. |

## 8. Phase 0 — Backups & forensics

> **Status (2026-07-07).** Layers 0–3 complete and verified (2026-04-25). **Layer 3b (QSPI NOR + eMMC boot0/1) captured 2026-07-07** on-dog at `~/cyberdog-forensics-2026-04-22/qspi-boot-dump-2026-07-07/` — replicate to the backup SSD next session. **V1.0.0.94 factory firmware is publicly downloadable after all** (official CDN, hash from MiRoboticsLab discussion #133 — review §3.2); Layer 4 targets it directly and the old V1.0.0.66-baseline contortion is demoted to historical note. The April boot-mechanism findings (`PHASE0_BOOT_MECHANISM_FINDINGS.md`) are **confounded** — two extlinux.conf copies exist and only the NVMe one was edited (review §2.3); the new **Phase 0.5** re-tests before Phase 2. Layer 4 + rescue drill runbook: `PHASE0_LAYER4_RUNBOOK.md` (updated 2026-07-07 with V1.0.0.94 + mirror-now list — **JetPack 5 EOL is Q3 2026, download this week**). Remaining Phase 0 work = review §6 checklist.

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

layer3b/                                # NEW 2026-07-07 — bootloader media (review §2.2)
  qspi-mtdblock0.img                    # 32 MiB QSPI NOR: MB1/MB2/cboot/BCT — THE brick-relevant flash
  emmc-boot0.img, emmc-boot1.img        # 4 MiB each (identical)

layer4/                                 # factory-reset path from bare silicon, ~11 GB
  jp4.5.1-bsp/                          # NVIDIA jetson_linux_r32.5.2 + sample rootfs (T186 path;
                                        #   NOT jetson-210_* — that's Nano)
  athena_foxy_2022.01.14_emmc_nvme_V1.0.0.94_release_b1b4a851ca.tgz   # EXACT stock firmware, 5.06 GB
  athena_foxy_2021.08.24_emmc_nvme_V1.0.0.66.*_bbcc37a86a.tgz         # secondary baseline, 5.08 GB
                                        #   (flashall.sh per the MiRoboticsLab flashing wiki)
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
11. ~~**Non-destructive bootloader test** (`LABEL second`)~~ — performed 2026-04-25 with negative results, then found **confounded** (two extlinux.conf copies — review §2.3). Superseded by **Phase 0.5** below.

**Verification gate**

- `sha256sum` matches across 3 copies of `layer0/params-emmc-p12.img`.
- `tar -tf layer2/rootfs-nvme.tar.zst | wc -l` ≥ 350,000 entries.
- `zstd -t layer3/emmc-full.img.zst` passes.
- Rescue-drill chroot prints valid `/etc/os-release`.
- Phase 0.5 boot-path disambiguation completed and written up (replaces the old `LABEL second` gate).

**Rollback.** N/A — no writes to dog except the harmless extlinux entry (restore from saved copy if needed).

**Time: ~6 evenings (18 hrs).** `dd` + `tar` are IO-bound on USB-3; run overnight.

### Phase 0.5 — boot-path disambiguation (added 2026-07-07, runs after Phase 0 sign-off)

Full procedure + rationale: **review D2**. Summary — 1–2 evenings, 3–4 reboots, all reversible; schedule with the next day free:

1. Marker bootarg on `LABEL primary` in the **NVMe** extlinux.conf → reboot → `/proc/cmdline`. Absent? Repeat on the **eMMC APP** copy. Determines which file is cboot's real pivot.
2. If the eMMC copy is live: **re-run the `DEFAULT`-field test there.** If `DEFAULT` works, adopt the safer dual-LABEL switching design in Phase 2.
3. **FDT-from-file test:** point `FDT` at a DTB copy whose `model` string carries a suffix; read `/proc/device-tree/model` after boot. Pass ⇒ per-OS DTB pairing works ⇒ Phase 2/4 design is safe. Fail ⇒ **stop; redesign Phase 2 before any surgery.**
4. Revert everything; write `PHASE0_BOOT_MECHANISM_FINDINGS.md` v2.

## 9. Phase 1 — x86 host dev environment

On Ubuntu 22.04 host:

- Install NVIDIA SDK Manager; pull JetPack 5.1.6 (L4T r35.6.4).
- Fork all repos under the owner's GitHub and clone pinned:
  - `<user>/athena_l4t_sdk` (fork of zbwu), branch `cyberdog-humble-r35.6.4` off `athena_l4t-r35.1`.
  - Submodule forks: `<user>/athena_l4t_kernel`, `athena_l4t_nvidia`, `athena_l4t_jakku_dts`.
  - `cyberdog_misc`, `cyberdog_motor_sdk`, `cyberdog_locomotion`, `cyberdog_ros2`, `cyberdog_ws`.
- Build Docker image `cyberdog-builder:r35.6` with `aarch64-linux-gnu-gcc-9/11`, `bison flex libssl-dev bc device-tree-compiler dtc`, ROS 2 Humble source-build deps.
- Install Xiaomi flashing prereqs on host: `sudo apt install device-tree-compiler nfs-common sshpass abootimg network-manager libxml2-utils`.
- `MANIFEST.yaml` records exact commit hashes of all repos.
- **Track S starts here (review D8):** port `cyberdog_locomotion` + `cyberdog_ws` Galactic→Humble on the x86 host and make it walk in `cyberdog_simulator` — pure software, overlaps Phases 2–5, and surfaces any locomotion-port showstopper while aborting is still free. Phase 6 then merely deploys the result.
- Also clone/mirror `MiRoboticsLab/cyberdog_tegra_kernel` (audio-codec + DT sources) and `morrownr/8821cu-20210916` (Wi-Fi driver).

**Verification.** `docker run cyberdog-builder:r35.6 aarch64-linux-gnu-gcc --version` prints 9.x/11.x; stock `tegra_defconfig` kernel builds clean.

**Time: ~3 evenings (9 hrs).**

## 10. Phase 2 — Rescue initrd + offline NVMe dual-rootfs

> **Redesigned three times.** 2026-04-25 (edit-in-place) → 2026-07-07 (review D2/D4: April was *confounded*; `resize2fs` can't shrink a mounted root) → **2026-07-10, settled by Phase 0.5 experiment** (`PHASE0_BOOT_MECHANISM_FINDINGS.md` v2).

**Phase 0.5 results (measured, 2026-07-10):**

1. **cboot reads the eMMC APP copy** (`/dev/mmcblk0p1` → `/boot/extlinux/extlinux.conf`). The NVMe copy is decorative. *All* extlinux edits and JP5 kernel artifacts belong on **eMMC APP p1** (1.5 GB, ~46 MB used) — **not** NVMe `/boot-jp5/` as previously planned.
2. **`DEFAULT` works** → the safer **dual-LABEL** design is adopted: `LABEL jp4` and `LABEL jp5` both persist; switching = flip one word after `DEFAULT` (atomic `rename(2)`).
3. **`INITRD`-from-file already works** (stock `LABEL primary` uses it every boot) — so cboot's file loader is functional. **`LINUX`/`FDT`-from-file remain unproven (step 4, gated on recovery capability) and are mandatory** — JP5's kernel+DTB must come from files, since the eMMC kernel/DTB partitions hold JP4's and `nvbootctrl` A/B is decorative.

**Design.** eMMC bootloader chain + kernel partitions stay untouched. NVMe becomes: p1 (50 GB, JP4.5 — shrunk **offline**) · p2 (50 GB, JP5 rootfs) · p3 (~17 GB, shared `/data`). JP5 kernel artifacts live as *files* in **`/boot-jp5/` on eMMC APP p1**; JP4↔JP5 switching flips `DEFAULT` in the eMMC APP `extlinux.conf`. Layer 3 `p01.img` is a full dd backup of that partition, so file-level edits there are recoverable.

**Sub-tasks**

1. **Build + rehearse the RAM rescue initrd (2–3 evenings).** Busybox + dropbear/sshd + USB-gadget bring-up (RNDIS `192.168.55.1` **and** `ttyGS0` serial console — reuse the stock `/opt/nvidia/l4t-usb-device-mode` configfs script), booted from its own extlinux entry with the *stock JP4 kernel*, staying in initramfs (never mounts NVMe). Rehearse boot-in/SSH-in/boot-out twice. **This is permanent infrastructure:** several recovery-matrix rows drop from "forced-recovery + x86 host" to "boot rescue label, fix over SSH". **Build materials all confirmed present on-dog 2026-07-09** (`/bin/busybox`, stock initrd template, complete `/opt/nvidia/l4t-usb-device-mode/`, `sshd`) — see [PHASE1_OFFDEVICE_SCOPING_2026-07-08.md](./PHASE1_OFFDEVICE_SCOPING_2026-07-08.md) §5; and the shrink geometry is numerically verified (§6: p1 floor ≈18.5 GB ≪ 50 GB target).
2. **Offline surgery from the rescue environment (1 evening):** `e2fsck -f /dev/nvme0n1p1` → `resize2fs /dev/nvme0n1p1 45G` → `parted` shrink p1 to 50 GB → create p2 + p3 → `mkfs.ext4 -L JP5_ROOT /dev/nvme0n1p2`, `mkfs.ext4 -L DATA /dev/nvme0n1p3` → `resize2fs /dev/nvme0n1p1` (grow back into p1's final size) → reboot to JP4, verify untouched.
3. **Boot-switch rehearsal with two identical JP4 kernels** (`/boot/Image` vs `/boot/Image.copy` + marker bootargs): implement `cyberdog-boot-switch jp4|jp5` against the Phase 0.5-proven pivot file, verify atomicity (`cp` to `.tmp` + `mv`) and that both paths boot, **before** any JP5 kernel exists.
4. Record p1/p2/p3 UUIDs in `MANIFEST.yaml`; keep `extlinux.conf.{jp4,jp5}-saved` canonical copies next to the live one.

**Verification.** `lsblk` shows p1/p2/p3; JP4 boots normally post-shrink; rescue label boots + SSH over USB works; switch rehearsal passes repeated cycles.

**Rollback.** Botched extlinux → boot rescue label, restore from saved copy. Rescue label itself broken → forced-recovery + x86 host (`PHASE0_RECOVERY_PROCEDURES.md` §1, ~30 min). Filesystem damage → Layer 2/3 restores, unchanged.

**Time: ~4 evenings (12 hrs).** (Was 2 — the rescue initrd is new scope, and worth it.) Schedule surgery night with the next full day free.

**Fallback if partition surgery is unpalatable:** loopback-file JP5 rootfs (`/jp5root.img` on p1, `losetup`+pivot from a custom JP5 initrd) — zero surgery, one-file reversal, modest I/O overhead. Back-pocket option only (review D4). The old `nvbootctrl` slot-B fallback is **retired** (proven decorative in April).

## 11. Phase 3 — L4T r35.6.4 BSP build

**Decision: rebase to r35.6.4, not zbwu's stale r35.1.** zbwu's branch is 4 years frozen; r35.6.4 (2026-02) is the **final** JetPack 5 release — after JP5's Q3 2026 EOL there will never be another rebase target, so land on it once and be done. Scope is smaller than originally feared: cameras + IMU + defconfig already exist in zbwu's tree (review §3.2); the genuinely new work is **audio**.

**Deliverables**

- Fork branches `cyberdog-humble-r35.6.4` in all four `athena_l4t_*` repos.
- `patches/` directories capturing zbwu's deltas vs upstream r35.1, rebased onto r35.6.4.
- **Verified `athena_defconfig`** — it **exists** in zbwu's kernel tree (`arch/arm64/configs/athena_defconfig`; issue #1 was a clone artifact). Diff-review it against Phase 0 `/proc/config.gz` + r35.6.4 `tegra_defconfig` rather than reconstructing. CyberDog-specific `CONFIG_*` to confirm:
  - `CONFIG_IIO_BMI160_I2C=y` (IMU)
  - `CONFIG_GPIO_TCA6424=y` (GPIO expander)
  - `CONFIG_REGULATOR_MAX20024=y` (PMIC)
  - `CONFIG_SND_SOC_TAS5805M=y` (audio amp)
  - `CONFIG_SND_SOC_RT5680=y` (codec)
  - `CONFIG_SENSORS_INA3221=y` (current monitor)
  - `CONFIG_VL53L1X=y` (TOF) — confirm from live DTB
  - OV7251 / OV13B10 camera drivers — **already ported in zbwu's tree** (`nv_ov13b10.c`/`nv_ov7251.c`, `CONFIG_NV_VIDEO_OV13B10/OV7251=m`); rebase, don't rewrite
  - **`CONFIG_CAN_RAW=y` + `CAN_DEV`/`CAN_BCM`/`CAN_GW` (motor bus)** — ⚠️ **caught 2026-07-08: zbwu's defconfig has only `CONFIG_CAN=y` + `MTTCAN=y`, NOT `CAN_RAW`.** The motor SDK uses raw SocketCAN; without this the bus is silent in Phase 5. Cheap fix, add explicitly. `MTTCAN` (Tegra CAN IP) is already present. See [PHASE1_OFFDEVICE_SCOPING_2026-07-08.md](./PHASE1_OFFDEVICE_SCOPING_2026-07-08.md) §1.
  - Note: zbwu's defconfig uses generic `CONFIG_GPIO_PCA953X=y` for the TCA6424s (covers the tca64xx family) and HID-sensor-hub configs alongside the BMI160 sources — verify the IMU path empirically in Phase 5. **BMI160 CONFIG is absent from zbwu's defconfig (sources present) — enable it.**
- **NEW — audio codec forward-port (the critical path to Phase 8):** `rt5680` + `tas5805m` from `cyberdog_tegra_kernel` (4.9) → 5.10 ASoC, plus re-authoring the `tegra194-mi-k91-audio.dtsi` nodes onto zbwu's p3668-based DTS (review D5). **Scoped 2026-07-08 — see [PHASE3_AUDIO_PORT_SCOPING.md](./PHASE3_AUDIO_PORT_SCOPING.md): MEDIUM-LOW risk, ~7–12 evenings; standard codec→component conversion (rt5659.c as template) + tegra-alt→audio-graph DT rewrite; upstream v6.1 tas5805m verified as backport alternative. Unknown #3 is bounded.**
- **NEW — `rtl8821cu` out-of-tree Wi-Fi module** (`morrownr/8821cu-20210916`): stock Wi-Fi is USB RTL8821CU with no in-tree 5.10 driver (review §2.6). Plus `rtl8821c` BT firmware from linux-firmware into the rootfs.
- **NEW — auto-revert initrd hook:** on root-mount failure, mount the boot-pivot FS, restore `extlinux.conf` from the jp4-saved copy (atomic `rename(2)`), `sync`, `reboot -f`; plus `panic=15` in APPEND. Converts the most likely Phase 4 failure from a 30-min USB rescue into a self-healing reboot (review D5). Rehearse deliberately in Phase 4.
- **Optional, off critical path — PREEMPT_RT:** official on r35.x for Xavier NX (developer-preview): `./kernel-5.10/scripts/rt-patch.sh apply-patches`, rebuild nvdisplay against it (headless operation dodges the display risk). Only after locomotion is stable on the stock kernel (review §3.1).
- **DTS strategy:** extend zbwu's proven-booting `tegra194-p3668-0001-p2151-0000.dts` (`model = "Xiaomi Cyberdog"`); use stock `tegra194-mi-k91{,-audio,-camera}.dts(i)` from `cyberdog_tegra_kernel` as the wiring oracle. Do **not** attempt a from-scratch mi-k91 port (review §3.2).
- Built artifacts: `Image`, DTB, initrd with critical drivers baked `=y` + auto-revert hook, out-of-tree `*.ko` (incl. 8821cu), ready for staging to `/boot-jp5/`.

**Sub-tasks**

1. Via SDK Manager or `source_sync.sh`, clone NVIDIA r35.6.4 kernel + bootloader sources.
2. Extract zbwu deltas: `git format-patch upstream-r35.1..athena_l4t-r35.1` in each submodule.
3. Rebase onto r35.6.4 in fork; resolve conflicts (expect hits in DTB fragments and camera/display drivers).
4. Synthesize `athena_defconfig` per above; commit as `arch/arm64/configs/athena_defconfig` in kernel fork.
5. Build in Docker: `make athena_defconfig && make -j Image dtbs modules`.
6. Package into tarball for staging.

**Verification.** Clean build; `file Image` arm64; DTB decompiles via `dtc`; no missing symbols from `cyberdog_motor_sdk` link.

**Time: ~15–25 evenings (45–75 hrs).** Still the biggest phase, but cameras/defconfig are already done in zbwu's tree; audio is the new core work (review D5).

**Risks**

- r35.1 → r35.6.x kernel API churn in out-of-tree drivers (camera subsystem especially). Port one driver at a time.
- Closed NVIDIA blobs (nvdec, nvenc, GPU FW) in `athena_l4t_nvidia` may have ABI changes. Pull fresh from r35.6.4 BSP; do not carry zbwu's forward.
- Missed driver in `athena_defconfig` → Phase 5 hardware fails. Mitigate: enable generously `=m` where unclear.

## 12. Phase 4 — First JP5 boot

**Deliverables.** Ubuntu 20.04 rootfs (JP5's sample rootfs + `apply_binaries.sh`) on `nvme0n1p2`; JP5 kernel + DTB + initrd in `/boot-jp5/` on p1; SSH accessible.

**Sub-tasks**

1. On x86: `sudo Linux_for_Tegra/apply_binaries.sh` → `Linux_for_Tegra/rootfs/`.
2. Transfer to dog: with dog booted into JP4.5 (LABEL primary), `rsync -aAXH Linux_for_Tegra/rootfs/ mi@cyberdog:/mnt/p2/`.
3. Stage kernel + DTB + initrd to `/boot-jp5/` on p1.
4. Edit `/mnt/p2/etc/fstab`: p2 as `/`, p3 as `/data`.
5. **Assume no Wi-Fi on first boot** (8821cu is out-of-tree): enable `nv-l4t-usb-device-mode` (RNDIS `192.168.55.1` + `ttyGS0` gadget serial console) in the rootfs **before** first boot — that's the access path. Then install the 8821cu module, copy Wi-Fi creds from Layer 0, configure via NetworkManager.
6. Reboot → switch to JP5 per the Phase 2 mechanism → watch the USB-gadget console. Expect: cboot → kernel load → mount p2 → systemd-journald → `sshd` up.
7. **Auto-revert drill:** once JP5 boots, deliberately point `root=` at a bogus partition for one boot and verify the initrd hook restores JP4 automatically (review D5/D6). Re-switch to JP5 afterwards.
8. Hardening + lifecycle: `pro attach` (Ubuntu Pro free tier → focal ESM to 2030); change every stock password (`pi/123`, `root/123`, `mi` — all community-documented).

**Verification.** `ssh mi@192.168.55.1` on JP5 side works over USB. `uname -r` shows `5.10.x-tegra`. `lsmod` shows expected drivers incl. `8821cu`. `ip a` shows usb0 + wlan0 (+ eth0).

**Rollback.** Switch back per the Phase 2 mechanism (or let the auto-revert hook do it) → fully-working JP4.5.1.

**Time: ~5 evenings (15 hrs).**

## 13. Phase 5 — Hardware bring-up

**Order: thermal/fan → CAN → motor SDK → MCUs → BMS → I²C → cameras → audio.** Safety-critical first, passive reads middle, GPU-dependent last.

### 5.0 Thermal & fan — gate for everything GPU-heavy (NEW, review D7)

- zbwu lists fan/tach/PWM as working on r35.1 — re-verify on the r35.6.4 rebase **before** any sustained GPU load: `nvfancontrol` profile present, fan spins under load, tach reads, thermal zones sane.
- 30-min `tegrastats` soak at the target nvpmodel; compare against the stock baseline (idle-ish, 15 W 6-core, fan `quiet`: CPU 56 °C / GPU 53.5 °C). Sealed chassis — do not skip.

### 5.1 CAN bus + motor SDK — dog on stand, legs off ground

- `modprobe can_raw c_can`; `ip link set can0 up type can bitrate 1000000`.
- `candump can0` should show motor heartbeat.
- Cross-compile `cyberdog_motor_sdk` in Docker, deploy, run `Example_MotorCtrl`: reads 12 motor positions.

### 5.2 MCU comms

- **MCUs are power-gated** — zero `/dev/ttyUSB*` exist at idle even on stock (review §2.7). *Prerequisite (do on the JP4 side before Phase 2):* capture the enable sequence — `udevadm monitor` + TCA6424 GPIO states while triggering stand/motion on the stock stack; also chase the unverified `192.168.55.233` "R-domain" community lead. Then, on JP5:
- Replay the enable sequence; `usb_adapter` (from `cyberdog_misc`) enumerates 3 USB-serial (`/dev/ttyUSB{0,1,2}` → head/body/rear MCUs).
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
- RealSense via librealsense2 for JP5 r35.6.4.

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

Forward-compat has **two** layers (audited 2026-07-09 — [PHASE1_OFFDEVICE_SCOPING_2026-07-08.md](./PHASE1_OFFDEVICE_SCOPING_2026-07-08.md) §2): **glibc** (a non-issue — all closed libs need ≤ GLIBC 2.27 ≪ focal's 2.31) and **ROS ABI** (the real gate). Full NEEDED audit: **6 of 9 closed libs are standalone** (glibc-only → genuinely copy-forward), but **3 link Foxy's `librclcpp`/`librcl` ABI** — including the keystone `libathena_utils_core.so`. Foxy→Humble breaks rclcpp ABI, so those 3 do **not** simply copy-forward. Two of them are audio libs already on the DROP list; the problem collapses to the **one keystone**, whose disposition (Foxy side-by-side runtime over DDS, vs replacing its consumers) is a Phase 5 decision. **Walking is unaffected** — locomotion links no closed lib.

**Time: ~25–30 evenings (75–90 hrs).**

**Risks**

- Motor runaway — **always on stand, legs off ground.**
- Camera DTB overlays are Xiaomi-specific; live in `athena_l4t_jakku_dts` fork.
- CAN termination / baud mismatch — keep USB-CAN sniffer ready.

## 14. Phase 6 — ROS 2 Humble + locomotion port

**Install strategy: source-build ROS 2 Humble on Ubuntu 20.04.** Tier-3 binary coverage gaps will bite in Nav2 + locomotion; source-build once is faster than firefighting later. `colcon --packages-up-to` for iterative builds. *(Re-validated 2026-07: still the standard JP5 path — known pins like setuptools 58.2.0 apply, no new breakage; RoboStack's `robostack-humble` on linux-aarch64 is a maintained fallback for CPU-side nodes only — review §3.1.)*

**Most of the Galactic→Humble port itself happens off-device in Track S** (Phase 1, review D8): ported + walking in `cyberdog_simulator` on x86 before this phase starts. Phase 6 deploys and integrates that result on the dog.

> **Re-scoped 2026-07-08** ([PHASE1_OFFDEVICE_SCOPING_2026-07-08.md](./PHASE1_OFFDEVICE_SCOPING_2026-07-08.md) §3): `cyberdog_locomotion` is **LCM-based, not ROS** — 949 LCM refs vs 7 rclcpp refs, and all 7 are in `CMakeLists.txt`/`package.xml`, none in source. It's a self-contained MIT-Cheetah control binary. `cyberdog_motor_sdk` has **zero** ROS coupling (pure CAN). **The Galactic→Humble work is NOT in locomotion** — it's in `cyberdog_ros2`'s LCM↔ROS bridge: `cyberdog_decision/decision_maker/motion_manager.{hpp,cpp}` + `cyberdog_interfaces/lcm_translate_msgs/`. Port budget shifts there; the locomotion binary just needs to build on 20.04 (LCM is distro-agnostic).

**Critical files to port (corrected target):**

- `cyberdog_ros2` `cyberdog_decision/decision_maker/motion_manager.cpp` — the real rclcpp coupling; Galactic → Humble API shifts.
- `cyberdog_interfaces/lcm_translate_msgs/` — LCM↔ROS translation (28 `.lcm` types); rebuild against Humble.
- `cyberdog_locomotion` — build the LCM binary on 20.04 as-is; no source-level ROS port. **Validate standalone via LCM loopback before any ROS stack exists** (Track S can walk-in-sim with just LCM + `simbridge`).
- `cyberdog_motor_sdk` CAN backend — pure C++/CAN, no ROS port.

**Galactic → Humble port surface (now confined to the decision layer):** `rclcpp` parameter API (typed declarations now required), message header namespace moves, launch composable-node syntax. Budget ~8 evenings, down from ~10 — locomotion itself is off the port path.

**Restore `/params`:** loopback-mount `layer0/params-emmc-p12.img`, copy camera intrinsics + extrinsics, IMU biases, audio EQ into expected paths on JP5 rootfs.

**Desktop swap (Lubuntu → Ubuntu):** install `xubuntu-desktop` (~1.5 GB lighter than GNOME, better for 8 GB Xavier NX); set as LightDM default; keep LXDE as fallback.

**Smoke test:** dog on stand, `ros2 launch cyberdog_bringup locomotion.launch.py`; stand → trot-in-place → set-down. Record bag for comparison against JP4.5.1 baseline.

**Verification.** `ros2 node list` shows all expected nodes. Trot telemetry matches JP4.5 within 5 % on control-loop rate.

**Time: ~12–18 evenings on-device** (Track S absorbed the port work off-device — review D8).

**Risks.** Humble's new executors have different latency profiles — audit MIT Cheetah control loop's `SCHED_FIFO` priorities. (If jitter is provably problematic, the optional PREEMPT_RT kernel from Phase 3 is the escalation path.)

## 15. Phase 7 — Perception, Nav2, teleop

- Nav2 Humble stack (stock).
- `slam_toolbox` with stereo odometry from OV7251 pair or RealSense depth.
- `realsense-ros` Humble branch for D430i.
- `ros2 joy` + `teleop_twist_joy` for an 8BitDo-class gamepad.
- `cyberdog_vision` / `cyberdog_miloc` ported forward (visual SLAM).

**Time: ~8 evenings (24 hrs).** Low brick risk.

## 16. Phase 8 — Voice stack replacement

Pipeline: **mic → openWakeWord ("Hey CyberDog") → VAD → whisper.cpp + TensorRT (`small`) → OpenAI streaming chat → Kokoro TTS (en+zh) → ALSA via TAS5805M → speaker.**

**Packaging reality on JP5 (review D11).** GPU wheels are **cp38-only** (final: torch 2.1.0, onnxruntime-gpu 1.16.x — mirror them now, Jetson Zoo is bot-walled), while `kokoro-onnx` needs **py≥3.10**. Resolution: whisper.cpp as C++/CUDA (`-DGGML_CUDA=1 -DCMAKE_CUDA_ARCHITECTURES=72`, pin a release that still builds on CUDA 11.4/gcc-9); **Kokoro on CPU ORT in a py3.10 venv** (82 M params — CPU suffices) or in a py3.10 jetson-container with GPU ORT; openWakeWord stays on py3.8 (semi-dormant upstream but functional; microWakeWord is ESP32-targeted — not applicable). **Optional cloud mode** behind a flag: `gpt-4o-mini-transcribe` (~$0.003/min) for STT and/or `gpt-realtime-2.1-mini` for full speech↔speech; the local pipeline remains the default/offline path.

**Critical files (create)**

- `/opt/cyberdog_voice/` — new ROS 2 node
- `/etc/cyberdog/llm.env` — OpenAI API key, root-only (`chmod 600`)
- `/etc/systemd/system/cyberdog-voice.service`

**Time: ~10 evenings (30 hrs).**

**Risks.** TensorRT engine builds are pinned to specific TRT version (8.5 on r35.6.4). Network latency to OpenAI dominates UX — cache common responses.

## 17. Phase 9 — Phone-app replacement

- **Lichtblick** (browser + desktop; MPL-2.0, actively maintained BMW fork of Foxglove v1) for visualization + control panels. Foxglove Studio v2 is account-gated SaaS now — its free tier is the optional extra, not the foundation (review D12).
- **foxglove_bridge** (`ros-humble-foxglove-bridge`, MIT, apt-installable) serving Lichtblick; **rosbridge_suite** for the custom web UI.
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

- `extlinux.conf` on the Phase 0.5-proven pivot filesystem (NVMe p1 *or* eMMC APP p1) — plus `extlinux.conf.{jp4,jp5}-saved` canonical copies
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

- `<fork>/athena_l4t_sdk` branch `cyberdog-humble-r35.6.4`
- `<fork>/athena_l4t_kernel/arch/arm64/configs/athena_defconfig` — exists upstream; diff-verified against `/proc/config.gz`
- `<fork>/athena_l4t_jakku_dts/tegra194-mi-k91.dts` — board DTB with Xiaomi sensor nodes
- `<fork>/cyberdog_locomotion/` branch `humble-port`
- `<fork>/cyberdog_ws/` branch `humble-aggregate` — meta-repo
- `~/cyberdog-dev/MANIFEST.yaml` — pinned commit hashes

## 20. Project-level verification

1. **Dual-boot works.** `cyberdog-boot-switch jp4|jp5` + `reboot` lands on JP4.5 or JP5 respectively (via the Phase 0.5-proven mechanism); both fully functional; a failed JP5 boot self-reverts via the initrd hook.
2. **Walking.** JP5 side, `ros2 launch cyberdog_bringup locomotion.launch.py`; dog stands, trots in place, walks forward 2 m via gamepad teleop.
3. **Sensors.** All 6 `/dev/video*` devices enumerate; BMI160 IMU publishes `/imu/data_raw` at ≥ 200 Hz; battery SOC publishes `/battery_state`.
4. **Voice.** "Hey CyberDog, sit" → dog sits. OpenAI key never leaves `/etc/cyberdog/llm.env`.
5. **Remote UI.** Phone browser → `http://cyberdog.local:8080` → Foxglove dashboard shows live cameras + gamepad control works.
6. **Rollback drill.** Deliberately corrupt `/etc/fstab` on p2, reboot, select `primary`, JP4.5 boots fine. Fix p2 from JP4.5 side.
7. **Full restore drill (quarterly).** Restore `layer2/rootfs-nvme.tar.zst` to a temporary directory, verify completeness.

## 21. Git strategy

- Fork all four `athena_l4t_*` repos + all `MiRoboticsLab/*` repos under user's GitHub.
- Per repo: branch `cyberdog-humble-r35.6.4` off zbwu's `athena_l4t-r35.1` (or upstream `main` for MiRoboticsLab).
- Cherry-pick zbwu's deltas as `git format-patch` onto r35.6.4 base.
- Each repo has `patches/` directory documenting every non-upstream commit with rationale.
- Tag known-good states: `v0.1-phase2-dualboot`, `v0.2-phase4-first-boot`, `v0.3-phase5-motors`, `v0.4-phase6-walking`, `v1.0-full`.
- Push to private-backup mirror weekly.
- Upstream PRs back to zbwu: the r35.6.4 rebase + the audio-codec port (good-citizen move — closes his README's "mic array/speaker not supported" gap).

## 22. Open questions

- Which extlinux.conf does cboot read (NVMe p1 vs eMMC APP p1), and does `DEFAULT` work in the live one? (Phase 0.5 — decides Phase 2's switching mechanism.)
- Does cboot load DTBs from `FDT` file lines? (Phase 0.5 model-string test — decides whether JP4/JP5 can pair kernels with their own DTBs.)
- ~~How hard is the `rt5680`/`tas5805m` ASoC forward-port 4.9 → 5.10?~~ — **scoped 2026-07-08** ([PHASE3_AUDIO_PORT_SCOPING.md](./PHASE3_AUDIO_PORT_SCOPING.md)): medium-low, ~7–12 evenings, no blocker candidates.
- What powers the MCU USB links on/off, and what is the `192.168.55.233` "R-domain"? (JP4-side capture before Phase 2 — review D7.)
- Whether r35.6.4 has breaking camera-driver ABI changes vs zbwu's r35.1 baseline (determined in Phase 3 rebase).
- Whether OpenAI streaming latency over Wi-Fi is acceptable for conversational UX (Phase 8 — local pipeline is the fallback).
- ~~Whether `libContentMotionAPI.so` is on the locomotion runtime path~~ — **resolved** (Phase 0 forensics: no; locomotion is open-path). Further confirmed 2026-07-08: locomotion is LCM/C++, links no closed libs.
- Keystone `libathena_utils_core.so` disposition — **refined 2026-07-09**: glibc is fine, but it links **Foxy rclcpp ABI** (not copy-forward to a Humble-only system). Options: Foxy side-by-side runtime interoperating over DDS, or replace its 20+ consumers. Decide in Phase 5. (Walking doesn't need it.)
- ~~Locomotion Galactic→Humble port difficulty~~ — **resolved 2026-07-08**: locomotion is LCM-based (not ROS); the real port surface is `cyberdog_ros2`'s decision/bridge layer.
- ~~Whether the bootloader honors extlinux LABEL selection~~ — **superseded** by the confound finding (review §2.3).

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
- [NVIDIA Jetson Linux r35.6.4 archive](https://developer.nvidia.com/embedded/jetson-linux-archive)
- [NVIDIA forum: Xavier NX from CyberDog reflash](https://forums.developer.nvidia.com/t/jetson-xavier-nx-from-cyberdog-reflash/328632)
- [Xiaomi CyberDog original white paper / Register coverage](https://www.theregister.com/2021/12/03/ubuntu_cyberdog/)
- [openWakeWord](https://github.com/dscripka/openWakeWord) · [whisper.cpp](https://github.com/ggml-org/whisper.cpp) · [whisper_trt (NVIDIA-AI-IOT)](https://github.com/NVIDIA-AI-IOT/whisper_trt) · [kokoro-onnx](https://github.com/thewh1teagle/kokoro-onnx)
- [Lichtblick](https://github.com/Lichtblick-Suite/lichtblick) · [foxglove_bridge](https://github.com/foxglove/ros-foxglove-bridge) · [rosbridge_suite](https://github.com/RobotWebTools/rosbridge_suite)
- **Added by the 2026-07-07 review:**
  - [PLAN_REVIEW_2026-07-07.md](./PLAN_REVIEW_2026-07-07.md) — this plan's review + rationale for every delta
  - [MiRoboticsLab/cyberdog_tegra_kernel](https://github.com/MiRoboticsLab/cyberdog_tegra_kernel) — stock 4.9 kernel source (audio codecs + mi-k91 DT)
  - [MiRoboticsLab/cyberdog_ros2 discussion #133](https://github.com/MiRoboticsLab/cyberdog_ros2/discussions/133) — official V1.0.0.94/.82/.66 firmware URLs
  - [JetPack 5 EOL notice (Q3 2026)](https://forums.developer.nvidia.com/t/jetpack-5-upcoming-end-of-life-notice/357716) · [JetPack 5.1.6 / L4T r35.6.4 release](https://forums.developer.nvidia.com/t/jetpack-5-1-6-l4t-35-6-4-is-now-live/359618) · [Jetson Linux r35.6.4](https://developer.nvidia.com/embedded/jetson-linux-r3564)
  - [morrownr/8821cu](https://github.com/morrownr/8821cu-20210916) — RTL8821CU out-of-tree Wi-Fi driver
  - [NVIDIA forum: bricked CyberDog reflash attempt, 2025](https://forums.developer.nvidia.com/t/jetson-xavier-nx-from-cyberdog-reflash/328632) — cautionary tale
