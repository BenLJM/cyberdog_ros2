# CyberDog JetPack 5 升级 — 全面复盘（2026-07-19）

> 复盘方法：6 个维度并行审查（计划合理性 / 执行对账 / 妥协点审计 / 仓库一致性 / Phase 4 安全 / 外部事实核查），共 42 个审查与核实智能体；每条 high/medium 发现都经过独立的对抗性核实。结果：**43 条确认、11 条部分成立（已修正）、0 条被推翻**。所有审查均为只读，未改动任何文件。

---

## 一、总体判断

**路线正确，执行质量高，不需要推倒重来。**

- 架构（NVMe 双 rootfs + eMMC APP p1 作 extlinux 支点 + 双 LABEL 翻 DEFAULT + 常驻 rescue + initrd 自动回退钩子）每一环都有 Phase 0.5/2 的实测背书，QSPI/eMMC/NVMe 分工建模正确，宏观阶段顺序合理。
- Phase 0–3 的执行有完整验证门记录，Phase 3 产物尺寸、补丁计数、分区几何在文档、MANIFEST、狗上活体三方全部对得上；时间线经文件 mtime 交叉验证真实自洽。
- 妥协追踪纪律总体好：8 项推迟/替代全部有据可查。

**真正的问题集中在三处：**

1. **Phase 2 用血换来的两条 cboot 实测教训没有传导进 Phase 4 计划**——尤其是 7.2 MB ramdisk 静默替换红线，直接威胁自动回退安全网。
2. **交付物与文档失同步**——HANDOFF 自相矛盾、REPRODUCE.md 复现指令缺 5 个补丁、LOCALVERSION 修复没落进构建脚本。
3. **一批"无声丢弃"的计划项**——BT 路径、MCU 捕获、走路测试、Track S 等从所有追踪清单里消失。

另外外部核查修正了一个方向性判断：**Phase 5.6 音频重写应对准 `tegra186-ape`（r35 官方定制路径），而不是 audio-graph**（r35/t194 上出厂禁用、文档薄、少有人走）。

---

## 二、5 个 HIGH 级发现（全部确认）

### H1. cboot 7.2 MB ramdisk 红线未传导，自动回退安全网可能"静默消失"
Phase 2 实测（PHASE2_RUNBOOK §3b/§7）：cboot ramdisk 缓冲装不下 13 MB initrd，**超限时静默改载 stock /boot/initrd 且不报错**，proven-safe 包络 = 7,236,790 B（打包后）。这条红线在主计划 §11/§12、PHASE3_BUILD_RESULTS、HANDOFF、tools/phase3/ 中 **grep 零命中**。危险组合：JP5 initramfs 还没组装（妥协 #7），而防变砖钩子就住在这个 initrd 里——最自然的做法（直接用 apply_binaries 的 r35 标准 initrd，约 10 MB+）会超限，cboot 静默换回 JP4 老 initrd，钩子无声消失。主计划 L153/L291 还保留着已被实测推翻的断言 "INITRD-from-file works"。
**修法**：initrd 做成 rescue stage-1 式的 busybox 壳（关键驱动已全部 =y、全内核仅 38 个模块，<2 MB 可行），构建+上膛双重 size gate < 7,236,790 B；红线写进 §12。

### H2. r35 rootfs 自带 bootloader 自动升级机制 = 全项目唯一软件变砖向量，计划零提及
apply_binaries 会装 `nvidia-l4t-bootloader`（nv-l4t-bootloader-config.service / nv_update_engine，开机自动刷 bootloader）。狗的引导链是小米定制 r32.5 cboot 住在 QSPI NOR（计划自己标注 "THE brick-relevant flash"），rootfs 是 rsync 上去的、/etc/nv_boot_control.conf 缺失或错误。后续任何一次 `apt upgrade nvidia-l4t-bootloader`（镜像了 r35.6 apt 仓 + Phase 4 有换源动作）都可能在下次开机触发 BUP 写入 QSPI。
**修法**：首启前在 p2 rootfs 内 `systemctl mask nv-l4t-bootloader-config.service`、`apt-mark hold nvidia-l4t-bootloader nvidia-l4t-initrd nvidia-l4t-xusb-firmware`，检查 `.nv-l4t-disable-boot-fw-update-in-preinstall` 标志；"JP5 侧永不允许写 mtdblock0/eMMC boot 分区"写进 §7 风险表。chroot 检查即可，成本极低。

