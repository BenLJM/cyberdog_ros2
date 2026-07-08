# Phase 3 audio-port scoping — rt5680 + tas5805m, 4.9 → 5.10 (2026-07-08)

Bounds "new unknown #3" from the 2026-07-07 review (D5). Every fact below was
established against **local sources** (`~/cyberdog-mirror-2026-07/repos/`, the live
dog, and the Phase 0 forensics DT dump) — not documentation guesswork. Working
copies of the extracted sources: `~/cyberdog-scoping/`.

**Verdict: MEDIUM-LOW risk, ~7–12 evenings inside Phases 3+5.** This is a
well-trodden codec→component conversion plus a tegra-alt→audio-graph DT rewrite,
not research. No blocker candidates found.

## Facts established

1. **Live usage confirmed** (the dog, 2026-07-08):
   - `CONFIG_SND_SOC_RT5680=y`, `CONFIG_SND_SOC_TAS5805M=y` in `/proc/config.gz`.
   - Live DT machine driver: `nvidia,tegra-audio-t186ref-mobile-rt565x` (r32
     **tegra-alt** framework, Xiaomi reusing the rt565x machine driver).
   - DAI links: `rt5680-aif1` (link `rt5680-codec`) + `tas5805m-amplifier` (link
     `tas5805-codec`); codecs on `i2c@3160000` at 0x2d (rt5680) / 0x2c (tas5805m).
   - `tegra194-mi-k91-audio.dtsi` (91 lines) enables `tegra_axbar`, `tegra_i2s5`,
     `tegra_sound` with a large multi-port `nvidia,audio-routing` table.

2. **Both 4.9 drivers use the REMOVED legacy codec API** — the core of the port:

   | Driver | Lines | `snd_soc_codec` refs | `snd_soc_component` refs | regmap |
   |---|---|---|---|---|
   | `rt5680.c` | 2,884 | 14 (`snd_soc_codec_driver`, `snd_soc_register_codec`) | 0 | ✅ 28 refs |
   | `tas5805m.c` | 598 | 8 (same pattern) | 0 | ✅ 13 refs |

   The `snd_soc_codec` API was removed in ~4.18; 5.10 is component-only
   (`include/sound/soc-component.h` present in zbwu's tree). Both drivers are
   already regmap-based → **no I/O-layer rewrite**, just the standard mechanical
   conversion: `snd_soc_codec_driver`→`snd_soc_component_driver`,
   `snd_soc_register_codec`→`devm_snd_soc_register_component`,
   `snd_soc_codec_get_drvdata`→component equivalents, ops table relocation.
   **In-tree template: `sound/soc/codecs/rt5659.c` exists in the 5.10 tree** —
   same vendor family, shows exactly what a converted Realtek driver looks like.

3. **zbwu's r35.1 never attempted audio** — clean slate, nothing to un-break:
   - `athena_defconfig` audio content: `CONFIG_SND=y`, `CONFIG_SND_SOC=y` — and
     *nothing else* (no Tegra audio platform drivers, no codecs).
   - No sound-card node in his `tegra194-p3668-0001-p2151-0000.dts`.

4. **5.10 target framework is present and standard**: the tree has
   `sound/soc/tegra/tegra_audio_graph_card.c` (r35's standard machine driver,
   DT-graph-based) plus generic `audio-graph-card.c`. The port maps the
   mi-k91 tegra-alt `tegra_sound` node onto audio-graph `dais`/`links` form —
   NVIDIA documents this r32→r35 audio DT migration.

5. **Upstream escape hatch for the amp (verified 2026-07-08):** mainline
   `sound/soc/codecs/tas5805m.c` exists in **v6.1** (absent in v5.17) — component
   API, ~600 lines, loads its DSP config via `request_firmware()`. Backporting it
   to 5.10 is a realistic alternative to converting Xiaomi's driver. Either way,
   Xiaomi's tuned DSP init lives in `tas5805m_basic.h` (1,740 lines of register
   writes) and must be carried — embedded table (Xiaomi route) or repackaged as a
   firmware blob (upstream route).

## Port checklist (lands in Phase 3, bring-up in Phase 5.6)

- [ ] **A. rt5680 conversion** (no upstream driver exists — must convert Xiaomi's):
      mechanical component-API pass over 2,884 lines using `rt5659.c` as the
      pattern reference. *Est. 2–4 evenings incl. first-sound debugging.*
- [ ] **B. tas5805m**: first try converting Xiaomi's 598-line driver (DSP table
      already embedded + tuned); fall back to backporting v6.1 upstream + Xiaomi
      DSP table as firmware. *Est. 1–2 evenings.*
- [ ] **C. Kconfig/Makefile/defconfig**: add `SND_SOC_RT5680` + `SND_SOC_TAS5805M`
      entries (out-of-mainline → own Kconfig lines) and enable the r35 Tegra audio
      stack in `athena_defconfig` (mirror the audio section of r35.6.4
      `tegra_defconfig` — zbwu's has none).
- [ ] **D. DT re-authoring**: mi-k91's 91-line audio dtsi → audio-graph links on
      zbwu's p3668 DTS (`i2s5`↔`rt5680` AIF1 + amp link; confirm the amp's serial
      port + mic-array TDM channel map during implementation). Keep the stock
      `nvidia,audio-routing` table as the routing oracle.
- [ ] **E. Userspace**: UCM/asound configs ported from JP4 `/etc/alsa/` (plan
      §13 5.6); verify 6-mic capture channel order against the stock system.

## Residual risks (all typical-grind, none blocker-shaped)

- DAPM widget/route names shift in the component world → expect an iteration loop
  of `dmesg` + `aplay -l` + amixer until routes bind. Standard audio bring-up.
- Mic-array channel mapping via rt5680 TDM — verify against stock recordings
  (Phase 0 baseline can be captured on JP4 any time before Phase 2).
- `tegra_i2s5` clocking/pinmux on the rebased DTS — cross-check against the live
  DT dump (`dtb-live.dts`), which is authoritative.

## Sources

- Extracted 4.9 sources + audio dtsi: `~/cyberdog-scoping/{codecs-4.9/,mi-k91-audio.dtsi}`
- Mirrors: `~/cyberdog-mirror-2026-07/repos/{cyberdog_tegra_kernel,athena_l4t_kernel,athena_l4t_jakku_dts}.git`
- Live config/DT: `/proc/config.gz`, `~/cyberdog-forensics-2026-04-22/layer0/dtb-live.dts`
- Upstream tas5805m: `torvalds/linux` `v6.1:sound/soc/codecs/tas5805m.c` (fetched 2026-07-08)
