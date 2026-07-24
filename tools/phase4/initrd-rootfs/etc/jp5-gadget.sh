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
