# 背部触摸板移植：4.9 `synaptics_dsx` → 5.10（任务 E）

**日期** 2026-07-26 · **状态** 代码全部落地，编译+DTB 实测通过，**未构建内核、未部署**（E 批次统一构建）

---

## 0. 一句话结论

**审计说的"数千行 API 适配"是高估。真实的 4.9→5.10 代码适配只有 3 个文件 / 56 行 diff。**
驱动已在 5.10.216-tegra 上零 warning 零 error 编译通过，DTB 已重编并反汇编核对，
狗上的 GPIO/I2C/权限/用户态消费者四条链路全部远程只读验证过。剩下的唯一未知量是"上电后
触摸板芯片是否真的应答 RMI4"——那要等 E 批次内核上机才能知道。

**值不值得做：值。** 它是本轮剩余软件活里性价比最高的一件——
出厂 ROS2 栈里有现成的消费者 `service_athena_touch`，它按名字找 `synaptics_dsx`，
而驱动注册的 input 设备名恰好就是 `synaptics_dsx`（下面 §5 有实证）。

---

## 1. R32 树里的完整驱动（`cyberdog_tegra_kernel.git` 分支 `athena`）

`kernel/kernel-4.9/drivers/input/touchscreen/synaptics_dsx/`：

| 文件 | 行数 | 出厂 `tegra_defconfig` 是否启用 | 本次是否移植 |
|---|---:|---|---|
| `synaptics_dsx_core.c` | 4916 | ✅ `_CORE=y` | ✅ |
| `synaptics_dsx_core.h` | 552 | — | ✅ |
| `synaptics_dsx_i2c.c` | 652 | ✅ `_I2C=y` | ✅ |
| `synaptics_dsx_rmi_dev.c` | 1083 | ✅ `_RMI_DEV=y` | ✅ |
| `synaptics_dsx_fw_update.c` | 5951 | ✅ `_FW_UPDATE=y` | ✅ |
| `synaptics_dsx_test_reporting.c` | 7425 | ✅ `_TEST_REPORTING=y` | ✅ |
| `Kconfig` / `Makefile` | 128 / 18 | — | ✅ |
| `synaptics_dsx_spi.c` | 712 | ❌ | ❌ 不需要（走 I2C） |
| `synaptics_dsx_rmi_hid_i2c.c` | 1006 | ❌ | ❌ |
| `synaptics_dsx_gesture.c` | 2308 | ❌ | ❌ |
| `synaptics_dsx_proximity.c` | 692 | ❌ | ❌ |
| `synaptics_dsx_active_pen.c` | 624 | ❌ | ❌ |
| `synaptics_dsx_video.c` | 416 | ❌ | ❌ |

外加 `kernel/kernel-4.9/include/linux/input/synaptics_dsx.h`（113 行，平台数据结构 + `PLATFORM_DRIVER_NAME`）。

移植的 6 个 .c/.h 合计 **20 579 行**，与出厂启用集合逐项一致——**不多不少，不做取舍**。

挂接点（与 4.9 完全同构）：
- `drivers/input/touchscreen/Kconfig` 末尾 `endif` 前插 `source ".../synaptics_dsx/Kconfig"`
- `drivers/input/touchscreen/Makefile` 追加 `obj-$(CONFIG_TOUCHSCREEN_SYNAPTICS_DSX) += synaptics_dsx/`

---

## 2. 4.9 → 5.10 到底改了什么（实测，不是猜）

方法：把 4.9 源码原样丢进 5.10 树直接编，让编译器报账，而不是靠经验清单猜。
结果**只有 3 处**，`src49-to-510.diff` 共 56 行。

### 2.1 `synaptics_dsx_rmi_dev.c` — `struct siginfo` → `struct kernel_siginfo`

```
error: passing argument 2 of 'send_sig_info' from incompatible pointer type
  expected 'struct kernel_siginfo *' but argument is of type 'struct siginfo *'
```
v4.20 的 signal 结构拆分（内核态 `kernel_siginfo` 与用户态 `siginfo` 分家）。
改法：第 104/105 行两个成员声明换类型即可，`si_signo`/`si_code` 字段在新结构里同名同位。**2 行。**

### 2.2 `synaptics_dsx_i2c.c` — VLA（5.10 全树 `-Werror=vla`）

```
error: ISO C90 forbids variable length array 'msg'   ← struct i2c_msg msg[rd_msgs + 1];
```
`rd_msgs` 由读长度算出（`(length-1)/255 + 1`），没有编译期上界。
改法：`kmalloc_array(rd_msgs + 1, sizeof(*msg), GFP_KERNEL)`，在唯一的 `exit:` 标签处 `kfree`。
**睡眠安全性已核实**：该读路径的唯一中断上下文是 `request_threaded_irq(irq, NULL, synaptics_rmi4_irq, ...)`
（core.c:1999，hardirq handler 为 NULL），即全部跑在 IRQ 线程里，`GFP_KERNEL` 合法。

