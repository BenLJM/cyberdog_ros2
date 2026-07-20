# Phase 4 — first JP5 boot RESULTS (2026-07-20)

**JP5 boots.** The first real boot of the ported system reached
`multi-user.target` + graphical, on kernel **5.10.216-tegra**, hostname
`cyberdog-jp5`, root on `nvme0n1p2`. Kernel-from-file (cboot → `/boot-jp5/`),
our busybox initrd + auto-revert guard, `switch_root`, the Ubuntu 20.04 rootfs,
our self-built module set, and the morrownr `8821cu` module (loads, refcnt 0 —
nothing to bind, see below) all work. `jp5-boot-ok.service` cleared the boot
counter. **The hard part of the port — a bootable JP5 — is done.**

**UPDATE 2026-07-20 — Wi-Fi is now FIXED and works from a clean boot.** JP5
brings up `wlan0`, associates with the AP, and is reachable at its usual DHCP
IP with no manual steps. See "Wi-Fi fix" below. Cameras/motors/audio remain
Phase-5 items. The dog currently boots **JP5** (DEFAULT jp5); `boot-switch`
back to JP4 any time.

## How Phase 4 was executed (unattended, no x86 host needed)

Owner opted for unattended completion + cancelled the JP4 walk test. All of
step §12⑥ was done **natively on the dog** (arm64), no x86 laptop:

1. Unpacked `Tegra_Linux_Sample-Root-Filesystem_R35.6.4` → p2, then the L4T BSP.
2. `apply_binaries.sh` ran natively via a **fake `qemu-aarch64-static`**
   (`#!/bin/sh\nexec "$@"`) — the L4T scripts only test that the file exists;
   on an arm64 host qemu is never actually invoked. This removes the x86
   dependency from rootfs assembly.
3. chroot config (`tools/phase4/configure-jp5-rootfs.sh`): `mi` user via
   `l4t_create_default_user` (oem-config disabled → headless-safe first boot),
   fstab by UUID (p2 `/`, p3 `/data` nofail), stock modules removed and our
   `modules-5.10.216-tegra.tar.gz` unpacked + `8821cu.ko` into `extra/` +
   `depmod`, BT firmware, `nv-l4t-bootloader-config` masked + `apt-mark hold`
   (QSPI brick guard, plan §7), `jp5-boot-ok.service`, ssh + JP4 host keys +
   authorized_keys, NetworkManager profiles from JP4, gadget service enabled.
4. Staged `/boot-jp5/` (rename map), rewrote the `LABEL jp5` stanza, regenerated
   the three `*-saved` copies (all pre-committed, §12③ — done 2026-07-19).
5. Rehearsal (hid both inits on p2) → guard reverted, `jp5-revert.log` carried
   the initrd build stamp. Then the real boot (above).

## Headless debug bridge (how JP5 was reached with Wi-Fi down)

No exposed UART; Wi-Fi is the internal chip that's currently dead. The access
path used — **reusable for all Phase-5 work**:

```
Mac ──Wi-Fi──▶ owner's Ubuntu laptop (ben@10.0.0.176, "Ben-Nano")
                     └──USB cable to CyberDog download port──▶ 192.168.55.1  (+ /dev/ttyACM0 serial)
```

The laptop's own ed25519 key is authorized on **both** JP4 `mi` and the p2 JP5
`mi` `authorized_keys`, so `ssh ben@10.0.0.176 'ssh mi@192.168.55.1 …'` reaches
CyberDog over USB regardless of Wi-Fi. p2 journald is persistent
(`/var/log/journal`), so each JP5 boot's logs survive a revert and are readable
from JP4 by mounting p2.

## Why Wi-Fi (and cameras / GPS / RealSense) don't work — root cause

`ip a` has no `wlan0`; `8821cu` is loaded but bound to nothing. The chip is
never **powered on**. The power chain, traced end-to-end on the running JP5:

```
wifi_bt_switch (reg-userspace-consumer)
  └─ default-supply = <&vdd_3v3_wlan_bt>            (regulator-fixed)
        └─ gpio = <&gpio_expand2 21>                 enable pin
              └─ gpio_expand2 = tca6424@22 on i2c@3160000 (Linux i2c-0)
                    └─ ✗ FAILS TO PROBE
```

