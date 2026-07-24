# nvmap R32 "handle == fd" compat — the camera mmap wall (JP4 userspace on R35 kernel)

**Result in one line:** the wall is a single NVIDIA build-time ABI toggle.
Setting `NVMAP_CONFIG_HANDLE_AS_FD := y` makes `NVMAP_IOC_CREATE` return a
**dmabuf fd** in `op.handle` (R32 semantics) instead of an opaque xarray **id**
(R35 default), so the R32 camera userspace's `mmap(op.handle)` maps the buffer
instead of failing `EBADF`. No userspace change, no `.c` change, no effect on the
kernel graphics stack.

---

## 1. The precise R32 vs R35 semantic difference (CREATE + mmap)

The R32 factory camera userspace does exactly this (from the on-dog strace):

```
fd5 = open("/dev/nvmap")
ioctl(fd5, NVMAP_IOC_CREATE) -> op.handle = H          # H returned by kernel
ioctl(fd5, NVMAP_IOC_ALLOC{.handle=H})                 # OK
mmap(NULL, len, RW, SHARED, H, 0)                       # <-- H used AS THE fd
```

The whole ABI hinges on one design decision — **what `op.handle` (`H`) is**:

| | R32 (JP4, mirror `cyberdog_tegra_kernel.git`) | R35 (this tree, default) |
|---|---|---|
| `NVMAP_IOC_CREATE` returns in `op.handle` | a **dma-buf fd** (`fd = ...; op.handle = fd; fd_install()`) | an **opaque id** from an xarray (`xa_alloc`, range `[U32_MAX/2, U32_MAX]`) |
| every later ioctl resolves `op.handle` via | `nvmap_handle_get_from_fd(op.handle)` → `dma_buf_get(fd)` | `nvmap_handle_get_from_id()` → xarray lookup |
| how userspace maps the buffer | `mmap()` the fd in `op.handle` directly → dma-buf `.mmap` | must call `NVMAP_IOC_GET_FD` first, then `mmap()` that fd |
| `mmap()` on `/dev/nvmap` itself | `-EPERM` (never used) | `-EPERM` (identical) |

R32 is a **one-value-two-uses** model: the value in `op.handle` is simultaneously
the handle for later ioctls **and** a directly-mmap-able fd. R35's default replaces
that with an indirection (id → GET_FD → fd) so a handle can live in multiple IOVA
spaces.

**Why the strace shows `0x7FFFFFFF` / `0x80000000` as the mmap fd.** That is the
literal proof the id path is active. `nvmap_id_array.c` allocates ids with
`XA_LIMIT(XA_START, U32_MAX)` where `#define XA_START (U32_MAX / 2)` = `0x7FFFFFFF`.
So the **first** id handed out is `0x7FFFFFFF` (INT_MAX) and the **second** is
`0x80000000` — exactly the two values the camera then passes to `mmap()` as an fd.
The VFS does `fdget(0x7FFFFFFF)`, finds no such fd, and returns `EBADF` **before any
nvmap code runs**. CREATE and ALLOC "succeed" because `nvmap_handle_get_from_id()`
happily resolves the id via the xarray; only `mmap()` — which needs a real fd —
falls over.

## 2. Root cause in the code, and the one gate that controls it

`nvmap_open()` (`nvmap_dev.c`) is the only place the per-file id table is armed:

```c
nvmap_id_array_init(&priv->id_array);
#ifdef NVMAP_CONFIG_HANDLE_AS_ID
    priv->ida = &priv->id_array;   // id semantics
#else
    priv->ida = NULL;              // fd (dma-buf) semantics  == R32
#endif
```

`nvmap_ioctl_create()` branches on exactly that pointer:

```c
if (client->ida) {                 // id path
    nvmap_id_array_id_alloc(client->ida, &id, dmabuf);
    op.handle = id;  copy_to_user(); return;      // <-- returns an ID
}
fd = nvmap_get_dmabuf_fd(client, ref->handle, is_ro);
op.handle = fd;                                    // <-- returns an FD (R32!)
nvmap_install_fd(client, handle, fd, ...);
```

