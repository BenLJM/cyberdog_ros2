# CyberDog JetPack 4 → 5 移植：权威现状

**最后更新 2026-07-25**（本文件取代 `cyberdog_ros2/PHASE5_STATUS.md`，后者的核心结论"相机被 RCE 固件锁死、必须动 QSPI"**已被推翻**，见下）

---

## 架构（实际路线，与原计划不同）

原计划是 ROS2 Humble 原生化（Phase 6–10）。**实际走的是另一条路且已既成事实**：

> **JP5 内核（5.10.216-tegra / L4T r35.6.4）+ chroot 跑 JP4 出厂 ROS2 Foxy 栈**

JP4 根文件系统在 `nvme0n1p1`，运行时挂在 `/mnt/jp4`。这条路线从未被正式改判入档，**它是终局架构还是过渡态，需要机主拍板**。

## 引导

**真配置在 eMMC `/dev/mmcblk0p1` 的 `/boot/extlinux/extlinux.conf`**（nvme 上那两份是幌子）。

| LABEL | 内核 | 说明 |
|---|---|---|
| `jp5` | `/boot-jp5/Image` + `tegra194-mi-k91.dtb` + `initrd` | 当前 DEFAULT |
| `primary` / `second` | `/boot/Image` | JP4 |
| `rescue` | `/boot/Image` + `initrd-rescue` | JP4 内核、RAM 盘、不挂 NVMe |

### 三重安全网（已实战验证）
1. **initrd 自动回滚守卫** `sbin/jp5-autorevert-hook`：启动尝试计数器（>3 次未成功 → 自动恢复 `extlinux.conf.jp4-saved` 并重启），rootfs 只读探测，写保护探测，恢复内容 `cmp` 校验，失败时挂 USB gadget shell 而**不是**盲目重启循环。计数器由 `jp5-boot-ok.service`（`After=multi-user.target`）清零。
   - **2026-07-19 实战触发过一次并成功回滚**（见 eMMC `/boot/jp5-revert.log`）
   - ⚠️ **`build/artifacts/jp5-autorevert-hook.sh` 是旧的 Phase-3 版本（bash、无计数器）。用它重建 initrd 会静默把安全网降级。权威版本在 `tools/phase4/initrd-rootfs/sbin/jp5-autorevert-hook`**
2. **串口控制台**：笔记本 `ben@10.0.0.176` 的 `/dev/ttyACM0`（115200）→ 可在 cboot extlinux 菜单远程选启动项。实测打回 `cyberdog-jp5 login:`。
3. **USB 网络** 192.168.55.100 ↔ 192.168.55.1（1.8ms）。

---

## 🔒 部署铁律

### DTB 五项，缺一不可（每次逐项 diff）
| 项 | 丢了会怎样 |
|---|---|
| `diag@5` disabled | RCE 相机 `CH_SETUP` 复发错误 128，相机链断 |
| 热区 `map3` 删除（`cl3_0` 悬空引用清零） | **静默复发 thermtrip 掉电死机** |
| `aonclk` 表项裁剪 | 声卡不注册 |
| `adsp_audio` 禁用 | 声卡不注册（defer 40 链） |
| legacy hsp okay + 四邮箱（cmd rx=SM6/tx=SM7、ivc rx=SM1/tx=SM0） | RCE 握手超时 |

> ⚠️ **H2 病理**：热区 `map3` 删除 + `aonclk` 裁剪 + `adsp_audio` 禁用这三项**与音频无关，却寄生在 `tegra194-mi-k91-audio.dtsi` 里**。回退音频 DTS = 静默复发热跳闸死机。**待拆分成独立 `thermal-fixup.dtsi`。**

### 构建顺序
`full-build.sh` → `build-jp5-initrd.sh`（后者会被前者清空 `out/final`，顺序反了白干）

