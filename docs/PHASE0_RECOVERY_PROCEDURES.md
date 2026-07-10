# Phase 0 — Recovery procedures & x86 host preparation

Recipes for every failure mode, keyed to the Layer 0–4 backups under `/mnt/backup/cyberdog-2026-04/` on the external USB SSD (label `CYBERDOG_BACKUP`).

## 1. Recovery-mode access to the dog (from x86 host)

Required before any eMMC-level recovery. Two equivalent paths:

> **On the "download cable" (clarified 2026-07-09 — the owner lost the factory one).**
> The official flashing wiki states plainly: *"下载线可以是普通的USB线，也可以是附送的刷机线（应该是黑色的）"* — **a normal USB-A→USB-C data cable works; the factory black cable is NOT required.** The black cable's only special property is a **modified pin that pulls Tegra's FC_REC low on power-up**, so it enters recovery *automatically* — the hardware equivalent of the `forced-recovery` command. Everything after entering recovery (flashall.sh) is identical either way. **Losing the black cable costs only the auto-trigger convenience — and one bricked-system fallback (Path B).** Use a known-good USB **data** cable (not charge-only).

### Path A — from the running dog (easiest; the normal path, no special cable)

```bash
# On the dog, over SSH (Wi-Fi 10.0.0.219 or USB-OTG 192.168.55.1):
sudo reboot --force forced-recovery
```

The dog restarts into the Tegra USB recovery mode. Connect a plain USB-A → USB-C **data** cable from host PC to the dog's **DOWNLOAD** port. On host:

```bash
lsusb | grep -i nvidia
# Expected: Bus 001 Device NNN: ID 0955:7e19 NVidia Corp.
```

**This is the primary path and it needs no special cable.** Its one prerequisite is
that the dog boots far enough to run the command (even the Phase-2 rescue initrd
suffices). The whole Phase 2/4 design deliberately always preserves an SSH-reachable
boot path precisely so this path always works.

### Path B — from a fully-bricked dog (can't SSH in to run Path A)

This is the **only** scenario where the black cable is not substitutable: with no
shell, you can't issue `forced-recovery`, so recovery must be triggered by hardware.
Options, best-known first:

1. **Factory black cable** (auto-triggers FC_REC on power-up) — if you still had it.
2. **Power-button-hold + connect USB-C at power-on** — Tegra BootROM *should* fall
   into RCM when it sees a host at power-on. ⚠️ **Documented from general Tegra
   behavior; NOT yet verified on this CyberDog.** Verify during the recovery-drill
   (below) before relying on it.
3. **Self-made recovery cable** — replicate the black cable by shorting the
   appropriate USB-C pin to FC_REC. Needs the k91 DOWNLOAD-port pinout (not yet
   documented; a teardown/continuity-probe task).

If none work and the eMMC/QSPI bootloader is fully dead, the only remaining path is
opening the chassis for the recovery header — **explicitly out of scope** (sealed
enclosure). **This is exactly why the Phase 2/4 design never lets the system brick
past an SSH-able state** — so Path A always remains available and Path B is never
actually needed.

### Recovery-mode drill (do once with the x86 host, before Phase 2)

Proves Path A works **without the black cable** — closes the lost-cable gap. Entering
recovery and doing nothing is **reversible and zero-risk** (RCM just waits for host
commands; power-cycle without flashing → normal boot):

1. x86 host ready, plain USB-A→C data cable connected to the DOWNLOAD port.
2. On the dog: `sudo reboot --force forced-recovery`.
3. On host: `lsusb | grep -i 0955:7e19` — **APX device present ⇒ Path A confirmed cable-independent.**
4. Do **not** flash anything. Power-cycle the dog → it boots normally back into JP4.5.
5. While here, optionally test Path B option 2 (power-hold + USB) to learn whether the
   BootROM-RCM fallback works on this unit.

## 2. Recovery matrix (keyed to which layer you need)

