# RCE legacy HSP backport — zero-flash camera on JP5 (WORKING PLAN)

Goal: let the **R35 kernel (5.10.216-tegra)** RCE camera driver talk to the
**factory R32-era RCE firmware** in QSPI, **without reflashing** it (reflash is
ruled out: MB2/R32 bootloader hands the kernel a legacy RCE, so no rce-fw build
matches at the handoff).

## TL;DR verdict — FEASIBLE, and NO core mailbox-driver change is needed

Zero-flash works with **two** small, self-contained changes:
1. a **command-layer** backport in the active camera driver
   `hsp-mailbox-client.c` (SM5 `RTCPU_COMMAND` ops + legacy fallback), and
2. a **board DTS override** that points the legacy `hsp` node at the correct
   four shared mailboxes via the generic `mboxes` binding.

**`drivers/mailbox/tegra-hsp.c` is NOT touched.** The "bidirectional shared
mailbox" driver hack discussed earlier (and requested as patch 0003) turned out
to be **unnecessary** — see §2. That is the safe outcome: no change to the core
HSP driver that BPMP/SPE/others depend on.

## 1. Correction to the earlier analysis (important)

My previous note claimed the transport was blocked because the SM5 firmware
uses "one shared mailbox half-duplex," which the generic driver can't do. **That
was wrong.** Reading the R32 pair driver settles it: a shared-mailbox *pair* at
index N is **full-duplex over TWO mailboxes, N and N^1**.

Evidence — `kernel/nvidia/drivers/platform/tegra/tegra186-hsp.c`:
```
tegra_hsp_sm_pair_request():
    pair->rx = tegra_hsp_sm_rx_create(dev, index,      ...);   // SM_RX(N)
    pair->tx = tegra_hsp_sm_tx_create(dev, index ^ 1,  ...);   // SM_TX(N^1)
of_tegra_hsp_sm_tx_by_name(): /* pair of the numbered shared-mailbox */
    smspec.args[1] = TEGRA_HSP_SM_TX(smspec.args[0] ^ 1);
```
So the JP4 legacy node `nvidia,hsp-shared-mailbox = <&hsp_rce 1>, <&hsp_rce 6>`
(`"ivc-pair","cmd-pair"`) actually means four unidirectional mailboxes:

| pair | VM receive (RCE->VM) | VM send (VM->RCE) |
|---|---|---|
| ivc (index 1) | `SM_RX(1)` | `SM_TX(1^1 = 0)` |
| cmd (index 6) | `SM_RX(6)` | `SM_TX(6^1 = 7)` |

Four **distinct** mailboxes (0,1,6,7), each unidirectional — exactly what the
mainline generic mailbox driver already provides (it's the same mechanism the
SM6/vm path uses; only the mailbox numbers and the message format differ). Hence
no `-EBUSY` (all different indices) and no driver-core change.

## 2. Why the bidirectional-driver patch (0003) is not needed / not built

The `-EBUSY` and "one channel can't send+receive" limits in
`drivers/mailbox/tegra-hsp.c` are real, but they only bite if you request the
*same* SM index as both TX and RX. The legacy protocol never does that — it uses
`SM_RX(6)`+`SM_TX(7)` and `SM_RX(1)`+`SM_TX(0)`. So the stock driver handles it.
Adding a bidirectional SM mode would be extra risk on a driver shared with
BPMP/SPE for zero benefit, so it is deliberately **omitted**.

## 3. Component A — command-layer driver patch

`0001-hsp-mailbox-client-legacy-sm5-protocol.patch` (**+295 / -1**), on the
active `hsp-mailbox-client.c` (the `CONFIG_TEGRA_CAMERA_HSP_MBOX_CLIENT=y` build
uses this file, not `hsp-combo.c`). It adds, over the generic mailbox framework:

- legacy `camrtc_hsp_cmd_ops` (`sync`=INIT+FW_VERSION, `resume`=FW_VERSION,
  `suspend`=PM_SUSPEND(0), `bye`=PM_SUSPEND(1), `ch_setup`/`ping`/`get_fw_hash`,
  `group_ring`=ring the ivc-tx mailbox), sharing the existing
  `camrtc_hsp_send/recv/sendrecv`;
