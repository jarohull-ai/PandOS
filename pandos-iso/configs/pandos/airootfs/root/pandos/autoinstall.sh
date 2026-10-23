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
set -ex
exec > >(tee -a /var/log/pandos-autoinstall.log) 2>&1

CONFIG_SRC=/root/pandos/user_configuration.json
CONFIG_RUN=/tmp/pandos-user_configuration.json

udevadm settle

# blkid -L is case-sensitive and real-world tools (Packer, Proxmox, libvirt,
# mkfs.fat's own uppercasing of FAT labels) disagree on "cidata" vs "CIDATA" -
# match either.
CIDATA_DEV=$(blkid -L cidata 2>/dev/null || blkid -L CIDATA 2>/dev/null || true)
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
# holding cidata itself. CIDATA_DEV can be a partition (sdb1 -> parent sdb)
# OR a whole disk with no partition table (cidata filesystem written
# directly to e.g. sdb) - in the latter case PKNAME is empty, so we must
# treat CIDATA_DEV's own name as the disk to exclude, not its (nonexistent)
# parent. Getting this wrong means the exclusion silently does nothing and
# the cidata medium itself could be wiped as the "target disk".
CIDATA_BASENAME=$(basename "$CIDATA_DEV")
CIDATA_SELF_TYPE=$(lsblk -no TYPE "$CIDATA_DEV" 2>/dev/null | head -1)
if [ "$CIDATA_SELF_TYPE" = "disk" ]; then
  CIDATA_DISK="$CIDATA_BASENAME"
else
  CIDATA_DISK=$(lsblk -no PKNAME "$CIDATA_DEV" 2>/dev/null | head -1)
fi

if [ -z "$CIDATA_DISK" ]; then
  echo "ERROR: could not determine which disk backs the cidata medium ($CIDATA_DEV) - refusing to guess a target disk." >&2
  exit 1
fi

TARGET_DISK=""
while read -r name rm type; do
  [ "$type" = "disk" ] || continue
  [ "$rm" = "1" ] && continue
  [ "$name" = "$CIDATA_DISK" ] && continue
  TARGET_DISK="/dev/$name"
  break
done < <(lsblk -dno NAME,RM,TYPE)

if [ -z "$TARGET_DISK" ]; then
  echo "ERROR: could not find a target disk (excluding the cidata medium $CIDATA_DISK)." >&2
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

# Dynamic root partition sizing: user_configuration.json's root size is a
# placeholder that only matched the original test disk (~13.8GiB) - on a
# bigger disk it wasted the rest, on a smaller one archinstall could fail
# outright. Compute the real root length from the actual target disk here,
# same way the "device" field is patched below. archinstall 4.0's Size/Unit
# model (checked directly in its source, archinstall/lib/models/device.py)
# has no percent/"fill remaining space" unit - length is a plain MiB value,
# so the real size has to be computed ourselves, not expressed in the JSON.
DISK_SIZE_MIB=$(( $(blockdev --getsize64 "$TARGET_DISK") / 1048576 ))
BOOT_START_MIB=1
BOOT_LEN_MIB=512
ROOT_START_MIB=$(( BOOT_START_MIB + BOOT_LEN_MIB ))
# 2 MiB trailing headroom for GPT backup header/alignment, same margin
# parted/sgdisk themselves reserve at the end of a disk.
ROOT_LEN_MIB=$(( DISK_SIZE_MIB - ROOT_START_MIB - 2 ))
if [ "$ROOT_LEN_MIB" -lt 1024 ]; then
  echo "ERROR: target disk $TARGET_DISK is only ${DISK_SIZE_MIB}MiB - too small for a usable PandOS install (need at least ~1.5GiB free for root beyond the boot partition)." >&2
  exit 1
fi
echo "Target disk size: ${DISK_SIZE_MIB}MiB -> root partition length: ${ROOT_LEN_MIB}MiB"

python3 - "$CONFIG_SRC" "$CONFIG_RUN" "$TARGET_DISK" "$ROOT_LEN_MIB" <<'PYEOF'
import json, sys
src, dst, disk, root_len_mib = sys.argv[1:5]
cfg = json.load(open(src))
cfg["disk_config"]["device_modifications"][0]["device"] = disk
partitions = cfg["disk_config"]["device_modifications"][0]["partitions"]
root_parts = [p for p in partitions if p.get("fs_type") == "btrfs"]
if len(root_parts) != 1:
    sys.exit(f"expected exactly one btrfs partition in the base config, found {len(root_parts)}")
root_parts[0]["size"]["value"] = int(root_len_mib)
json.dump(cfg, open(dst, "w"), indent=2)
PYEOF

# Captured via if/else, not a bare command + $?, because under `set -e` a
# failing plain command aborts the script immediately - before a following
# `RC=$?` line would ever run. if/else is exempt from set -e.
if archinstall --config "$CONFIG_RUN" --silent --skip-version-check --skip-ntp --skip-wkd; then
  RC=0
else
  RC=$?
fi
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

# `|| true`: a busy final unmount here doesn't indicate data loss (every
# write above already landed via its own mount/arch-chroot call finishing
# successfully under set -e) and systemd will force-detach on reboot anyway -
# it must not block reaching POST_PROCESSING_OK and the reboot itself.
umount -R /mnt || true

echo "=== POST_PROCESSING_OK ==="
echo "Install complete. Rebooting in 10s (remove installation media now)."
sleep 10
systemctl reboot
