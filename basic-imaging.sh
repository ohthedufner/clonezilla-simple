#!/bin/bash
# basic-imaging.sh — a simple text menu for the 90% case on Clonezilla Live:
#   back up a disk, restore a disk, verify an image. Everything else falls
#   through to the stock Clonezilla menu (ocs-live-general).
#
# Runs on an unmodified Clonezilla Live USB. Depends only on tools already
# present there: bash, dialog, lsblk, blkid, udevadm, ocs-sr, ocs-chkimg.
#
# License: MIT

set -o pipefail

TITLE="Basic Disk Imaging"
IMG_ROOT="/home/partimag"              # Clonezilla's canonical image repo mountpoint
MOUNTED_REPO=""                        # set when we mount a repo ourselves
LOG="/var/log/basic-imaging.log"

# ----------------------------------------------------------------------------
# helpers
# ----------------------------------------------------------------------------
die()  { dialog --title "$TITLE" --msgbox "$1" 10 70; }
info() { dialog --title "$TITLE" --infobox "$1" 6 70; sleep 1; }

need() {
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || { echo "Missing required command: $c" >&2; exit 1; }
  done
}

human_size() {   # bytes -> "931.5 GB"
  numfmt --to=iec-i --suffix=B --format="%.1f" "$1" 2>/dev/null || echo "$1 B"
}

# The device the live system itself is running from — never offer it as a target.
boot_disk() {
  local src
  src=$(findmnt -n -o SOURCE /lib/live/mount/medium 2>/dev/null \
     || findmnt -n -o SOURCE /run/live/medium 2>/dev/null)
  [ -n "$src" ] && lsblk -no PKNAME "$src" 2>/dev/null | head -1
}

# Short human description of what's on a disk, e.g. "ntfs:Windows, vfat:EFI"
disk_contents() {
  local disk=$1 out=""
  while read -r name fstype label; do
    [ -z "$fstype" ] && continue
    out+="${out:+, }${fstype}${label:+:$label}"
  done < <(lsblk -rno NAME,FSTYPE,LABEL "/dev/$disk" | tail -n +2)
  [ -n "$out" ] && echo "$out" || echo "no recognised filesystems"
}

# Emit dialog menu items: "sda" "WDC WD10EZEX 931.5G SATA  [ntfs:Windows, vfat:EFI]"
disk_menu_items() {
  local skip name size model tran serial
  skip=$(boot_disk)
  while read -r name size model tran; do
    [ "$name" = "$skip" ] && continue
    serial=$(udevadm info --query=property --name="/dev/$name" 2>/dev/null \
             | sed -n 's/^ID_SERIAL_SHORT=//p')
    printf '%s\n' "$name"
    printf '%s\n' "$(printf '%-22.22s %7s %-5s %s  [%s]' \
       "${model:-unknown}" "$size" "${tran^^}" "${serial:+sn:$serial}" "$(disk_contents "$name")")"
  done < <(lsblk -dno NAME,SIZE,MODEL,TRAN -e 7,11 | awk '$1 !~ /^(loop|sr|zram)/')
}

