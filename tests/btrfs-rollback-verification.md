# Verification: Btrfs/Snapper rollback with the @/@home/@log/@pkg/@snapshots layout

**Date:** 2026-10-22
**Goal:** empirically check whether restoring root (`@`) after a bad update
correctly restores the system state, while leaving `/home` untouched, on a
real system installed by `archinstall` with our explicit Btrfs layout
(`@`→`/`, `@home`→`/home`, `@log`→`/var/log`,
`@pkg`→`/var/cache/pacman/pkg`, `@snapshots`→`/.snapshots`).

## Test environment

- Host: Ubuntu/Zorin (not Arch), Docker 29.1.3, QEMU 8.2.2 + KVM, OVMF
  (UEFI).
- Disk image: a 12GiB raw file, attached via `losetup -fP` on the host,
  partitioned and populated inside an `archlinux:latest` container
  (`--privileged`, with the host's `/dev` mounted in).
- The final "live" test was done over SSH into a VM running in QEMU
  (`-enable-kvm`, a `virtio` virtual disk, UEFI via OVMF, SSH port forwarded
  `hostfwd=tcp::2222-:22`).

## What did NOT work along the way (important, so it isn't repeated)

1. **`archinstall` can't run in a bare `--privileged` container without
   systemd as PID 1.** Two specific, different places broke:
   - `_verify_service_stop` calls `systemctl show ...
     archlinux-keyring-wkd-sync.timer` → "System has not been booted with
     systemd as init system (PID 1)." Workaround: the `--skip-wkd` flag.
   - `set_keyboard_language` calls `localectl --no-pager list-keymaps` over
     D-Bus → the same error, and THIS one has no flag workaround —
     `localectl` always needs a live systemd+D-Bus. Trying to run the
     container with `/usr/lib/systemd/systemd` as PID 1 (the "systemd in
     Docker" pattern) didn't succeed in a reasonable time (the container
     either exited with code 255 with no logs, or hung without printing
     anything to stdout).
   - **Conclusion for our pipeline:** the fast `archinstall` loop via
     `losetup`+container, described earlier in the README, does NOT work
     with the full `archinstall` CLI as originally planned. Partitioning
     and creating Btrfs subvolumes **does work** in a bare container
     (confirmed, see below) — it's only the `archinstall` calls that depend
     on `systemctl`/`localectl`/D-Bus that need a real systemd. To be
     resolved later: either the fast loop uses `systemd-nspawn`/a fully
     correctly configured "systemd in Docker", or it gets reduced to
     testing just the partitioning/subvolumes (as in this test), with the
     rest of the config (locale, users, bootloader, snapper) done manually
     via `arch-chroot` — which is in fact closer to how Omarchy itself
     builds its offline mirror (not via a live `archinstall`, via
     `makepkg`).
2. **The loop device DOES work inside a `--privileged` container**
   (disproving an earlier forum-sourced concern) — `losetup -fP` inside an
   `archlinux:latest --privileged` container with `-v /dev:/dev` attached
   normally, and the `/dev/loopX` device is visible and persists on the
   host too after the container exits.
3. **A race condition on partition device nodes** (`/dev/loop10p1` didn't
   exist immediately after `parted`/archinstall created the partitions) —
   fixed by running `systemd-udevd --daemon` + `udevadm trigger && udevadm
   settle` in the container BEFORE partitioning. Without this:
   `DiskError: Unable to determine new partition number`.
4. **A default `archinstall` run leaves an empty `/.snapshots` directory**
   (not a subvolume) inside `@` already at the base-install stage —
   probably from the `filesystem`/`systemd` package. This is an ADDITIONAL,
   different cause of conflict than the one described on the Arch Wiki
   (`@.snapshots` auto-mounted) — in our case the conflict happened even
   with nothing mounted at `/.snapshots` at all, purely from the plain
   directory existing. `snapper create-config /` refuses with `errno:17
   (File exists)`, because `btrfs_util_create_subvolume_fd()` won't
   overwrite an existing directory. **Workaround:** `rmdir /.snapshots`
   before calling `snapper create-config /` — confirmed to be sufficient.
5. **A chroot with an uninitialized `pacman-key` keyring** → every package
   signature is "unknown trust". For this one-off test the workaround was a
   temporary `SigLevel = Never` in `/etc/pacman.conf` while installing
   packages in the chroot, restored to `Required DatabaseOptional`
   immediately after. **This workaround is NOT acceptable for a real PandOS
   image** — there, `pacman-key --init && pacman-key --populate archlinux`
   has to be done properly. Noted here only as the cause of an error in
   this test.
6. **`genfstab`, run inside the `--privileged` container, added a
   `/swapfile` entry to the target's fstab even though there is no such
   file there** — most likely because the container's `/proc/swaps` shows
   the HOST's active swap (PID/mount namespaces in `--privileged` don't
   isolate this from the host the way one might expect). This has to be
   manually stripped from `fstab` before booting. This is an artifact of
   the test methodology (the container), not something that applies to a
   real PandOS built a different way.

