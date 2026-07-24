# SPDX-License-Identifier: GPL-2.0
# CyberDog BCM4775 GPS power/standby driver — out-of-tree build for
# 5.10.216-tegra.  Inside the cyberdog-kbuild container, after a full
# kernel build in $(KOUT) (needs Module.symvers there because of
# CONFIG_MODVERSIONS):
#
#   make -C /tmp/kb M=/work/gps-port/module ARCH=arm64 modules
#
# In-tree use (optional): copy bcm_gps_tty.c + Kconfig into
# drivers/gps/ and hook drivers/{Kconfig,Makefile} as on 4.9
# (see ../patches-not-applied/0001-in-tree-drivers-gps.patch).

obj-$(CONFIG_XIAOMI_GPS_UART_DRIVER) += bcm_gps_tty.o

# default for the M= out-of-tree case, where the config symbol is unset
ifeq ($(CONFIG_XIAOMI_GPS_UART_DRIVER),)
obj-m += bcm_gps_tty.o
endif
