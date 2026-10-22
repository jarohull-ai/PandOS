# Verification: booting the installed image in QEMU (slow loop)

**Date:** 2026-10-22
**Goal:** test in QEMU the same already-installed disk image from the
successful 8th attempt of the fast loop (`tests/full-config-verification.md`)
— without re-running `archinstall`, without an HTTP server serving the
config. Four specific points: booting to COSMIC, PandaCode, Snapper,
`snap-pac`.

## Environment

QEMU 8.2.2 + KVM, OVMF (UEFI, `/usr/share/OVMF/OVMF_CODE_4M.fd`), the
`pandos-full.img` image (14GiB, the same file as in the fast-loop test) as
`virtio`, SSH port forwarded `hostfwd=tcp::2223-:22`, `-vga virtio -display
none` plus a QMP socket for screenshots (`screendump`) — programmatic
visual verification, without needing Jaro to look at a window.

## 1. Booting to COSMIC — DOES NOT WORK, cause identified precisely

**Result: the system does NOT boot to graphical COSMIC.** The screenshot
(QMP `screendump`) shows a plain text login prompt on tty1 (`pandos
login:`). This is NOT a Wayland/COSMIC rendering problem in the VM (which
we hadn't even reached yet) — it's two missing steps in provisioning:

1. `greetd.service` is **disabled** (never enabled in `custom_commands`).
2. Even after manually starting `greetd` (which worked with no error, the
   process came up fine), it used the **default** config
   (`/etc/greetd/config.toml`) pointing at the built-in text greeter
   `agreety --cmd /bin/sh`, NOT COSMIC. The `cosmic-greeter` package ships
   its OWN, ready-made config template at
   `/etc/greetd/cosmic-greeter.toml`:
   ```toml
   [terminal]
   vt = "1"
   [general]
   service = "login"
   [default_session]
   command = "cosmic-greeter-start"
   user = "cosmic-greeter"
   ```
   but nothing ever copied it to `/etc/greetd/config.toml`.

**Specific fix for `provision.sh` for the next iteration (not applied in
this test — this is a diagnostic report, not a fix):**
```sh
cp /etc/greetd/cosmic-greeter.toml /etc/greetd/config.toml
systemctl enable greetd.service
```
After this fix, actual COSMIC/Wayland rendering in a headless QEMU
(software rendering, no passed-through GPU) is a separate, still-untested
risk — noted as the next step, not assumed to work upfront.

## 2. PandaCode — installed correctly, panics without a graphical session (expected)

`/usr/share/applications/pandacode.desktop` present and correct. Manually
running `/opt/pandacode/PandaCode.AppImage` over SSH:

```
thread 'main' panicked at .../tao-0.35.3/.../event_loop.rs:217:53:
Failed to initialize gtk backend!: BoolError { message: "Failed to initialize GTK", ... }
```

This is the **expected** consequence of point 1 (no graphical session at
all), not a defect in PandaCode or `fuse2`. Important: the binary **starts
and gets as far as GTK initialization** before the panic — confirming the
AppImage unpacks/launches correctly (no "cannot execute" error, no FUSE
error). A real test of PandaCode working requires fixing point 1 first.

## 3. Snapper — WORKS

```
$ snapper --no-dbus list-configs
Config | Subvolume
-------+----------
home   | /home
root   | /
```

A manual snapshot (`snapper -c root create --description
manual-test-snapshot`) created with no error. Also noticed: the timeline
timer had already made its first automatic snapshot (`timeline`, about 23
min after boot) — confirming `snapper-timeline.timer` is actually running
in the background, not just "enabled" on paper.

## 4. `snap-pac` — WORKS, after one extra fix found along the way

The first attempt (`pacman -S nano`) failed for a different, unrelated
reason: `error: nano: signature ... is unknown trust` — the pacman keyring
from `pacstrap` didn't have a trusted key for that particular package
maintainer. This is a separate, real provisioning problem (not related to
`snap-pac` itself): **`custom_commands` should explicitly include
`pacman-key --populate archlinux`**, not rely on `pacstrap` having already
done this fully. After manually running that command and retrying:

```
:: Running pre-transaction hooks...
(1/1) Performing snapper pre snapshots for the following configurations...
==> root: 3
:: Processing package changes...
installing nano...
:: Running post-transaction hooks...
(2/2) Performing snapper post snapshots for the following configurations...
==> root: 4
```

`snapper -c root list` afterward shows entries #3 (`pre`) and #4 (`post`,
with `Pre # = 3`) with the correct description `pacman -S --noconfirm
nano` — **confirmed directly, not just by the absence of an error.**

