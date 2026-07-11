# Phase 0 — Layer 4 + rescue drill runbook

Self-contained x86 host runbook. Run on the **Ubuntu 22.04 PC** (per project constraints). When complete, Phase 0 is done and Phase 1 (x86 dev env build-out) can start.

> **State as of 2026-05-16.** All public URLs in this document were verified live by `WebFetch` 302/HEAD probes. Re-verify before starting if more than ~3 months have passed — NVIDIA archive mirrors have moved before, and Xiaomi's CDN bucket policy could change.
>
> **Update 2026-07-07 (see `PLAN_REVIEW_2026-07-07.md`).** All URLs re-verified live. Three changes: (1) **V1.0.0.94 — the dog's exact firmware — IS publicly downloadable** (§3; the May "not publicly mirrored" conclusion was wrong); (2) **JetPack 5 EOL is Q3 2026** → new §2b mirrors the r35.6.4 target artifacts NOW; (3) new §4c replicates the **Layer 3b QSPI/bootloader dumps** captured on-dog 2026-07-07. V1.0.0.66 is 5.08 GB, not 3 GB.

## 0. What this runbook produces

| Path on backup SSD | Origin | Approx size | Purpose |
|---|---|---|---|
| `cyberdog-2026-04/layer4/jp4.5.1-bsp/Linux_for_Tegra/` | NVIDIA (public) | ~5 GB | Base BSP for any reflash; also Phase 3 starting point |
| `cyberdog-2026-04/layer4/athena_foxy_2022.01.14_*_V1.0.0.94_*.tgz` | Xiaomi CDN (public — see §3) | **5.06 GB** | **EXACT stock firmware** — primary factory-reset path |
| `cyberdog-2026-04/layer4/athena_foxy_2021.08.24_*_V1.0.0.66_*.tgz` | Xiaomi CDN (public) | 5.08 GB | Secondary baseline (kept for redundancy) |
| `cyberdog-2026-04/layer4b-v94-bl/{t18x,t19x}/` | dog `/opt/ota_package/` (private) | ~135 MB | V1.0.0.94 bootloader OTA payloads (no longer load-bearing now that the full V1.0.0.94 tgz is in hand, but cheap — still capture) |
| `cyberdog-2026-04/layer3b/` | dog `~/cyberdog-forensics-2026-04-22/qspi-boot-dump-2026-07-07/` | 40 MB | **QSPI NOR (32 MiB) + eMMC boot0/1** — the real bootloader home; exact-state brick recovery (§4c) |
| `cyberdog-2026-04/jp5-mirror/` | NVIDIA (public, **EOL Q3 2026**) | ~13 GB | r35.6.4 (+r32.5.2 already in layer4) BSP/rootfs/sources + apt snapshot + cp38 wheels (§2b) |
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

## 2b. Mirror-now — JP5 target artifacts (⚠️ JetPack 5 EOL Q3 2026)

Everything the port depends on, downloaded while NVIDIA still serves it anonymously
(all URLs verified 200 OK on 2026-07-07):

```bash
mkdir -p /media/backup/cyberdog-2026-04/jp5-mirror && cd $_

# Jetson Linux r35.6.4 (JetPack 5.1.6 — the FINAL release for Xavier NX)
wget https://developer.nvidia.com/downloads/embedded/l4t/r35_release_v6.4/release/jetson_linux_r35.6.4_aarch64.tbz2
wget https://developer.nvidia.com/downloads/embedded/l4t/r35_release_v6.4/release/tegra_linux_sample-root-filesystem_r35.6.4_aarch64.tbz2
wget https://developer.nvidia.com/downloads/embedded/l4t/r35_release_v6.4/sources/public_sources.tbz2

# JetPack apt repo snapshot (CUDA/TensorRT/etc. debs for r35.6)
# NOTE: sample-rootfs r35.6.2 URL quirk if ever needed: it has NO /release/ segment.
apt-mirror-or-wget-r repo.download.nvidia.com/jetson/{common,t194}/dists/r35.6   # ~see review §3.1

# Final JP5 python wheels (cp38; Jetson Zoo is bot-walled now)
wget 'https://developer.download.nvidia.com/compute/redist/jp/v512/pytorch/torch-2.1.0a0+41361538.nv23.06-cp38-cp38-linux_aarch64.whl'
# onnxruntime-gpu 1.16.x cp38: github.com/ykawa2/onnxruntime-gpu-for-jetson releases

sha256sum * | tee SHA256SUMS
```

