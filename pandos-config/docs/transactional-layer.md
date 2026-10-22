# Transactional layer — design doc

**Status: to be reconsidered later, NOT a priority before MVP (boot→ISO).**
Decided 2026-10-22: this is an interesting concept, but not a verified
need — we already have a working, empirically verified manual rollback via
`btrfs-assistant --restore` (CLI, confirmed in
`tests/btrfs-rollback-verification.md`). This document stays in the repo as
a starting point in case the need ever comes up, but it is not being
implemented right now. The priority is booting in QEMU, then the ISO.

## Concept

Goal: an agent (CLI) can roll back a failed pacman change on its own
without asking the human, with a guarantee confirmed by a real boot, not by
elapsed time.

**Principle:** a transaction is confirmed by booting
(`boot-complete.target`), not by time. Only completed pacman transactions
(`-S`, `-Syu`, `-R`); interrupted ones are outside the guarantee
(fail-open, requiring a manual decision).

**States:** `pending` → `confirmed` (happy path, 1 reboot) or `pending` →
`rolled-back` (requires a second reboot; the agent doesn't report success
before it).

**Persistence:** a separate `@pandos` → `/pandos` subvolume for tx-records,
attempt counters, logs. Fail-closed: no `@pandos` → `pandos-tx install`
refuses before making any change.

**Pacman hooks:** `pandos-tx-pre` (snapshot + tx-record), `pandos-tx-post`
(pending + `snapshot_id` read, not guessed), `pandos-tx-confirm` (via
`pandos-boot-confirm.service`).

**CLI contract (v1, no daemon):** `pandos-tx install/upgrade/status/
rollback/confirm/history`, a JSON response with state and `action_hint`.

**Option A (recommended for v1):** a second boot entry, "PandOS Recovery",
pointing at the snapshot; `/etc/grub.d/40_pandos` generates the entry from
the last tx-record.

## Implementation caveats (to account for if/when this comes back into scope)

1. **Pacman hook ordering:** `pandos-tx-pre.hook` must run after the
   `snap-pac` hook (e.g. name it `zz-pandos-tx-pre.hook`, or have the script
   check whether a snapshot already exists) — pacman runs hooks in
   alphanumeric order of filenames (this is a real, documented mechanism,
   not a guess). Otherwise `snapshot_id` will be `null`.

2. **`@pandos` and Snapper — CORRECTED 2026-10-22 (the first version of this
   caveat was wrong):** the original version talked about excluding
   `@pandos` from Snapper via `SUBVOLUME_EXCLUDE`. That's likely unnecessary
   and was never verified as a real Snapper option. `@pandos` as a
   top-level subvolume (a sibling of `@`) **is not covered by a snapshot of
   `@` purely by Btrfs's architecture** — that's exactly what we already
   verified empirically for `@home`/`@log`/`@pkg` (see
   `tests/btrfs-rollback-verification.md` and
   wiki.archlinux.org/title/Snapper: "a snapshot of @ does not cover other
   subvolumes"). To be confirmed for `@pandos` specifically in QEMU if/when
   we come back to this topic — but don't assume upfront that an extra
   exclusion mechanism is needed.

3. **`boot-complete.target` vs `graphical.target`:** verify in QEMU whether
   `pandos-boot-confirm.service` starts AFTER `graphical.target` (not
   before). If before — consider `After=graphical.target`.

## Open question

Whether this ever comes back into scope, and when, depends on whether the
need for "the agent rolls back changes on its own without asking the
human" ever genuinely comes up. For now: no.
