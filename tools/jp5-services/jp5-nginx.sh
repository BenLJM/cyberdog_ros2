#!/bin/bash
# CyberDog JP5: 在 chroot(JP4 rootfs) 里跑出厂 nginx。
#
# 出厂 nginx.service 提供两件事,JP5 上此前完全没有对应实现:
#   1) RTMP 推流服务端 :1935  application live —— athena_camera/maincamera 把 AI 头顶相机
#      的实时画面推到 rtmp://<dog>/live,手机 App 从这里拉流看"狗眼视角"
#   2) 相册 HTTP :8083 root=/home/mi/Camera(autoindex on) —— App 浏览/下载狗拍的照片视频
# 两者的生产者都是 maincamera(AI 相机),AI 相机目前不通,所以现在起来是"空服务";
# 但端口在=App 拿到空列表而不是 connection refused,且 D455 侧将来要复用 RTMP 时无需再补。
#
# 注意: nginx 自己 daemonize,由 systemd 用 PIDFile 跟踪(宿主可见 /mnt/jp4/.../nginx.pid)。
set -u
BIN=/usr/local/nginx/sbin/nginx
exec /usr/sbin/chroot /mnt/jp4 "$BIN"
