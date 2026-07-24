# nvmap R32 ABI compat shim — JP4 camera userspace on the JP5 (R35) kernel

Lets the factory JP4 chroot camera userspace (`nvargus-daemon` / `libargus`,
compiled against **R32** nvmap headers, running as a **64-bit aarch64** process)
talk to the **R35** `5.10.216-tegra` nvmap driver without recompiling userspace.

Two layers, built cumulatively into one `nvmap.ko`:

| layer | ioctls | status | patch |
|---|---|---|---|
| **WRITE/READ/PARAMETERS** | nr 6/7/27 | **Real, functional fix** (confirmed on-dog: no more `NVMAP_IOC_WRITE failed`) | `0001` |
| **MMAP/PIN_MULT/UNPIN_MULT** | nr 5/10/11 | **Compat surface only — faithful `-ENOTTY` deprecation, NOT a functional map/pin, NOT the camera fix** | `0002` |

> **Read this first (headline finding).** The task premise was "R32 had working
> MMAP/PIN, R35 deleted them → re-add them." **This is false for this codebase.**
> On the shipped CyberDog R32 kernel, `NVMAP_IOC_MMAP`/`PIN_MULT`/`UNPIN_MULT`
> were *already* deprecated stubs that returned **`-ENOTTY`**, and `mmap()` on
> `/dev/nvmap` *already* returned **`-EPERM`** — identical to R35 today. The
> camera worked on JP4 while these returned `-ENOTTY`, so it does **not** depend
> on them. Re-adding them (even as "real" implementations) is therefore **not**
> what unblocks `PosixMemMap mmap failed`. Details in §3.

---

## 1. Root cause of the WRITE/READ layer (confirmed, unchanged from 0001)

`_IOW()`/`_IOR()` encode `sizeof(struct)` into the ioctl number. Two nvmap
structs changed size R32 → R35, so the R32-native ioctl numbers the userspace
emits no longer matched any `case` in the R35 switch → `-ENOTTY`.

| struct | R32 size | R35 size |
|---|---|---|
| `nvmap_rw_handle` | 32 (`unsigned long addr` + 6× `__u32`) | 56 (`__u64 addr` + `__u32 handle` + 5× `__u64`) |
| `nvmap_handle_parameters` | 56 | 64 (+ trailing `__u64 offset`) |

0001 re-creates the exact R32 layouts (`nvmap_rw_handle_r32`,
`nvmap_handle_parameters_r32`) and dispatches them into the existing, working
`nvmap_ioctl_rw_handle` / `nvmap_ioctl_get_handle_parameters` code paths with a
size-bounded copy. **This is a genuine functional fix** and is confirmed on the
dog (the `NVMAP_IOC_WRITE failed` dmesg line is gone).

## 2. ioctl-number verification (PASS, both layers)

`scratchpad/ioctl_verify*.c` compiled & run on an LP64 target (struct sizes are
identical on any LP64 ABI; macOS arm64 == Linux aarch64 for these POD structs).
For 0002 the numbers were **also** recomputed by preprocessing the *real edited*
`uapi/linux/nvmap.h` with `__KERNEL__` defined:

```
WRITE/READ (0001)   R32native == R35 replica, and != R35 native (56B)   PASS
MMAP_R32       = 0xc0184e05   (R32 _IOWR('N',5, 24B)  == replica)        PASS
PIN_MULT_R32   = 0xc0184e0a   (R32 _IOWR('N',10,24B)  == replica)        PASS
UNPIN_MULT_R32 = 0x40184e0b   (R32 _IOW ('N',11,24B)  == replica)        PASS
```

R32 `nvmap_map_caller` = 4× `__u32` + `unsigned long` = **24 B**;
`nvmap_pin_handle` = 2 pointers + `__u32` = **24 B** (padded). The replicas
(`nvmap_map_caller_r32`, `nvmap_pin_handle_r32`) reproduce those sizes exactly,
so the re-added numbers equal what the aarch64 userspace emits. nr 5/10/11 are
free in R35 (no collision) and ≤ `NVMAP_IOC_MAXNR`(=106), so they reach the
switch rather than being rejected by the MAXNR guard.

## 3. Why MMAP/PIN is a compat surface, not a fix (the investigation)

Evidence gathered from **both** trees (mirror `cyberdog_tegra_kernel.git` = R32
= what the dog shipped; and the R35 build tree):

**(a) MMAP was never functional on R32 either.**
- R32 legacy `nvmap_dev.c`: `.mmap = nvmap_map` → returns **`-EPERM`**
  ("mmap not supported on nvmap file"). `NVMAP_IOC_MMAP` case → `pr_warn(...
  "deprecated. Use mmap().")` then `break` with `err` still `-ENOTTY`.
