#!/bin/bash
# configure-jp5-rootfs.sh — Phase 4 §12⑥ chroot config, run ON the dog (JP4 side).
# As executed 2026-07-20. p2 (JP5 rootfs) mounted at $R; the L4T BSP tree
# (Linux_for_Tegra with tools/l4t_create_default_user.sh) at $W; artifacts at $A.
# Prereq: sample-rootfs + BSP already unpacked into p2, apply_binaries.sh already
# run (native, via a fake /usr/bin/qemu-aarch64-static = `#!/bin/sh\nexec "$@"`).
#
# Usage:  sudo ./configure-jp5-rootfs.sh <mi-password>
set -euo pipefail
PW="${1:?usage: configure-jp5-rootfs.sh <mi-password>}"
R=${R:-/mnt/jp5root}
W=${W:-$R/.phase4-work/Linux_for_Tegra}
A=${A:-/data/jp5-build-2026-07-19-tegra}
KREL=5.10.216-tegra
REPO=${REPO:-/home/mi/cyberdog_ros2}

echo "== 1. default user mi (oem-config disabled → headless-safe first boot)"
( cd "$W/tools" && ./l4t_create_default_user.sh -u mi -p "$PW" -n cyberdog-jp5 --accept-license )

echo "== 2. fstab by UUID (see docs/MANIFEST.yaml)"
cat > "$R/etc/fstab" <<'FSTAB'
UUID=81fb4c00-f0ed-4d0c-832b-5799db784b88  /      ext4  defaults                                     0 1
UUID=fa0f76a4-1010-43bf-9ee7-b12c3d020360  /data  ext4  defaults,nofail,x-systemd.device-timeout=10  0 2
FSTAB
mkdir -p "$R/data"

echo "== 3. modules: stock out, ours in, 8821cu → extra/, depmod"
rm -rf "$R/lib/modules/$KREL"
tar xzf "$A/modules-$KREL.tar.gz" -C "$R"
mkdir -p "$R/lib/modules/$KREL/extra"
cp "$A/modules/8821cu.ko" "$R/lib/modules/$KREL/extra/"
chroot "$R" depmod -a "$KREL"
grep -q 'extra/8821cu.ko' "$R/lib/modules/$KREL/modules.dep"
echo 8821cu > "$R/etc/modules-load.d/8821cu.conf"

echo "== 4. BT firmware (bare files for the NVIDIA rtk_btusb driver)"
install -m 644 "$A/bt-firmware/rtl8821cu_fw"     "$R/lib/firmware/"
install -m 644 "$A/bt-firmware/rtl8821cu_config" "$R/lib/firmware/"

echo "== 5. bootloader auto-update masked + held (QSPI brick guard, plan §7)"
# `systemctl mask` fails inside the chroot when the unit is a symlink; do it by hand:
ln -sfn /dev/null "$R/etc/systemd/system/nv-l4t-bootloader-config.service"
rm -f "$R/etc/systemd/system/multi-user.target.wants/nv-l4t-bootloader-config.service"
chroot "$R" apt-mark hold nvidia-l4t-bootloader nvidia-l4t-initrd nvidia-l4t-xusb-firmware

echo "== 6. jp5-boot-ok + jp5-net-watchdog (headless safety nets)"
install -m 755 "$REPO/tools/phase4/jp5-boot-ok.sh"        "$R/usr/local/sbin/jp5-boot-ok"
install -m 644 "$REPO/tools/phase4/jp5-boot-ok.service"   "$R/etc/systemd/system/"
install -m 755 "$REPO/tools/phase4/jp5-net-watchdog.sh"   "$R/usr/local/sbin/jp5-net-watchdog"
install -m 644 "$REPO/tools/phase4/jp5-net-watchdog.service" "$R/etc/systemd/system/"
install -m 644 "$REPO/tools/phase4/jp5-net-watchdog.timer"   "$R/etc/systemd/system/"
chroot "$R" systemctl enable jp5-boot-ok.service jp5-net-watchdog.timer

echo "== 7. ssh: enable + host keys (reuse JP4's) + authorized_keys"
chroot "$R" systemctl enable ssh
[ -f "$R/etc/ssh/ssh_host_ed25519_key" ] || cp -a /etc/ssh/ssh_host_* "$R/etc/ssh/"  # or: chroot "$R" ssh-keygen -A
install -d -m 700 "$R/home/mi/.ssh"
install -m 600 /home/mi/.ssh/authorized_keys "$R/home/mi/.ssh/authorized_keys"
MIID=$(grep '^mi:' "$R/etc/passwd" | cut -d: -f3)
chown -R "$MIID:$MIID" "$R/home/mi/.ssh"

echo "== 8. Wi-Fi credentials (NetworkManager keyfiles from JP4)"
install -d -m 755 "$R/etc/NetworkManager/system-connections"
cp -a /etc/NetworkManager/system-connections/. "$R/etc/NetworkManager/system-connections/" 2>/dev/null || true
chmod 600 "$R"/etc/NetworkManager/system-connections/* 2>/dev/null || true

echo "== 9. USB gadget as first access path"
chroot "$R" systemctl enable nv-l4t-usb-device-mode 2>/dev/null || true

echo "== CONFIG COMPLETE =="
