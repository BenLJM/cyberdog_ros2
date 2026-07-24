# CyberDog JP4→JP5 音频子系统 DTS 移植方案

日期：2026-07-23 ／ 目标内核：L4T r35.6.4 / 5.10.216（athena_defconfig）
真理来源：`audio-port/dtb-live.dts`（JP4 实机 DT 转储）+ `audio-port/mi-k91-audio.dtsi`（Xiaomi 4.9 源码）+ 4.9 机器驱动（`build/mirror/athena_l4t_nvidia.git` 的 `tegra-alt/machine_drivers/tegra_machine_driver.c`）

**状态：草案 `jp5-audio-draft.dtsi` 已通过树内 `make dtbs` 编译验证**（产物 `jp5-audio-draft-verify.dtb`，317KB，全部合并点已反编译核对）。

---

## 1. 硬件拓扑结论（来自 JP4 live DT，权威）

```
                     Jetson Xavier NX (t194 APE/AHUB)
                    ┌───────────────────────────────┐
  8×PDM 麦克风阵列   │  I2S3 ── dsp_a(TDM) 6ch×16bit  │
 (DMIC L1/R1..L4/R4)│        @16kHz, Tegra 为主      │
        │           │  fsync-width=15 (JP4 值)       │
   ┌────▼─────┐     │                               │
   │ RT5680   │◄────┤ BCLK/FSYNC/DATA (无 MCLK 依赖) │
   │(ALC5680) │     │                               │
   │ i2c 0x2d │     │  I2S5 ── i2s 1ch×16bit @16kHz  │
   └──────────┘     │        Tegra 为主              │
   ┌──────────┐     │                               │
   │ TAS5805M │◄────┘                               
   │ 单声道功放│      i2c 总线：gen1_i2c (i2c@3160000)
   │ i2c 0x2c │
   └────┬─────┘
      喇叭
```

| 元件 | 型号 | 总线/地址 | DAI 链接 | 格式 | 参数 |
|---|---|---|---|---|---|
| 采音 codec | Realtek RT5680 (ALC5680，带内置 DSP) | gen1_i2c @0x2d | JP4 dai-link-3，cpu=**I2S3** | dsp_a (TDM) | 16kHz / 6ch / s16_le / fsync-width 15 / name-prefix "h1" |
| 功放 | TI TAS5805M | gen1_i2c @0x2c | JP4 dai-link-5，cpu=**I2S5** | i2s | 16kHz / 1ch / s16_le / name-prefix "x" |

**麦克风阵列**：8 颗 PDM 麦全部挂在 RT5680 的 4 组 DMIC 输入上（codec DAPM 输入 "DMIC L1/R1..L4/R4"），**不经过** Tegra 的 DMIC 控制器。routing `"h1 DMIC Lx/Rx" ← "h1 Int DMIC"`。JP4 里其余 x/y/z/m/n/o/a/b/c/d/d1/d2 路由对全是 dummy spdif-dit 占位，不必移植。

**GPIO（两颗 TCA6424 expander，同在 gen1_i2c）**：

| 线 | expander/引脚 | 功能 | 使用者 |
|---|---|---|---|
| SND_CODEC_1V8_EN | gpio_expand2(0x22) pin 19 | RT5680 AVDD 1V8 | rt5680 驱动 `codec-1v8-enable-gpio`（probe 拉高） |
| SND_PA_1V8_EN | gpio_expand2(0x22) pin 18 | codec/功放共用 DVDD 1V8 | rt5680 `codec-pa-1v8-enable-gpio` + tas5805m `pa-1v8-enable-gpio`（两驱动都拉高，JP4 亦如此） |
| SND_PA_PDN | gpio_expand1(0x23) pin 7 | TAS5805M PDN（高=工作） | tas5805m 驱动 `pdn-enable-gpio` |
| RESET_CODEC / LDO1_EN_CODEC | gpio_expand1 pin 5/6 | 板上预留 | JP4 DT **未引用**，驱动也不碰，维持不动 |

