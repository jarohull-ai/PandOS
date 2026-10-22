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

## Artefakty (pierwszy przebieg, przed poprawkami)

`screendump.png` (zrzut ekranu tty1 login prompt), `pandos-full.img` (ten sam
obraz z testu szybkiej pętli, teraz z dodatkowym pakietem `nano` i kilkoma
dodatkowymi snapshotami Snappera z tego testu) — oba w scratchpadzie sesji,
nie w repo.

---

## Powtórka po poprawkach (2026-10-22, ten sam dzień) — WSZYSTKIE 4 PUNKTY PRZESZŁY

Dwie poprawki wdrożone w `pandos-config/provision.sh`:
1. `pacman-key --init && pacman-key --populate archlinux` na samym początku.
2. `cp /etc/greetd/cosmic-greeter.toml /etc/greetd/config.toml` **przed**
   `systemctl enable greetd.service` (kolejność ma znaczenie — potwierdzone).

Pełna szybka pętla uruchomiona ponownie od zera na świeżym obrazie z tymi
poprawkami (`ARCHINSTALL_EXIT_CODE=0`, `POST_PROCESSING_OK`), potem ten sam
obraz zabootowany w QEMU jeszcze raz.

### 1. Boot do COSMIC — DZIAŁA

Zrzut ekranu przez QMP `screendump` pokazuje **prawdziwy graficzny greeter
COSMIC**: zegar, data, tapeta (mgławica Oriona), pole hasła z nazwą
użytkownika `pandos`, ikony dostępności/klawiatury/zasilania u dołu.
Zasymulowano wpisanie hasła przez QMP `send-key` (`pandos` + Enter) —
**pełne zalogowanie się powiodło**, kolejny zrzut ekranu pokazuje w pełni
działający pulpit COSMIC: górny panel (Workspaces/Applications, zegar, tray
z ikonami sieci/dźwięku/baterii), dolny dok z launcherami aplikacji.
Weryfikacja przez SSH: wszystkie procesy `cosmic-*` (comp, panel, launcher,
app-library, workspaces, applets, itd.) oraz `xdg-desktop-portal-cosmic`
żywe pod użytkownikiem `pandos` na `tty1`. Software rendering w headless
QEMU bez przekazanego GPU zadziałał bez problemu — obawa z wcześniejszego
raportu okazała się niepotrzebna.

### 2. PandaCode pod XWayland — DZIAŁA (po znalezieniu właściwego DISPLAY)

Pierwsza próba (`DISPLAY=:0`) dalej panikowała na GTK — bo `:0` należy do
**osobnej** sesji XWayland greetera (`cosmic-greeter`), nie do zalogowanej
sesji `pandos`. Rzeczywista sesja `pandos` ma swój XWayland na `:1`
(potwierdzone: `ps aux | grep -i xwayland` → `Xwayland :1 ...`, gniazdo
`/tmp/.X11-unix/X1` należące do `pandos`). Z poprawnym
`DISPLAY=:1 WAYLAND_DISPLAY=wayland-1`: **PandaCode przechodzi przez
inicjalizację GTK bez panikowania** — zamiast tego dostaje tylko ostrzeżenia
`MESA-EGL: DRI3 error: Could not get DRI3 device` / `failed to create dri2
screen` — to oczekiwane ograniczenie software renderingu w headless QEMU bez
prawdziwego GPU (`virtio-vga` bez `virgl`), nie defekt PandaCode ani naszego
configu.

### 3. Snapper — nadal DZIAŁA bez zmian

`snapper --no-dbus list-configs` → `root`/`home` poprawnie.

### 4. snap-pac — DZIAŁA, TERAZ bez żadnej ręcznej naprawy w locie

`pacman -S nano` **za pierwszym razem, bez błędu keyringu** (w przeciwieństwie
do pierwszego przebiegu testu) — `pacman-key --populate archlinux` wbudowane
w `provision.sh` rozwiązało to raz na zawsze przy budowie obrazu. Pre/post
snapshoty (`#1 pre` / `#2 post`, poprawny opis `pacman -S --noconfirm nano`)
utworzone automatycznie.

