#!/bin/bash
# =============================================================================
#  NVCSI 电源域变体 部署 / 回滚      用法: deploy-variant.sh <A|B|C|revert|status>
#  在狗上以 root 执行。**不自动重启** —— 重启由人决定。
#
#  A      = 只换 DTB（Image 一字节不动）
#  B      = 只换 Image（DTB 一字节不动）
#  revert = 把两者都还原成 .pre-variant 备份
#  status = 只看当前装的是什么
#
#  ⚠️ 做实验前请确认 USB 下载线**插着**：万一 probe 挂死需要拔电，
#     USB 插着断电会进 RCM —— 在这个场景下这正是我们要的（RCM 才能救砖）。
# =============================================================================
set -euo pipefail

P1=/mnt/emmcp1
BOOT=$P1/boot-jp5
STAGE=/tmp/nvcsi-variants

# 🔴 构建时锁定的期望校验和。**部署前必须逐字节核对。**
# 2026-07-27 实测教训：33MB 的 Image 走 WiFi scp 被超时打断，狗上留下一个
# 57% 的残缺文件（19496960 / 34155008 字节）。没有校验就把它刷进 /boot-jp5
# 等于当场变砖，而且是「内核在到达 initrd 之前就死」那一类——
# initrd 里的自动回滚守卫**够不着**，只能走 RCM 救砖。
EXPECT_A_DTB=dd9a7350406abd0ab64a3634c647f079740b1ac81f9551ca42698efc7ada88b3
EXPECT_B_IMG=bdf077cf39673adb237452413bab26795bb1eb1157a9fbffe3c5e6c45493bdcc
# 变体 C = 0002 + 运行时开关版 0003（默认关），故意不含 0004
EXPECT_C_IMG=f4693ce5c0baf619173acfbd51da23dfe83a77639a79fee1b7715d02a8fc47e2  # C2: 修 LOCALVERSION 后重建

mount | grep -q "$P1" || { mkdir -p $P1; mount /dev/mmcblk0p1 $P1; }

sha() { sha256sum "$1" 2>/dev/null | cut -c1-16; }

# 校验暂存件：文件在 + 校验和逐字符相符，否则拒绝部署
verify() {
    local f="$1" want="$2" name="$3"
    [ -f "$f" ] || { echo "FATAL: 缺 $f"; exit 1; }
    local got
    got=$(sha256sum "$f" | awk '{print $1}')
    if [ "$got" != "$want" ]; then
        echo "FATAL: $name 校验和不符 —— 拒绝部署"
        echo "  期望 $want"
        echo "  实际 $got  ($(stat -c %s "$f") 字节)"
        echo "  → 多半是传输被打断。重新 scp 完整文件后再来。"
        exit 1
    fi
    echo "  ✅ $name 校验通过 ($(stat -c %s "$f") 字节)"
}

status() {
    echo "════ 当前 /boot-jp5 ════"
    printf "  %-28s %s  %s\n" "Image"    "$(sha $BOOT/Image)"    "$(stat -c %s $BOOT/Image) 字节"
    printf "  %-28s %s  %s\n" "DTB"      "$(sha $BOOT/tegra194-mi-k91.dtb)" "$(stat -c %s $BOOT/tegra194-mi-k91.dtb) 字节"
    echo "  --- 备份 ---"
    for f in $BOOT/Image.pre-variant $BOOT/tegra194-mi-k91.dtb.pre-variant; do
        [ -f "$f" ] && printf "  %-28s %s\n" "$(basename $f)" "$(sha $f)" || printf "  %-28s (无)\n" "$(basename $f)"
    done
    echo "  --- 变体参考校验和 ---"
    echo "    变体A DTB   dd9a735040 6abd0ab6"
    echo "    变体B Image bdf077cf39 673adb23"
    echo "    变体C Image 8bc45ee7f8 d4fd1ffd"
    echo "    good  DTB   $(sha $BOOT/tegra194-mi-k91.dtb.pre-variant 2>/dev/null || echo '(尚未备份)')"
}

case "${1:-status}" in
A)
    verify "$STAGE/A-dtonly/tegra194-mi-k91.dtb" "$EXPECT_A_DTB" "变体A DTB"
    [ -f "$BOOT/tegra194-mi-k91.dtb.pre-variant" ] || cp -a "$BOOT/tegra194-mi-k91.dtb" "$BOOT/tegra194-mi-k91.dtb.pre-variant"
    cp "$STAGE/A-dtonly/tegra194-mi-k91.dtb" "$BOOT/tegra194-mi-k91.dtb"
    sync
    verify "$BOOT/tegra194-mi-k91.dtb" "$EXPECT_A_DTB" "落盘后复校 DTB"
    echo "✅ 变体 A 已部署（只换了 DTB，Image 未动）"
    status
    echo
    echo "下一步：reboot。挂死的话 → 拔电重启（USB 插着会进 RCM，用 RCM 刷回）"
    ;;
B)
    verify "$STAGE/B-conly/Image" "$EXPECT_B_IMG" "变体B Image"
    [ -f "$BOOT/Image.pre-variant" ] || cp -a "$BOOT/Image" "$BOOT/Image.pre-variant"
    cp "$STAGE/B-conly/Image" "$BOOT/Image"
    sync
    verify "$BOOT/Image" "$EXPECT_B_IMG" "落盘后复校 Image"
    echo "✅ 变体 B 已部署（只换了 Image，DTB 未动）"
    status
    echo
    echo "下一步：reboot。挂死的话 → 拔电重启（USB 插着会进 RCM，用 RCM 刷回）"
    ;;
C)
    verify "$STAGE/C-gated/Image" "$EXPECT_C_IMG" "变体C Image"
    [ -f "$BOOT/Image.pre-variant" ] || cp -a "$BOOT/Image" "$BOOT/Image.pre-variant"
    cp "$STAGE/C-gated/Image" "$BOOT/Image"
    sync
    verify "$BOOT/Image" "$EXPECT_C_IMG" "落盘后复校 Image"
    echo "✅ 变体 C 已部署（只换 Image；开关默认关，预期能正常启动）"
    status
    echo
    echo "下一步：reboot。起来后武装实验："
    echo "  echo 1 | sudo tee /sys/module/tegra_camera_rtcpu/parameters/r32_camera_power"
    ;;
revert)
    n=0
    [ -f "$BOOT/Image.pre-variant" ] && { cp "$BOOT/Image.pre-variant" "$BOOT/Image"; n=$((n+1)); echo "  已还原 Image"; }
    [ -f "$BOOT/tegra194-mi-k91.dtb.pre-variant" ] && { cp "$BOOT/tegra194-mi-k91.dtb.pre-variant" "$BOOT/tegra194-mi-k91.dtb"; n=$((n+1)); echo "  已还原 DTB"; }
    sync
    echo "✅ 还原了 $n 个文件"
    status
    ;;
status) status ;;
*) echo "用法: $0 <A|B|C|revert|status>"; exit 2 ;;
esac
