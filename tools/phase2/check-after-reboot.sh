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
    # the APPEND alone does NOT prove the rescue initramfs ran (2026-07-12:
    # cboot's ramdisk buffer rejected the oversized initrd and silently loaded
    # the stock one -> full JP4 booted with this very cmdline). Require the
    # rescue filesystem itself and the absence of systemd.
    if [ -x /sbin/rescue-surgery ] && [ ! -d /run/systemd/system ]; then
        echo "VERDICT: RESCUE environment booted."
        echo " - confirm NVMe untouched:   ! grep nvme /proc/mounts"
        grep -q nvme /proc/mounts && echo "   *** WARNING: something mounted the NVMe! ***" || echo "   OK: no NVMe mounts"
        echo " - confirm gadget:           ip addr show usb0 (expect 192.168.55.1)"
        echo " - from laptop:              ssh root@192.168.55.1"
        echo " - rehearse the escape hatch twice (runbook §4.2):  back-to-jp4"
        exit 0
    fi
    echo "VERDICT: *** JP4 booted WITH the rescue APPEND. Two possible causes: ***"
    echo "  (a) cboot fell back to the stock initrd (loaded size == stock), or"
    echo "  (b) stage-1 ran and deliberately fell back to JP4 (loaded size ~2 MB;"
    echo "      dmesg + phase2-stage1.log say which branch and why)"
    hs=$(od -An -tx1 /proc/device-tree/chosen/linux,initrd-start 2>/dev/null | tr -d ' \n')
    he=$(od -An -tx1 /proc/device-tree/chosen/linux,initrd-end   2>/dev/null | tr -d ' \n')
    if [ -n "$hs" ] && [ -n "$he" ]; then
        echo " - initrd cboot actually loaded: $((16#$he - 16#$hs)) bytes"
        echo "   (stock /boot/initrd = 7236790 B; stage-1 initrd-rescue ~2 MB)"
    else
        echo " - could not read DT initrd bounds"
    fi
    echo " - stage-1 kernel-log traces (empty = stage-1 never ran = cboot fallback):"
    sudo dmesg 2>/dev/null | grep 'rescue-s1:' | tail -5 | sed 's/^/     /'
    if mount | grep -q '/mnt/emmc-app'; then :; else sudo mkdir -p /mnt/emmc-app && sudo mount /dev/mmcblk0p1 /mnt/emmc-app; fi
    echo " - stage-1 pivot log (last lines):"
    if sudo test -f /mnt/emmc-app/boot/phase2-stage1.log; then
        sudo tail -5 /mnt/emmc-app/boot/phase2-stage1.log | sed 's/^/     /'
    else
        echo "     (none)"
    fi
    echo " - surgery markers on the pivot:"
    ls -la /mnt/emmc-app/boot/ 2>/dev/null | grep -E 'phase2' | sed 's/^/     /' || echo "     (none)"
    exit 1
fi

if [ -f /etc/nv_tegra_release ] && echo "$kernel" | grep -q '^4\.9'; then
    echo "VERDICT: JP4 booted (normal)."
    if mount | grep -q '/mnt/emmc-app'; then :; else sudo mkdir -p /mnt/emmc-app && sudo mount /dev/mmcblk0p1 /mnt/emmc-app; fi
    def=$(awk '/^DEFAULT /{print $2}' /mnt/emmc-app/boot/extlinux/extlinux.conf)
    echo "DEFAULT: $def"
    if sudo test -f /mnt/emmc-app/boot/phase2-autorun-surgery; then
        echo "*** WARNING: LIVE arm flag on the pivot — any rescue-labeled boot"
        echo "    WILL run the surgery. Disarm or re-run arm-and-go deliberately. ***"
    fi
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