### ⛔ 绝对不要做
- **不要"修" PWM 极性**：极性反转是这块板子的**硬件事实**，通用 `pwm-fan.c` 已用 DTB 里降序的 `cooling-levels=<255 178 135 95 0 …>` 补偿，端到端自洽正确，且"PWM 失能=全速"还是 fail-safe。**改了才会散热失效。**
- **不要远程 `systemctl isolate multi-user.target`**：会同时断掉 SSH 和 fanboy，无法远程回滚。
- **不要给 wlan0 改静态 DNS**：已实测 223.5.5.5/8.8.8.8 在本 LAN 上 UDP53/TCP53 全超时，修法无效却会冒断掉唯一 ssh 通道的险。
- **不要绕过 pulseaudio 走 ALSA 直通**：客户端流是 16kHz，pulse 在做 16k→48k 重采样；**16k 会被 BE 抽干 → 功放 CLK 故障锁存（要断电才清）**。
- **不要在笔记本上跑 `apt-get autoremove --purge`**：会 purge python2，而出厂 R32 树的 `BUP_generator.py` shebang 是 `#!/usr/bin/python`。

---

## 元器件状态

| 子系统 | 状态 | 说明 |
|---|---|---|
| 运动板 + 12 电机 | ✅ | LCM leg_control_data + spi_data 500Hz |
| 机身 IMU | ✅ | LCM myIMU ~1000Hz |
| 以太网 → 运动板 | ✅ | 千兆 |
| Wi-Fi (8821cu) | ✅ | 5GHz，冷启自动上线 |
| 麦克风阵列 (RT5680 6ch) | ✅ | 753 寄存器回放 + 42 控件按名 |
| 扬声器 (TAS5805M) | ✅ | 48k 立体声实测出声 |
| 双风扇 / 散热 | ✅ 兜住 | 5 温区注册、90.5°C 降频 + 96°C critical 已绑；但 `thermal_zone5` **mode=disabled** → 内核不动风扇，100% 靠用户态 `fanboy` |
| CPU 功耗模式 | ✅ 已修 | 曾误停在 `MODE_10W_DESKTOP`(4核)，**已恢复出厂 `MODE_15W_6CORE`(pmode 2)**；⚠️ `/etc/nvpmodel.conf` 的 `DEFAULT` 仍是 5，rootfs 重刷会静默退回 |
| 蓝牙 (Realtek hci0) | ⚠️ 退化 | hci0 UP RUNNING，但 JP4 的 `bluetooth_ros2.service` 在 JP5 无对应实现 |
| D455 深度相机 | ✅ | `d455-camera.service` 已部署+enabled，随栈自启（sidecar）。848x480@30 三路影像 + IMU 200Hz 实测满速，详见 0726 条目 |
| GPS (BCM4775) | ⚠️ 退化 | 驱动点火、`nstandby=1`；出厂节点写死 4.9 sysfs 路径 + `/dev/ttyTHS0` 是 `root:dialout` 而节点跑在 `mi` 下 → **没出过数据** |
| 电池 / BMS | ⏸️ 物理项 | **机主已物理拆除电池**，当前适配器供电（只有 `usb-charger`，无 battery 节点） |
| AI 头顶相机（3 sensor） | ❌ 不通 | RCE 固件活(cmd=5)、IVC 通、nvcsi initialized、3 颗 subdev 全 bound、nvmap 手术已过 —— 但采集控制面 ABI 结构性分家 |
| 超声 ×4 / ToF / 光线 / LED | ❓ 未验证 | CAN 总线证实是活的（TX 有 ACK、TEC=0、MCU 回 timesync）。静默是出厂设计（`enable_count=0`，需上层发 ENABLE service）。**端到端从未验证过** |
| 背部触摸板 | ❌ 不通 | DT disabled + **5.10 内核里根本没有 `synaptics_dsx` 驱动**。修 = 一次 4.9→5.10 驱动移植 |
| 系统时钟 | ❌ 不通 | 停在 2000-01-01（双根因，见下） |
| swap | ❌ 无 | 内核没编 `CONFIG_ZRAM`，`nvzramconfig` failed |
| 硬件看门狗 | ❌ 禁用 | DT 里禁着，"挂死后自愈"零路径 |
| pstore / ramoops | ❌ 不通 | DT carveout 对不上，硬断电/panic 拿不到内核侧黑匣子 |
| OP-TEE | ❌ 不通（可接受） | R32 引导器混血，本来就不可用 |

---

## AI 头顶相机：为什么是死路（2026-07-25 定案）

