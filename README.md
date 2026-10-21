# Encrypt7z

Right-click encryption for Windows 11: 7z + AES-256 (file names encrypted) via the 7Zip4PowerShell module (in-process, no password on any command line).

## Install
1. Copy this folder to the PC.
2. In PowerShell (no admin): `powershell -ExecutionPolicy Bypass -File .\Install.ps1`
   (needs internet once, to fetch the pinned module from the PowerShell Gallery)

### Offline or blocked network
If the PowerShell Gallery is unreachable (for example, broken IPv6 routing), the installer automatically retries over IPv4 with the built-in `curl.exe`. If that also fails, get `https://www.powershellgallery.com/api/v2/package/7Zip4PowerShell/2.4.0` on another PC (it saves a `.nupkg`), or copy `%LOCALAPPDATA%\Programs\Encrypt7z\Modules` from a PC where the install worked, then run:
`powershell -ExecutionPolicy Bypass -File .\Install.ps1 -ModuleSource <path to the .nupkg or Modules folder>`

## Use
- One item: right-click > Show more options > **Encrypt...**
- Several items: select them > right-click > Show more options > Send to > **Encrypt (7-Zip)**
- Output: `<name>.7z` in the same folder (multiple items: `<parent folder name>.7z`). Existing files are never overwritten.

## Settings
`%LOCALAPPDATA%\Programs\Encrypt7z\config.json`: `minPasswordLength`, `encryptFilenames`, `verify` (extracts to %TEMP% to compare, deleted right after), `deleteOriginals` (default state of the checkbox, permanent delete (no Recycle Bin, not a secure wipe), only after verification, off by default).

## Uninstall
`%LOCALAPPDATA%\Programs\Encrypt7z\Uninstall.ps1`

## Requirements
Windows 11, [7-Zip](https://www.7-zip.org/) (64-bit) installed, internet access during install.

## Third-party components
This repository contains only the scripts below, licensed under MIT (see `LICENSE`). It does not include any third-party binaries:
- The installer downloads the [7Zip4PowerShell](https://www.powershellgallery.com/packages/7Zip4PowerShell) module from the PowerShell Gallery at install time. It has its own license; check it before redistributing the installed files.
- The 7-Zip engine (`7z.dll`) is copied from your own 7-Zip installation. 7-Zip is licensed under the GNU LGPL (with an unRAR restriction).

## Security notes
- Encryption: 7z format, AES-256; the password is handled in-process and never placed on a command line.
- "Delete originals" is a normal permanent delete, not a secure wipe; deleted data may remain recoverable on SSDs. Use BitLocker/Device Encryption for that.
- Scripts run with `-ExecutionPolicy Bypass` (per process only).
