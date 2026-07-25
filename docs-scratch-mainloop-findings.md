# 主控自查发现（与工作流并行，0725）

## ✅ 已修复
1. **CPU 少两核 + 功耗预算少 1/3（移植回归）**
   - 现象：nproc=4，负载 5.29，cpufreq 长期顶满 1907MHz
   - 误判排除：6 核**全部启动成功**（`smp: Brought up 1 node, 6 CPUs`），不是 cboot 删核
   - 真因：nvpmodel 停在 `MODE_10W_DESKTOP`(pmode 5)，把 cpu4/5 下线
   - 金标准：JP4 `/mnt/jp4/var/lib/nvpmodel/status` = `pmode:0002 fmode:quiet` = **MODE_15W_6CORE**
   - 修复：`nvpmodel -m 2`，已持久化到 /var/lib/nvpmodel/status
   - 实测：15 分钟热监控峰值 **69°C，与切换前完全一致（散热零代价）**；频率 1907→1420MHz（6核封顶），总吞吐 6×1.42 > 4×1.9
   - 回归：RCE cmd=5 ✓ 传感器 3 ✓ video 9 ✓ 声卡 2 ✓ wlan ✓ 模块失败 0 ✓ 无内核崩溃 ✓ nvgpu 引用 18 ✓

## ✅ 已确认（重要安全网）
2. **内核原生热保护完整活着**（此前不知道）
   - 6 个温区全注册：CPU/GPU/AUX/AO-therm、PMIC-Die、thermal_fan_est
   - 冷却设备：`thermal-cpufreq-0`(24级降频)、`thermal-devfreq-0`(14级)、`bwmgr-therm-handler`、pwm-fan×2
   - CPU-therm 跳变点：被动降频 **90.5°C**、临界 **96°C**（早于硬件 thermtrip ~103°C）
   - 结论：提功耗不会再重演"静默烧到硬件断电"

3. **串口救援通道实测可用**（"零人工干预"最高约束的真正兜底）
   - 笔记本 `/dev/ttyACM0` 打回 `cyberdog-jp5 login:`
   - 意味着新内核起不来时可通过串口在 cboot extlinux 菜单远程选回上一个内核
   - USB 网络 192.168.55.100↔192.168.55.1 通（1.8ms）；USB ID 0955:7020 = L4T 正常模式
   - 笔记本余量 28G（80% 已用），cyberdog-flash 占 374M

4. **真引导配置确认**：eMMC `/dev/mmcblk0p1`（挂 /mnt/emmc）→ `/boot/extlinux/extlinux.conf`
   - `LABEL jp5` → `/boot-jp5/{Image, tegra194-mi-k91.dtb, initrd}`
   - 另有 `LABEL rescue`（RAM 盘 + JP4 内核，不挂 NVMe）
   - 当前部署件：Image `c13cfaf9…` / DTB `8da03287…`（= nvmap-handle-fd 那套，含 diag@5）
   - 回滚链完整：Image.prev-{handlefd,legacy,nvmap,unified} + DTB.prev-{chsetup,handlefd,legacy,nvmap,unified}

## 🔴 新发现待办
5. **fanboy 保命动作对机器人负载完全无效**
   - `if [ $c -ge 92 ]; then pkill -x cc1plus; pkill -x make; fi` —— 编译专用
   - ROS2 负载热失控时这行代码什么都不做
   - 真正救命的是内核降频（已确认工作），但兜底应改成通用的（降 nvpmodel / 冻结非关键节点）
   - 另：风扇曲线只有 4 档且 ≥70°C 就满速，之后无余量

6. **ramoops（内核崩溃黑匣子）probe 失败**
   - `ramoops reserved-memory:ramoops_carveout: failed to locate DT /reserved-memory resource` → `-22`
   - DTB 缺 ramoops 保留内存 carveout
   - 价值：我们在部署带核心内存管理手术的实验内核，ramoops 能把内核 panic 跨重启保存下来
   - 现有 deadman 黑匣子是用户态的，抓不到内核 panic
   - 修法：DTS 加 reserved-memory ramoops 节点（低风险）

7. **swap 完全没有**
   - `mmcblk0p13` 有 12G swap 分区但 `swapon --show` 为空、`free` 显示 Swap: 0
   - 且 `nvzramconfig.service` failed（zram 也没起）
   - 内存目前够用（7.7G/6.7G 可用），但 12G 分区白放

8. **pulseaudio 70% CPU × 3 实例**（交给 D2 审计）

9. **系统时钟停在 2000-01-01**，NTP active 但 `System clock synchronized: no`（交给 D2 审计）
   - 副作用：日志时间戳错乱（同一次引导里出现 Jun 17 / Jul 23 / Jan 01），严重妨碍调试