已推倒的墙：RCE legacy hsp 邮箱回移 ✅ / `diag@5` CH_SETUP ✅ / nvmap WRITE ABI ✅ / **nvmap handle-as-fd 核心手术 ✅**（`NVMAP_CONFIG_HANDLE_AS_FD:=y`，mmap/EBADF 墙已倒，nvgpu 毫发无伤）/ 采集 ioctl 参数墙（`build/capture-ioctl-compat/`，已构建通过）✅

**但后面还有一堵垫片原理上翻不过去的墙**，三条独立硬证据：
1. **一票否决**：`CAPTURE_CHANNEL_SETUP_REQ` 消息号 R32=`0x10`、R35=`0x1E`，且 R35 把 `0x10` 显式改名成 `CAPTURE_CONTROL_RESERVED_10`。R35 内核发的话 R32 固件根本不认识。（与已修好的 `diag@5`/CH_SETUP 是**两回事**——那个是 IVC 总线建立层）
2. `capture_channel_config` 216B→272B 全错位；更糟的是 ISP 侧 `CAPTURE_CHANNEL_ISP_SETUP_REQ` 两边**都是 0x20**，R32 固件会"接受"然后按错布局解析 → **静默乱掉而非报错**（特征：`arm-smmu Unhandled context fault`）
3. 每帧内存模型换了范式：R32=reloc（内核就地打补丁 IOVA）；R35=buffer-table+memoryinfo，且缓冲必须先经 `VI_CAPTURE_BUFFER_REQUEST` 注册 —— **R32 根本没有这个 ioctl 号**，所以 R32 用户态永远不会注册

**继续在 R35 驱动上打垫片是明确的死路。** 三个选项待机主拍板：
- **(a) 整体回移 R32 采集驱动** —— 与已打赢的两仗同一套路，源码在 `build/mirror/cyberdog_tegra_kernel.git` 现成，依赖面窄，三方自洽零翻译。**唯一有希望的路**，但工程量与 nvmap 核心手术同量级
- **(b) 先部署本轮垫片当探针** —— 零风险可回滚，价值是看清下一堵墙。**判别点：错误码从 `-EINVAL` 变成 `-ETIMEDOUT` 就说明垫片生效、卡点前移到 IVC 控制面**
- **(c) 收手** —— 接受 D455 为唯一相机

---

## 时钟停在 2000 的双根因

1. **`nvrtc-sync-boot.service`**（R35 新带进来的，JP4 根本没有）在 timesyncd 已经把时间恢复之后，又用**没电的 PMIC 备份 RTC** 把系统时间覆盖回 2000
2. **DNS 全灭**（路由 10.0.0.1 已降级，`getent` rc=2）→ NTP 连域名都查不出

修复顺序不可乱，见 `docs/` 下的行动计划。三个坑：
- `disable --now` 加在 **shutdown** 单元上会当场触发 ExecStop，把 2000 年写进备份 RTC
- **别把 `nvrtc-sync-shutdown` 也禁了** —— 它是当前唯一把正确时间落盘到硬件的通道
- 配置键是 `FallbackNTP=`，不是 `FallbackNTPServers=`

---

## 已被推翻的旧结论（不要再据此行动）

1. ~~"TCA6424 两条 init-gpios hog 在 JP5 丢失 = 全系统共同病根"~~ — JP4 那两条 hog 带 `status="disabled"`，`for_each_available_child_of_node()` 会跳过，**在 JP4 上同样从未生效**
2. ~~"CAN 总线实质死亡"~~ — TX 有 ACK、TEC=0、MCU 回了 timesync 应答，静默是出厂空闲态设计
3. ~~"ov7251 I2C 地址在 JP5 错位 +1"~~ — R35 驱动的 `ov7251_update_sccb_id()` 会主动把传感器搬到 DT 指定地址
4. ~~"GPS 停在 standby"~~ — 驱动 probe 里无条件拉高 nstandby，实测 `nstandby=1`
5. ~~"PWM 极性反了是 bug"~~ — 是硬件事实 + 降序 cooling-levels 补偿，端到端正确
6. ~~"相机被 RCE 固件锁死、必须动 QSPI"~~（`PHASE5_STATUS.md`）— 已用零刷写的 legacy hsp 驱动回移解决

