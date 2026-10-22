#!/bin/bash
case "$1" in
  list-keymaps)
    find /usr/share/kbd/keymaps -name '*.map.gz' -printf '%f\n' 2>/dev/null | sed 's/\.map\.gz$//' | sort -u
    [ -z "$(find /usr/share/kbd/keymaps -name '*.map.gz' 2>/dev/null)" ] && echo "us"
    exit 0
    ;;
  set-keymap)
    echo "KEYMAP=${2:-us}" > /etc/vconsole.conf
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