**时钟**：两颗 codec 都不吃 AUD_MCLK（RT5680 从 BCLK 内部锁相；TAS5805M 从 BCLK 自动锁）。DAP 引脚 pinmux 由 MB1 BCT 配好（JP4 内核 DT 里没有任何 DAP pinmux 条目），我们双启动方案沿用原 bootloader 链 → pinmux 无需动。卡级 pll_a/pll_a_out0/extern1 时钟走 JP5 `tegra194-audio-p3668.dtsi` 原样。

**耳机检测**：无（机器狗没有耳机口）。

---

## 2. JP5 (5.10) 基线与 4.9→5.10 映射

r35.6.4 里 Xavier NX 音频有两套卡：

1. **`tegra_sound`，compatible `nvidia,tegra186-ape`** —— r35 默认卡，`kernel-5.10/sound/soc/tegra/tegra_machine_driver.c` + `tegra_asoc_machine.c`，结构化 `nvidia-audio-card,dai-link@N`（cpu/codec 子节点 + `sound-dai` phandle）。devkit 出货即用它。**本方案主目标。**
2. `tegra_sound_graph`，compatible `nvidia,tegra186-audio-graph-card` —— 上游式 OF-graph 卡，r35 里默认 **disabled**。草案已把 codec 的 port/endpoint 接好（惰性），未来一行 status 即可切换。

> 前一阶段占位文件（树内 `jakku/kernel-dts/tegra194-mi-k91-audio.dtsi`）的结论仍然成立：r32 的 tegra-alt 机器驱动在 5.10 编译不过，不能走老路。

### 节点映射表

| JP4 (4.9 tegra-alt) | JP5 (5.10 r35) | 说明 |
|---|---|---|
| `tegra_sound` compatible `nvidia,tegra-audio-t186ref-mobile-rt565x` | `&tegra_sound` compatible `nvidia,tegra186-ape` | 机器驱动整个换代 |
| `nvidia,model = "jetson-xaviernx-ape"` | `nvidia-audio-card,name = "jetson-xaviernx-ape"` | 草案保留 JP4 卡名，JP4 的 alsactl state/脚本可平移 |
| `nvidia,dai-link-3 { cpu-dai=<&tegra_i2s3> ... }` | `&i2s3_to_codec`（=`nvidia-audio-card,dai-link@78`）覆写 | cpu 侧已由基线给好 `<&tegra_i2s3 I2S_DAP>` |
| `nvidia,dai-link-5 { cpu-dai=<&tegra_i2s5> ... }` | `&i2s5_to_codec`（=`dai-link@80`）覆写 | 同上 |
| `codec-dai = <&rt5680>; codec-dai-name="rt5680-aif1"` | `codec { sound-dai = <&rt5680>; }` + codec 节点 `#sound-dai-cells=<0>` | 5.10 不再用 dai-name 字符串，单 DAI 组件自动解析 |
| `format = "dsp_a"` | 同名 `format` 属性 | `snd_soc_of_parse_daifmt` 解析 |
| 主从：4.9 默认 Tegra 主 | **链接上不写** `bitclock-master`/`frame-master` = Tegra 主 | r35 语义（与主线相反方向）：写了这俩属性反而是 codec 做主；已对照 `tegra210_i2s_set_fmt`（CBM_CFM→MASTER_EN）与 galen rt5658 参考确认 |
| `srate`/`num-channel`/`bit-format` | 同名属性（C2C link 参数） | 允许范围 8k-192k/1-16ch，16k/6ch/1ch/s16_le 均合法 |
| `fsync-width = <15>`（dai-link 属性） | **无 DT 等价物**。运行时 mixer：`amixer -c jetsonxaviernxape cset name='I2S3 FSYNC Width' 15` | 5.10 驱动默认 0（1 BCLK 宽）；soc dtsi 里残留的 `fsync-width` 属性 5.10 驱动不读 |
| `name-prefix = "h1"/"x"` | 链接 codec 子节点 `prefix = "h1"/"x"` | 卡级 codec_conf |
| `nvidia,audio-routing` 卡属性 | `nvidia-audio-card,widgets` + `nvidia-audio-card,routing` | 只保留 h1/x 有效对（见草案） |
| `nvidia,num-codec-link`/`nvidia,xbar` | 不需要 | 新驱动按子节点自枚举 |
| 13 颗 dummy `spdif-dit` codec | 不需要 | 基线 I2S_DUMMY DAI 承担 |