### H3. REPRODUCE.md 的 kernel/nvidia 补丁指令不完整——照文档复现会丢相机和树内 Wi-Fi 驱动
实际构建树 kernel/nvidia 有 6 个提交（5 个 zbwu：rtl8821cu 5.10 修复、ov7251/ov13b10 相机驱动等，+3028 行；1 个 tegra-alt stub），但 `cyberdog-deltas/nvidia/` 只放了 1 个，而 REPRODUCE.md 明文说 "cyberdog-deltas 是你实际要 apply 的全部"。照文档在新机器复现：nv_ov7251.ko / nv_ov13b10.ko 不会产出，过不了它自己第 64-65 行的验收门。好消息：diffstat 逐一比对证明 zbwu-patches/nvidia/0001-0005 在 r35.6.4 上干净套用、内容未丢——**只是文档指令错了**。
**修法**：改 REPRODUCE.md 第 3 步（先 am zbwu-patches/nvidia/0001-0005 再 am cyberdog-deltas/nvidia/0001），或从构建树 format-patch 导全 6 个补丁统一语义；在狗上提交推送。

### H4. HANDOFF 说 LABEL jp5 "已带 LINUX/FDT/INITRD 行"是个陷阱——现存 stanza 是 proof 模式，root 指向 JP4 根分区
eMMC 上现存的 LABEL jp5 是 2026-07-11 stage-linux-fdt-proof.sh 铺的证明模式：LINUX/FDT 是 JP4 内核字节拷贝、INITRD 指向 stock JP4 initrd、`root=/dev/nvme0n1p1`、无 panic=15。新会话若据 HANDOFF ⑤ 只把新 Image/DTB 放进 /boot-jp5/ 就切 jp5，会得到 **5.10 内核 + JP4 initrd + rw 挂载 JP4 保底系统的根分区**——模块目录全错、systemd 半残地往 p1 上写，可能损坏唯一的回滚系统；而钩子探测的 p2 是好的，不会回退。
**修法**：Phase 4 的 extlinux 步骤写成"整段重写 LABEL jp5 stanza"（INITRD=/boot-jp5/initrd、root=p2、panic=15），随后**重新生成三个 \*-saved 副本**（钩子回退时复制的就是 jp4-saved）并 diff 校验；修正 HANDOFF ⑤ 措辞。

### H5. 存在多条"狗失联且自动回退不触发"的路径；兜底的 Path-B 硬件 RCM 从未有意验证
钩子只在 root 探测/挂载失败时回退。绕过它的首启失败类别：(a) initrd 超限被静默换掉→钩子不在场；(b) p2 挂载成功但随后 panic→panic=15 重启后探测再次通过→无限 panic 循环（钩子头部注释宣称的防 panic 循环能力**不成立**）；(c) 内核挂死不 panic；(d) 系统起来但 gadget 和 Wi-Fi 都没起。这些场景唯一出路是硬件进 RCM——而 PHASE0_RECOVERY_PROCEDURES §1 标注该触发 "NOT yet verified"。有趣的是 memory 记录过一次意外：插 USB 线冷上电狗进了 RCM/APX (0955:7e19)——这正是 Path B 大概率可用的证据，但没人把两件事联系起来。
**修法**：Phase 4 之夜第一件事、趁 JP4 shell 还在，做一次零风险 Path-B 演练（正常关机→插 USB→上电→x86 lsusb 找 0955:7e19→断电回 JP4）。给钩子加启动尝试计数（eMMC 上写 attempt 文件，N 次未见成功标记即回退），覆盖 (b)(c)(d)。

---

## 三、8 项妥协逐条裁定

