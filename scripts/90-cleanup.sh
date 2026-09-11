#!/usr/bin/env bash
#
# 90-cleanup.sh — generalization. MUST be the last provisioner.
#
# Strips anything that has to be unique per device. A cloned disk otherwise
# carries one machine-id and one set of SSH host keys across all 122 units,
# which breaks DHCP and trips SSH warnings fleet-wide.
#
# Hostname and IP are deliberately NOT handled here — the service desk sets
# those after deployment.
#
set -euo pipefail

echo "== SSH host key regeneration =="
# Installed before the keys are deleted so the unit is in place on first boot.
# Without it sshd refuses to start and every device is unreachable.
# 24.04 uses socket activation, so ordering must cover ssh.socket too.
cat > /etc/systemd/system/regen-ssh-hostkeys.service <<'EOF'
[Unit]
Description=Regenerate SSH host keys on first boot
Before=ssh.service ssh.socket
ConditionPathExistsGlob=!/etc/ssh/ssh_host_*_key

[Service]
Type=oneshot
ExecStart=/usr/bin/ssh-keygen -A
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl enable regen-ssh-hostkeys.service

echo "== Re-harden SSH =="
# Password auth was on only so Packer could log in during the build.
mkdir -p /etc/ssh/sshd_config.d
printf 'PasswordAuthentication no\nPermitRootLogin no\n' \
  > /etc/ssh/sshd_config.d/99-hardening.conf

echo "== Package cache =="
apt-get clean
rm -rf /var/lib/apt/lists/*

echo "== Machine identity =="
# truncate, not rm: systemd only regenerates when the file exists but is
# empty. Ubuntu uses machine-id as its DHCP client identifier, so clones
# would otherwise fight over a single lease.
truncate -s 0 /etc/machine-id
rm -f /var/lib/dbus/machine-id
ln -sf /etc/machine-id /var/lib/dbus/machine-id

echo "== SSH host keys =="
rm -f /etc/ssh/ssh_host_*

echo "== Interface naming =="
rm -f /etc/systemd/network/*.link
rm -f /etc/udev/rules.d/70-persistent-net.rules

echo "== Network config =="
# cloud-init writes /etc/netplan/50-cloud-init.yaml at install time with the
# BUILD machine's MAC hardcoded in a match: block. That file ships inside the
# image, so every other device fails the match and gets no network at all.
#
# Replace it with a wildcard config and stop cloud-init regenerating it.
rm -f /etc/netplan/50-cloud-init.yaml

printf 'network: {config: disabled}\n' \
  > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg

cat > /etc/netplan/01-netcfg.yaml <<'EOF'
network:
  version: 2
  ethernets:
    all-en:
      match:
        name: "en*"
      dhcp4: true
      dhcp6: false
      # Identify by MAC rather than the machine-id-derived DUID. Without this
      # a reimaged device looks like a brand-new host to DHCP, which can land
      # it in a different VLAN than the same hardware had before.
      dhcp-identifier: mac
EOF
chmod 600 /etc/netplan/01-netcfg.yaml
netplan generate

echo "== cloud-init =="
# No metadata service on bare metal. Without this pin cloud-init spends
# 30-120s hunting for one on every boot.
printf 'datasource_list: [ NoCloud, None ]\n' \
  > /etc/cloud/cloud.cfg.d/99-datasource.cfg
cloud-init clean --logs --seed || true

echo "== Logs and history =="
journalctl --rotate || true
journalctl --vacuum-time=1s || true
rm -rf /var/log/journal/* || true
find /var/log -type f -name '*.log' -delete || true
rm -f /var/log/wtmp /var/log/btmp /var/log/lastlog || true
rm -f /root/.bash_history /home/*/.bash_history || true

echo "== Zero free space =="
# Deleted files leave old data behind, and garbage does not compress.
# Costs ~2 minutes of build time, saves roughly 1 GB on the final .xz.
dd if=/dev/zero of=/EMPTY bs=1M status=none || true
rm -f /EMPTY
fstrim -av || true
sync

echo "--- verification ---"
echo "machine-id bytes : $(wc -c < /etc/machine-id)   (expect 0)"
echo "host keys        : $(ls /etc/ssh/ | grep -c host || true)   (expect 0)"
echo "regen unit       : $(systemctl is-enabled regen-ssh-hostkeys.service)"
echo "growroot unit    : $(systemctl is-enabled growroot.service)"
echo "BOOTX64.EFI      : $([ -f /boot/efi/EFI/BOOT/BOOTX64.EFI ] && echo present || echo MISSING)"
echo "netplan files    : $(ls /etc/netplan/)   (expect only 01-netcfg.yaml)"
echo "hardcoded MAC    : $(grep -c macaddress /etc/netplan/*.yaml || echo 0)   (expect 0)"