- `camrtc_hsp_legacy_rx_notify` (SM5 responses carry ids < `CAMRTC_HSP_HELLO`;
  the vm rx callback would drop them) and `camrtc_hsp_legacy_ivc_notify`;
- `camrtc_hsp_cmd_probe()` requesting **four** mbox channels by name —
  `cmd-tx`, `cmd-rx`, `ivc-tx`, `ivc-rx` — via `mbox_request_channel_byname`,
  plus the fallback in `camrtc_hsp_probe()` (**vm first, legacy on -ENOTSUPP**),
  vm path untouched;
- restores `RTCPU_CMD_PING`(3)/`RTCPU_CMD_FW_HASH`(5) which R35's
  `camrtc-commands.h` had turned into `RESERVED` (fixed ABI values the firmware
  still uses).

The driver never hardcodes mailbox indices — it requests by name, so the SM
index map lives entirely in the DTS (Component B).

## 4. Component B — board DTS override

`tegra194-mi-k91-rtcpu-legacy.dtsi` + `0002-jakku-p2151-include-rtcpu-legacy.patch`
(one `#include` after the audio dtsi in `tegra194-p3668-0001-p2151-0000.dts`).
Under `&tegra_rce` it:

- disables `hsp-vm1/2/3` + `hsp-cem`. Disabling `hsp-vm1` makes
  `camrtc_hsp_vm_probe()` return `-ENOTSUPP` (legacy fallback). It is also
  mandatory for mailbox availability: `hsp-vm1` = `SM_TX(0)`,`SM_RX(1)` and
  `hsp-cem` = `SM_RX(6)`,`SM_TX(7)` occupy **exactly** the four mailboxes the
  legacy pairs need, so they must be freed;
- re-expresses the legacy `hsp` child (already in `tegra194-camera.dtsi`) with
  the generic binding, deleting the old `nvidia,hsp-shared-mailbox*` props:

  | mbox-name | cell | direction |
  |---|---|---|
  | `cmd-rx` | `SM_RX(6)` | RCE -> VM (responses) |
  | `cmd-tx` | `SM_TX(7)` | VM -> RCE (commands) |
  | `ivc-rx` | `SM_RX(1)` | RCE -> VM (IVC doorbell in) |
  | `ivc-tx` | `SM_TX(0)` | VM -> RCE (IVC doorbell out) |

  These are byte-equivalent to the JP4 working mailboxes.

## 5. Build / compile verification

`make -j6 Image dtbs` in the `cyberdog-kbuild` container against
`athena_defconfig`, all three changes applied:

**PASS (rc=0).** `vmlinux`/`Image` linked; `include/config/kernel.release` =
`5.10.216-tegra`; vmlinux vermagic = `5.10.216-tegra SMP preempt mod_unload
modversions aarch64`. Legacy symbols present in the linked active object
`drivers/platform/tegra/rtcpu/built-in.a`: `camrtc_hsp_cmd_ops`,
`camrtc_hsp_cmd_send`, `camrtc_hsp_legacy_rx_notify`,
`camrtc_hsp_legacy_ivc_notify`.

`tegra194-p3668-0001-p2151-0000.dtb` built; `dtc -I dtb` confirms the legacy
node: `hsp-vm1/2/3` + `hsp-cem` `status="disabled"`, and `hsp` `okay` with
`mboxes = <hsp_rce SM RX(6)>, <SM TX(7)>, <SM RX(1)>, <SM TX(0)>`
(raw `0x06, 0x80000007, 0x01, 0x80000000`) named `cmd-rx,cmd-tx,ivc-rx,ivc-tx`,
old `nvidia,hsp-shared-mailbox*` props deleted.

`drivers/mailbox/tegra-hsp.c` unchanged (0 diff) — confirming no core change.

## 6. On-target verification (deploy new Image + legacy DTB)

1. Deploy the built `Image` and the p2151 `*.dtb` via the existing JP5 flow
   (`full-build.sh` then `build-jp5-initrd.sh`), keeping the factory RCE firmware.
