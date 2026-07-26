# F1 — ramoops kernel black box, via kernel cmdline (ZERO DTB / ZERO kernel change)

## Verdict

**Feasible, and it needs no DTB edit and no code edit — only two words on the
kernel command line.** Nothing in `build/kernel-E/out/` implements F1; F1 is a
one-line change to `/boot/extlinux/extlinux.conf` on eMMC `mmcblk0p1`.

## Why probe fails today

```
ramoops reserved-memory:ramoops_carveout: failed to locate DT /reserved-memory resource
ramoops: probe of reserved-memory:ramoops_carveout failed with error -22
```

R32 and R35 describe the carveout differently:

| | compatible | how the base address is found |
|---|---|---|
| R32 (JP4, 4.9) | `nvidia,ramoops` | NVIDIA's own reserved-mem handler records the dynamically allocated base |
| R35 (JP5, 5.10) | `ramoops` (upstream) | `fs/pstore/ram.c:ramoops_parse_dt()` calls `platform_get_resource(IORESOURCE_MEM,0)` |

Our node (`hardware/nvidia/soc/t19x/kernel-dts/tegra194-soc/tegra194-soc-memory.dtsi`)
is a *dynamic* reservation — `size` + `alignment` + `alloc-ranges`, **no `reg`**:

```
ramoops_carveout {
        compatible = "ramoops";
        size = <0x0 0x200000>;
        record-size = <0x00010000>;
        console-size = <0x00080000>;
        alignment = <0x0 0x10000>;
        alloc-ranges = <0x0 0x0 0x1 0x0>;
        no-map;
};
```

`drivers/of/platform.c` still creates a platform device for it (`ramoops` is in
`reserved_mem_matches[]`), but with no `reg` there is no `IORESOURCE_MEM`, so
`ramoops_parse_dt()` returns `-EINVAL`. **The memory is reserved correctly; only
the driver binding fails.**

## Where the carveout actually is — 0xf0800000, size 0x200000

Two independent derivations, both from live read-only forensics on the dog:

1. **Memory-map subtraction.** cboot's `/memory` node (`/sys/firmware/fdt`):
   ```
   reg = <0x0 0x80000000 0x0 0x2c000000     -> 0x80000000..0xabffffff
          0x0 0xac200000 0x0 0x44800000     -> 0xac200000..0xf09fffff
          0x1 0x00000000 0x1 0x80000000>    -> 0x100000000..0x27fffffff
   ```
   `/sys/kernel/debug/memblock/memory` after boot:
   ```
   0: 0x0000000080000000..0x00000000abffffff
   1: 0x00000000ac200000..0x00000000f07fffff    <-- 2 MiB shorter than DT
   2: 0x0000000100000000..0x000000027fffffff
   ```
   `of_reserved_mem` calls `memblock_remove()` for `no-map` regions, so the
   allocation shows up as a *hole*. Region 1 lost exactly `0xf0800000..0xf09fffff`.
   That is the only Linux-side removal in the whole map (`camdbg_carveout`,
   `generic_carveout` and `vpr-carveout` are `status = "disabled"` or size 0;
   `grid-of-semaphores` has a fixed `reg` at 0x40040000, below RAM start).

2. **Page accounting.** DT memory total = 8,329,887,744 B. Kernel reports
   `On node 0 totalpages: 2033152` = 8,327,790,592 B. Delta = **exactly
   0x200000**, the ramoops size.

Allocation is deterministic: `memblock_find_in_range()` is top-down and
`alloc-ranges` caps it at 4 GiB, so it always lands at
`(top of the sub-4 GiB memory region) - 2 MiB` = `0xf0a00000 - 0x200000`.
Nothing else allocates from memblock before `early_init_fdt_scan_reserved_mem()`,
so kernel-image or initrd size changes cannot move it.

> ⚠ **NOT** to be confused with the 2 MiB hole at `0xac000000..0xac1fffff` —
> that one is missing from cboot's `/memory` node itself, i.e. it is a
> *bootloader* carveout of unknown ownership. **Do not point ramoops at it.**

## The change

eMMC `/dev/mmcblk0p1` → `/boot/extlinux/extlinux.conf`, `LABEL jp5`, append to
the existing `APPEND` line (everything before stays byte-identical):

