# PandOS

Instalowalny Linux dla osób, które traktują agentów AI jako główny sposób
pracy z komputerem. [PandaCode](https://github.com/aicodeking/pandacode) jest
głównym punktem wejścia, a nie tylko kolejną aplikacją obok terminala czy
menedżera plików.

PandOS powstaje przede wszystkim jako codzienne środowisko pracy autora i jest
kierowany do ludzi pracujących w podobny sposób. Obraz pozostaje czysty — bez
wbudowanych kluczy API; dostawcę i używane agenty konfiguruje się samodzielnie
po instalacji.

## Status

Projekt na etapie projektowania architektury, przed pierwszym działającym
szkieletem. Ten plik rośnie wraz z projektem i jest źródłem prawdy o
decyzjach — każda ważna decyzja architektoniczna i jej weryfikacja (albo
obalenie) trafia tu, z datą i źródłem.

## Zasady projektowe

1. **PandaCode jako punkt wejścia**, nie jedna z wielu aplikacji.
2. **Czysty system, bez kluczy** — żadnych tokenów/API keys w obrazie ISO.
3. **Prosty domyślnie, otwarty w środku** — spójne doświadczenie agent-first,
   bez ukrywania systemu i bez blokowania trybu zaawansowanego.

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

**Korekta szybkiej pętli (2026-10-22, z testu w `tests/` + wkładem DeepSeeka,
potwierdzona w źródle):** `archinstall` w gołym kontenerze `--privileged` nie
da się odpalić end-to-end — woła `localectl`/`systemctl` przez D-Bus, co wymaga
żywego systemd jako PID 1. Nie inwestujemy w `systemd-nspawn` na tym etapie.
Rozwiązanie: w configu JSON pomijamy `locale_config` i `bootloader_config` —
sprawdzone w źródle (`archinstall/lib/installer.py:964-966`,
`archinstall/scripts/guided.py:117`), że oba kroki są warunkowe (`if
locale_config:` / `if config.bootloader_config:`) i po prostu się nie wykonują,
gdy pola są nieobecne. Zamiast nich — `custom_commands` (pole configu,
wykonywane na końcu instalacji przez `arch-chroot`, `guided.py:181`): locale,
hostname, user, `bootctl`/`grub-install`, `systemctl enable`. `systemctl
enable` działa bez żywego systemd (tylko symlinki plików jednostek) —
w przeciwieństwie do `localectl`, który faktycznie pyta demona.

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

### Mechanizm rollbacku — POTWIERDZONE empirycznie (2026-10-22)

Zweryfikowane w realnej VM (archinstall → arch-chroot → QEMU/UEFI → SSH),
dwukrotnie: raz ręczną podmianą subwolumenu, raz prawdziwym narzędziem.
Pełny log i procedura w [`tests/btrfs-rollback-verification.md`](tests/btrfs-rollback-verification.md).

**Odrzucona hipoteza:** `btrfs subvolume set-default` — nietestowalna z
definicji, bo `grub-mkconfig` wpisuje `rootflags=subvol=@` na twardo w linię
jądra, więc zmiana "domyślnego subwolumenu" btrfs nic by nie zmieniła w tym,
co się bootuje.

**Działający mechanizm:** rename-swap na poziomie top-level btrfs
(`subvolid=5`) — bieżący `@` zmienia nazwę na backup, nowy zapisywalny `@`
powstaje jako snapshot wybranego punktu przywracania. Działa **w pełni z
działającego, zabootowanego systemu, bez Live USB** (sesja SSH przetrwała
całą operację). Po reboot: root przywrócony, `/home` nienaruszone.

[Btrfs Assistant](https://gitlab.com/btrfs-assistant/btrfs-assistant)
(pakiet `btrfs-assistant`, `extra`, nie AUR) ma gotowy, headless tryb CLI
(`btrfs-assistant --list` / `--restore <indeks>`, działa z
`QT_QPA_PLATFORM=offscreen`, bez GUI) — **potwierdzone, że robi dosłownie
ten sam rename-swap**, nie trzeba reimplementować mechanizmu samemu. To
jest kandydat do wywołania bezpośrednio z UI/wrappera PandOS.

**Otwarte na później:** sprzątanie starych `@_backup_*` po rollbacku
(nieautomatyczne), zachowanie GUI (nie tylko CLI) narzędzia — niesprawdzone,
brak środowiska graficznego w teście.

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