pick_disk() {   # $1 = prompt ; prints chosen disk name
  local items
  mapfile -t items < <(disk_menu_items)
  [ ${#items[@]} -eq 0 ] && { die "No disks found (other than the Clonezilla boot media)."; return 1; }
  dialog --title "$TITLE" --no-tags --menu "$1\n\nModel · Size · Bus · Serial · [contents]" \
    20 110 10 "${items[@]}" 3>&1 1>&2 2>&3
}

# Full-detail block for confirmation screens
disk_summary() {
  local d=$1
  echo "Device:   /dev/$d"
  echo "Model:    $(lsblk -dno MODEL /dev/$d)"
  echo "Size:     $(lsblk -dno SIZE /dev/$d)"
  echo "Bus:      $(lsblk -dno TRAN /dev/$d)"
  echo "Serial:   $(udevadm info -q property -n /dev/$d | sed -n 's/^ID_SERIAL_SHORT=//p')"
  echo "Contents: $(disk_contents "$d")"
}

# ----------------------------------------------------------------------------
# image repository
# ----------------------------------------------------------------------------
# Mount a partition (not on the chosen target disk) or a network share at IMG_ROOT.
ensure_repo() {
  local exclude=$1   # disk we must not use as repo
  mountpoint -q "$IMG_ROOT" && return 0
  mkdir -p "$IMG_ROOT"

  local choice
  choice=$(dialog --title "$TITLE" --menu "Where are the images stored?" 12 70 3 \
    local "A partition on another local drive (USB disk, second HDD...)" \
    smb   "Windows / Samba network share" \
    nfs   "NFS network share" 3>&1 1>&2 2>&3) || return 1

  case $choice in
    local)
      local items=() name size fstype label pk
      while read -r name size fstype label pk; do
        [ -z "$fstype" ] && continue
        [ "$pk" = "$exclude" ] && continue
        [ "$pk" = "$(boot_disk)" ] && continue
        case $fstype in swap|crypto_LUKS|LVM2_member) continue;; esac
        items+=("$name" "$(printf '%-7s %-6s %-12s on %s (%s)' "$size" "$fstype" "${label:--}" "$pk" "$(lsblk -dno MODEL /dev/$pk)")")
      done < <(lsblk -rno NAME,SIZE,FSTYPE,LABEL,PKNAME | awk 'NF>=1 && $0 ~ / /')
      [ ${#items[@]} -eq 0 ] && { die "No usable partitions found for an image store."; return 1; }
      local part
      part=$(dialog --title "$TITLE" --no-tags --menu "Choose the partition holding (or to hold) the images:" 20 100 10 "${items[@]}" 3>&1 1>&2 2>&3) || return 1
      mount "/dev/$part" "$IMG_ROOT" || { die "Could not mount /dev/$part."; return 1; }
      ;;
    smb)
      local server share user pass
      server=$(dialog --title "$TITLE" --inputbox "Server (IP or hostname):" 8 60 3>&1 1>&2 2>&3) || return 1
      share=$(dialog  --title "$TITLE" --inputbox "Share name:" 8 60 3>&1 1>&2 2>&3) || return 1
      user=$(dialog   --title "$TITLE" --inputbox "Username:" 8 60 3>&1 1>&2 2>&3) || return 1
      pass=$(dialog   --title "$TITLE" --passwordbox "Password:" 8 60 3>&1 1>&2 2>&3) || return 1
      mount -t cifs "//$server/$share" "$IMG_ROOT" -o "username=$user,password=$pass" \
        || { die "Could not mount //$server/$share."; return 1; }
      ;;
    nfs)
      local server path
      server=$(dialog --title "$TITLE" --inputbox "NFS server (IP or hostname):" 8 60 3>&1 1>&2 2>&3) || return 1
      path=$(dialog   --title "$TITLE" --inputbox "Exported path (e.g. /srv/images):" 8 60 3>&1 1>&2 2>&3) || return 1
      mount -t nfs "$server:$path" "$IMG_ROOT" || { die "Could not mount $server:$path."; return 1; }
      ;;
  esac
  MOUNTED_REPO=1
}

release_repo() {
  [ -n "$MOUNTED_REPO" ] && { sync; umount "$IMG_ROOT" 2>/dev/null; MOUNTED_REPO=""; }
}

