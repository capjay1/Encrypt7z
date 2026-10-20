[CmdletBinding()]
param()

# Removes everything Install.ps1 created (per-user).
$ErrorActionPreference = 'Continue'
$installDir = Join-Path $env:LOCALAPPDATA 'Programs\Encrypt7z'

foreach ($base in 'Software\Classes\*\shell\Encrypt7z', 'Software\Classes\Directory\shell\Encrypt7z') {
    [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($base, $false)
}
$lnk = Join-Path ([Environment]::GetFolderPath('SendTo')) 'Encrypt (7-Zip).lnk'
if (Test-Path -LiteralPath $lnk) { Remove-Item -LiteralPath $lnk -Force }

# This script may be running from inside the install folder, so delete it from a detached process.
if (Test-Path -LiteralPath $installDir) {
    Start-Process powershell.exe -WindowStyle Hidden -ArgumentList '-NoProfile', '-Command',
    "Start-Sleep 2; Remove-Item -LiteralPath '$installDir' -Recurse -Force"
}
Write-Host 'Encrypt7z removed.'
