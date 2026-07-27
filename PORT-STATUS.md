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
2. ~~**串口控制台**：笔记本 `ben@10.0.0.176` 的 `/dev/ttyACM0`（115200）→ 可在 cboot extlinux 菜单远程选启动项。~~
   🔴 **2026-07-27 实测推翻，这条不能当救援手段用。**
   那个 `/dev/ttyACM0` 不是内核控制台，是 **USB gadget 的 `acm.GS0` → 狗侧 `/dev/ttyGS0`**，上面跑的只是 `agetty`。
   证据：①`/proc/consoles` 只有 `tty0 / ttyTCU0 / ramoops-1`，**没有 ttyGS0** ②写 `/dev/kmsg` 到不了笔记本，直接写 `/dev/ttyGS0` 才到 ③gadget 由 `nv-l4t-usb-device-mode` 在 **T+19.4s** 才创建，agetty 在 T+89s ④笔记本 `lsusb` 上没有任何第二个 usb-serial 桥。
   **内核启动只花 15.7s，所以引导器输出和 probe 挂死整个落在 [0, 19.4s] 这个盲区里，这条线原理上看不见。** 也就**够不着 extlinux 菜单**。
   → 真·内核控制台是 `ttyTCU0`，走板上调试 UART，需要机主接 USB-TTL(3.3V)。见新增的 §2026-07-27。
   → 当前笔记本上已常驻 `cyberdog-serial-log.service`，覆盖 T+19.4s 之后的用户态输出 + 掉线/回归时刻，**不覆盖早期启动**。
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
| GPS (BCM4775) | ✅ 链路通（待室外定星） | **2026-07-27 改判**：串口实测在发合法 Bream/UBX 帧（`0xB5 0x62`）并抓到 `$GP`/`GGA` 片段；出厂节点独占 `/dev/ttyTHS0` 且**本来就有**读线程（`scene_detection.cpp:243-250`）。`/SceneDetection` 静默是因为发布条件要求有效经纬度（室内无星）→ 出厂正确行为，**不是数据链坏**。体检：`cyberdog-gps-check.sh` |
| 电池 / BMS | ⏸️ 物理项 | **机主已物理拆除电池**，当前适配器供电（只有 `usb-charger`，无 battery 节点） |
| AI 头顶相机（3 sensor） | ❌ 不通 | RCE 固件活(cmd=5)、IVC 通、nvcsi initialized、3 颗 subdev 全 bound、nvmap 手术已过 —— 但采集控制面 ABI 结构性分家 |
| 前超声 / ToF / 光流 / 光线 / LED | ✅ 已通 + 开机自动使能 | 0725 实测出数；**2026-07-27 补上自动使能** `cyberdog-sensors.service`：A/B 实测 `ObstacleDetection` 0.00→10.13 Hz、`BodyState` 0.00→25.01 Hz。（开源树里没人发 ENABLE，本该由闭源手机 App 发） |
| 背部触摸板 | ✅ 已通 | 驱动 4.9→5.10 移植(3 文件 56 行)+ DT 使能；`event0=synaptics_dsx`，出厂 `touch_publisher` 节点已 activate。⏸️ 物理触摸未由人验证 |
| 系统时钟 | ❌ 不通 | 停在 2000-01-01（双根因，见下） |
| swap | ❌ 无 | 内核没编 `CONFIG_ZRAM`，`nvzramconfig` failed |
| 硬件看门狗 | ❌ 禁用 | DT 里禁着，"挂死后自愈"零路径 |
| pstore / ramoops | ✅ 已通 | 纯 extlinux cmdline 零内核零 DTB 改动；**每次开机完整 console 日志(从 `[0.000000]` 到最后一行)自动落盘归档**，见下节。⚠️ 只覆盖热复位，硬断电 DRAM 掉电无解 |
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

---

## 🗳️ ramoops 黑匣子（2026-07-26 落地并端到端验证）