| # | 妥协 | 裁定 | 说明 |
|---|------|------|------|
| 1 | LOCALVERSION 没设（5.10.216+） | **欠妥** | 修复只写进 REPRODUCE.md，**full-build.sh（两份副本逐字节一致）至今没改**——照脚本重跑会原样复现错误。狗上已暂存的整套产物都要重编重传。 |
| 2 | "内核 delta 已推成补丁序列" | **欠妥（只对 2/3）** | kernel-5.10 x8 ✅、jakku-dts x3 ✅，**nvidia 缺 zbwu 5 个补丁**（见 H3）。且仓库版 HANDOFF 第 2 条与它自己所在的 commit 6eb9704 自相矛盾（还在说"没推到任何远程"、"要重做音频转换"），会误导新会话白费数小时。 |
| 3 | Phase 2 手术手工收尾、重跑未彩排 | 可接受 | 一次性动作、终态已多重验证，重跑路径已无意义。 |
| 4 | 音频 tegra-alt 死路 → Phase 5.6 | 可接受，**但方向要改** | 推迟时机正确、四处留痕、PLACEHOLDER DTS 不构成 Phase 4 启动风险。但外部核查发现 audio-graph 并非 r35 标准（t194 上出厂 `status="disabled"`，NVIDIA 注释"未来才计划做默认"）；r35 官方定制路径是 **`nvidia,tegra186-ape` + nvidia-audio-card,\* 属性**，有文档有论坛先例。graph 卡的 tegra_codecs.c 对 codec 有硬编码特判，自定义链路可能还要改 C 代码。Phase 5.6 应对准 APE 形式，graph 只作备选。 |
| 5 | motor SDK 链接检查推迟 Phase 5 | 可接受 | 内核侧 CAN 配置无洞，推迟的只是与内核无关的用户态检查。 |
| 6 | 两个 Wi-Fi 驱动 | 可接受 | 狗上暂存的正是计划首选的 morrownr 版（已确认支持 5.10/arm64）。建议借 LOCALVERSION 重编机会直接在 defconfig 关掉树内 rtl8821cu，彻底去重。 |
| 7 | JP5 initramfs 未组装 | **欠妥** | 计划 §11 把 initrd 列为 **Phase 3 交付物**却没交付，§11 完成注记和 §12 子任务清单都没记这笔账，只有交接文档记了。叠加 H1 的尺寸红线，这是 Phase 4 最大的未完成安全件。 |
| 8 | BMI160 未验证、PREEMPT_RT 跳过 | 可接受 | 配置已双保险、推迟点正确。 |

**未列入清单的妥协（新发现）：**
- **full-build.sh 无 `set -o pipefail`、吞错误**：`make | tail -6` 管道退出码恒为 0，编译失败照样走到打包；`/work/out/final` 从不清理 + 增量复用 /tmp/kb 时 modules_install 对旧产物"成功"执行——**上次的旧产物会被当新品打包**。LOCALVERSION 强制重编马上就要跑这个脚本，属现行踩坑点。修法：`set -euo pipefail`、IMG_RC 非零即 exit、打包前 `rm -rf /work/out/final` 并断言 KREL=5.10.216-tegra（约 5 行，与 LOCALVERSION 同批提交）。
- **/data 只剩 2.7 G（87% 满）**：重编产物重传前先清掉旧的 /data/jp5-build-2026-07-19/。

---

## 四、执行对账：无声丢弃与记录缺口（medium 级）

1. **蓝牙整条路径被丢弃**（比想象的深）：§11 交付物 "rtl8821c BT firmware" 零落实；且实际内核**没开 mainline btusb/btrtl**，用的是 NVIDIA 树的 `rtk_btusb.ko`（CONFIG_RTK_BTUSB=m），它要的固件是 `/lib/firmware/` 下的裸文件 `rtl8821cu_fw` + `rtl8821cu_config`（可从狗的 JP4 侧拷出），**不是** linux-firmware 的 rtl_bt/rtl8821c_fw.bin。追加进 Phase 4 staging 清单。
2. **MCU 使能序列捕获**（计划写明 "Phase 2 之前在 JP4 侧完成"）：未执行、脱离所有追踪清单（只在 PHASE0_LAYER4_RUNBOOK L267 留着未勾选待办）。注意 start-capture.sh 目前只捕 udev/dmesg/lsusb，**缺计划要求的 TCA6424 GPIO 状态读取**。R-domain (192.168.55.233) 初探其实 7 月 7 日已做过，欠的是深挖（按计划排 Phase 5 即可）。
3. **走路测试未做但 §7 打了 [x] "gate all green"**：runbook 自己括号承认 "Walk test still owner's to run"。若 Phase 4/5 之后才发现 JP4 侧走路异常，将无法区分是缩盘还是后续改动所致。应排在 Phase 4 前——和 MCU 捕获是同一晚的天然搭车（站立触发正是捕获时机）。
4. **Track S 从未启动**（Phase 1 交付物，§14 的 12–18 晚预算明文依赖它把移植工作离机消化）：不启动则 Phase 6 预算隐性膨胀回 ~20+ 晚。它纯软件、不需要狗和 x86 笔记本，是 Phase 4 硬件夜之间最好的并行工作。
5. **CONFIG_VL53L1X（TOF）核对项**：好消息——这是计划的错误假设。TOF 挂在 STM32 上、数据走 CAN（0x630/0x600），活体 DTB 无 vl53 节点，4.9/5.10 树里都没有这个符号。应在 §11 标 N/A 并记结论，Phase 5 验证 CAN 数据流即可。
6. **备份点名缺口**：手术夜 "备份可达" 硬前置在定稿 runbook 里至今未勾。Layer 3b（QSPI dump）其实已双副本验证（可撤回疑虑）；**真正的单点是 Layer 3 的 p01.img（eMMC APP p1 dump）——最后校验停留在 2026-04-25**。Phase 4 动 eMMC 前必须挂 SSD 实际 sha256 抽查。
7. **§4.3 双内核彩排无执行记录**：rescue 的 LINUX+FDT+INITRD 三行组合大概率已随 6+ 次启动自证（203bbef 提交信息），真正未验证的是 **jp5 label 本身**（/boot-jp5/ 路径、34 MB 大 Image、未组装的 initrd）。动手前先 dump 狗上 live 的 extlinux.conf 存档进 repo——repo 里至今没有手术后真实 extlinux 内容的任何存档。
8. **runbook §2 的 extlinux 蓝本已被 §3b 教训作废**：蓝本里 rescue 无 LINUX 行——照抄重写最终 extlinux 会**默默弄坏救援入口**，到最需要它的时刻才发现。更新蓝本 + Phase 4 改完先 boot-switch rescue 实测一次逃生舱，再切 jp5。
9. **MANIFEST 从未钉 commit 哈希**（§9/§19 规定的职责）：镜像其实有 SSD 副本（7 月 9/11 已验证，非单副本），残留风险是 7-11 新抓的 apt 快照+语音栈未复制、morrownr 构建 commit 无处记录。下次接 SSD 跑一次 replicate-to-ssd.sh 增量 + MANIFEST 补 pinned-commits 小节。
10. **HANDOFF 第 2 条自相矛盾**（见妥协 #2）；**LOCALVERSION 重编没排进 Phase 4 步骤序列**——狗上旧 5.10.216+ 产物随时可能被当真货上膛。

