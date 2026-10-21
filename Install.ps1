[CmdletBinding()]
param(
    # Pinned version of the 7Zip4PowerShell module that gets vendored into the install folder.
    [string]$ModuleVersion = '2.4.0',
    # Offline install: a downloaded 7Zip4PowerShell .nupkg file, or the Modules folder copied from a PC where the install worked.
    [string]$ModuleSource = ''
)

# Per-user install, no admin needed. Safe to run again (it overwrites its own files and registry keys).
$ErrorActionPreference = 'Stop'
$installDir = Join-Path $env:LOCALAPPDATA 'Programs\Encrypt7z'
$script     = Join-Path $installDir 'Encrypt.ps1'
$launcher   = "conhost.exe --headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$script`""

Write-Host "Installing to $installDir"
New-Item -ItemType Directory -Force -Path $installDir | Out-Null
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Encrypt.ps1') -Destination $script -Force
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Uninstall.ps1') -Destination $installDir -Force
Unblock-File -LiteralPath $script

# Keep an existing config.json (user settings), otherwise create the default one.
$cfgFile = Join-Path $installDir 'config.json'
if (Test-Path -LiteralPath $cfgFile) { $cfg = Get-Content -LiteralPath $cfgFile -Raw | ConvertFrom-Json }
else {
    $cfg = [pscustomobject]@{ minPasswordLength = 10; encryptFilenames = $true; verify = $false; deleteOriginals = $false; moduleDllSha256 = '' }
}

# Vendor the pinned module.
$modDir = Join-Path $installDir 'Modules'
if (Test-Path -LiteralPath $modDir) {
    try { Remove-Item -LiteralPath $modDir -Recurse -Force -ErrorAction Stop }
    catch { throw "Cannot replace the old module, a file is in use. Close ALL PowerShell windows (one may have imported the module), then run Install.ps1 from a fresh window. Details: $($_.Exception.Message)" }
}
New-Item -ItemType Directory -Force -Path $modDir | Out-Null
function Expand-Nupkg {
    param([string]$File)
    $dest = Join-Path $modDir "7Zip4PowerShell\$ModuleVersion"
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    $zip = Join-Path $env:TEMP ('7z4ps-' + [Guid]::NewGuid().ToString('N') + '.zip')
    Copy-Item -LiteralPath $File -Destination $zip
    try { Expand-Archive -LiteralPath $zip -DestinationPath $dest -Force } finally { Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue }
}

if ($ModuleSource) {
    $src = (Resolve-Path -LiteralPath $ModuleSource).Path
    Write-Host "Using local module source: $src"
    if ((Get-Item -LiteralPath $src).PSIsContainer) {
        Copy-Item -Path (Join-Path $src '*') -Destination $modDir -Recurse -Force
    }
    else { Expand-Nupkg -File $src }
}
else {
    Write-Host "Downloading 7Zip4PowerShell $ModuleVersion from the PowerShell Gallery..."
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    # 1st try: curl.exe over IPv4 (fast; avoids long hangs when IPv6 routing to the gallery is broken).
    $curl  = Join-Path $env:SystemRoot 'System32\curl.exe'
    $nupkg = Join-Path $env:TEMP ('7Zip4PowerShell.' + $ModuleVersion + '.nupkg')
    $ok = $false
    if (Test-Path -LiteralPath $curl) {
        & $curl --ipv4 --fail --location --silent --show-error --connect-timeout 20 --max-time 300 --output $nupkg "https://www.powershellgallery.com/api/v2/package/7Zip4PowerShell/$ModuleVersion"
        $ok = ($LASTEXITCODE -eq 0) -and (Test-Path -LiteralPath $nupkg)
    }
    if ($ok) {
        try { Expand-Nupkg -File $nupkg } finally { Remove-Item -LiteralPath $nupkg -Force -ErrorAction SilentlyContinue }
    }
    else {
        Write-Warning 'curl.exe download failed; trying PowerShellGet (Save-Module)...'
        try { Save-Module -Name 7Zip4PowerShell -RequiredVersion $ModuleVersion -Path $modDir -Force -ErrorAction Stop }
        catch {
            throw ("Could not download the module: $($_.Exception.Message)`n" +
                "Check that this PC can reach https://www.powershellgallery.com (DNS, proxy, firewall). " +
                "Or install offline: re-run with -ModuleSource <path to 7Zip4PowerShell.$ModuleVersion.nupkg, or the Modules folder from a PC where install worked>.")
        }
    }
}
$dll = Get-ChildItem -LiteralPath $modDir -Recurse -Filter '7Zip4Powershell.dll' | Select-Object -First 1
if (-not $dll) { throw 'Module download looks incomplete: 7Zip4Powershell.dll not found.' }

# The gallery package does not include the 7-Zip engine; borrow it from the installed 7-Zip.
$engineSrc = Join-Path $env:ProgramFiles '7-Zip\7z.dll'
if (-not (Test-Path -LiteralPath $engineSrc)) { throw "7-Zip not found: $engineSrc is missing. Install 7-Zip (64-bit) first." }
$engineDst = Join-Path $dll.DirectoryName '7z64.dll'
if (-not (Test-Path -LiteralPath $engineDst)) { Copy-Item -LiteralPath $engineSrc -Destination $engineDst }

Get-ChildItem -LiteralPath $modDir -Recurse -File | Unblock-File
$hash = (Get-FileHash -LiteralPath $dll.FullName -Algorithm SHA256).Hash
$cfg.moduleDllSha256 = $hash
$cfg | ConvertTo-Json | Set-Content -LiteralPath $cfgFile -Encoding UTF8
Write-Host "Module DLL SHA-256: $hash"

# Icon: 7-Zip if present, otherwise a shell32 lock-like icon.
$icon = Join-Path $env:ProgramFiles '7-Zip\7zFM.exe'
if (-not (Test-Path -LiteralPath $icon)) { $icon = "$env:SystemRoot\System32\shell32.dll,47" }

# Right-click verb (classic menu: "Show more options"). Registry API because '*' is a wildcard for New-Item.
foreach ($base in 'Software\Classes\*\shell\Encrypt7z', 'Software\Classes\Directory\shell\Encrypt7z') {
    $k = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($base)
    $k.SetValue('', 'Encrypt...')
    $k.SetValue('Icon', $icon)
    $k.SetValue('MultiSelectModel', 'Single')   # one item only; use Send To for several
    $k.Close()
    $c = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey("$base\command")
    $c.SetValue('', "$launcher `"%1`"")
    $c.Close()
}

# Send To shortcut (explorer appends all selected paths as arguments).
$lnkPath = Join-Path ([Environment]::GetFolderPath('SendTo')) 'Encrypt (7-Zip).lnk'
$sh  = New-Object -ComObject WScript.Shell
$lnk = $sh.CreateShortcut($lnkPath)
$lnk.TargetPath = 'conhost.exe'
$lnk.Arguments  = "--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$script`""
$lnk.IconLocation = $icon
$lnk.Save()

Write-Host 'Done. Right-click a file > Show more options > Encrypt...   or   Send to > Encrypt (7-Zip).'