| Failure mode | Recovery source | Approximate time |
|---|---|---|
| Corrupt rootfs on `nvme0n1p2` (JP5 side) | Re-rsync `Linux_for_Tegra/rootfs/` from x86 host into `/mnt/p2`; re-run Phase 4 | 30 min |
| Corrupt rootfs on `nvme0n1p1` (JP4.5 side) | Layer 2 `rootfs-nvme.tar.zst` restore (see §3) | 45 min |
| `/boot/extlinux/extlinux.conf` broken (no boot menu) | Layer 0 `extlinux.conf.original` + Layer 1 `boot-jp4.tar.zst` | 10 min (via USB recovery) |
| Wrong kernel or DTB in `/boot` | Layer 1 `boot-jp4.tar.zst` | 10 min |
| `/params` factory calibration wiped | Layer 0 `params-emmc-p12.img` → `dd` back onto `/dev/mmcblk0p12` | 2 min |
| Wi-Fi creds lost | Layer 0 `wifi-creds.tar.gz` → extract to `/etc/NetworkManager/system-connections/` | 1 min |
| eMMC kernel / DTB partition corrupted | Layer 3 `emmc-parts/p{02..09,14}.img` + USB force-recovery + NVIDIA flash tool | 45 min |
| eMMC GPT corrupted | Layer 3 `emmc-full.img.zst` + `gpt.bin` + USB force-recovery | 1 hr |
| **QSPI bootloader (MB1/MB2/cboot/BCT) corrupted** | **Layer 3b `qspi-mtdblock0.img`** (exact current state — added 2026-07-07, review §2.2) + USB force-recovery + flash tools. Preferred over any factory reflash: no version/ratchet questions | 1 hr |
| Totally bricked (eMMC + NVMe both lost) | Layer 4 factory-reset path (see §5) — **now with the exact V1.0.0.94 image** | 2–3 hrs |

## 3. Rootfs restore from Layer 2 tar

With the dog in recovery mode and NVMe accessible over USB (via `initrd_flash` or mass-storage passthrough):

```bash
# On x86 host — p1 is the JP4.5 partition
sudo mount /dev/disk/by-label/CYBERDOG_BACKUP /media/backup
sudo mkfs.ext4 -F -L ROOT_JP4 /dev/sda-cyberdog-p1   # adjust device
sudo mount /dev/sda-cyberdog-p1 /mnt/restore
sudo tar --xattrs --acls --numeric-owner \
  -I 'zstd -T0 -d' \
  -xf /media/backup/cyberdog-2026-04/layer2/rootfs-nvme.tar.zst \
  -C /mnt/restore

# Re-bless extlinux
sudo cp /media/backup/cyberdog-2026-04/layer0/extlinux.conf.original \
        /mnt/restore/boot/extlinux/extlinux.conf
sudo umount /mnt/restore
sync
```

## 4. eMMC partition surgical restore

For each corrupt partition `p<N>`, while the dog is in recovery mode and eMMC is exposed as e.g. `/dev/sdb` on the host:

```bash
sudo dd if=/media/backup/cyberdog-2026-04/layer3/emmc-parts/p<NN>.img \
        of=/dev/sdb<N> bs=1M conv=fsync status=progress
```

If the GPT itself is damaged:

```bash
sudo sgdisk --load-backup=/media/backup/cyberdog-2026-04/layer3/gpt.bin /dev/sdb
sudo partprobe /dev/sdb
```

For total eMMC reflash (slower but simpler):

```bash
sudo zstd -d -c /media/backup/cyberdog-2026-04/layer3/emmc-full.img.zst \
  | sudo dd of=/dev/sdb bs=4M status=progress
```

## 5. Factory-reset from bare silicon (Layer 4)

