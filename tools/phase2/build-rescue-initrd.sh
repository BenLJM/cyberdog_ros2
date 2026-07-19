#!/bin/bash
# Phase 2 §3 — build the RAM rescue system (PHASE2_RUNBOOK.md §3), TWO-STAGE.
#
# 2026-07-12 incident: cboot's ramdisk buffer cannot hold the previous 13 MB
# monolithic initrd-rescue — it silently fell back to the stock /boot/initrd
# (QSPI cboot string: "Ramdisk size ... greater than allocated size"), booting
# JP4 with the rescue APPEND. Proven-safe envelope = the stock initrd
# (7.06 MB packed / 16 MB raw). Hence the split:
#
#   STAGE 1  /boot/initrd-rescue        (~2 MB, loaded by cboot)
#       static busybox + /init that mounts eMMC APP p1 (NEVER the NVMe),
#       sha256-verifies the bundle, unpacks it into a tmpfs and switch_roots
#       into it. Fallback matrix on any bundle problem:
#         SUCCESS marker on pivot  -> boot JP4 (surgery already done)
#         arm flag still present   -> boot JP4 (surgery never started; safe)
#         otherwise                -> HOLD in stage-1 shell, never touch NVMe
#           (covers "flag consumed + bundle broken" = possible mid-surgery
#            power loss; console/ttyTCU0 only, USB laptop territory)
#
#   STAGE 2  /boot/rescue-bundle.cpio.gz  (the previous full rescue system,
#       byte-for-byte the same content, just not loaded by cboot anymore):
#       - static busybox (254 applets) under /bb, PATH-appended
#       - OpenSSH sshd, key-only root login, REAL host keys (same fingerprint)
#       - surgery toolchain: parted sgdisk resize2fs e2fsck mkfs.ext4
#         tune2fs dumpe2fs lsblk partprobe wipefs zstd rsync scp
#       - Wi-Fi userspace (driver+fw in kernel) + USB gadget (RNDIS + ACM)
#       - /init that NEVER touches the NVMe, hands PID1 to busybox init
#       - rescue-autorun gated surgery + rescue-boot-switch / back-to-jp4
#
# Output: /home/mi/phase2/{initrd-rescue,rescue-bundle.cpio.gz} (+ .sha256).
# Run as root. Hard size gates enforce stage-1 < stock envelope.
set -euo pipefail

[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }

OUT_DIR=/home/mi/phase2
WORK=${WORK:-/tmp/claude-1000/-home-mi/141756d7-9afa-4b37-87f6-f728db1a03bc/scratchpad/rescue-build}
ROOT="$WORK/root"
SRC_INITRD=/mnt/emmc-app/boot/initrd

mountpoint -q /mnt/emmc-app || mount /dev/mmcblk0p1 /mnt/emmc-app
[ -f "$SRC_INITRD" ] || { echo "missing $SRC_INITRD"; exit 1; }

rm -rf "$ROOT"; mkdir -p "$ROOT"
chmod 700 "$WORK"    # tree holds Wi-Fi PSK + host keys while building
( cd "$ROOT" && zcat "$SRC_INITRD" | cpio -idm --quiet )
echo "== stock initrd unpacked: $(du -sh "$ROOT" | cut -f1)"

# ---------- helpers ----------
copy_bin() {  # copy_bin <abs path> [dest-rel-dir]
    local src=$1 dest=${2:-} d
    [ -e "$src" ] || { echo "MISSING $src"; exit 1; }
    d="$ROOT${dest:-$(dirname "$src")}"
    mkdir -p "$d"
    cp -a "$src" "$d/"
    # resolve symlinked binaries (e.g. /usr/bin/scp is real, parted real)
    ldd "$src" 2>/dev/null | awk '/=>/ {print $3} /^\t\// {print $1}' | while read -r lib; do
        [ -n "$lib" ] || continue
        local rel="$ROOT$lib"
        if [ ! -e "$rel" ]; then
            mkdir -p "$(dirname "$rel")"
            # copy the symlink chain target-first
            cp -aL "$lib" "$rel"
        fi
    done
}

