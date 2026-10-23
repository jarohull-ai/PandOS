set -ex

# --- pacman keyring: pacstrap doesn't always leave every maintainer key
# trusted, discovered when `pacman -S nano` failed with "unknown trust" in
# the previous boot test. Must run before anything later needs trusted
# signatures (nothing in this script does yet, but a built PandOS image
# needs this done once at build time, not left to the first live `pacman -S`).
pacman-key --init
pacman-key --populate archlinux

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

# --- greetd + cosmic-greeter: config BEFORE enable, order matters (greetd
# reads config.toml at start; enabling first would leave it pointed at the
# bundled agreety text greeter, confirmed in the previous boot test). ---
cp /etc/greetd/cosmic-greeter.toml /etc/greetd/config.toml
systemctl enable greetd.service

# --- PandaCode (pinned version + sha256, not 'latest' - confirmed via
# the GitHub releases API that aicodeking/pandacode publishes a
# matching .sha256 file per asset) ---
mkdir -p /opt/pandacode
PANDACODE_VERSION="v0.3.32"
PANDACODE_SHA256="7304b756182fb424e86a3a702b273ad915b780955aa90eeb2b2b53c06317caa4"
curl -fL -o /opt/pandacode/PandaCode.AppImage \
  "https://github.com/aicodeking/pandacode/releases/download/${PANDACODE_VERSION}/PandaCode-Linux-x86_64.AppImage"
echo "${PANDACODE_SHA256}  /opt/pandacode/PandaCode.AppImage" | sha256sum -c -
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