**零内核改动、零 DTB 改动** —— 只在 eMMC p1 的 `/boot/extlinux/extlinux.conf` 的 `LABEL jp5` 的 `APPEND` 尾部加一串模块参数。备份 `extlinux.conf.pre-ramoops`。

```
ramoops.mem_address=0xf0800000 ramoops.mem_size=0x200000 ramoops.record_size=0x10000 \
ramoops.console_size=0x80000 ramoops.ftrace_size=0 ramoops.pmsg_size=0 ramoops.max_reason=3
```

### 为什么原来 probe -22
DT 的 `reserved-memory/ramoops_carveout` 是**动态保留**(只有 `size`/`alignment`/`alloc-ranges`，没有 `reg`)。
R35 换成上游 `compatible="ramoops"` 的 `ramoops_parse_dt()` **要求 `reg`** → `-EINVAL`。
绕法：ramoops 是 **builtin**，`ramoops_register_dummy()` 在 `mem_size!=0` 时用模块参数造一个 dummy platform device，
`platform_data` 非空就整个跳过 DT 解析。DT 那个设备随后 probe 会打一句 `already initialized`，无害。

### 地址是怎么锁死的（三重独立证据，别再靠猜）
| 证据 | 值 |
|---|---|
| 引导器交给内核的 `/memory` 节点 | `0xac200000‑0xf09fffff` |
| 内核 `memblock.memory` 实际 | `0xac200000‑0xf07fffff` |
| **内核自己挖掉的差值** | **`0xf0800000‑0xf09fffff` = 正好 2 MiB** |

- 大小与 `ramoops_carveout` 的 `size=<0 0x200000>` **精确相符**
- 位置与 memblock **自顶向下**分配器的预测**精确相符**（`alloc-ranges` 上限 4 GiB）
- DT 里**唯一**一个非零的 `no-map` 动态保留就是 `ramoops_carveout`
- `of_reserved_mem` 对 `no-map` 走 `memblock_remove()`，所以它表现为**真空洞**而不是带 flag 的区段

⚠️ **`0xac000000` 那个洞也是 2 MiB，但它是引导器的**（`/memory` 节点里本来就没有它）。
用它会写进引导器 carveout —— `request_mem_region` 不会拦（没人注册 iomem），会**静默写坏**。

### 🔴 最关键的坑：`Unlink=yes` 会抹掉当前这次开机的日志
`ramoops_pstore_erase(PSTORE_TYPE_CONSOLE)` → `persistent_ram_zap(cprz)`。
也就是**删 pstore 文件会 zap 掉【正在用的】console 环形区**。
`systemd-pstore` 默认 `Unlink=yes` 且在 **~17s** 运行 → 每次开机都把 `[0..17s]` 抹干净，
**而那正是驱动 probe 挂死的窗口，黑匣子最该看见的地方**。

实测铁证：
| | |
|---|---|
| boot B 里 systemd-pstore 运行于 | `[17.072 – 17.188]` |
| boot B 归档的第一行 | `[17.280506]` ← 紧接着的下一条 |
| boot A 归档的第一行 | `[0.000000]` ← 当时 `/sys/fs/pstore` 是空的，`ConditionDirectoryNotEmpty` 没过，**根本没运行** |

**修法**：`/etc/systemd/pstore.conf` 设 `Unlink=no`（备份 `.orig`）。
崩溃记录改由 `cyberdog-blackbox-rotate` 归档后自己 `rm /sys/fs/pstore/dmesg-ramoops-*` 消费掉 ——
erase 一个 dump prz 只 zap 它自己，**不碰 console prz**（`ramoops_pstore_erase` 的 `case PSTORE_TYPE_DMESG`）。

