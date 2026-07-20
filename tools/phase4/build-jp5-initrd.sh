#!/bin/bash
# Phase 4 — build the JP5 initramfs (plan §12; RETROSPECTIVE-2026-07-19 H1/H5).
#
# Design: a tiny static-busybox shell in the spirit of the Phase-2 rescue
# stage-1 loader (tools/phase2/build-rescue-initrd.sh). It does exactly four
# things, in order:
#   1. mount devtmpfs/proc/sysfs           (before ANYTHING else)
#   2. bring up the USB gadget console      (RNDIS 192.168.55.1 + ACM ttyGS0 —
#      the only early observability this sealed dog has; PHASE0: no exposed UART)
#   3. run /sbin/jp5-autorevert-hook        (boot-attempt counter + rootfs probe;
#      reverts to JP4 or HOLDs reachable — see tools/phase3/jp5-autorevert-hook.sh)
#   4. mount /dev/nvme0n1p2 ro + switch_root
#
# NO kernel modules are included: every boot-critical driver is =y in the JP5
# kernel (NVMe, EXT4, SDHCI_TEGRA, MMC_BLOCK, XUDC, CONFIGFS — verified against
# the built .config, PHASE3_BUILD_RESULTS).
#
# HARD SIZE GATES (PHASE2_RUNBOOK §3b, 2026-07-12 incident): this cboot's
# ramdisk buffer holds at most the stock initrd — 7,236,790 B packed / 16 MiB
# raw. An oversized initrd is NOT an error at boot: cboot SILENTLY loads the
# stock /boot/initrd instead and the auto-revert safety net vanishes. Both
# gates are enforced here at build time and must be re-checked at staging time
# (stage step re-runs `stat -c%s` before copying to /boot-jp5/).
#
# Run inside the cyberdog-kbuild container (or any arm64 Linux) with
# busybox-static installed:
#   docker run --rm -v ~/projects/cyberdog/build:/work \
#     -v ~/projects/cyberdog/cyberdog_ros2:/repo cyberdog-kbuild \
#     bash /repo/tools/phase4/build-jp5-initrd.sh
# Output: $OUT_DIR/jp5-initrd (+ .sha256). Default OUT_DIR=/work/out/final so
# the initrd travels with the kernel artifacts.
set -euo pipefail

MAX_PACKED=7236790            # stock initrd packed size — PROVEN cboot envelope
MAX_RAW=16777216              # stock initrd raw size (16 MiB)
OUT_DIR=${OUT_DIR:-/work/out/final}
WORK=${WORK:-/tmp/jp5-initrd-build}
HOOK=${HOOK:-/repo/tools/phase3/jp5-autorevert-hook.sh}
BUSYBOX=${BUSYBOX:-/bin/busybox}

[ -f "$HOOK" ] || { echo "FATAL: hook not found at $HOOK (set HOOK=)"; exit 1; }
if [ ! -x "$BUSYBOX" ]; then
    echo "busybox-static not present — installing"
    apt-get update -qq && apt-get install -y -qq busybox-static
fi
[ -x "$BUSYBOX" ] || { echo "FATAL: no busybox at $BUSYBOX"; exit 1; }
# must be static: a dynamic busybox silently dies in an initramfs with no libs.
# Verify positively (a missing/failing ldd must not pass a dynamic binary).
if command -v file >/dev/null 2>&1; then
    file -b "$BUSYBOX" | grep -q 'statically linked' \
        || { echo "FATAL: $BUSYBOX is not statically linked"; exit 1; }
elif command -v ldd >/dev/null 2>&1; then
    if ldd "$BUSYBOX" 2>/dev/null | grep -q '=>'; then
        echo "FATAL: $BUSYBOX is dynamically linked — install busybox-static"; exit 1
    fi
else
    echo "FATAL: neither 'file' nor 'ldd' available — cannot prove busybox is static"; exit 1
fi

R="$WORK/root"
rm -rf "$R"
mkdir -p "$R/bin" "$R/bb" "$R/sbin" "$R/etc" "$R/dev" "$R/proc" "$R/sys" \
         "$R/mnt/bootpivot" "$R/mnt/jp5probe" "$R/newroot" "$R/tmp" \
         "$R/var/run" "$R/usr/bin" "$R/usr/sbin"

# ---------- busybox + applet sanity ----------
cp -a "$BUSYBOX" "$R/bin/busybox"
ln -sf busybox "$R/bin/sh"
"$R/bin/busybox" --list > "$WORK/bb.applets"
for a in sh init mount umount switch_root mkdir sleep cat echo ls sync reboot \
         grep mv cp rm date seq stat head tr ifconfig ip sed ln \
         cmp setsid cttyhack rmdir; do
    grep -qx "$a" "$WORK/bb.applets" || { echo "FATAL: busybox lacks applet: $a"; exit 1; }
done
for a in $(cat "$WORK/bb.applets"); do ln -sf /bin/busybox "$R/bb/$a"; done

