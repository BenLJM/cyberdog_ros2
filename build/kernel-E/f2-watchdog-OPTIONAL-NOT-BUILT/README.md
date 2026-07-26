# F2 — hardware watchdog: **RECOMMENDATION IS DO NOT ENABLE IN THIS BATCH**

Nothing in this directory is compiled into `build/kernel-E/out/`.
`tegra194-mi-k91-watchdog.dtsi.OPTIONAL` is a *draft*, deliberately given a
non-`.dtsi` suffix so no `#include` can pick it up by accident.

## What the hardware/driver actually does (read from source, not assumed)

`drivers/watchdog/tegra_wdt_t18x.c` (kernel/nvidia), DT node
`/watchdog@30c0000`, present in the running DTB as:

```
watchdog@30c0000 {
        compatible = "nvidia,tegra-wdt-t18x";
        nvidia,watchdog-index = <0>;  nvidia,timer-index = <7>;
        nvidia,expiry-count = <5>;
        nvidia,enable-on-init;            <-- !!
        nvidia,extend-watchdog-suspend;
        timeout-sec = <120>;
        nvidia,disable-debug-reset;
        status = "disabled";
};
```

Four facts that decide the risk:

1. **`nvidia,enable-on-init` is present.** `tegra_wdt_t18x_probe()` arms the
   counter at probe time. Flipping `status` to `okay` is *not* "register the
   device and wait for userspace" — it starts the watchdog immediately.
2. **But the kernel feeds it itself.** The driver requests a threaded IRQ whose
   whole body is `__tegra_wdt_t18x_ping()`. Expiry level 1 raises a local
   interrupt, the ISR pets the dog. So with nothing in userspace touching
   `/dev/watchdog`, a reset only happens if the kernel cannot run a threaded
   IRQ handler for the full expiry chain (~120 s). That is a genuine hang.
3. **The first userspace open is a one-way door.** `tegra_wdt_t18x_ref()` does
   `disable_irq()` the first time the watchdog is started/pinged from
   userspace. Combined with `CONFIG_WATCHDOG_NOWAYOUT=y`, once systemd (or
   anything else) opens `/dev/watchdog`, the kernel feeder is gone permanently
   and that process becomes a single point of failure — if it stops petting,
   the board resets, and it can never legally close the device.
4. **The reset is a POR.** `nvidia,disable-por-reset` is absent, so
   `WDT_CFG_SYS_PORST_EN` is set. The final expiry is a *system power-on reset*,
   not a warm reset. **This is very likely to destroy the ramoops DRAM
   contents** (unverified either way on this SoC), i.e. the watchdog would turn
   "the dog hangs and I can go poke it" into "the dog silently rebooted and
   left nothing behind". Removing `disable-por-reset`'s counterpart is not an
   option — without POR there is no reset at all (`nvidia,disable-debug-reset`
   is already set, so level-4 debug reset is off too).

## Why "disabled" is not a JP4→JP5 regression

NVIDIA gates this node on ODM data, not on the board file:

* R35 `tegra194-p3668-p3509-overlay.dts` fragment@1: `odm-data = "enable-denver-wdt"` → `status = "okay"`.
* R32 `tegra194-plugin-manager-p3668.dtsi`: `fragement-tegra-wdt-en`, same odm-data key.

Our odmdata does not set that bit, so the Tegra watchdog was **also disabled on
factory JP4**. Enabling it is new, never-validated behaviour on this board — not
the restoration of something the port lost.

## Recommendation

**Do not ship it with kernel E.** Kernel E already carries (a) the nvmap /
capture-ABI core surgery and (b) another path's camera power-domain DTB change.
Adding an automatic resetter on top means that any instability becomes
undiagnosable — you cannot tell an nvmap fault from a watchdog reset, and the
watchdog's POR erases the ramoops evidence that would have told you.

The correct order is: **black box first, resetter second.**

## If the owner wants it anyway — staged recipe

* **Step A** — deploy F1 (cmdline only) and confirm `console-ramoops-0` shows up
  after a normal reboot. Do not proceed until that works.
* **Step B** — deploy `tegra194-mi-k91-watchdog.dtsi.OPTIONAL` *alone*, on top
  of an otherwise-known-good kernel/DTB. Do **not** set systemd's
  `RuntimeWatchdogSec`, do **not** run any watchdog daemon; leave the kernel ISR
  as the only feeder. Confirm `dmesg | grep -i "Tegra WDT init timeout"` and
  then leave the dog idle overnight and under load for a day. Expected: zero
  resets.
* **Step C** — only if B is boring for several days, and only with the owner
  present, consider `RuntimeWatchdogSec=` in `/etc/systemd/system.conf`. Note
  point 3 above: this permanently removes the kernel feeder.
* **Rollback** — restore the previous DTB (`/boot-jp5/tegra194-mi-k91.dtb`) from
  the `.prev-*` backup. If the dog reboot-loops before SSH: the laptop's serial
  console (`ben@10.0.0.176`, `/dev/ttyACM0`, 115200) can pick `rescue`/`primary`
  in the cboot extlinux menu, and the initrd autorevert hook restores
  `extlinux.conf.jp4-saved` after 3 unsuccessful boots.

## Zero-DTB alternative, for a later batch

`CONFIG_SOFT_WATCHDOG` is **not** currently set. Adding `CONFIG_SOFT_WATCHDOG=m`
to `athena_defconfig` would give a `/dev/watchdog` backed by a kernel timer,
usable with systemd `RuntimeWatchdogSec`, with no DT change and no effect at all
until the module is explicitly loaded. It recovers a wedged systemd/userspace
but *not* a hard kernel hang. Not added here — it is an unrequested change to a
batch that already carries core-memory surgery.
