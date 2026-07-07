# Plan review & optimization — 2026-07-07

Full review of `JETPACK5_HUMBLE_PORT_PLAN.md` + the four Phase 0 docs, cross-checked
against (a) fresh non-destructive forensics on the live dog and (b) a July-2026
re-verification of the external ecosystem (NVIDIA, ROS, community repos, firmware
mirrors). Everything in §2 was verified tonight on the running `k91`.

**Verdict up front.** The plan's architecture (dual-rootfs on NVMe, stock bootloader
untouched, layered backups, phased bring-up) survives review and remains the right
approach. But four findings materially change the details:

1. **The Phase 0 boot-mechanism conclusions are confounded** — there are TWO copies of
   `extlinux.conf` (NVMe p1 *and* eMMC APP p1) and the April tests only edited the NVMe
   copy. "cboot ignores `DEFAULT`" may be wrong. Must re-test (new Phase 0.5).
2. **The bootloader lives on QSPI NOR (`/dev/mtdblock0`), which no backup layer covered.**
   Dumped tonight (new Layer 3b). This also gives a better recovery path than the
   V1.0.0.66 factory flash.
3. **Secure-boot fuses are NOT burned** (`odm_production_mode=0x0`) — a never-tested
   project-killing risk is now positively retired: self-built kernels will boot.
4. **Phase 2 as written cannot work** — `resize2fs` cannot shrink a mounted root
   filesystem. Partition surgery needs an offline environment (rescue initrd), which
   the plan must now build first — and which doubles as a permanent safety net.

---

## 1. What was reviewed

- `docs/JETPACK5_HUMBLE_PORT_PLAN.md` (552 lines, last edit 2026-05-16)
- `docs/PHASE0_{FORENSICS_ANALYSIS,BOOT_MECHANISM_FINDINGS,RECOVERY_PROCEDURES,LAYER4_RUNBOOK}.md`
- Live system: fuses, QSPI/mtd, eMMC APP partition, extlinux configs (all 3 copies),
  kernel provenance (file vs partition), initrd structure, Wi-Fi/BT hardware, services,
  `/params` contents, thermal state
- External: JetPack/L4T status for t194, Ubuntu 20.04 ESM, ROS 2 Humble status,
  zbwu + MiRoboticsLab repos, firmware mirrors, Foxglove licensing (see §3)

## 2. New empirical findings from the live dog (2026-07-07)

### 2.1 Secure boot is NOT fused — risk retired ✅

```
/sys/devices/platform/tegra-fuse/odm_production_mode = 0x00000000
odm_lock = 0x00000000
arm_jtag_disable = 0x00000000
```

The `Image.sig`/`initrd.sig` files are advisory; cboot on an unfused t194 does not
enforce signatures. **Any self-built kernel/DTB/initrd will load.** This was an
implicit, never-verified assumption of Phases 3–4; it is now fact. (zbwu's successful
r35.1 boot already implied fuses were clean on his unit; now confirmed on ours.)

Residual note: `/proc/cmdline` carries `boot.ratchetvalues=0.4.2` (MB1/MTS rollback
counters). With `odm_production_mode=0` ratchet enforcement is not expected, but see
§2.2 — with a QSPI dump in hand we never need to flash the *older* V1.0.0.66
bootloader at all, sidestepping any rollback-ratchet question entirely.

### 2.2 The bootloader lives on QSPI NOR — new Layer 3b (captured tonight) ✅

`/etc/nv_boot_control.conf`:

```
TEGRA_OTA_BOOT_DEVICE /dev/mtdblock0     ← 32 MB QSPI NOR flash
TEGRA_OTA_GPT_DEVICE  /dev/mtdblock0
TNSPEC 3668-100-0001--1-2-jetson-xavier-nx-devkit-emmc-nvme0n1p1
```

Xavier NX boots MB1/MB2/cboot/BCT from **QSPI NOR**, not from eMMC. Layers 0–4
covered eMMC + NVMe but **never the QSPI** — the one component whose corruption is the
canonical "brick". Also note the TNSPEC: Xiaomi flashed with the *stock devkit-emmc
board spec* (root on `nvme0n1p1`) — the NVIDIA `jetson-xavier-nx-devkit-emmc` flash
profile is closer to k91 than the plan assumed.

**Captured tonight** to `/home/mi/cyberdog-forensics-2026-04-22/qspi-boot-dump-2026-07-07/`:

| File | Size | SHA-256 (first 12) |
|---|---|---|
| `qspi-mtdblock0.img` | 32 MiB | `9820ec477de2` |
| `emmc-boot0.img` | 4 MiB | `bb9f8df61474` |
| `emmc-boot1.img` | 4 MiB | `bb9f8df61474` (identical to boot0) |

**Action (Layer 3b):** copy this directory to the backup SSD next time it is attached,
and into the backup-of-backup. **Recovery-matrix change:** "bootloader corrupted" now
restores the *exact* current QSPI image via RCM/initrd-flash rather than falling back
to the 2021 V1.0.0.66 `flashall.sh` (older BL, unknown ratchet interaction, and it
rewrites everything). V1.0.0.66 demotes to true last resort.

### 2.3 TWO extlinux.conf copies exist — April's boot conclusions are confounded ⚠️

**eMMC APP (`/dev/mmcblk0p1`, 1.5 GB) is not an unused rootfs** as the plan's
partition table says. It contains exactly one thing: a `/boot` island —

