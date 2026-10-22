set -ex

# --- locale / timezone / console ---
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "KEYMAP=us" > /etc/vconsole.conf
ln -sf /usr/share/zoneinfo/UTC /etc/localtime

# --- user ---
id pandos &>/dev/null || useradd -m -G wheel -s /bin/bash pandos
echo 'pandos:pandos' | chpasswd
echo 'root:pandos' | chpasswd
echo '%wheel ALL=(ALL) ALL' > /etc/sudoers.d/wheel

# --- ssh (test convenience only, not a real PandOS production setting) ---
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config

# --- bootloader (bootloader_config omitted from config on purpose, see README) ---
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=PANDOS --removable

# --- snapper: nested .snapshots first, swapped to top-level @snapshots after archinstall exits ---
test -d /.snapshots && rmdir /.snapshots
snapper --no-dbus -c root create-config /
snapper --no-dbus -c home create-config /home

mkdir -p /etc/systemd/system/grub-btrfsd.service.d
cat > /etc/systemd/system/grub-btrfsd.service.d/override.conf <<'EOF'

[Service]
ExecStart=
ExecStart=/usr/bin/grub-btrfsd --syslog /.snapshots
EOF
systemctl enable grub-btrfsd.service

# --- PandaCode ---
mkdir -p /opt/pandacode
curl -fL -o /opt/pandacode/PandaCode.AppImage \
  https://github.com/aicodeking/pandacode/releases/latest/download/PandaCode-Linux-x86_64.AppImage
chmod +x /opt/pandacode/PandaCode.AppImage

cat > /usr/share/applications/pandacode.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=PandaCode
Comment=Desktop workspace for coding agents
Exec=/opt/pandacode/PandaCode.AppImage
Icon=utilities-terminal
Categories=Development;
Terminal=false
EOF

# --- markers for continuity with the previous rollback test ---
echo "pandos-root-before-change" > /etc/pandos-root-marker.txt
echo "home-marker: should survive any root rollback" > /home/pandos/home-marker.txt
chown pandos:pandos /home/pandos/home-marker.txt

echo "=== custom_commands provisioning complete ==="