---

## 五、计划文本需要修的地方

- **§12 缺"安装完整模块集 + depmod"步骤**，且有撞车隐患：apply_binaries 会装原厂 5.10.216-tegra 模块，LOCALVERSION 重编后自编模块 KREL 同名——直接解包会得到两套 config 不同的混装目录。修法：先 `rm -rf` p2 的 /lib/modules/5.10.216-tegra，再解自编全集，chroot `depmod -a`。
- **§12 步骤 6/7 应对调**（计划自己的 review D6 白纸黑字要求彩排是真实首启前的门槛）。且彩排方法要改：钩子硬编码探测 p2、不读 cmdline，**bogus root= 法在 p2 装好 rootfs 后不会触发钩子**。正确做法：把首次武装启动排在 rsync rootfs **之前**——p2 是空文件系统，钩子的 /sbin/init 检查天然失败并回退，零配置改动同时验证"cboot 从文件载核 + initrd 真被加载 + DEFAULT 翻回 jp4"三件事。
- **两处 `apt install ros-humble-foxglove-bridge` 不成立**：packages.ros.org 的 focal dist 只有 Foxy/Galactic——focal 上没有任何 ros-humble-\* 二进制。foxglove_bridge、Nav2、slam_toolbox、realsense-ros 全部进源编工作区，Phase 7 的 ~8 晚估算需复核。另：NVIDIA Isaac apt 的 focal Humble deb 已于 2025-06-30 整体下架，二进制逃生门已不存在（源编路线本身成立，是 JP5 社区标准打法）。
- **首启观测规程缺失**：ttyTCU0 无外露焊盘，gadget console 最早从 initrd 起才可见——§12 "watch cboot → kernel load" 做不到。且"开机别插 USB"告诫与"盯 USB 串口台"表面矛盾。实测经验可调和且应写成规程：**热重启全程插线安全（Phase 2 整夜验证）；冷上电先上电、后插线**；gadget console 尽早搬进 initrd（复用 rescue 的 configfs 脚本）把盲区压缩到几秒。
- L153/L291 过时断言 "INITRD-from-file works" 需修正（见 H1）。
- 计划 §52 写 "Ubuntu 22.04 host"——r35.6.4 官方 host 矩阵是 x86_64 Ubuntu 18.04/20.04，22.04 不在其列。

---

## 六、优化机会