### 归档链
`ramoops 环形区` → `systemd-pstore`(copy, 不 unlink) → `/var/lib/systemd/pstore/` → **`cyberdog-blackbox-rotate.service`** → `/var/log/cyberdog-blackbox/<时间戳>[-CRASH]/`，保留最近 30 次。
> systemd 245 写的是**扁平文件名**(`console-ramoops-0`)，不转存的话下次开机直接覆盖，黑匣子只有一层深。
> 目录名带 `-CRASH` 表示上次是**真崩溃**(有 `dmesg-ramoops-*`)，一眼可辨。

### 验收（5 次重启实测）
- `ramoops: using 0x200000@0xf0800000, ecc: 0`；`/proc/iomem` 24 个 `ramoops:dmesg(N/23)` + `ramoops:console`，正好铺满 2 MiB
- 归档 **796 行 / 55639 字节**，首行 `[0.000000] Booting Linux on physical CPU 0x0000000000`，末行 `[72.434193] reboot: Restarting system`
- 用户态面包屑：`<3>`/`<4>` 前缀能进环形区；**无前缀的 `/dev/kmsg` 进不去** —— `printk` 是 `6 6 1 7`，
  `default_message_loglevel=6` 而 `6 >= console_loglevel(6)` 被过滤。写黑匣子必须带 `<4>` 或更低。
- 零回归：6/6 温区、6 核 pmode2、0 failed、36 模块、9 video、2 声卡、rmem 26MB、zram 6、
  RCE cmd=5、CAN UP、eth0 5075 pkt/s、`I2S5 Mux=ADMAIF1`、功放 `0x71=0x00`、31 个 ROS2 节点

### ⚠️ 覆盖边界（别高估它）
| 场景 | 能不能拿到 |
|---|---|
| panic / oops（`panic=15` 自动热重启） | ✅ |
| 正常重启、异常重启 | ✅ |
| **真挂死需要拔电** | ❌ **DRAM 掉电即失** |
| 热跳闸断电 | ❌ 同上 |

~~补这个缺口的唯一办法是**在救援笔记本上常驻串口日志**(`/dev/ttyACM0` → 落盘)，与 ramoops 互补。~~
🔴 **2026-07-27 实测：`/dev/ttyACM0` 补不了这个缺口**（它是 USB gadget 的 ttyGS0，T+19.4s 才存在）。详见下节。

---

# 2026-07-27 追加

## 🔴 「串口控制台」这条救援路是假的（三重安全网实为两重）

笔记本上的 `/dev/ttyACM0` **不是内核控制台**，是 L4T USB gadget 的 `acm.GS0` → 狗侧 `/dev/ttyGS0`，上面只有一个 `agetty`。

| 证据 | 结果 |
|---|---|
| `/proc/consoles` | `tty0` / `ttyTCU0` / `ramoops-1` —— **没有 ttyGS0** |
| 写 `/dev/kmsg` | 笔记本收不到 |
| 直接写 `/dev/ttyGS0` | 笔记本**收到** |
| gadget 创建时刻 | `nv-l4t-usb-device-mode` 在 **T+19.4s**，agetty 在 T+89s |
| 笔记本 `lsusb` | 只有 `0955:7020`，**没有第二个 usb-serial 桥** |

内核启动只花 **15.7s** → 引导器输出与 probe 挂死整个落在 `[0, 19.4s]` 盲区，**这条线原理上看不见**，也够不着 extlinux 菜单。
以前"实测打回 `cyberdog-jp5 login:`"是真的，但那是 agetty，只能证明狗已经完成启动。

**已部署（笔记本 `ben@10.0.0.176`）**：`cyberdog-serial-log.service` + `/usr/local/bin/cyberdog-serial-log.py`
→ 落盘 `/var/log/cyberdog-serial/console.log`（logrotate 14 天）。
- **只读打开**（`O_RDONLY`）+ `CLOCAL` + `-HUPCL`：从 OS 层面保证我们不可能往那个口写一个字节
  （狗的 extlinux 菜单在等按键，写进去会改启动项）
