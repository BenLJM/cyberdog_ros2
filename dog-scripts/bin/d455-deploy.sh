#!/bin/bash
# =============================================================================
#  D455 冷启自启 + 自愈: 部署 / 回滚脚本
#  在 **JP5 host(狗)** 上以 root 执行。文件先 scp 到 /tmp/d455-stage/。
#
#  Mac 侧:
#    cd /Users/ben/projects/cyberdog/dog-scripts
#    ssh mi@10.0.0.219 'mkdir -p /tmp/d455-stage/bin /tmp/d455-stage/systemd'
#    scp bin/d455-*.sh              mi@10.0.0.219:/tmp/d455-stage/bin/
#    scp systemd/d455-*.service systemd/d455-*.timer mi@10.0.0.219:/tmp/d455-stage/systemd/
#    ssh mi@10.0.0.219 'sudo bash /tmp/d455-stage/bin/d455-deploy.sh install'
#
#  回滚(一条命令, 不留残留):
#    ssh mi@10.0.0.219 'sudo bash /tmp/d455-stage/bin/d455-deploy.sh uninstall'
#  回滚后系统回到部署前状态: 相机不自启, 栈不受影响, rs-poc-run.sh 照旧能用。
#
#  ⚠️ 本脚本**不**重启栈、**不**重启机器, 也不动任何出厂 launch 文件。
# =============================================================================
set -eu
STAGE="$(cd "$(dirname "$0")/.." && pwd)"
ACTION="${1:-}"

install_it() {
  echo "== 安装脚本到 JP5 host =="
  install -m 0755 "$STAGE/bin/d455-camera.sh"  /usr/local/bin/d455-camera.sh
  install -m 0755 "$STAGE/bin/d455-doctor.sh"  /usr/local/bin/d455-doctor.sh
  install -m 0755 "$STAGE/bin/d455-verify.sh"  /usr/local/bin/d455-verify.sh

  echo "== 安装 inner 脚本到 chroot(JP4 rootfs) =="
  # 目录一定存在(是 mi 的家), 但保持 mkdir-在前/cp-在后/验证-在最后 的写法
  # —— 0724 那次 `cp x y || mkdir y` 把 8821cu.ko 漏掉的教训(LESSONS #29)
  mkdir -p /mnt/jp4/home/mi
  install -m 0755 "$STAGE/bin/d455-camera-inner.sh" /mnt/jp4/home/mi/d455-camera-inner.sh
  [ -x /mnt/jp4/home/mi/d455-camera-inner.sh ] || { echo "FATAL inner 脚本没装上"; exit 1; }

  echo "== 安装 systemd units =="
  install -m 0644 "$STAGE/systemd/d455-camera.service" /etc/systemd/system/d455-camera.service
  install -m 0644 "$STAGE/systemd/d455-doctor.service" /etc/systemd/system/d455-doctor.service
  install -m 0644 "$STAGE/systemd/d455-doctor.timer"   /etc/systemd/system/d455-doctor.timer
  systemctl daemon-reload

  echo "== 前置条件自检 =="
  ok=1
  [ -x /usr/local/bin/jp5-chroot-prep.sh ] || { echo "  !! 缺 jp5-chroot-prep.sh"; ok=0; }
  [ -x /mnt/jp4/opt/lrs-wrapper/lib/realsense2_camera/realsense2_camera_node ] \
    || { echo "  !! 缺 /opt/lrs-wrapper 包装器节点"; ok=0; }
  [ -e /etc/udev/rules.d/99-realsense-libusb.rules ] \
    || echo "  ~ 提醒: JP5 host 上没有 99-realsense-libusb.rules(/dev/video* 可能不是 0666)"
  [ -e /sys/bus/platform/devices/realsense_switch/state ] \
    || echo "  ~ 提醒: 找不到 realsense_switch(内核/DTB 变了?)"
  [ "$ok" -eq 1 ] || { echo "前置条件不满足, 先修再 enable"; exit 1; }

  echo "== enable(只登记自启, 不立即启动) =="
  systemctl enable d455-camera.service      # -> jp5-cyberdog-stack.service.wants/
  systemctl enable d455-doctor.timer
  echo
  echo "已 enable。现在**不会**自动起来 —— 手工验证请跑:"
  echo "    sudo systemctl start d455-camera.service && sleep 25 && sudo /usr/local/bin/d455-verify.sh"
  echo "冷启动/软重启后它会随 jp5-cyberdog-stack.service 一起起来。"
}

uninstall_it() {
  echo "== 停 + disable =="
  systemctl disable --now d455-doctor.timer 2>/dev/null || true
  systemctl stop    d455-doctor.service     2>/dev/null || true
  systemctl disable --now d455-camera.service 2>/dev/null || true
  echo "== 删文件 =="
  rm -f /etc/systemd/system/d455-camera.service \
        /etc/systemd/system/d455-doctor.service \
        /etc/systemd/system/d455-doctor.timer
  rm -f /etc/systemd/system/jp5-cyberdog-stack.service.wants/d455-camera.service
  rm -f /usr/local/bin/d455-camera.sh /usr/local/bin/d455-doctor.sh /usr/local/bin/d455-verify.sh
  rm -f /mnt/jp4/home/mi/d455-camera-inner.sh
  rm -rf /run/d455-camera /run/d455-doctor.miss
  systemctl daemon-reload
  echo "回滚完成。栈/出厂 launch 文件从头到尾没被碰过。"
}

sysctl_it() {
  # 独立一步, 因为它是**全局内核参数**, 影响面比相机大, 值得单独决策。
  # 内容=把 JP4 出厂 /etc/sysctl.conf 的 rmem 调优补回 JP5 host(移植漏项)。
  # 2026-07-26: 正常情况下**不需要跑这一步** —— /etc/sysctl.d/99-cyberdog.conf 已经做了。
  CUR=$(cat /proc/sys/net/core/rmem_max)
  if [ "$CUR" -ge 26214000 ]; then
    echo "net.core.rmem_max 已经是 $CUR (>=26214000), 无需安装。"
    grep -rl "rmem_max" /etc/sysctl.d/ 2>/dev/null | sed "s/^/  已由此文件提供: /"
    echo "不安装 60-cyberdog-dds.conf, 避免同一参数两处定义。"
    return 0
  fi
  echo "== rmem_max 只有 $CUR, 安装 DDS 大消息 sysctl(解锁 848x480) =="
  install -m 0644 "$STAGE/systemd/60-cyberdog-dds-sysctl.conf" /etc/sysctl.d/60-cyberdog-dds.conf
  sysctl --system >/dev/null
  echo "net.core.rmem_max = $(cat /proc/sys/net/core/rmem_max)"
}

case "$ACTION" in
  install)   install_it ;;
  sysctl)    sysctl_it ;;
  uninstall) uninstall_it ;;
  *) echo "用法: $0 {install|sysctl|uninstall}"; exit 2 ;;
esac