## Wniosek

**MVP configu jest kompletne i w pełni zweryfikowane end-to-end**: instalacja
przez `archinstall` w jednym przebiegu → boot w QEMU → graficzny COSMIC →
zalogowanie → PandaCode się odpala → Snapper/`snap-pac` działają automatycznie
na żywym systemie. Jedyne pozostałe ograniczenie to brak akceleracji GPU w
tym konkretnym środowisku testowym (headless QEMU, software rendering) — nie
dotyczy poprawności samego configu PandOS.

---

## Scenariusz B: instalacja z ISO (`archiso` + `cidata`, w pełni bezobsługowa) — ZATRZYMANE, przyczyna zidentyfikowana

**Data:** 2026-10-22. **Cel:** zbudować instalowalne ISO (`pandos-iso/`,
fork profilu `releng`) i przetestować w QEMU pełny, bezobsługowy scenariusz:
boot z ISO → wykrycie dysku `cidata` → `autoinstall.sh` →
`archinstall --config ... --silent` → post-processing (`@snapshots`,
`grub-mkconfig`, `genfstab`) → `systemctl reboot` → oczekiwany boot
zainstalowanego systemu z dysku.

### Co faktycznie się stało

Proces QEMU (`qemu-system-x86_64 ... -drive file=target-disk.img,...
-drive file=cidata.img,... -drive file=out/pandos-....iso,media=cdrom ...`)
działał **ok. 6h16min** (14:46–21:04) bez osiągnięcia stabilnego końcowego
stanu. Monitorowanie przez QMP `screendump` (nie przez forka, bezpośrednio)
pokazało powtarzający się cykl:

1. Instalacja pakietów (COSMIC + reszta, 188 pakietów) kończy się, dochodzi
   do post-transaction hooków pacmana — w jednym z przebiegów zaobserwowano
   `(21/21) Performing snapper post snapshots...` natychmiast po czym
   `fatal library error, lookup self` w logu hooka. **Nieistotne dla wyniku
   końcowego** — to komunikat z pojedynczego hooka pacmana (prawdopodobnie
   `snap-pac`/`grub-btrfsd` przy próbie `/proc/self/exe` w chroot), nie
   przerwał transakcji ani samego `archinstall` (co potwierdza fakt, że
   zaraz potem nastąpił reboot zgodny ze skryptem, patrz niżej) — **do
   potwierdzenia precyzyjnie przy następnej iteracji, nie olewać całkowicie,
   ale nie jest to przyczyna pętli opisanej niżej.**
2. Krótko po tym: ekran TianoCore/OVMF (reboot). To pasuje dokładnie do
   końcówki `autoinstall.sh`: `echo "Install complete. Rebooting in 10s..."`
   → `sleep 10` → `systemctl reboot`.
3. Zamiast wystartować zainstalowany system z `target-disk.img`, VM **wraca
   do live ISO**: nowy proces `autoinstall.sh` (inny PID), ponowne wykrycie
   `cidata`, ponowne `archinstall --config ... --silent` **od zera, na tym
   samym dysku**.
4. Krok 1–3 powtórzył się wielokrotnie w ciągu ponad 6 godzin (zaobserwowane
   bezpośrednio: check5/6 ok. 17:53, check8/9 ok. 17:54–17:56, kolejny pełny
   cykl od zera widoczny o 21:01 — a więc **co najmniej 3 pełne cykle
   instalacji w jednej sesji testowej**, prawdopodobnie więcej pomiędzy
   punktami kontrolnymi, których nie rejestrowałem w sposób ciągły).

Proces zatrzymany ręcznie (`kill`) na wyraźne polecenie — **nie uznajemy
tego za "instalacja się nie udała"**, tylko za "test się nigdy nie kończy",
co to dwie różne rzeczy.

### Przyczyna — zidentyfikowana, nie zgadywana