1. **（最大的白捡提速）Humble/Nav2 源编搬到 Mac colima arm64 容器离机做**：§14 没说在哪台机器编；8 GB Xavier NX 裸编 rclcpp/Fast-DDS/Nav2 极易 OOM、数个通宵量级。Phase 3 已验证的 Mac 原生 arm64 容器起一个 focal 镜像全速编，`/opt/ros/humble` 安装空间打包 rsync 到狗；CUDA 相关包再上狗编。若坚持狗上编：JP5 fstab 启用 eMMC p13 现成的 12.9 GB swap 分区 + colcon 限并发。
2. 无头狗不装 xubuntu 桌面；JP5 fstab 的 /data 加 nofail。
3. **rootfs 组装可去 x86 化**（arm64 原生 chroot 或 OTA apt 源直装 nvidia-l4t-\* deb），但救援 tegraflash 仍是 x86 二进制——**x86 笔记本作为保险不可省**。
4. 两件不可再生资产入库：`build/docker/Dockerfile`（cyberdog-kbuild 镜像配方，476 字节，REPRODUCE.md 引用了却没提交）；`dtb-live.dts`（260 KB 活体 JP4 DT 反编译，Phase 5.6 的 authoritative 对照——现有两份副本一份在"可丢的" build/ 里、一份在即将动手术的狗 p1 上，gzip 后入 git 推 GitHub）。
5. Mac clone 落后 origin 4 个提交：本地改动经逐字节 cmp 与 origin 头部完全一致，`git pull` 会被覆盖保护挡住——先收掉本地未跟踪/已改文件再拉即可，无内容风险。

---

## 七、外部事实核查结论

| 断言 | 结论 |
|------|------|
| JetPack 5.1.6 = L4T r35.6.4，内核 5.10.216 | ✅ 确认（含本地源码 Makefile 直接验证）|
| r35.6.4 是 JP5 最后版本；JP6/7 仅 Orin；JP5 2026 Q3 EOL | ✅ 确认，与计划 §43 一致（镜像意识正确）|
| morrownr 8821cu 支持 5.10 / arm64 | ✅ 确认（5.10–5.11 在 Realtek 支持区间，aarch64 在列）|
| ROS 2 Humble on focal | ⚠️ Tier 3 源码级（Tier 1 是 22.04）；源编路线成立，但 focal 无任何 Humble 二进制，Isaac focal 仓 2025-06-30 已下架 |
| audio-graph 是 r35 标准声卡 | ❌ **不成立**——标准是 tegra186-ape；graph 卡 t194 出厂 disabled（见妥协 #4）|
| "无 LINUX 行则 cboot 无视 INITRD" | 外部无官方文档，但本机两次实测自证——按"本机实测行为"对待即可 |
| apply_binaries 需 x86_64 host | ✅（官方 18.04/20.04；组装可绕，救援不可绕）|
| r35.6.x known issues 影响本机启动拓扑 | 基本不适用（全部针对 r35 UEFI 链，狗保留 r32.5 cboot）|

---

## 八、Phase 4 前行动清单（按优先级）

**A. 构建侧（Mac，可立即做）**
1. 修 full-build.sh：`LOCALVERSION=-tegra` + `set -euo pipefail` + IMG_RC 断言 + 清 out/final + KREL 断言；顺手 defconfig 关掉树内 rtl8821cu。重编、清狗上旧目录、重传。
2. 写 tools/phase4/build-jp5-initrd.sh：busybox 壳 + jp5-autorevert-hook + gadget console 尽早拉起，**构建+上膛双 size gate < 7,236,790 B**。
3. 修钩子：/init 先挂 devtmpfs/proc/sysfs；加启动尝试计数；mmcblk0p1 也加等待循环；修正头部注释的夸大宣称。

**B. 文档侧（狗上提交推送）**
4. REPRODUCE.md 补 nvidia 5 补丁指令（H3）；HANDOFF 第 2/5 条改正；runbook §2 蓝本 rescue 补 LINUX 行；计划 L153/L291/§11/§12 按上文修；dump 狗上 live extlinux.conf 存档入库；Dockerfile + dtb-live.dts.gz 入库。

**C. JP4 侧一晚（机主在场，Phase 4 前）**
5. 走路测试 + MCU 使能序列捕获（补 TCA6424 GPIO 读取）+ 从 JP4 拷出 rtl8821cu_fw/config BT 固件 + 接 SSD 做备份点名（重点 sha256 抽查 p01.img）+ replicate-to-ssd 增量。

**D. Phase 4 之夜规程（x86 笔记本在场）**
6. 开场零风险 Path-B RCM 演练（H5）→ rootfs 生成后 chroot 屏蔽 bootloader 更新（H2）→ 模块清理+解包+depmod → 整段重写 jp5 stanza + 重新生成 \*-saved 副本（H4）→ 先 boot-switch rescue 验证逃生舱 → **rsync rootfs 之前**用空 p2 做回退彩排 → 真实首启（热重启、全程插线）。

**E. 并行**
7. Track S（cyberdog_locomotion Galactic→Humble 模拟器移植）启动，填硬件夜之间的空档。
8. Phase 5.6 方向从 audio-graph 改为 tegra186-ape（文档同步修正）。
