#!/bin/bash
# Launches the scenario-B QEMU test: boot the built PandOS ISO with a
# cidata-labeled drive attached, let autoinstall.sh install unattended to
# target-disk.img, then (on reboot) boot the installed system itself.
#
# bootindex is REQUIRED here, not optional: grub-install writes the
# bootloader to the same fallback EFI path (/EFI/BOOT/BOOTX64.EFI) that the
# ISO itself uses, so without an explicit boot order OVMF keeps picking the
# CD-ROM on every reboot and the install loops forever instead of ever
# booting the installed disk - confirmed the hard way in
# tests/qemu-boot-verification.md (scenario B, ~6h reinstall loop before
# this was found). format=raw drives can't take bootindex directly
# ("Block format 'raw' does not support the option 'bootindex'") - it has to
# go on an explicit -device.
#
# Expects, in the current directory: OVMF_CODE_4M.fd, OVMF_VARS.fd (copy of
# a pristine /usr/share/OVMF/OVMF_VARS_4M.fd - this script does NOT reset it
# between runs), target-disk.img (raw, pre-sized, e.g.
# `truncate -s 15032385536 target-disk.img` - also NOT reset between runs,
# delete/recreate it yourself for a clean install test), cidata.img, and
# out/pandos-<date>-x86_64.iso (from `mkarchiso`, see build-iso.sh).
set -eu

SSH_PORT="${SSH_PORT:-2227}"
QMP_SOCK="${QMP_SOCK:-qmp-test.sock}"
ISO="${ISO:-$(ls out/pandos-*-x86_64.iso | head -1)}"

qemu-system-x86_64 \
  -enable-kvm -m 4096 -smp 4 \
  -drive if=pflash,format=raw,file=OVMF_CODE_4M.fd,readonly=on \
  -drive if=pflash,format=raw,file=OVMF_VARS.fd \
  -drive file=target-disk.img,format=raw,if=none,id=diskdrv \
  -device virtio-blk-pci,drive=diskdrv,bootindex=1 \
  -drive file=cidata.img,format=raw,if=virtio \
  -drive file="$ISO",media=cdrom,if=none,id=cddrv \
  -device virtio-blk-pci,drive=cddrv,bootindex=2 \
  -netdev user,id=n1,hostfwd=tcp::"$SSH_PORT"-:22 \
  -device virtio-net-pci,netdev=n1 \
  -vga virtio -display none \
  -qmp unix:"$QMP_SOCK",server,nowait
