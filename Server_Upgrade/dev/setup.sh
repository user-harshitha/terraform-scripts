#!/bin/bash

# Set up comprehensive logging
LOG_FILE="/var/log/full-provisioning.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "===== STARTING PROVISIONING $(date) ====="

echo "--- MOUNTING VOLUMES ---"

mkdir -p /app /appdata /database

# Wait for devices to be available (up to 2 minutes)
for i in {1..120}; do
  if [ -b /dev/nvme1n1 ] && [ -b /dev/nvme2n1 ] && [ -b /dev/nvme3n1 ]; then
    break
  fi
  sleep 1
done

# Detect NVMe devices (if instance uses NVMe)
if ls /dev/nvme* 1> /dev/null 2>&1; then
  APP_DEVICE="/dev/nvme1n1"
  APPDATA_DEVICE="/dev/nvme2n1"
  DATABASE_DEVICE="/dev/nvme3n1"
else
  APP_DEVICE="/dev/sdf"
  APPDATA_DEVICE="/dev/sdg"
  DATABASE_DEVICE="/dev/sdh"
fi

# Wait until all 3 NVMe devices are detected
while [ $(ls /dev/nvme* | grep -c 'n1$') -lt 3 ]; do
  sleep 1
  echo "Waiting for NVMe devices..."
done

sleep 60

# Format and mount volumes, comment this while testing on data volumes. This needs format only if its a new volume.
#mkfs -t ext4 $APP_DEVICE
#mkfs -t ext4 $APPDATA_DEVICE
#mkfs -t ext4 $DATABASE_DEVICE

mount $APP_DEVICE /app || {
  echo "Failed to mount $APP_DEVICE to /app"
  exit 1
}
mount $APPDATA_DEVICE /appdata || {
  echo "Failed to mount $APPDATA_DEVICE to /appdata"
  exit 1
}
mount $DATABASE_DEVICE /database || {
  echo "Failed to mount $DATABASE_DEVICE to /database"
  exit 1
}

# Add to fstab (use UUID for reliability)
APP_UUID=$(blkid -s UUID -o value $APP_DEVICE)
APPDATA_UUID=$(blkid -s UUID -o value $APPDATA_DEVICE)
DATABASE_UUID=$(blkid -s UUID -o value $DATABASE_DEVICE)

echo "UUID=$APP_UUID /app ext4 defaults,nofail 0 2" >> /etc/fstab
echo "UUID=$APPDATA_UUID /appdata ext4 defaults,nofail 0 2" >> /etc/fstab
echo "UUID=$DATABASE_UUID /database ext4 defaults,nofail 0 2" >> /etc/fstab

echo "===== PROVISIONING COMPLETE $(date) ====="