# ---------- device nodes (kernel opens /dev/console before devtmpfs) ----------
mkdir -p "$ROOT/dev"
[ -e "$ROOT/dev/console" ] || mknod -m 600 "$ROOT/dev/console" c 5 1
[ -e "$ROOT/dev/null" ]    || mknod -m 666 "$ROOT/dev/null"    c 1 3
[ -e "$ROOT/dev/kmsg" ]    || mknod -m 644 "$ROOT/dev/kmsg"    c 1 11
[ -e "$ROOT/dev/tty" ]     || mknod -m 666 "$ROOT/dev/tty"     c 5 0
[ -e "$ROOT/dev/urandom" ] || mknod -m 666 "$ROOT/dev/urandom" c 1 9

# ---------- busybox ----------
cp -a /bin/busybox "$ROOT/bin/busybox"
mkdir -p "$ROOT/bb"
for a in $(/bin/busybox --list); do ln -sf /bin/busybox "$ROOT/bb/$a"; done
# 2026-07-19 incident fixes, both found live in the armed rescue:
# - the stock-initrd base has NO /bin/sh — #!/bin/sh scripts (udhcpc hook!)
#   silently failed to exec, so the DHCP lease was never applied
[ -e "$ROOT/bin/sh" ] || ln -sf /bin/busybox "$ROOT/bin/sh"
# - resize2fs REFUSES to run when it cannot determine mount state (no mtab);
#   e2fsck only warns, so this bit exactly once — at the S2 shrink
ln -sf /proc/mounts "$ROOT/etc/mtab"

# ---------- surgery + transfer tools ----------
for b in /sbin/parted /sbin/partprobe /sbin/sgdisk /sbin/resize2fs /sbin/e2fsck \
         /sbin/tune2fs /sbin/dumpe2fs /sbin/wipefs /bin/lsblk /sbin/mke2fs /sbin/blkid \
         /usr/bin/zstd /usr/bin/rsync /usr/bin/scp; do
    copy_bin "$b"
done
# 2026-07-16 review (critical): gate_tools + surgery S8 need the NAME mkfs.ext4;
# on Ubuntu 18.04 it is a symlink to mke2fs (copied above with its lib closure)
ln -sf mke2fs "$ROOT/sbin/mkfs.ext4"
cp -a /etc/mke2fs.conf "$ROOT/etc/mke2fs.conf"

# ---------- sshd ----------
copy_bin /usr/sbin/sshd
mkdir -p "$ROOT/etc/ssh" "$ROOT/root/.ssh" "$ROOT/run/sshd"
for k in rsa ecdsa ed25519; do
    cp -a "/etc/ssh/ssh_host_${k}_key" "/etc/ssh/ssh_host_${k}_key.pub" "$ROOT/etc/ssh/"
done
[ -f /etc/ssh/moduli ] && cp -a /etc/ssh/moduli "$ROOT/etc/ssh/"
cp /home/mi/.ssh/authorized_keys "$ROOT/root/.ssh/authorized_keys"
chown -R root:root "$ROOT/root"
chmod 700 "$ROOT/root" "$ROOT/root/.ssh"
chmod 600 "$ROOT/root/.ssh/authorized_keys"

cat > "$ROOT/etc/ssh/sshd_config" <<'EOF'
Port 22
HostKey /etc/ssh/ssh_host_rsa_key
HostKey /etc/ssh/ssh_host_ecdsa_key
HostKey /etc/ssh/ssh_host_ed25519_key
PermitRootLogin prohibit-password
PasswordAuthentication no
ChallengeResponseAuthentication no
UsePAM no
UseDNS no
PidFile /run/sshd.pid
Subsystem sftp internal-sftp
EOF