- 用 by-id 稳定路径，设备消失（狗重启/RCM）不是错误，自动等回来
- **实际覆盖**：T+19.4s 之后的用户态输出、掉线/回归的精确时刻、login 提示。**不覆盖早期启动。**

**要补早期盲区只有一条路**：接板上调试 UART（`ttyTCU0`）到 USB-TTL(3.3V)。⏸️ 需机主动手。

## ✅ ov_msckf 单目 VIO 上线（`ov-vio.service`）

栈的 sidecar（`WantedBy` + `PartOf`，与 d455 同一套语义）。**修掉两个会静默出错的坑**：

1. **内参对不上**：出厂 launch 硬编码 640x480（`fx=388.36 cx=319.38 cy=240.99`），而 D455 跑在 848x480（`fx=429.77 cx=427.41 cy=236.46`，cx 差 **108 像素**）。
   内参错了 VIO **不报任何错**，只是安静输出错误轨迹。已按 `camera_info` 实测值覆盖，节点启动打印证实：`cam_0_wh: 848 x 480` / `cam_0_intrinsic: 429.766 429.766 427.407 236.462`。
   （外参 `T_C0toI` 平移 `[-0.03, 0.007, 0.016]` 与 D455 手册 IMU→左红外偏移吻合，且与分辨率无关 → 保持出厂值。）
2. **IR 点阵发射器**：开 depth 就开投射器，infra 上的散斑**跟着相机走** → 无视差的假特征 → KLT 咬住它们 → VIO 认为自己没动。**不是精度问题，是结果无效。**
   实测 A/B（相邻像素绝对差均值）：**ON=4.152 / OFF=1.376**。
   由 service 启动时关、停止时还原（`ov-vio-emitter.sh`，双向实测过）。代价：depth 退化成纯被动双目（当前 depth 订阅者=0）。

**lifecycle 陷阱**：`ros_subscribe_msckf` 是 managed 节点，起来后停在 `unconfigured` 只发 `transition_event` —— 极易误判成"坏了"。必须显式 configure→activate。
（另：手写 params.yaml 漏 `stereo_pairs` 会让 configure 抛异常，所以坚持用出厂 launch 只覆盖内参。）

**实测无回归**：0 failed、6/6 温区、63°C、eth0 **5089 pkt/s**（基线 ~5075，运动板没被抢）、相机 infra 30.3Hz / imu 198.6Hz。
⚠️ VIO 占 **171% CPU**（1.7/6 核），load→12，靠 `Nice=10 + CPUWeight=30` 让路。要降可调 `num_pts` 或开 `downsample_cameras`。
⏸️ **必须机主在场才能验收**：VIO 需要运动才初始化（`no IMU excitation 0.0147 < 0.4`，狗静止是**正确行为**）。
注：本机是小米改版，输出话题是 `odomfoot`/`odomfusion`/`poseimu`/`pathimu`，不是原版 `odomimu`。

## ✅ 传感器开机自动使能（`cyberdog-sensors.service`）

| 话题 | 使能前 | 使能后 |
|---|---|---|
| `/ObstacleDetection` | **0.00 Hz** | **10.13 Hz**（真回波 0.2227m） |
| `/BodyState` | **0.00 Hz** | **25.01 Hz** |

坐实了旧判断：开源树里没人发 ENABLE（`motion_manager.cpp:168` 建了 client 却全树零次 `async_send_request`），本该由闭源手机 App 发。
用 `ception_msgs/srv/SensorDetectionNode`：`obstacle_detection` 发 `ENABLE_ALL(4)`；`athena_body_state` 发 `ENABLE_ROTATION_VECTOR(50)`+`ENABLE_SPEED_VECTOR(52)`；`timeout=ALWAYSON`，`clientid=9`（避开出厂 BMS=1/BT=2/AUDIO=3）。
服务**自验收**：光有 `success=True` 不算，要话题真出数达标才算成功。
⚠️ 我们是常驻 ALWAYSON client（引用计数语义）→ 手机 App 之后关不掉这些传感器。要还原：`SENSOR_DISABLE=1` 跑一次。

