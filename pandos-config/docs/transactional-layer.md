# Warstwa transakcyjna — design doc

**Status: do rozważenia później, NIE priorytet przed MVP (boot→ISO).**
Zdecydowane 2026-10-22: to jest ciekawa koncepcja, ale nie weryfikowana
potrzeba — mamy już działający, zweryfikowany ręczny rollback przez
`btrfs-assistant --restore` (CLI, potwierdzone empirycznie w
`tests/btrfs-rollback-verification.md`). Ten dokument zostaje w repo jako
punkt wyjścia, gdyby ta potrzeba kiedyś się pojawiła, ale nie jest teraz
implementowany. Priorytetem jest boot w QEMU, potem ISO.

## Koncepcja

Cel: agent (CLI) może sam wycofać nieudaną zmianę pacmana bez pytania
człowieka, z gwarancją potwierdzoną przez realny boot, nie przez upływ czasu.

**Zasada:** transakcja jest potwierdzana przez boot (`boot-complete.target`),
nie przez czas. Tylko zakończone transakcje pacman (`-S`, `-Syu`, `-R`);
przerwane są poza gwarancją (failed-open, wymagają ręcznej decyzji).

**Stany:** `pending` → `confirmed` (szczęśliwa ścieżka, 1 reboot) albo
`pending` → `rolled-back` (wymaga drugiego rebootu; agent nie raportuje
sukcesu przed nim).

**Trwałość:** osobny subwolumen `@pandos` → `/pandos` na tx-recordy, licznik
prób, logi. Fail-closed: brak `@pandos` → `pandos-tx install` odmawia przed
jakąkolwiek zmianą.

**Hooki pacman:** `pandos-tx-pre` (snapshot + tx-record), `pandos-tx-post`
(pending + `snapshot_id` odczytany, nie zgadywany), `pandos-tx-confirm`
(przez `pandos-boot-confirm.service`).

**Kontrakt CLI (v1, bez daemona):** `pandos-tx install/upgrade/status/
rollback/confirm/history`, odpowiedź JSON ze stanem i `action_hint`.

**Opcja A (rekomendowana dla v1):** drugi wpis rozruchowy "PandOS Recovery"
wskazujący na snapshot; `/etc/grub.d/40_pandos` generuje wpis z ostatniego
tx-recordu.

## Zastrzeżenia implementacyjne (do uwzględnienia, jeśli/gdy to wróci do realizacji)

1. **Kolejność hooków pacmana:** `pandos-tx-pre.hook` musi wykonać się po
   hooku `snap-pac` (np. nazwa `zz-pandos-tx-pre.hook`, albo sprawdzenie w
   skrypcie, czy snapshot już istnieje) — pacman wykonuje hooki w porządku
   alfanumerycznym nazw plików (to prawdziwy, dokumentowany mechanizm, nie
   zgadywanie). Inaczej `snapshot_id` będzie `null`.

2. **`@pandos` i Snapper — POPRAWIONE 2026-10-22 (pierwsza wersja tego
   zastrzeżenia była błędna):** oryginalna wersja mówiła o wykluczeniu
   `@pandos` ze Snappera przez `SUBVOLUME_EXCLUDE`. To prawdopodobnie
   niepotrzebne i niezweryfikowane jako realna opcja Snappera. `@pandos` jako
   top-level subwolumen (siostrzany do `@`) **nie jest objęty snapshotem `@`
   z samej architektury Btrfs** — to dokładnie to, co już zweryfikowaliśmy
   empirycznie dla `@home`/`@log`/`@pkg` (patrz
   `tests/btrfs-rollback-verification.md` i wiki.archlinux.org/title/Snapper:
   "snapshot @ nie obejmuje innych subwolumenów"). Do potwierdzenia dla
   `@pandos` konkretnie w QEMU, jeśli/gdy wrócimy do tego tematu — ale nie
   zakładać z góry, że trzeba dodatkowy mechanizm wykluczania.

3. **`boot-complete.target` a `graphical.target`:** zweryfikować w QEMU, czy
   `pandos-boot-confirm.service` uruchamia się PO `graphical.target` (a nie
   przed). Jeśli przed — rozważyć `After=graphical.target`.

## Otwarte pytanie

Czy to w ogóle ma wrócić do realizacji, i kiedy — zależy od tego, czy
potrzeba "agent sam wycofuje zmiany bez pytania człowieka" kiedyś się
realnie pojawi. Na razie: nie.
