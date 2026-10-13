<#
.SYNOPSIS
  Add the Basic Disk Imaging menu to an existing Clonezilla Live USB (Windows).

.DESCRIPTION
  Finds removable drives that contain a Clonezilla Live layout, copies
  basic-imaging.sh to the root, and adds a new DEFAULT boot entry to both
  syslinux.cfg (BIOS) and grub.cfg (UEFI) using Clonezilla's ocs_live_run= hook.
  Stock entries are left untouched. Safe to re-run.

  No admin rights needed — it only writes files on a FAT32 USB stick.
#>
param([string]$Drive)   # optional: skip auto-detect, e.g. -Drive E:
$ErrorActionPreference = 'Stop'

$Label  = 'Basic Disk Imaging (simple menu)'
$RunCmd = 'ocs_live_run="bash /lib/live/mount/medium/basic-imaging.sh"'
$Src    = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) '..\basic-imaging.sh'
if (-not (Test-Path $Src)) { $Src = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'basic-imaging.sh' }
if (-not (Test-Path $Src)) { throw "basic-imaging.sh not found next to this script." }

# Replace an existing ocs_live_run="..." (stock Clonezilla sets it) or append ours.
function Set-RunHook([string]$kargs) {
  if ($kargs -match 'ocs_live_run=("[^"]*"|\S*)') { return ($kargs -replace 'ocs_live_run=("[^"]*"|\S*)', $RunCmd) }
  return "$kargs $RunCmd"
}

# Replace only the FIRST match (the static [regex]::Replace's 4th arg is RegexOptions, not a count).
function Replace-First([string]$text, [string]$pattern, [string]$with) {
  $rx = New-Object Text.RegularExpressions.Regex($pattern, 'Multiline')
  return $rx.Replace($text, $with.Replace('$', '$$'), 1)
}

function Write-Step($m) { Write-Host "  $m" -ForegroundColor Cyan }
function Write-Ok($m)   { Write-Host "  $m" -ForegroundColor Green }

# Write text with LF endings and no BOM — syslinux/grub on the live system expect Unix files.
function Save-Unix($path, [string]$text) {
  $text = $text -replace "`r`n", "`n"
  [IO.File]::WriteAllText($path, $text, (New-Object Text.UTF8Encoding $false))
}

Write-Host ""
Write-Host "clonezilla-simple — add Basic Disk Imaging to a Clonezilla Live USB" -ForegroundColor White
Write-Host ""