cat > "$ROOT/etc/passwd" <<'EOF'
root:x:0:0:root:/root:/bin/bash
sshd:x:110:65534::/run/sshd:/usr/sbin/nologin
EOF
cat > "$ROOT/etc/group" <<'EOF'
root:x:0:
tty:x:5:
nogroup:x:65534:
EOF
cat > "$ROOT/etc/shadow" <<'EOF'
root:*:19000:0:99999:7:::
sshd:*:19000:0:99999:7:::
EOF
chmod 640 "$ROOT/etc/shadow"
cat > "$ROOT/etc/nsswitch.conf" <<'EOF'
passwd: files
group: files
shadow: files
hosts: files
EOF

# ---------- Wi-Fi userspace (driver + firmware are BUILT INTO the stock kernel:
#             CONFIG_RTL8821CU=y + CONFIG_EXTRA_FIRMWARE=rtl8821cu_fw) ----------
copy_bin /sbin/wpa_supplicant
# iw (power_save off) — copy from wherever the host has it; skip if absent
for c in /sbin/iw /usr/sbin/iw /usr/bin/iw; do
    if [ -e "$c" ]; then copy_bin "$c"; break; fi
done
install -m 600 /dev/null "$ROOT/etc/wpa_supplicant.conf"   # never world-readable, even mid-write
{
    echo "ctrl_interface=/var/run/wpa_supplicant"
    for f in /etc/NetworkManager/system-connections/*; do
        [ -f "$f" ] || continue
        ssid=$(sed -n 's/^ssid=//p' "$f" | head -1)
        psk=$(sed -n 's/^psk=//p' "$f" | head -1)
        [ -n "$ssid" ] && [ -n "$psk" ] || continue
        printf 'network={\n\tssid="%s"\n\tpsk="%s"\n}\n' "$ssid" "$psk"
    done
} > "$ROOT/etc/wpa_supplicant.conf"
chmod 600 "$ROOT/etc/wpa_supplicant.conf"
grep -q 'network=' "$ROOT/etc/wpa_supplicant.conf" \
    || echo "WARN: no Wi-Fi credentials captured — rescue will be USB/serial only"

cat > "$ROOT/etc/udhcpc.script" <<'EOF'
#!/bin/sh
# minimal udhcpc hook for the rescue initramfs
case "$1" in bound|renew) ;; *) exit 0 ;; esac
ifconfig "$interface" "$ip" netmask "${subnet:-255.255.255.0}" up
while /bb/route del default 2>/dev/null; do :; done
[ -n "${router%% *}" ] && /bb/route add default gw "${router%% *}" "$interface"
echo "${router%% *}" > /var/run/wifi.router
echo "rescue: wifi $interface $ip" > /dev/kmsg
exit 0
EOF
chmod 755 "$ROOT/etc/udhcpc.script"

# ---------- rescue tools ----------
cat > "$ROOT/sbin/rescue-boot-switch" <<'EOF'
#!/bin/bash
# rescue-boot-switch {primary|jp4|jp5|rescue} — flip DEFAULT in the eMMC APP p1
# extlinux.conf (the boot pivot, Phase 0.5-proven). Atomic tmp+mv.
set -euo pipefail
t=${1:-}
case "$t" in primary|jp4|jp5|rescue) ;; *) echo "usage: rescue-boot-switch {primary|jp4|jp5|rescue}"; exit 1 ;; esac
m=/tmp/bootpivot; mkdir -p "$m"
own_mount=0
if ! grep -q "^/dev/mmcblk0p1 $m " /proc/mounts; then
    mount /dev/mmcblk0p1 "$m"; own_mount=1
fi
c="$m/boot/extlinux/extlinux.conf"
[ -f "$c" ] || { echo "ERROR: $c not found"; exit 1; }
if ! grep -q "^LABEL ${t}\$" "$c"; then
    if [ "$t" = jp4 ] && grep -q "^LABEL primary\$" "$c"; then
        echo "note: no LABEL jp4 yet, using LABEL primary"; t=primary
    else
        echo "ERROR: LABEL ${t} does not exist in extlinux.conf"; exit 1
    fi
fi
sed "s/^DEFAULT .*/DEFAULT ${t}/" "$c" > "$c.tmp"
grep -q "^DEFAULT ${t}\$" "$c.tmp" || { echo "ERROR: rewrite verification failed"; rm -f "$c.tmp"; exit 1; }
mv "$c.tmp" "$c"
sync
[ "$own_mount" = 1 ] && umount "$m"
echo "OK: DEFAULT -> ${t}.  Reboot with:  reboot -f"
EOF
chmod 755 "$ROOT/sbin/rescue-boot-switch"

install -m 755 /home/mi/phase2/rescue-surgery.sh "$ROOT/sbin/rescue-surgery"
install -m 755 /home/mi/phase2/rescue-autorun.sh "$ROOT/sbin/rescue-autorun"

cat > "$ROOT/sbin/back-to-jp4" <<'EOF'
#!/bin/bash
# one-key escape hatch: point DEFAULT back at JP4 and reboot immediately
set -e
rescue-boot-switch jp4
sync
echo "Rebooting to JP4 in 3s..."; sleep 3
exec /bb/reboot -f
EOF
chmod 755 "$ROOT/sbin/back-to-jp4"

cat > "$ROOT/etc/rescue-banner" <<'EOF'
echo '================ CyberDog RESCUE (RAM, JP4 kernel) ================'
echo ' NVMe is NOT mounted. Rootfs is a RAM initramfs.'
echo '   back-to-jp4                     -> flip DEFAULT to JP4 and reboot'
echo '   rescue-boot-switch {primary|jp4|jp5|rescue}  -> flip only'
echo '   surgery tools: parted sgdisk resize2fs e2fsck mkfs.ext4 tune2fs'
echo '                  dumpe2fs lsblk partprobe wipefs zstd rsync'
echo '   extras in /bb (busybox): vi less ps top ip brctl cpio ...'
echo ' Network: usb0 RNDIS 192.168.55.1 (host: static 192.168.55.100/24)'
echo ' Serial : ACM /dev/ttyGS0 115200 on the same USB cable'
echo '==================================================================='
EOF

cat > "$ROOT/etc/profile" <<'EOF'
export PATH=/bin:/sbin:/usr/bin:/usr/sbin:/bb
export PS1='rescue# '
. /etc/rescue-banner
EOF
mkdir -p "$ROOT/root"
cat > "$ROOT/root/.bashrc" <<'EOF'
export PATH=/bin:/sbin:/usr/bin:/usr/sbin:/bb
export PS1='rescue# '
. /etc/rescue-banner
EOF

# ---------- gadget bring-up + sysinit ----------
cat > "$ROOT/etc/rc.rescue" <<'EOF'
#!/bin/bash
# sysinit for the rescue initramfs. Sets up the USB gadget (RNDIS + ACM),
# same VID/PID/MACs as stock nv-l4t-usb-device-mode so the host sees a
# familiar device. NEVER touches the NVMe.
export PATH=/bin:/sbin:/usr/bin:/usr/sbin:/bb

echo "rescue: rc.rescue starting" > /dev/kmsg

mount -t configfs none /sys/kernel/config 2>/dev/null || true
mkdir -p /dev/pts /tmp /var/log /var/run /run/sshd
mount -t devpts devpts /dev/pts 2>/dev/null || true
mount -t tmpfs tmpfs /tmp 2>/dev/null || true
hostname cyberdog-rescue 2>/dev/null || true
ip link set lo up 2>/dev/null || ifconfig lo 127.0.0.1 up || true

# --- USB gadget ---
udc=""
for i in $(seq 60); do
    udc=$(ls /sys/class/udc 2>/dev/null | head -1)
    [ -n "$udc" ] && break
    sleep 1
done
if [ -n "$udc" ]; then
    g=/sys/kernel/config/usb_gadget/l4t
    mkdir -p "$g"; cd "$g"
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
        echo rescue-no-serial > strings/0x409/serialnumber
    fi
    echo "NVIDIA" > strings/0x409/manufacturer
    echo "CyberDog Rescue" > strings/0x409/product
    mkdir -p configs/c.1
    # RNDIS must be first for Windows hosts
    mkdir -p functions/rndis.usb0
    echo de:9f:89:2d:cf:80 > functions/rndis.usb0/host_addr
    echo de:9f:89:2d:cf:81 > functions/rndis.usb0/dev_addr
    ln -sf functions/rndis.usb0 configs/c.1/
    echo 1 > os_desc/use
    echo 0xcd > os_desc/b_vendor_code
    echo MSFT100 > os_desc/qw_sign
    echo RNDIS   > functions/rndis.usb0/os_desc/interface.rndis/compatible_id
    echo 5162001 > functions/rndis.usb0/os_desc/interface.rndis/sub_compatible_id
    ln -sf configs/c.1 os_desc 2>/dev/null || true
    mkdir -p functions/acm.GS0
    ln -sf functions/acm.GS0 configs/c.1/
    echo "$udc" > UDC
    cd /
    # u_ether netdev appears as usb0 (rndis.usb0 instance)
    for i in $(seq 10); do
        [ -d /sys/class/net/usb0 ] && break
        sleep 1
    done
    if [ -d /sys/class/net/usb0 ]; then
        ifconfig usb0 192.168.55.1 netmask 255.255.255.0 up \
            && echo "rescue: usb0 up at 192.168.55.1" > /dev/kmsg \
            || echo "rescue: usb0 config FAILED" > /dev/kmsg
    else
        echo "rescue: usb0 netdev never appeared" > /dev/kmsg
    fi
else
    echo "rescue: no UDC found — gadget skipped (ttyTCU0 only)" > /dev/kmsg
fi

# --- Wi-Fi, best effort in background (driver+fw built into this kernel) ---
(
    # 2026-07-19: the RTL8821CU is an internal USB chip that enumerated at
    # t=66s in rescue — the old 45 s wait missed it by 4 s. Wait 180 s.
    for i in $(seq 180); do [ -d /sys/class/net/wlan0 ] && break; sleep 1; done
    if [ -d /sys/class/net/wlan0 ] && [ -s /etc/wpa_supplicant.conf ]; then
        ifconfig wlan0 up 2>/dev/null || true
        # kill USB-WiFi power-save + keep the link hot (keepalive below)
        command -v iw >/dev/null 2>&1 && iw dev wlan0 set power_save off 2>/dev/null
        wpa_supplicant -B -i wlan0 -c /etc/wpa_supplicant.conf >/dev/null 2>&1
        if /bb/udhcpc -i wlan0 -s /etc/udhcpc.script -t 15 -T 3 -n -q >/dev/null 2>&1; then
            wip=$(/bb/ip -4 addr show wlan0 2>/dev/null | sed -n 's/.*inet \([0-9.]*\).*/\1/p' | head -1)
            command -v iw >/dev/null 2>&1 && iw dev wlan0 set power_save off 2>/dev/null
            gw=$(cat /var/run/wifi.router 2>/dev/null)
            if [ -n "$gw" ]; then
                ( while :; do ping -c 1 -W 2 "$gw" >/dev/null 2>&1; sleep 5; done ) &
            fi
            echo "rescue: Wi-Fi UP — ssh root@${wip} (keepalive->${gw:-none})" > /dev/kmsg
        else
            echo "rescue: Wi-Fi join failed — USB gadget/serial still available" > /dev/kmsg
        fi
    else
        echo "rescue: no wlan0 or no Wi-Fi conf — USB gadget/serial only" > /dev/kmsg
    fi
) &

. /etc/rescue-banner > /dev/kmsg 2>&1 || true
echo "rescue: ready — ssh root@192.168.55.1 (USB) or Wi-Fi IP above" > /dev/kmsg
EOF
chmod 755 "$ROOT/etc/rc.rescue"

cat > "$ROOT/etc/inittab" <<'EOF'
::sysinit:/etc/rc.rescue
::once:/sbin/rescue-autorun
::respawn:/usr/sbin/sshd -D -e -f /etc/ssh/sshd_config
::respawn:/bb/getty -n -l /bin/bash 115200 ttyGS0 vt100
::askfirst:/bin/bash
::ctrlaltdel:/bb/reboot -f
::shutdown:/bb/sync
EOF

# ---------- /init (PID1) ----------
[ -f "$ROOT/init" ] && mv "$ROOT/init" "$ROOT/init.stock"
cat > "$ROOT/init" <<'EOF'
#!/bin/bash
# CyberDog rescue initramfs — Phase 2 (PHASE2_RUNBOOK.md §3).
# Stays in RAM forever; NEVER mounts the NVMe. Hands PID1 to busybox init
# for zombie reaping + sshd/getty respawn. Escape hatch: back-to-jp4.
export PATH=/bin:/sbin:/usr/bin:/usr/sbin:/bb

mount -t proc proc /proc          || exec /bin/bash
mount -t devtmpfs none /dev 2>/dev/null || true
mount -t sysfs sysfs /sys         || exec /bin/bash
echo "rescue: init taking over (cyberdog.rescue marker: $(grep -o 'cyberdog.rescue=1' /proc/cmdline || echo absent))" > /dev/kmsg

exec /bb/init
EOF
chmod 755 "$ROOT/init"

# ---------- repack stage 2: the bundle (NOT loaded by cboot) ----------
mkdir -p "$OUT_DIR"
# stage-1 unpacks the bundle into a 192m tmpfs — keep comfortable headroom
BUNDLE_RAW=$(du -sb "$ROOT" | cut -f1)
[ "$BUNDLE_RAW" -lt 160000000 ] || { echo "FATAL: bundle raw ${BUNDLE_RAW}B exceeds 192m tmpfs headroom"; exit 1; }
install -m 600 /dev/null "$OUT_DIR/rescue-bundle.cpio.gz"   # embeds Wi-Fi PSK + SSH host keys
( cd "$ROOT" && find . | cpio -H newc -o --quiet | gzip -9 ) > "$OUT_DIR/rescue-bundle.cpio.gz"
BUNDLE_SHA=$(sha256sum "$OUT_DIR/rescue-bundle.cpio.gz" | cut -d' ' -f1)
echo "$BUNDLE_SHA  $OUT_DIR/rescue-bundle.cpio.gz" > "$OUT_DIR/rescue-bundle.cpio.gz.sha256"
echo "== bundle: $(du -sh "$ROOT" | cut -f1) unpacked, $(du -h "$OUT_DIR/rescue-bundle.cpio.gz" | cut -f1) packed ($BUNDLE_SHA)"

# ---------- build stage 1: tiny loader initramfs (THIS is what cboot loads) ----------
S1="$WORK/s1root"
rm -rf "$S1"
mkdir -p "$S1/bin" "$S1/bb" "$S1/dev" "$S1/etc" "$S1/proc" "$S1/sys" \
         "$S1/mnt/pivot" "$S1/rescue" "$S1/newroot" "$S1/tmp"

# applets stage-1 depends on must exist in this busybox
# (list to a file first: `--list | grep -q` under pipefail races on SIGPIPE)
/bin/busybox --list > "$WORK/bb.applets"
for a in sh ash init mount umount switch_root sha256sum cpio zcat mkdir \
         sleep cat echo ls stat sync reboot grep mv date; do
    grep -qx "$a" "$WORK/bb.applets" || { echo "busybox lacks applet: $a"; exit 1; }
done
cp -a /bin/busybox "$S1/bin/busybox"
ln -sf busybox "$S1/bin/sh"
for a in $(/bin/busybox --list); do ln -sf /bin/busybox "$S1/bb/$a"; done

mknod -m 600 "$S1/dev/console" c 5 1
mknod -m 666 "$S1/dev/null"    c 1 3
mknod -m 644 "$S1/dev/kmsg"    c 1 11
mknod -m 666 "$S1/dev/tty"     c 5 0
mknod -m 666 "$S1/dev/urandom" c 1 9

# the sha the bundle on the pivot must match, frozen at build time
echo "$BUNDLE_SHA  /mnt/pivot/boot/rescue-bundle.cpio.gz" > "$S1/etc/bundle.sha256"

cat > "$S1/init" <<'EOF'
#!/bin/sh
# CyberDog rescue STAGE 1 (tiny, fits cboot's ramdisk buffer — 2026-07-12).
# Mounts eMMC APP p1 (NEVER the NVMe), verifies + unpacks the stage-2 bundle
# into a tmpfs, switch_roots into it. Fallback matrix on bundle failure
# (STARTED marker is written by rescue-autorun in the same transaction that
# consumes the arm flag, BEFORE any disk write):
#   SUCCESS marker            -> boot JP4 (surgery already done)
#   arm flag intact           -> defuse flag (mv .stale) + boot JP4 (never started)
#   STARTED without SUCCESS   -> HOLD (possible mid-surgery power loss)
#   none of the above         -> boot JP4 (never armed; e.g. rehearsal boot)
# Accepted residual risks (documented, 2026-07-16 review):
#   - if cboot/the kernel cannot load/unpack THIS initramfs at all, the kernel
#     mounts root= from cbootargs => plain JP4 boot (fail-open; same as the
#     2026-07-12 incident). After a mid-surgery power loss that ALSO corrupts
#     this file, that fallback would mount a half-shrunk NVMe — judged exotic
#     enough to accept in exchange for fail-open on first boot.
#   - if exec switch_root itself fails, PID1 dies => kernel panic (hang).
#     Preconditions are all pre-checked, so this needs a busybox bug.
export PATH=/bb:/bin:/sbin

mount -t proc proc /proc 2>/dev/null
mount -t devtmpfs none /dev 2>/dev/null
mount -t sysfs sysfs /sys 2>/dev/null

klog() { echo "rescue-s1: $*" > /dev/kmsg 2>/dev/null; echo "rescue-s1: $*" > /dev/console 2>/dev/null; }
# breadcrumb on the pivot for post-mortem from JP4 (check-after-reboot.sh reads it)
slog() {
    klog "$*"
    if [ -w /mnt/pivot/boot ]; then
        echo "$(date 2>/dev/null) stage-1: $*" >> /mnt/pivot/boot/phase2-stage1.log 2>/dev/null
        sync
    fi
}

HOLD() {
    klog "HOLD: $* — NVMe untouched. Shells on ttyTCU0 (serial) and console."
    while :; do sh < /dev/ttyTCU0 > /dev/ttyTCU0 2>&1; sleep 1; done &
    while :; do sh < /dev/console > /dev/console 2>&1; sleep 1; done
}

BOOT_JP4() {
    slog "falling back to JP4: $*"
    umount /mnt/pivot 2>/dev/null || umount -l /mnt/pivot 2>/dev/null
    i=0
    while [ "$i" -lt 60 ]; do [ -b /dev/nvme0n1p1 ] && break; sleep 1; i=$((i+1)); done
    [ -b /dev/nvme0n1p1 ] || HOLD "nvme0n1p1 never appeared"
    mount /dev/nvme0n1p1 /newroot || HOLD "JP4 root mount failed"
    # /sbin/init is an ABSOLUTE symlink to /lib/systemd/systemd on Ubuntu 18.04:
    # -x would resolve it against stage-1's root (dangling) — accept a symlink
    [ -x /newroot/sbin/init ] || [ -L /newroot/sbin/init ] || HOLD "no /sbin/init on JP4 root"
    klog "switch_root -> JP4"
    umount /proc /sys 2>/dev/null
    exec switch_root -c /dev/console /newroot /sbin/init
}

klog "stage-1 up"
i=0
while [ "$i" -lt 30 ]; do [ -b /dev/mmcblk0p1 ] && break; sleep 1; i=$((i+1)); done
[ -b /dev/mmcblk0p1 ] || HOLD "mmcblk0p1 never appeared"
mount /dev/mmcblk0p1 /mnt/pivot || HOLD "cannot mount boot pivot"

B=/mnt/pivot/boot/rescue-bundle.cpio.gz
FLAG=/mnt/pivot/boot/phase2-autorun-surgery
OKM=/mnt/pivot/boot/phase2-surgery.SUCCESS
STARTED=/mnt/pivot/boot/phase2-surgery.STARTED

bundle_bad() {
    slog "bundle problem: $*"
    [ -f "$OKM" ] && BOOT_JP4 "surgery already SUCCESS; rescue not critical"
    if [ -f "$FLAG" ]; then
        # defuse: a stale live flag must never fire an unattended surgery later.
        # VERIFY the rename took (ro pivot / IO error) — a live flag left behind
        # while we report it defused is the worst combination.
        mv "$FLAG" "$FLAG.stale" 2>/dev/null
        sync
        if [ -f "$FLAG" ]; then
            slog "HOLD: arm flag could NOT be defused (pivot read-only?)"
            HOLD "live arm flag undismissable — refusing to proceed"
        fi
        BOOT_JP4 "arm flag intact => surgery never started (flag defused to .stale)"
    fi
    if [ -f "$STARTED" ]; then
        slog "HOLD: STARTED without SUCCESS => possible mid-surgery power loss"
        HOLD "STARTED without SUCCESS => possible mid-surgery power loss"
    fi
    BOOT_JP4 "never armed (no flag/STARTED/SUCCESS) — benign, e.g. rehearsal boot"
}

[ -f "$B" ] || bundle_bad "missing $B"
sha256sum -c /etc/bundle.sha256 || bundle_bad "sha256 mismatch"
mount -t tmpfs -o size=192m,mode=0755 tmpfs /rescue || bundle_bad "tmpfs mount failed"
( cd /rescue && zcat "$B" | cpio -idm ) || bundle_bad "unpack failed"
[ -x /rescue/init ] || bundle_bad "bundle has no executable /init"
grep -q ' /rescue tmpfs ' /proc/mounts || bundle_bad "/rescue is not the tmpfs mountpoint"

klog "bundle verified — switch_root into full rescue"
umount /mnt/pivot 2>/dev/null || umount -l /mnt/pivot 2>/dev/null
umount /proc /sys 2>/dev/null
exec switch_root -c /dev/console /rescue /init
EOF
chmod 755 "$S1/init"

install -m 600 /dev/null "$OUT_DIR/initrd-rescue"
( cd "$S1" && find . | cpio -H newc -o --quiet | gzip -9 ) > "$OUT_DIR/initrd-rescue"
sha256sum "$OUT_DIR/initrd-rescue" | tee "$OUT_DIR/initrd-rescue.sha256"

# ---------- hard size gates: stage-1 must fit the PROVEN cboot envelope ----------
STOCK_PACKED=$(stat -c%s "$SRC_INITRD")
STOCK_RAW=$(zcat "$SRC_INITRD" | wc -c)
S1_PACKED=$(stat -c%s "$OUT_DIR/initrd-rescue")
S1_RAW=$(zcat "$OUT_DIR/initrd-rescue" | wc -c)
echo "== stage-1: packed $S1_PACKED B (stock $STOCK_PACKED B), raw $S1_RAW B (stock $STOCK_RAW B)"
[ "$S1_PACKED" -lt "$STOCK_PACKED" ] || { echo "FATAL: stage-1 packed >= stock envelope"; exit 1; }
[ "$S1_RAW"    -lt "$STOCK_RAW"    ] || { echo "FATAL: stage-1 raw >= stock envelope"; exit 1; }
echo "== build OK (two-stage)"