## 🔴 新踩的坑：`chroot ... su - mi -c` 在无 tty 时吞掉内层 stdout

手工跑（有 tty）能看到全部输出，**systemd 起的时候 journal 里一行都没有**；加 `python3 -u` 无效（不是 python 缓冲，是 `su` 那一层）。
对"价值全在自验收输出"的服务等于白做。**修法**：包装器先把输出抓进变量，再由自己逐行 echo。
⚠️ 同一个吞噬也影响既有的 `d455-camera-inner.sh` 和新的 `ov-vio-inner.sh` 的内层日志（关键输出走宿主侧脚本，所以只是观测性损失）。

## ✅ GPS 改判：链路是通的，不需要写桥

原判断「出厂节点没有串口读线程 → 数据链没通 → 得自己写个桥」**是错的**：
1. 开源 `scene_detection.cpp:243-250` **本来就有**读线程，init 里就 `SetMsgRate(0xF0,…)` 开了 GPGGA/GPRMC/GPSV
2. 出厂 `service_scene_detection` **独占持有** `/dev/ttyTHS0` 并在读 —— 再写一个桥只会互相抢字节
3. 串口实测活着：合法 Bream/UBX 帧同步头 `0xB5 0x62`（class 0x04 INF / 0x02），并抓到 `$GP`/`GGA` 片段
4. 静默的真因在 `gps_data_receiver_callback`：`if (flag==1 && (lat!=0 || lon!=0))` —— **没有效经纬度就一条不发**。室内无星 → 0 Hz 是**出厂正确行为**
5. `GPS_START` 服务返回 success

**唯一没验证的是室外能不能定星** ⏸️ 需机主把狗抱到露天。
体检工具：`cyberdog-gps-check.sh`（驱动层 + 串口活性 + ROS 话题层，一条命令）。
⚠️ 波特率 **3000000 是对的**，别去"修"它。

## 🔬 kernel-E 炸机静态分析（§6.4 前置，零风险离线完成）

1. **kernel-E 实际改了什么**：DTB 侧只有两处功能改动 —— 触摸板（已证明是好的，今天仍在跑）+ 相机电源拓扑（`nvcsi/vi/vi-thi/isp` 加 power-domains+resets+clocks）。ramoops 根本不在 DTB 里（纯 extlinux cmdline），"H2 拆分"对 DTB 输出零影响。Image 侧多了 C 补丁 0002/0003/0004：`camrtc_device_group` 标记 good=**1** / failed=**4**，`nvcsilp` good=0 / failed=1。
2. 🔴 **A/B 对照没有真正隔离元凶**：撤除时 DT 那半和 C 补丁那半是**一起**撤的。现有证据只支持"相机电源这项工作整体是元凶"，**不支持"具体是 DT 还是 C 补丁"**。下次必须拆成两个独立可启动变体（血的教训#1 的直接应用）。
3. ✅ **排除掉一个主要假设**（实测只读）：原怀疑"R32 BPMP 不认识 VE 域 → MRQ 无应答 → 阻塞"。实测证伪 —— BPMP debugfs 完整暴露 `powergate/ve` 和 `powergate/ispa`，`powergate_summary` 正常应答，`ve/state`=0、`ispa/state`=0 读取 rc=0，且**同一条 MRQ 路径上 aud/disp/xusba-c/pciex8a/gpu 正在被实际使用且已上电**；补丁引用的时钟 `nvcsilp` 204MHz、`vi_const` 408MHz 在运行内核里都存在且健康。
   → **BPMP 通信层是好的，挂死点在内核侧的 attach / runtime-PM / reset 时序。**
   头号嫌疑：`t19_nvcsi_info` 的 `.keepalive`/`.poweron_reset`，以及 `camrtc_device_group_busy()` 被放在 `tegra_cam_rtcpu_runtime_resume()` 里跨设备跨域嵌套 `pm_runtime_get_sync()`。
