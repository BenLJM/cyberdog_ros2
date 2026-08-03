# cyberdog_ros2 — JetPack 5 port

Xiaomi's CyberDog ROS2 stack, running on JetPack 5.

Xiaomi open-sourced CyberDog and then stopped. Anyone who still owns
one is stuck on the toolchain it shipped with. This branch gets it onto
JetPack 5 so the hardware stays usable.

75 commits ahead of upstream.

## Status

Everything is up except the voice module.

Working:
- Vision sensors
- Intel RealSense D450
- Microphones
- Locomotion
- Ultrasonic sensors

Not working:
- XIAOAI Voice module (You can replace it with your own)

## My unit
<img width="572" height="589" alt="image" src="https://github.com/user-attachments/assets/2af73eb9-33b9-4d8c-aa07-6ee88b57751b" />
![Uploading image.png…]()

Mine has a myCobot arm and a LiDAR on it. During COVID I used it to
fetch deliveries from the door.

## Working notes

- JP5-BRINGUP-2026-07-22.md
- PORT-STATUS.md
- LESSONS-CYBERDOG-2026-07-23.md

Commit messages are in Chinese.
