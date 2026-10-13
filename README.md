# clonezilla-simple

A short guided menu for the thing most people actually use Clonezilla for:
**back up a disk, restore a disk, verify the image.** Everything else is one
keypress away in the original Clonezilla menu.

It is a single bash script that runs on an **unmodified Clonezilla Live USB**.
No custom ISO, no desktop environment — it fits on a 1 GB stick alongside
stock Clonezilla.

```
┌────────── Basic Disk Imaging ──────────┐
│ 1  Back up a disk to an image          │
│ 2  Restore an image to a disk          │
│ 3  Verify an image                     │
│ 4  Show attached disks                 │
│ 5  Advanced: original Clonezilla menu  │
│ 6  Drop to a shell                     │
└────────────────────────────────────────┘
```

## Why

Clonezilla is excellent and tiny, but even "Beginner mode" walks you through a
dozen screens of choices that don't matter for a straight disk image. Rescuezilla
solves the UX problem but is a full graphical ISO. This sits in between.

## What it does differently

- **Disks are shown as hardware, not letters.** You pick from
  `Samsung SSD 870 EVO · 931.5G · SATA · sn:S5Y... · [ntfs:Windows, vfat:EFI]`
  — not `sda`. The Clonezilla USB itself — and the drive holding your
  images — are hidden from the list.
- **Restore makes you prove it.** Full disk details, a default-No confirm,
  then you type the device name.
- **Verification is built in.** Every backup is checked with `ocs-chkimg`
  when it finishes; you can also verify any image on demand.
- **Sane defaults, no questions.** partclone, parallel gzip, 4 GB chunks
  (FAT32-safe), no encryption, no fsck. Edit two lines in the script if you
  want otherwise.
- **Nothing removed.** Option 5 is the stock `ocs-live-general` menu. Stock
  boot entries stay in the boot menu too.

## Install

### Step 1 — make a normal Clonezilla Live USB

Download the Clonezilla Live **ISO** (amd64, stable) and write it with
[Rufus](https://rufus.ie):

> **Do NOT use "DD Image" mode.** When Rufus asks, choose **"Write in ISO Image
> mode"** (the default). DD mode — and balenaEtcher, which only does DD — produce
> a read-only stick that Windows cannot write to, so the next step cannot work.

Any ~1 GB or larger stick is fine.

### Step 2 — add the simple menu

**Windows:** download this repo as a ZIP (green *Code* button → *Download ZIP*),
unzip it anywhere, and double-click **`windows\Install to USB.cmd`**.
It finds the Clonezilla stick, copies the menu onto it, and makes it the
default boot entry. Nothing is installed on your PC; it is a plain PowerShell
script and needs no admin rights.

**Linux / macOS:** mount the stick and run

```bash
sudo ./install-to-usb.sh /media/$USER/CLONEZILLA     # wherever it mounted
```

Both installers do the same thing: copy `basic-imaging.sh` to the root of the
stick and add a **default** boot entry (BIOS `syslinux.cfg` and UEFI `grub.cfg`)
that starts it through Clonezilla's documented `ocs_live_run=` hook. Stock
entries are kept. Re-running is safe.

### No installer at all?

Copy `basic-imaging.sh` to the root of the USB, boot normal Clonezilla,
choose *Enter_shell*, and run:

```
sudo bash /lib/live/mount/medium/basic-imaging.sh
```

## Image storage

When backing up or restoring you'll be asked where images live:

- another local partition (external USB drive, second internal disk)
- a Windows / Samba share
- an NFS share

It is mounted at `/home/partimag` exactly as Clonezilla expects, so images
made here are ordinary Clonezilla images and vice-versa.

## Under the hood

| Menu item | Command |
|-----------|---------|
| Back up   | `ocs-sr -q2 -c -j2 -z1p -i 4096 -sfsck -senc -p true savedisk NAME DISK` then `ocs-chkimg` |
| Restore   | `ocs-sr -g auto -e1 auto -e2 -r -j2 -c -p true restoredisk NAME DISK` |
| Verify    | `ocs-chkimg -or /home/partimag NAME` |

Logs go to `/var/log/basic-imaging.log` on the live system.

## Contributing

It's ~250 lines of bash using `dialog`. Ideas that would fit:

- partition-level (not whole-disk) backup/restore
- restore to a *smaller* disk (`-icds` + `-k1`) behind an "expert" toggle
- a scheduled/unattended mode via `ocs_live_run` kernel args
- translations (`dialog` strings are all in one file)

PRs welcome. Keep it dependency-free — it has to run on stock Clonezilla Live.

## License

MIT. Clonezilla itself is GPL and is not included or modified by this project.