---

# 2026-07-25 深夜追加

## 🔴 rmem_max：一个 123 倍的移植回归（已修）
JP4 `/etc/sysctl.conf` 设 `net.core.rmem_max=26214000`（26MB），**移植时整条丢了**，JP5 停在内核默认 `212992`（208KB）。
后果：所有 ROS2/DDS 大消息过不去。实测 D455 848x480 深度帧 814KB → 10 秒只收到 1 帧；424x240（203KB）满速 30.1Hz——**阈值正好卡在 208KB**。
两条独立的线（D455 取流、systemd 缺口审计）互相印证。极可能是 0722「rs_bridge 投递不出去」悬案的真凶。
修复：`/etc/sysctl.d/99-cyberdog.conf`。
**2026-07-26 追认**：确实是它。rmem 补齐后 848x480 当场满速（见下），0722 悬案结案。

---

# 2026-07-26 追加

## ✅ D455 深度相机：冷启自启落地（`d455-camera.service`）
JP4 出厂有 `rs-bridge.service`，JP5 一直没有对应实现 —— 相机每次都要人工拉起。现已补齐。

**部署内容**（全部为新增文件，未改动任何既有 unit / 出厂 launch）：

| 文件 | 位置 | 作用 |
|---|---|---|
| `d455-camera.service` | JP5 `/etc/systemd/system/` | 主 unit，`WantedBy` + `PartOf` = `jp5-cyberdog-stack.service` |
| `d455-camera.sh` | JP5 `/usr/local/bin/` | 宿主侧启动器：chroot 兜底、电源轨、USB 等待、尝试计数 |
| `d455-camera-inner.sh` | chroot `/home/mi/` | 直接 exec `/opt/lrs-wrapper` 包装器节点（不走 `ros2 run`） |
| `d455-doctor.sh` + `.service`/`.timer` | JP5 | 每 5 分钟 CPU 活性判活，连续 2 次判死才重启 |
| `d455-verify.sh` | JP5 `/usr/local/bin/` | 只读验收（rclpy 计数，不信 `ros2 topic hz`） |

**实测（2026-07-26 03:27–03:46）**

```
depth  848x480 Z16  30.0 Hz      infra1 848x480 Y8  30.1 Hz
infra2 848x480 Y8   30.0 Hz      imu                197.6 Hz
节点 CPU ≈16% 单核    SoC 62.5–65°C（无变化）    10 分钟零重启、PID 未变
```

**三条被推翻/证实的旧判断**
1. ~~"848x480 过不了 DDS"~~ —— 真凶是 `rmem_max`，补回 26MB 后当场满速。默认分辨率已从 424x240 提到出厂档位 **848x480**。
2. ~~"独立 systemd unit 的 DDS 参与者投递不到栈内节点"~~（`CAMERA-VIO-HANDOFF-2026-07-22.md`）—— 实测本 unit 与栈**同图可见（31 节点）**，投递正常。同样是 `rmem_max` 背的锅。**结论：不需要塞进栈 launch。**
3. ✅ 证实：IMU 速率必须 pin 成 gyro 200 / accel 100，否则节点自动挑 400/200 → `Motion Module failure`，IMU 无数据。

**默认档位 = `full`（depth + infra1 + infra2）**，对齐出厂 `realsense2_camera/launch/high_performance.py`（848x480、三路全开）。
出厂 VIO `ov_msckf/launch/ros2.launch.py` 的 remap 要的正是 `camera/infra1`、`camera/infra2`、`camera/imu` —— 只开 depth+infra1 的话 VIO 拿不到右目，所以默认给全。

**与既有工作流的关系（实测过，不是推理）**
`PartOf` + `WantedBy` 让相机成为栈的 sidecar：`systemctl stop jp5-cyberdog-stack` → 相机自动停、USB 设备释放；`start` → 相机自动回来。
所以 `/home/mi/rs-poc-run.sh`、`/home/mi/factory-node-revive.sh`（都是"停栈→独占相机→起栈"）**一行都不用改，也不会 device-busy**。`jp5-stack-doctor` 重启栈时相机跟着重启，同样正确。

