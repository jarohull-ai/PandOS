#!/bin/bash
# Runs at live-boot (pandos-autoinstall.service) if a cidata-labeled drive is
# present. Triggers a fully unattended install using the bundled, already
# verified user_configuration.json - see tests/full-config-verification.md
# and tests/qemu-boot-verification.md in the PandOS repo for how this config
# was built and tested (fast loop + QEMU boot).
#
# Unlike the fast-loop build container, this runs under a real systemd PID 1
# (the booted live ISO), so none of the build-container workarounds
# (localectl stub, arch-chroot -S stripping) are needed here - archinstall's
# own arch-chroot/localectl calls work natively.
set -x
exec > >(tee -a /var/log/pandos-autoinstall.log) 2>&1

CONFIG_SRC=/root/pandos/user_configuration.json
CONFIG_RUN=/tmp/pandos-user_configuration.json

udevadm settle

# blkid -L is case-sensitive and real-world tools (Packer, Proxmox, libvirt,
# mkfs.fat's own uppercasing of FAT labels) disagree on "cidata" vs "CIDATA" -
# match either.
CIDATA_DEV=$(blkid -L cidata 2>/dev/null || blkid -L CIDATA 2>/dev/null)
if [ -z "$CIDATA_DEV" ]; then
  echo "No cidata-labeled drive found - staying interactive."
  cat > /etc/motd <<'EOF'

  PandOS live environment.

  No unattended-install drive (label "cidata") was found, so nothing is
  happening automatically. To install by hand:

    archinstall --config /root/pandos/user_configuration.json

  (edit the "device" field in that file first to match your target disk,
  e.g. /dev/sda or /dev/nvme0n1 - check with `lsblk`.)

EOF
  exit 0
fi

echo "cidata drive found at $CIDATA_DEV - starting unattended install."

# Pick the install target: first non-removable disk that isn't the medium
# holding cidata itself. Strips a trailing partition-number suffix from the
# cidata device to get its parent disk, so we don't ever target that disk by
# mistake even if it also happens to look like a plain disk.
CIDATA_PARENT=$(lsblk -no PKNAME "$CIDATA_DEV" 2>/dev/null | head -1)
TARGET_DISK=""
while read -r name rm type; do
  [ "$type" = "disk" ] || continue
  [ "$rm" = "1" ] && continue
  [ "$name" = "$CIDATA_PARENT" ] && continue
  TARGET_DISK="/dev/$name"
  break
done < <(lsblk -dno NAME,RM,TYPE)

if [ -z "$TARGET_DISK" ]; then
  echo "ERROR: could not find a target disk (excluding the cidata medium)." >&2
  exit 1
fi
echo "Target disk: $TARGET_DISK"

# partition suffix: devices ending in a digit (nvme0n1, loop10) get "pN",
# plain-lettered devices (sda, vda) get "N" directly.
if [[ "$TARGET_DISK" =~ [0-9]$ ]]; then
  PART_SUFFIX="p"
else
  PART_SUFFIX=""
fi
BOOT_PART="${TARGET_DISK}${PART_SUFFIX}1"
ROOT_PART="${TARGET_DISK}${PART_SUFFIX}2"

python3 - "$CONFIG_SRC" "$CONFIG_RUN" "$TARGET_DISK" <<'PYEOF'
import json, sys
src, dst, disk = sys.argv[1:4]
cfg = json.load(open(src))
cfg["disk_config"]["device_modifications"][0]["device"] = disk
json.dump(cfg, open(dst, "w"), indent=2)
PYEOF

archinstall --config "$CONFIG_RUN" --silent --skip-version-check --skip-ntp --skip-wkd
RC=$?
echo "ARCHINSTALL_EXIT_CODE=$RC"
if [ "$RC" -ne 0 ]; then
  echo "ERROR: archinstall failed, stopping before post-processing." >&2
  exit 1
fi

# --- post-processing: swap snapper's nested .snapshots for a top-level
# @snapshots subvolume, same sequence as pandos-config/run-fast-loop.sh ---
umount -R /mnt 2>/dev/null || true
mkdir -p /mnt
mount -o subvol=/@ "$ROOT_PART" /mnt
mount --mkdir -o subvol=/@home "$ROOT_PART" /mnt/home
mount --mkdir -o subvol=/@log "$ROOT_PART" /mnt/var/log
mkdir -p /mnt/var/cache/pacman
mount --mkdir -o subvol=/@pkg "$ROOT_PART" /mnt/var/cache/pacman/pkg
mount --mkdir "$BOOT_PART" /mnt/boot

arch-chroot /mnt /bin/bash -ex <<'CHROOT'
test -f /etc/snapper/configs/root
test -f /etc/snapper/configs/home
grep -q 'SUBVOLUME="/"' /etc/snapper/configs/root
grep -q 'SUBVOLUME="/home"' /etc/snapper/configs/home
test -d /.snapshots && rmdir /.snapshots
CHROOT

mkdir -p /mnt_top
mount -o subvolid=5 "$ROOT_PART" /mnt_top
btrfs subvolume create /mnt_top/@snapshots
umount /mnt_top
mkdir -p /mnt/.snapshots
mount -o subvol=/@snapshots "$ROOT_PART" /mnt/.snapshots

arch-chroot /mnt /bin/bash -ex <<'CHROOT2'
snapper --no-dbus -c root list
grub-mkconfig -o /boot/grub/grub.cfg
CHROOT2

rm -f /mnt/etc/fstab
genfstab -U /mnt > /mnt/etc/fstab
cat /mnt/etc/fstab

umount -R /mnt

echo "=== POST_PROCESSING_OK ==="
echo "Install complete. Rebooting in 10s (remove installation media now)."
sleep 10
systemctl reboot
