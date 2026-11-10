#!/usr/bin/env bash
# 服务机第一步（root，重跑没有副作用）：数据盘格式化、挂到 /var/lib/postgresql，装 PostgreSQL 16。
#   deploy/aliyun/run.sh ecs --run-file deploy/aliyun/machine/01-disk-postgres.sh
# 数据盘是买机器时带的那块 20G（/dev/vdb）：只在它上面还没有文件系统时才格式化。
set -euo pipefail
DISK=/dev/vdb
MOUNT=/var/lib/postgresql

if ! blkid "$DISK" >/dev/null 2>&1; then
  echo "格式化 $DISK（ext4）"
  mkfs.ext4 -q -L thinktin-data "$DISK"
else
  echo "$DISK 已经有文件系统：$(blkid -o value -s TYPE "$DISK")"
fi
UUID=$(blkid -o value -s UUID "$DISK")
mkdir -p "$MOUNT"
if ! grep -q "$UUID" /etc/fstab; then
  echo "UUID=$UUID $MOUNT ext4 defaults,nofail 0 2" >> /etc/fstab
fi
mountpoint -q "$MOUNT" || mount "$MOUNT"
echo "挂载：$(findmnt -n -o SOURCE,TARGET,FSTYPE,SIZE "$MOUNT")"

export DEBIAN_FRONTEND=noninteractive
if ! dpkg -s postgresql-16 >/dev/null 2>&1; then
  apt-get update -qq >/dev/null
  apt-get install -y -qq postgresql-16 >/dev/null
fi
systemctl enable --now postgresql >/dev/null 2>&1 || true
sleep 2
echo "PostgreSQL：$(sudo -u postgres psql -Atc 'select version()' | cut -c1-40)"
echo "数据目录：$(sudo -u postgres psql -Atc 'show data_directory')（在 $(df --output=source "$(sudo -u postgres psql -Atc 'show data_directory')" | tail -1) 上）"
echo "监听：$(sudo -u postgres psql -Atc 'show listen_addresses')（现在只有本机能连，装服务时再放开给 k3s 的 Pod）"
df -h / "$MOUNT" | awk 'NR==1 || /vd/'