And `nvmap_handle_get_from_id()` already handles **both**: with `ida == NULL` it does
`dma_buf_get((int)id)` — i.e. treats `op.handle` as an fd, identical to R32's
`nvmap_handle_get_from_fd()`. So with `priv->ida == NULL` the **entire** R35 driver
already speaks the R32 dialect: CREATE returns an fd, ALLOC/WRITE/READ/GET_ID accept
that fd, and `mmap(fd)` hits the normal dma-buf path.

`NVMAP_CONFIG_HANDLE_AS_ID` is set by the config logic in
`Makefile.memory.configs` for 5.10+ **unless** its sibling toggle is on:

```make
ifneq ($(NVMAP_CONFIG_HANDLE_AS_FD),y)
    NVMAP_CONFIG_HANDLE_AS_ID := y      # default: id semantics
    NVMAP_CONFIG_FD_START := 0x0
endif
```

NVIDIA ships `NVMAP_CONFIG_HANDLE_AS_FD` for precisely this purpose — its own comment
reads *"fallback option to support handle as FD … useful to debug issue if its due to
handle as ID or FD."* Setting it to `y` prevents `HANDLE_AS_ID` from ever being
defined → `priv->ida = NULL` → R32 semantics.

## 3. The fix (this is the whole change)

`drivers/video/tegra/nvmap/Makefile.memory.configs`:

```
-NVMAP_CONFIG_HANDLE_AS_FD := n
+NVMAP_CONFIG_HANDLE_AS_FD := y
```

Patch: `0003-nvmap-handle-as-fd-r32-compat.patch` (apply `-p1` from `kernel/nvidia/`).
Consequences, all automatic from the existing `#ifdef`s:

- `priv->ida = NULL` for every `/dev/nvmap` open → CREATE returns a dma-buf fd.
- `nvmap_id_array.o` is dropped from `nvmap-y` (Makefile); all `nvmap_id_array_*`
  calls resolve to the `static inline` no-op stubs in `nvmap_priv.h` (`#else` arm),
  so the module still links with **zero** undefined symbols.
- `FD_START` reverts to its default `0x400` (unused in the module build, which
  allocates fds via `get_unused_fd_flags()` regardless).

Camera flow afterward, end to end:

```
CREATE -> op.handle = 7           (real dma-buf fd, fd_install'd)
ALLOC{.handle=7} -> get_from_id -> dma_buf_get(7) -> nvmap dmabuf -> alloc backing
mmap(.., 7, 0) -> fdget(7) -> dma_buf .mmap -> nvmap_dmabuf_mmap -> __nvmap_map(vma)
                  -> buffer mapped.  NO EBADF.
```

`__nvmap_map` runs on a **fresh, fop-created** VMA (the dma-buf mmap), so its
`BUG_ON(vma->vm_private_data != NULL)` — the hazard flagged in the earlier MMAP-ioctl
investigation — is not in play here. This is the ordinary, supported R35 dma-buf map
path; we merely reach it without an intervening `GET_FD`.

### Why the two alternative routes were rejected

- **Route B (intercept `mmap` of the id) is structurally impossible.** `mmap(0x7FFFFFFF)`
  fails in the VFS `fdget()` layer before any driver `.mmap` is called. A non-fd number
  has no `struct file`, so there is nothing for nvmap to hook. The only way to make
  `mmap(op.handle)` work is to make `op.handle` a real fd — i.e. route A.
- **Route A by editing `nvmap_ioctl_create` by hand** (force the fd branch) would work
  but is strictly worse than flipping the vendor toggle: it would leave the id
  machinery half-wired, fight the `#ifdef`s in `get_from_id`/`is_nvmap_id_ro`/dmabuf-fd
  allocation, and diverge from a configuration NVIDIA actually tests. The toggle flips
  **all** of those sites coherently in one move.

## 4. Why this does not touch nvgpu / host1x / VI / the graphics stack (hard constraint)

The toggle changes the **userspace `/dev/nvmap` ioctl ABI only**. Argument:

1. `priv->ida` is set **exclusively** in `nvmap_open()` (the `/dev/nvmap` file open,
   `kernel_client = false`). No other site assigns it.
