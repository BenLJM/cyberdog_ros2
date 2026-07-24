# CyberDog 经验教训沉淀（2026-07-22/23 两日战役总结）

> 战果：JP4 与 JP5 双系统零干预站立全部达成；充电之谜破案；JP5 相机双流魔咒打破。
> 配套文档：STAND-TRUTH-2026-07-22.md（站立真相）、JP5-BRINGUP-2026-07-22.md（JP5 架构与过程）。

## 一、电源与硬件铁律

1. **真关机 = 长按电源键到所有灯全灭。** `ssh shutdown -h now` 只关 Jetson 主脑，电源板/运动板继续活着（灯亮）。一切"断电清状态"的操作必须以真关机为准。
2. **运动板低压锁存**：电池电压不足（≈18.2V 及以下实测触发）时运动板置 12 电机欠压错误并**锁存**——电压恢复不会自愈，热插拔电池不清，warm reboot 不清，**只有真断电冷启动能清**。症状=motion_manager 刷 `Locking state & Error state`、recovery_stand 超时。
3. **充电的一切怪象根源 = DC 充电口接触不良**：插着≈没插（整夜零充电）、半接触=能检测不能充（2 秒中止脉冲循环）、按到位=3A 快充。电池本身健康（health 100%、仅 4 循环）。**判据永远看电流不看插没插**：`~/checkcharge.sh`。
4. **充电需开机进行**（关机后电源板不执行充电协商，或至少不可靠）。充电时运动域疑似被锁（风扇停）→ **站立前必须拔适配器，站立中严禁插**。
5. **电量显示会骗人**：老化/深放包 soc 虚高（47%→一次冷启动崩到 1%）；深放电后静置表面电压回升（16.7→18.2V）不代表有容量。低压开机会被开机浪涌反复压死（假"重启循环"）。
6. **Expander GPIO 禁忌**：`RSTN_HUB` 别碰（共享 hub 复位，会连带敲掉 Wi-Fi）；`VBUS_MOTION_EN` 工作态本来就是未驱动（运动板吃电池总线）——站立不需要动任何 expander 输出。
7. **传感器电源开关 = reg-userspace-consumer**（sysfs `state` 写 enabled）：`realsense_switch` / `gps_switch` / `mcu_sensor_switch` / `wifi_bt_switch`，在 /sys/bus/platform/devices/ 下。出厂系统有人写，JP5 上要自己写（已入 jp5-cyberdog-net.sh）。

## 二、软件与架构铁律

8. **"[Offline] Odom state response is offline" 是 DEFAULT 模式正常噪音**（内层循环带模式门禁），不是故障。odom_out 来自**运动板 LCM 腿部里程计**（state_estimator@7669，500Hz），与相机 VIO 无关；"抱狗晃初始化 VIO"是伪需求。
9. **零干预站立机制**：`checkout_mode MANUAL(3)` 成功即自动 recovery_stand。LOW_BTR 只挡 `>=MODE_SEMI(13)` 自主模式。
10. **chroot 跑异版本栈的四件套**（JP5 跑 JP4 Foxy 栈的完整配方）：
    - p1 `/etc/hosts` 必须有 `localhost` 行 + cyclonedds peers 用 `127.0.0.1`（否则 DDS 发现全灭、lifecycle 级联不激活——原生启动靠 systemd nss 掩盖此缺陷）；
    - bind `/run/udev`（V4L2/libudev 类设备枚举必需）；
    - **LCM 就绪门**：栈启动前等到运动板真包到达（加组竞态一旦发生不会自愈）；
    - **自愈 doctor**：栈聋（Motion offline 刷屏）但线上有流 → 自动重启栈。
11. **l4tbr0 要自力配置**：NVIDIA gadget 脚本在无 USB 线冷启动下会留下 DOWN/无 IP 的桥；jp5-cyberdog-net.sh 自己拉桥、配 IP、并 eth0、加 224.0.0.0/4 路由。
12. **JP5 相机突破**（2026-07-23）：5.10 内核 V4L2 完整支持 D455（6 节点含 metadata），**深度+红外并发双流成功（JP4 双流魔咒破除）**，IR 节点含 **Y8I 左右红外交错格式**（单流立体！）→ 立体 VIO 硬件可行。已知坑：出厂 2.48 V4L2 后端起流 core dump（下一步：chroot 内编译新版 librealsense）；RSUSB 后端在 JP5 仍是单流限制。相机枚举前提=电源开关+udev 规则（均已持久化）。

