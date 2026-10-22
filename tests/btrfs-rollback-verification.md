# Weryfikacja: rollback Btrfs/Snapper z layoutem @/@home/@log/@pkg/@snapshots

**Data:** 2026-10-22
**Cel:** sprawdzić empirycznie, czy przywracanie root (`@`) po złej aktualizacji
poprawnie odtwarza stan systemu, przy zachowaniu `/home` nienaruszonym, na
realnym systemie zainstalowanym przez `archinstall` z naszym jawnym layoutem
Btrfs (`@`→`/`, `@home`→`/home`, `@log`→`/var/log`, `@pkg`→`/var/cache/pacman/pkg`,
`@snapshots`→`/.snapshots`).

## Środowisko testu

- Host: Ubuntu/Zorin (nie Arch), Docker 29.1.3, QEMU 8.2.2 + KVM, OVMF (UEFI).
- Obraz dysku: plik raw 12GiB, podłączony przez `losetup -fP` na hoście,
  partycjonowany i wypełniony wewnątrz kontenera `archlinux:latest`
  (`--privileged`, z `/dev` hosta zamontowanym).
- Finalny test "na żywo" wykonany przez SSH do VM uruchomionej w QEMU
  (`-enable-kvm`, dysk wirtualny `virtio`, UEFI przez OVMF, port SSH
  przekierowany `hostfwd=tcp::2222-:22`).

## Co NIE zadziałało po drodze (ważne, żeby nie powtarzać)

1. **`archinstall` nie da się uruchomić w gołym kontenerze `--privileged`
   bez systemd jako PID 1.** Dwa konkretne, różne miejsca się wywaliły:
   - `_verify_service_stop` woła `systemctl show ... archlinux-keyring-wkd-sync.timer`
     → "System has not been booted with systemd as init system (PID 1)."
     Obejście: flaga `--skip-wkd`.
   - `set_keyboard_language` woła `localectl --no-pager list-keymaps` przez
     D-Bus → ten sam błąd, i TEGO nie ma obejścia flagą — `localectl` zawsze
     wymaga żywego systemd+D-Bus. Próba odpalenia kontenera z
     `/usr/lib/systemd/systemd` jako PID 1 (wzorzec "systemd w Dockerze")
     nie powiodła się w rozsądnym czasie (kontener wychodził z kodem 255 bez
     logów, albo wisiał bez wypisania niczego na stdout).
   - **Wniosek dla naszego pipeline'u:** szybka pętla `archinstall` przez
     `losetup`+kontener, opisana wcześniej w README, NIE działa z pełnym CLI
     `archinstall` tak jak zaplanowano. Partycjonowanie i tworzenie
     subwolumenów Btrfs **działa** w gołym kontenerze (potwierdzone,
     patrz niżej) — to tylko wywołania `archinstall` zależne od
     `systemctl`/`localectl`/D-Bus, które wymagają prawdziwego systemd.
     Do ponownego rozstrzygnięcia: albo szybka pętla używa
     `systemd-nspawn`/w pełni poprawnie skonfigurowanego "systemd w
     Dockerze", albo zostaje zredukowana do testowania samego
     partycjonowania/subwolumenów (jak w tym teście), a reszta configu
     (locale, użytkownicy, bootloader, snapper) robiona ręcznie przez
     `arch-chroot` — co jest de facto bliższe temu, jak Omarchy sama buduje
     swój offline-mirror (nie przez żywy `archinstall`, przez `makepkg`).
2. **Loop device DZIAŁA wewnątrz kontenera `--privileged`** (obalona
   wcześniejsza obawa z forum) — `losetup -fP` w kontenerze `archlinux:latest
   --privileged` z `-v /dev:/dev` przyczepił się normalnie i urządzenie
   `/dev/loopX` jest widoczne i trwałe również na hoście po wyjściu
   kontenera.
3. **Race condition na node'ach partycji** (`/dev/loop10p1` nie istniał
   natychmiast po `parted`/archinstall tworzącym partycje) — naprawione
   odpaleniem `systemd-udevd --daemon` + `udevadm trigger && udevadm settle`
   w kontenerze PRZED partycjonowaniem. Bez tego: `DiskError: Unable to
   determine new partition number`.
4. **Domyślny `archinstall` zostawia pusty katalog `/.snapshots`** (nie
   subwolumen) w `@` już na etapie bazowej instalacji — prawdopodobnie z
   pakietu `filesystem`/`systemd`. To jest DODATKOWA, inna przyczyna
   konfliktu niż ta opisana na Arch Wiki (`@.snapshots` automatycznie
   zamontowany) — u nas konflikt wystąpił even bez żadnego zamontowania
   czegokolwiek w `/.snapshots`, czysto przez istnienie zwykłego katalogu.
   `snapper create-config /` odmawia z `errno:17 (File exists)`, bo
   `btrfs_util_create_subvolume_fd()` nie nadpisze istniejącego katalogu.
   **Obejście:** `rmdir /.snapshots` zanim się woła `snapper create-config /`
   — potwierdzone, że to wystarcza.
