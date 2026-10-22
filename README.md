# PandOS

Instalowalny Linux dla osób nietechnicznych, w którym [PandaCode](https://github.com/aicodeking/pandacode)
jest punktem wejścia zamiast terminala czy menedżera plików. Czysty obraz bez
kluczy API — dostawcę konfiguruje się samemu po instalacji.

## Status

Projekt na etapie projektowania architektury, przed pierwszym działającym
szkieletem. Ten plik rośnie wraz z projektem i jest źródłem prawdy o
decyzjach — każda ważna decyzja architektoniczna i jej weryfikacja (albo
obalenie) trafia tu, z datą i źródłem.

## Zasady projektowe

1. **PandaCode jako punkt wejścia**, nie jedna z wielu aplikacji.
2. **Czysty system, bez kluczy** — żadnych tokenów/API keys w obrazie ISO.
3. **Dostępny dla zwykłych użytkowników, otwarty dla deweloperów** — domyślnie
   proste doświadczenie, bez blokowania trybu zaawansowanego.

## Decyzje architektoniczne

### Nie forkujemy Omarchy (2026-10-22)

Pierwotny plan zakładał fork `omarchy`/`omarchy-iso` z podmianą Hyprland→COSMIC.
Zweryfikowane bezpośrednio w repozytoriach (`omacom/omarchy`, `omacom/omarchy-iso`,
`omacom/omarchy-pkgs`) pokazało, że Hyprland jest wpleciony w co najmniej trzy
repozytoria naraz, build wymaga Dockera `--privileged`, bootloader to Limine
(nie GRUB). Koszt przepisania tego na COSMIC przewyższa korzyść z dziedziczenia
gotowego instalatora.

**Decyzja:** czysty Arch Linux + `archinstall` + COSMIC + preinstalowany
PandaCode, budowane od zera.

### COSMIC bez AUR (potwierdzone 2026-10-22)

`cosmic-session` i `cosmic-greeter` to oficjalne pakiety w repo `extra`
(grupa `cosmic`), nie AUR. Sprawdzone bezpośrednio w bazie pakietów Arch.

### Pipeline budowy: archinstall + archiso, nie wybór między nimi

Dwie pętle o różnej prędkości, nie jeden mechanizm:

- **Szybka pętla ("szkic architektury"):** `archinstall` + config JSON + skrypt
  Pythona (provisioning: COSMIC, Snapper, snap-pac, PandaCode AppImage; mirror
  tylko `core`/`extra`, bez `testing`/AUR) odpalany przeciw plikowi-obrazowi
  dysku przez `losetup` — bez bootowania ISO/VM. `archinstall` wymaga
  `arch-chroot`/`genfstab`, więc biegnie w kontenerze Arch
  (`ghcr.io/archlinux/archlinux:latest`, `--privileged`), bo maszyna
  deweloperska nie jest Archem. Loop device nie działa wewnątrz kontenera —
  `losetup` robimy na hoście, do kontenera przekazujemy gotowy `/dev/loopX`.
- **Wolna pętla ("wydruk do ISO"):** fork profilu `releng` z `archiso`
  (ma już `archinstall` w swoim `packages.x86_64` — sprawdzone w źródle na
  gitlab.archlinux.org/archlinux/archiso) + systemd unit szukający dysku
  `cidata` (wzorzec NoCloud/cloud-init, wsparty natywnie przez
  Proxmox/Packer/libvirt) + `mkarchiso`. Odpalana rzadziej, tylko do
  weryfikacji finalnego produktu.

Python do provisioningu, nie Rust — `archinstall` ma natywne API Pythona
(`Installer`/`Profile`/`Application`), środowisko live i tak wymaga Pythona.
Argumenty za Rustem (spójność z PandaCode, bezpieczeństwo pamięci) nie mają
zastosowania do jednorazowego skryptu instalacyjnego.

### Układ subwolumenów Btrfs (potwierdzone z wiki.archlinux.org/title/Snapper + źródła archinstall, 2026-10-22)

Wiki sugeruje `@`→`/`, `@home`→`/home`, `@snapshots`→`/.snapshots`,
`@var_log`→`/var/log`, żeby chronić `/home` przed rollbackiem `/`. Pułapka:
wersje `archinstall` starsze niż 3.0.5 montują `@.snapshots` w sposób psujący
`snapper create-config` (GitHub issue #1808, zlinkowany wprost na wiki) —
używać 3.0.5+.

**Ważne:** domyślny layout samego `archinstall` (funkcja
`get_default_btrfs_subvols()` w `archinstall/lib/disk/default_layouts.py`,
sprawdzone w źródle na branchu `master`) to `@`→`/`, `@home`→`/home`,
`@log`→`/var/log`, `@pkg`→`/var/cache/pacman/pkg` — **bez** `@snapshots`.
Trzeba go jawnie nadpisać w configu JSON (pole `btrfs` na partycji roota, lista
obiektów `{"name": ..., "mountpoint": ...}`, dataclass `SubvolumeModification`
w `archinstall/lib/models/device.py`), dodając `@snapshots`→`/.snapshots` do
listy domyślnej. Finalna lista do użycia: `@`, `@home`, `@log`, `@pkg`,
`@snapshots`.

### Mechanizm rollbacku — W TRAKCIE WERYFIKACJI (2026-10-22)

Wiki opisuje przywracanie `@` (root) jako procedurę ręczną z Live CD, nie
przez komendę `snapper rollback` z działającego systemu. Dla celu "jedno
kliknięcie" dla nietechnicznego użytkownika kandydatem jest
[Btrfs Assistant](https://gitlab.com/btrfs-assistant/btrfs-assistant)
(pakiet `btrfs-assistant`, oficjalne repo `extra`, nie AUR) — raporty z forum
(EndeavourOS) wskazują, że GUI "przywróć + reboot" działa z działającego
systemu bez Live USB. **Niepotwierdzone źródłowo z pierwszej ręki, test w VM
w toku** — zobacz `tests/` po zakończeniu.

### Lista pakietów — draft (2026-10-22)

**COSMIC:** instalacja `cosmic-session` (grupa `cosmic`) wystarcza — sprawdzone
bezpośrednio w jego liście `depends` w bazie pakietów Arch, pociąga za sobą
m.in. `cosmic-greeter` (własny greeter, **GDM niepotrzebny**, mimo że starsze
poradniki z 2024 go zalecały) i `xorg-xwayland` (**potrzebne przez PandaCode**,
patrz niżej — to jest automatyczne, nic dodatkowego do zrobienia). Warto dodać
jawnie opcjonalne: `cosmic-terminal`, `cosmic-store`, `cosmic-text-editor`,
`gnome-keyring` (do przechowywania kluczy dostawców AI zgodnie z zasadą
projektową #2 — PandaCode sam nie trzyma kluczy, ale CLI agentów, które
odpala, mogą chcieć systemowego keyringu).

**PandaCode — wymagania potwierdzone z jego własnego README (2026-10-22):**
wymaga `fuse2` (pakiet `fuse2`, oficjalne repo `extra`, nie AUR) do odpalenia
AppImage bez `APPIMAGE_EXTRACT_AND_RUN=1`; wymaga X11 lub XWayland (patrz
COSMIC wyżej — już pokryte); wymaga zainstalowanego osobno `git` + co najmniej
jednego CLI agenta (Claude Code / Codex / itd.) — **PandaCode świadomie nic z
tego nie zawiera**, użytkownik instaluje i loguje się sam. To jest zgodne z
zasadą projektową #2, nie coś do obejścia. Instalacja samego PandaCode: AppImage
z `github.com/aicodeking/pandacode/releases/latest/download/PandaCode-Linux-x86_64.AppImage`
do np. `/opt/pandacode/`, `chmod +x`, wpis `.desktop` + ewentualny autostart.

**Warstwa bezpieczeństwa:** `btrfs-progs`, `snapper`, `snap-pac`,
`btrfs-assistant` (wszystkie w `extra`, zero AUR).

**Baza:** `base`, `linux`, `networkmanager`, `git`, `sudo`, bootloader (do
ostatecznego rozstrzygnięcia dla produktu finalnego — testowy VM używa `grub`
dla prostoty, patrz `tests/`).

**Otwarte, nierozstrzygnięte:** który przeglądarkę preinstalować (nic jeszcze
nie wybrano — do decyzji, nie zgadywania).

## Struktura repo

Szkielet katalogów (`pandos-config/` dla `archinstall`, `pandos-iso/` dla
`archiso`) celowo jeszcze nie istnieje — stawiamy go po dopracowaniu treści
(lista pakietów, provisioning, rozstrzygnięty mechanizm rollbacku), żeby nie
budować struktury pod rozwiązanie, które się jeszcze zmieni.
