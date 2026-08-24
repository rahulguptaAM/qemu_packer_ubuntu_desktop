#!/usr/bin/env bash
set -euo pipefail


# ssh.service and ssh.socket.
sudo tee /etc/systemd/system/regen-ssh-hostkeys.service >/dev/null <<'EOF'
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

sudo systemctl enable regen-ssh-hostkeys.service

sudo apt-get clean
sudo rm -rf /var/lib/apt/lists/*

sudo truncate -s 0 /etc/machine-id
sudo rm -f /var/lib/dbus/machine-id
sudo ln -sf /etc/machine-id /var/lib/dbus/machine-id


sudo rm -f /etc/ssh/ssh_host_*


sudo rm -f /etc/systemd/network/*.link
sudo rm -f /etc/udev/rules.d/70-persistent-net.rules


sudo journalctl --rotate || true
sudo journalctl --vacuum-time=1s || true
sudo rm -rf /var/log/journal/* || true
sudo find /var/log -type f -name '*.log' -delete || true
sudo rm -f /var/log/wtmp /var/log/btmp /var/log/lastlog || true


sudo rm -f /root/.bash_history /home/*/.bash_history || true


sudo dd if=/dev/zero of=/EMPTY bs=1M status=none || true
sudo rm -f /EMPTY
sudo fstrim -av || true

sync

echo "--- verification ---"
echo "machine-id bytes : $(sudo wc -c < /etc/machine-id)   (expect 0)"
echo "host keys        : $(sudo ls /etc/ssh/ | grep -c host || true)   (expect 0)"
echo "regen unit       : $(sudo systemctl is-enabled regen-ssh-hostkeys.service)"