2. `dmesg` should now show the RCE syncing over the **legacy** path:
   - GOOD: `... rtcpu ...: version cpu=rce cmd=5 sha1=<...>`
     (`tegra_camrtc_log_fw_version`, `tegra-camera-rtcpu.c:987`; `cmd=5` = the
     factory SM5 firmware, matching JP4).
   - GOOD: **no** `hsp-vm1: response timeout`, **no** `rce full reset`.
   - The probe line should name the legacy child (`...:hsp`), not `:hsp-vm1`.
3. Confirm camera IVC/capture channels come up and a stream starts (D455 path).

## 7. Residual risks

- **Cannot runtime-test on this Mac.** The transport is proven to work at the
  framework level (the SM6/vm path already transports over these same generic SM
  channels on JP5; only the firmware protocol differs), and the mailbox numbers
  are copied 1:1 from the working JP4 config — but the actual SM5 handshake can
  only be confirmed on the dog (watch for `cmd=5`). Low-moderate.
- **FW version floor:** `camrtc_hsp_cmd_fw_version` requires FW `>= SM4`; factory
  is SM5 -> OK. If `dmesg` shows a version mismatch, the flash FW is older than
  assumed. Low.
- **Coarse IVC notify:** legacy `group_notify(..., 0xFFFF)` wakes all IVC groups
  (original R32 behaviour); functionally correct, marginally more wakeups. Low.
- **`tx_done` on cmd-tx** still points at the vm `camrtc_hsp_tx_empty_notify`
  (completes `emptied`, which the legacy send path does not wait on) — harmless.
- **No BPMP/SPE impact:** nothing outside this camera node changed; the generic
  HSP driver is untouched and other HSP users keep their existing single-
  direction channels. This is the main reason to prefer this over patch 0003.

## 8. Deployable artifacts

Built and copied out to `/Users/ben/projects/cyberdog/build/rce-legacy-port/out/`:
- `Image` — the 5.10.216-tegra kernel (33 MB).
- `tegra194-p3668-0001-p2151-0000.dtb` — the p2151 board DTB with the legacy
  rtcpu node (310 KB).
- `SHA256SUMS`, `VERMAGIC` — checksums and `5.10.216-tegra`.

Deploy via the existing JP5 flow (these replace the `Image` and `*p2151*.dtb`
that `full-build.sh` stages; then re-run `build-jp5-initrd.sh`). Factory RCE
firmware stays as-is.

## 9. File manifest (this directory)

- `0001-hsp-mailbox-client-legacy-sm5-protocol.patch` — command-layer backport
  (apply from `kernel/nvidia/`: `patch -p1 < 0001-...patch`).
- `tegra194-mi-k91-rtcpu-legacy.dtsi` — board override; install into
  `hardware/nvidia/platform/t19x/jakku/kernel-dts/`.
- `0002-jakku-p2151-include-rtcpu-legacy.patch` — `#include` into the p2151 board
  DTS (apply from `hardware/nvidia/`: `patch -p1 < 0002-...patch`).
- `hsp-mailbox-client.c.orig`, `tegra194-p3668-0001-p2151-0000.dts.orig` —
  pristine baselines. Kernel tree restored to pristine after building.
- `out/` — deployable `Image` + `.dtb` (see §5).
- **No `0003`** — the bidirectional tegra-hsp change is intentionally not made
  (§2).

## 10. Provenance

- Pair = full-duplex N/N^1: `tegra186-hsp.c` `tegra_hsp_sm_pair_request`
  (rx=SM_RX(N), tx=SM_TX(N^1)) and `of_tegra_hsp_sm_tx_by_name` (`args[0] ^ 1`).
- Active driver select: rtcpu `Makefile` + `.config`
  `CONFIG_TEGRA_CAMERA_HSP_MBOX_CLIENT=y`, `CONFIG_TEGRA_HSP_MBOX=y`.
- Dropped cmd ids: parent commit `0202724f8` "remove unused HSP commands".
- Working reference: JP4 live DT `build/audio-port/dtb-live.dts` (7270-7301);
  JP4 dmesg `cmd=5`.
