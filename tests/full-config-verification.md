# Weryfikacja: pełny `user_configuration.json` (szybka pętla, jeden przebieg archinstall)

**Data:** 2026-10-22
**Cel:** napisać kompletny config dla `archinstall`, który w jednym przebiegu (nie
w dwóch fazach jak w poprzednim teście) daje system z naszym layoutem Btrfs,
Snapperem, COSMIC i PandaCode — zgodnie z rekomendacją DeepSeeka: `archinstall`
robi dysk+pakiety+locale+użytkownika+bootloader przez `custom_commands`, bez
`systemd-nspawn`.

**Wynik: POTWIERDZONE.** Config w `pandos-config/user_configuration.json` +
`pandos-config/provision.sh` (treść pola `custom_commands`) +
`pandos-config/run-fast-loop.sh` (sterownik budujący w kontenerze) działa od
A do Z. Doszliśmy tu przez 7 realnych, zrozumianych przeszkód — żadna nie była
ślepym zgadywaniem, każda potwierdzona tracebackiem/źródłem przed poprawką.

## Środowisko

Jak w poprzednim teście: Ubuntu/Zorin (nie Arch), Docker `--privileged`,
`archlinux:latest` jako kontener budujący, obraz dysku 14GiB przez `losetup`
na hoście (nie w kontenerze — loop device DZIAŁA w `--privileged`, potwierdzone
też tutaj, obawa z forum nieaktualna/nietrafiona w tym środowisku).

## Przeszkody napotkane po drodze (7, każda zrozumiana, nie zgadywana)

1. **Pominięcie `locale_config` w JSON NIE wystarcza.** Oczekiwałem (na
   podstawie wcześniejszej weryfikacji źródła), że to zablokuje wywołanie
   `localectl`. Okazało się, że `Installer.minimal_installation()` ma
   `locale_config: LocaleConfiguration | None = LocaleConfiguration.default()`
   jako **domyślny argument funkcji** (`installer.py:893`), niezależny od
   top-level configu — więc `set_keyboard_language()` i tak się wywołuje.
   To koryguje wcześniejsze, niepełne ustalenie w README (zweryfikowałem
   tylko JEDNO z dwóch miejsc, które wywołują ten kod).
2. (Błąd własny, nie archinstall: `which: command not found` w minimalnym
   obrazie `archlinux:latest` zabiło skrypt przez `set -e` przed dojściem do
   archinstall. Naprawione usunięciem zbędnego sprawdzenia.)
3. Powtórka przeszkody #1 po naprawieniu #2.
4. **`arch-chroot` w tej wersji `arch-install-scripts` domyślnie używa
   `systemd-run` (flaga `-S`, którą `archinstall` ZAWSZE dołącza do każdego
   swojego wywołania `arch-chroot`), co wymaga `/run/systemd/system` na
   hoście** (`systemd_sanity_check()` w `arch-chroot`, potwierdzone czytając
   sam skrypt). To głębsza, inna przyczyna niż #1 — nie tylko `localectl`,
   cały mechanizm chrootowania w tej wersji wymaga systemd. Naprawione:
   wrapper w kontenerze, który zdejmuje `-S` z argumentów przed wywołaniem
   prawdziwego `arch-chroot`, zmuszając go do tradycyjnego,
   bezsystemdowego `chroot_setup()` (zwykłe bind-mounty, nic nie wymaga).
   Rozwiązanie zdecydowanie prostsze niż próba odpalenia prawdziwego
   systemd jako PID 1 w kontenerze (co już wcześniej zawiodło w rozsądnym
   czasie w poprzednim teście).
5. Po naprawieniu #1 i #4: **`archinstall` przeszedł w całości, exit code 0** —
   pierwszy raz. Ale mój WŁASNY krok po instalacji padł: `snapper -c root
   create-config /` → "Creating config failed (subvolume already covered)."
   Inna przyczyna niż poprzedni test (tam było "File exists" na zwykłym
   katalogu) — tu `@snapshots` było zadeklarowane w `disk_config` z
   `mountpoint: "/.snapshots"`, więc `archinstall` **sam je montował**
   podczas disk setup, i `rmdir` się wywalał na "Device or resource busy"
   (zob. punkt 6, to był faktyczny pierwszy symptom, zanim dotarłem do
   samego create-config).
6. Naprawa #5: usunięcie `@snapshots` z `disk_config.btrfs` — tworzymy je
   sami w kroku po instalacji (dokładnie jak w pierwszym teście), zamiast
   próbować współistnieć z automatycznym montowaniem przez `archinstall`.
