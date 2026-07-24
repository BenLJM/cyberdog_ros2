# CyberDog GPS (BCM4775) 驱动 JP4→JP5 移植说明

日期：2026-07-24 · 目标内核：5.10.216-tegra (L4T r35.6.4, athena_defconfig)
状态：**.ko 已编译通过**（vermagic 见下），未上狗验证。

## 0. TL;DR — 这个"驱动"到底是什么

JP4 dmesg 里的 `[SSPBBD] gps probe` / `platform_driver_register sspbbd bcm_gps_tty misc_register ret is 0`
来自 **一个 393 行的小平台驱动**（4.9 树 `drivers/gps/bcm_gps_tty.c`，
`CONFIG_XIAOMI_GPS_UART_DRIVER`，Kconfig `default y` + `drivers/Makefile obj-y += gps/`
→ 内建）。它 **不是** 三星/Broadcom 完整 SSPBBD sensorhub 栈——那套框架
（bbdpl、SPI 传输、/dev/bbd_* misc 设备簇）在小米 4.9 源码里根本不存在，
log 前缀和"misc_register"字样只是从别处抄来的文案。所以本次移植 **没有
"最小可用子集"取舍问题**：全部驱动逻辑就是——

1. probe（DT `compatible = "bcm4775"`）：使能 `vdd`(1.8V) regulator →
   请求 `nstandby-gpio` 并拉高 → msleep(30) → 使能 `vddgps`(3.3V) regulator
2. 建 sysfs：`/sys/devices/bcm4775/nstandby`（0660，读/写 0|1，**raw 值**）

**NMEA/定位数据不走这个驱动**。数据路径 = BCM4775 的 UART ↔ tegra-hsuart
`serial@3100000`（uarta，别名 serial0）→ **/dev/ttyTHS0**，由用户态
`cyberdog_scenedetection`（ROS2 节点，Broadcom Bream 协议栈）驱动：
先 `echo 0 > /sys/devices/bcm4775/nstandby; sleep 1; echo 1 > …`（复位脉冲），
115200 开口 → 下载固件 `/usr/sbin/bream.patch` → 切 **3,000,000 bps** →
Bream 二进制协议出 NAV-PVT 等（scene_detection.cpp 全流程）。

## 1. 源码位置与规模

| 项 | 位置 |
|---|---|
| 4.9 原始驱动 | `mirror/cyberdog_tegra_kernel.git` (branch `athena`) `kernel/kernel-4.9/drivers/gps/{bcm_gps_tty.c(393行),Kconfig,Makefile}`，副本在 `gps-port/src49/` |
| 4.9 DTS 节点 | 同仓 `hardware/.../jakku/kernel-dts/common/mirp-common.dtsi` + `tegra194-mi-k91.dts`（`bcm4775` 节点，副本 `gps-port/src49/*.49`） |
| JP4 活体 DT | `audio-port/dtb-live.dts`：`/bcm4775` 节点存在；`gps_wake` 节点 **disabled**（NVIDIA 参考板遗留，与我们无关）；uarta okay |
| 移植后源码 | `gps-port/module/{bcm_gps_tty.c,Makefile,Kconfig}`（out-of-tree 模块） |
| 4.9→5.10 diff | `gps-port/src49-to-510.diff` |
| 产物 | `gps-port/bcm_gps_tty.ko`（+ `gps-port/dts/` 两个 DT 交付物） |

相关但**未移植**（不需要）：`drivers/misc/gps_wake.c`（NVIDIA e2614 参考板
用，活体 DT 里 disabled）；`ublox6-gps-*.c`（非本机硬件）。

## 2. 4.9→5.10 改了什么

**API 层面：零强制修改。** 该驱动只用了 5.10 仍健在的老接口
（`of_get_named_gpio`/legacy gpio_*、devm_regulator_get、platform_driver、
device_create_file；任务书里预警的 timer/access_ok/proc_ops/spi 全都用不到），
smoke 编译一次通过、无告警。实际做的改动（详见 src49-to-510.diff）：