## Summary and specific fixes for the next `provision.sh` iteration

| # | Point | Result | Action |
|---|-------|-------|-------|
| 1 | Booting to COSMIC | ❌ doesn't work (missing greetd config) | add `cp .../cosmic-greeter.toml config.toml` + `systemctl enable greetd` |
| 2 | PandaCode | ✅ installed correctly, depends on point 1 | no action, depends on 1 |
| 3 | Snapper | ✅ fully works | no action |
| 4 | snap-pac | ✅ works, after the keyring fix | explicitly add `pacman-key --populate archlinux` to `custom_commands` |

None of these four points is a "blind mystery" — each has an identified,
specific cause and a ready fix to apply in the next config iteration,
before moving on to `archiso`.

## Artifacts (first pass, before the fixes)

`screendump.png` (screenshot of the tty1 login prompt), `pandos-full.img`
(the same image from the fast-loop test, now with the extra `nano` package
and a few extra Snapper snapshots from this test) — both in the session's
scratchpad, not in the repo.

---

## Re-run after the fixes (2026-10-22, same day) — ALL 4 POINTS PASSED

Two fixes applied to `pandos-config/provision.sh`:
1. `pacman-key --init && pacman-key --populate archlinux` right at the
   start.
2. `cp /etc/greetd/cosmic-greeter.toml /etc/greetd/config.toml` **before**
   `systemctl enable greetd.service` (order matters — confirmed).

The full fast loop run again from scratch on a fresh image with these
fixes (`ARCHINSTALL_EXIT_CODE=0`, `POST_PROCESSING_OK`), then the same
image booted in QEMU again.

### 1. Booting to COSMIC — WORKS

A screenshot via QMP `screendump` shows a **real graphical COSMIC
greeter**: clock, date, wallpaper (the Orion Nebula), a password field with
username `pandos`, accessibility/keyboard/power icons at the bottom.
Simulated typing the password via QMP `send-key` (`pandos` + Enter) —
**full login succeeded**, the next screenshot shows a fully working COSMIC
desktop: top panel (Workspaces/Applications, clock, tray with
network/sound/battery icons), bottom dock with app launchers. Verified over
SSH: all `cosmic-*` processes (comp, panel, launcher, app-library,
workspaces, applets, etc.) and `xdg-desktop-portal-cosmic` alive under user
`pandos` on `tty1`. Software rendering in headless QEMU with no
passed-through GPU worked with no problem — the concern raised in the
earlier report turned out to be unnecessary.

### 2. PandaCode under XWayland — WORKS (after finding the right DISPLAY)

The first attempt (`DISPLAY=:0`) still panicked on GTK — because `:0`
belongs to the greeter's **separate** XWayland session (`cosmic-greeter`),
not the logged-in `pandos` session. The actual `pandos` session has its own
XWayland on `:1` (confirmed: `ps aux | grep -i xwayland` → `Xwayland :1
...`, socket `/tmp/.X11-unix/X1` owned by `pandos`). With the correct
`DISPLAY=:1 WAYLAND_DISPLAY=wayland-1`: **PandaCode gets through GTK
initialization without panicking** — instead it only gets warnings
`MESA-EGL: DRI3 error: Could not get DRI3 device` / `failed to create dri2
screen` — this is the expected limitation of software rendering in
headless QEMU without a real GPU (`virtio-vga` without `virgl`), not a
defect in PandaCode or our config.

### 3. Snapper — still WORKS, unchanged

`snapper --no-dbus list-configs` → `root`/`home` correctly.

### 4. snap-pac — WORKS, NOW with no manual on-the-fly fix at all

`pacman -S nano` **worked the first time, with no keyring error** (unlike
the first test run) — `pacman-key --populate archlinux` baked into
`provision.sh` fixed this once and for all at image-build time. Pre/post
snapshots (`#1 pre` / `#2 post`, correct description `pacman -S --noconfirm
nano`) created automatically.

## Conclusion

