# Phase 0 — Layer 4 + rescue drill runbook

Self-contained x86 host runbook. Run on the **Ubuntu 22.04 PC** (per project constraints). When complete, Phase 0 is done and Phase 1 (x86 dev env build-out) can start.

> **State as of 2026-05-16.** All public URLs in this document were verified live by `WebFetch` 302/HEAD probes. Re-verify before starting if more than ~3 months have passed — NVIDIA archive mirrors have moved before, and Xiaomi's CDN bucket policy could change.

## 0. What this runbook produces

| Path on backup SSD | Origin | Approx size | Purpose |
|---|---|---|---|
| `cyberdog-2026-04/layer4/jp4.5.1-bsp/Linux_for_Tegra/` | NVIDIA (public) | ~5 GB | Base BSP for any reflash; also Phase 3 starting point |
| `cyberdog-2026-04/layer4/athena_foxy_*_V1.0.0.66*/` | Xiaomi CDN (public V1.0.0.66) | ~3 GB | `flashall.sh` factory baseline — only fallback Xiaomi publishes |
| `cyberdog-2026-04/layer4b-v94-bl/{t18x,t19x}/` | dog `/opt/ota_package/` (private) | ~135 MB | V1.0.0.94 bootloader payloads to upgrade post-flash |
| `cyberdog-2026-04/layer4/RESCUE_DRILL_RESULT.txt` | rescue drill output | <1 KB | Proof that Layer 2 is restorable end-to-end |

After this runbook, the only way to brick the dog without recovery is total physical destruction or losing the backup SSD.

## 1. Prerequisites on the x86 host

```bash
# Disk: need ~25 GB free for BSP, sample rootfs unpack, and rescue loopback
df -h ~ /tmp

# Required packages (Xiaomi flashall.sh prerequisites + NVIDIA + rescue drill)
sudo apt update
sudo apt install -y \
  device-tree-compiler nfs-common sshpass abootimg \
  network-manager libxml2-utils \
  qemu-user-static binfmt-support \
  zstd wget ca-certificates

# Stop udisks (Xiaomi wiki specifically calls this out — auto-mount races flashall.sh)
sudo systemctl stop udisks2.service
sudo systemctl mask udisks2.service  # re-enable after Phase 4
```

Attach the backup SSD (label `CYBERDOG_BACKUP`):

```bash
sudo mkdir -p /media/backup
sudo mount /dev/disk/by-label/CYBERDOG_BACKUP /media/backup
ls /media/backup/cyberdog-2026-04/layer{0,1,2,3}  # sanity check existing layers present
```

## 2. Layer 4 download — NVIDIA L4T r32.5.2 BSP

```bash
mkdir -p /media/backup/cyberdog-2026-04/layer4/jp4.5.1-bsp
cd /media/backup/cyberdog-2026-04/layer4/jp4.5.1-bsp

# Both URLs 302 → developer.download.nvidia.com/embedded/L4T/r32_Release_v5.2/T186/
# Filenames are jetson_linux_* (NOT jetson-210_* — that's T210/Nano).
wget --content-disposition \
  https://developer.nvidia.com/embedded/l4t/r32_release_v5.2/t186/jetson_linux_r32.5.2_aarch64.tbz2
wget --content-disposition \
  https://developer.nvidia.com/embedded/l4t/r32_release_v5.2/t186/tegra_linux_sample-root-filesystem_r32.5.2_aarch64.tbz2

# Record actual hashes for future integrity checks
sha256sum *.tbz2 | tee SHA256SUMS

# Unpack
sudo tar xpf Jetson_Linux_R32.5.2_aarch64.tbz2          # creates Linux_for_Tegra/
cd Linux_for_Tegra/rootfs
sudo tar xpf ../../Tegra_Linux_Sample-Root-Filesystem_R32.5.2_aarch64.tbz2
cd ..
sudo ./apply_binaries.sh                                # ~5 min
```