- R32 `nv2/` ("rewritten for clarity and safety"): **identical** — mmap fop
  `-EPERM`, `NVMAP_IOC_MMAP` deprecated.
- R35: mmap fop `nvmap_map` is **byte-identical** (`-EPERM`); `NVMAP_IOC_MMAP`
  number/struct removed → hits `default:` → `-ENOTTY`.
- So **R32 and R35 return the identical result** (ioctl `-ENOTTY`, fop `-EPERM`).
  There is *no* ABI gap here — unlike WRITE/READ where the number itself differed.

**(b) There is no recoverable "original" implementation to port.**
`nvmap_map_into_caller_ptr` and `nvmap_ioctl_pinop` are **declared** in
`nvmap_ioctl.h` (both R32 and R35) but **defined nowhere** (`grep` = 0 hits in
every `.c`). The mirror is a single squashed commit (`ab67f9dae [Init] Let there
be code`), so git history holds no earlier NVIDIA body either. The task's pointer
to "R32 `nvmap_map_into_caller_ptr` implementation logic" refers to code that is
not present in this repo.

**(c) A real MMAP-into-caller bridge is not safe on R35.**
The supported R35 map path *does* exist and *does* work: `NVMAP_IOC_GET_FD` →
`mmap()` the dma-buf fd → `nvmap_dmabuf_mmap()` → **`__nvmap_map(h, vma)`**
(`nvmap_dmabuf.c`), with page faults served by `nvmap_vma_ops.fault`. But
`__nvmap_map` is written for a **fresh, fop-created VMA**: it `kzalloc`s a
`nvmap_vma_priv`, and ends with **`BUG_ON(vma->vm_private_data != NULL)`**.
Retrofitting it onto a caller's *pre-existing* VMA (the old
`NVMAP_IOC_MMAP`-into-`caller.addr` model) would trip that `BUG_ON` or corrupt
the VMA's anon/vm_ops state. So the legacy semantics cannot be re-expressed
through the R35 machinery without rewriting core MM code — which cannot be
validated from this Mac.

**(d) A real PIN is not well-defined on R35.**
R35 obtains a device address dynamically via per-attachment `dma_buf` mapping
(one IOVA per SMMU domain). There is **no static per-handle IOVA** to return
(grep for pin/`get_addr`/iova internal APIs = empty). A single `addr` filled into
the pin array is undefined across IOMMU domains — which is *exactly* the reason
NVIDIA deprecated pin: *"User space must never pin NvMap handles to allow
multiple IOVA spaces."*

**(e) `PosixMemMap mmap failed` is an `mmap()` syscall failure, not an ioctl.**
It cannot be caused by a missing `NVMAP_IOC_MMAP` ioctl. The camera maps buffers
by `mmap()`-ing the dma-buf fd → `__nvmap_map`. If that fails on R35 it is
because of a condition *inside* `__nvmap_map`/alloc (handle not allocated, heap
lacks `cpu_access_mask`, RO, or VPR) or because the capture pipeline never
produced the buffer — **none of which a re-added ioctl can change.**

### Consequence — what 0002 actually does

0002 re-adds nr 5/10/11 with R32-exact numbers and installs **explicit, named**
dispatch cases that `pr_warn_once(...)` and leave `err == -ENOTTY`. Observable
behaviour is **byte-identical to the shipped JP4 kernel** (both `-ENOTTY`); the
only delta vs R35-`default` is a precise deprecation message instead of
"Unknown NVMAP_IOC". It is safe (no regression, cannot destabilise), honest
(does not pretend to map/pin), and complete at the ABI-number level. **It is not
expected to change camera behaviour.**

## 4. Build result

- Container `cyberdog-kbuild`, tree at `/work`, `bash /work/full-build.sh`,
  `athena_defconfig`. Full tree: Image + dtbs + modules.
- `KREL = 5.10.216-tegra`; `nvmap.ko` vermagic asserted `5.10.216-tegra …
  aarch64`. `-Werror` is on for the nvmap subdir; 0002 adds only `case` labels +
  `pr_warn_once` (no new locals / no new calls) → warning-clean.
- nvmap is `obj-m` (`NVMAP_CONFIG_LOADABLE_MODULE := y`) → the entire fix lives
  in **`nvmap.ko`**. **0002 changes nothing in Image or DTB** (only nvmap.ko +
  the uapi header it consumes).

**Build stamp (2026-07-25):** `full-build.sh` exit 0.
`nvmap.ko` vermagic = `5.10.216-tegra SMP preempt mod_unload modversions
aarch64`; size **8,832,176 B (8.83 MB), not stripped** (has debug_info/.symtab).
The 0002 deprecation strings are present in the module
(`strings nvmap.ko | grep "compat stub"` → both lines). `-Werror` on the nvmap
subdir; `nvmap_dev.o` compiled clean. sha256(nvmap.ko) =
`1a48206b7aa963864e12cf2b4883326039b8c29851271f58d19bf2b21d7f7281`.