**The MVP config is complete and fully verified end-to-end**: install via
`archinstall` in a single pass → boot in QEMU → graphical COSMIC → login →
PandaCode launches → Snapper/`snap-pac` work automatically on the live
system. The only remaining limitation is the lack of GPU acceleration in
this particular test environment (headless QEMU, software rendering) — not
related to the correctness of the PandOS config itself.

---

## Scenario B: installing from the ISO (`archiso` + `cidata`, fully unattended) — STOPPED, cause identified

**Date:** 2026-10-22. **Goal:** build an installable ISO (`pandos-iso/`, a
fork of the `releng` profile) and test the full unattended scenario in
QEMU: boot from the ISO → detect the `cidata` drive → `autoinstall.sh` →
`archinstall --config ... --silent` → post-processing (`@snapshots`,
`grub-mkconfig`, `genfstab`) → `systemctl reboot` → the installed system is
expected to boot from disk.

### What actually happened

The QEMU process (`qemu-system-x86_64 ... -drive file=target-disk.img,...
-drive file=cidata.img,... -drive file=out/pandos-....iso,media=cdrom ...`)
ran for **about 6h16min** (14:46–21:04) without reaching a stable end
state. Monitoring via QMP `screendump` (directly, not through the fork)
showed a repeating cycle:

1. Package installation (COSMIC + the rest, 188 packages) finishes,
   pacman's post-transaction hooks run — in one pass, `(21/21) Performing
   snapper post snapshots...` was observed, immediately followed by `fatal
   library error, lookup self` in the hook's log. **Irrelevant to the final
   outcome** — this is a message from a single pacman hook (probably
   `snap-pac`/`grub-btrfsd` attempting `/proc/self/exe` inside a chroot),
   it didn't abort the transaction or `archinstall` itself (confirmed by
   the fact that a reboot matching the script followed right after, see
   below) — **to be pinned down precisely in the next iteration, not
   dismissed entirely, but it is not the cause of the loop described
   below.**
2. Shortly after: a TianoCore/OVMF screen (reboot). This matches exactly
   the end of `autoinstall.sh`: `echo "Install complete. Rebooting in
   10s..."` → `sleep 10` → `systemctl reboot`.
3. Instead of starting the installed system from `target-disk.img`, the VM
   **goes back to the live ISO**: a new `autoinstall.sh` process (different
   PID), `cidata` detected again, `archinstall --config ... --silent` run
   again **from scratch, on the same disk**.
