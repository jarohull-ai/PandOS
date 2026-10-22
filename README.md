# PandOS

<p align="center">
  <img src="assets/pandos-mascot.png" width="420" alt="Maskotka PandOS — panda z łapami pingwina">
</p>

Instalowalny Linux dla osób, które traktują agentów AI jako główny sposób
pracy z komputerem. [PandaCode](https://github.com/aicodeking/pandacode) jest
głównym punktem wejścia, a nie tylko kolejną aplikacją obok terminala czy
menedżera plików.

PandOS powstaje przede wszystkim jako codzienne środowisko pracy autora i jest
kierowany do ludzi pracujących w podobny sposób. Obraz pozostaje czysty — bez
wbudowanych kluczy API; dostawcę i używane agenty konfiguruje się samodzielnie
po instalacji.

## Status

**MVP bootuje end-to-end (2026-10-22), zweryfikowane w QEMU, nie tylko w
teorii:** `archinstall` (config w `pandos-config/`) w jednym przebiegu
instaluje dysk+pakiety+COSMIC+PandaCode+Snapper → system bootuje do
graficznego greetera COSMIC → logowanie działa → pełny pulpit COSMIC się
odpala → PandaCode startuje pod XWayland → Snapper i `snap-pac` automatycznie
tworzą snapshoty na żywym systemie. Szczegóły i dokładne komendy w
[`tests/full-config-verification.md`](tests/full-config-verification.md) i
[`tests/qemu-boot-verification.md`](tests/qemu-boot-verification.md).

**Instalowalne ISO zweryfikowane end-to-end (2026-10-22):** `pandos-iso/`
(fork profilu `releng` archiso) buduje się, bootuje w QEMU, wykrywa dysk
`cidata` i odpala `archinstall` w pełni bezobsługowo — system instaluje się i
bootuje do działającego COSMIC za pierwszym razem, bez ręcznej ingerencji.
PandOS przestaje być configiem testowanym tylko w szybkiej pętli i staje się
realnym, instalowalnym systemem. Szczegóły, w tym napotkana i naprawiona
pułapka z kolejnością bootowania w QEMU, w
[`tests/qemu-boot-verification.md`](tests/qemu-boot-verification.md)
(sekcja „Scenariusz B").

Ten plik rośnie wraz z projektem i jest źródłem prawdy o decyzjach — każda
ważna decyzja architektoniczna i jej weryfikacja (albo obalenie) trafia tu,
z datą i źródłem.

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

## Otwarte decyzje

### Warstwa transakcyjna — odłożona (2026-10-22)

Zaprojektowana koncepcja (`pandos-config/docs/transactional-layer.md`):
CLI `pandos-tx`, potwierdzanie transakcji pacmana przez realny boot (nie
czas), automatyczny rollback bez pytania człowieka. **Decyzja: nie priorytet
przed MVP.** Mamy już działający, zweryfikowany ręczny rollback przez
`btrfs-assistant --restore` — to wystarcza na razie. Dokument zostaje w repo
jako punkt wyjścia, gdyby ta potrzeba kiedyś wróciła, ale nic z niego nie jest
teraz implementowane.

### Rozproszenie / lokalne modele — NIE odłożona jako dokument, tylko odrzucona na teraz (2026-10-22)

W odróżnieniu od warstwy transakcyjnej, ten pomysł (agenci rozproszeni,
lokalne modele przez Ollama, uprawnienia `pandos-tx` dla agentów) **nie ma
jeszcze design docu w repo** — padła wprost decyzja „nie teraz, wracamy
czysto do ISO" i temat nie został nawet spisany. Jeśli ma wrócić, najpierw
potrzebuje własnego dokumentu (analogicznego do
`pandos-config/docs/transactional-layer.md`), nie od razu implementacji.

## Co dalej (po MVP ISO)

Krótka lista priorytetów po domknięciu instalowalnego ISO (2026-10-22), żeby
nic nie trzeba było sobie przypominać za tydzień. Żaden z tych punktów nie
jest w toku — to jest spisanie stanu, nie nowa praca:

| # | Temat | Status |
|---|-------|--------|
| 1 | Bridge sieciowy zamiast `user`/NAT w testach QEMU | Do rozważenia — przyspieszyłoby kolejne iteracje testów ISO, niewdrożone, niezapisane gdzie indziej niż tu |
| 2 | `fatal library error, lookup self` w hooku pacmana | Nieblokujące, do zbadania kiedyś (patrz `tests/qemu-boot-verification.md`) |
| 3 | Warstwa transakcyjna (`pandos-tx`) | Design doc gotowy (`pandos-config/docs/transactional-layer.md`), implementacja odłożona do decyzji o priorytecie |
| 4 | Rozproszenie / lokalne modele | **Brak jeszcze design docu** — odrzucone na teraz, nie spisane; priorytet dopiero po MVP ISO, jeśli w ogóle |
| 5 | ISO do dystrybucji dla innych (nie tylko do własnego użytku) | Otwarte pytanie, nie podjęta decyzja — do przemyślenia, jeśli PandOS ma wyjść poza użytek autora |

Kontekst do punktu 4 (żeby nie był zagadką za miesiąc, bez pisania design
docu): temat padł w briefie z 2026-10-22 — dwa poziomy, oba odłożone: (1)
zdalna inferencja — agent/kod zostają na PandOS, zapytania do modelu idą na
drugi komputer przez API zgodne z OpenAI (Ollama); (2) zdalne wykonywanie
pracy — agent na drugiej maszynie dostaje worktree i wykonuje komendy, co
wymaga kolejki/blokad/uprawnień. Argument nie jest po prostu „lokalne
zamiast chmury" — to małe modele do wąskich zadań (formatowanie,
klasyfikacja, boilerplate) z automatyczną eskalacją do większego
modelu/chmury, gdy lokalny wynik nie przechodzi testów, mierzone realnymi
oszczędnościami (odsetek zadań lokalnych, liczba eskalacji, czas). Priorytet
dopiero po MVP ISO i po realnych pomiarach, nie z góry.

## Struktura repo

`pandos-config/` (`archinstall`: `user_configuration.json`, `provision.sh`,
`run-fast-loop.sh`, `docs/`) i `pandos-iso/` (`archiso`: `configs/pandos/`,
`test-qemu-boot.sh`) już istnieją i działają — szybka pętla, wolna pętla i
instalacja z ISO wszystkie trzy zweryfikowane
(`tests/full-config-verification.md`, `tests/qemu-boot-verification.md`).
