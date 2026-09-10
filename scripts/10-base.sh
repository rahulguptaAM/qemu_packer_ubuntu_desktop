#!/usr/bin/env bash
#
# 10-base.sh — Layer 0 base. Everything identical across all devices.
#
# Application stack (PostgreSQL, RabbitMQ, the AppImage) goes in a separate
# script later. This one only has to produce something that boots correctly
# on the Geekland hardware.
#
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

echo "== Update =="
apt-get update
apt-get -y dist-upgrade

echo "== Kernel + firmware =="
# Server ISO already installs linux-generic, but be explicit: a virtual or
# trimmed kernel would not find the SATA controller on real hardware.
apt-get install -y --no-install-recommends \
  linux-generic \
  linux-firmware        # i915 firmware for the J6412 iGPU

echo "== Graphics stack for the Avalonia app =="
# The app renders directly to /dev/dri via GBM. No X, no Wayland compositor,
# no display manager — confirmed on the existing device.
apt-get install -y --no-install-recommends \
  libgbm1 \
  libgl1-mesa-dri \
  libegl1-mesa \
  libinput10 \
  libdrm2 \
  libudev1

echo "== Peripheral support =="
apt-get install -y --no-install-recommends \
  libhidapi-hidraw0 libhidapi-libusb0 \
  brightnessctl \
  alsa-utils \
  usbutils v4l-utils libinput-tools evtest

echo "== Utilities =="
apt-get install -y --no-install-recommends \
  curl jq \
  cloud-guest-utils \
  chrony \
  vim less

echo "== GRUB =="
# consoleblank=0: without it the console blanks after 10 minutes and a
# wall-mounted clock goes dark. Not set on the vendor's image.
# quiet/splash removed: on an appliance, boot messages are the only
# diagnostic anyone gets on site.
sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="consoleblank=0"/' /etc/default/grub
sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=3/'                 /etc/default/grub
sed -i 's/^GRUB_TIMEOUT_STYLE=.*/GRUB_TIMEOUT_STYLE=menu/'  /etc/default/grub
grep -q '^GRUB_TIMEOUT_STYLE' /etc/default/grub || echo 'GRUB_TIMEOUT_STYLE=menu' >> /etc/default/grub
update-grub

echo "== UEFI fallback bootloader =="
# The device's NVRAM has a boot entry pointing at \EFI\ubuntu, created when
# the vendor installed. A cloned SSD dropped into a fresh unit has no such
# entry, so the firmware falls back to \EFI\BOOT\BOOTX64.EFI. Without this
# the unit reports "No bootable device" even though the OS is fine.
if [ -d /boot/efi/EFI/ubuntu ]; then
  mkdir -p /boot/efi/EFI/BOOT
  cp -f /boot/efi/EFI/ubuntu/shimx64.efi /boot/efi/EFI/BOOT/BOOTX64.EFI
  cp -f /boot/efi/EFI/ubuntu/grubx64.efi /boot/efi/EFI/BOOT/grubx64.efi
  cp -f /boot/efi/EFI/ubuntu/mmx64.efi   /boot/efi/EFI/BOOT/ 2>/dev/null || true
  ls -l /boot/efi/EFI/BOOT/
else
  echo "WARNING: /boot/efi/EFI/ubuntu not found" >&2
fi

echo "== Grow root on first boot =="
# The image is 12 GB; the device's SSD is 128 GB. Nothing expands the
# filesystem automatically on a bare-metal install, so do it explicitly.
cat > /usr/local/sbin/growroot <<'SCRIPT'
#!/bin/bash
set -euo pipefail
ROOT=$(findmnt -no SOURCE /)
DISK="/dev/$(lsblk -no PKNAME "$ROOT")"
PART="${ROOT##*[a-z]}"
growpart "$DISK" "$PART" || true
resize2fs "$ROOT"        || true
touch /var/lib/growroot-done
SCRIPT
chmod +x /usr/local/sbin/growroot

cat > /etc/systemd/system/growroot.service <<'EOF'
[Unit]
Description=Grow root filesystem to fill the disk on first boot
DefaultDependencies=no
After=local-fs.target
Before=multi-user.target
ConditionPathExists=!/var/lib/growroot-done

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/growroot

[Install]
WantedBy=multi-user.target
EOF
systemctl enable growroot.service

echo "== Extra console on tty2 =="
# The app holds DRM master on tty1 and does not release it on VT switch, so
# Ctrl+Alt+F2 is the only way onto a console with the app running.
systemctl enable getty@tty2.service

echo "== SSH =="
systemctl enable ssh

echo "== Never sleep =="
# A wall-mounted clock that suspends is a broken clock.
systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
systemctl disable unattended-upgrades 2>/dev/null || true

echo "== TRIM =="
systemctl enable fstrim.timer

echo "== Image manifest =="
# Six months from now this is how you tell which build a device came from.
cat > /etc/image-manifest <<EOF
image=applied-timeclock
os=$(. /etc/os-release; echo "$PRETTY_NAME")
kernel=$(ls /boot/vmlinuz-* | sed 's|.*vmlinuz-||' | head -1)
built=$(date -Iseconds)
EOF
cat /etc/image-manifest

apt-get -y autoremove
echo "Base complete."