### codec 驱动现状（重要：已就绪）

- `kernel-5.10/sound/soc/codecs/rt5680.c` / `tas5805m.c` **已完成 component API 移植**并接进 Kconfig/Makefile；`athena_defconfig` 里 `CONFIG_SND_SOC_RT5680=m`、`CONFIG_SND_SOC_TAS5805M=m`。无需再移植驱动。
- 两驱动 DT 需求与 4.9 完全一致：rt5680 缺 `codec-1v8-enable-gpio`/`codec-pa-1v8-enable-gpio` 会 **probe -EIO**；tas5805m 同理需要 `pdn-enable-gpio`/`pa-1v8-enable-gpio`。compatible 分别是 `realtek,rt5680`、`ti,tas5805m`。
- DAI 名不变："rt5680-aif1"、"tas5805m-amplifier"（新卡用不上，列此备查）。
- TDM 澄清：4.9 机器驱动只对 **CPU DAI**（Tegra I2S）调 `set_tdm_slot`，**从未**调过 rt5680 的——codec 侧 TDM/DSP 配置向来是 Xiaomi 用户态（codec_reg sysfs / 服务）或 codec 缺省完成的。所以 5.10 内核侧无需为 TDM 补 machine 代码，行为与 JP4 对等。

### 板级现状（zbwu r35 树，`common/tegra194-p2151-0000.dtsi`）

- 已含 `gpio_expand1/2`、`tas5805m@2c`/`rt5680@2d` 骨架（**disabled**，且 rt5680 的 compatible 误写为 `realtek,rt5679`，供电走 regulator 风格）。
- 其正文在 include `tegra194-audio-p3668.dtsi` 之后 **强制 disable 了 `aconnect@2a41000` 和 `tegra_sound`** —— 这是当前 JP5 音频全灭的直接原因之一；AHUB/ADMAIF/I2S 子节点的 okay（来自 `tegra-platforms-audio-enable.dtsi`）都被父节点闸住。
- 定义了三颗音频 fixed-regulator（`dvdd_codec_amp_1v8`→exp2/18、`avdd_codec_1v8`→exp2/19、`pvdd_amp_12v`→exp1/7），**与 codec 驱动要抢同三根 expander 线**；且因 ported 驱动不 regulator_get，开机 ~30s 后 `regulator_late_cleanup` 会把三根线全拉低（codec 断电、功放进 PDN）。草案将其全部 disable，GPIO 所有权交还 codec 驱动（=JP4 行为）。

---

## 3. 草案文件与接入方法

草案：`/Users/ben/projects/cyberdog/build/audio-port/jp5-audio-draft.dtsi`
内容五段：① 重新打开 `aconnect`；② `&tegra_sound` 卡属性/widgets/routing；③ `&i2s3_to_codec`、`&i2s5_to_codec` 链接覆写；④ `&rt5680`、`&tas5805m` codec 节点补全（含 OF-graph 端点，惰性）；⑤ 三颗音频 regulator disable。