# ---------------------------------------------------------------- find the stick
if ($Drive) {
  $Drive = $Drive.TrimEnd('\')
  if (-not (Test-Path (Join-Path $Drive 'live'))) { throw "$Drive does not contain a Clonezilla Live layout (no live\ folder)." }
  $target = [pscustomobject]@{ Drive=$Drive; Label='(given)'; SizeGB='?'; FS='?' }
} else {
$candidates = Get-CimInstance Win32_LogicalDisk |
  Where-Object { $_.DriveType -in 2,3 -and $_.DeviceID -ne $env:SystemDrive } |
  ForEach-Object {
    $root = "$($_.DeviceID)\"
    [pscustomobject]@{
      Drive    = $_.DeviceID
      Label    = $_.VolumeName
      FS       = $_.FileSystem
      SizeGB   = [math]::Round($_.Size / 1GB, 1)
      IsCz     = (Test-Path "$root\live") -and ((Test-Path "$root\syslinux\syslinux.cfg") -or (Test-Path "$root\boot\grub\grub.cfg"))
      ReadOnly = $_.FileSystem -in 'CDFS','UDF'
    }
  }

$cz = @($candidates | Where-Object IsCz)

if ($cz.Count -eq 0) {
  $ro = @($candidates | Where-Object { $_.ReadOnly -and (Test-Path "$($_.Drive)\live") })
  if ($ro.Count -gt 0) {
    Write-Host "Found a Clonezilla drive ($($ro[0].Drive)) but it is read-only ($($ro[0].FS))." -ForegroundColor Yellow
    Write-Host "That happens when the ISO was written raw: balenaEtcher, or Rufus in 'DD Image' mode."
    Write-Host "DO NOT use DD mode. Re-create the stick with Rufus and choose 'ISO Image' mode when asked,"
    Write-Host "then run this again."
  } else {
    Write-Host "No Clonezilla Live USB found." -ForegroundColor Yellow
    Write-Host "Plug in the stick you made with Rufus and run this again."
    Write-Host ""
    Write-Host "Drives seen:"
    $candidates | Format-Table Drive, Label, FS, SizeGB -AutoSize | Out-String | Write-Host
  }
  exit 1
}

if ($cz.Count -eq 1) {
  $target = $cz[0]
} else {
  Write-Host "More than one Clonezilla USB found:"
  for ($i = 0; $i -lt $cz.Count; $i++) {
    Write-Host ("  [{0}] {1}  {2}  {3} GB" -f ($i+1), $cz[$i].Drive, $cz[$i].Label, $cz[$i].SizeGB)
  }
  $n = Read-Host "Which one"
  $target = $cz[[int]$n - 1]
}
}   # end auto-detect

$usb = $target.Drive
if ($usb -match '^[A-Za-z]:$') { $usb += '\' }
Write-Host "Target: $($target.Drive)  ($($target.Label), $($target.SizeGB) GB, $($target.FS))"
Write-Host ""

# ---------------------------------------------------------------- copy script
Write-Step "Copying basic-imaging.sh"
Save-Unix (Join-Path $usb 'basic-imaging.sh') (Get-Content $Src -Raw)
Write-Ok "done"

# ---------------------------------------------------------------- syslinux (BIOS)
foreach ($rel in 'syslinux\syslinux.cfg','syslinux\isolinux.cfg') {
  $cfg = Join-Path $usb $rel
  if (-not (Test-Path $cfg)) { continue }
  $text = (Get-Content $cfg -Raw) -replace "`r`n", "`n"
  if ($text -match 'basic-imaging\.sh') { Write-Ok "$rel already patched"; continue }

  Write-Step "Patching $rel"
  # first "label ..." block
  $m = [regex]::Match($text, '(?ms)^label [^\n]*\n(.*?)(?=^label |\z)')
  if (-not $m.Success) { Write-Host "  could not find a label block; skipping" -ForegroundColor Yellow; continue }
  $block  = $m.Value
  $kernel = [regex]::Match($block, '(?m)^\s*kernel (.+)$').Groups[1].Value.Trim()
  $append = [regex]::Match($block, '(?m)^\s*append (.+)$').Groups[1].Value.Trim()
  if (-not $kernel -or -not $append) { Write-Host "  could not parse kernel/append; skipping" -ForegroundColor Yellow; continue }

  $entry = @"
label basic-imaging
  MENU DEFAULT
  MENU LABEL $Label
  kernel $kernel
  append $(Set-RunHook $append)
  TEXT HELP
  Back up / restore / verify a disk with a short guided menu.
  Full Clonezilla is available from inside this menu.
  ENDTEXT

"@
  $text = [regex]::Replace($text, '(?m)^\s*MENU DEFAULT\s*\n', '')          # drop old default
  $text = Replace-First $text '^label ' ($entry + "`n" + 'label ')   # insert before first label
  Save-Unix $cfg $text
  Write-Ok "done"
}

# ---------------------------------------------------------------- grub (UEFI)
foreach ($rel in 'boot\grub\grub.cfg','EFI\boot\grub.cfg') {
  $cfg = Join-Path $usb $rel
  if (-not (Test-Path $cfg)) { continue }
  $text = (Get-Content $cfg -Raw) -replace "`r`n", "`n"
  if ($text -match 'basic-imaging\.sh') { Write-Ok "$rel already patched"; continue }

  Write-Step "Patching $rel"
  $m = [regex]::Match($text, '(?ms)^menuentry [^\n]*\{[ \t]*\n(.*?)^\}')
  if (-not $m.Success) { Write-Host "  could not find a menuentry; skipping" -ForegroundColor Yellow; continue }
  $block  = $m.Value
  $lm = [regex]::Match($block, '(?m)^\s*(\$linux_cmd|linuxefi|linux) (.+)$')
  $im = [regex]::Match($block, '(?m)^\s*(\$initrd_cmd|initrdefi|initrd) (.+)$')
  if (-not $lm.Success -or -not $im.Success) { Write-Host "  could not parse linux/initrd; skipping" -ForegroundColor Yellow; continue }
  $linuxCmd  = $lm.Groups[1].Value; $linux  = $lm.Groups[2].Value.Trim()
  $initrdCmd = $im.Groups[1].Value; $initrd = $im.Groups[2].Value.Trim()

  $entry = @"
menuentry "$Label" --id basic-imaging {
  search --set -f /live/vmlinuz
  $linuxCmd $(Set-RunHook $linux)
  $initrdCmd $initrd
}

"@
  $text = Replace-First $text '^menuentry ' ($entry + "`n" + 'menuentry ')
  if ($text -match '(?m)^set default=') {
    $text = Replace-First $text '^set default=.*$' 'set default="basic-imaging"'
  } else {
    $text = 'set default="basic-imaging"' + "`n" + $text
  }
  Save-Unix $cfg $text
  Write-Ok "done"
}

Write-Host ""
Write-Host "Finished. Boot from the USB; '$Label' is now the default entry." -ForegroundColor Green
Write-Host "The original Clonezilla entries are still in the boot menu, and under 'Advanced' inside the simple menu."
Write-Host "You can safely eject the drive now."