### Cumulative fixes — confirmed present (source tree + built DTB via `dtc -I dtb`)

| area | criterion | result |
|---|---|---|
| nvmap WRITE/READ (0001) | `NVMAP_IOC_WRITE_R32` + `nvmap_rw_handle_r32` in tree | present |
| nvmap MMAP/PIN (0002) | `NVMAP_IOC_MMAP_R32/PIN_MULT_R32/UNPIN_MULT_R32` in tree | present |
| audio | `rt5680` in DTB | present (codec + links) |
| thermal | `map3` in CPU/GPU/AUX/PMIC cooling-maps | removed via `/delete-node/ map3` overlay |
| GPS | `bcm4775` node | present, `status = "okay"` |
| camera (RCE) | legacy `hsp` mailboxes | `okay`, `mbox-names = "cmd-rx,cmd-tx,ivc-rx,ivc-tx"`, hsp-vm1/2/3 `disabled` |

## 5. Deployable artifacts — `nvmap-r32compat/out/`

| file | role |
|---|---|
| `Image` | 5.10.216-tegra kernel (unchanged in content vs 0001; carries rce-legacy + audio + GPS built-ins) |
| `nvmap.ko` | the cumulative R32 ABI shim (**WRITE/READ real fix + MMAP/PIN faithful stubs**) |
| `tegra194-p3668-0001-p2151-0000.dtb` | board DTB with all DT fixes |
| `SHA256SUMS`, `VERMAGIC` | checksums / `5.10.216-tegra` |

Patches: `0001-nvmap-r32-abi-compat.patch` (WRITE/READ/PARAMETERS),
`0002-nvmap-mmap-pin-r32-compat.patch` (MMAP/PIN delta on top of 0001),
`nvmap-r32compat-cumulative.patch` (single-apply pristine→current, all of it).
All three validated to apply with `patch -p1` from `kernel/nvidia/` and to
reproduce the tree byte-identically. `out.0001-backup/` holds the prior known-good
0001-only artifacts.

**Deploy:** the fix is entirely in `nvmap.ko`; drop it into
`/lib/modules/5.10.216-tegra/…/nvmap/`, rebuild initrd, reboot. (Image/DTB are
unchanged vs the 0001 build; redeploy the matched triple if you prefer.)

## 6. On-target verification

- **WRITE/READ (0001):** PASS criterion already met — no `NVMAP_IOC_WRITE
  failed` in dmesg.
- **MMAP/PIN (0002):** expect **no change** to `PosixMemMap mmap failed` /
  `TAKE_PICTURE INVALID_STATE`. If you want to confirm the stub is reached,
  `dmesg` will show the new `nvmap: NVMAP_IOC_MMAP removed …` once-line if (and
  only if) userspace actually probes the legacy number.

## 7. Residual risks & the real next wall

- **MMAP/PIN bridge is a placeholder, by design and by necessity** (§3). Anyone
  reading "added MMAP/PIN" must understand it is a named `-ENOTTY`, not a
  functional map/pin. Confidence that it fixes the camera: **near zero.**
- **The real cause of `PosixMemMap mmap failed` is downstream of nvmap.** Most
  likely the ISP/capture pipeline — **`nvhost`/`host1x`, VI, NVCSI, and the RCE
  camera-firmware channel setup**. `TAKE_PICTURE → INVALID_STATE` is a
  pipeline-state error, consistent with capture never reaching a valid state
  (not a raw OOM/mapping error). If a buffer is never produced, the downstream
  `mmap()` of it fails regardless of nvmap.
- **Expect the same ABI-widening wall in `nvhost`/`host1x`.** Those ioctls saw
  the identical R32→R35 `unsigned long`→`__u64` growth as `nvmap_rw_handle`.
  After the RCE mailbox + nvmap WRITE fixes, the next failures are likely
  `NVHOST_IOCTL_*` / `TEGRA_*` channel/submit ioctls returning `-ENOTTY`, fixable
  with the **same size-shim technique** as 0001 (find the emitted number, add a
  matching struct/case) — but that is a separate, larger investigation.
- **Module load order.** The fix only takes effect once *this* `nvmap.ko` is the
  loaded one (it loads early, from initrd); ensure the initrd/rootfs copy is the
  replaced one, not a stale module.
- **32-bit compat path untouched.** The pre-existing `CONFIG_COMPAT`
  `nvmap_*_32` paths (genuine 32-bit tasks) are independent and unmodified.