# ---------- device nodes (kernel opens /dev/console before devtmpfs) ----------
mknod -m 600 "$R/dev/console" c 5 1
mknod -m 666 "$R/dev/null"    c 1 3
mknod -m 644 "$R/dev/kmsg"    c 1 11
mknod -m 666 "$R/dev/tty"     c 5 0
mknod -m 666 "$R/dev/urandom" c 1 9

# ---------- the auto-revert guard (canonical copy lives in tools/phase3) ----------
install -m 755 "$HOOK" "$R/sbin/jp5-autorevert-hook"

# ---------- tegra-xusb HOST-controller firmware (2026-07-20) ----------
# The tegra-xusb (3610000.xhci) driver is BUILTIN and request_firmware()s
# nvidia/tegra194/xusb.bin during early kernel init — while THIS initramfs is
# still root, before switch_root. The real rootfs copy is therefore invisible
# to it (direct load -2 → udev fallback -110 → probe fails permanently), so the
# USB HOST bus never comes up and the internal RTL8821CU Wi-Fi/BT (which lives
# on that host bus) never enumerates. Bake the firmware into the initramfs so
# the early direct load succeeds. See docs/PHASE4_BOOT_RESULTS.md.
# Source the firmware from the assembled JP5 rootfs or the L4T BSP (it ships in
# the nvidia-l4t-xusb-firmware deb) — NVIDIA proprietary, not committed here:
#   cp <rootfs-or-BSP>/lib/firmware/nvidia/tegra194/xusb.bin \
#      ~/projects/cyberdog/build/firmware/nvidia/tegra194/xusb.bin
XUSB_FW=${XUSB_FW:-/work/firmware/nvidia/tegra194/xusb.bin}
if [ -f "$XUSB_FW" ]; then
    mkdir -p "$R/lib/firmware/nvidia/tegra194"
    cp "$XUSB_FW" "$R/lib/firmware/nvidia/tegra194/xusb.bin"
else
    echo "FATAL: xusb host firmware not found at $XUSB_FW"
    echo "       copy it from the assembled rootfs or L4T BSP:"
    echo "       /lib/firmware/nvidia/tegra194/xusb.bin -> \$(dirname $XUSB_FW)/"
    exit 1
fi

# ---------- USB gadget console (same VID/PID/MACs as stock nv-l4t-usb-device-mode,
#            same shape as the Phase-2 rescue rc.rescue gadget block) ----------
cat > "$R/etc/jp5-gadget.sh" <<'EOF'
#!/bin/sh
# Bring up RNDIS (usb0 192.168.55.1) + ACM (/dev/ttyGS0). Best-effort: a boot
# must never hang here — UDC wait is capped at 15 s (XUDC is =y, normally <2 s).
export PATH=/bb:/bin:/sbin
mount -t configfs none /sys/kernel/config 2>/dev/null
udc=""
i=0
while [ "$i" -lt 15 ]; do
    udc=$(ls /sys/class/udc 2>/dev/null | head -1)
    [ -n "$udc" ] && break
    sleep 1; i=$((i+1))
done
if [ -z "$udc" ]; then
    echo "jp5-init: no UDC after 15s — gadget skipped (fully blind boot)" > /dev/kmsg
    exit 0
fi
g=/sys/kernel/config/usb_gadget/l4t
mkdir -p "$g" && cd "$g" || {
    echo "jp5-init: configfs gadget dir unavailable — gadget skipped" > /dev/kmsg
    exit 0
}
echo 0x0955 > idVendor
echo 0x7020 > idProduct
echo 0x0002 > bcdDevice
echo 0xEF > bDeviceClass
echo 0x02 > bDeviceSubClass
echo 0x01 > bDeviceProtocol
mkdir -p strings/0x409
if [ -f /proc/device-tree/serial-number ]; then
    tr -d '\000' < /proc/device-tree/serial-number > strings/0x409/serialnumber
else
    echo jp5-initrd-no-serial > strings/0x409/serialnumber
fi
echo "NVIDIA" > strings/0x409/manufacturer
echo "CyberDog JP5 initrd" > strings/0x409/product
mkdir -p configs/c.1
mkdir -p functions/rndis.usb0
echo de:9f:89:2d:cf:80 > functions/rndis.usb0/host_addr
echo de:9f:89:2d:cf:81 > functions/rndis.usb0/dev_addr
ln -sf functions/rndis.usb0 configs/c.1/
echo 1 > os_desc/use
echo 0xcd > os_desc/b_vendor_code
echo MSFT100 > os_desc/qw_sign
echo RNDIS   > functions/rndis.usb0/os_desc/interface.rndis/compatible_id
echo 5162001 > functions/rndis.usb0/os_desc/interface.rndis/sub_compatible_id
ln -sf configs/c.1 os_desc 2>/dev/null
mkdir -p functions/acm.GS0
ln -sf functions/acm.GS0 configs/c.1/
echo "$udc" > UDC
cd /
i=0
while [ "$i" -lt 10 ]; do [ -d /sys/class/net/usb0 ] && break; sleep 1; i=$((i+1)); done
if [ -d /sys/class/net/usb0 ]; then
    ifconfig usb0 192.168.55.1 netmask 255.255.255.0 up \
        && echo "jp5-init: gadget up — usb0 192.168.55.1 + ttyGS0" > /dev/kmsg \
        || echo "jp5-init: usb0 config FAILED" > /dev/kmsg
