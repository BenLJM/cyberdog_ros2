# RCE CH_SETUP error 128 — root cause & fix (JP5 zero-flash camera)

## TL;DR

The `CH_SETUP` failure was **NOT** a bug in our legacy `hsp-mailbox-client.c`
backport. Our backport sends the CH_SETUP command **byte-identically** to the
R32 factory driver. The real cause is a **device-tree service-set mismatch**:
R35's `tegra194-camera.dtsi` adds one extra IVC channel — `diag@5`
(`nvidia,service = "diag"`) — that the CyberDog's **factory R32-era RCE
firmware does not implement**. During boot sync the firmware walks the IVC
setup descriptors, hits the unknown `"diag"` service, and returns
`RTCPU_CH_ERR_NO_SERVICE` (value **128**).

**Fix:** disable `/camera-ivc-channels/diag@5` in the JP5 board DT (one DT
fragment). `ivc-bus.c` then omits its descriptor, the config region advertises
exactly the five services the R32 firmware supports, and `CH_SETUP` succeeds.

Confidence that CH_SETUP will now return 0: **high**. Confidence that the
camera then produces an image (TAKE_PICTURE): **moderate** (a separate, later
stage — see Residual risks).

---

## 1. What error 128 actually is

`kernel/nvidia/include/soc/tegra/camrtc-channels.h` (identical R32 and R35):

```
enum {
    /* 0 .. 127 indicate unknown commands */
    RTCPU_CH_ERR_NO_SERVICE   = 128,   <-- this one
    RTCPU_CH_ERR_ALREADY      = 129,
    RTCPU_CH_ERR_UNKNOWN_TAG  = 130,
    RTCPU_CH_ERR_INVALID_IOVA = 131,
    RTCPU_CH_ERR_INVALID_PARAM= 132,
};
```

`128 = NO_SERVICE` is decisive. The firmware returned a **channel-setup**
error, not a transport/command error — meaning the command reached the FW, the
FW read the config region at the IOVA (else `131 INVALID_IOVA`), parsed a valid
`IVC-SETU` TLV tag (else `130 UNKNOWN_TAG`), and rejected the **service name**
inside it. So: IOVA fine, memory coherent, TLV layout fine — one service name
is simply unknown to the FW.

## 2. Why it is NOT our command-layer backport

Byte-for-byte comparison of the CH_SETUP path, R32 vs R35+backport:

| item | R32 factory | R35 + our backport | same? |
|---|---|---|---|
| command word | `RTCPU_COMMAND(CH_SETUP, iova>>8)` (`tegra_camrtc_iovm_setup`, tegra-camera-rtcpu.c) | `RTCPU_COMMAND(CH_SETUP, iova>>8)` (`camrtc_hsp_cmd_ch_setup`) | **yes** |
| `RTCPU_CMD_CH_SETUP` | `6` | `6` | yes |
| `RTCPU_COMMAND` / `GET_ID` / `GET_VALUE` macros | `(id<<24)|val` / `(v>>24)&0x7f` / `v&0xffffff` | identical | yes |
| error decode | `GET_ID==ERROR → return value` | identical | yes |
| PREFIX (0x7d) needed? | **no** — R32 `iovm_setup` never sends PREFIX; region IOVA fits in 32 bits (`iova>>8` ≤ 24 bits) | n/a | — |
| IVC_READY (cmd 2) needed? | **no** — `RTCPU_CMD_IVC_READY` is defined in the R32 header but **not used anywhere** in the R32 camera/rtcpu driver (grep: only unrelated tegra-aon / tegra-safety-ivc subsystems use their own IVC_READY) | n/a | — |
| doorbell? | camera RCE uses shared-mailbox pairs, not the HSP doorbell, for commands | same | — |

The R32 boot sequence is exactly `INIT → FW_VERSION → (per region) CH_SETUP`.
No prefix, no IVC_READY, no pre-sync value, no doorbell. Our backport already
matches this. Since `FW_VERSION`/`FW_HASH` succeed on-dog (`cmd=5 sha1=…`), the
transport is proven working, and `CH_SETUP` rides the same transport — the 128
is a firmware *semantic* rejection delivered correctly through a working link.

