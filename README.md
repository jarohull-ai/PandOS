# PandOS

<p align="center">
  <img src="assets/pandos-mascot.png" width="420" alt="PandOS mascot — a panda with penguin feet">
</p>

An installable Linux for people who treat AI agents as their primary way of
working with a computer. [PandaCode](https://github.com/aicodeking/pandacode)
is the main entry point, not just another app next to the terminal or file
manager.

PandOS is being built first and foremost as the author's own daily driver,
and is aimed at people who work the same way. The image stays clean — no
baked-in API keys; the provider and agents you use are configured yourself
after installation.

## Status

**MVP boots end-to-end (2026-10-22), verified in QEMU, not just in theory:**
`archinstall` (config in `pandos-config/`) installs disk+packages+COSMIC+
PandaCode+Snapper in a single pass → the system boots to the graphical
COSMIC greeter → login works → the full COSMIC desktop comes up → PandaCode
starts under XWayland → Snapper and `snap-pac` automatically create
snapshots on the live system. Details and exact commands in
[`tests/full-config-verification.md`](tests/full-config-verification.md) and
[`tests/qemu-boot-verification.md`](tests/qemu-boot-verification.md).

**Installable ISO verified end-to-end (2026-10-22):** `pandos-iso/` (a fork
of archiso's `releng` profile) builds, boots in QEMU, detects a `cidata`
drive, and runs `archinstall` fully unattended — the system installs itself
and boots to a working COSMIC desktop on the first try, with no manual
intervention. PandOS stops being a config tested only in the fast loop and
becomes a real, installable system. Details, including a boot-order pitfall
in QEMU that was hit and fixed, are in
[`tests/qemu-boot-verification.md`](tests/qemu-boot-verification.md)
("Scenario B" section).

This file grows with the project and is the source of truth for decisions —
every significant architectural decision and its verification (or
rejection) lands here, with a date and a source.

## Project principles

1. **PandaCode as the entry point**, not one app among many.
2. **Clean system, no keys** — no tokens/API keys baked into the ISO image.
3. **Simple by default, open underneath** — a coherent agent-first
   experience, without hiding the system or blocking power-user mode.

## Architecture decisions

### Not forking Omarchy (2026-10-22)

The original plan assumed forking `omarchy`/`omarchy-iso` and swapping
Hyprland for COSMIC. Verified directly against the repos
(`omacom/omarchy`, `omacom/omarchy-iso`, `omacom/omarchy-pkgs`): Hyprland is
woven into at least three repos at once, the build requires Docker
`--privileged`, and the bootloader is Limine (not GRUB). The cost of
rewriting all of that for COSMIC outweighs the benefit of inheriting a
ready-made installer.

**Decision:** a clean Arch Linux + `archinstall` + COSMIC + preinstalled
PandaCode, built from scratch.

### COSMIC without AUR (confirmed 2026-10-22)

`cosmic-session` and `cosmic-greeter` are official packages in the `extra`
repo (`cosmic` group), not AUR. Checked directly against the Arch package
database.

### Build pipeline: archinstall + archiso, not a choice between them

Two loops at different speeds, not one single mechanism:

- **Fast loop ("sketch the architecture"):** `archinstall` + a JSON config +
  a Python provisioning script (COSMIC, Snapper, snap-pac, the PandaCode
  AppImage; mirror restricted to `core`/`extra`, no `testing`/AUR) run
  against a raw disk image file via `losetup` — no ISO/VM boot involved.
  `archinstall` needs `arch-chroot`/`genfstab`, so it runs inside an Arch
  container (`ghcr.io/archlinux/archlinux:latest`, `--privileged`), since
  the dev machine isn't Arch itself. The loop device doesn't work inside
  the container — `losetup` is done on the host, and the ready `/dev/loopX`
  is passed into the container.
- **Slow loop ("print to an ISO"):** a fork of archiso's `releng` profile
  (which already ships `archinstall` in its `packages.x86_64` — checked
  directly in the source at gitlab.archlinux.org/archlinux/archiso) + a
  systemd unit that looks for a `cidata` drive (the NoCloud/cloud-init
  convention, natively supported by Proxmox/Packer/libvirt) + `mkarchiso`.
  Run less often, only to verify the final product.

Python for provisioning, not Rust — `archinstall` has a native Python API
(`Installer`/`Profile`/`Application`), and the live environment requires
Python anyway. The arguments for Rust (consistency with PandaCode, memory
safety) don't apply to a one-shot install script.

**Fast-loop correction (2026-10-22, from the test in `tests/` + input from
DeepSeek, confirmed in source):** `archinstall` can't run end-to-end in a
bare `--privileged` container — it calls `localectl`/`systemctl` over D-Bus,
which needs a live systemd as PID 1. We're not investing in
`systemd-nspawn` at this stage. Fix: the JSON config omits `locale_config`
and `bootloader_config` — confirmed in source
(`archinstall/lib/installer.py:964-966`,
`archinstall/scripts/guided.py:117`) that both steps are conditional (`if
locale_config:` / `if config.bootloader_config:`) and simply don't run when
those fields are absent. In their place — `custom_commands` (a config
field, run at the very end of the install via `arch-chroot`,
`guided.py:181`): locale, hostname, user, `bootctl`/`grub-install`,
`systemctl enable`. `systemctl enable` works without a live systemd (it's
just unit-file symlinks) — unlike `localectl`, which actually queries the
daemon.

### Btrfs subvolume layout (confirmed from wiki.archlinux.org/title/Snapper + archinstall source, 2026-10-22)

The wiki suggests `@`→`/`, `@home`→`/home`, `@snapshots`→`/.snapshots`,
`@var_log`→`/var/log`, to protect `/home` from a `/` rollback. Pitfall:
`archinstall` versions older than 3.0.5 mount `@.snapshots` in a way that
breaks `snapper create-config` (GitHub issue #1808, linked directly from the
wiki) — use 3.0.5+.

**Important:** `archinstall`'s own default layout (the
`get_default_btrfs_subvols()` function in
`archinstall/lib/disk/default_layouts.py`, checked in source on the
`master` branch) is `@`→`/`, `@home`→`/home`, `@log`→`/var/log`,
`@pkg`→`/var/cache/pacman/pkg` — **without** `@snapshots`. It has to be
explicitly overridden in the JSON config (the `btrfs` field on the root
partition, a list of `{"name": ..., "mountpoint": ...}` objects, the
`SubvolumeModification` dataclass in `archinstall/lib/models/device.py`),
adding `@snapshots`→`/.snapshots` to the default list. Final list in use:
`@`, `@home`, `@log`, `@pkg`, `@snapshots`.

### Rollback mechanism — EMPIRICALLY CONFIRMED (2026-10-22)

Verified on a real VM (archinstall → arch-chroot → QEMU/UEFI → SSH), twice:
once with a manual subvolume swap, once with a real tool. Full log and
procedure in
[`tests/btrfs-rollback-verification.md`](tests/btrfs-rollback-verification.md).

**Rejected hypothesis:** `btrfs subvolume set-default` — untestable by
definition, because `grub-mkconfig` hardcodes `rootflags=subvol=@` into the
kernel line, so changing btrfs's "default subvolume" wouldn't change
anything about what actually boots.

**Working mechanism:** a top-level btrfs rename-swap (`subvolid=5`) — the
current `@` is renamed to a backup, and a new writable `@` is created as a
snapshot of the chosen restore point. Works **fully from a running, booted
system, with no Live USB needed** (the SSH session survived the entire
operation). After reboot: root restored, `/home` untouched.

[Btrfs Assistant](https://gitlab.com/btrfs-assistant/btrfs-assistant) (the
`btrfs-assistant` package, `extra`, not AUR) has a ready-made headless CLI
mode (`btrfs-assistant --list` / `--restore <index>`, works with
`QT_QPA_PLATFORM=offscreen`, no GUI) — **confirmed to do literally the same
rename-swap**, no need to reimplement the mechanism ourselves. This is a
candidate to be called directly from a PandOS UI/wrapper.

**Open for later:** cleanup of old `@_backup_*` subvolumes after a rollback
(not automatic), and the GUI (not just CLI) tool's behavior — unverified, no
graphical environment in the test.

### Package list — draft (2026-10-22)

**COSMIC:** installing `cosmic-session` (the `cosmic` group) is enough —
confirmed directly in its `depends` list in the Arch package database; it
pulls in `cosmic-greeter` (its own greeter, **GDM not needed**, even though
older 2024 guides recommended it) and `xorg-xwayland` (**needed by
PandaCode**, see below — this is automatic, nothing extra to do). Worth
adding explicitly as optional: `cosmic-terminal`, `cosmic-store`,
`cosmic-text-editor`, `gnome-keyring` (for storing AI provider keys per
project principle #2 — PandaCode itself doesn't hold keys, but the agent
CLIs it launches may want a system keyring).

**PandaCode — requirements confirmed from its own README (2026-10-22):**
needs `fuse2` (the `fuse2` package, official `extra` repo, not AUR) to run
the AppImage without `APPIMAGE_EXTRACT_AND_RUN=1`; needs X11 or XWayland
(see COSMIC above — already covered); needs `git` plus at least one agent
CLI (Claude Code / Codex / etc.) installed separately — **PandaCode
deliberately ships none of that**, the user installs and logs in
themselves. This is consistent with project principle #2, not something to
work around. Installing PandaCode itself: the AppImage from
`github.com/aicodeking/pandacode/releases/latest/download/PandaCode-Linux-x86_64.AppImage`
into e.g. `/opt/pandacode/`, `chmod +x`, a `.desktop` entry plus optional
autostart.

**Safety layer:** `btrfs-progs`, `snapper`, `snap-pac`, `btrfs-assistant`
(all in `extra`, zero AUR).

**Base:** `base`, `linux`, `networkmanager`, `git`, `sudo`, bootloader (to
be finalized for the final product — the test VM uses `grub` for
simplicity, see `tests/`).

**Open, undecided:** which browser to preinstall (nothing chosen yet — to
be decided, not guessed).

## Open decisions

### Transactional layer — deferred (2026-10-22)

A designed concept (`pandos-config/docs/transactional-layer.md`): a
`pandos-tx` CLI, confirming pacman transactions via a real boot (not time),
automatic rollback without asking the human. **Decision: not a priority
before MVP.** We already have a working, verified manual rollback via
`btrfs-assistant --restore` — that's enough for now. The document stays in
the repo as a starting point in case this need comes back later, but none
of it is being implemented right now.

### Distributed agents / local models — NOT deferred as a document, just declined for now (2026-10-22)

Unlike the transactional layer, this idea (distributed agents, local models
via Ollama, `pandos-tx` permissions for agents) **has no design doc in the
repo yet** — the explicit decision was "not now, back to ISO" and the topic
was never even written down. If it comes back, it first needs its own
document (like `pandos-config/docs/transactional-layer.md`), not
implementation straight away.

## What's next (post-MVP)

A short list of priorities after closing out the installable ISO
(2026-10-22), so nothing needs to be reconstructed from memory a week from
now. None of these items are in progress — this is a record of state, not
new work:

| # | Topic | Status |
|---|-------|--------|
| 1 | Bridge networking instead of `user`/NAT in QEMU tests | Worth considering — would speed up further ISO test iterations, not implemented, not recorded anywhere else |
| 2 | `fatal library error, lookup self` in a pacman hook | Non-blocking, to be investigated eventually (see `tests/qemu-boot-verification.md`) |
| 3 | Transactional layer (`pandos-tx`) | Design doc ready (`pandos-config/docs/transactional-layer.md`), implementation deferred pending a priority decision |
| 4 | Distributed agents / local models | **No design doc yet** — declined for now, not written down; priority only after MVP ISO, if at all |
| 5 | Distributing the ISO to others (not just personal use) | Open question, no decision made — to be thought through if PandOS is meant to go beyond the author's own use |

Context for item 4 (so it isn't a mystery a month from now, without writing
a design doc): the topic came up in a planning discussion on 2026-10-22
(pasted into this project's Claude Code chat as a Codex-authored brief — no
separate file exists; the full text can be found by searching that
session's transcript for "rozproszenie i lokalne modele" if it's ever
needed verbatim). Two levels, both deferred: (1) remote inference — the
agent/code stay on PandOS, model requests go to a second machine over an
OpenAI-compatible API (Ollama); (2) remote work execution — an agent on the
second machine gets a worktree and runs commands, which needs a
queue/locking/permissions model. The argument isn't simply "local instead
of cloud" — it's small models for narrow tasks (formatting, classification,
boilerplate) with automatic escalation to a larger model/cloud when the
local result fails tests, judged on measured savings (share of local tasks,
number of escalations, time). Priority only after MVP ISO and after real
measurements, not assumed upfront.

## Repo structure

`pandos-config/` (`archinstall`: `user_configuration.json`, `provision.sh`,
`run-fast-loop.sh`, `docs/`) and `pandos-iso/` (`archiso`:
`configs/pandos/`, `test-qemu-boot.sh`) both already exist and work — the
fast loop, the slow loop, and installing from the ISO are all three
verified (`tests/full-config-verification.md`,
`tests/qemu-boot-verification.md`).
