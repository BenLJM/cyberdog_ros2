#!/bin/bash
# Phase 2 §3 — build the RAM rescue initrd (PHASE2_RUNBOOK.md §3)
#
# Base: the LIVE stock initrd from eMMC APP p1 (the file cboot actually loads,
# proven Phase 0.5). Additions:
#   - static busybox (254 applets) under /bb, PATH-appended (stock tools win)
#   - OpenSSH sshd, key-only root login, REAL host keys (same fingerprint as JP4)
#   - partition-surgery toolchain: parted sgdisk resize2fs e2fsck mkfs.ext4
#     tune2fs dumpe2fs lsblk partprobe wipefs zstd rsync scp
#   - USB-gadget bring-up (RNDIS usb0 = 192.168.55.1 + ACM ttyGS0), same
#     VID/PID/MACs as the stock nv-l4t-usb-device-mode gadget
#   - /init that NEVER touches the NVMe, then hands PID1 to busybox init
#     (proper reaping + sshd/getty respawn)
#   - rescue-boot-switch / back-to-jp4 one-key escape hatch
#
# Output: /home/mi/phase2/initrd-rescue (+ sha256). Run as root.
set -euo pipefail

[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }

OUT_DIR=/home/mi/phase2
WORK=${WORK:-/tmp/claude-1000/-home-mi/141756d7-9afa-4b37-87f6-f728db1a03bc/scratchpad/rescue-build}
ROOT="$WORK/root"
SRC_INITRD=/mnt/emmc-app/boot/initrd

mountpoint -q /mnt/emmc-app || mount /dev/mmcblk0p1 /mnt/emmc-app
[ -f "$SRC_INITRD" ] || { echo "missing $SRC_INITRD"; exit 1; }

rm -rf "$ROOT"; mkdir -p "$ROOT"
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

# ---------- surgery + transfer tools ----------
for b in /sbin/parted /sbin/partprobe /sbin/sgdisk /sbin/resize2fs /sbin/e2fsck \
         /sbin/tune2fs /sbin/dumpe2fs /sbin/wipefs /bin/lsblk \
         /usr/bin/zstd /usr/bin/rsync /usr/bin/scp; do
    copy_bin "$b"
done
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

. /etc/rescue-banner > /dev/kmsg 2>&1 || true
echo "rescue: ready — ssh root@192.168.55.1" > /dev/kmsg
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

# ---------- repack ----------
mkdir -p "$OUT_DIR"
( cd "$ROOT" && find . | cpio -H newc -o --quiet | gzip -9 ) > "$OUT_DIR/initrd-rescue"
chmod 644 "$OUT_DIR/initrd-rescue"
sha256sum "$OUT_DIR/initrd-rescue" | tee "$OUT_DIR/initrd-rescue.sha256"
echo "== unpacked size: $(du -sh "$ROOT" | cut -f1), packed: $(du -h "$OUT_DIR/initrd-rescue" | cut -f1)"
echo "== build OK"