## Test procedure (exact commands, not just a plan)

1. Partitioning + subvolumes + the base system via `archinstall --config
   user_configuration.json --creds user_credentials.json --silent
   --skip-version-check --skip-ntp --skip-wkd` inside the container — it
   got as far as `set_keyboard_language` (D-Bus error), but **partitioning
   and creating the `@`/`@home`/`@log`/`@pkg`/`@snapshots` subvolumes
   finished successfully**, and the base system's pacstrap (`base`,
   `linux`, mkinitcpio) also finished successfully before that error.
2. Finished the install manually via `arch-chroot` (script
   `finish-install.sh`, kept locally in the session's scratchpad, not in
   this repo): packages (`grub`, `efibootmgr`, `snapper`, `snap-pac`,
   `btrfs-assistant`, `grub-btrfs`, `inotify-tools`, `openssh`, `sudo`,
   `vim`, `networkmanager`, `dosfstools`), locale, hostname, user `pandos`
   + root with password `pandos`, enabling `sshd`/`NetworkManager`,
   `snapper -c root create-config /` and `snapper -c home create-config
   /home` (after `rmdir /.snapshots`, see point 4 above), `grub-install
   --target=x86_64-efi ... --removable`, overriding `grub-btrfsd.service`
   to `--syslog /.snapshots`, swapping Snapper's own `.snapshots` for our
   top-level `@snapshots` (`btrfs subvolume delete` + remount `-o
   subvol=/@snapshots`), `grub-mkconfig`, `genfstab -U /mnt >>
   /mnt/etc/fstab` (with the bad `/swapfile` entry manually removed, see
   point 6).
3. Boot in QEMU: `qemu-system-x86_64 -enable-kvm -m 3072 -smp 4 -drive
   if=pflash,...OVMF_CODE_4M.fd,readonly=on -drive if=pflash,...OVMF_VARS.fd
   -drive file=pandos-test.img,format=raw,if=virtio -netdev
   user,hostfwd=tcp::2222-:22 -device virtio-net-pci -nographic`.
4. SSH into the VM (`ssh -p 2222 root@localhost`, password auth via the
   `SSH_ASKPASS`/`SSH_ASKPASS_REQUIRE=force` trick, since there's no TTY in
   this session).
