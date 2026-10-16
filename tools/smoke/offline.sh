#!/bin/sh
# 在断网的网络命名空间里运行命令：只打开回环接口（模型网关替身在本机），没有外网和 DNS。
# 用来确认自部署的 agent 不依赖各家的云服务。需要 root（或允许非特权用户命名空间）：
#   unshare -n tools/smoke/offline.sh env -u HTTPS_PROXY -u https_proxy tools/smoke/smoke.sh codex
# 容器里常常没有 ip 命令，所以用 ioctl(SIOCGIFFLAGS/SIOCSIFFLAGS) 打开 lo。
python3 -I -c '
import fcntl, socket, struct
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
flags = struct.unpack("16sH", fcntl.ioctl(s, 0x8913, struct.pack("16sH", b"lo", 0))[:18])[1]
fcntl.ioctl(s, 0x8914, struct.pack("16sH", b"lo", flags | 1))
'
exec "$@"