The R32→R35 refactor of `ivc-bus.c` moves `tegra_ivc_bus_start` into
`tegra_ivc_bus_create` and group-filters notifies, but the TLV builder
(`tegra_ivc_channel_create`) is unchanged: it still writes
`struct camrtc_tlv_ivc_setup` (byte-identical struct in both trees) with
`ivc_service` copied from each child's `nvidia,service`. So the config region
content is a pure function of the DT child set.

## 3. The actual difference: an extra DT channel the R32 FW lacks

`camera-ivc-channels` service set:

| | JP4 (R32, **working**) | JP5 (R35 DTB, **fails**) |
|---|---|---|
| echo@0 | echo | echo |
| dbg@1 | debug | debug |
| dbg@2 | debug | debug |
| ivccontrol@3 | capture-control | capture-control |
| ivccapture@4 | capture | capture |
| **diag@5** | *(absent)* | **diag  ← extra** |

Source of the extra node: `hardware/.../tegra194-soc/tegra194-camera.dtsi`
lines 170–177, `diag@5 { compatible = "nvidia,tegra186-camera-diagnostics";
nvidia,service = "diag"; … }`.

**Firmware-level proof** (the actual on-dog binary, not inference):

```
$ strings qspi-backup-factory.bin | grep -xc <svc>
  echo             8
  debug            6
  capture          6
  capture-control  4
  diag             0     <-- the string does not exist in the factory FW
```

The newer R35 rce-fw image (`rce-fix/…/camera-rtcpu-t194-rce.img`) *does*
contain `diag` — confirming `diag` is a service introduced in firmware newer
than the CyberDog's factory R32 build.

So: R35 kernel writes a `diag` IVC-SETU descriptor → factory FW walks the
chain → no `diag` service → `RTCPU_CH_ERR_NO_SERVICE` (128) → whole
`tegra_ivc_bus_boot_sync` fails `-EIO`.

## 4. The fix

`rce-chsetup-fix/0003-rtcpu-legacy-disable-diag-ivc-channel.patch` appends to
the existing legacy override
`hardware/nvidia/platform/t19x/jakku/kernel-dts/tegra194-mi-k91-rtcpu-legacy.dtsi`:

```dts
&{/camera-ivc-channels/diag@5} {
    status = "disabled";
};
```

`ivc-bus.c` `tegra_ivc_bus_start()` skips children whose `status == "disabled"`,
so no `diag` descriptor is written. The config region then lists exactly
echo/debug/debug/capture-control/capture — the five services present in the
factory FW — and `CH_SETUP` should return 0.

- `hsp-mailbox-client.c` legacy path: **unchanged** (correctly, it was never
  the bug). VM path: untouched.
- Diagnostics is telemetry-only; the capture pipeline
  (`capture` + `capture-control`) does not depend on it. JP4 has never had a
  `diag` channel and captures fine.

## 5. Build / verification (container `cyberdog-kbuild`, athena_defconfig)

Incremental `make -j6 Image dtbs` (native `O=/tmp/kb`), whole tree recompiled
clean (Image relinked), then DTB decompiled and checked:

- `include/config/kernel.release` = **5.10.216-tegra**;
  vmlinux vermagic = `5.10.216-tegra SMP preempt mod_unload modversions aarch64`.
- New DTB `/camera-ivc-channels`: `diag@5` → `status = "disabled"`; the other
  five channels have no status (enabled).
- Legacy RCE `hsp` node intact: `compatible = nvidia,tegra186-hsp-mailbox`,
  `mbox-names = cmd-rx,cmd-tx,ivc-rx,ivc-tx` (the four SM6/7/1/0 mailboxes);
  `hsp-vm1/2/3` + `hsp-cem` all `status = "disabled"`.

Accumulated fixes confirmed still present in the built tree:
- **RCE legacy 4-mailbox** backport (`hsp-mailbox-client.c` legacy ops +
  `mbox-names` DT) — present, compiled, in the DTB.
