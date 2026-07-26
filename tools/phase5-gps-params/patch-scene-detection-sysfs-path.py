import shutil, os, stat
D = "/mnt/jp4/opt/ros2/cyberdog/lib/athena_scene_detection"
B = D + "/service_scene_detection"
BAK = B + ".orig-20260726"
TMP = B + ".new"
src = BAK if os.path.exists(BAK) else B
if not os.path.exists(BAK):
    shutil.copy2(B, BAK); print("backup created")
data = bytearray(open(BAK, "rb").read())
pairs = [
    (b"echo 0 > /sys/devices/bcm4775/nstandby\x00", b"/usr/sbin/gpsnst 0"),
    (b"echo 1 > /sys/devices/bcm4775/nstandby\x00", b"/usr/sbin/gpsnst 1"),
]
for old, new in pairs:
    idx = data.find(old)
    assert idx >= 0, ("not found", old)
    slot = len(old) - 1
    data[idx:idx+len(old)] = new + b" " * (slot - len(new)) + b"\x00"
    print("patched at", idx)
open(TMP, "wb").write(bytes(data))
st = os.stat(BAK)
os.chmod(TMP, st.st_mode); os.chown(TMP, st.st_uid, st.st_gid)
os.replace(TMP, B)
print("replaced", B)