**防呆**：`Restart=on-failure` + `RestartSec=20` + `StartLimitBurst=5/900s`（不做每几秒 chroot 加载 202MB 库的永动机）；`RestartPreventExitStatus=78`（缺文件类错误直接躺平等人）；`SuccessExitStatus=143`（正常停机不落 failed 态）；哨兵在 SoC ≥85°C 时拒绝动手。

**回滚**：`sudo bash /tmp/d455-stage/bin/d455-deploy.sh uninstall` —— 删干净，栈与出厂文件全程未被碰过。

## 🔴 音频路由：我们自己把调试期的错误固化进了「金标准」（已修）
`/etc/cyberdog-audio-golden.state` 里三个控件全部偏离 JP4 出厂值：

| 控件 | JP4 出厂 | 我们的 golden（错） |
|---|---|---|
| `I2S5 Mux` | `ADMAIF1` | `ADMAIF4` |
| `ADMAIF1 Mux` | `I2S5` | `None` |
| `I2S5 Loopback` | `true` | `false` |

`ADMAIF4` 是调试期用 `hw:1,3` 试喇叭留下的。后果三连：
1. **pulse 播出去的字节一个都没到功放**——语音播报全部丢进黑洞（"喇叭已验收出声"验的是 `hw:1,3` 直推，与 pulse 是两条路）
2. 没有 I2S 背压做 flow control → ADMA 以 **106 倍实时速度**空转 → `dma1chan0` 中断 **623 次/秒** → pulseaudio 常驻 89% CPU
3. AEC 参考回环饿死（`dma1chan1` 自开机只触发过 1 次）→ **这就是 athena_audio aec 线程超时的真因**

修复后实测：中断率 623→11 次/秒、pulseaudio **89%→3%**、负载 5~7→2.0、48kHz 无 xrun。已固化进 golden.state。
⚠️ **副作用（必须记住）**：`hw:1,3` 路径现在不出声了，那是错误路由。**验证喇叭必须改用 `hw:1,0`**，否则会误判"喇叭坏了"。
⚠️ 「远程无法确认声音是否真的响」——需要人耳，或机主在场。

> 顺带否决：审计原定的 `tsched=0` 方向已被实测证伪（623 次/秒的中断率证明 DMA 真在搬数据，切中断驱动只会把定时器唤醒换成硬中断，填充量一分不减）。**不要动内核、不要重建 tegra210-adma.ko。**

## 🔓 DDS 发现通了
栈用 `ROS_DOMAIN_ID=42` + `ROS_LOCALHOST_ONLY=1` + `RMW_IMPLEMENTATION=rmw_cyclonedds_cpp` +
`CYCLONEDDS_URI=file:///etc/systemd/system/cyclonedds.xml`。用对这套环境即可从 chroot 看到全部 20 个节点、
调出厂栈的 service。此前用默认 domain 0 什么都发现不了。

## 传感器：从「推理」变成「实测」
- **前超声：实测出数**（`/mi1045904/ObstacleDetection` ~10Hz、range=0.2083m、回波幅值 8891~10161 有抖动=真回波）
- **底部 ToF、底部光流、光线传感器：实测出数**（ToF 18.6~19.6mm 与趴地姿态吻合；光线 0.2066 lux）
- **后超声：实测不存在**——全局广播使能点名，8 类传感器只有 type 7 `PROXIMITY_REAR` 一帧不出。**器件未装配，不是移植问题，不要再投时间**
- 状态表里「超声×4」是错的：实际是前超声 1 + 底部 ToF 1 + 底部光流 1
- **关键**：整个 `cyberdog_ros2` 树里没有任何开源节点会发 ENABLE（`motion_manager.cpp:168` 建了 client 但从没 `async_send_request`）。使能只可能来自闭源手机 App → **不做动作的话这些传感器在 JP5 上永远是黑的**
- 两个出厂级缺陷（JP4 上同样坏，非 JP5 引入）：`get_regulater_name()` 三次 `snprintf` 都从偏移 0 写导致 MCU 掉线自愈从未生效；底板时间戳帧只有 4 字节有效载荷而主机拷 8 字节，导致所有底板传感器时间戳是垃圾