1. **模块化**：out-of-tree `obj-m` 构建（4.9 是内建）。`late_initcall_sync`
   保留——MODULE 语境下宏展开就是 `module_init`。
2. **`MODULE_DEVICE_TABLE(of, …)` 新增**：udev 冷插拔按 DT modalias
   (`of:Nbcm4775…`) 自动 modprobe，JP4 内建时代不需要、模块时代必需。
3. **生命周期补洞**（4.9 内建永不卸载，全是漏的）：regulator 句柄存进
   priv；probe 失败路径逐级回滚（disable vdd / gpio_free / kfree）；
   remove() 现在会 nstandby 拉低→关 vddgps→关 vdd→gpio_free→kfree——
   **rmmod = GPS 真断电**，也避免 devm regulator put 时 enable 计数不平衡的
   WARN。
4. kmalloc+memset → kzalloc；删掉 4.9 里大段注释掉的死代码（gps_1v8 /
   wifi_gpio sysfs）。
5. **所有 log 文案、sysfs 路径/权限、probe 时序（vdd→nstandby↑→30ms→vddgps）
   与 4.9 逐字一致**——用户态 scene_detection 和机主 grep dmesg 的习惯不破坏。

## 3. 编译（可复现步骤）

```bash
# 容器（树挂 /work，O= 必须容器本地路径）
docker run -d --name gps-kbuild -v /Users/ben/projects/cyberdog/build:/work cyberdog-kbuild sleep infinity
docker exec gps-kbuild bash -c '
  export LOCALVERSION=-tegra
  cd /work/src/Linux_for_Tegra/source/public/kernel_src/kernel/kernel-5.10
  make -s O=/tmp/kb ARCH=arm64 athena_defconfig
  make -j6 O=/tmp/kb ARCH=arm64 Image dtbs modules   # CONFIG_MODVERSIONS=y ⇒ 必须整树 build 出 Module.symvers，光 modules_prepare 不够
  make -C /tmp/kb M=/work/gps-port/module ARCH=arm64 modules
'
```

vermagic 实测：见文末"验收记录"。

## 4. DTS：JP5 **不缺节点，缺的是一个 status**

`hardware/.../common/tegra194-p2151-0000.dtsi` 里 `/bcm4775` 节点早已存在
且参数与 JP4 活体 DT 1:1（vdd=vdd_1v8_gps、vddgps=vdd_3v3_gps、
nstandby=gpio_expand2 pin10=GNSS_EN），唯独 `status = "disabled"`（当年因
5.10 无驱动而关）。配套件也都健在：两个 fixed-regulator（expander2
pin16/pin20，JP5 已把 4.9 的 ACTIVE_LOW+enable-active-high 矛盾写法改成
诚实的 ACTIVE_HIGH，电气行为不变）、TCA6424（我们 07-20 的 gpio-hog 复位
释放修复正是它的前置条件）、uarta okay、`gps_switch`
reg-userspace-consumer okay。athena_defconfig 前置项齐：SERIAL_TEGRA=y,
GPIO_PCA953X=y, REGULATOR_USERSPACE_CONSUMER=y。

启用二选一（**推荐 A**）：

- **A. 树内补丁**（进 patch 栈，随下次 full-build 出 DTB）：
  `gps-port/patches-not-applied/0001-p2151-DT-enable-bcm4775-GPS-node-for-ported-bcm_gps_.patch`
  （在 jakku 仓 `git am`；仓库当前 HEAD b8a3485 上验证过 apply+dtbs 编译，
  见"验收记录"）。树已还原，未留改动。
  另附**可选**内核树内化补丁
  `0001-drivers-gps-port-Xiaomi-bcm_gps_tty-BCM4775-GNSS-pow.patch`
  （kernel-5.10 仓，HEAD 35ed0d5d3 制作：drivers/gps/ 三件套 + drivers/
  {Kconfig,Makefile} 挂钩 + athena_defconfig `=m`）——想让模块随
  full-build.sh 一起出、进 modules tarball 时再 am，当前不需要。
