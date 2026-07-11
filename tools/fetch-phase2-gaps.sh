#!/bin/bash
# Fill the 2026-07-11 review's mirror gaps (JP5 EOL Q3 2026 — fetch now):
#   1. Voice-stack sources + models (Phase 8): whisper.cpp, kokoro-onnx (+model
#      files), kokoro-tts, openWakeWord, whisper ggml-small weights
#   2. JetPack r35.6 apt-repo snapshot (CUDA/cuDNN/TensorRT debs) for t194 +
#      common — EXCLUDING deepstream*/nsight* (huge, off critical path; logged)
# Resumable: re-run to continue. Verifies sha256 from the repo metadata.
set -uo pipefail
cd "$(dirname "$0")"
MIRROR=$PWD
FAIL=0

log() { echo "[$(date +%F' '%T)] $*"; }

# ---------------- 1. voice stack ----------------
mkdir -p repos wheels/voice-models
declare -A REPOS=(
    [whisper.cpp]=https://github.com/ggml-org/whisper.cpp
    [kokoro-onnx]=https://github.com/thewh1teagle/kokoro-onnx
    [kokoro-tts]=https://github.com/nazdridoy/kokoro-tts
    [openWakeWord]=https://github.com/dscripka/openWakeWord
)
for name in "${!REPOS[@]}"; do
    if [ -d "repos/$name.git" ]; then
        log "repo $name: updating"
        git -C "repos/$name.git" remote update --prune >/dev/null 2>&1 || { log "FAIL update $name"; FAIL=1; }
    else
        log "repo $name: cloning"
        git clone --mirror "${REPOS[$name]}" "repos/$name.git" || { log "FAIL clone $name"; FAIL=1; }
    fi
done

fetch_file() { # url dest
    local url=$1 dest=$2
    [ -s "$dest" ] && { log "have $(basename "$dest")"; return 0; }
    log "fetching $(basename "$dest")"
    wget -c -q --show-progress=off -O "$dest.part" "$url" && mv "$dest.part" "$dest" \
        || { log "FAIL $url"; FAIL=1; return 1; }
}
fetch_file https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/kokoro-v1.0.onnx wheels/voice-models/kokoro-v1.0.onnx
fetch_file https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/voices-v1.0.bin  wheels/voice-models/voices-v1.0.bin
fetch_file https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin wheels/voice-models/ggml-small.bin

# ---------------- 2. r35.6 apt repo snapshot ----------------
APT=$MIRROR/nvidia/apt-r35.6
mkdir -p "$APT"
BASE=https://repo.download.nvidia.com/jetson
EXCLUDE_RE='^(deepstream|nsight)'
for dist in common t194; do
    d="$APT/$dist"
    mkdir -p "$d"
    log "apt[$dist]: fetching Packages"
    wget -q -O "$d/Packages.gz" "$BASE/$dist/dists/r35.6/main/binary-arm64/Packages.gz" \
        || { log "FAIL Packages.gz $dist"; FAIL=1; continue; }
    gunzip -kf "$d/Packages.gz"
    # parse: Package / Filename / SHA256 / Size records
    awk -v RS='' -v OFS='\t' '{
        pkg=""; fn=""; sha=""; sz=""
        n=split($0, L, "\n")
        for (i=1;i<=n;i++) {
            if (L[i] ~ /^Package: /)  { pkg=substr(L[i],10) }
            if (L[i] ~ /^Filename: /) { fn=substr(L[i],11) }
            if (L[i] ~ /^SHA256: /)   { sha=substr(L[i],9) }
            if (L[i] ~ /^Size: /)     { sz=substr(L[i],7) }
        }
        if (pkg!="" && fn!="") print pkg, fn, sha, sz
    }' "$d/Packages" > "$d/manifest.tsv"
    total=$(awk -F'\t' '{s+=$4} END{printf "%.1f", s/1e9}' "$d/manifest.tsv")
    kept=$(awk -F'\t' -v re="$EXCLUDE_RE" '$1!~re {s+=$4} END{printf "%.1f", s/1e9}' "$d/manifest.tsv")
    log "apt[$dist]: $(wc -l < "$d/manifest.tsv") pkgs, ${total} GB total, ${kept} GB after excluding ${EXCLUDE_RE}"
    awk -F'\t' -v re="$EXCLUDE_RE" '$1~re {print "EXCLUDED: "$1" ("$4" bytes)"}' "$d/manifest.tsv"
    while IFS=$'\t' read -r pkg fn sha sz; do
        [[ "$pkg" =~ $EXCLUDE_RE ]] && continue
        dest="$d/$fn"
        if [ -f "$dest" ]; then
            got=$(sha256sum "$dest" | cut -d' ' -f1)
            [ "$got" = "$sha" ] && continue
            log "re-fetch (bad hash): $fn"
            rm -f "$dest"
        fi
        mkdir -p "$(dirname "$dest")"
        wget -c -q -O "$dest.part" "$BASE/$dist/$fn" || { log "FAIL $fn"; FAIL=1; continue; }
        mv "$dest.part" "$dest"
        got=$(sha256sum "$dest" | cut -d' ' -f1)
        [ "$got" = "$sha" ] || { log "HASH MISMATCH $fn"; FAIL=1; rm -f "$dest"; }
    done < "$d/manifest.tsv"
    log "apt[$dist]: done"
done

# ---------------- summary ----------------
log "sizes:"
du -sh repos/whisper.cpp.git repos/kokoro-onnx.git repos/kokoro-tts.git repos/openWakeWord.git \
      wheels/voice-models "$APT" 2>/dev/null
if [ "$FAIL" = 0 ]; then
    log "ALL OK — remember: re-run replicate-to-ssd.sh next time the SSD is attached"
else
    log "COMPLETED WITH FAILURES — grep FAIL above, re-run to resume"
fi
exit $FAIL