```
/boot/Image                (38,795,272 bytes — 8 bytes SMALLER than NVMe copy)
/boot/initrd               (7,236,790 bytes — differs from NVMe copy too)
/boot/tegra194-mi-k91.dtb
/boot/extlinux/extlinux.conf   ← same TEXT as the NVMe copy (both stock V1.0.0.94)
```

The April boot-mechanism tests (`PHASE0_BOOT_MECHANISM_FINDINGS.md`) edited only the
**NVMe** copy. Both copies' `LABEL primary` APPEND lines are *identical*, so the
observation "primary's APPEND landed in cmdline" **cannot distinguish which file cboot
actually read.** Every negative result has an untested alternative explanation:

| April conclusion | Alternative explanation |
|---|---|
| "`DEFAULT` field is ignored" | cboot read the *eMMC* copy, whose `DEFAULT` is `primary` — the edit was never seen |
| "menu doesn't render / marker never appeared" | same confound |
| "only in-place edit of `LABEL primary` works" | possibly true of the *eMMC* copy, not the NVMe one |

Also: stock 2021 config (`extlinux.conf.nv-update-extlinux-backup`) has **no `LINUX`
line under `primary`** — and neither does the live config. See §2.4.

**This is the single most important thing to resolve before any Phase 2 work** — it
decides *which filesystem the boot pivot lives on* and possibly *resurrects the
original, safer dual-LABEL design*. New **Phase 0.5** (§4.1) nails it with 2–3
reboots, all reversible marker tests.

### 2.4 The kernel boots from the eMMC kernel partition, not from /boot/Image ⚠️

`LABEL primary` (the label that boots, in both copies) has `INITRD` and `APPEND`
but **no `LINUX` line**. Per cboot semantics, kernel then loads from the **kernel
partition** — and indeed `/dev/mmcblk0p2` starts with an `NVDA` signed-container
header wrapping the *same* `4.9.201-tegra #1 SMP PREEMPT Fri Jan 14 2022` build.

Consequences for the plan:

- The dog has **never been observed loading a kernel or DTB from a file**. The
  Phase 2/4 design (point `LINUX`/`FDT` at `/boot-jp5/*`) relies on two cboot
  behaviors — `LINUX <file>` and `FDT <file>` — that are documented for L4T r32 but
  unverified on Xiaomi's cboot build. The "two identical kernels" rehearsal must
  explicitly cover **both**, including `FDT` (test: point `FDT` at a *copy* of the DTB
  whose `model` string is cosmetically changed, then read `/proc/device-tree/model`
  after boot — zero functional risk, unambiguous result).
- If `FDT`-from-file turns out unsupported, JP4/JP5 **cannot share** the partition
  DTB (p4) — that would force a different Phase 2 design; find out *now*, not in
  Phase 4.
- Upside: because the running kernel comes from eMMC p2, botching files under
  `/boot` on NVMe is **less dangerous than the plan assumed** — the kernel + initrd
  + DTB partition path stays intact regardless.

### 2.5 Phase 2 as written cannot work: no online shrink of the root FS 🛑

Plan §10 step 2: "`e2fsck -f /dev/nvme0n1p1; resize2fs /dev/nvme0n1p1 45G`" while
booted from p1. **ext4 cannot be shrunk while mounted**, and you cannot unmount your
own root. "Boot single-user" does not help — root is still mounted. The step would
have failed on the night, with pressure to improvise. Redesign (§4.2): build a
**RAM-only rescue boot entry** (JP4 kernel + custom busybox/L4T initrd that stays in
initramfs, brings up USB-RNDIS at 192.168.55.1 + sshd, never mounts NVMe), boot into
it, and do the shrink offline. The stock initrd (150-entry L4T gzip cpio) is a
workable base. This rescue entry then remains forever as the maintenance/repair
environment — a second major win from the same work. (Alternative considered:
loopback-file JP5 rootfs on p1, no repartitioning at all — kept as fallback §4.2b.)

### 2.6 Wi-Fi is USB Realtek RTL8821CU — out-of-tree driver needed on JP5

`lsusb`: `0bda:c820`, driver `rtl8821cu` (Xiaomi ships an out-of-tree module on 4.9).
Kernel 5.10 (r35.x) has **no in-tree support** (rtw88 USB variants landed ≥5.18).
Add to Phase 3 build list: `morrownr/8821cu-20210916` (actively maintained, builds on
5.10). Bluetooth is `btusb`/`btrtl` (in-tree) + `rtl8821c` firmware from
`linux-firmware`. Without this, first JP5 boot has **no Wi-Fi** — plan for USB-OTG
(192.168.55.1) as the Phase 4 access path anyway.

### 2.7 Smaller findings

- **MCU serial ports are power-gated**: with `cyberdog_ros2.service` running but idle,
  zero `/dev/ttyUSB*` exist and no STM32s appear on USB. The head/body/rear MCUs are
  evidently powered on demand (TCA6424 GPIO?). Phase 5 must capture the enable
  sequence from the stock stack (udev events + GPIO traces while triggering motion)
  rather than assuming always-on ports.
- **`/params` contents confirmed**: `camera/` (stereo + AI intrinsics/extrinsics YAMLs,
  factory check images) and `audio/` (XiaoAi `token.toml`, `ai_status.toml` — dead
  cloud auth, worthless going forward). The irreplaceable part is specifically the
  camera extrinsics. Plan §14's restore step stands.
- **Thermal baseline** (idle-ish, 15W 6-core, fan `quiet`): CPU 56 °C, GPU 53.5 °C.
  JP5 has a different fan stack (`nvfancontrol`) — §4.5 adds an explicit thermal
  bring-up + soak gate, missing from the plan.