- **nvmap R32 WRITE/ABI compat** — `nvmap_ioctl.c` `nvmap_rw_handle_r32` path
  present in tree (compiled into the Image).
- **audio** — board DTS still `#include "tegra194-mi-k91-audio.dtsi"` (before
  the rtcpu-legacy include).
- GPS (`bcm_gps_tty.ko`) and Wi-Fi (`8821cu.ko`) are out-of-tree modules built
  separately by `full-build.sh`; unaffected by this DT-only change and not
  rebuilt here.

`nvmap.ko` was **not** rebuilt/needed — this change is DT-only, no driver
source changed, so `nvmap.ko` and all `.ko`s are byte-identical to the last
`full-build.sh` run. `out/` therefore ships `Image` + the fixed `.dtb` only.

## 6. On-target acceptance criteria

Deploy `out/Image` + `out/tegra194-p3668-0001-p2151-0000.dtb` via the normal
JP5 flow (`full-build.sh` stages these; then `build-jp5-initrd.sh`), keeping the
factory RCE firmware. Then in `dmesg`:

- GOOD: still `rtcpu …: version cpu=rce cmd=5 sha1=…` (transport unchanged).
- GOOD: **no** `tegra-ivc-bus …: IOVM setup error: 128`.
- GOOD: **no** `rtcpu …: ivc-bus boot sync failed: -5`.
- GOOD: the RCE IVC/capture channels probe; `capture` / `capture-control`
  channel devices appear (VI/NVCSI capture path can open).
- FINAL: `camera_service` `TAKE_PICTURE` (D455 path) produces an image.

If `IOVM setup error` returns but with a **different** value:
- `132` (INVALID_PARAM) on a channel → a frame-geometry mismatch; the most
  likely candidate is `dbg@1` whose `frame-size` R35 raised to `0x1c0` (448)
  vs JP4's `0x180` (384). Next step would be to also override that back to
  `0x180`. (It is *not* the cause of the 128 — service-name match is
  independent of frame size — so it is left as-is for now.)
- `129` (ALREADY) → FW already set up (e.g. by MB2); harmless / handled by
  retry.

## 7. Residual risks

- **Cannot runtime-test on this Mac.** The root cause is proven at the firmware
  binary level (`diag` absent) and the DT fix is verified in the built DTB, but
  the actual CH_SETUP=0 can only be confirmed on the dog. The 128→0 step is
  **high confidence**.
- **Downstream of CH_SETUP is a separate matter (moderate confidence for a
  picture).** CH_SETUP succeeding only means the IVC channels are established.
  Getting an image additionally needs the VI/NVCSI/capture user stack and the
  D455 stream path — out of scope of this error and unaffected here. This is
  flagged as the next wall, not a regression from this change.
- **`dbg@1` frame-size drift (0x1c0 vs JP4 0x180).** Left unchanged; does not
  affect service matching. Watch for a follow-on `132` (see §6).
- **Losing the diag/telemetry channel** is expected and benign for capture; the
  `camera-diagnostics` driver simply won't bind (no channel device). No crash —
  disabled IVC children are a supported configuration.
- **No BPMP/SPE/other-HSP impact:** only the RCE camera node's DT changed; core
  HSP driver and all other subsystems untouched.

## 8. Files

- `0003-rtcpu-legacy-disable-diag-ivc-channel.patch` — the fix (apply with
  `patch -p1` from `hardware/nvidia/`; already applied in the working tree).
- `out/Image` — 5.10.216-tegra kernel (unchanged content vs last full-build;
  rebuilt for provenance).
- `out/tegra194-p3668-0001-p2151-0000.dtb` — board DTB with `diag@5` disabled.
- `out/VERMAGIC`, `out/SHA256SUMS`.

Tree change is kept in place (`tegra194-mi-k91-rtcpu-legacy.dtsi`); `build/patches/kernel`
untouched; patch stored here standalone per instructions.