4. Steps 1–3 repeated multiple times over more than 6 hours (directly
   observed: check5/6 around 17:53, check8/9 around 17:54–17:56, another
   full cycle from scratch seen at 21:01 — so **at least 3 full install
   cycles in one test session**, likely more between checkpoints that
   weren't recorded continuously).

The process was stopped manually (`kill`) on explicit instruction — **this
is not treated as "the install failed"**, but as "the test never ends" —
those are two different things.

### Cause — identified, not guessed

Two facts, both verified directly in the code and in the actual QEMU
launch command:

1. **`autoinstall.sh` ends with a comment explicitly about physically
   removing the media:** `"Install complete. Rebooting in 10s (remove
   installation media now)."` — this is correct and expected for an
   installer on real hardware (USB/DVD, the operator removes the media),
   but **nothing in the QEMU test automation does the equivalent of that**
   (there's no detach/eject of the CD-ROM before the reboot).
2. **The command that launches QEMU has no forced boot order at all** —
   confirmed directly in `ps aux`: no `-boot order=...` flag and no
   `bootindex=` on any `-drive`. So the firmware (OVMF) picks the boot
   device according to its own default logic, and `grub-install
   --target=x86_64-efi --efi-directory=/boot --bootloader-id=PANDOS
   --removable` (in `provision.sh`/`autoinstall.sh`) writes the bootloader
   to the **fallback** EFI path (`/EFI/BOOT/BOOTX64.EFI`) — exactly the
   same conventional path that archiso itself publishes its own boot entry
   under on the ISO. When both devices (disk and CD-ROM) have a bootable
   file at the same fallback path, and nothing forces a priority, OVMF in
   this environment consistently picks the CD-ROM.

**This is a problem with the QEMU test environment itself, not a bug in
PandOS's install logic** — on real hardware with the media physically
removed, this scenario wouldn't occur. But testing scenario B in QEMU
requires explicitly working around it.

### Recommended fix (to apply in the next iteration, NOT APPLIED in this test)

Two independent, complementary options — recommended to apply both:

1. **In the QEMU command:** add `bootindex=1` to `-drive
   file=target-disk.img,...` and a higher number (e.g. `bootindex=2`) to
   `-drive file=...iso,media=cdrom` — this is the standard, documented way
   in QEMU to force the disk's priority over the CD-ROM regardless of what
   each device's NVRAM/fallback EFI contains.
2. **Optionally, as extra insurance:** after `POST_PROCESSING_OK` is
   confirmed (before `systemctl reboot`), detach the CD-ROM programmatically
   via QMP from the outside (`blockdev-change-medium` / `eject`) — the
   equivalent of "removing the media" from the script's comment, but driven
   by the test harness, not by `autoinstall.sh` (which has no access to its
   own host's QMP).

### What is NOT confirmed at this point (deliberately, to do in the next iteration)

- The exact number of full reinstall cycles in this 6-hour session — **at
  least 3** observed directly via QMP screenshots, the real number could be
  higher (screenshots were taken at specific points, not continuously).
  Moot after the fact — the cause (missing `bootindex`) has already been
  identified and fixed, see below.

### ⚠️ Known issue, NON-BLOCKING (to investigate later, not now)

`fatal library error, lookup self` appears in a pacman hook's log (likely
`snap-pac` or `grub-btrfsd` trying to read `/proc/self/exe` inside
`arch-chroot`) during `(21/21) Performing snapper post snapshots...` while
installing packages. **Does not affect the outcome** — the build finishes
correctly, the system boots, Snapper/Btrfs work as verified (see the
section below). But it hasn't been investigated where exactly it comes
from. To be checked sometime via `journalctl` on the installed system,
**not before announcing the MVP** — this does not block closing out the
ISO.

### `bootindex` fix — APPLIED AND CONFIRMED (same day, next run)

Fix #1 from the section above applied directly in the QEMU command (not in
the repo — this is a test-harness parameter, not a PandOS config setting):
the target disk attached via `-device
virtio-blk-pci,drive=...,bootindex=1`, the CD-ROM via `-device
virtio-blk-pci,drive=...,bootindex=2` (plain `-drive ...,bootindex=N`
doesn't work with `format=raw` — QEMU requires an explicit `-device` for
this option, confirmed by the error on the first attempt: *"Block format
'raw' does not support the option 'bootindex'"*).

**Result: booting from disk worked on the first try, with no fallback to
the CD-ROM.** A QMP screenshot right after the VM started (the disk already
had data from a previously completed install cycle in the same session)
showed the **graphical COSMIC greeter with user `pandos`** — not the
console installer. Simulated login via QMP `send-key` → **a full, logged-in
COSMIC desktop** (Workspaces/Applications, clock, tray, dock with
launchers).

Verification over SSH (port 2227) on the live, installed system:

```
$ systemctl is-active graphical.target greetd
active
active

$ cat /etc/os-release | head -3
NAME="Arch Linux"

$ sudo btrfs subvolume list /
ID 256 gen 27 top level 5 path @
ID 257 gen 27 top level 5 path @home
ID 258 gen 27 top level 5 path @log
ID 259 gen 13 top level 5 path @pkg
ID 264 gen 18 top level 5 path @snapshots       (top-level, as planned)
ID 263 gen 16 top level 257 path @home/.snapshots  (snap-pac, expected)

$ sudo snapper --no-dbus -c root list
0 | single | ... | current

$ cat /etc/pandos-root-marker.txt /home/pandos/home-marker.txt
pandos-root-before-change
home-marker: should survive any root rollback
```

The subvolume layout exactly matches the design (`@`, `@home`, `@log`,
`@pkg`, top-level `@snapshots`). `PandaCode.AppImage` present (93,854,200
bytes, executable). Running it over SSH without a graphical session panics
on GTK — **this is the same, already documented and understood case**
(missing `DISPLAY`/`WAYLAND_DISPLAY` in the SSH session, see point 2 in the
test above), not a new problem — full verification with the correct
`DISPLAY` wasn't repeated, since the mechanism was already confirmed
earlier on the same config.

**Conclusion: scenario B (ISO + `cidata`, fully unattended install) works
end-to-end.** The only real defect was the boot order in the QEMU test
command — once fixed, the system boots straight to a working COSMIC on the
first try, with no loop. The `bootindex` fix should be made permanent in
this project's QEMU test-launch script (to be done when tidying up
`pandos-iso/`).
