#!/bin/sh

DEVICE="/dev/disk/by-uuid/82EA-1B12"
MOUNT_POINT="/mnt/usb"

# If the device is not present, do nothing and exit cleanly
if [ ! -b "$DEVICE" ]; then
    echo "[mount_script] Device not present: $DEVICE"
    exit 0
fi

# Make sure mount point exists
mkdir -p "$MOUNT_POINT"

# If it's already mounted, do nothing
if mountpoint -q "$MOUNT_POINT"; then
    echo "[mount_script] Already mounted at $MOUNT_POINT"
    exit 0
fi

# Mount VFAT drive with ownership set to the current user
mount -t vfat -o uid=1000,gid=1000,utf8=1 "$DEVICE" "$MOUNT_POINT"

# Never fail boot because of this script
if [ $? -ne 0 ]; then
    echo "[mount_script] Mount failed"
    exit 0
fi

echo "[mount_script] Mount successful"
exit 0