5. **Chroot bez zainicjowanego keyringu `pacman-key`** → wszystkie sygnatury
   pakietów "unknown trust". Dla tego jednorazowego testu obejście to
   tymczasowe `SigLevel = Never` w `/etc/pacman.conf` na czas instalacji
   pakietów w chroocie, przywrócone na `Required DatabaseOptional` od razu
   po. **To obejście NIE jest akceptowalne dla prawdziwego obrazu PandOS** —
   tam trzeba normalnie `pacman-key --init && pacman-key --populate
   archlinux`. Zanotowane wyłącznie jako przyczyna błędu w tym teście.
6. **`genfstab` uruchomiony w `--privileged` kontenerze dopisał wpis
   `/swapfile` do fstab celu, którego tam nie ma** — najpewniej przez
   `/proc/swaps` kontenera pokazujące aktywny swap HOSTA (namespaces
   PID/mount w `--privileged` nie izolują tego od hosta tak, jak
   mogłoby się wydawać). Trzeba to ręcznie wyciąć z `fstab` przed bootem.
   To artefakt metodologii testowej (kontener), nie coś co dotyczy
   prawdziwego PandOS budowanego w inny sposób.

## Procedura testu (dokładne komendy, nie tylko plan)

1. Partycjonowanie + subwolumeny + bazowy system przez `archinstall --config
   user_configuration.json --creds user_credentials.json --silent
   --skip-version-check --skip-ntp --skip-wkd` w kontenerze — doszło aż do
   `set_keyboard_language` (błąd D-Bus), ale **partycjonowanie i tworzenie
   subwolumenów `@`/`@home`/`@log`/`@pkg`/`@snapshots` zakończyło się
   sukcesem** oraz pacstrap bazowego systemu (`base`, `linux`, mkinitcpio)
   też się zakończył sukcesem przed tym błędem.
2. Dokończenie instalacji ręcznie przez `arch-chroot` (skrypt
   `finish-install.sh`, zachowany lokalnie w scratchpadzie, nie w tym repo):
   pakiety (`grub`, `efibootmgr`, `snapper`, `snap-pac`, `btrfs-assistant`,
   `grub-btrfs`, `inotify-tools`, `openssh`, `sudo`, `vim`, `networkmanager`,
   `dosfstools`), locale, hostname, user `pandos` + root z hasłem `pandos`,
   `sshd`/`NetworkManager` enable, `snapper -c root create-config /` i
   `snapper -c home create-config /home` (po `rmdir /.snapshots`, patrz
   punkt 4 wyżej), `grub-install --target=x86_64-efi ... --removable`,
   override `grub-btrfsd.service` na `--syslog /.snapshots`, zamiana
   własnego `.snapshots` snappera na nasz top-level `@snapshots` (`btrfs
   subvolume delete` + remount `-o subvol=/@snapshots`), `grub-mkconfig`,
   `genfstab -U /mnt >> /mnt/etc/fstab` (z ręcznym usunięciem błędnego wpisu
   `/swapfile`, patrz punkt 6).
3. Boot w QEMU: `qemu-system-x86_64 -enable-kvm -m 3072 -smp 4 -drive
   if=pflash,...OVMF_CODE_4M.fd,readonly=on -drive if=pflash,...OVMF_VARS.fd
   -drive file=pandos-test.img,format=raw,if=virtio -netdev
   user,hostfwd=tcp::2222-:22 -device virtio-net-pci -nographic`.
4. SSH do VM (`ssh -p 2222 root@localhost`, auth hasłem przez trik
   `SSH_ASKPASS`/`SSH_ASKPASS_REQUIRE=force`, bo brak TTY w tej sesji).