else
    echo "jp5-init: usb0 netdev never appeared" > /dev/kmsg
fi
exit 0
EOF
chmod 755 "$R/etc/jp5-gadget.sh"

# ---------- /init ----------
cat > "$R/init" <<'EOF'
#!/bin/sh
# CyberDog JP5 initramfs (Phase 4). Order matters:
# mounts -> gadget console -> auto-revert guard -> switch_root to nvme0n1p2.
export PATH=/bb:/bin:/sbin

mount -t proc proc /proc 2>/dev/null
mount -t devtmpfs none /dev 2>/dev/null
mount -t sysfs sysfs /sys 2>/dev/null

klog() { echo "jp5-init: $*" > /dev/kmsg 2>/dev/null; echo "jp5-init: $*" > /dev/console 2>/dev/null; }

HOLD() {
    klog "HOLD: $* — shells on ttyGS0 (USB) + console"
    # setsid+cttyhack: give the rescue shell a controlling TTY so Ctrl-C works
    if [ -c /dev/ttyGS0 ]; then
        while :; do setsid cttyhack sh < /dev/ttyGS0 > /dev/ttyGS0 2>&1; sleep 1; done &
    fi
    while :; do setsid cttyhack sh < /dev/console > /dev/console 2>&1; sleep 1; done
}

klog "up ($(cat /etc/jp5-initrd.build 2>/dev/null))"

# 2. earliest possible observability — the sealed dog has no exposed UART
/etc/jp5-gadget.sh || true

# 3. the safety net: counts boot attempts, probes p2, reverts to JP4 or HOLDs.
#    Returns 0 only when the JP5 rootfs looks bootable.
/sbin/jp5-autorevert-hook || HOLD "auto-revert guard returned unexpectedly"

# 4. real root mount (ro — systemd remounts rw per fstab) + switch_root
i=0
while [ "$i" -lt 10 ]; do [ -b /dev/nvme0n1p2 ] && break; sleep 1; i=$((i+1)); done
mount -o ro /dev/nvme0n1p2 /newroot || HOLD "final root mount failed after probe OK"
INIT=/sbin/init
[ -x /newroot$INIT ] || [ -L /newroot$INIT ] || INIT=/lib/systemd/systemd
[ -x /newroot$INIT ] || [ -L /newroot$INIT ] || HOLD "no init on JP5 root"

# hand the gadget back CLEANLY: configfs is a kernel-global namespace that
# survives switch_root. A leftover l4t gadget (even unbound) pins the rndis
# function's refcount — the rootfs nv-l4t-usb-device-mode would get EBUSY
# rewriting MACs and could die mid-setup. Tear the whole thing down
# (success path only — HOLD paths above keep the console alive).
g=/sys/kernel/config/usb_gadget/l4t
if [ -d "$g" ]; then
    echo "" > "$g/UDC" 2>/dev/null
    rm -f "$g/configs/c.1/rndis.usb0" "$g/configs/c.1/acm.GS0" 2>/dev/null
    rm -f "$g/os_desc/c.1" 2>/dev/null
    rmdir "$g/configs/c.1/strings/0x409" "$g/configs/c.1" 2>/dev/null
    rmdir "$g/functions/rndis.usb0" "$g/functions/acm.GS0" 2>/dev/null
    rmdir "$g/strings/0x409" "$g" 2>/dev/null
    [ -d "$g" ] && klog "warn: gadget teardown incomplete — rootfs usb0 may need a re-plug"
fi

klog "switch_root -> JP5 ($INIT)"
umount /sys/kernel/config 2>/dev/null
umount /proc /sys 2>/dev/null
exec switch_root -c /dev/console /newroot "$INIT"
EOF
chmod 755 "$R/init"

# build stamp (shows up in the kmsg banner — proves WHICH initrd cboot loaded)
date -u +"jp5-initrd %Y-%m-%dT%H:%M:%SZ" > "$R/etc/jp5-initrd.build"

# ---------- pack + hard size gates ----------
mkdir -p "$OUT_DIR"
( cd "$R" && find . | cpio -H newc -o --quiet | gzip -9 ) > "$OUT_DIR/jp5-initrd"
PACKED=$(stat -c%s "$OUT_DIR/jp5-initrd")
RAW=$(zcat "$OUT_DIR/jp5-initrd" | wc -c)
echo "== jp5-initrd: packed ${PACKED} B (gate < ${MAX_PACKED}), raw ${RAW} B (gate < ${MAX_RAW})"
[ "$PACKED" -lt "$MAX_PACKED" ] || { echo "FATAL: packed size >= proven cboot envelope — cboot would SILENTLY load the stock initrd instead"; exit 1; }
[ "$RAW" -lt "$MAX_RAW" ] || { echo "FATAL: raw size >= stock envelope"; exit 1; }
( cd "$OUT_DIR" && sha256sum jp5-initrd | tee jp5-initrd.sha256 )   # relative path — portable `sha256sum -c` on the dog
echo "== build OK — stage to eMMC /boot-jp5/initrd (re-check size at staging!)"
