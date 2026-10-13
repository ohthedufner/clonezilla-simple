#!/bin/bash
# install-to-usb.sh — add Basic Disk Imaging to an existing Clonezilla Live USB.
#
#   sudo ./install-to-usb.sh /media/you/CLONEZILLA
#
# Copies basic-imaging.sh onto the stick and adds a new DEFAULT boot entry
# that launches it via Clonezilla's documented ocs_live_run= hook. The stock
# Clonezilla entries are left untouched, so nothing is lost.
#
# Run from Linux (or WSL with the stick mounted). Idempotent: re-run to update.

set -euo pipefail

USB=${1:-}
[ -z "$USB" ] && { echo "usage: $0 /path/to/mounted/clonezilla/usb"; exit 1; }
[ -d "$USB/live" ] || { echo "$USB does not look like a Clonezilla Live USB (no live/ folder)"; exit 1; }

HERE=$(cd "$(dirname "$0")" && pwd)
LABEL="Basic Disk Imaging (simple menu)"
# Path as seen from inside the booted live system; the medium is mounted here.
RUN_CMD="ocs_live_run=\"bash /lib/live/mount/medium/basic-imaging.sh\""

cp "$HERE/basic-imaging.sh" "$USB/basic-imaging.sh"
echo "copied basic-imaging.sh"

# ---------- syslinux / isolinux (BIOS boot) ----------
for cfg in "$USB"/syslinux/syslinux.cfg "$USB"/syslinux/isolinux.cfg; do
  [ -f "$cfg" ] || continue
  if grep -q "basic-imaging.sh" "$cfg"; then
    echo "$cfg already patched"; continue
  fi
  # Grab the first stock entry and clone it with our run hook.
  stock=$(awk '/^label /{if(f)exit; f=1} f' "$cfg")
  kernel=$(echo "$stock" | sed -n 's/^[[:space:]]*kernel //p' | head -1)
  append=$(echo "$stock" | sed -n 's/^[[:space:]]*append //p' | head -1)
  [ -n "$kernel" ] && [ -n "$append" ] || { echo "could not parse $cfg; skipping"; continue; }

  entry="label basic-imaging
  MENU DEFAULT
  MENU LABEL ${LABEL}
  kernel ${kernel}
  append ${append} ${RUN_CMD}
  TEXT HELP
  Back up / restore / verify a disk with a short guided menu.
  Full Clonezilla is available from inside this menu.
  ENDTEXT
"
  # remove any existing MENU DEFAULT, set ours, insert before first label
  sed -i '/^[[:space:]]*MENU DEFAULT/d' "$cfg"
  awk -v e="$entry" '!done && /^label /{print e; done=1} {print}' "$cfg" > "$cfg.tmp" && mv "$cfg.tmp" "$cfg"
  echo "patched $cfg"
done

# ---------- grub (UEFI boot) ----------
for cfg in "$USB"/boot/grub/grub.cfg "$USB"/EFI/boot/grub.cfg; do
  [ -f "$cfg" ] || continue
  if grep -q "basic-imaging.sh" "$cfg"; then
    echo "$cfg already patched"; continue
  fi
  # First stock menuentry block
  stock=$(awk '/^menuentry /{if(f)exit; f=1} f' "$cfg")
  linux=$(echo "$stock" | sed -n 's/^[[:space:]]*linux //p' | head -1)
  initrd=$(echo "$stock" | sed -n 's/^[[:space:]]*initrd //p' | head -1)
  [ -n "$linux" ] && [ -n "$initrd" ] || { echo "could not parse $cfg; skipping"; continue; }

  entry="menuentry \"${LABEL}\" --id basic-imaging {
  search --set -f /live/vmlinuz
  linux ${linux} ${RUN_CMD}
  initrd ${initrd}
}
"
  awk -v e="$entry" '!done && /^menuentry /{print e; done=1} {print}' "$cfg" > "$cfg.tmp" && mv "$cfg.tmp" "$cfg"
  # make it the default
  if grep -q '^set default=' "$cfg"; then
    sed -i 's/^set default=.*/set default="basic-imaging"/' "$cfg"
  else
    sed -i '1i set default="basic-imaging"' "$cfg"
  fi
  echo "patched $cfg"
done

sync
echo
echo "Done. Boot the USB; '${LABEL}' is the default entry."
echo "Stock Clonezilla entries remain in the boot menu, and also under 'Advanced' inside the simple menu."