5. **Test A — ręczna podmiana subwolumenu `@` (symulacja hipotezy
   `set-default`, ZMIENIONA w trakcie — patrz "Ważne odkrycie" niżej):**
   - `snapper -c root create --description clean-before-change` (snapshot #1)
   - zmiana: `/etc/pandos-root-marker.txt` nadpisany
   - `mount -o subvolid=5 /dev/vda2 /mnt/top` (top-level btrfs, NA ŻYWO,
     system wciąż działa z `@`)
   - `mv /mnt/top/@ /mnt/top/@broken-test`
   - `btrfs subvolume snapshot /mnt/top/@snapshots/1/snapshot /mnt/top/@`
     (nowy, zapisywalny `@` z treści snapshotu)
   - `umount /mnt/top`, sesja SSH pozostała żywa przez całą operację
   - `reboot`
   - **Wynik po reboot: `/etc/pandos-root-marker.txt` = `pandos-root-before-change`
     (PRZYWRÓCONE), `/home/pandos/home-marker.txt` nienaruszony. System
     wstał normalnie.**
6. **Test B — prawdziwe narzędzie `btrfs-assistant` (nie przybliżenie):**
   odkryto, że ma tryb CLI (`btrfs-assistant --list`, `--restore <indeks>`),
   działający headless z `QT_QPA_PLATFORM=offscreen` (bez GUI/displaya).
   - nowy cykl: zmiana markera → `snapper create --description
     clean-for-ba-cli-test` (snapshot #2) → kolejna zmiana markera
   - `btrfs-assistant --list` → poprawnie wylistował oba snapshoty z ich
     indeksami i ścieżkami `@snapshots/N/snapshot`
   - `btrfs-assistant --restore 2` → wypisało: `Restoring snapshot
     @snapshots/2/snapshot` / `Snapshot restoration complete.` / `A copy of
     the original subvolume has been saved as @_backup_2026-10-22T...` /
     `Please reboot immediately`
   - **Potwierdzone bezpośrednio z kodu działania narzędzia: robi DOKŁADNIE
     to samo co Test A ręcznie** — zmienia nazwę bieżącego `@` na
     `@_backup_<timestamp>` i tworzy nowy zapisywalny `@` ze snapshotu. To
     NIE jest `btrfs subvolume set-default`.
   - `reboot` → **Wynik: marker poprawnie przywrócony (`before-ba-test`),
     `/home` nienaruszony, zamontowany `subvolid` nowego `@` potwierdzony
     w `/proc/mounts`.**

## Ważne odkrycie, które zmieniło plan testu w trakcie

Oryginalna hipoteza do zweryfikowania (ustalona przed testem) była:
`btrfs subvolume set-default <snapshot> /` + reboot. **Ta hipoteza została
odrzucona PRZED wykonaniem, nie empirycznie, na podstawie sprawdzenia
`grub.cfg`:** `grub-mkconfig` zapisuje w linii jądra `rootflags=subvol=@`
na twardo:

```
linux /vmlinuz-linux root=UUID=... rw rootflags=subvol=@ loglevel=3 quiet
```

`btrfs subvolume set-default` zmienia tylko to, co się montuje, gdy mount
NIE podaje jawnego `subvol=`/`rootflags=subvol=`. Skoro GRUB jawnie wymusza
`subvol=@`, zmiana "domyślnego subwolumenu" na poziomie btrfs **nie miałaby
żadnego efektu na to, co się bootuje** — hipoteza była nietestowalna w tej
formie, bo z definicji by nie zadziałała. Zamiast tego przetestowano
mechanizm rename-swap na poziomie top-level (`subvolid=5`), który DZIAŁA z
twardo zakodowanym `subvol=@`, bo fizycznie podmienia to, co leży pod tą
samą nazwą `@`. Potem się okazało (Test B), że to jest dosłownie to, co robi
prawdziwy `btrfs-assistant --restore`.

## Konkluzja

**POTWIERDZONE**, dwukrotnie — raz ręcznie (Test A), raz prawdziwym
narzędziem `btrfs-assistant --restore` z jego trybu CLI (Test B):

- Mechanizm rename-swap subwolumenu `@` na poziomie top-level poprawnie
  przywraca root do stanu z wybranego snapshotu.
- `/home` (osobny subwolumen `@home`) pozostaje całkowicie nienaruszony
  przy każdym teście.
- **Nie trzeba Live USB.** Operacja działa w pełni z działającego,
  zabootowanego systemu przez SSH — wbrew sugestii z Arch Wiki, że
  przywracanie `@` wymaga Live CD. To dotyczyło prawdopodobnie ostrożnej
  rekomendacji ogólnej, nie twardego wymogu technicznego; w naszym teście
  sesja SSH przetrwała całą operację rename+snapshot bez zakłóceń.
- `btrfs-assistant` ma gotowy, działający headless tryb CLI
  (`--list`/`--restore <N>`), który może być bezpośrednio wywołany z
  własnego UI/wrappera PandOS bez pisania własnej logiki subvolume-swap od
  zera — **to zmienia plan**: nie trzeba reimplementować mechanizmu
  rollbacku, wystarczy wywołać istniejące narzędzie.
- Nasz layout (`@`/`@home`/`@log`/`@pkg`/`@snapshots`) współpracuje z
  `btrfs-assistant`, `snapper` (po poprawce z punktu 4) i `grub-btrfs`/
  `grub-btrfsd` bez dalszych zmian.

**Otwarte pytania na później (nierozstrzygnięte w tym teście):**
- Czy GUI `btrfs-assistant` (nie CLI) ma identyczne zachowanie — nie
  sprawdzone, VM nie miała środowiska graficznego. Rozumowo powinno być
  tożsame (to samo binarne narzędzie, ten sam kod C++), ale niepotwierdzone.
- Sprzątanie starych `@_backup_*`/`@broken-test` subwolumenów po rollbacku
  nie jest automatyczne — do zaprojektowania (albo ręczne `btrfs subvolume
  delete`, albo automatyczna retencja w naszym wrapperze).
- Mechanizm szybkiej pętli `archinstall` (bez pełnego bootowania) wymaga
  przeprojektowania — patrz punkt 1 w sekcji "Co NIE zadziałało".

## Artefakty testu

Obraz dysku (12GiB), logi instalacji i skrypty pomocnicze zostały w
scratchpadzie sesji (`pandos-test.img`, `finish-install.sh`,
`finish-install.log`, `user_configuration.json`, `user_credentials.json`,
`qemu-boot.log`), NIE w tym repo (duże pliki binarne, już objęte
`.gitignore`). VM zatrzymana po teście, loop device odłączony.