- **No Docker on the stock system** (relevant only if the container track in §4.6 is
  exercised on JP4 — it is NOT recommended there; kernel 4.9 + CUDA 10.2 make it
  low-value).
- Stock cruft: `/boot/initrd.img-5.4.0-{42,65}-generic` (Dec 2022 accidental HWE
  kernel installs — inert, do not carry forward), `pgyvpn.service` (owner-installed
  VPN), nginx + `ota_server.service` still enabled and pointing at dead
  infrastructure. None block anything; clean up on the JP5 side by simply not
  migrating them.
- Passwordless sudo is active for `mi` — convenient for the runbooks; note it.
- **R-domain confirmed (2026-07-07):** `192.168.55.233` is reachable via the internal
  `l4tbr0` bridge (members `eth0`, `rndis0`, `usb0`) and runs
  `SSH-2.0-dropbear_2015.71` — a second, separate compute domain (the MCU/GD32
  coprocessor side, per MAVProxyUser notes). Reconnaissance only; no login attempted
  (unknown-function coprocessor, possibly motion/safety — owner decides). Phase 5 should
  map what this domain exposes; it may be where the MCU power-gating / motion enable
  actually lives (§2.7).

## 3. Ecosystem re-verification (July 2026)

### 3.1 NVIDIA / OS / ROS — verified 2026-07-07

**Two changes force plan edits; the rest confirms the plan.**

| Topic | Finding (all URLs verified live 2026-07-07) |
|---|---|
| **Target version** | **JP 5.1.5 / r35.6.2 is superseded: JetPack 5.1.6 / L4T r35.6.4 shipped 2026-02-04**, explicitly supports Xavier NX. Same kernel 5.10 / Ubuntu 20.04 / CUDA 11.4 stack — a drop-in retarget, zero extra port effort, latest security fixes. No r35.6.3 exists. **→ Retarget every "r35.6.2" in the plan to r35.6.4.** |
| **JetPack 5 EOL: Q3 2026** ⚠️ | Announced 2026-01-15: no new JP5 releases after Q3 2026; support moves to newer JetPack (which dropped Xavier). **JP 5.1.6 is effectively the final OS for this hardware.** Downloads are still anonymous today, and NVIDIA historically keeps old L4T archives up (r32.5.2 from 2021 still serves), but: **mirror ALL artifacts now** — r35.6.4 + r35.6.2 driver package, sample rootfs, `public_sources.tbz2`, plus a snapshot of the apt repos `repo.download.nvidia.com/jetson/{common,t194}/dists/r35.6`. New Phase 0 item, do it this week. |
| r35.6.4 URLs | `https://developer.nvidia.com/downloads/embedded/l4t/r35_release_v6.4/release/jetson_linux_r35.6.4_aarch64.tbz2` (801 MB) · `.../r35_release_v6.4/release/tegra_linux_sample-root-filesystem_r35.6.4_aarch64.tbz2` (1.52 GB) · `.../r35_release_v6.4/sources/public_sources.tbz2` (198 MB) — all 200 OK, anonymous. |
| r35.6.2 URL quirk | Sample-rootfs URL has **no `/release/` path segment** (unlike the driver package): `.../l4t/r35_release_v6.2/tegra_linux_sample-root-filesystem_r35.6.2_aarch64.tbz2`. The `/release/` variant 404s. (Moot after retarget, noted in case r35.6.2 is mirrored too.) |
| r32.5.2 recovery URLs | Both runbook URLs still live (350 MB / 1.49 GB, 200 OK). Mirror them now as well. |
| **PREEMPT_RT** | Officially supported on r35.x for Xavier NX (developer-preview quality): `./kernel-5.10/scripts/rt-patch.sh apply-patches` in public_sources, then normal build; **nvdisplay must be rebuilt against the RT kernel** (community reports display issues otherwise — headless use unaffected). CUDA userspace unaffected. → optional Phase 3 add-on for the locomotion loop, not on the critical path. |
| **Ubuntu 20.04** | Standard support **ended 2025-05-31**. ESM (Ubuntu Pro) to **2030**; free personal tier: ≤5 machines, arm64 OK, `esm-apps` covers universe. `pro attach` on L4T focal is community-proven, not Canonical-certified. → Phase 4 gains a `pro attach` step. |
| **ROS 2 Humble** | EOL **2027-05-31**. Source-build on focal remains the standard JP5 path; no new breakage reported 2025-26 (setuptools 58.2.0 pin etc. still apply); `packages.ros.org/ros2/ubuntu/dists/focal` still serves. Active distros mid-2026: Jazzy (→2029), Kilted, Lyrical (new LTS, 2026-05, →2031). **Both JP5 and Humble are EOL by mid-2027 — the end-state is a frozen-but-modern stack; the forward path afterward is containers (below), and that's fine.** |
| RoboStack | `robostack-humble` channel exists for linux-aarch64, actively maintained (pushed 2026-06-11). A real alternative to source-building for CPU-side ROS, but conda ROS won't link L4T CUDA/TensorRT bits — noted as fallback, not the plan. |
| **jetson-containers** | Prebuilt `dustynv/ros:humble-*-l4t-r35.{1.0..4.1}` images exist (newest build 2023-12, ~5-6 GB). **On JP5, CUDA/cuDNN/TensorRT live INSIDE the image** (not host-mounted like JP4), and NVIDIA states r35.x images run across r35.x hosts → an r35.4.1 Humble image runs on the r35.6.4 host. nvidia-container-toolkit ships with JP5. → containers become the sanctioned escape hatch for py3.10-era ML tooling and post-Humble ROS. |
| **PyTorch / ORT on JP5** | Final JP5 PyTorch wheel: **torch 2.1.0 (cp38, CUDA 11.4)** — URL live. onnxruntime-gpu for JP5: **cp38 only** (1.16.0 Jetson Zoo / 1.16.3 ykawa2 GitHub). elinux.org Jetson Zoo is now bot-walled; mirror the wheels too. |
| **whisper.cpp** | Very active (v1.9.1, 2026-06). On Xavier build with `-DGGML_CUDA=1 -DCMAKE_CUDA_ARCHITECTURES=72` (avoids a 10-min PTX JIT stall); recent releases may assume newer CUDA/gcc than 11.4/gcc-9 — **pin a release that still builds on JP5**. |
| **kokoro-onnx** | Active (v0.5.0, 2026-01; repo pushed 2026-07-05) but **requires Python ≥3.10** — conflicts with JP5's cp38-only GPU ORT. Resolution: run Kokoro on **CPU** ORT in a py3.10 venv (82 M params — CPU is acceptable), or inside a py3.10 container with GPU ORT. Voice stack gets a two-python packaging note (§4.7). |
| openWakeWord | Semi-dormant (last release v0.6.0, 2024-02) but functional and still the de-facto Linux wake-word. microWakeWord moved to OHF-Voice and is ESP32-targeted — not a Jetson drop-in. Keep openWakeWord. |
| OpenAI audio (optional cloud mode) | Realtime S2S: `gpt-realtime-2.1` ($32/$64 per 1M audio tokens in/out) and `-mini` ($10/$20). STT: `gpt-4o-transcribe` ≈$0.006/min, `-mini` ≈$0.003/min. TTS: `gpt-4o-mini-tts` ≈$0.015/min. |
| Spare hardware | **Xavier NX modules available through July 2027** (NVIDIA lifecycle page) — a used devkit/module for off-dog flash rehearsal is a purchasable option this year, not hypothetical. |