pick_image() {   # list image dirs in repo
  local items=() d
  for d in "$IMG_ROOT"/*/; do
    [ -f "$d/clonezilla-img" ] || continue
    d=${d%/}; d=${d##*/}
    items+=("$d" "$(du -sh "$IMG_ROOT/$d" 2>/dev/null | cut -f1)  $(stat -c %y "$IMG_ROOT/$d" | cut -d. -f1)")
  done
  [ ${#items[@]} -eq 0 ] && { die "No Clonezilla images found in the chosen location."; return 1; }
  dialog --title "$TITLE" --menu "Choose an image:" 20 90 10 "${items[@]}" 3>&1 1>&2 2>&3
}

run_and_show() {   # run a long command, show its output live, pause at the end
  clear
  echo "==> $*" | tee -a "$LOG"
  "$@" 2>&1 | tee -a "$LOG"
  local rc=${PIPESTATUS[0]}
  echo
  if [ "$rc" -eq 0 ]; then echo "*** Completed successfully. ***"; else echo "*** FAILED (exit $rc). See $LOG ***"; fi
  read -rp "Press Enter to return to the menu..." _
  return "$rc"
}

# ----------------------------------------------------------------------------
# actions
# ----------------------------------------------------------------------------
do_backup() {
  local disk name
  disk=$(pick_disk "Which disk do you want to BACK UP?") || return
  ensure_repo "$disk" || return

  name=$(dialog --title "$TITLE" --inputbox "Name for this image:" 8 60 \
         "$(hostname 2>/dev/null || echo pc)-$(lsblk -dno MODEL /dev/$disk | tr -cs 'A-Za-z0-9' '-' | sed 's/-$//')-$(date +%Y-%m-%d)" \
         3>&1 1>&2 2>&3) || { release_repo; return; }
  [ -e "$IMG_ROOT/$name" ] && { die "An image named '$name' already exists."; release_repo; return; }

  dialog --title "Confirm backup" --yesno "$(disk_summary "$disk")

Image will be saved to: $IMG_ROOT/$name
Free space there:       $(df -h --output=avail "$IMG_ROOT" | tail -1 | tr -d ' ')

The image is verified automatically after saving.
Proceed?" 18 80 || { release_repo; return; }

  # -q2 partclone, -j2 clone hidden data, -z1p parallel gzip, -i 0 no split,
  # -sfsck skip fsck, -senc no encryption, -p true: return here when done,
  # -c: ocs-sr confirms nothing itself (we already did).
  run_and_show ocs-sr -q2 -c -j2 -z1p -i 0 -sfsck -senc -p true savedisk "$name" "$disk" \
    && run_and_show ocs-chkimg -or "$IMG_ROOT" "$name"
  release_repo
}

do_restore() {
  local disk img
  ensure_repo "" || return
  img=$(pick_image) || { release_repo; return; }
  disk=$(pick_disk "Which disk should receive the image?\n\n  *** EVERYTHING ON THE CHOSEN DISK WILL BE ERASED ***") || { release_repo; return; }

  dialog --title "!!! DESTRUCTIVE OPERATION !!!" --defaultno --yesno "$(disk_summary "$disk")

Image to restore: $img

ALL DATA ON THIS DISK WILL BE OVERWRITTEN.
Are you absolutely sure?" 17 80 || { release_repo; return; }

  local typed
  typed=$(dialog --title "Final check" --inputbox "Type the device name ($disk) to confirm:" 8 60 3>&1 1>&2 2>&3)
  [ "$typed" = "$disk" ] || { die "Confirmation did not match. Nothing was changed."; release_repo; return; }

  # -g auto: reinstall grub, -e1 auto -e2: CHS fixes, -r: resize fs, -k: keep partition table from image
  run_and_show ocs-sr -g auto -e1 auto -e2 -r -j2 -c -p true restoredisk "$img" "$disk"
  release_repo
}

do_verify() {
  local img
  ensure_repo "" || return
  img=$(pick_image) || { release_repo; return; }
  run_and_show ocs-chkimg -or "$IMG_ROOT" "$img"
  release_repo
}

do_disk_list() {   # read-only "what's plugged in?" view
  local txt=""
  for d in $(lsblk -dno NAME -e 7,11 | grep -Ev '^(loop|sr|zram)'); do
    txt+="$(disk_summary "$d")"$'\n'
    [ "$d" = "$(boot_disk)" ] && txt+="          (this is the Clonezilla boot media)"$'\n'
    txt+=$'\n'
  done
  dialog --title "Attached disks" --msgbox "$txt" 30 90
}

# ----------------------------------------------------------------------------
# main
# ----------------------------------------------------------------------------
need dialog lsblk udevadm ocs-sr ocs-chkimg

while :; do
  choice=$(dialog --title "$TITLE" --cancel-label "Shutdown" \
    --menu "Clonezilla Live — simple mode\n\nUse arrow keys and Enter." 16 70 6 \
      1 "Back up a disk to an image" \
      2 "Restore an image to a disk" \
      3 "Verify an image" \
      4 "Show attached disks" \
      5 "Advanced: original Clonezilla menu" \
      6 "Drop to a shell" 3>&1 1>&2 2>&3)
  rc=$?
  if [ $rc -ne 0 ]; then
    dialog --title "$TITLE" --yesno "Shut down the computer now?" 6 40 && { clear; poweroff; }
    continue
  fi
  case $choice in
    1) do_backup ;;
    2) do_restore ;;
    3) do_verify ;;
    4) do_disk_list ;;
    5) clear; ocs-live-general ;;
    6) clear; echo "Type 'exit' to return to the menu."; bash ;;
  esac
done