(`wget --content-disposition` follows the 302 and saves with the canonical capitalised filename `Jetson_Linux_R32.5.2_aarch64.tbz2` etc. — adjust the unpack lines if your wget version names them differently.)

## 3. Layer 4 download — Xiaomi V1.0.0.66 baseline flashall

```bash
cd /media/backup/cyberdog-2026-04/layer4/

# This is the only publicly-mirrored Xiaomi factory bundle.
# V1.0.0.94 (the version on the dog) needs the build-hash suffix that we
# don't have publicly; we recover its userspace from Layer 1 + Layer 0 instead.
wget https://cdn.cnbj2m.fds.api.mi-img.com/cyberdog-package/build/athena_foxy_2021.08.24_emmc_nvme_V1.0.0.66.20210824_release_bbcc37a86a.tgz

sha256sum athena_foxy_*.tgz | tee -a SHA256SUMS
tar xzf athena_foxy_2021.08.24_emmc_nvme_V1.0.0.66.20210824_release_bbcc37a86a.tgz
ls athena_foxy_2021.08.24_emmc_nvme_V1.0.0.66*/flashall.sh   # verify present
```

If the download is dead by the time you run this, the most likely backup mirror is one of the community archives — search `MAVProxyUser` and `cyber-zoo` GitHub orgs for the filename. Failing that, the NVIDIA `flash.sh` from the BSP can produce a generic Xavier NX system, but it loses Xiaomi's `tegra194-mi-k91` device-tree blobs and partition layout — recovery would require a Phase 3 custom BSP build, which is much more work.

## 4. Layer 4b — capture V1.0.0.94 BL payloads (run on the dog, not the x86 host)

The dog's `/opt/ota_package/` holds the actual NVIDIA BL binaries used by V1.0.0.94. Not on any public mirror; harvest before any destructive step.

```bash
# SSH to the dog, with the SAME backup SSD mounted at /mnt/backup
mkdir -p /mnt/backup/cyberdog-2026-04/layer4b-v94-bl
sudo cp -av /opt/ota_package/t18x /mnt/backup/cyberdog-2026-04/layer4b-v94-bl/
sudo cp -av /opt/ota_package/t19x /mnt/backup/cyberdog-2026-04/layer4b-v94-bl/
( cd /mnt/backup/cyberdog-2026-04/layer4b-v94-bl &&
  sha256sum t18x/* t19x/* | sudo tee SHA256SUMS )
sync
```

Approximate sizes:
- `t19x/bl_update_payload` ~78 MB
- `t19x/bl_only_payload` ~33 MB
- `t19x/xusb_only_payload` ~125 KB
- `t18x/bl_update_payload` ~12 MB
- `t18x/bl_only_payload` ~9 MB

Move the SSD back to the x86 host before Section 5.

## 5. Rescue drill — prove Layer 2 is restorable

This is **non-destructive** and uses a 20 GB loopback file in `/tmp`. Total runtime ~15 min. Mandatory before Phase 2 partition surgery: a backup that hasn't been restored end-to-end is still hypothetical.

```bash
# 1. Loopback image
truncate -s 20G /tmp/rescue-test.img
mkfs.ext4 -F -L RESCUE_TEST /tmp/rescue-test.img
sudo mkdir -p /mnt/rescue
sudo mount -o loop /tmp/rescue-test.img /mnt/rescue

# 2. Restore Layer 2
time sudo tar --xattrs --acls --numeric-owner \
  -I 'zstd -T0 -d' \
  -xf /media/backup/cyberdog-2026-04/layer2/rootfs-nvme.tar.zst \
  -C /mnt/rescue

# 3. qemu-aarch64 chroot
sudo cp /usr/bin/qemu-aarch64-static /mnt/rescue/usr/bin/
sudo chroot /mnt/rescue /usr/bin/qemu-aarch64-static /bin/bash -c '
  echo "=== os-release ==="
  cat /etc/os-release
  echo "=== uname -a ==="
  uname -a
  echo "=== athena packages ==="
  dpkg -l | grep ^ii.*athena
  echo "=== athena_version output ==="
  /usr/bin/athena_version 2>&1 || true
  echo "=== /opt/ros2/cyberdog top ==="
  ls /opt/ros2/cyberdog/ | head
' | sudo tee /media/backup/cyberdog-2026-04/layer4/RESCUE_DRILL_RESULT.txt

# 4. Cleanup
sudo umount /mnt/rescue
rm /tmp/rescue-test.img
```

