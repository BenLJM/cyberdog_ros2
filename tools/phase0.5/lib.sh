# Shared helpers for Phase 0.5 — sourced by the step scripts. Not run directly.
set -euo pipefail
P05=/home/mi/phase0.5
BK=$P05/backups
mkdir -p "$BK"

NVME_CONF=/boot/extlinux/extlinux.conf
EMMC_MNT=/mnt/emmc-app
EMMC_CONF=$EMMC_MNT/boot/extlinux/extlinux.conf

mount_emmc_rw() { sudo mkdir -p $EMMC_MNT; mountpoint -q $EMMC_MNT || sudo mount /dev/mmcblk0p1 $EMMC_MNT; }
umount_emmc()   { if mountpoint -q $EMMC_MNT; then sync; sudo umount $EMMC_MNT; fi }

backup_once() { # args: live-file backup-name  (never overwrites an existing backup)
  if [ ! -f "$BK/$2" ]; then sudo cp -a "$1" "$BK/$2"; echo "backed up: $1 -> $BK/$2"; fi
}

edit_conf() { # args: conf-file awk-program description  — atomic, with sanity asserts
  local f=$1 prog=$2 desc=$3 tmp
  tmp=$(mktemp)
  sudo awk "$prog" "$f" > "$tmp"
  grep -q '^LABEL primary' "$tmp" || { echo "SANITY FAIL ($desc): LABEL primary missing — ABORTED, $f untouched"; rm -f "$tmp"; exit 1; }
  grep -q '^TIMEOUT'       "$tmp" || { echo "SANITY FAIL ($desc): TIMEOUT missing — ABORTED, $f untouched"; rm -f "$tmp"; exit 1; }
  echo "--- change to $f:"; diff "$f" "$tmp" || true
  sudo cp "$tmp" "$f.p05tmp" && sudo mv "$f.p05tmp" "$f" && sync
  rm -f "$tmp"
  echo "applied: $desc"
}

add_marker() { # args: conf-file label marker  — append marker to that label's APPEND line
  local f=$1 label=$2 marker=$3
  if sudo grep -q -- "$marker" "$f"; then echo "marker $marker already present in $f — nothing to do"; return 0; fi
  edit_conf "$f" '
    /^LABEL / { inblk = ($2 == "'"$label"'") }
    inblk && $1 == "APPEND" { sub(/[ \t]*$/, ""); $0 = $0 " '"$marker"'" }
    { print }
  ' "add $marker to LABEL $label"
  [ "$(sudo grep -c -- "$marker" "$f")" -eq 1 ] || { echo "POST-CHECK FAIL: marker count != 1 in $f — run ./revert-all.sh"; exit 1; }
}

set_default() { # args: conf-file label
  local f=$1 d=$2
  edit_conf "$f" '{ if ($1 == "DEFAULT") print "DEFAULT '"$d"'"; else print }' "DEFAULT -> $d"
}

add_fdt_line() { # args: conf-file  — insert FDT line into primary block after INITRD
  local f=$1
  if sudo grep -q '^[ \t]*FDT ' "$f"; then echo "FDT line already present in $f — nothing to do"; return 0; fi
  edit_conf "$f" '
    /^LABEL / { inblk = ($2 == "primary") }
    { print }
    inblk && $1 == "INITRD" { print "      FDT /boot/dtb-fdttest.dtb" }
  ' "add FDT /boot/dtb-fdttest.dtb to LABEL primary"
}