5. **Test A — manually swapping the `@` subvolume (simulating the
   `set-default` hypothesis, CHANGED mid-test — see "Important finding"
   below):**
   - `snapper -c root create --description clean-before-change` (snapshot
     #1)
   - change: `/etc/pandos-root-marker.txt` overwritten
   - `mount -o subvolid=5 /dev/vda2 /mnt/top` (top-level btrfs, LIVE, the
     system is still running on `@`)
   - `mv /mnt/top/@ /mnt/top/@broken-test`
   - `btrfs subvolume snapshot /mnt/top/@snapshots/1/snapshot /mnt/top/@`
     (a new, writable `@` made from the snapshot's content)
   - `umount /mnt/top`, the SSH session stayed alive through the whole
     operation
   - `reboot`
   - **Result after reboot: `/etc/pandos-root-marker.txt` =
     `pandos-root-before-change` (RESTORED), `/home/pandos/home-marker.txt`
     untouched. The system came up normally.**
6. **Test B — the real `btrfs-assistant` tool (not an approximation):**
   discovered it has a CLI mode (`btrfs-assistant --list`, `--restore
   <index>`), working headless with `QT_QPA_PLATFORM=offscreen` (no
   GUI/display).
   - a new cycle: change the marker → `snapper create --description
     clean-for-ba-cli-test` (snapshot #2) → change the marker again
   - `btrfs-assistant --list` → correctly listed both snapshots with their
     indices and `@snapshots/N/snapshot` paths
   - `btrfs-assistant --restore 2` → printed: `Restoring snapshot
     @snapshots/2/snapshot` / `Snapshot restoration complete.` / `A copy of
     the original subvolume has been saved as @_backup_2026-10-22T...` /
     `Please reboot immediately`
   - **Confirmed directly from the tool's actual behavior: it does EXACTLY
     the same thing as Test A did manually** — renames the current `@` to
     `@_backup_<timestamp>` and creates a new writable `@` from the
     snapshot. This is NOT `btrfs subvolume set-default`.
   - `reboot` → **Result: the marker correctly restored
     (`before-ba-test`), `/home` untouched, the newly mounted `@`'s
     `subvolid` confirmed in `/proc/mounts`.**

## An important finding that changed the test plan mid-way

The original hypothesis to verify (set before the test) was: `btrfs
subvolume set-default <snapshot> /` + reboot. **This hypothesis was
rejected BEFORE being run, not empirically, based on checking `grub.cfg`:**
`grub-mkconfig` hardcodes `rootflags=subvol=@` into the kernel line:

```
linux /vmlinuz-linux root=UUID=... rw rootflags=subvol=@ loglevel=3 quiet
```

`btrfs subvolume set-default` only changes what gets mounted when the mount
does NOT specify an explicit `subvol=`/`rootflags=subvol=`. Since GRUB
explicitly forces `subvol=@`, changing the "default subvolume" at the btrfs
level **would have had no effect at all on what actually boots** — the
hypothesis was untestable in this form, because by definition it wouldn't
have worked. Instead, the top-level rename-swap mechanism (`subvolid=5`)
was tested, which DOES work with a hardcoded `subvol=@`, because it
physically swaps out what lives under that same `@` name. It then turned
out (Test B) that this is literally what the real `btrfs-assistant
--restore` does.

## Conclusion

**CONFIRMED**, twice — once manually (Test A), once with the real
`btrfs-assistant --restore` tool via its CLI mode (Test B):

- The top-level `@` subvolume rename-swap mechanism correctly restores
  root to the state of the chosen snapshot.
- `/home` (a separate `@home` subvolume) stays completely untouched in
  every test.
- **No Live USB needed.** The operation works fully from a running, booted
  system over SSH — contrary to the Arch Wiki's suggestion that restoring
  `@` requires a Live CD. That was probably a cautious general
  recommendation, not a hard technical requirement; in our test the SSH
  session survived the entire rename+snapshot operation without
  interruption.
- `btrfs-assistant` has a ready-made, working headless CLI mode
  (`--list`/`--restore <N>`) that can be called directly from a PandOS
  UI/wrapper without writing our own subvolume-swap logic from scratch —
  **this changes the plan**: the rollback mechanism doesn't need to be
  reimplemented, the existing tool can just be called.
- Our layout (`@`/`@home`/`@log`/`@pkg`/`@snapshots`) works with
  `btrfs-assistant`, `snapper` (after the fix from point 4), and
  `grub-btrfs`/`grub-btrfsd` with no further changes.

**Open questions for later (not resolved in this test):**
- Whether `btrfs-assistant`'s GUI (not the CLI) behaves identically — not
  checked, the VM had no graphical environment. It should logically be the
  same (the same binary tool, the same C++ code), but this is unconfirmed.
- Cleaning up old `@_backup_*`/`@broken-test` subvolumes after a rollback
  isn't automatic — needs to be designed (either manual `btrfs subvolume
  delete`, or automatic retention in our wrapper).
- The fast `archinstall` loop mechanism (without a full boot) needs to be
  redesigned — see point 1 in the "What did NOT work" section.

## Test artifacts

The disk image (12GiB), install logs, and helper scripts were left in the
session's scratchpad (`pandos-test.img`, `finish-install.sh`,
`finish-install.log`, `user_configuration.json`, `user_credentials.json`,
`qemu-boot.log`), NOT in this repo (large binary files, already covered by
`.gitignore`). The VM was stopped after the test, the loop device detached.