### Pass criteria

`RESCUE_DRILL_RESULT.txt` must contain:

- `Ubuntu 18.04.6 LTS` from `/etc/os-release`
- `aarch64` from `uname -a` (proves binfmt + qemu-static handoff worked)
- `ii  athena-version  1.0.0.94` from dpkg list — proves the **actual production version** restored
- `1.0.0.94` from `athena_version` (proves arm64 binary executed under qemu)
- `/opt/ros2/cyberdog/` populated

If any of these fail, **Phase 2 is blocked** until the failure is understood. Most common cause: missing `qemu-user-static` or `binfmt-support` — re-check Section 1.

## 6. Backup-of-backup (mandatory before Phase 2)

Single-medium backup is a single point of failure. Before Phase 2 starts, mirror the entire `/media/backup/cyberdog-2026-04/` to **at least one other medium** (second USB drive OR an x86-host directory):

```bash
# Option A: second USB drive (preferred — physically separate)
sudo rsync -aHAX --info=progress2 \
  /media/backup/cyberdog-2026-04/ \
  /media/backup-secondary/cyberdog-2026-04/
sync

# Option B: x86 host disk (acceptable if drive #2 unavailable)
sudo rsync -aHAX --info=progress2 \
  /media/backup/cyberdog-2026-04/ \
  ~/cyberdog-backup-mirror/
```

Then re-verify integrity on both copies:

```bash
for D in /media/backup /media/backup-secondary; do
  echo "=== $D ==="
  zstd -t $D/cyberdog-2026-04/layer2/rootfs-nvme.tar.zst
  zstd -t $D/cyberdog-2026-04/layer3/emmc-full.img.zst
  ( cd $D/cyberdog-2026-04/layer4 && sha256sum -c SHA256SUMS )
  ( cd $D/cyberdog-2026-04/layer4b-v94-bl && sha256sum -c SHA256SUMS )
done
```

## 7. Phase 0 sign-off checklist

Before tagging `v0.1-phase0-complete` and starting Phase 1:

- [ ] Layer 4 BSP unpacked, `apply_binaries.sh` ran clean
- [ ] Layer 4 V1.0.0.66 flashall bundle present, `flashall.sh` is `+x`
- [ ] Layer 4b BL payloads copied, SHA256SUMS validated
- [ ] `RESCUE_DRILL_RESULT.txt` shows `Ubuntu 18.04.6 LTS` + `1.0.0.94`
- [ ] Backup-of-backup completed, both copies verified
- [ ] PHASE0_BOOT_MECHANISM_FINDINGS.md `LABEL second` test result captured (already done 2026-04-25 — JP4↔JP5 switching is edit-in-place only)
- [ ] Tag commit on `docs/jetpack5-humble-port`: `git tag v0.1-phase0-complete && git push --tags`

## 8. What's next (Phase 1 preview)

Phase 1 (x86 host dev environment) — `JETPACK5_HUMBLE_PORT_PLAN.md` §9 — sets up the cross-build toolchain, ROS 2 Humble x86 dev install, and r35.6.2 BSP source tree alongside the r32.5.2 one. None of it touches the dog. Expect ~3 evenings.

The first thing Phase 1 actually does is rebuild the same r32.5.2 BSP with `flash.sh --no-flash` to confirm the host can drive Tegra flashing end-to-end *before* introducing the much larger r35.6.2 source tree. That's the cheapest possible smoke-test of the host.