19. **适配器必须开机前插好，严禁带电插拔**：运行中插入适配器的接触抖动会打出电源毛刺 → 整机复位 + Wi-Fi/USB 子系统卡死（warm reboot 治不好，又得冷启动）。正确顺序：真关机 → 插稳适配器 → 开机 → checkcharge 确认电流为正。
20. **救援桥 = download 口**（gadget 设备口，给笔记本 192.168.55.x）；**extension 口是 USB 主机口**——笔记本插上去=主机对主机，报"cable is bad/无法枚举"是正常现象不是线坏。download 口冷开机时别插线（RCM 怪癖），一律开机后热插。

21. **🔥JP5 插电死机真凶=热跳闸（0723 深夜定案，机主推理击破我的接触不良误判）**：移植后内核热区缺失 → nvfancontrol 崩 → 且 **PWM 极性反了（0=全速4258rpm、255=最慢882rpm）** → 风扇一直怠速 → 满载约30分钟 SoC 硬件 thermtrip → PMIC 断电并**锁定关机**（必须重新上电），零日志、电源板灯照亮（假活）。已装 `fanboy.service`（BPMP 直读 /sys/kernel/debug/bpmp/debug/soctherm/group_CPU/temp、反极性曲线、≥92°C 掐重负载）+ `deadman.service` 黑匣子（体征20秒落盘）。根治=内核 BPMP thermal + DT 极性，与音频 DTS 同车入下次构建。DC口接触问题只影响充电电流，与死机无关。
22. **出厂相机节点 shim 顶替的判决**：librealsense 2.55.1 编好后，`librealsense2.so.2.48→2.55.1` 符号链接能让 2.48 时代的 realsense2_camera_node 启动并开流，但**帧零投递（节点CPU 0%）且启用 IMU 秒死**——C++ 内联 ABI 裂缝，回调链断在节点内部。正解=对 2.55.1 头文件源码重编包装器。原始库 API 五模式全胜（rs_poc），硬件与新库无罪。
23. **Foxy 工具链三坑**：`ros2 topic hz` 无 QoS 适配测不了 BEST_EFFORT 话题（用 rclpy 显式 BEST_EFFORT 订阅计数）；`ros2 topic list` 走 daemon 缓存会展示已死节点的**幽灵话题**（先 pgrep 确认节点活着）；chroot 内 ros2 CLI 满载 CPU 下启动要 10 秒级超时余量。
24. **pkill -f 自杀第二式**：就算用了 `[x]` 括号诀，若同一条 ssh 脚本里既有明文目标字符串（如启动命令）又有 pkill，pkill 仍会匹配**父 shell 的命令行**把自己会话+被 nohup 的目标一锅端。杀进程放独立的 ssh 调用里，模式用括号断字。
25. **Mac 侧长时值守必须 `caffeinate -i` 包裹**，否则 Mac 睡眠让监控断片数小时（0723 下午 13:40-15:54 盲区事故）。狗无外网：给它编译要预喂依赖（nlohmann json 改本地 URL 的先例），chroot DNS 修法=往 p1 磁盘上的 /run/resolvconf/resolv.conf 写真实 nameserver（原生启动时被 tmpfs 遮住，零副作用）。

26. **🔑 r32 cboot + r35 内核混血的特征病：运行时悬空 phandle**（0724 内核法证，一晚中两发）：出厂 bootloader 在启动时对 DT 做修剪（NX 熔断删 cluster3 CPU、删 aonclk 等），r35 内核对悬空引用零容忍 → 温区整区构建失败(-2)、clocks-init/声卡永久 defer。**法证三板斧：`/sys/kernel/debug/devices_deferred`（欠账名单）→ function_graph ftrace 对 probe 函数（`set_graph_function`+手动 bind）→ 反编译 DTB 对照活树查悬空引用。**修法=DTS 层删除/裁剪引用死人的属性（map3、clocks 表项）。
27. **athena_defconfig 两个音频缺口**：无 ADSP（→DTS 禁 adsp_audio 跳 40 条链即可，卸载/AEC 不需要）；无 CONFIG_TEGRA210_ADMA（→admaif open ENODEV "dmaengine request slave channel failed"；单模块可热补：容器 modules_prepare+目标 .ko，vermagic 对上即插）。声卡注册≠出声：R2 待解（RT5680 TDM 上电默认不足 → EIO 无数据，JP4 codec_reg 快照回放是正路）。
28. **grep/管道吞错三连坑**：`cmd | head || echo 失败` 永不触发（head 吃掉退出码）；`grep -A2 xxx` 无匹配时 exit 1 会带崩 `set -e` 脚本；zsh 里 `echo ===` 触发等号展开报错。写诊断脚本时错误路径要显式 `; echo rc=$?`。