**接入（正式启用时做，本次未改树）**：把草案拷进
`hardware/nvidia/platform/t19x/jakku/kernel-dts/`（沿用文件名 `tegra194-mi-k91-audio.dtsi` 直接**整文件替换占位**即可，board dts 的 include 行都不用动）。
⚠️ 必须**替换**而不是并存：占位文件在 sound 节点下留下的 `nvidia,dai-link-1/2` 子节点会被 5.10 机器驱动的子节点遍历撞上（它不按名字过滤），因缺 `cpu` 子节点而 **probe 失败**。

## 4. 编译验证（已完成）

- 方法：草案临时接入板级 DTS → `cyberdog-kbuild` 容器内 `make O=/tmp/kb2 athena_defconfig dtbs`（容器本地路径，未碰 `build/out/kbuild` 既有产物）→ 编译通过 → 反编译核对 → 树恢复原状。
- 证据：`audio-port/jp5-audio-draft-verify.dtb`。已核对项：
  - sound 节点：okay / tegra186-ape / 卡名 / widgets / routing 全对；无残留 tegra-alt 子节点。
  - `dai-link@78`：dsp_a / 16000 / 6ch / s16_le / codec→rt5680 / prefix "h1"；cpu=`<&tegra_i2s3 I2S_DAP>`。
  - `dai-link@80`：i2s / 16000 / 1ch / s16_le / codec→tas5805m / prefix "x"；cpu=`<&tegra_i2s5 I2S_DAP>`。
  - rt5680@2d/tas5805m@2c：compatible、GPIO phandle（exp2=0x2b pin19/18、exp1=0x2a pin7）、`#sound-dai-cells`、port/endpoint、okay 全对。
  - `aconnect@2a41000` okay；三颗 regulator disabled。

## 5. 上机验证步骤（Phase 5.6 bring-up）

```bash
# 0) 启动后先看卡有没有起来
dmesg | grep -iE "tegra.*(ape|asoc|sound)|rt5680|tas5805"
cat /proc/asound/cards          # 期望出现 jetson-xaviernx-ape
aplay -l ; arecord -l           # ADMAIF1..20 PCM 设备

# 1) 复刻 JP4 的 fsync 宽度（TDM 链路）
amixer -c jetsonxaviernxape cset name='I2S3 FSYNC Width' 15

# 2) XBAR 路由（新卡不会自动连 ADMAIF↔I2S，要用 amixer 摆交叉开关）
amixer -c jetsonxaviernxape cset name='I2S5 Mux' ADMAIF1      # 播放: ADMAIF1→I2S5
amixer -c jetsonxaviernxape cset name='ADMAIF2 Mux' I2S3      # 录音: I2S3→ADMAIF2

# 3) 播放冒烟（喇叭）
speaker-test -D hw:jetsonxaviernxape,0 -c 1 -r 16000 -F S16_LE -t sine -f 440 -l 2
# 或 aplay -D hw:jetsonxaviernxape,0 -r 16000 -f S16_LE -c 1 test16k.wav
# 无声排查顺序: amixer 里 x 前缀控件(功放音量/mute) → expander 线电平
#   (gpioinfo | grep -iE "SND|PDN") → i2cdump 0x2c 看 TAS5805 是否退出 PDN

# 4) 录音冒烟（6ch TDM 麦阵）
arecord -D hw:jetsonxaviernxape,1 -r 16000 -f S16_LE -c 6 -d 5 mic6.wav
# 逐通道看波形/能量: sox mic6.wav -n remix 1 stats 等
# 若 6ch 全静音: 检查 h1 前缀控件(ADC/DMIC 开关与音量)；
# 若只有 2ch 有数据: RT5680 未进 TDM 模式 → 见风险 R2

# 5) 复刻 JP4 codec 配置（一次性，拿到后固化进 alsactl state 或启动脚本）
# 在 JP4 系统: cat /sys/bus/i2c/devices/1-002d/codec_reg > jp4-rt5680-regs.txt
# 对照默认表 diff 出 Xiaomi 用户态写过的寄存器，在 JP5 用同一 sysfs 回放
```