4. ✅ **VE / ISPA 点火实验已做（2026-07-27，机主在场）—— 结果是关键的好消息**，见下节。

## ✅ 冷启动验收（连续两次重启，零回归）

验收脚本 `cyberdog-acceptance.sh` —— 重启前后跑同一份，逐行 diff 即回归报告。

两次重启后全部一致：`0 failed`、6/6 温区、pmode 2、rmem 26MB、0 oops、0 deferred、9 video、2 声卡、
can0 UP、`I2S5 Mux=ADMAIF1`、eth0 **5107 pkt/s**、37 个 ROS2 节点、
相机 30.2Hz / imu 196.9Hz、`ObstacleDetection` 10.0Hz、`BodyState` 25.0Hz、
`ov_msckf` **active [3]**、`emitter_enabled=0`、黑匣子归档 4→6（每次开机都归档，首行 `[0.000000] Booting Linux`）。

**两个新服务冷启动自证**（journal 原文）：
```
[ov-vio-emitter]  emitter_enabled=0 OK (attempt 1)
[ov-vio-activate] final state: active [3]
[cyberdog-sensors] OK /mi1045904/ObstacleDetection -> 9.93 Hz
[cyberdog-sensors] OK /mi1045904/BodyState -> 23.70 Hz
[cyberdog-sensors] RESULT: all sensor groups enabled and verified
```

## 🔴 新问题：传感器使能会运行时退化，且**重发 ENABLE 救不回来**

运行约 11 小时后实测 `ObstacleDetection` 从 10 Hz **掉到 0.00 Hz**（`BodyState` 从 25 降到 15，未归零）。

排查结论（都是实测）：
| 层 | 状态 |
|---|---|
| CAN 总线 | ✅ 健康：`ERROR-ACTIVE`、berr-counter 0/0、零 bus-error/bus-off、rx **45 pkt/s** |
| ROS 服务端 | ✅ 应答正常：重发 `ENABLE_ALL` 返回 `success=True, clientcount=2` |
| 话题 | ❌ 仍然 **0.00 Hz** |
| 强制刷新（`DISABLE_ALL` → `ENABLE_ALL`） | ❌ 无效，且 `DISABLE_ALL` 后 clientcount **没有下降** |
| 重启 | ✅ **当场恢复到 10 Hz** |

→ 典型的**引用计数记账与硬件真实状态漂移**：服务端认为"已经开着，不必再下发"，而 MCU 侧那一路其实已经卡死。
→ 和出厂那个已知缺陷吻合：`get_regulater_name()` 三次 `snprintf` 都从偏移 0 写，导致 **MCU 掉线自愈从未生效**（JP4 上同样坏）。
→ **待办**：加一个传感器健康哨兵（timer，发现 0 Hz 持续 N 次就重启栈并告警）。目前唯一恢复手段是重启。

## 🔴 狗重启会打死笔记本的 xHCI（USB 救援通道没有想象中可靠）

第二次重启后笔记本 `lsusb` 上**整个 bus 003 全没了**，dmesg：
```
xhci_hcd 0000:00:14.0: xHCI host controller not responding, assume dead
xhci_hcd 0000:00:14.0: HC died; cleaning up
```
狗侧完全正常（UDC 已绑定、4 个 function 都在、`/dev/ttyGS0` 在、`EP 0 enabled`）—— **是笔记本侧的控制器猝死**。

**救法**（已实测，来自旧记忆条目）：
```bash
echo 0000:00:14.0 | sudo tee /sys/bus/pci/drivers/xhci_hcd/unbind
sleep 3
echo 0000:00:14.0 | sudo tee /sys/bus/pci/drivers/xhci_hcd/bind
```
⚠️ 先确认笔记本的 ssh 不走 USB 网卡（本机走 PCIe 的 `wlp0s20f3`，安全）。
⚠️ **含义**：USB 救援通道（192.168.55.1）和串口日志在狗重启后**可能需要人工 unbind/bind 才能恢复**。
做高风险内核改动前要把这条算进去 —— 它不是无人值守可靠的。

