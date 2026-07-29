#!/bin/bash
# =============================================================================
#  运动板状态快照 —— **纯只读**，动它之前的"事前存档"
#
#  为什么：运动板跑着 500Hz 平衡控制器、固件加密不可重建、SSH 是唯一入口。
#  一旦以后要往里面放东西（motor_sdk / 自研控制器），必须先有一份"原样"存档，
#  否则出问题连"改回去"的参照都没有。
#
#  🔴 本脚本只做：ping / 端口探测 / 被动 LCM 监听 / 宿主侧看到的运动板信息。
#     **不 SSH 登入运动板、不发任何 LCM 包、不改任何东西。**
#     登入运动板是独立的一步，需要机主明确同意（见输出末尾的说明）。
# =============================================================================
set -u
OUT="${1:-/tmp/mb-snapshot}"
mkdir -p "$OUT"
MB=192.168.55.233
MB2=192.168.55.100

log() { echo "[mb-snap] $*"; }

log "① 网络与可达性"
{
  echo "# 采集时刻(宿主单调时间): $(cat /proc/uptime | cut -d' ' -f1)s since boot"
  echo "## 宿主网桥"
  ip -4 addr show l4tbr0 2>/dev/null
  ip route 2>/dev/null | grep 192.168.55
  echo "## 运动板可达性"
  for H in $MB $MB2; do
    echo "### $H"
    ping -c3 -W2 $H 2>&1 | tail -3
    for P in 22 8080 10206; do
      timeout 3 bash -c "echo >/dev/tcp/$H/$P" 2>/dev/null \
        && echo "  tcp/$P OPEN" || echo "  tcp/$P closed"
    done
    arp -n $H 2>/dev/null
  done
} > "$OUT/network.txt" 2>&1

log "② 被动 LCM 频道普查(10 秒,只收不发)"
python3 - "$OUT" <<'PY' > "$OUT/lcm-channels.txt" 2>&1
import socket, struct, sys, time, collections
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM,socket.IPPROTO_UDP)
s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1); s.bind(("",7667))
s.setsockopt(socket.IPPROTO_IP,socket.IP_ADD_MEMBERSHIP,
             struct.pack("4sl",socket.inet_aton("239.255.76.67"),socket.INADDR_ANY))
s.settimeout(1.0)
ch=collections.Counter(); sz={}; src=collections.Counter(); t0=time.time()
while time.time()-t0<10:
    try: d,a=s.recvfrom(65535)
    except socket.timeout: continue
    src[a[0]]+=1
    if len(d)<8 or struct.unpack_from(">I",d,0)[0]!=0x4C433032: continue
    i=d.find(b"\0",8)
    if i<0: continue
    c=d[8:i].decode("utf-8","replace"); ch[c]+=1; sz[c]=len(d)-i-1
el=time.time()-t0
print("# 被动监听 %.1f 秒 —— 本进程从未 sendto"%el)
print("## 发包方"); [print("  %-16s %6d 包 %.1f/s"%(k,v,v/el)) for k,v in src.most_common()]
print("## 频道(名称 频率Hz 载荷字节)")
for c,n in ch.most_common(): print("  %-34s %8.2f %6d"%(c,n/el,sz.get(c,0)))
PY

log "③ 宿主侧与运动板相关的配置/服务"
{
  echo "## 宿主上跟 LCM/运动相关的进程"
  ps aux 2>/dev/null | grep -iE "lcm|motion|cheetah" | grep -v grep
  echo "## chroot 里的 LCM 类型定义(md5,用于确认版本)"
  find /mnt/jp4/home/mi/cyberdog_ros2/cyberdog_interfaces/lcm_translate_msgs/lcm_type \
       -name '*.lcm' -exec md5sum {} \; 2>/dev/null | sort -k2
} > "$OUT/host-side.txt" 2>&1

log "④ 校验和"
( cd "$OUT" && find . -type f ! -name SHA256SUMS -exec sha256sum {} \; | sort -k2 > SHA256SUMS )

log "快照完成 → $OUT"
ls -la "$OUT" | tail -n +2 | awk '{print "   ",$5,$9}'
cat <<'NOTE'

⚠️ 本快照【不含】运动板内部文件系统 —— 那需要 SSH 登入 192.168.55.233。
   登入本身是只读的，但属于"接触运动板"，按项目红线需要机主明确同意。
   同意后再跑：tools/motion/mb-snapshot-inner.sh（尚未编写）。
NOTE
