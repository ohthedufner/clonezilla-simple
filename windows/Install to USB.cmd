@echo off
:: Double-click me. Adds the Basic Disk Imaging menu to a Clonezilla Live USB.
:: Nothing is installed on this PC; this just runs the PowerShell script next to it.
title clonezilla-simple installer
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-ToUsb.ps1"
if errorlevel 1 (
  echo.
  echo Something went wrong. See messages above.
)
echo.
pause