### 2.3 `synaptics_dsx_fw_update.c` — `-Werror=implicit-fallthrough`

`fwu_erase_configuration()` 的 `case UPP_AREA:` 少一个 `break`，成功路径会掉进 `default:` 返回 `-EINVAL`。
这是上游自带的 bug。**没有"顺手修掉"**——出厂 R32 固件跑的就是这个行为，
改语义等于引入一个只有我们这台机器有的分支。加 `fallthrough;` 注解，行为逐字节不变。**1 行。**

### 2.4 审计点名的雷区，逐个核对结果

| 审计担心的 | 实际情况 |
|---|---|
| i2c `probe` → `probe_new` 签名 | **非问题**。`probe_new` 是 4.10 加的可选项，老 `.probe(client, id)` 到 6.3 才移除，5.10 原样能编 |
| `input_mt_init_slots` 变化 | **非问题**。三参数形态自 3.7 未变 |
| `fb_notifier` → `drm_panel` | **非问题**。整段在 `#ifdef CONFIG_FB_TOUCH` 里，这个符号全树不存在，永远编不进去 |
| `CONFIG_HAS_EARLYSUSPEND` 残留 | 同上，永不生效 |
| regulator / gpiod API | **非问题**。用的是 `regulator_get` + legacy `gpio_request`/`gpio_direction_*`，5.10 全部还在。且 DT 没给 `pwr-reg-name`/`bus-reg-name`，regulator 分支根本不走 |
| `ioremap_nocache`、`access_ok` 参数、`get_user_pages` 签名 | **全树 0 处引用** |
| `__devinit`/`__devexit` 残留 | **0 处** |
| `set_fs`/`KERNEL_DS`/`vfs_read`/`do_gettimeofday`/`struct timeval`/`setup_timer` | **全部 0 处** |
| `class_create(THIS_MODULE, name)` 两参形态 | 6.4 才改，5.10 正确 |
| PM ops | `struct dev_pm_ops` 常规写法，无需改 |

**收尾编译（clean rebuild）：5 个 .o 全部产出，0 error 0 warning。**

---

## 3. 产物

```
build/touchpad-port/
├── NOTES.md                       ← 本文件
├── pristine/                      ← R32 4.9 原样导出（9 文件），用于随时重放/对拍
├── ported/                        ← 落地到 5.10 树里的成品（9 文件）
├── src49-to-510.diff              ← §2 那 56 行，就是全部的 API 适配
└── patches/
    ├── 0001-synaptics_dsx-driver-sources-ported-4.9-to-5.10.patch   (新增 9 文件)
    ├── 0002-input-touchscreen-hook-up-synaptics_dsx-subdir.patch    (Kconfig/Makefile)
    ├── 0003-athena_defconfig-enable-SYNAPTICS_DSX.patch             (6 个 CONFIG)
    └── 0004-p2151-DT-enable-back-touchpad-synaptics_dsx-node.patch  (DTS 使能)
```

**patch 已经应用到活动树**（`build/src/Linux_for_Tegra/source/public/kernel_src/`），
E 批次跑 `full-build.sh` 会自动带上，不需要额外动作。`patches/` 是给回滚/审阅/重放用的。
同样内容已镜像进 `kernel-tree-mods/public/kernel_src/`（仓库跟踪副本）。

> ⚠️ 刷新 `kernel-tree-mods` 里的 `athena_defconfig` 时**顺带带进了别人的一行**
> `CONFIG_TEGRA_CAPTURE_R32_ABI=y`（任务 #27 相机采集回移的，本来就在活动树里、只是镜像还没同步）。
> 不是本任务引入的，别误判。

### 回滚
删 `drivers/input/touchscreen/synaptics_dsx/` 与 `include/linux/input/synaptics_dsx.h`，
反向应用 0002/0003/0004 即可。三个挂接点都是纯追加，不碰任何既有代码路径；
`CONFIG_*` 全关时这些文件一个字节都不进 vmlinux。**对其它子系统零风险面。**

---

## 4. DT：为什么原来是 disabled，以及使能改了什么

### 4.1 为什么 disabled
小米的 R35 分支（`athena_l4t_jakku_dts.git` 分支 `athena_dev`）把板级 DTS 前移了，
但 `athena_l4t_kernel.git` / `athena_l4t_nvidia.git` 两个 R35 内核仓里**都没有 `synaptics_dsx` 驱动**
（已 `ls-tree` 全树确认）。也就是说：**小米自己也没做这次 4.9→5.10 驱动移植，
所以把节点标了 `disabled` 挂起。**不是硬件问题，是驱动缺席。