## 🔧 串口记录器修掉两个缺陷（都是 A1 重启验收暴露的）

1. **设备重新枚举后记录器抱着死 fd 空转**：狗重启后 by-id 符号链接从 `ttyACM0` 指到了 `ttyACM1`，
   而旧 fd 指向已消失的 ttyACM0，`read()` 只是一直返回 `EAGAIN` **不报错** →
   记录器看似在跑、实际永远收不到一个字节，**整个重启窗口一行没记到**。
   修法：每秒 `os.stat(dev).st_rdev` 与 `os.fstat(fd).st_rdev` 比对，变了就重开。
2. **`StartLimitIntervalSec` 放错 section**：写在 `[Service]` 里会被 systemd 当未知键忽略
   （`Unknown key name 'StartLimitIntervalSec' in section 'Service'`），限流形同虚设。必须放 `[Unit]`。

修后实测闭环：`device re-enumerated, reopening` → `waiting for …` → 设备回来自动重连 → 捕获到 `cyberdog-jp5 login:`。

## ✅ VE / ISPA 电源域点火实验：**能上电，且完全干净**（2026-07-27，机主在场）

AI 相机主线上最便宜、最决定性的一步。只写 NVIDIA 自己的 BPMP debugfs，不动内核、不动 DT、不重启。

| 步骤 | 结果 |
|---|---|
| `echo 1 > powergate/ve/state` | ✅ 写入成功，`ve: 0 → 1` |
| `echo 1 > powergate/ispa/state` | ✅ 写入成功，`ispa: 0 → 1` |
| 新增 oops / `rce-noc` / SMMU fault | **0**（点火后、静置 10s 后、恢复后三次采样都是 0） |
| failed units / 温度 | 0 / 65.5°C 无变化 |
| 恢复 `echo 0` | ✅ 两个域都干净落回 0，系统仍在线 |

### 为什么这条结论很重要

**这套 `R32 BPMP 固件 + R35 内核` 的混血系统上，VE 和 ISPA 电源域本身完全可以正常上下电。**
也就是说 kernel-E 炸机 **不是"电源域这条路走不通"**，而是 **内核侧的 attach / runtime-PM / reset 时序**问题。
配合前面已经排除的 BPMP 通信层，现在可以把嫌疑范围收得很窄：

- `t19_nvcsi_info` 的 `.keepalive` / `.poweron_reset`
- `camrtc_device_group_busy()` 被放在 `tegra_cam_rtcpu_runtime_resume()` 里跨设备跨域嵌套 `pm_runtime_get_sync()`
- `vi_thi` / `isp` 这两个**没有 `reg`** 的节点被加上 `power-domains` 后的 attach 行为

→ **重做 NVCSI 电源域的把握度显著提高**，NOTES 里原来写的 70–80% 可以上调。

### 一个必须记住的细节

BPMP 侧 `ve/state=1` 的同时，内核 genpd 里仍然是 `ve off-0`，`nvcsi/nvcsilp/vi` 的 `enable_cnt` 仍然是 0。
**BPMP 记账与内核 genpd 记账是两套**，直接写 debugfs 会绕过 genpd。
所以这个实验证明的是「硬件+BPMP 能上电」，**不等于**「内核把设备挂上去之后也能正常走完 attach」——
后者正是 kernel-E 死掉的地方，必须靠拆分变体去验。

### 顺带发现的噪音（不紧急）

`uvcvideo: Failed to query (GET_CUR) UVC control 1 on unit 3: -32` 在持续刷屏（-32 = EPIPE），
来自 D455 的 UVC 控制查询。当前不影响取流（30.2Hz 稳定），记一笔待查。
