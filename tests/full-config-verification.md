# Verification: full `user_configuration.json` (fast loop, one `archinstall` pass)

**Date:** 2026-10-22
**Goal:** write a complete config for `archinstall` that, in a single pass
(not in two phases like the previous test), produces a system with our
Btrfs layout, Snapper, COSMIC and PandaCode — following DeepSeek's
recommendation: `archinstall` does disk+packages+locale+user+bootloader via
`custom_commands`, without `systemd-nspawn`.

**Result: CONFIRMED.** The config in `pandos-config/user_configuration.json`
+ `pandos-config/provision.sh` (the content of the `custom_commands` field)
+ `pandos-config/run-fast-loop.sh` (the driver script building inside the
container) works from start to finish. We got here through 7 real,
understood obstacles — none of them blind guessing, each confirmed by a
traceback/source before being fixed.

## Environment

Same as the previous test: Ubuntu/Zorin (not Arch), Docker `--privileged`,
`archlinux:latest` as the build container, a 14GiB disk image via
`losetup` on the host (not in the container — the loop device DOES work in
`--privileged`, confirmed here too, the forum-sourced concern was
outdated/not applicable in this environment).

## Obstacles hit along the way (7, each understood, not guessed)

1. **Omitting `locale_config` from the JSON is NOT enough.** I expected
   (based on earlier source verification) this would block the `localectl`
   call. It turned out that `Installer.minimal_installation()` has
   `locale_config: LocaleConfiguration | None = LocaleConfiguration.default()`
   as a **function default argument** (`installer.py:893`), independent of
   the top-level config — so `set_keyboard_language()` gets called anyway.
   This corrects an earlier, incomplete finding in the README (I had only
   verified ONE of the two places that call this code).
2. (My own bug, not archinstall's: `which: command not found` in the
   minimal `archlinux:latest` image killed the script via `set -e` before
   it even reached archinstall. Fixed by removing the unnecessary check.)
3. A repeat of obstacle #1 after fixing #2.
4. **`arch-chroot` in this version of `arch-install-scripts` uses
   `systemd-run` by default (the `-S` flag, which `archinstall` ALWAYS
   attaches to every one of its `arch-chroot` calls), which requires
   `/run/systemd/system` on the host** (`systemd_sanity_check()` in
   `arch-chroot`, confirmed by reading the script itself). This is a
   deeper, different cause than #1 — not just `localectl`, the entire
   chrooting mechanism in this version needs systemd. Fixed: a wrapper in
   the container that strips `-S` from the arguments before calling the
   real `arch-chroot`, forcing it into its traditional,
   systemd-independent `chroot_setup()` (plain bind mounts, nothing
   required). Definitely a simpler solution than trying to run a real
   systemd as PID 1 in the container (which had already failed to finish
   in a reasonable time in the previous test).
5. After fixing #1 and #4: **`archinstall` went through completely, exit
   code 0** — for the first time. But my OWN post-install step failed:
   `snapper -c root create-config /` → "Creating config failed (subvolume
   already covered)." A different cause than the previous test (there it
   was "File exists" on a plain directory) — here `@snapshots` was declared
   in `disk_config` with `mountpoint: "/.snapshots"`, so `archinstall`
   **mounted it itself** during disk setup, and `rmdir` failed with
   "Device or resource busy" (see point 6, that was the actual first
   symptom, before I got to `create-config` itself).
6. Fix for #5: removing `@snapshots` from `disk_config.btrfs` — we create
   it ourselves in the post-install step (exactly as in the first test),
   instead of trying to coexist with `archinstall`'s automatic mount.