## AI 头顶相机：R32 采集 ABI 已部署，卡在 RCE 固件侧总线错误
部署了 `build/r32-capture-backport/`（4 patch，**纯增量 +2809/-0**，全部包在 `CONFIG_TEGRA_CAPTURE_R32_ABI` 里，
9 条 `static_assert` 编译期证明 R32 布局全局生效：`CAPTURE_CHANNEL_SETUP_REQ==0x10`、`capture_channel_config==216`、
`capture_descriptor==704`）。Image `f4b6a035…`，DTB/initrd 未动，零回归。

**实测结果（走真实 argus 路径）**：
```
kernel: CPU:0, Error:rce-noc  →  Host read timeout at address 303cc (0x15a303cc = NVCSI 空间)
kernel: Camera RTCPU gone bad! restoring it immediately!!
kernel: isp capture control message timed out / isp capture setup failed
argus:  Error IoctlFailed → Failed to create CameraProvider → 断言失败
```
判别标记 `r32-abi: ... setup accepted` **没有出现**。

**定性**：消息送到了、RCE 固件开始执行了，但在解引用时落到未响应的地址上崩溃（`rce-noc` 是 RCE 自己的 NoC 端口）。
这与 NOTES 点名的头号未知数**吻合但不构成证明**——R35 的 `capture_get_gos_table()` 直接返回 count=0/table=NULL
（`nvhost_syncpt_get_gos()` 这个符号在 R35 里根本不存在），若 R32 固件解引用这张空表即是此现象。

**安全性**：RCE 崩溃**只在主动驱动采集时发生**，开机握手干净（`cmd=5`），RCE 每次都自恢复成功，
整机零影响（0 failed 单元、0 内核崩溃、WiFi/音频/6核/9 video 节点全在）。**这个内核留着是安全的。**

**下一步**：GoS 表是最该证伪的一件事，且便宜——在 JP4 引导下抓一次 `num_vi_gos_tables` 实际值。

## 🔊 喇叭修复完成（2026-07-26，机主亲耳验证）

**验证方式最硬**：修好后机主听到了**出厂语音播报**（"开始充电"、"电量低于10%"）自己响起来——不是测试音，是工厂栈自己发的。

**病根**：pulseaudio 只能选到单声道 profile，而 TAS5805M 需要立体声 I2S 帧，收到单声道帧就报 `CLK_FAULT` 并静音。

```
默认 profile-set: [Mapping analog-stereo] device-strings = front:%f   ← 这块卡没有 front:1 → profile 不可用
                  [Mapping analog-mono]   device-strings = hw:%f      ← 可用 → 只能选单声道
```

**修法（两处，都极小）**：
1. `/usr/share/pulseaudio/alsa-mixer/profile-sets/cyberdog.conf`（复制 default.conf，**只改 2 行**）：
   `analog-stereo` 的 `device-strings` 改成 `hw:%f`、`priority` 提到 20
2. 宿主 `/etc/udev/rules.d/91-cyberdog-pulse-stereo.rules`（1 行）：
   `SUBSYSTEM=="sound", KERNEL=="card*", ATTR{id}=="jetsonxaviernxa", ENV{PULSE_PROFILE_SET}="cyberdog.conf"`

**⚠️ 踩过的坑**：`load-module module-udev-detect profile_set=xxx` 在 **PulseAudio 11.1 上不支持**，会 `Failed to parse module arguments` → `Module load failed` → **整个 pulse 起不来**。必须走 udev 属性这条路。备份在 `default.pa.bak-mono`。

**验证结果**：
| 项 | 修复前 | 修复后 |
|---|---|---|
| 声卡 profile | `output:analog-mono+input:analog-mono` | `output:analog-stereo+input:analog-stereo` |
| sink | 1ch | **2ch 48000Hz RUNNING** |
| 麦克风 source | 正常 | **仍正常**（未被破坏） |
| 功放 `0x71` | `0x04` CLK_FAULT | `0x00` 无故障（放音时） |
| pulseaudio CPU | 89% → 3%（路由修复）| **0%** |
| 出厂语音播报 | 静默 | **能听到** |