- **B. 免重刷 DTB 的 runtime overlay**：`gps-port/dts/cyberdog-gps-bcm4775-enable.dtbo`
  （源码同目录）。拷到 /boot，extlinux.conf JP5 条目加
  `OVERLAYS /boot/cyberdog-gps-bcm4775-enable.dtbo`，由 r35 UEFI
  L4TLauncher 在启动时合并（内核 CONFIG_OF_OVERLAY 未开，**不影响**此路径，
  合并发生在 bootloader）。重启后 `ls /proc/device-tree/bcm4775/status`
  应为 `okay`。若 L4TLauncher 版本不吃 OVERLAYS，退回方案 A。

## 5. 上狗加载/验证步骤（JP5）

```bash
# 0) 前置：DTB 已按 §4 任一方案启用节点；重启后确认
cat /proc/device-tree/bcm4775/status          # → okay

# 1) 装模块（推荐正式路径）
sudo cp bcm_gps_tty.ko /lib/modules/5.10.216-tegra/kernel/drivers/misc/
sudo depmod -a && sudo modprobe bcm_gps_tty   # 或快测: sudo insmod bcm_gps_tty.ko

# 2) 验 probe（与 JP4 dmesg 逐字同款）
dmesg | grep -i sspbbd
#   期望: KERN_ERR [SSPBBD] gps probe / [SSPBBD] nstandby=<N>
#   期望: platform_driver_register sspbbd bcm_gps_tty misc_register ret is 0
ls -l /sys/devices/bcm4775/nstandby            # 0660, root:root
cat /sys/devices/bcm4775/nstandby              # → 1 (probe 已拉高)
cat /sys/kernel/debug/regulator/regulator_summary | grep -E 'gps'  # 两路 enabled

# 3) 复位脉冲 + 原始 NMEA 冒烟（芯片上电默认 115200 会先吐 NMEA/Bream 帧）
echo 0 | sudo tee /sys/devices/bcm4775/nstandby; sleep 1
echo 1 | sudo tee /sys/devices/bcm4775/nstandby
sudo systemctl stop nvgetty 2>/dev/null; sudo systemctl disable nvgetty 2>/dev/null  # 见风险#3
sudo stty -F /dev/ttyTHS0 115200 raw -echo
sudo timeout 10 cat /dev/ttyTHS0 | strings | grep -E '\$G[PN]' # 有 $GPxxx/$GNxxx 即链路通
#   注意: 4775 固件未载入时输出可能是 Bream 二进制而非纯 NMEA，有稳定字节流即算通

# 4) 完整链路 = 原厂用户态（chroot 原厂栈内）：scene_detection 需要
#    /usr/sbin/bream.patch（JP4 rootfs 自带）+ /sys/devices/bcm4775/nstandby
#    + /dev/ttyTHS0（确保 chroot 内可见：sysfs/dev 已 bind-mount 即可），
#    先 115200 灌固件再切 3Mbps，出 ROS 话题即全通。
```

## 6. 风险清单

1. **gpio_request 撞车（-EBUSY）**：expander2 pin10 若被 gpiod/sysfs 预先
   export（比如哪个 bring-up 脚本把 GNSS_EN 当普通开关掰过），probe 失败。
   处置：unexport 后重新 modprobe；长期规矩=该脚驱动独占。
2. **与 gps_switch 并存**：驱动 probe 后自己持有两路 regulator 的 enable
   引用，用户态再 enable/disable `gps_switch` 只增减引用计数、**关不掉**
   GPS 电（驱动在就常供电）。省电需求 = rmmod（本移植已让 rmmod 真断电+
   进 standby）。别把"gps_switch 关了怎么还有电"当 bug 报。
3. **nvgetty 抢 ttyTHS0**：L4T 默认可能在 ttyTHS0 挂 getty，会吃掉/干扰
   GPS 字节流（JP4 原厂镜像早关了，我们 JP5 rootfs 未必）。验证前
   `systemctl disable --now nvgetty`。