```
ramoops.mem_address=0xf0800000 ramoops.mem_size=0x200000 ramoops.record_size=0x10000 ramoops.console_size=0x80000 ramoops.ftrace_size=0 ramoops.pmsg_size=0 ramoops.max_reason=3
```

Resulting full line:

```
      APPEND ${cbootargs} root=/dev/nvme0n1p2 rw rootwait rootfstype=ext4 console=ttyTCU0,115200n8 console=tty0 fbcon=map:0 net.ifnames=0 panic=15 ramoops.mem_address=0xf0800000 ramoops.mem_size=0x200000 ramoops.record_size=0x10000 ramoops.console_size=0x80000 ramoops.ftrace_size=0 ramoops.pmsg_size=0 ramoops.max_reason=3
```

Rationale per parameter:

| param | value | why |
|---|---|---|
| `mem_address` | `0xf0800000` | derived above |
| `mem_size` | `0x200000` (2 MiB) | matches the carveout exactly; must be a power of 2 or ramoops rounds down |
| `record_size` | `0x10000` (64 KiB) | same as the DT's `record-size`; gives 24 dmesg records in the 1.5 MiB left after console |
| `console_size` | `0x80000` (512 KiB) | same as the DT's `console-size`. `CONFIG_PSTORE_CONSOLE=y`, so this is the zone that captures a **silent hang** (no panic, no oops) |
| `ftrace_size` | `0` | `CONFIG_PSTORE_FTRACE` is not set — would otherwise waste 4 KiB. `ramoops_init_przs()` handles 0 |
| `pmsg_size` | `0` | `CONFIG_PSTORE_PMSG` is not set — same. `ramoops_init_prz()` handles 0 |
| `max_reason` | `3` = `KMSG_DUMP_EMERG` | panic + oops + emergency. `4` (`SHUTDOWN`) would write a record on every clean shutdown |

## Why this is safe

`ramoops_init()` is a `postcore_initcall`, so the module-parameter ("dummy")
device binds **before** `of_platform_default_populate_init()` (`arch_initcall_sync`)
creates the DT device. The DT device then hits ramoops_probe's
`if (cxt->max_dump_cnt) { pr_err("already initialized\n"); }` — one cosmetic
error line replacing today's cosmetic error line. No conflict.

`persistent_ram_buffer_map()` takes the `pfn_valid()` branch: 0xf0800000 was
`memblock_remove()`d, `memblock_is_map_memory()` is false, so `pfn_valid()` is
false and ramoops goes through `persistent_ram_iomap()` →
`request_mem_region()` + `ioremap_wc()`. It does **not** vmap live kernel pages.

## Verification — **do NOT use `echo c > /proc/sysrq-trigger`**

`panic=15` reboots automatically and the rescue USB cable is usually plugged in;
a reboot with that cable attached can drop the board into RCM. Verify passively:

**Boot 1 (right after the cmdline change):**
```sh
dmesg | grep -i ramoops
#   expect: "ramoops: using module parameters"
#   expect: NO "failed to locate DT /reserved-memory resource"
#   expect (harmless):  "ramoops: already initialized"
sudo grep -i ramoops /proc/iomem
#   expect: f0800000-f09fffff : ramoops   (proves the iomap path, not vmap)
cat /sys/module/ramoops/parameters/mem_address   # 0xf0800000
```
`/sys/fs/pstore` will be empty on boot 1 — the RAM signature is garbage the
first time and gets zeroed.

**Boot 2 (any later normal reboot):**
```sh
sudo ls -la /sys/fs/pstore/            # console-ramoops-0 = previous boot's console
sudo ls -la /var/lib/systemd/pstore/   # systemd-pstore.service is ENABLED on this dog:
                                       # it moves records here and clears /sys/fs/pstore
```
Seeing `console-ramoops-0` after a clean reboot is the end-to-end proof.

## Honest limitation

ramoops lives in DRAM. It survives a **warm** reset (panic reboot, `reboot`,
watchdog reset if the reset is not a full POR) but it does **not** survive a
power cut. The 2026-07-23 thermtrip failure mode is a hard power-off, so
**ramoops will not explain a thermtrip.** Its value here is the experimental
nvmap/capture kernel: an oops or panic in `nvmap`/`fusa-capture` now leaves a
record instead of a silent reboot, and the console zone catches a hang that
never reaches a panic.