判据补充：功放空闲时 `0x71=0x04` 是**正常**的（无流即无时钟），只有放音期间读到 `0x00` 才算通。

## 🔌 充电/电池（2026-07-26 实测确诊）
- 适配器插了数天，实测**充电电流恒为 0~40mA**（真充电是 3A），`checkcharge.sh` 判定"适配器已识别但没充上"
- **拔掉适配器后空载 15 秒内 SOC 从 17% 塌到 0%**，电压每 5 秒掉 80mV → **电芯失效/内阻过大，电池报废**
- "开始充电"语音只代表适配器被识别，**不代表真在充电**
- 机主已决定：先不换，全部工作完成后再买新电池

## 🚫 运动锁存 = 适配器联锁（不是欠压锁存，机主判断）
`[State_Detection] Locking state & Error state detected. Checking to passive` 5Hz 刷屏 = **充电中禁止运动的安全联锁**。
**实测**：拔掉适配器后 26次/5秒 → 0，插回来又出现。
→ **不需要长按断电清锁存**；站立前拔适配器即可（与旧记忆"站立前必须拔适配器"一致，现已从"疑似"升为实测）。

## ⚠️ USB 线插着断电会进 RCM
电池塌陷导致断电后，因下载口插着 USB 线，重新上电进了 **RCM（USB ID 变 `0955:7e19` APX，串口消失）**。
恢复：插好适配器 → **拔掉 USB 线** → 长按电源到灯全灭 → 开机。
本次恢复后 `PMC reset source: SYS_RESET_N`（真硬件复位），**全家桶全自动恢复、0 failed 单元** —— 这是"零人工干预"约束的一次有分量验证。

## 🔵 蓝牙 GATT 打通（2026-07-26）
**唯一阻塞是 chroot 内缺 `/run/dbus` bind** —— 出厂 `gattserver` 通过 D-Bus 跟宿主 bluetoothd 通信（`org.bluez` 的 `GattManager1`/`LEAdvertisingManager1`）。
补进 `jp5-chroot-prep.sh` 即通，顺带修掉 chroot 内 pulseaudio 反复刷的 "Failed to connect to system bus"。

新增 `jp5-bluetooth-gatt.{sh,service}`（宿主 unit 包装出厂 gattserver），**已设开机自启**。
验证：`get psn=P21511820GR00177ZM` / `BLE_STATUS_ADV` / `GATT application registered` / `Advertisement registered`。

**⚠️ 踩坑**：systemd 不带 `HOME`，而 ROS2 的 `rcl_logging_spdlog` 要用它展开 `~/.ros/log`，缺了直接
`rcutils_expand_user failed` → `Failed to initialize logging` → 退出。出厂 unit 是 `User=root`（systemd 自动给 HOME），
chroot 包装会丢掉，**必须显式 `export HOME=/root`**。这个只有真 `systemctl start` 才暴露，交互式试跑看不出来。

## 💡 LED 子系统实测通过（2026-07-26）
`led_server` 节点实时处理 LED 命令（`start process led cmd` / `command=28` / `command=9`），
**机主目视确认头部橙灯在闪**（低电量指示，与电池 0% 吻合）。
→ 整条链路 **ROS2 节点 → led_server → CAN → MCU → 灯珠** 全部验证，
元器件表里最后一个"只靠推理挂着"的项已结案。

## 自启服务清单（全部 enabled，2026-07-26 实测）
| 服务 | 作用 |
|---|---|
| `fanboy` | 温控守护 v2（反极性风扇曲线 + 92°C CPU 频率封顶 + 82°C 迟滞恢复） |
| `deadman` | 用户态黑匣子 |
| `audio-init` | 声卡金标准回放（v2 如实上报 + `Before=stack`） |
| `cyberdog-health` | 长稳基线采集 |
| `cyberdog-timekeeper` | 时钟单调地板（只向前推） |
| `jp5-cyberdog-stack` | chroot 出厂 ROS2 栈 |
| `jp5-cyberdog-net` | 内网/CAN |
| `jp5-boot-ok` | 清启动尝试计数器（oneshot，inactive 属正常） |
| `jp5-bluetooth-gatt` | 蓝牙 GATT（手机 App 通道） |
