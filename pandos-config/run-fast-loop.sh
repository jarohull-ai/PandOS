set -x

pacman -Sy --noconfirm archlinux-keyring
pacman -Syu --noconfirm --needed archinstall arch-install-scripts btrfs-progs parted udev

cp /work/localectl-stub.sh /usr/sbin/localectl
chmod +x /usr/sbin/localectl

real_arch_chroot=$(readlink -f "$(command -v arch-chroot)")
if [[ "$real_arch_chroot" != *.real ]]; then
  mv "$real_arch_chroot" "${real_arch_chroot}.real"
  cat > "$real_arch_chroot" <<WRAP
#!/bin/bash
args=()
for a in "\$@"; do
  [[ "\$a" == "-S" ]] && continue
  args+=("\$a")
done
exec ${real_arch_chroot}.real "\${args[@]}"
WRAP
  chmod +x "$real_arch_chroot"
fi

systemctl mask systemd-udevd 2>/dev/null || true
/usr/lib/systemd/systemd-udevd --daemon
udevadm trigger
udevadm settle

cd /work
set -e
archinstall --config user_configuration.json --silent \
  --skip-version-check --skip-ntp --skip-wkd
RC=$?
echo "ARCHINSTALL_EXIT_CODE=$RC"

set -ex
umount -R /mnt 2>/dev/null || true

mkdir -p /mnt
mount -o subvol=/@ /dev/loop10p2 /mnt
mount --mkdir -o subvol=/@home /dev/loop10p2 /mnt/home
mount --mkdir -o subvol=/@log /dev/loop10p2 /mnt/var/log
mkdir -p /mnt/var/cache/pacman
mount --mkdir -o subvol=/@pkg /dev/loop10p2 /mnt/var/cache/pacman/pkg
mount --mkdir /dev/loop10p1 /mnt/boot

arch-chroot /mnt /bin/bash -ex <<'CHROOT2'
# provision.sh (custom_commands, run earlier in this same archinstall pass)
# already created /etc/snapper/configs/{root,home} successfully. This block
# used to redundantly call create-config again here and failed with
# "subvolume already covered" - verify instead of recreating.
test -f /etc/snapper/configs/root
test -f /etc/snapper/configs/home
grep -q 'SUBVOLUME="/"' /etc/snapper/configs/root
grep -q 'SUBVOLUME="/home"' /etc/snapper/configs/home
test -d /.snapshots && rmdir /.snapshots
CHROOT2

mkdir -p /mnt_top
mount -o subvolid=5 /dev/loop10p2 /mnt_top
btrfs subvolume create /mnt_top/@snapshots
umount /mnt_top
mkdir -p /mnt/.snapshots
mount -o subvol=/@snapshots /dev/loop10p2 /mnt/.snapshots

arch-chroot /mnt /bin/bash -ex <<'CHROOT3'
snapper --no-dbus -c root list
mkdir -p /etc/systemd/system/grub-btrfsd.service.d
cat > /etc/systemd/system/grub-btrfsd.service.d/override.conf <<'EOF2'

[Service]
ExecStart=
ExecStart=/usr/bin/grub-btrfsd --syslog /.snapshots
EOF2
systemctl enable grub-btrfsd.service
grub-mkconfig -o /boot/grub/grub.cfg
CHROOT3

rm -f /mnt/etc/fstab
genfstab -U /mnt > /mnt/etc/fstab
sed -i '/swapfile/d' /mnt/etc/fstab
cat /mnt/etc/fstab

echo "=== VERIFY ==="
btrfs subvolume list /mnt
arch-chroot /mnt /bin/bash -c "snapper -c root list-configs; snapper -c home list-configs; ls -la /etc/pacman.d/hooks/ 2>/dev/null; ls -la /opt/pandacode/; ls -la /usr/share/applications/pandacode.desktop; cat /etc/pandos-root-marker.txt; cat /home/pandos/home-marker.txt"

echo "=== POST_PROCESSING_OK ==="
umount -R /mnt