Kernel log:
```
pca953x 0-0022: failed writing register
pca953x: probe of 0-0022 failed with error -121   (EREMOTEIO)
pca953x: probe of 0-0023 failed with error -121
```
`i2cdetect -y 0` sees only `0x50` (an EEPROM) — the two **TCA6424 GPIO
expanders at 0x22/0x23 do not ACK on the bus**. Because `gpio_expand2` never
registers, ~18 GPIO-gated `regulator-fixed` nodes (`vdd_3v3_wlan_bt`,
`vdd_*_gps`, camera `vana`/`vif`, mcu/realsense rails …) stay in
`EPROBE_DEFER (-517)` forever, so `wifi_bt_switch`, `gps_switch`,
`realsense_switch`, `mcu_sensor_switch`, and `ov7251`/`ov13b10` are all
unpowered. Additionally `bc00000.rtcpu:hsp-vm1: response timeout` — the camera
RTCPU/SPE firmware isn't answering (separate, cameras-only).

**Not a wrong-bus DT error**: the factory JP4 DT
(`docs/dtb-live-jp4-2026-07.dts.gz`) has the same node at
`/i2c@3160000/tca6424@23`. Same bus, JP4 works, JP5 doesn't → the difference is
5.10-side i2c timing / expander power / pinmux, not the DT topology. Bus 0
itself is electrically fine (the 0x50 EEPROM responds), so it's **expander-
specific**, not a dead bus.

## Wi-Fi fix (2026-07-20) — SOLVED, two independent root causes

Traced live over the debug bridge, then fixed and confirmed on a clean boot
(`wlan0` associates on its own, dog reachable over Wi-Fi; BT firmware also
loads via `rtk_btusb`).

**Fix 1 — TCA6424 shared reset (DTB).** The two GPIO expanders on `i2c@3160000`
share one active-low RESET (AON `CC,3`). Xiaomi's 4.9 `gpio-pca953x` pulsed it;
zbwu commented the DT `reset-gpio` out, so on 5.10 the expanders stay in reset
and NAK i2c (`pca953x` probe `-121`) → every GPIO-gated fixed regulator defers
`-517` (no Wi-Fi/BT/camera power). Added a **gpio-hog** driving AON `CC,3` HIGH
from AON-gpio registration — releases both chips before either probes, dodging
the shared-claim / probe-order hazard of `reset-gpios` on the nodes.
`tools/phase3/cyberdog-deltas/jakku-dts/0004-*.patch`. After this: expanders
probe (`i2cdetect` shows `UU` at 0x22/0x23), `vdd-3v3-wlan-bt` enables.

**Fix 2 — xhci host firmware in the initrd.** With power restored, `wlan0`
still didn't appear because the internal RTL8821CU is on the USB *host* bus and
`tegra-xusb 3610000.xhci` failed: it is a **builtin** driver that
`request_firmware()`s `nvidia/tegra194/xusb.bin` during early kernel init —
while our minimal initramfs is root, before `switch_root` — so the rootfs copy
is invisible (`direct load -2` → udev fallback `-110` → probe fails
permanently, USB host bus never comes up). Baking `xusb.bin` into the initramfs
(`build-jp5-initrd.sh`, +80 KB) makes the early direct load succeed. After
this: `usb 1-2.2 idVendor=0bda idProduct=c820`, `8821cu` binds, `wlan0`
connects — from a clean boot, no manual rebind.

## Remaining Phase-5 peripheral items (Fix 1 unblocked their power)

- **Cameras** (`ov7251`/`ov13b10`): the reset-hog restored their regulator
  power, but the camera **RTCPU/SPE firmware** still fails (`bc00000.rtcpu`
  sha1=000…0, HSP response timeouts) — provision that firmware next.
- **Motors** (CAN), **audio** (§5.6 tegra186-ape), **IMU** binding — as scoped.

## Files added this phase

- `tools/phase4/configure-jp5-rootfs.sh` — the chroot config (reproducible).
- `tools/phase4/jp5-net-watchdog.{sh,service,timer}` — headless first-boot net
  safety net (reverts to JP4 after N boots with no network/session). NOTE its
  reboots are **warm** and won't un-wedge the flaky USB Wi-Fi chip; it is a
  coarse "don't strand a headless dog" net, not a Wi-Fi fixer. Default timing
  is deliberately generous.
