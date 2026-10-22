# Weryfikacja: boot w QEMU zainstalowanego obrazu (wolna pętla)

**Data:** 2026-10-22
**Cel:** przetestować w QEMU ten sam, już zainstalowany obraz dysku z udanej
8. próby szybkiej pętli (`tests/full-config-verification.md`) — bez
ponownego odpalania `archinstall`, bez serwera HTTP z configiem. Cztery
konkretne punkty: boot do COSMIC, PandaCode, Snapper, `snap-pac`.

## Środowisko

QEMU 8.2.2 + KVM, OVMF (UEFI, `/usr/share/OVMF/OVMF_CODE_4M.fd`), obraz
`pandos-full.img` (14GiB, ten sam plik co w teście szybkiej pętli) jako
`virtio`, port SSH przekierowany `hostfwd=tcp::2223-:22`, `-vga virtio
-display none` + gniazdo QMP do zrzutów ekranu (`screendump`) — weryfikacja
wizualna programowa, bez angażowania Jaro do patrzenia na okno.

## 1. Boot do COSMIC — NIE DZIAŁA, przyczyna zidentyfikowana precyzyjnie

**Wynik: system NIE bootuje do graficznego COSMIC.** Zrzut ekranu (QMP
`screendump`) pokazuje zwykły tekstowy prompt logowania na tty1
(`pandos login:`). To NIE jest problem renderowania Wayland/COSMIC w VM
(do którego nawet nie doszliśmy) — to brak dwóch kroków w provisioningu:

1. `greetd.service` jest **disabled** (nigdy nie włączony w `custom_commands`).
2. Nawet po ręcznym odpaleniu `greetd` (zadziałało bez błędu, proces wstał
   poprawnie), użył **domyślnego** configu (`/etc/greetd/config.toml`)
   wskazującego na wbudowany tekstowy greeter `agreety --cmd /bin/sh`, NIE
   na COSMIC. Pakiet `cosmic-greeter` wysyła WŁASNY, gotowy szablon configu
   pod `/etc/greetd/cosmic-greeter.toml`:
   ```toml
   [terminal]
   vt = "1"
   [general]
   service = "login"
   [default_session]
   command = "cosmic-greeter-start"
   user = "cosmic-greeter"
   ```
   ale nic nigdy nie skopiowało go na `/etc/greetd/config.toml`.

**Konkretna poprawka do `provision.sh` na następną iterację (niewdrożona w
tym teście — to raport diagnostyczny, nie poprawka):**
```sh
cp /etc/greetd/cosmic-greeter.toml /etc/greetd/config.toml
systemctl enable greetd.service
```
Po tej poprawce rzeczywiste renderowanie COSMIC/Wayland w headless QEMU
(software rendering, brak przekazanego GPU) to osobne, jeszcze nieprzetestowane
ryzyko — odnotowane jako kolejny krok, nie zakładać z góry że zadziała.

## 2. PandaCode — zainstalowany poprawnie, panikuje bez sesji graficznej (oczekiwane)

`/usr/share/applications/pandacode.desktop` obecny i poprawny.
Ręczne uruchomienie `/opt/pandacode/PandaCode.AppImage` przez SSH:

```
thread 'main' panicked at .../tao-0.35.3/.../event_loop.rs:217:53:
Failed to initialize gtk backend!: BoolError { message: "Failed to initialize GTK", ... }
```

To jest **oczekiwany** skutek punktu 1 (brak sesji graficznej w ogóle), nie
defekt PandaCode czy `fuse2`. Ważne: binarka **startuje i dochodzi do
inicjalizacji GTK** przed panic — potwierdza to, że AppImage się poprawnie
rozpakowuje/uruchamia (żaden błąd "cannot execute", żaden błąd FUSE). Realny
test działania PandaCode wymaga najpierw naprawy punktu 1.

## 3. Snapper — DZIAŁA

```
$ snapper --no-dbus list-configs
Config | Subvolume
-------+----------
home   | /home
root   | /
```

Manualny snapshot (`snapper -c root create --description manual-test-snapshot`)
utworzony bez błędu. Dodatkowo zauważone: timeline timer już zdążył zrobić
swój pierwszy automatyczny snapshot (`timeline`, ok. 23 min po boocie) —
potwierdza, że `snapper-timeline.timer` faktycznie działa w tle, nie tylko
jest "enabled" na papierze.

## 4. `snap-pac` — DZIAŁA, po jednej dodatkowej poprawce znalezionej po drodze

Pierwsza próba (`pacman -S nano`) nie powiodła się z innego, niezwiązanego
powodu: `error: nano: signature ... is unknown trust` — keyring pacmana z
`pacstrap` nie miał zaufanego klucza akurat tego maintainera pakietu. To
osobny, realny problem provisioningu (nie dotyczy `snap-pac` samego w sobie):
**`custom_commands` powinno zawierać `pacman-key --populate archlinux`
jawnie**, nie polegać na tym, że `pacstrap` już to w pełni zrobił. Po ręcznym
odpaleniu tej komendy i retry:

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

`snapper -c root list` po fakcie pokazuje wpisy #3 (`pre`) i #4 (`post`, z
`Pre # = 3`) z poprawnym opisem `pacman -S --noconfirm nano` — **potwierdzone
bezpośrednio, nie tylko przez brak błędu.**

## Podsumowanie i konkretne poprawki do następnej iteracji `provision.sh`

| # | Punkt | Wynik | Akcja |
|---|-------|-------|-------|
| 1 | Boot do COSMIC | ❌ nie działa (brak configu greetd) | dodać `cp .../cosmic-greeter.toml config.toml` + `systemctl enable greetd` |
| 2 | PandaCode | ✅ zainstalowany poprawnie, wymaga punktu 1 | brak akcji, zależne od 1 |
| 3 | Snapper | ✅ w pełni działa | brak akcji |
| 4 | snap-pac | ✅ działa, po poprawce keyringu | dodać `pacman-key --populate archlinux` jawnie do `custom_commands` |

Żaden z tych czterech punktów nie jest "ślepą zagadką" — każdy ma
zidentyfikowaną, konkretną przyczynę i gotową poprawkę do wdrożenia w
kolejnej iteracji configu, zanim przejdziemy do `archiso`.

## Artefakty

`screendump.png` (zrzut ekranu tty1 login prompt), `pandos-full.img` (ten sam
obraz z testu szybkiej pętli, teraz z dodatkowym pakietem `nano` i kilkoma
dodatkowymi snapshotami Snappera z tego testu) — oba w scratchpadzie sesji,
nie w repo.
