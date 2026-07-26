#!/bin/sh
# F1 verification — READ ONLY. Run on the dog after a reboot that carries the
# new kernel cmdline. Never triggers a crash.
echo "=== 1. cmdline carries the params ==="
tr ' ' '\n' < /proc/cmdline | grep ramoops || echo "  !! no ramoops.* on cmdline"
echo
echo "=== 2. driver bound via module parameters ==="
dmesg | grep -i ramoops || echo "  (nothing in the current dmesg ring)"
echo "  want: 'ramoops: using module parameters'"
echo "  want: NO 'failed to locate DT /reserved-memory resource'"
echo "  ok  : 'ramoops: already initialized'  (the DT device losing the race)"
echo
echo "=== 3. iomap path taken (proves we are NOT aliasing live RAM) ==="
sudo grep -i ramoops /proc/iomem || echo "  !! no ramoops region in /proc/iomem"
echo "  want: f0800000-f09fffff : ramoops"
echo
echo "=== 4. parameters as seen by the kernel ==="
for p in mem_address mem_size record_size console_size ftrace_size pmsg_size max_reason; do
    printf '  %-14s = ' "$p"; cat "/sys/module/ramoops/parameters/$p" 2>/dev/null || echo "(absent)"
done
echo
echo "=== 5. black box contents ==="
mount | grep pstore
echo "-- /sys/fs/pstore (cleared by systemd-pstore.service at boot) --"
sudo ls -la /sys/fs/pstore/ 2>&1
echo "-- /var/lib/systemd/pstore (where systemd-pstore parks them) --"
sudo ls -laR /var/lib/systemd/pstore/ 2>&1 | head -40
echo
echo "=== 6. memory map sanity (carveout must still be a hole) ==="
sudo grep 'System RAM' /proc/iomem
echo "  want: the sub-4GiB region still ENDS at f07fffff"
