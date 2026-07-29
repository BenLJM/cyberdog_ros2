# -*- coding: utf-8 -*-
"""判定 leg_control_data 的各字段是"活的测量"还是"常量/默认值"。纯被动。"""
import socket, struct, time, statistics
GROUP="239.255.76.67"; PORT=7667; FP=8
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM,socket.IPPROTO_UDP)
s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1); s.bind(("",PORT))
s.setsockopt(socket.IPPROTO_IP,socket.IP_ADD_MEMBERSHIP,struct.pack("4sl",socket.inet_aton(GROUP),socket.INADDR_ANY))
s.settimeout(1.0)
FIELDS=["q","qd","p","v","tau_est","force_est","force_desired"]
samples={f:[[] for _ in range(12)] for f in FIELDS}
imu_acc=[]
t0=time.time(); n=0
while time.time()-t0<6:
    try: d,_=s.recvfrom(65535)
    except socket.timeout: continue
    if len(d)<8 or struct.unpack_from(">I",d,0)[0]!=0x4C433032: continue
    i=d.find(b"\0",8)
    if i<0: continue
    ch=d[8:i].decode("utf-8","replace"); p=d[i+1:]
    if ch=="leg_control_data" and len(p)==392:
        n+=1
        if n%25: continue           # 抽样,别把内存撑爆
        o=FP
        for f in FIELDS:
            v=struct.unpack_from(">12f",p,o); o+=48
            for k in range(12): samples[f][k].append(v[k])
    elif ch=="myIMU" and len(p)==80:
        a=struct.unpack_from(">3f",p,FP+16+12+12)   # acc 在 quat+rpy+omega 之后
        imu_acc.append(a[2])
print("═══ leg_control_data 字段活性判定（%d 帧,抽样 %d 组）═══"%(n,len(samples["q"][0])))
print("  %-15s %12s %12s %12s %s"%("字段","最小","最大","标准差","判定"))
for f in FIELDS:
    allv=[x for k in range(12) for x in samples[f][k]]
    if not allv: continue
    sd=statistics.pstdev(allv) if len(allv)>1 else 0.0
    # 逐关节看是否恒定
    per_joint_const=all(len(set(samples[f][k]))<=1 for k in range(12))
    verdict="❌ 每关节恒定(非测量值)" if per_joint_const else ("⚠️ 几乎不变" if sd<1e-6 else "✅ 在变(活数据)")
    print("  %-15s %12.4f %12.4f %12.6f %s"%(f,min(allv),max(allv),sd,verdict))
if imu_acc:
    print("\n═══ 对照:IMU acc_z（已知是活数据）═══")
    print("  最小 %.4f 最大 %.4f 标准差 %.6f → %s"%(min(imu_acc),max(imu_acc),
        statistics.pstdev(imu_acc), "✅ 在变" if statistics.pstdev(imu_acc)>1e-6 else "❌ 恒定"))