7. Po #6: **NOWY błąd w tym samym miejscu** — "subvolume already covered"
   nadal, ale teraz z innej przyczyny. Diagnostyka (nie zgadywanie) pokazała:
   `/etc/snapper/configs/root` i `/home` **już istniały, w pełni poprawne**
   (`SUBVOLUME="/"` i `SUBVOLUME="/home"`) PRZED moim wywołaniem
   `create-config` — najpewniej zbootstrapowane przez hook `snap-pac`
   (`05-snap-pac-pre.hook`/`zz-snap-pac-post.hook`, znalezione w
   `/usr/share/libalpm/hooks/`) podczas którejś transakcji pacmana w trakcie
   `pacstrap`. Mój `create-config` był redundantny. Naprawione: weryfikacja
   istnienia configów (`test -f` + `grep SUBVOLUME`) zamiast tworzenia ich.
   Efekt domino: krok po instalacji próbował potem `btrfs subvolume delete
   /mnt/.snapshots`, co teraz nie miało czego usuwać (bo `/.snapshots` było
   już tylko zwykłym, usuniętym przez `rmdir` katalogiem, nie subwolumenem)
   → "Could not statfs: No such file or directory". Naprawione: usunięcie
   tej już niepotrzebnej linii.

**Po przeszkodzie #7 (8. próba): sukces end-to-end.**

## Weryfikacja wyniku (nie tylko brak błędu — realna zawartość)

```
$ btrfs subvolume list /mnt
ID 256 gen 21 top level 5 path @
ID 257 gen 15 top level 5 path @home
ID 258 gen 16 top level 5 path @log
ID 259 gen 13 top level 5 path @pkg
ID 260 gen 12 top level 5 path var/lib/portables      (systemd default, harmless)
ID 261 gen 12 top level 5 path var/lib/machines        (systemd default, harmless)
ID 263 gen 15 top level 257 path @home/.snapshots      (snap-pac's own nested config for /home, expected)
ID 264 gen 16 top level 5 path @snapshots              (ours, top-level, created in post-processing)
```

- `/opt/pandacode/PandaCode.AppImage`: 92 908 024 bytes, `rwxr-xr-x` — pobrany
  i wykonywalny.
- `/usr/share/applications/pandacode.desktop`: obecny.
- `/etc/pandos-root-marker.txt` → `pandos-root-before-change` (poprawna treść).
- `/home/pandos/home-marker.txt` → `home-marker: should survive any root
  rollback` (poprawna treść).
- `grub-install` i `grub-mkconfig` zakończone bez błędu.
- `/etc/fstab` wygenerowany na nowo (`genfstab -U`) PO podmianie `@snapshots`,
  z wpisem `/swapfile` z `/proc/swaps` hosta wyciętym (artefakt metodologii
  kontenerowej, nie dotyczy prawdziwego PandOS — zob. poprzedni test).

**Drobny, nieistotny dla wyniku defekt własnego skryptu weryfikującego:**
`snapper -c root list-configs` w komendzie weryfikacyjnej zwrócił "Failure
(org.freedesktop.DBus.Error.FileNotFound)" — zapomniałem `--no-dbus` w TEJ
jednej linii weryfikacyjnej (nie w samej instalacji). Nieistotne, bo zawartość
plików configów już zweryfikowana bezpośrednio przez `grep`.

**Kosmetyczny, nieistotny defekt na samym końcu:** `umount -R /mnt` na
zakończenie skryptu zwrócił "target is busy" — kontener i tak się rozmontowuje
przy wyjściu (`--rm`), nie wpływa na zawartość zapisaną na dysku obrazu.

## Pliki w repo

- `pandos-config/user_configuration.json` — finalny, działający config.
- `pandos-config/provision.sh` — treść pola `custom_commands` (osobny,
  czytelny plik; przy zmianach trzeba go ponownie wkleić do JSON-a jako
  zawartość `custom_commands[0]`, najlepiej przez mały skrypt Pythona z
  `json.dump`, nie ręcznie — uniknie błędów escapowania nowych linii).
- `pandos-config/localectl-stub.sh` — atrapa `localectl` (tylko do budowy w
  kontenerze, nigdy nie trafia do obrazu docelowego PandOS).
- `pandos-config/run-fast-loop.sh` — sterownik: instaluje `archinstall` w
  kontenerze, podkłada atrapę `localectl` i wrapper zdejmujący `-S` z
  `arch-chroot`, naprawia race condition przez `systemd-udevd`, odpala
  `archinstall`, a potem robi krok po instalacji (podmiana `@snapshots`,
  `grub-btrfsd`, `grub-mkconfig`, `genfstab`, weryfikacja).

Nie commitowane (duże pliki binarne, `.gitignore`): obraz dysku testowego
(`pandos-full.img`, 14GiB), log budowy.

## Czego NIE zweryfikowano w tej iteracji (świadomie, poza zakresem)

- Boot w QEMU i realne uruchomienie COSMIC/Wayland — zgodnie z zakresem tej
  iteracji, odłożone na "wolną pętlę", którą robimy tylko po potwierdzeniu
  szybkiej pętli. To następny krok.
- Czy `pacman -Syu` na żywym systemie faktycznie tworzy snapshot przez
  `snap-pac` — do zweryfikowania w wolnej pętli / boot teście.
- Integracja `btrfs-assistant` z własnym wrapperem PandOS — mechanizm już
  zweryfikowany w poprzednim teście, nie testowany ponownie tutaj.