Also `git clone --mirror`: `zbwu/athena_l4t_{sdk,kernel,nvidia,jakku_dts}`,
`MiRoboticsLab/cyberdog_tegra_kernel`, `MiRoboticsLab/cyberdog_{locomotion,motor_sdk,ros2,ws}`,
`morrownr/8821cu-20210916`.

## 3. Layer 4 download — Xiaomi factory firmware (V1.0.0.94 primary)

**2026-07-07: the exact stock firmware IS publicly served.** The build-hash suffixes
were published by the official `mi-CyberDog` account in
[MiRoboticsLab/cyberdog_ros2 discussion #133](https://github.com/MiRoboticsLab/cyberdog_ros2/discussions/133);
HEAD-verified 200 OK tonight:

```bash
cd /media/backup/cyberdog-2026-04/layer4/

# PRIMARY: V1.0.0.94 (2022.01.14) — byte-exact match for this dog's firmware, 5.06 GB
wget http://cdn.cnbj2m.fds.api.mi-img.com/cyberdog-package/build/athena_foxy_2022.01.14_emmc_nvme_V1.0.0.94_release_b1b4a851ca.tgz
md5sum athena_foxy_2022.01.14_*.tgz    # expect b1b4a851ca59c19956b0039de316ee41

# SECONDARY: V1.0.0.66 (2021.08.24) baseline, 5.08 GB — redundancy is cheap
wget https://cdn.cnbj2m.fds.api.mi-img.com/cyberdog-package/build/athena_foxy_2021.08.24_emmc_nvme_V1.0.0.66.20210824_release_bbcc37a86a.tgz
# (V1.0.0.82 2021.09.26 also exists: ..._V1.0.0.82_release_45bed14190.tgz)

sha256sum athena_foxy_*.tgz | tee -a SHA256SUMS
tar xzf athena_foxy_2022.01.14_emmc_nvme_V1.0.0.94_release_b1b4a851ca.tgz
ls athena_foxy_2022.01.14*/flashall.sh   # verify present
```

With V1.0.0.94 in hand, the old recovery contortion ("V1.0.0.66 factory flash +
Layer 1 userspace restore + Layer 4b BL re-apply") is **retired as primary path** —
factory reset is simply the V1.0.0.94 `flashall.sh`. Keep the old procedure in
`PHASE0_RECOVERY_PROCEDURES.md` as the fallback of last resort should the CDN die
before you download (it has survived 4.5 years; do not test that luck — download tonight).

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

## 4c. Layer 3b — replicate the QSPI/bootloader dumps (run on the dog, same SSD session)

Captured on-dog 2026-07-07 (review §2.2): the bootloader (MB1/MB2/cboot/BCT) lives on
**QSPI NOR** (`/dev/mtdblock0`), which Layers 0–4 never covered. Replicate the dumps:

```bash
mkdir -p /mnt/backup/cyberdog-2026-04/layer3b
cp -av ~/cyberdog-forensics-2026-04-22/qspi-boot-dump-2026-07-07/* \
      /mnt/backup/cyberdog-2026-04/layer3b/
( cd /mnt/backup/cyberdog-2026-04/layer3b && sha256sum -c SHA256SUMS )
sync
```

Expected: `qspi-mtdblock0.img` (32 MiB, sha256 `9820ec…`), `emmc-boot0.img` =
`emmc-boot1.img` (4 MiB, sha256 `bb9f8d…`). This is the *exact-state* bootloader
restore source — preferred over any factory-version reflash for "bootloader
corrupted" scenarios (no version/ratchet questions).

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

Before tagging `v0.1-phase0-complete` and starting Phase 1. **Progress 2026-07-09:**
mirror + Layer 3b + Layer 4b now replicated to the SSD (`tools/replicate-to-ssd.sh`,
all SHA256-verified); rescue drill run natively on-dog (`tools/rescue-drill-native.sh`).

- [x] **V1.0.0.94 downloaded, MD5 `b1b4a851ca59c19956b0039de316ee41` ✓** + V1.0.0.66 ✓ — on SSD `mirror-2026-07/firmware/`
- [~] **jp5-mirror: r35.6.4 trio ✓ + r32.5.2 pair ✓ + cp38 wheels ✓ + 14 repo mirrors ✓** — on SSD, SHA256-verified. **Still TODO: apt-repo snapshot** of `repo.download.nvidia.com/jetson/{common,t194}/dists/r35.6` (CUDA/TensorRT debs) — deferred to Phase 1 host setup (installable from NVIDIA apt at build time; not a one-shot big artifact at EOL risk)
- [x] **Layer 4b BL payloads copied to SSD, SHA256SUMS validated ✓**
- [x] **Layer 3b QSPI/boot0/1 dumps replicated to SSD, SHA256SUMS validated ✓** (§4c)
- [x] **`RESCUE_DRILL_RESULT.txt` = PASS (2026-07-09)** — layer2 restored to loopback in 144 s: `Ubuntu 18.04.6 LTS` ✓, `athena-version 1.0.0.94` ✓, 6 athena pkgs, `/opt/ros2/cyberdog` + keystone `.so` intact, 312,020 files. Dog-native (arm64) file-level verify; loopback auto-cleaned. Result saved to SSD.
- [x] **r32.5.2 BSP unpacked + apply_binaries DONE (2026-07-11)** on x86 SSD `phase1-work/Linux_for_Tegra/`. Gives stock `flash.sh` + recovery plumbing. (Stock r32.5.2 has NO `l4t_initrd_flash.sh` — only NFS scripts.)
- [x] **V94 firmware unpacked + reflash capability CONFIRMED (2026-07-11)**. `flashall.sh` (173 B wrapper) calls **Xiaomi's own `tools/kernel_flash/l4t_initrd_flash.sh --flash-only -c external_storage_layout_nvme.xml --external-device nvme0n1p1 jetson-xavier-nx-devkit-... nvme0n1p1`** — Xiaomi bundled initrd-flash into the V94 package (stock r32.5.2 lacks it). k91 board confs present (`p3509-...-mi-k91-qspi-emmc.conf`, `p3668-mi-k91.conf.common`); `bootloader/` 720M (recovery.img/boot0.img); `tools/` 12G holds the prebuilt NVMe rootfs image (that's why `rootfs/` is only 332K — CyberDog rootfs lives on NVMe, flashed from prebuilt image). **Reflash-from-RCM capability = the second half of step4's safety net → step4 preconditions now met.**
- [x] **Backup-of-backup DONE (2026-07-11)** — core layers (layer0/1/2/3b/4b, 6.3 GB) rsync'd to x86 `~/cyberdog-backup-mirror/`, verified (layer2 zstd -t; layer3b/4b sha256 -c). 2 physical media now. *Excluded by design:* layer3 (15 GB eMMC dump — SSD-only, acceptable; params already in layer0) and mirror-2026-07 (19 GB — dog NVMe holds a 2nd copy).
- [x] **Recovery-mode drill DONE (2026-07-10)** — `sudo reboot --force forced-recovery` (triggered over Wi-Fi) → x86 host enumerated `0955:7e19` APX with a plain USB-A→C data cable. **Recovery works WITHOUT the lost factory cable.** Dog power-cycled back to JP4.5 cleanly. *(Second half of the safety net — actually reflashing from RCM — still needs the Phase-1 x86 toolchain; that's why boot-risky step4 waits for Phase 1.)*
- [ ] MCU power-gating capture on JP4 side (review D7) — **needs owner** to trigger motion
- [ ] Tag `v0.1-phase0-complete && git push --tags`
- [ ] **Then Phase 0.5 (boot-path disambiguation — review D2) before any Phase 2 work**

## 8. What's next (Phase 1 preview)

Phase 1 (x86 host dev environment) — `JETPACK5_HUMBLE_PORT_PLAN.md` §9 — sets up the cross-build toolchain, ROS 2 Humble x86 dev install, and r35.6.2 BSP source tree alongside the r32.5.2 one. None of it touches the dog. Expect ~3 evenings.

The first thing Phase 1 actually does is rebuild the same r32.5.2 BSP with `flash.sh --no-flash` to confirm the host can drive Tegra flashing end-to-end *before* introducing the much larger r35.6.2 source tree. That's the cheapest possible smoke-test of the host.
