#!/bin/bash
# Host-side driver for the fast loop. Creates/reuses a raw disk image,
# attaches it to the first free loop device via `losetup -f` (never a
# hardcoded /dev/loopN - that previously collided with a loop device snapd
# already had claimed), runs run-fast-loop.sh inside a privileged Arch
# container with that device passed in via $LOOP_DEV, and detaches it again
# on exit, success or failure.
#
# losetup needs root; this host has no passwordless sudo configured, so run
# this script with sudo yourself (or as root):
#   sudo pandos-config/build-fast-loop.sh
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "This script needs root (for losetup). Re-run with sudo." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMG="${IMG:-$SCRIPT_DIR/build/pandos-fast-loop.img}"
IMG_SIZE="${IMG_SIZE:-14G}"
CONTAINER_IMAGE="${CONTAINER_IMAGE:-archlinux:latest}"

mkdir -p "$(dirname "$IMG")"
if [ ! -f "$IMG" ]; then
  echo "Creating fresh disk image: $IMG ($IMG_SIZE)"
  truncate -s "$IMG_SIZE" "$IMG"
fi

LOOP_DEV=$(losetup -f --show -P "$IMG")
echo "Attached $IMG as $LOOP_DEV"

cleanup() {
  echo "Detaching $LOOP_DEV"
  losetup -d "$LOOP_DEV" 2>/dev/null || true
}
trap cleanup EXIT

docker run --rm --privileged \
  -v "$SCRIPT_DIR":/work \
  -v /dev:/dev \
  -e LOOP_DEV="$LOOP_DEV" \
  "$CONTAINER_IMAGE" bash /work/run-fast-loop.sh