4. **3Mbps 波特率**：tegra-hsuart r35 支持，但若 Bream 切速后丢帧，先退
   921600/115200 排查（scene_detection 里 baudrate 常量）。
5. **vermagic/modversions 强校验**：本 .ko 在 kernel-5.10 仓 HEAD
   35ed0d5d3 + athena_defconfig 下编译，CRC 与该树的 Module.symvers 逐项
   核对一致。狗上正在跑的内核若出自**更早的树状态**（如 4fb86af 批次），
   vermagic 相同、CRC 大概率兼容（期间补丁未动核心导出接口），但 insmod
   若报 `disagrees about version of symbol module_layout` → 重跑一次
   full-build.sh 刷新 Image+modules 后再装，或按狗上内核的树提交点重编
   本模块（步骤 §3，10 秒级）。
6. **probe 顺序**：依赖 TCA6424(gpio_expand2) 先就位。i2c 抖动时驱动返回
   EPROBE_DEFER 自动重试，属正常；若 dmesg 持续刷 defer，先查 07-20 的
   tca6424 gpio-hog 复位释放还在不在。
7. **overlay 路径不确定性**（仅方案 B）：r35 L4TLauncher 对 OVERLAYS 的
   支持以实机为准；上车后必查 /proc/device-tree/bcm4775/status。
8. **天线/室内**：链路通≠定位成。室内无 fix 是正常现象，验证"出数据"
   即可，fix 到室外草坪上验。

## 7. 验收记录（2026-07-24，cyberdog-kbuild 容器实测）

- 整树构建：`make -j6 O=/tmp/kb ARCH=arm64 Image dtbs modules` 零 Error；
  `kernel.release = 5.10.216-tegra`；Module.symvers 772,386 B。
  树状态：kernel-5.10 @ 35ed0d5d3，jakku DTS @ b8a3485（均 clean）。
- 模块：`make -C /tmp/kb M=/work/gps-port/module ARCH=arm64 modules`
  一次通过、无告警（首次 modules_prepare 冒烟编译亦零改动通过——4.9 代码
  在 5.10 无任何 API 硬伤）。
- **vermagic 实测 = `5.10.216-tegra SMP preempt mod_unload modversions aarch64`**（目标逐字命中）。
- modversions：`__versions` 节 22 条 CRC；抽查 `module_layout=0x59f1f09f`、
  `__platform_driver_register=0x729052e0` 与 /tmp/kb/Module.symvers 一致。
- modalias：`of:N*T*Cbcm4775`（DT 自动加载就绪）。
- DTS 验证：树内临时套用补丁 A → `make dtbs` → 反编译产物 DTB 确认
  `/bcm4775 { status = "okay"; nstandby-gpio = <&gpio_expand2 0x0a 0x01> }`
  与 JP4 活体 DT (`<0x26 0xa 0x1>`) 参数一致；验证版 DTB 存
  `dts/tegra194-p3668-0001-p2151-0000-gps-verify.dtb`（**验证用途**，正式
  DTB 请走 patch A + full-build.sh）。随后树还原、dtbs 重建回原状
  （status=disabled），两仓 `git status` clean。
- overlay：`dts/cyberdog-gps-bcm4775-enable.dtbo` dtc 编译+反编译核对 OK。
- sha256（同 `SHA256SUMS`）：
  - `bcm_gps_tty.ko` = 097e821f7ca2725312555f7e8ee68fa6b590667c241b52ea4d1d7df65544420a
  - `cyberdog-gps-bcm4775-enable.dtbo` = 8c22900319f4d3211e95783237ef35377d38f71386434c7b9a47175261758c99
  - `…-gps-verify.dtb` = 84c9ea85b8cb9bf003c38561a879d653b44b7768b71c1ab29b9e83fd26b07882
- 未做（需实机）：insmod/probe、ttyTHS0 数据流、Bream 3Mbps、定位 fix。