通过标准：`speaker-test` 喇叭出 440Hz 正弦；`arecord` 6 通道都有能量且对拍手声同步响应。

## 6. 风险清单

| # | 风险 | 概率/影响 | 缓解 |
|---|---|---|---|
| R1 | **fsync 宽度**：5.10 默认 0（1 BCLK），JP4 用 15；RT5680 对 FSYNC 宽度若敏感则 TDM 采不到 | 中/高 | 上机第一步 amixer 设 15（§5.1）；确认后可加小补丁把默认值写进 i2s 驱动或开机脚本固化 |
| R2 | **RT5680 TDM 6ch 模式**：内核从不写 TDM1_CTRL1（4.9 也不写），6ch 依赖 codec 上电缺省或 Xiaomi 用户态初始化 | 中/高 | 若只出 2ch：按 §5.5 从 JP4 dump codec_reg 回放；终极手段=driver probe 里补 `TDM1_CTRL1 |= 0x8A00`（TDM_MODE|6CH in/out, 16bit）小补丁 |
| R3 | **RT5680 内置 DSP/固件**：JP4 上唤醒词/波束成形若跑在 codec DSP（is_dsp_mode sysfs），其固件加载属 Xiaomi 用户态，内核 DTS 管不到 | 高(功能)/低(透传) | 本阶段目标=6ch PCM 透传可用；DSP 功能等 Mi 服务栈迁移时另行处理 |
| R4 | **ADSP 固件依赖**：卡包含 ADSP FE 链接（adsp_pcm/compr），`adsp@2993000` okay；若 rootfs 缺 adsp*.elf，整卡 probe 挂起 | 低 | 标准 L4T r35 rootfs 自带；若真缺：dmesg 会卡 "adsp"，届时在 dtsi 加 adsp disable + 相应链接 disable |
| R5 | **共享 1V8（exp2/18）时序**：rt5680 与 tas5805m 驱动都拉这根线，模块加载先后会互相"抢"（都拉高，方向一致，JP4 同样如此） | 低 | 无需处理；若见 gpio busy 告警属 legacy API 双驱同线的正常噪音 |
| R6 | **regulator 被我们禁用**：若后续有人把驱动改成 regulator 风格（zbwu 的原意），要同步删 GPIO 属性并撤销 §草案第 5 段 | 说明性 | 计划内的"干净终态"方向，不影响本阶段 |
| R7 | **1ch I2S5 播放**：JP4 就是 1ch，理论 5.10 hw 支持 1-16ch；若 mono 撞驱动约束 | 低 | 链接 num-channel 改 2 + "I2S5 Codec Channels"/Mono 控件兜底 |
| R8 | **DAP pinmux**：完全依赖原 MB1 BCT（JP4 内核 DT 无 DAP 条目，我们沿用原 bootloader）；若哪天换 JP5 原生刷机链，pinmux 要补 | 低(现架构) | 死寂时用 `/sys/kernel/debug/pinctrl` 或 devmem 查 DAP3/DAP5 pad |
| R9 | **卡名/控件名变化**：ALSA 控件从 JP4 的 "x/h1 ..."（tegra-alt 命名）变为 r35 命名（"I2S3 ..." 等 XBAR 控件是新的）；老脚本里 numid 全部失效 | 必然/低 | 卡名已保留；bring-up 后重新 `alsactl store` 生成 JP5 版 state |

## 7. 后续（非本阶段）

- 起机验证后：把最终 dtsi 以正式补丁形式落入 `build/patches/kernel`（新 patch 文件，编号顺延，不动既有 0001-0005）。
- audio-graph 切换（可选）：`&tegra_sound { status="disabled" }` + `&tegra_sound_graph { status="okay" }`——端点已在草案中接好；需上机回归。
- Xiaomi 音频服务（xiaoai/ROS 音频节点）在 JP5 chroot 栈下的 codec 初始化路径梳理（R2/R3 的正解）。
