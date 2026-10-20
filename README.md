# Encrypt7z

Right-click encryption for Windows 11: 7z + AES-256 (file names encrypted) via the 7Zip4PowerShell module (in-process, no password on any command line).

## Install
1. Copy this folder to the PC.
2. In PowerShell (no admin): `powershell -ExecutionPolicy Bypass -File .\Install.ps1`
   (needs internet once, to fetch the pinned module from the PowerShell Gallery)

## Use
- One item: right-click > Show more options > **Encrypt...**
- Several items: select them > right-click > Show more options > Send to > **Encrypt (7-Zip)**
- Output: `<name>.7z` in the same folder (multiple items: `<parent folder name>.7z`). Existing files are never overwritten.

## Settings
`%LOCALAPPDATA%\Programs\Encrypt7z\config.json`: `minPasswordLength`, `encryptFilenames`, `verify` (extracts to %TEMP% to compare, deleted right after), `deleteOriginals` (default state of the checkbox, permanent delete (no Recycle Bin, not a secure wipe), only after verification, off by default).

## Uninstall
`%LOCALAPPDATA%\Programs\Encrypt7z\Uninstall.ps1`
