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

# Bare udevd (no real PID 1/systemd) in this container never creates /dev
# nodes for partitions added to a loop device AFTER it's already attached,
# and never populates its own database (PARTN/PARTUUID/UUID) for them
# either - confirmed in isolation: the kernel registers them correctly and
# immediately (/proc/partitions has them right away), but no combination of
# `udevadm settle`/`trigger`/`partprobe`/`blockdev --rereadpt` makes the
# node or the udev-db entries appear. Only `udevadm trigger --action=add
# --sysname-match=<name>` (forcing udev to treat it as a fresh "add" event)
# actually populates them - verified directly, both the node and lsblk's
# partn/partuuid fields come back correct afterwards. Since archinstall
# 4.5-1 relies on plain `udevadm settle` in several places (its own
# `udev_sync()` helper is nothing but that) and this problem will keep
# recurring at every one of them, wrap `udevadm` itself once instead of
# chasing each call site: whenever something runs `udevadm settle`, first
# mknod+trigger-add every loop partition the kernel knows about but that
# has no /dev node or udev-db entry yet.
real_udevadm=$(readlink -f "$(command -v udevadm)")
if [[ "$real_udevadm" != *.real ]]; then
  mv "$real_udevadm" "${real_udevadm}.real"
  cat > "$real_udevadm" <<WRAP
#!/bin/bash
if [ "\$1" = "settle" ]; then
  while read -r major minor _ pname; do
    [ -e "/dev/\$pname" ] || mknod "/dev/\$pname" b "\$major" "\$minor" 2>/dev/null
    ${real_udevadm}.real trigger --action=add --sysname-match="\$pname" 2>/dev/null || true
  done < <(grep -E '^[[:space:]]*[0-9]+[[:space:]]+[0-9]+[[:space:]]+[0-9]+[[:space:]]+loop[0-9]+p[0-9]+\$' /proc/partitions)
fi
exec ${real_udevadm}.real "\$@"
WRAP
  chmod +x "$real_udevadm"
fi

# archinstall 4.5-1 (confirmed 2026-10-23, pulled fresh from the `extra`
# repo - a regression vs. the version used on 2026-10-22, when this same
# script last ran clean) calls `wipefs --all` on each freshly created
# partition BEFORE syncing with udev - device_handler.py's partition()
# method literally wipes signatures first, then calls udev_sync(), with a
# comment reading "Sync with udev after wiping signatures" (the wrong
# order, confirmed by reading that file directly in the container). Result:
# `wipefs: error: /dev/loopXpN: probing initialization failed: No such file
# or directory`.
#
# Isolated, reproducible test (manual parted + losetup -P, no archinstall
# involved): the KERNEL does register the new partitions correctly and
# immediately (visible in /proc/partitions right after `disk.commit()`),
# but udevd running bare in this container (no real PID 1/systemd) never
# creates the /dev/loopXpN device NODE for them - neither `udevadm settle`
# nor `partprobe` nor `blockdev --rereadpt` make it appear. This is a udev
# problem, not a kernel or a timing problem, so retrying with settle/sleep
# alone never recovers. Fix: when wipefs reports a partition path missing,
# look up its real major:minor in /proc/partitions (which does have it) and
# `mknod` the device node ourselves - exactly what losetup's own error
# message suggests ("You may use mknod(1) to recover it") when this same
# node-vs-kernel-state split happens to a loop device itself. Verified
# working in isolation before wiring it in here.
real_wipefs=$(readlink -f "$(command -v wipefs)")
if [[ "$real_wipefs" != *.real ]]; then
  mv "$real_wipefs" "${real_wipefs}.real"
  cat > "$real_wipefs" <<WRAP
#!/bin/bash
for attempt in 1 2 3 4 5; do
  out=\$(${real_wipefs}.real "\$@" 2>&1) && { printf '%s\n' "\$out"; exit 0; }
  printf '%s\n' "\$out" | grep -q 'No such file or directory' || { printf '%s\n' "\$out" >&2; exit 1; }
  dev="\${@: -1}"
  name=\$(basename "\$dev")
  line=\$(grep -E "\${name}\\\$" /proc/partitions)
  if [ -n "\$line" ]; then
    read -r major minor _ _ <<<"\$line"
    [ -e "\$dev" ] || mknod "\$dev" b "\$major" "\$minor"
  fi
  udevadm settle
  sleep 1
done
printf '%s\n' "\$out" >&2
exit 1
WRAP
  chmod +x "$real_wipefs"
fi

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
