#!/bin/bash
# 充电记录仪: BMS一帧解码追加到日志
python3 - <<PYEOF >> /var/log/battwatch.log 2>&1
import socket, struct, time
s=socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR,1)
s.bind(("239.255.76.67",7672))
s.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP, struct.pack("4s4s", socket.inet_aton("239.255.76.67"), socket.inet_aton("192.168.55.1")))
s.settimeout(8)
try:
    d,a=s.recvfrom(2048)
    i=d.index(b"\x00",8)
    v,c,t,soc,st,key,h,lp,pb=struct.unpack(">hhhbbbbhb", d[i+9:i+22])
    print("%s volt=%.2fV curr=%+dmA soc=%d%% temp=%d health=%d%% status=0x%02x" % (time.strftime("%F %T"), v/1000, c, soc, t, h, st))
except Exception as e:
    print(time.strftime("%F %T"), "no-bms:", e)
PYEOF