7. After #6: **A NEW error in the same spot** — "subvolume already
   covered" again, but now for a different reason. Diagnosis (not
   guessing) showed: `/etc/snapper/configs/root` and `/home` **already
   existed, fully correct** (`SUBVOLUME="/"` and `SUBVOLUME="/home"`)
   BEFORE my own `create-config` call — almost certainly bootstrapped by
   the `snap-pac` hook (`05-snap-pac-pre.hook`/`zz-snap-pac-post.hook`,
   found in `/usr/share/libalpm/hooks/`) during some pacman transaction in
   `pacstrap`. My `create-config` was redundant. Fixed: checking whether
   the configs already exist (`test -f` + `grep SUBVOLUME`) instead of
   creating them. Domino effect: the post-install step then tried `btrfs
   subvolume delete /mnt/.snapshots`, which now had nothing to delete
   (because `/.snapshots` was already just a plain, `rmdir`-removed
   directory, not a subvolume) → "Could not statfs: No such file or
   directory". Fixed: removed that now-unnecessary line.

**After obstacle #7 (8th attempt): end-to-end success.**

## Verifying the result (not just "no error" — real content)

```
$ btrfs subvolume list /mnt
ID 256 gen 21 top level 5 path @
ID 257 gen 15 top level 5 path @home
ID 258 gen 16 top level 5 path @log
ID 259 gen 13 top level 5 path @pkg
ID 260 gen 12 top level 5 path var/lib/portables      (systemd default, harmless)
ID 261 gen 12 top level 5 path var/lib/machines        (systemd default, harmless)
ID 263 gen 15 top level 257 path @home/.snapshots      (snap-pac's own nested config for /home, expected)
ID 264 gen 16 top level 5 path @snapshots              (ours, top-level, created in post-processing)
```

- `/opt/pandacode/PandaCode.AppImage`: 92,908,024 bytes, `rwxr-xr-x` —
  downloaded and executable.
- `/usr/share/applications/pandacode.desktop`: present.
- `/etc/pandos-root-marker.txt` → `pandos-root-before-change` (correct
  content).
- `/home/pandos/home-marker.txt` → `home-marker: should survive any root
  rollback` (correct content).
- `grub-install` and `grub-mkconfig` finished with no error.
- `/etc/fstab` regenerated (`genfstab -U`) AFTER swapping in
  `@snapshots`, with the `/swapfile` entry from the host's `/proc/swaps`
  manually stripped out (a container-methodology artifact, not relevant to
  the real PandOS — see the previous test).

**A minor, result-irrelevant defect in my own verification script:**
`snapper -c root list-configs` in the verification command returned
"Failure (org.freedesktop.DBus.Error.FileNotFound)" — I forgot `--no-dbus`
in THAT one verification line (not in the install itself). Irrelevant,
since the config files' content was already verified directly via `grep`.

**A cosmetic, result-irrelevant defect right at the end:** `umount -R /mnt`
at the end of the script returned "target is busy" — the container unmounts
everything on exit anyway (`--rm`), it doesn't affect what was written to
the disk image.

## Files in the repo

- `pandos-config/user_configuration.json` — the final, working config.
- `pandos-config/provision.sh` — the content of the `custom_commands` field
  (a separate, readable file; when changed, it has to be pasted back into
  the JSON as the content of `custom_commands[0]`, ideally via a small
  Python script using `json.dump`, not by hand — avoids newline-escaping
  mistakes).
- `pandos-config/localectl-stub.sh` — a `localectl` stand-in (build-only,
  inside the container, never ends up in the actual PandOS image).
- `pandos-config/run-fast-loop.sh` — the driver: installs `archinstall`
  inside the container, plants the `localectl` stub and the wrapper that
  strips `-S` from `arch-chroot`, works around the `systemd-udevd` race
  condition, runs `archinstall`, and then does the post-install step
  (swapping in `@snapshots`, `grub-btrfsd`, `grub-mkconfig`, `genfstab`,
  verification).

Not committed (large binary files, `.gitignore`): the test disk image
(`pandos-full.img`, 14GiB), the build log.

## What was NOT verified in this iteration (deliberately, out of scope)

- Booting in QEMU and actually starting COSMIC/Wayland — per this
  iteration's scope, deferred to the "slow loop", which we only do after
  the fast loop is confirmed. That's the next step.
- Whether `pacman -Syu` on a live system actually creates a snapshot via
  `snap-pac` — to be verified in the slow loop / boot test.
- Integrating `btrfs-assistant` with a PandOS-specific wrapper — the
  mechanism was already verified in the previous test, not re-tested here.