This is the nuclear option. Uses NVIDIA's official BSP + Xiaomi's `flashall.sh` (per [the official wiki](https://github.com/MiRoboticsLab/cyberdog_ros2/wiki/%E5%A6%82%E4%BD%95%E7%BA%BF%E5%88%B7%E9%93%81%E8%9B%8B)).

### Preparation (do this during Phase 0, before any destructive step)

On the x86 Ubuntu 22.04 host:

```bash
# Xiaomi's flashing prerequisites
sudo apt install device-tree-compiler nfs-common sshpass abootimg \
                 network-manager libxml2-utils

# Stop udisks (the wiki specifically calls this out)
sudo systemctl stop udisks2.service

# Populate Layer 4 on the backup drive
mkdir -p /media/backup/cyberdog-2026-04/layer4/jp4.5.1-bsp
cd /media/backup/cyberdog-2026-04/layer4/jp4.5.1-bsp

# NVIDIA L4T r32.5.2 (JetPack 4.5.1) BSP tarballs — URLs verified 2026-05-16.
# Note: filenames are jetson_linux_* (NOT jetson-210_* which is Nano/T210).
# 302 redirects to developer.download.nvidia.com/embedded/L4T/r32_Release_v5.2/T186/...
wget https://developer.nvidia.com/embedded/l4t/r32_release_v5.2/t186/jetson_linux_r32.5.2_aarch64.tbz2
wget https://developer.nvidia.com/embedded/l4t/r32_release_v5.2/t186/tegra_linux_sample-root-filesystem_r32.5.2_aarch64.tbz2

# Unpack
sudo tar xpf jetson_linux_r32.5.2_aarch64.tbz2
cd Linux_for_Tegra/rootfs
sudo tar xpf ../../tegra_linux_sample-root-filesystem_r32.5.2_aarch64.tbz2
cd ..
sudo ./apply_binaries.sh
```

**Xiaomi flashall bundle.** ~~As of 2026-05-16, V1.0.0.94 is not publicly mirrored~~ — **superseded 2026-07-07: V1.0.0.94 IS publicly downloadable** (hash suffix published in MiRoboticsLab discussion #133; see `PHASE0_LAYER4_RUNBOOK.md` §3). **Factory reset is now simply the V1.0.0.94 `flashall.sh`** — byte-exact for this dog. The V1.0.0.66 procedure below is retained ONLY as the fallback of last resort (e.g., CDN dies before the download happens):

```bash
cd /media/backup/cyberdog-2026-04/layer4/
# Public V1.0.0.66 baseline (2021.08.24 build, ~3 GB)
wget https://cdn.cnbj2m.fds.api.mi-img.com/cyberdog-package/build/athena_foxy_2021.08.24_emmc_nvme_V1.0.0.66.20210824_release_bbcc37a86a.tgz
sha256sum athena_foxy_2021.08.24_emmc_nvme_V1.0.0.66.20210824_release_bbcc37a86a.tgz \
  > athena_foxy_V1.0.0.66.sha256
tar xzf athena_foxy_2021.08.24_emmc_nvme_V1.0.0.66.20210824_release_bbcc37a86a.tgz
# Contains flashall.sh tailored for tegra194-mi-k91
```

**Why this is acceptable.** A V1.0.0.66 factory flash, then immediate restore of Layer 1 (`opt-ros2-cyberdog.tar.zst` — our actual V1.0.0.94 closed userspace) and Layer 0 (`params-emmc-p12.img` — IRREPLACEABLE factory calibration) will produce a system functionally equivalent to V1.0.0.94 at the userspace level. Bootloader differs (V1.0.0.66 BL vs the V1.0.0.94 BL preserved in Layer 4b — see below); restore the V1.0.0.94 BL via the in-place OTA mechanism after the system boots, or accept the V1.0.0.66 BL since it's still a JP4.5.1-class L4T r32.5.x bootloader.

### Layer 4b — preserve V1.0.0.94 bootloader payloads (run on the dog)

The dog ships actual V1.0.0.94 NVIDIA bootloader OTA payloads under `/opt/ota_package/t19x/`. These are not on any public mirror and are critical for bringing a V1.0.0.66 baseline back to V1.0.0.94 BL parity:

```bash
# On the dog, with /mnt/backup mounted:
mkdir -p /mnt/backup/cyberdog-2026-04/layer4b-v94-bl
sudo cp -av /opt/ota_package/t19x /mnt/backup/cyberdog-2026-04/layer4b-v94-bl/
sudo cp -av /opt/ota_package/t18x /mnt/backup/cyberdog-2026-04/layer4b-v94-bl/  # MCU side, smaller
sha256sum /mnt/backup/cyberdog-2026-04/layer4b-v94-bl/t19x/* \
          /mnt/backup/cyberdog-2026-04/layer4b-v94-bl/t18x/* \
  | sudo tee /mnt/backup/cyberdog-2026-04/layer4b-v94-bl/SHA256SUMS
sync
```

Total ~135 MB; covers `bl_only_payload`, `bl_update_payload`, `xusb_only_payload` per chip. Reapply post-flash via the existing `robot_update` / `athena_update.sh` path on the recovered dog.

### Full factory flash (only when everything else has failed)

With the dog in recovery mode:

```bash
cd /media/backup/cyberdog-2026-04/layer4/athena_foxy_2021.08.24_emmc_nvme_V1.0.0.66*/
sudo ./flashall.sh
# Takes ~30-45 min; do not disconnect power or USB.
# This produces a V1.0.0.66 baseline. After it boots, restore V1.0.0.94 userspace below.
```

After success, reinstall the `athena-*` packages from Layer 1 dpkg metadata:

```bash
# Dog is alive with sample rootfs; now restore CyberDog userspace
ssh mi@192.168.55.1 sudo mkdir -p /opt/ros2
scp /media/backup/cyberdog-2026-04/layer1/opt-ros2-cyberdog.tar.zst mi@192.168.55.1:/tmp/
ssh mi@192.168.55.1 sudo tar --xattrs --acls --numeric-owner \
  -I 'zstd -T0 -d' -xf /tmp/opt-ros2-cyberdog.tar.zst -C /
# Restore systemd units from /etc/systemd/system copy in Layer 1 etc-cyberdog-configs.tar.zst
# Then systemctl daemon-reload && systemctl enable cyberdog_ros2 ...
```

Restore `/params` last:

```bash
ssh mi@192.168.55.1 "sudo dd of=/dev/mmcblk0p12 bs=1M conv=fsync" \
  < /media/backup/cyberdog-2026-04/layer0/params-emmc-p12.img
```

## 6. Rescue drill (non-destructive, run once before Phase 2)

Confirms Layer 2 can actually be restored. Do this on the x86 host:

```bash
# 1. Create a loopback image of the target size
truncate -s 20G /tmp/rescue-test.img
mkfs.ext4 -F -L RESCUE_TEST /tmp/rescue-test.img

# 2. Loop-mount
sudo mkdir -p /mnt/rescue
sudo mount -o loop /tmp/rescue-test.img /mnt/rescue

# 3. Restore Layer 2
sudo tar --xattrs --acls --numeric-owner \
  -I 'zstd -T0 -d' \
  -xf /media/backup/cyberdog-2026-04/layer2/rootfs-nvme.tar.zst \
  -C /mnt/rescue

# 4. qemu-aarch64 chroot (requires qemu-user-static binfmt-support)
sudo apt install qemu-user-static binfmt-support
sudo cp /usr/bin/qemu-aarch64-static /mnt/rescue/usr/bin/
sudo chroot /mnt/rescue /usr/bin/qemu-aarch64-static /bin/bash -c 'cat /etc/os-release; uname -a; dpkg -l | grep athena | head'

# 5. Clean up
sudo umount /mnt/rescue
rm /tmp/rescue-test.img
```

Success criterion: chroot prints `Ubuntu 18.04.6 LTS` and lists the `athena-*` packages. If this works, the backup is proven restorable.

## 7. Non-destructive `LABEL second` extlinux test (brick-risk mitigation)

> **2026-07-07: SUPERSEDED by Phase 0.5** (review D2). This test was run on
> 2026-04-25 with negative results — but it edited only the NVMe copy of
> `extlinux.conf`, and a second copy on eMMC APP p1 may be the one cboot reads
> (`PLAN_REVIEW_2026-07-07.md` §2.3). Use the Phase 0.5 marker-bootarg +
> FDT-model-string procedure instead of the below.

This must pass before Phase 2 partition surgery is attempted. The whole NVMe dual-rootfs plan depends on CyberDog's cboot honoring extlinux label selection.

### Preparation

```bash
# On the dog, backup the original (already done in Layer 0)
sudo cp /boot/extlinux/extlinux.conf /boot/extlinux/extlinux.conf.pre-test
```

### The test

Edit `/boot/extlinux/extlinux.conf` to add a `LABEL second` that points at the **same** current kernel (so even if the label is selected, the system comes up identically):

```
TIMEOUT 30
DEFAULT primary

MENU TITLE L4T boot options

LABEL primary
      MENU LABEL primary kernel
      LINUX /boot/Image
      INITRD /boot/initrd
      APPEND ${cbootargs} quiet root=/dev/nvme0n1p1 rw rootwait rootfstype=ext4 console=ttyTCU0,115200n8 console=tty0 fbcon=map:0 net.ifnames=0

LABEL second
      MENU LABEL second (TEST — identical to primary)
      LINUX /boot/Image
      INITRD /boot/initrd
      APPEND ${cbootargs} quiet root=/dev/nvme0n1p1 rw rootwait rootfstype=ext4 console=ttyTCU0,115200n8 console=tty0 fbcon=map:0 net.ifnames=0 cyberdog.test=second
```

The extra `cyberdog.test=second` bootarg is visible in `/proc/cmdline` — that's how we verify which label actually booted.

### Execute

Connect a USB-to-TTL-serial cable to `ttyTCU0` (the debug UART on the dog's PCB) and run `screen /dev/ttyUSB0 115200` on the host so we can see the boot menu.

1. Reboot: `sudo reboot`
2. At the extlinux prompt (30 s timeout), type `2` or `second` + Enter.
3. After boot, verify: `cat /proc/cmdline | grep cyberdog.test` should show `cyberdog.test=second`.
4. Reboot again, let the timeout expire → `primary` should be selected by default, `/proc/cmdline` should **not** contain the test bootarg.
5. Revert: `sudo cp /boot/extlinux/extlinux.conf.pre-test /boot/extlinux/extlinux.conf`.

### Pass criteria

| Step | Expected |
|---|---|
| 1 | Extlinux prompt visible on serial console |
| 2 | Menu accepts `second` selection |
| 3 | `cyberdog.test=second` in cmdline after explicit `second` boot |
| 4 | Default-timeout boot does NOT contain the test bootarg |

If any step fails, the NVMe-dual-rootfs plan collapses and we fall back to the eMMC A/B `nvbootctrl` path (higher risk — see main plan §10).

If you can't get a serial cable:

- Alternative verification: add `cyberdog.test=second` to the `second` bootargs as above. If you boot and see that string in `/proc/cmdline`, the label was honored. If you can't reach the prompt to select `second`, temporarily set `DEFAULT second` for a single reboot and check the cmdline that way. (Riskier: if `second` fails to boot, you're stuck on the wrong default.)

## 8. Backup drive hygiene

- The backup drive stays mounted at `/mnt/backup/` on the dog's JP4.5 system during Phase 0. Unmount cleanly before unplugging: `sudo umount /mnt/backup`.
- Verify integrity occasionally:

```bash
zstd -t /mnt/backup/cyberdog-2026-04/layer2/rootfs-nvme.tar.zst
zstd -t /mnt/backup/cyberdog-2026-04/layer3/emmc-full.img.zst
sha256sum -c /mnt/backup/cyberdog-2026-04/layer0/params-emmc-p12.img.sha256
```

- Before Phase 2 starts, **physically copy the entire backup drive contents to at least one other medium** (another USB drive or the x86 host). Single-medium backups are single points of failure.