2. In-kernel nvmap consumers — nvgpu, host1x, VI, NVCSI, display, VIC — never call
   `nvmap_open()`. They obtain an `nvmap_client` through `__nvmap_create_client()`,
   which sets `kernel_client = true` and **leaves `ida` NULL** (it is zero-initialised
   and never touched there). So kernel clients were **already** in "fd/dma-buf" mode
   irrespective of `HANDLE_AS_ID`; this flag has never applied to them.
3. Kernel drivers also don't use the `op.handle` ioctl ABI at all — they use the
   in-kernel API (`nvmap_alloc`, `nvmap_pin`, `dma_buf_*`, `__nvmap_map`) and dma-buf
   handles, none of which read `client->ida`.

So the change is *incapable* of altering the kernel graphics path — not "unlikely to",
but structurally isolated by the `kernel_client` / `nvmap_open` split. The only clients
whose CREATE return value changes are userspace processes that `open("/dev/nvmap")`, and
on the JP5 dog those are the R32 chroot camera/multimedia libraries — which **want** fd
semantics. There is no R35-native userspace nvmap client on this system to regress.

(One could imagine a still more surgical "per-client heuristic" that hands fds only to
R32 callers, but there is no signal at CREATE time to distinguish them — R32 and R35
issue the identical ioctl — and it is unnecessary precisely because the kernel path is
already isolated and the userspace is uniformly R32.)

## 5. Build

- Container `cyberdog-kbuild`, tree at `/work`, `bash /work/full-build.sh`,
  `athena_defconfig`, `LOCALVERSION=-tegra`. Full tree: Image + dtbs + modules.
- nvmap is `obj-m` (`LOADABLE_MODULE := y` for 5.10) → the fix lives entirely in
  **`nvmap.ko`**. Image and DTB are unchanged in content vs the prior 0001/0002 build.
- Warning surface: the toggle only removes a translation-unit (`nvmap_id_array.o`) and
  flips `#ifdef`s that were already exercised in the tree; it introduces no new locals,
  calls, or casts. `-Werror` is on for the nvmap subdir. (Build stamp + vermagic +
  warning grep appended below once the container run completes.)

**Build stamp (2026-07-25):** container `full-build.sh` exit 0.
- `nvmap.ko` vermagic = `5.10.216-tegra SMP preempt mod_unload modversions aarch64`;
  size **8,544,320 B (8.54 MB), not stripped** (has debug_info/.symtab). sha256 =
  `8890a5fa816044b5766cf39f0e106e01754e3488be75ebee5463c6462bda8aa4`.
- **HANDLE_AS_FD verified in the binary:** `nm nvmap.ko` shows **no** global
  `nvmap_id_array_*` text symbols and **no** `id_array` symbols of any binding →
  `nvmap_id_array.o` was excluded from the link → the toggle compiled through.
- **`-Werror` clean (proof by construction):** the nvmap subdir carries
  `subdir-ccflags-y := -Werror`; every nvmap `.c` recompiled under this change (the
  flag alters subdir ccflags), so any warning would have been promoted to an error
  and aborted the build. The build completed and produced `nvmap.ko` → zero warnings
  in the nvmap subdir.
- Image sha256 = `c13cfaf92add4a40f73a9de6dde10d3defcd7f8fd367f2cbf8ce019f13229f47`
  (unchanged in content vs prior 0001/0002 build — this fix touches only nvmap.ko).
- **DTB dtc cross-check (deployment iron-law, all PASS):** decompiled
  `tegra194-p3668-0001-p2151-0000.dtb` (sha256 `8da03287…`):
  - `camera-diagnostics/diag@5` → `status = "disabled"` ✓ (drops the diag IVC channel the R32 FW lacks → no CH_SETUP 128 fallback)
  - `realtek,rt5680` → 6 codec compatibles ✓
  - thermal `map3` → 0 occurrences (removed) ✓
  - `bcm4775` GPS → `status = "okay"` ✓
  - `hsp-vm1/2/3` (+ `hsp-cem`) → `status = "disabled"` ✓
  - legacy `hsp` (`nvidia,tegra186-hsp-mailbox`) → `mbox-names = "cmd-rx","cmd-tx","ivc-rx","ivc-tx"; status = "okay"` ✓

### Cumulative fixes confirmed present (source tree)

