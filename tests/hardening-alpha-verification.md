# Hardening alpha — verification log (2026-10-23/24)

Follow-up to Codex's 2026-10-23 review (`PandOS is a verified QEMU
installation prototype — not yet safe for distribution`). Scope: the
concrete, fixable issues from that review, tackled one at a time per
Jaro's own priority call, each verified for real before being considered
done. Test credentials (`pandos`/`pandos`, root SSH) were explicitly
deferred — not addressed here.

## 1. Disk-selection bug in `autoinstall.sh` — FIXED, verified

**File:** `pandos-iso/configs/pandos/airootfs/root/pandos/autoinstall.sh`

**Problem:** the old exclusion logic computed `CIDATA_PARENT` via
`lsblk -no PKNAME "$CIDATA_DEV"`. If the `cidata` filesystem is written
directly to a whole disk with no partition table (a realistic scenario —
some tools write NoCloud media that way), `PKNAME` is empty for a
top-level disk device, the exclusion check `[ "$name" = "$CIDATA_PARENT" ]`
never matches, and the cidata medium itself could be picked as the install
target.

**Fix:** detect whether `$CIDATA_DEV` itself is a whole disk
(`lsblk -no TYPE`) and use its own name directly in that case; otherwise
fall back to `PKNAME` as before. Fail closed (exit 1, no guessing) if the
backing disk still can't be determined.

**Verification:** the real, unmodified logic was extracted from the file
and run against three mocked `blkid`/`lsblk` scenarios (no real block
devices/sudo needed):
- cidata on a whole disk, no partition table (the bug case) → target
  correctly resolves to the other disk, never the cidata medium.
- cidata on a partition (normal case) → unchanged, still correct.
- no cidata drive present → script still exits 0 and stays interactive
  (confirms the fix doesn't break the no-op path).

## 2. Missing `set -e` / silent post-processing failures — FIXED, verified

**File:** same `autoinstall.sh`.

**Problem:** the script only had `set -x`. If mounting a subvolume,
`grub-mkconfig`, or `genfstab` failed after a successful `archinstall`
run, the script would keep going and still print `POST_PROCESSING_OK`.

**Fix:** `set -ex`. Two places needed explicit handling to avoid breaking
existing behavior under `set -e`:
- `CIDATA_DEV=$(blkid -L cidata ... || blkid -L CIDATA ... || true)` — the
  trailing `|| true` keeps the "no cidata drive, stay interactive" path
  alive (otherwise the failing command substitution itself would abort
  the script before that check ever ran).
- `archinstall`'s own exit code is now captured via `if archinstall ...;
  then RC=0; else RC=$?; fi` instead of `archinstall ...; RC=$?` — a bare
  failing command right before the `$?` read would abort under `set -e`
  before that line ever ran.
- The final `umount -R /mnt` got `|| true`: a busy unmount at that exact
  point doesn't mean data loss (every write already landed via its own
  successful mount/arch-chroot call) and must not block reaching
  `POST_PROCESSING_OK` and the reboot.

**Verification:** syntax-checked, plus an isolated test confirming the
`if/else` exit-capture pattern survives `set -e` without aborting.

## 3. Hardcoded partition size — FIXED, verified

**File:** same `autoinstall.sh`.

**Problem:** the root partition size was a literal value
(`13822 MiB`) sized for the one test disk. On a bigger disk the rest was
wasted; on a smaller one `archinstall` could fail outright (asking for a
partition bigger than the disk).

**Checked first, not assumed:** downloaded the real `archinstall` 4.0
wheel from PyPI and read `archinstall/lib/models/device.py` — there is no
percent/"fill remaining space" `Unit` in its `Size` model, so this has to
be computed ourselves, not expressed declaratively in the JSON.

**Fix:** `blockdev --getsize64 "$TARGET_DISK"` reads the real disk size at
install time; root length = disk size − boot partition − 2 MiB GPT
headroom. Refuses to continue (clear error, before touching the disk) if
that leaves less than ~1.5 GiB for root.

**Verification:** the real sizing + JSON-patching logic was extracted and
run against four real disk-size scenarios (fake `blockdev`, real
`python3`/`jq`-equivalent JSON check):

| Disk | Old hardcoded value | New computed value |
|---|---|---|
| 14 GiB (the original test disk) | 13822 MiB | 13821 MiB — matches, no regression |
| 100 GiB | 13822 MiB (rest wasted) | 101885 MiB — uses the whole disk |
| 8 GiB | 13822 MiB (**would have failed** — bigger than the disk) | 7677 MiB — fits correctly |
| 1 GiB | — | clean error before any install attempt, instead of failing midway |

## 4. Default browser (`epiphany`) + an unrelated `archinstall` regression — FIXED, verified

**Context:** PandaCode's own cloned source
(`src-tauri/src/lib.rs:open_external_url`, invoked from `agent-input.ts`,
`github-hub.ts`, `github.ts`, `overlay.ts`, `main.ts`, and others) shells
out to `xdg-open` for every external link in the UI — agent messages,
GitHub issues/PRs, docs. PandaCode's *own* embedded browsing surface
(`src-tauri/src/browser.rs`) is a separate thing used only by agents for
page inspection and doesn't need a system browser. Without a real browser
installed, every one of those `xdg-open` calls fails. Decision: add
`epiphany` (GNOME Web) — confirmed in the official `extra` repo (not
AUR), shares the WebKit engine PandaCode's own Tauri webview already
needs (`webkitgtk` in `src-tauri/Cargo.toml`) instead of adding a second
heavy engine like Firefox/Gecko. Its real dependency list (checked via
the Arch package API) is plain GTK4/libadwaita/webkitgtk-6.0 — no
`gnome-shell`/`gnome-session`, so no hard GNOME-desktop requirement that
would conflict with COSMIC.

Added to the `packages` list in both `pandos-config/user_configuration.json`
and the ISO's bundled copy
(`pandos-iso/configs/pandos/airootfs/root/pandos/user_configuration.json`
— a separate file, not a symlink; both must be edited together, a minor
process risk worth knowing about).

**Unrelated but blocking discovery while verifying this:** rebuilding the
fast loop to check that `epiphany` actually lands on the installed system
hit a real, reproducible failure that had nothing to do with `epiphany` —
`archinstall` itself. Confirmed:

- `pacman -Q archinstall` in a fresh container today: **4.5-1**. The same
  script ran clean on 2026-10-22 — this is a regression introduced
  upstream between then and now, not a PandOS bug.
- Read `device_handler.py`'s `partition()` method directly in that
  version: it calls `wipefs --all` on every newly created partition
  *before* calling `udev_sync()`, with the method's own comment reading
  "Sync with udev after wiping signatures" (the wrong order, confirmed by
  reading the source, not guessed) → `wipefs: error: /dev/loopXpN:
  probing initialization failed: No such file or directory`.
- Isolated test (manual `parted` + `losetup -P`, no `archinstall`
  involved) to find the real cause: the kernel registers the new
  partitions immediately (`/proc/partitions` has them right away), but
  bare `systemd-udevd` running without a real PID 1/systemd in this
  container **never creates the `/dev/loopXpN` node or populates its own
  database** for them — not `udevadm settle`, not `udevadm trigger`, not
  `partprobe`, not `blockdev --rereadpt`. This is a udev problem, not a
  timing race, so retry-with-sleep alone never recovers (confirmed: 10
  retries with `partprobe`+`settle`+`sleep 1` each still failed
  identically).
- What does work, confirmed in isolation before being wired in:
  `udevadm trigger --action=add --sysname-match=<name>` forces udev to
  treat it as a fresh device and actually populates both the node and its
  database (`PARTN`/`PARTUUID` fields `lsblk` needs). Losetup's own error
  message for a similar lost-node situation literally suggests the same
  recovery tool ("You may use `mknod(1)` to recover it").
- Even `archinstall`'s own `udev_sync()` helper (used correctly, *after*
  formatting, before `fetch_part_info()`) is nothing but a plain
  `udevadm settle` — insufficient for the same reason.

**Fix, `pandos-config/run-fast-loop.sh`** (same wrap-the-tool technique
already used there for `arch-chroot -S`-stripping): two small wrapper
scripts installed before `archinstall` runs.
- `wipefs` wrapper: retries up to 5 times on "No such file or directory",
  looking up the missing partition's real major:minor in
  `/proc/partitions` and `mknod`-ing it before each retry (wipefs itself
  runs *before* any `udev_sync()` call in `archinstall`'s own code, so
  waiting for a later `settle` wouldn't help here).
- `udevadm` wrapper: whenever anything calls `udevadm settle` — including
  `archinstall`'s own internal `udev_sync()` — first scans
  `/proc/partitions` for any loop partition missing its `/dev` node,
  `mknod`s it, and runs the real `trigger --action=add` for it, then
  calls the real `settle`. This covers every other call site in
  `archinstall` without having to special-case each one.

**End-to-end verification:** a full fast-loop rebuild (real
`archinstall` in a privileged Arch container, not a dry run) completed
start to finish with both fixes in place — `archinstall` succeeded,
`@`/`@home`/`@log`/`@pkg`/`@snapshots` all created correctly,
`grub-mkconfig` succeeded, `fstab` generated, PandaCode AppImage present,
rollback markers present, `POST_PROCESSING_OK` printed. Confirmed on the
resulting disk, via `pacman -Q` over SSH after booting it in QEMU:
`epiphany 51.1-2`, `cosmic-session 1:1.10.0-1`, `graphical.target` and
`greetd` both `active`, `org.gnome.Epiphany.desktop` present.

**Left honestly open, not claimed as done:** a full visual launch of
`epiphany` inside a real, authenticated COSMIC desktop session. Launching
it directly against the greeter's own Xwayland `:0` as the `pandos` user
was correctly rejected by X11 authorization (`pandos` has no cookie for
`cosmic-greeter`'s own display — expected security behavior, not a bug),
and GDK did get far enough to attempt a display connection without any
missing-library or platform-incompatibility crash. Launching a second,
independent `cosmic-session` as `pandos` directly (bypassing the greeter)
started the process but it never progressed past D-Bus/session setup
without a real logind-assigned seat. A clean test would need to script
the actual greetd login (IPC or QMP keystrokes) — not done here; the two
cosmic-session-related smaller tests above are decent secondary evidence
(no dependency conflict, no crash-on-missing-library), but not a
substitute for watching it actually render under a real login.

## Two small process notes for later

- `pandos-config/run-fast-loop.sh`/`user_configuration.json` hardcode
  `/dev/loop10` as the build loop device. On a host with many installed
  snaps (`snapd` claims loop devices sequentially from 0 up — this host
  had 36 of them), that number can collide with a real, in-use snapd
  loop mount. Should use `losetup -f` (first free) instead of a fixed
  number.
- The ISO's bundled `user_configuration.json`
  (`pandos-iso/configs/pandos/airootfs/root/pandos/user_configuration.json`)
  is a separate copy of `pandos-config/user_configuration.json`, not a
  symlink. Both need the same edit when the package list changes — easy
  to forget one.