### 4.2 总线：一个差点踩进去的坑（已澄清，结论是没坑）
R32 板级文件 `tegra194-mi-k91.dts` 把节点挂在 `&dp_aux_ch3_i2c`，
而 R35 前移版挂在 `i2c@31e0000`——看着像被搬错了总线。查 R32 SoC dtsi：

```
tegra194-soc-i2c.dtsi:191:  dp_aux_ch3_i2c: i2c@31e0000 {
tegra194-soc-i2c.dtsi:31 :  i2c8 = &dp_aux_ch3_i2c;
```

**同一个控制器，只是换了引用写法。** 狗上实测 `i2c-8 → 31e0000.i2c`，
`OF_ALIAS_0=i2c8`，总线已 `okay` 且当前**无任何子设备**（DP AUX/HDMI DDC 线，没接显示器）。

### 4.3 使能实际改了三处（`0004` patch）

| 改动 | 理由 |
|---|---|
| `status = "disabled"` → `"okay"` | 显然 |
| `synaptics,irq-gpio` 第三 cell `0x2002` → **`0x2008`** | 恢复出厂 R32 值。`0x2002`=`IRQF_ONESHOT\|IRQF_TRIGGER_FALLING`，`0x2008`=`IRQF_ONESHOT\|IRQF_TRIGGER_LOW`。驱动的中断触发方式**只从这一格取**（`synaptics_dsx_i2c.c` parse_dt → `bdata->irq_flags` → `request_threaded_irq`）。RMI4 F01 的中断在状态寄存器被读走之前一直拉低，**边沿触发丢一次沿就永久卡死**；电平触发才是对的。zbwu 前移时留的是另一份更早的 Athena 初版值 |
| 取消注释 `synaptics,cap-button-codes = <102 158>` | 恢复出厂 R32 值。**不是可有可无的装饰**：`synaptics_rmi4_f1a_button_map()`（core.c:2961）在器件存在 F1A 功能而 `cap_button_map->map == NULL` 时直接 `return -ENODEV`，会**把整个 probe 打掉**。反过来，若这颗器件没有 F1A，该属性只是被 parse 后闲置。**留着严格优于删掉。** 102=KEY_HOME，158=KEY_BACK |

`interrupts = <... 0x2002>` 这条**故意保持原样不动**：它在 5.10 里是装饰性的。
`i2c_device_probe()` 走 `of_irq_get()`，tegra186-gpio 的 `irq_domain_xlate_twocell`
会把第二 cell `& IRQ_TYPE_SENSE_MASK` 掩成 2（edge-falling）先建一个映射；
随后驱动自己 `gpio_to_irq()` 拿到**同一个 irq 号**再用 `IRQF_TRIGGER_LOW` 覆盖。
即使 `of_irq_get` 失败，5.10 的 i2c core 也只是 `irq = 0` 继续，不会让 probe 失败。

### 4.4 GPIO 编号：DT 宏与内核线号不是一回事（已实测对上）
`TEGRA194_MAIN_GPIO(Q,3)` = `16*8+3` = **131**，但 `gpiochip1` 的第 131 线名字是 `PV.00`。
不矛盾：`gpio-tegra186.c` 有自定义 `.of_xlate`，把 DT 的「口*8+偏移」换算成驱动的线性口内编号，
真正落到 **line 103 = `PQ.03`**。狗上实测佐证：`line 101 "PQ.01" "interrupt" [used]`——
那正是 `gpio_expand1` 的 `interrupt-parent = <&tegra_main_gpio MAIN_GPIO(Q,1)>`，映射规则验证通过。

---

## 5. 狗上远程只读验证（全部实测，未做任何改动）