### 3.2 CyberDog community / firmware / UI — verified 2026-07-07

**Two findings remove major plan constraints; the rest sharpens Phase 3 scope.**

| Topic | Finding (verified by fetch unless noted) |
|---|---|
| **V1.0.0.94 factory firmware IS publicly downloadable** 🎉 | The May review concluded V1.0.0.94 "is NOT publicly mirrored" — **wrong as of tonight**. The official CDN serves all three CyberDog 1 builds; the build-hash suffixes are published in [MiRoboticsLab/cyberdog_ros2 discussion #133](https://github.com/MiRoboticsLab/cyberdog_ros2/discussions/133) (posted by the official `mi-CyberDog` account, 2022-02-09): **V1.0.0.94** `http://cdn.cnbj2m.fds.api.mi-img.com/cyberdog-package/build/athena_foxy_2022.01.14_emmc_nvme_V1.0.0.94_release_b1b4a851ca.tgz` — HEAD 200 OK, **5,058,308,096 bytes**, MD5 `b1b4a851ca59c19956b0039de316ee41`. Also V1.0.0.82 (2021.09.26, `_45bed14190.tgz`) and V1.0.0.66 (5.08 GB, not 3 GB as the runbook says). **No V1.0.1.x exists — V1.0.0.94 is the final CyberDog 1 firmware, and it's exactly what this dog runs.** → Layer 4 strategy simplifies enormously (§4.3). Download NOW; the CDN has survived 4.5 years but is not guaranteed. |
| **zbwu Issue #1 ("missing athena_defconfig") is NOT a real defect** | The reporter's own follow-up (2023-01-02): the error was a **non-recursive clone artifact**. `arch/arm64/configs/athena_defconfig` exists in `athena_l4t_kernel` (HTTP 200 verified). Remaining errors were missing host deps (`flex`, cross-gcc). → Plan §6 unknown #3 is retired. The `/proc/config.gz` snapshot remains useful as a cross-check, not as a reconstruction necessity. |
| **zbwu r35.1 port: what actually works** (README, verified) | Works: wireless, BT, ethernet, **CAN**, GPU/CUDA, NVMe, USB3/OTG, debug UART, **fan/tach/PWM**, HDMI, GPIO, **RealSense, color camera, stereo camera**. Not tested: MCU-sensors, GPS, touchpad. **Not supported: mic array, speaker.** Locomotion explicitly out of scope ("only contains the Xavier NX part"). |
| **Camera + IMU drivers are ALREADY ported to 5.10** | `athena_l4t_nvidia` carries `nv_ov13b10.c`, `nv_ov7251.c` (+ mode tables, headers); defconfig has `CONFIG_NV_VIDEO_OV13B10=m`, `CONFIG_NV_VIDEO_OV7251=m`. BMI160 sources present (`nvs_bmi160.c` + iio bmi160). GPIO expander via generic `CONFIG_GPIO_PCA953X=y` (covers TCA6424). → Phase 3's feared camera-driver port is **already done**. |
| **The remaining driver gap is AUDIO — and the sources are open** | `tas5805m` (amp) and `rt5680` (codec) are **absent** from zbwu's 5.10 tree — hence "mic/speaker not supported". Both exist in Xiaomi's **open stock 4.9 kernel repo `MiRoboticsLab/cyberdog_tegra_kernel`** (`sound/soc/codecs/rt5680.{c,h}`, `tas5805m.{c,h}`) along with the stock DT trio `tegra194-mi-k91.dts` / `-audio.dtsi` / `-camera.dtsi`. → Phase 3's real new work = forward-port 2 codec drivers 4.9→5.10 + re-author the audio DT nodes. (This repo was missing from plan §5 entirely.) |
| **zbwu's DTS strategy differs from the plan's assumption** | He did **not** port `tegra194-mi-k91.dts`; he rebased CyberDog onto NVIDIA's devkit DTS: `tegra194-p3668-0001-p2151-0000.dts` with `model = "Xiaomi Cyberdog"`. Consistent with the TNSPEC finding (§2.2: Xiaomi flashed with the devkit-emmc board spec). → Phase 3 should **extend zbwu's proven-booting p3668-based DTS** and use stock `mi-k91.dts`/dtsi as the wiring reference, not port it wholesale. |
| zbwu ecosystem is frozen but complete-ish | `athena_l4t_sdk` last commit 2022-08-20; 2 pristine forks; no successor project anywhere (GitHub/zhihu/CSDN searches). Sibling repos: `athena_locomotion` (2022-09), `athena_motorcontrol` (branch `gd32f303`), `GD32_SPINE` — the **motor/spine MCUs are GD32F303** (plan §3 says "STM32" for the peripheral MCUs; the motor domain at least is GD32). |
| MiRoboticsLab: nothing new for CyberDog 1 | v1.3.0 (2024-01-17) remains the last release; post-2024 activity is CyberDog 2 / vision-stack only. Flashing wiki still live and unchanged (flashall.sh + forced-recovery + black cable). |
| **A 2025 brick case validates the paranoia** | NVIDIA forum (Mar 2025): owner bricked a CyberDog doing a Clonezilla NVMe backup interrupted mid-write; never recovered (thread closed unresolved). Takeaways codified in §4.3: cross-L4T-release cloning fails; eMMC work via `l4t_initrd_flash.sh`; never run block-level tools against the live disk without a plan. Our layered dd/tar backups + rescue drill are exactly the right defense. |
| **Foxglove → Lichtblick swap** | Foxglove Studio v2 is closed + **account-gated** (free tier: 3 users/5 devices, fine but SaaS-tied). **Lichtblick** (BMW's MPL-2.0 fork): v1.26.0 (2026-06-17), 3–4-week release cadence, desktop + browser, speaks the foxglove-bridge WebSocket protocol. **`foxglove_bridge` is MIT, maintained, and installable as `ros-humble-foxglove-bridge` from apt.** → Phase 9 primary: foxglove_bridge + Lichtblick; Foxglove-free-tier as optional extra. |
| USB gadget console (no disassembly!) | Community docs + tonight's service list (`serial-getty@ttyGS0.service` running): the USB-C download port exposes **RNDIS network (192.168.55.1) AND a gadget serial login console (ttyGS0)** once the kernel is up. Not a cboot console (that's still ttyTCU0, unreachable), but it means a JP5 boot that reaches systemd is debuggable **without Wi-Fi**. Carry the same gadget config into the JP5 rootfs and the rescue initrd. |
| Misc community intel | Stock creds `pi/123`, `root/123` (change on JP5!). Dreame was the ODM (factory Wi-Fi profiles baked in stock image). XiaoAi endpoints (`access.speech.ai.xiaomi.com`) confirm the voice stack's cloud dependency. One unverified lead: a second SSH-able "R"/MCU domain at `192.168.55.233` (MAVProxyUser notes) — check during Phase 5. |

## 4. Plan deltas — the optimized plan

Each delta names the plan section it amends. The main plan has been edited to match;
this section preserves the *why*.

### D1 — Retarget: JP 5.1.6 / L4T r35.6.4 (amends plan title, §1, §9, §11)

r35.6.4 (2026-02-04) is a security-fix drop-in over r35.6.2 — same kernel 5.10,
Ubuntu 20.04, CUDA 11.4 — and is the **final** JetPack 5 line for Xavier NX (JP5 EOL
Q3 2026). Every `r35.6.2` reference becomes `r35.6.4`. Fork branch name:
`cyberdog-humble-r35.6.4`.

### D2 — NEW Phase 0.5: boot-path disambiguation (inserts between Phase 0 and 1)

Motivation: §2.3/§2.4 — two extlinux.conf copies exist and the April conclusions are
confounded; kernel/DTB file-loading is unproven on this cboot. **1–2 evenings, 3–4
reboots, every step reversible.** Schedule on a night with the next day free (worst
case is a ~30-min forced-recovery revert).

1. **Which file does cboot read?** Append marker `cyberdog.src=nvme` to `LABEL
   primary`'s APPEND in the **NVMe** copy only. Reboot. `grep cyberdog.src /proc/cmdline`.
   - Present → cboot reads the NVMe copy → April's "DEFAULT ignored" result stands
     (that test *did* edit the NVMe copy). Boot pivot = NVMe `/boot`, as designed.
   - Absent → repeat with `cyberdog.src=emmcapp` in the **eMMC APP** copy
     (mount `/dev/mmcblk0p1` rw — file-level edit, p01 dd-dump in hand). Present after
     reboot → **boot pivot lives on eMMC APP p1**, and the April DEFAULT/menu tests
     were testing a file cboot never read.
2. **If the pivot is the eMMC copy: re-run the DEFAULT-field test there** (marker on
   `LABEL second`'s APPEND + `DEFAULT second`). If cboot honors it, the original
   **dual-LABEL design is resurrected**: JP4 and JP5 live as two permanent labels and
   switching = flipping one `DEFAULT` word — strictly safer than rewriting `primary`
   in place. Adopt it in Phase 2 if proven.
3. **FDT-from-file rehearsal** (on whichever FS is live): make a copy of
   `tegra194-mi-k91.dtb`, change only its `model` string (append `-fdttest` via
   `dtc`), point `FDT` at the copy, reboot, read `/proc/device-tree/model`.
   - Suffix visible → cboot loads DTBs from files → JP4/JP5 can pair kernels with
     their own DTBs without touching the eMMC DTB partition. This single test
     de-risks the entire Phase 2/4 switching design.
   - Not visible / boot fails → **stop and redesign Phase 2** before any partition
     surgery (JP4/JP5 cannot share partition-sourced DTBs; options: partition-DTB
     swap scripts with dumps in hand, or single-kernel approaches). Finding this now
     instead of in Phase 4 is the point of Phase 0.5.
4. Revert all files; write results into `PHASE0_BOOT_MECHANISM_FINDINGS.md` v2.

(`LINUX`-from-file gets its definitive test naturally in Phase 4, where `uname -r`
5.10-vs-4.9 discriminates unambiguously; if FDT file-loading works, LINUX file-loading
— the same extlinux loader path — is near-certain.)

### D3 — Backup & recovery restructure (amends plan §8; runbook; recovery procedures)

1. **Layer 3b (bootloader media) — NEW, partially done tonight.** QSPI NOR
   (`mtdblock0`, 32 MiB) + `mmcblk0boot{0,1}` dumped to
   `~/cyberdog-forensics-2026-04-22/qspi-boot-dump-2026-07-07/` with SHA256SUMS.
   Replicate to backup SSD + second medium next session. Recovery matrix gains:
   "bootloader/QSPI corrupted → restore exact `qspi-mtdblock0.img` via RCM +
   flash tools" — an *exact-state* restore that sidesteps every version/ratchet question.
2. **Layer 4 upgrade: V1.0.0.94 factory image** (§3.2). Download the exact stock
   firmware (5.06 GB, MD5-verifiable) + keep V1.0.0.66 as secondary. The old
   "V1.0.0.66 baseline + Layer 1 userspace + Layer 4b BL re-apply" contortion is
   **demoted from primary recovery path to historical note** — factory reflash is now
   simply `V1.0.0.94 flashall.sh`, byte-identical to what shipped on this dog.
   Layer 4b (OTA BL payloads) still gets copied (cheap, already scripted) but is no
   longer load-bearing.
3. **Mirror-now list (JP5 EOL Q3 2026)** — one x86 evening, ~25 GB:
   r35.6.4 trio (driver pkg + sample rootfs + public_sources), r32.5.2 pair,
   apt-repo snapshot of `repo.download.nvidia.com/jetson/{common,t194}/dists/r35.6`,
   JP5 python wheels (torch 2.1.0 cp38, onnxruntime-gpu 1.16.x cp38),
   V1.0.0.94 + V1.0.0.66 firmware, zbwu's four repos + `MiRoboticsLab/cyberdog_tegra_kernel`
   + `cyberdog_{locomotion,motor_sdk,ros2,ws}` clones. Everything the project depends
   on must survive NVIDIA/Xiaomi link-rot.
4. **Codified don'ts** (from the 2025 brick case, §3.2): no whole-disk imaging of a
   live disk from a possibly-flaky host; no cross-L4T-release rootfs cloning; eMMC
   writes only via `l4t_initrd_flash.sh`/recovery mode or dd-restore of our own dumps.

### D4 — Phase 2 v3: rescue initrd first, then offline surgery (rewrites plan §10)

§2.5: online shrink is impossible. New sequence:

1. **Build a RAM-only rescue boot entry** (2–3 evenings): JP4 kernel + custom initrd
   (busybox + dropbear/sshd + the stock configfs USB-gadget script for RNDIS
   192.168.55.1 **and ttyGS0 serial console**), added as an extlinux label/DEFAULT
   target per Phase 0.5 findings. It never mounts NVMe → from it, `nvme0n1p1` is
   free for `e2fsck + resize2fs + parted`.
2. Rehearse: boot rescue, SSH in over USB, `touch` nothing, reboot back. Twice.
3. **Offline surgery** (1 evening): shrink p1 117→50 GB, create p2 (JP5 root, 50 GB)
   + p3 (`/data`, ~17 GB). Verify JP4 boots. UUIDs into MANIFEST.
4. The rescue entry is **permanent infrastructure**: it also converts several
   recovery-matrix rows from "forced-recovery + x86 host" to "boot rescue label,
   fix over SSH" — including a botched extlinux edit, as long as the rescue label
   itself stays intact.

*Fallback if rescue-initrd work stalls:* loopback-file JP5 rootfs (`/jp5root.img` on
p1, mounted by a custom JP5 initrd) — zero partition surgery, modest I/O overhead,
reversible by deleting one file. Keep in the back pocket; don't lead with it.

### D5 — Phase 3 scope rewrite (amends plan §11)

The kernel work is **smaller and different** than planned:

- `athena_defconfig` **exists** (§3.2) — the synthesis task becomes a *diff-review*
  of it against `/proc/config.gz` (+ additions below), not a reconstruction.
- Cameras (nv_ov13b10, nv_ov7251) + BMI160 + PCA953X-family GPIO: **already in
  zbwu's tree** — rebase, don't rewrite.
- **NEW: audio codec forward-port** — `rt5680` + `tas5805m` from
  `MiRoboticsLab/cyberdog_tegra_kernel` (4.9) to 5.10, plus the
  `tegra194-mi-k91-audio.dtsi` nodes re-authored onto zbwu's p3668-based DTS.
  ASoC API churn 4.9→5.10 is real but bounded (two codec drivers, one machine
  driver / DT graph). This is the critical path to Phase 8 voice.
- **NEW: `rtl8821cu` out-of-tree Wi-Fi driver** (§2.6, morrownr repo) + `rtl8821c`
  BT firmware into the rootfs.
- **NEW: initrd auto-revert hook** — the JP5 initrd's root-mount failure path
  restores `extlinux.conf` from the jp4-saved copy (atomic `rename(2)`), syncs,
  `reboot -f`; plus `panic=15` in APPEND. Converts the most likely Phase 4 failure
  (bad rootfs/fstab/driver) from a 30-min USB rescue into self-healing. Rehearse
  deliberately in Phase 4 (point `root=` at a bogus partition once).
- **DTS strategy** (per §3.2): extend zbwu's `tegra194-p3668-0001-p2151-0000.dts`
  (proven to boot), with stock `mi-k91.dts/dtsi` as the wiring oracle. Do NOT
  attempt a from-scratch mi-k91 port.
- **Optional, off critical path: PREEMPT_RT build** via `rt-patch.sh apply-patches`
  (officially supported for Xavier NX on r35.x, developer-preview). Requires
  rebuilding nvdisplay; the dog is headless in operation so display risk is moot.
  Try only after locomotion is stable on the stock kernel.
- Rebase base: zbwu r35.1 → **r35.6.4** (was r35.6.2).

Net effort: **~15–25 evenings** (was 20–30) — cameras/defconfig removed, audio port added.

### D6 — Phase 4 additions (amends plan §12)

- First-access path is **USB-C gadget (RNDIS 192.168.55.1 + ttyGS0 serial)**, not
  Wi-Fi (8821cu is out-of-tree; assume no Wi-Fi on first boot). Enable
  `nv-l4t-usb-device-mode` in the JP5 rootfs before first boot.
- `pro attach` (Ubuntu Pro free tier) on the JP5 rootfs → focal security updates to
  2030 (esm-apps covers universe; arm64 supported; community-proven on L4T).
- Auto-revert rehearsal (D5) is a Phase 4 gate before any real JP5 rootfs boot.

### D7 — Phase 5 additions (amends plan §13)

- **Thermal/fan gate (NEW, early):** zbwu lists fan/tach/PWM as working on r35.1 —
  verify on r35.6.4 rebase *before* GPU-heavy bring-up: `nvfancontrol` profile, fan
  spins under `tegrastats` soak, thermal zones sane. Sealed chassis + summer +
  15 W mode = the one hardware-damage risk software can cause. Baseline (stock,
  idle, fan `quiet`): CPU 56 °C / GPU 53.5 °C.
- **MCU power-gating capture (NEW, do on JP4 side before Phase 2):** §2.7 — zero
  ttyUSB devices exist at idle; the stock stack powers MCUs on demand. On the JP4
  system, trigger stand/motion while logging `udevadm monitor` + TCA6424 GPIO states
  to learn the enable sequence; otherwise Phase 5 will stare at absent devices.
  (Also chase the unverified `192.168.55.233` "R-domain" lead while stock still runs.)
- Audio bring-up in 5.6 now has real content: the D5 codec port lands here
  (aplay/arecord + UCM), feeding Phase 8.
- Motor-domain MCUs are **GD32F303** (zbwu `athena_motorcontrol`, `GD32_SPINE`) —
  correct the §3 hardware-map "STM32" assumption where it matters (firmware tooling,
  if ever needed).

### D8 — NEW Track S: simulation-first Humble port (amends plan §9/§14 sequencing)

The Galactic→Humble port of `cyberdog_locomotion` + `cyberdog_ws` is pure x86 work
(plan already owns a `cyberdog_simulator` reference). **Start it in Phase 1, not
Phase 6**: port + build + walk-in-sim on the x86 host while Phases 2–5 grind through
hardware. Phase 6 on-device then becomes deploy-and-integrate (~12–18 evenings
instead of 20–25), and any locomotion-port showstopper surfaces **before** the
destructive phases, while abort is still free. Validates the Phase-0 "walking needs
no closed code" thesis end-to-end, in software, months earlier.

### D9 — Phase 6 notes (amends plan §14)

- Humble-on-focal source build: still the right call in 2026 (§3.1 — no new
  breakage; RoboStack aarch64 noted as fallback for CPU-side nodes only).
- Acknowledge the horizon: Humble EOL 2027-05, JP5 EOL 2026-Q3. The end-state is a
  **frozen-but-modern** stack; that is the hardware's ceiling and it's fine. The
  forward path afterward is containers (D10), not another base-OS port.

### D10 — Container layer as sanctioned escape hatch (NEW cross-cutting, plan §14/§16)

Install docker + nvidia-container-toolkit on the JP5 side (kernel 5.10; CUDA lives
inside JP5-era images so r35.4.1 images run on the r35.6.4 host). Uses: (a) py3.10+
ML tooling that cp38 can't host, (b) prebuilt `dustynv/ros:humble-*-l4t-r35.4.1`
as build-cache/fallback for Humble, (c) post-Humble-EOL ROS distros later without
touching the base OS. Keep the *robot* base (locomotion, drivers, bringup) bare-metal.

### D11 — Phase 8 voice-stack packaging fix (amends plan §16)

- **Two-python reality on JP5** (§3.1): GPU wheels (torch 2.1.0, onnxruntime-gpu
  1.16.x) are **cp38-only**; `kokoro-onnx` needs **py≥3.10**. Resolution: whisper.cpp
  (C++, CUDA `CMAKE_CUDA_ARCHITECTURES=72`, pin a release that builds on CUDA
  11.4/gcc-9) for STT; **Kokoro on CPU ORT in a py3.10 venv** (82 M params — CPU is
  fine) or in a py3.10 container with GPU ORT. Wake word: openWakeWord (py3.8-ok,
  semi-dormant but functional; microWakeWord is ESP32-targeted — not applicable).
- Mirror the cp38 wheels now (D3.3) — Jetson Zoo is already bot-walled.
- **Optional cloud mode**, prices sane for hobby use: `gpt-4o-mini-transcribe`
  (~$0.003/min) / `gpt-realtime-2.1-mini` for full S2S. Local pipeline stays the
  default/offline path; cloud is a latency/quality upgrade behind a flag.
- XiaoAi remnants (`/params/audio/token.toml`, `access.speech.ai.xiaomi.com` blobs):
  confirmed dead-cloud, drop list unchanged.

### D12 — Phase 9 UI swap: Lichtblick (amends plan §17)

`foxglove_bridge` (MIT, `apt install ros-humble-foxglove-bridge`) + **Lichtblick**
(MPL-2.0, v1.26.0 2026-06, 3–4-week cadence, desktop + browser) as the primary UI.
Foxglove Studio free tier (account-gated SaaS) optional. rosbridge_suite still fine
for the thin custom web UI. Change stock passwords (`pi/123`, `root/123`, `mi`)
during Phase 4 hardening — they are community-documented.

## 5. Revised sequencing & effort

```
Phase 0   (finish)   ~3 ev   mirrors (D3.3) + SSD replication (L3b, L4b, L4-v94) +
                             rescue drill + backup-of-backup + MCU capture (D7) + tag
Phase 0.5 (NEW)      1–2 ev  boot-path disambiguation (D2)  ← gates Phase 2 design
Phase 1              ~3 ev   x86 env (r35.6.4)  ── Track S starts here (D8, ~8–10 ev,
                             overlaps everything; pure software)
Phase 2 v3           ~4 ev   rescue initrd + rehearse + offline shrink (D4)
Phase 3              15–25   r35.6.4 rebase + audio-codec port + 8821cu + auto-revert
                             initrd (+ optional RT later) (D5)
Phase 4              ~5 ev   first JP5 boot via USB-gadget access (D6)
Phase 5              20–30   bring-up: CAN→motors→MCUs→I²C→cameras→thermal→audio (D7)
Phase 6              12–18   deploy Track S output on-device (D8/D9)
Phase 7–10           ~28 ev  unchanged in shape (voice per D11, UI per D12)
────────────────────────────────────────────────────────────────────────
total ≈ 92–128 evenings ≈ 4–6 months at current cadence (unchanged headline;
risk profile substantially better: 2 project-killers retired, 2 new gates added
where failures are cheap)
```

## 6. Next-actions checklist (supersedes "Pending Phase 0 work" everywhere)

> **Progress 2026-07-08.** Items 1 (first on-dog copy) and 6 (R-domain probe) done;
> the boot re-test and MCU-motion capture need the owner at the keyboard (reboots /
> triggering motion). Executable kits committed under repo `tools/`.

1. ✅ **Mirror-now — FIRST copy on the dog's NVMe** (`~/cyberdog-mirror-2026-07/`, ~18 GB,
   script `tools/mirror-fetch-all.sh`). Verified 2026-07-08: **V1.0.0.94 MD5
   `b1b4a851ca59c19956b0039de316ee41` + byte-exact 5,058,308,096** ✓; V1.0.0.66 MD5
   `bbcc37a86afe512b8a04ee6c1c05d867` ✓; r35.6.4 trio + r32.5.2 pair all pass `bzip2 -t`
   integrity ✓; torch 2.1.0 cp38 + onnxruntime-gpu 1.16.3 cp38 present; 14 git mirrors all valid. **On-disk confirmation
   of Phase 3 scope** (D5): audio codecs `rt5680.{c,h}`/`tas5805m.{c,h}` + stock
   `tegra194-mi-k91{,-audio,-camera}.dts(i)` present in `cyberdog_tegra_kernel`;
   `athena_defconfig` + `nv_ov13b10.c`/`nv_ov7251.c` present in zbwu's tree; zbwu DTS is
   p3668-based (has `common/tegra194-audio-p3668.dtsi` as an audio starting point).
   *Still TODO:* this is one copy on the same disk being repartitioned in Phase 2 — **must
   be rsync'd to the backup SSD + a second medium before Phase 2** (it is NOT yet a backup).
2. **[dog + SSD]** Attach `CYBERDOG_BACKUP`: copy Layer 4b (`/opt/ota_package/*`,
   pending since May) + **Layer 3b** (`qspi-boot-dump-2026-07-07/`) + move the
   mirrors in; `zstd -t` spot-checks.
3. **[x86]** Rescue drill (runbook §5) — unchanged, still mandatory.
4. **[x86 + 2nd medium]** Backup-of-backup (runbook §6).
5. **[dog, 1 evening]** **Phase 0.5** (D2). Update
   `PHASE0_BOOT_MECHANISM_FINDINGS.md` with v2 results.
6. **[dog, JP4 side]** MCU power-gating capture + `192.168.55.233` check (D7) —
   do while the stock stack still runs daily.
7. Tag `v0.1-phase0-complete`; start Phase 1 + Track S.