## 三、诊断方法论（这两天最值钱的部分）

13. **日志字符串 ≠ 故障**。读到源码确定语义前，不要让一条日志定性任何问题（"Odom offline" 误导了整整两个会话）。
14. **tcpdump 看得见 ≠ socket 收得到**，中间还有桥投递、IGMP、路由、per-socket 加组、进程内分发五层。分层取证三板斧：tcpdump（线上有没有）→ python 裸 socket（内核给不给新 socket）→ strace（目标进程到底收没收）。
15. **机主的物理观察是一等公民证据**：风扇声停 → 发现充电锁运动；灯没灭 → 发现假关机；"插了一天没充进"→ 锁定接触不良。远程数据要和现场观察互相校准。
16. **别在无人看守时发运动指令**（checkout MANUAL 会自动起立）。物理动作类命令必须机主在场。
17. **pkill -f 会匹配自己的命令行自杀**（ssh 会话被自己杀掉）。用 `[x]` 正则技巧（如 `pkill -f "[l]c_bringup"`）。
18. **误判要显式撤销**：本战役误判过"换回了旧电池"、"看门狗造成重启循环"、"涓流充电假说"——每次都在文档里明确标注推翻，防止后续会话继承错误结论。

## 四、当前遗留与后续菜单

- **充电口物理修复**（分级）：L0=插头找对位置+胶带固定+每次 checkcharge 确认（现行）；L1=检查母座簧片是否外扩（镊子回弯）、触点酒精清洁；L2=换 DC 母座（焊接）或换适配器。
- **旧电池 #1 拯救**：接触良好时装狗上开机充电即可（大概率同样健康）。
- **相机下一步**：chroot 内编译 librealsense 2.50+（V4L2 后端）→ 出厂 realsense 节点复活 → ov_msckf 改回立体（撤销单目 hack）→ 导航链路。
- **gps_switch 还没开**；MCU 传感器（超声/TOF/光流）按黄金 GPIO 清单逐个点亮；音频 tegra186-ape DTS；长期 Humble 原生化。

29. **0724 统一内核部署战（含两桩乌龙的教训）**：①部署脚本里 `cp x y || mkdir y` 的写法=目录不存在时只建目录不重试复制——8821cu.ko 没上车导致新内核首启无 Wi-Fi 假失踪（正解=mkdir 在前、cp 在后、验证在最后；8821cu 装在 /lib/modules/<ver>/extra/ 不在 kernel/ 树里）。②Mac 侧长等待哨兵两次忘包 caffeinate 断片数小时——**凡 run_in_background 的等待循环必须 caffeinate -i 包裹，无例外**。③笔记本 x86 的 xHCI 控制器会整体猝死（内置摄像头/蓝牙/wwan/狗口全消失），远程复活=逐个 unbind/bind /sys/bus/pci/drivers/xhci_hcd 下的控制器（内置设备多在 0000:00:14.0）。
30. **音频无声排查全图谱（0724 实战总结）**：声卡注册→能开流→有数据→能出声是四道独立关卡。①FE RUNNING 但 BE i2s clk enable=0 = codec DAPM 控件没开（**金标准=JP4 的 /var/lib/alsa/asound.state 按名回放**，alsactl 按 numid 会失败）；②寄存器层拿 JP4 的 regmap debugfs 快照回放（753 个,跳 0x0000）；③功放静默查 fault 寄存器（TAS5805M 0x71=0x04 是 CLK 故障，清障写 0x78=0x80），根因=16k 流被 BE 3 倍速抽干提前停钟（48k 立体声原生稳）；④终极验收=自听自证（ADMAIF 分流录自己的播放，Goertzel 找频点）。athena_audio 会占 ADMAIF1/2，调试走 3/4。