| 检查 | 结果 | 含义 |
|---|---|---|
| `i2c-8` 存在且 `31e0000.i2c` | ✅ `OF_ALIAS_0=i2c8`，无子设备 | 总线就绪、无冲突 |
| `i2cget -y 8 0x20` | 返回 `0x00`（未 NAK） | 0x20 地址上有东西应答；但此刻芯片在复位态，这一条只能算弱证据 |
| `gpioinfo gpiochip3` line 7 `TOUCHPAD_NRST` | `unused input`，读值 **0** | 板上默认拉低 = **触摸板当前被按在复位里**。正是驱动接手后要做的第一件事（拉低 20ms 再放高，等 200ms） |
| line 6 `x_INT_TOUCHPAD` | `unused input`，读值 1 | 中断线空闲（`irq-on-state=0`，低有效） |
| `gpiochip1` line 103 `PQ.03` | `unused input` | 中断脚没被别人占 |
| `gpiochip3` 有无 gpio-hog 占 line 7 | **无**（R32 那个 `init-gpios{gpio-hog}` 在 R35 树里不存在） | `gpio_request(reset)` 不会 `-EBUSY`。这是 R32 直搬过来最容易踩的雷，已排除 |
| 用户态消费者 | `/mnt/jp4/opt/ros2/cyberdog/lib/athena_touch/service_athena_touch` + `libathena_touch_core.so` | 出厂栈里现成的 ROS2 节点 `TouchPubNode`，发 `interaction_msgs/msg/Touch` |
| 它按什么找设备 | `.so` 里紧挨着的两个串：`/dev/input` 和 **`synaptics_dsx`** | 扫 `/dev/input/event*`，用 `EVIOCGNAME` 匹配名字 |
| 驱动注册的名字 | `input_dev->name = PLATFORM_DRIVER_NAME` = **`synaptics_dsx`** | **逐字符对上** |
| chroot 权限（审计的 gid 107 vs 101） | 已是**非问题** | `/dev/input/event*` 实测 `crw-rw---- mi input`，**属主是 mi**；chroot 内外 `mi` 都是 uid 1000，靠 owner 位就能开，与组无关。今天已有 `/etc/udev/rules.d/99-cyberdog-input.rules`（`OWNER="mi"`）在位，新节点会自动套用 |

---

## 6. 本机构建验证（证据，不是推理）

容器 `nvmap-kbuild`，树 `/work/src/.../kernel-5.10`，构建目录 `/tmp/kb`（沿用现成配置，**没有构建内核/Image**）：

1. `make O=/tmp/kb athena_defconfig` → 6 个 `CONFIG_TOUCHSCREEN_SYNAPTICS_DSX*` 全部落成 `=y`
   （证明 Kconfig 挂接与依赖链正确，没被 `olddefconfig` 悄悄丢掉）
2. `make O=/tmp/kb drivers/input/touchscreen/synaptics_dsx/`（clean rebuild）
   → `synaptics_dsx_{core,i2c,rmi_dev,fw_update,test_reporting}.o` + `built-in.a`，**0 error 0 warning**
3. 未定义符号核对：`nm -u built-in.a` 取 118 个符号，与既有 `System.map` 求差，
   只剩 `synaptics_rmi4_bus_init` / `synaptics_rmi4_bus_exit` / `synaptics_rmi4_new_function`
   ——**全是驱动自己 core.c 里定义的**。vmlinux 链接不会有未决符号
4. `make O=/tmp/kb dtbs` → `tegra194-p3668-0001-p2151-0000.dtb` 重建成功（rc=0）
5. `dtc -I dtb -O dts` 反汇编核对节点：
   `status="okay"` / `irq-gpio = <0x0c 0x83 0x2008>` / `cap-button-codes = <0x66 0x9e>` ✅
6. **部署铁律五项复查**（我只碰了 synaptics 节点，仍逐项确认未被殃及）：
   `diag@5` → `status="disabled"` ✅ ／ `map3` 出现 **0** 次 ✅ ／ `adsp_audio` 节点在但被 audio dtsi 处理 ✅

---

## 7. 把握度与残余风险

**把握度：高（约 85%）。** 依据是四条链路全部实测闭环：驱动能编 → DTB 能出且内容对 →
GPIO/I2C 在狗上确实空闲可用 → 用户态消费者与设备名逐字符对上。

剩下的 15% 全部集中在一件事上：**触摸板芯片上电后是否真的应答 RMI4**。
这没法远程判定，因为它此刻被 `TOUCHPAD_NRST=0` 按在复位里，只有驱动跑起来才会放开。

失败时的排查顺序（上机后看 dmesg）：
1. `synaptics_dsx ... Failed to read F01 ...` → 芯片没醒：先看 `reset-delay-ms=200` 够不够，
   再确认 0x20 地址（`ub-i2c-addr=0x2c` 是 bootloader 模式地址，正常固件在 0x20）
2. `cap_button_map is NULL` → 不会发生（§4.3 已预防），若真出现说明 DT 没生效
3. probe 成功但 `/dev/input/` 里没有名为 `synaptics_dsx` 的节点 →
   `cat /sys/class/input/event*/device/name` 逐个看
4. 有节点但 chroot 内 `service_athena_touch` 打不开 → 查 §5 最后一行那条 udev 规则是否套上

**不建议现在做的事**：`_FW_UPDATE` 模块会 `request_firmware()` 找触摸板固件包。
出厂 R32 树里有 `firmware/synaptics/startup_fw_update.img.ihex`，**本次没有移植它，也不应该移植**——
在没搞清当前触摸板固件版本前触发固件升级是纯粹的下行风险。模块编进去只是为了与出厂配置一致，
不喂固件文件它就什么也不做。
