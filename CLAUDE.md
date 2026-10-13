# clonezilla-simple — project notes for Claude Code

## What this is
A single bash `dialog` menu (`basic-imaging.sh`) that runs on an **unmodified
Clonezilla Live USB** via the `ocs_live_run=` kernel hook, offering the 90% case:
back up a disk, restore a disk, verify an image. Option 5 drops to the stock
`ocs-live-general` menu. Two installers patch an existing stick's boot menus.
MIT licensed, public on GitHub (ohthedufner/clonezilla-simple).

## Hard constraints
- **Zero dependencies beyond stock Clonezilla Live.** Only bash, dialog, lsblk,
  blkid, udevadm, findmnt, ocs-sr, ocs-chkimg. Do not add Python, Perl, whiptail-
  only features, or anything that needs a package install.
- **Must fit a 1 GB stick.** The script is ~10 KB; keep it that way.
- **Windows installer must stay no-install, no-admin, no-exe.** `windows/Install to
  USB.cmd` launches `Install-ToUsb.ps1` with `-ExecutionPolicy Bypass`. Do not
  compile to .exe (ps2exe) — unsigned PS-exes trip SmartScreen/AV.
- **Both installers must produce byte-identical results.** Test fixture: real
  Clonezilla 3.x `syslinux.cfg` and `grub.cfg` (see "Testing"). The grub config
  uses `$linux_cmd`/`$initrd_cmd` variables, not literal `linux`/`initrd`.
- **Replace, don't append, `ocs_live_run=`** — stock configs already set it to
  `ocs-live-general`.
- Line endings: `.sh`/`.ps1` LF, `.cmd` CRLF (enforced by `.gitattributes`).
  The PS installer rewrites copied files as LF/no-BOM via `Save-Unix`.

## Layout
- `basic-imaging.sh` — the TUI. Sections: helpers, image repository, actions, main.
- `install-to-usb.sh` — Linux/macOS installer.
- `windows/Install to USB.cmd` + `windows/Install-ToUsb.ps1` — Windows installer.
  `-Drive X:` skips auto-detect. Detects CDFS/UDF (DD-mode/Etcher) sticks and
  tells the user to re-flash with Rufus in ISO mode.
- `README.md` — user-facing. Keep the "Do NOT use DD mode" warning prominent.

## Disk picker rules
Users identify drives by hardware, not letters: Model · Size · Bus · Serial ·
[fstype:label, …]. The live medium's own disk (`boot_disk()`) is never listed as a
target. Restore requires a default-No confirm plus typing the device name.

## ocs-sr defaults (change deliberately)
- savedisk: `-q2 -c -j2 -z1p -i 0 -sfsck -senc -p true`, then `ocs-chkimg`.
- restoredisk: `-g auto -e1 auto -e2 -r -j2 -c -p true`.
Images live at `/home/partimag` (Clonezilla's canonical mountpoint).

## Testing
No Clonezilla in CI; the installers are tested against fixture copies of stock
configs. Pattern used so far:
```
mkdir -p fake/live fake/syslinux fake/boot/grub   # + stock cfg files
./install-to-usb.sh fake                          # bash
pwsh -File windows/Install-ToUsb.ps1 -Drive fake  # powershell
diff the two results; run each twice (second run must be a no-op)
shellcheck -S warning *.sh
```
**Not yet verified on real hardware**: `ocs-sr` flag set on current Clonezilla,
and the medium path `/lib/live/mount/medium` (older builds used `/live/image`).
First real test: Rufus a stick, run the .cmd, boot in a VM against a scratch disk.

## Style
Concise, peer-level. Tell Eric when a mature existing solution covers something
before building it. Commit messages: imperative subject, short body.
