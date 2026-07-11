#!/bin/bash
# Phase 2 rehearsal verdict — run after every Phase-2 reboot, from wherever you
# land (JP4 or rescue). Tells you what booted and the exact next command.
# Style follows phase0.5/check-after-reboot.sh.
set -u

cmdline=$(cat /proc/cmdline)
kernel=$(uname -r)

echo "=== Phase 2 check-after-reboot ==="
echo "kernel : $kernel"

if echo "$cmdline" | grep -q 'cyberdog.rescue=1'; then
    echo "VERDICT: RESCUE environment booted."
    echo " - confirm NVMe untouched:   ! grep nvme /proc/mounts"
    grep -q nvme /proc/mounts && echo "   *** WARNING: something mounted the NVMe! ***" || echo "   OK: no NVMe mounts"
    echo " - confirm gadget:           ip addr show usb0 (expect 192.168.55.1)"
    echo " - from laptop:              ssh root@192.168.55.1"
    echo " - rehearse the escape hatch twice (runbook §4.2):  back-to-jp4"
    exit 0
fi

if [ -f /etc/nv_tegra_release ] && echo "$kernel" | grep -q '^4\.9'; then
    echo "VERDICT: JP4 booted (normal)."
    if mount | grep -q '/mnt/emmc-app'; then :; else sudo mkdir -p /mnt/emmc-app && sudo mount /dev/mmcblk0p1 /mnt/emmc-app; fi
    def=$(awk '/^DEFAULT /{print $2}' /mnt/emmc-app/boot/extlinux/extlinux.conf)
    echo "DEFAULT: $def"
    case "$def" in
        primary)
            echo "State is stock-boot + rescue staged."
            echo "Next rehearsal step: sudo cyberdog-boot-switch rescue && sudo reboot"
            ;;
        rescue)
            echo "*** DEFAULT is rescue but JP4 booted — cboot ignored it?! Investigate before proceeding. ***"
            ;;
        *)
            echo "DEFAULT=$def — unexpected at this stage; investigate."
            ;;
    esac
    echo "If this boot FOLLOWED a successful rescue rehearsal:"
    echo " - record results in docs/PHASE0_BOOT_MECHANISM_FINDINGS.md v3 / runbook §7"
    echo " - rehearsal must pass TWICE before surgery night (runbook §4.2)"
    exit 0
fi

echo "VERDICT: unknown environment — inspect manually. cmdline: $cmdline"
exit 1