Dwa fakty, oba zweryfikowane bezpośrednio w kodzie i w rzeczywistym poleceniu
uruchomienia QEMU:

1. **`autoinstall.sh` kończy się komentarzem wprost mówiącym o fizycznym
   usunięciu nośnika:** `"Install complete. Rebooting in 10s (remove
   installation media now)."` — to poprawne i oczekiwane dla instalatora na
   prawdziwym sprzęcie (USB/DVD, operator wyjmuje nośnik), ale **nic w
   testowej automatyzacji QEMU nie robi tego odpowiednika** (nie ma
   odłączenia/wysunięcia CD-ROM przed rebootem).
2. **Polecenie uruchamiające QEMU nie ma żadnego wymuszonego porządku
   bootowania** — zweryfikowane bezpośrednio w `ps aux`: brak flagi
   `-boot order=...` i brak `bootindex=` na którymkolwiek `-drive`. Firmware
   (OVMF) wybiera więc urządzenie rozruchowe wg własnej domyślnej logiki, a
   `grub-install --target=x86_64-efi --efi-directory=/boot
   --bootloader-id=PANDOS --removable` (w `provision.sh`/`autoinstall.sh`)
   zapisuje bootloader pod **fallbackową** ścieżką EFI
   (`/EFI/BOOT/BOOTX64.EFI`) — dokładnie tę samą konwencjonalną ścieżkę,
   pod którą archiso publikuje własny rozruch na ISO. Gdy oba urządzenia
   (dysk i CD-ROM) mają bootowalny plik pod tą samą fallbackową ścieżką, a
   nic nie wymusza priorytetu, OVMF w tym środowisku konsekwentnie wybiera
   CD-ROM.

**To jest problem samego testowego środowiska QEMU, nie błąd logiki
instalacji PandOS** — na prawdziwym sprzęcie z fizycznie wyjętym nośnikiem
ten scenariusz by nie wystąpił. Ale do przetestowania scenariusza B w QEMU
trzeba to jawnie obejść.

### Rekomendowana poprawka (do wdrożenia w następnej iteracji, NIEWDROŻONA w tym teście)

Dwie niezależne, uzupełniające się opcje — zalecane wdrożenie obu:

1. **W poleceniu QEMU:** dodać `bootindex=1` do `-drive
   file=target-disk.img,...` i wyższy numer (np. `bootindex=2`) do
   `-drive file=...iso,media=cdrom` — to standardowy, udokumentowany sposób
   QEMU na wymuszenie priorytetu dysku nad CD-ROM niezależnie od tego, co
   zawiera NVRAM/fallback EFI obu urządzeń.
2. **Opcjonalnie, dodatkowe zabezpieczenie:** po potwierdzonym
   `POST_PROCESSING_OK` (przed `systemctl reboot`), odłączyć CD-ROM
   programowo przez QMP z zewnątrz (`blockdev-change-medium` / `eject`) —
   odpowiednik "wyjęcia nośnika" z komentarza w skrypcie, ale sterowany
   przez harness testowy, nie przez `autoinstall.sh` (który nie ma dostępu
   do QMP swojego własnego hosta).

### Co NIE jest w tym momencie potwierdzone (świadomie, do zrobienia w następnej iteracji)

- Czy po poprawce `bootindex` zainstalowany system faktycznie bootuje do
  końca (COSMIC, SSH jako `pandos`, Snapper) **z ISO/`cidata`** — ten
  konkretny test (scenariusz B w całości) nie został jeszcze domknięty.
- Dokładna przyczyna `fatal library error, lookup self` w hooku snapper —
  nieistotna dla pętli opisanej wyżej, ale warta osobnego sprawdzenia przy
  następnym przebiegu (np. `journalctl` w zainstalowanym systemie po
  pierwszym udanym boocie).
- Dokładna liczba pełnych cykli reinstalacji w tej 6-godzinnej sesji —
  zaobserwowano **co najmniej 3** bezpośrednio przez zrzuty QMP, realna
  liczba może być wyższa (zrzuty robione punktowo, nie w sposób ciągły).
