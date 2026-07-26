#!/bin/bash
set -u
exec /usr/sbin/chroot /mnt/jp4 /usr/local/nginx/sbin/nginx -s stop
