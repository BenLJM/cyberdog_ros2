# Phase 5 — peripheral bring-up STATUS (2026-07-20)

Snapshot taken live on JP5 (5.10.216-tegra) right after Wi-Fi came up, over the
Mac→laptop→USB bridge and directly over Wi-Fi (10.0.0.219). The Wi-Fi fix's
TCA6424 reset-hog (see PHASE4_BOOT_RESULTS) restored power to the whole
GPIO-gated regulator tree, so cameras/sensors/gps rails are now ON — that
unblocked a lot here.

| Peripheral | State | Notes |
|---|---|---|
| **Wi-Fi / BT** | ✅ working | wlan0 associates from clean boot; rtk_btusb loads FW. Done (Phase 4). |
| **CAN (motors)** | ✅ interface up | `can0` registers (c310000; c320000 disabled by the athena DTS by design). `ip link set can0 up type can bitrate 1000000` → **state ERROR-ACTIVE, no bus errors** = healthy. The boot-time "Missing controller reset / probe failed" is a transient EPROBE before BPMP resets are ready; it retries and registers at t≈20s. **Motors actually moving needs the motor controllers powered + cyberdog_motor_sdk + owner present.** |
| **Sensors (hwmon)** | ✅ 6 hwmon | thermal + power monitors (INA3221 etc.) up. |
| **Cameras** | ❌ blocked by RCE firmware (CONFIRMED) | 3 v4l2 nodes correctly mapped (video0/1=ov7251@2-0061/62, video2=ov13b10@2-0036); all subdevs `bound`; **media graph is perfect** (`media-ctl -p`: every link ENABLED, formats set — ov13b10 SRGGB10 4208x3120, ov7251 SBGGR10 640x480). So it is NOT a sensor-streaming/media config issue. On `v4l2-ctl --stream-mmap` the kernel sends the capture-setup IVC to the RCE and it **times out** — dmesg: `vi_capture_setup → tegra_capture_ivc_tx → response timeout → rce full reset retry 2/3,3/3 → "vi capture setup failed"`. And `tegra-camera-rtcpu.c` has **no request_firmware path** — it only resets the RCE and boot-syncs to firmware already placed in the carveout **by the bootloader**. We keep the r32.5 Xiaomi cboot → the RCE runs the r32.x firmware (`sha1=0`), which handshakes (subdevs bind) but does not speak the 5.10 capture protocol. **Fix requires updating the RCE firmware the bootloader loads = a QSPI/boot-firmware change — the exact brick-risk the dual-boot design avoids. Owner decision + RCM ready + present required; do NOT do it remotely/unattended.** This is the one peripheral the old-bootloader/new-kernel split cannot support without touching boot firmware. |
| **IMU (BMI160)** | ❌ via MCU, not direct i2c | No iio device. Confirmed against the JP4 live DT: a `bmi160@69` node DOES exist (on `i2c@c240000`/bus-1, int on AON AA,2, mount matrices) **but it is `status="disabled"` on JP4 too** — the factory stack does NOT use the direct i2c IMU. Real IMU data flows through the **MCU coprocessor** (like motors/TOF) → part of the MCU subsystem below, not a simple DT node. (One could enable `bmi160@69` on JP5 to get a raw iio device, but the CyberDog software reads IMU from the MCU, so it wouldn't feed the stack.) |
| **Audio** | ⏳ DTS authoring pending | Codec .ko (rt5680/tas5805m) built + framework-agnostic. `tegra194-mi-k91-audio.dtsi` is still the PLACEHOLDER. Phase 5.6 = re-author against **nvidia,tegra186-ape** + `nvidia-audio-card,*` (per the corrected pivot). Route/mic binding needs real HW. |

## What's genuinely remaining (and what it needs)

**The big remaining piece is the MCU coprocessor subsystem.** The three GD32/
STM32 MCUs (head/body/rear, the "R-domain" reachable at 192.168.55.233 over
l4tbr0) own the motors, IMU, TOF, LEDs and touch — the Jetson talks to them and
the cyberdog_ros2 stack consumes their data. Bringing the robot to life on JP5
means porting that bridge (udev enable-sequence capture — the pre-Phase-2
prereq still not done — then the motor/sensor SDK), and it's what makes motors/
IMU/TOF "work" rather than just "the CAN interface is up". This is genuinely
multi-session and needs the owner present to trigger motion.

Tractable remotely (each = a DTB/kernel rebuild + reboot, verify over the bridge):
- **Audio DTS** (Phase 5.6) — author against nvidia,tegra186-ape; validation
  needs HW (aplay/arecord with a human listening).

Blocked / needs a decision:
- **Cameras** — the RCE firmware is bootloader-loaded (r32.5 carveout) against
  a 5.10 capture stack; a real fix likely means touching the QSPI bootloader —
  the one thing the whole dual-boot design avoids. First cheap thing to try:
  a media-ctl + sensor-register + strobe-gpio pass to rule out a
  sensor-streaming config issue before concluding it's the bootloader.

Needs the owner physically present (cannot be validated remotely):
- Motors moving, IMU/TOF sanity (all via the MCU subsystem), camera image
  quality, audio playback/mic.

## Debug access (reusable)
Mac → owner laptop `ben@10.0.0.176` → USB → CyberDog `192.168.55.1`; JP5 also
reachable directly over Wi-Fi at `10.0.0.219` (JP4 host keys reused → no
known_hosts churn). JP5 `mi` sudo needs the password (scratchpad, not in repo);
JP4 `mi` is passwordless. apt works on JP5 (full focal + L4T sources).