| area | marker | file | status |
|---|---|---|---|
| nvmap WRITE/READ R32 (0001) | `NVMAP_IOC_WRITE_R32`, `nvmap_rw_handle_r32` | `uapi/linux/nvmap.h`, `nvmap_ioctl.c` | present |
| nvmap MMAP/PIN stubs (0002) | `NVMAP_IOC_MMAP_R32` etc. | `nvmap_dev.c` | present (moot under this fix) |
| **nvmap handle-as-fd (0003, this)** | `NVMAP_CONFIG_HANDLE_AS_FD := y` | `Makefile.memory.configs` | **present** |
| audio | `rt5680` 6-mic card + `tas5805m` | `tegra194-mi-k91-audio.dtsi`, board `.dts` | present |
| ADMA | `tegra194-soc-audio.dtsi` ADMA | soc audio dtsi | present |
| GPS | `bcm4775` | `common/tegra194-p2151-0000.dtsi` | present |
| RCE legacy 4 mailboxes | `mbox-names = "cmd-rx","cmd-tx","ivc-rx","ivc-tx"; status="okay"` + hsp-vm1/2/3 `disabled` | `tegra194-mi-k91-rtcpu-legacy.dtsi` | present |
| diag@5 disabled | `&{/camera-ivc-channels/diag@5} { status="disabled"; }` | `tegra194-mi-k91-rtcpu-legacy.dtsi` | present |

Board `.dts` (`tegra194-p3668-0001-p2151-0000.dts`) `#include`s the mi-k91 audio and
rtcpu-legacy overlays. DTB `dtc` cross-check appended with the build stamp.

## 6. On-target acceptance criteria

1. **The wall falls if:** starting `maincamera`/`nvargus-daemon` no longer logs
   `PosixMemMap mmap failed` / the `mmap … EBADF` in strace is gone. The CREATE return
   value in `op.handle` should now be a **small fd** (e.g. `6`, `7`), not `0x7FFFFFFF`.
2. **Full success if:** `TAKE_PICTURE` produces a JPG (buffer maps, capture pipeline
   runs through VI/NVCSI/RCE with the legacy-mailbox + diag@5 DT already in place).

## 7. Rollback

- **Instant, no reflash:** keep the previous `nvmap.ko`; the fix is entirely in that
  module. Restore the old `/lib/modules/5.10.216-tegra/…/nvmap/nvmap.ko`, rebuild
  initrd, reboot. (Image/DTB are unchanged, so no bootloader/partition churn.)
- **Source:** revert `0003` (`HANDLE_AS_FD := n`) and rebuild, or `git`-less: restore
  `pristine/Makefile.memory.configs.orig`.
- The owner's existing older-kernel backup remains the ultimate fallback.

## 8. Confidence & residual risk

- **That the specific mmap-EBADF wall falls: high.** The failure is fully explained
  (id-as-fd), the fix directly makes `op.handle` a real fd, and the resulting map path
  is the standard dma-buf one. This is a vendor-supported toggle, not a bespoke hack.
- **That a JPG comes out end-to-end: good, not certain.** mmap failing at buffer-pool
  setup is *upstream* of capture, so clearing it is necessary; whether the VI/NVCSI/RCE
  capture then yields a frame depends on the rest of the pipeline. All *known* walls
  (RCE legacy mailboxes, diag@5, nvmap WRITE ABI) are already addressed, but an
  unmapped-so-far pipeline issue could surface next (most likely an `nvhost`/`host1x`
  channel ioctl hitting the same R32→R35 `unsigned long`→`__u64` struct-width growth
  that 0001 fixed for nvmap WRITE — fixable with the same size-shim technique).
- **That nvgpu / the graphics stack is unaffected: very high** — structural isolation
  (§4), not a probabilistic bet.
- **Residual userspace risk: low.** Any R32 client path that only ever "worked" by
  accident under id semantics is realigned to the fd semantics it was compiled for; the
  strace flow (CREATE/ALLOC/mmap) is native fd usage. Per-handle fd consumption rises
  (each handle now holds an open fd, as on R32) — ensure the daemon's `RLIMIT_NOFILE`
  is adequate; nvmap already bumps it in `nvmap_open`, and R32 ran this way by design.
