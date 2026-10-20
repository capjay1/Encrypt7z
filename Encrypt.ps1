[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Paths
)

# Encrypt.ps1 - core script. Called by the right-click verb (1 item) and by Send To (1..n items).
# Creates <name>.7z (AES-256, file names encrypted) next to the selected item(s) using the 7Zip4PowerShell module in-process,
# so the password never appears on a command line.

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()

$title = 'Encrypt (7-Zip)'
$root  = $PSScriptRoot

function Show-Msg {
    param([string]$Text, [string]$Icon = 'Information', [string]$Buttons = 'OK')
    [Windows.Forms.MessageBox]::Show($Text, $title, $Buttons, $Icon)
}

function Get-Config {
    $cfg = [ordered]@{
        minPasswordLength = 10
        encryptFilenames  = $true    # also encrypt file names inside the .7z
        verify            = $false   # extract to %TEMP% and compare; always done when deleting originals
        deleteOriginals   = $false   # default state of the checkbox
        moduleDllSha256   = ''       # filled in by Install.ps1
    }
    $file = Join-Path $root 'config.json'
    if (Test-Path -LiteralPath $file) {
        $json = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
        foreach ($k in @($cfg.Keys)) {
            if ($null -ne $json.$k) { $cfg[$k] = $json.$k }
        }
    }
    $cfg
}

function Get-PasswordStrength {
    param([string]$Pw)
    $classes = 0
    foreach ($re in '[a-z]', '[A-Z]', '\d', '[^a-zA-Z\d]') { if ($Pw -cmatch $re) { $classes++ } }
    $score = $classes
    if ($Pw.Length -ge 12) { $score++ }
    if ($Pw.Length -ge 16) { $score++ }
    if ($Pw.Length -lt 8)  { $score = [Math]::Min($score, 1) }
    if ($score -le 2) { 'weak' } elseif ($score -le 4) { 'good' } else { 'strong' }
}

function Get-UniquePath {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $Path }
    $dir  = Split-Path $Path -Parent
    $base = [IO.Path]::GetFileNameWithoutExtension($Path)
    $ext  = [IO.Path]::GetExtension($Path)
    $i = 1
    do { $candidate = Join-Path $dir "$base ($i)$ext"; $i++ } while (Test-Path -LiteralPath $candidate)
    $candidate
}

# Runs in a background runspace so the progress window stays responsive.
$work = {
    param($ModuleManifest, $Items, $Out, $Secure, $Verify, $EncNames)
    $result = @{ Ok = $false; Error = $null }
    $tmp = $null
    try {
        Import-Module -Name $ModuleManifest -Force
        $first = $true
        foreach ($i in $Items) {
            $p = @{
                Path             = $i.FullName
                ArchiveFileName  = $Out
                Format           = 'SevenZip'
                SecurePassword   = $Secure
            }
            if ($EncNames)        { $p.EncryptFilenames = $true }
            if ($i.PSIsContainer) { $p.PreserveDirectoryRoot = $true }
            if (-not $first)      { $p.Append = $true }
            Compress-7Zip @p
            $first = $false
        }
        if (-not (Test-Path -LiteralPath $Out)) { throw 'The archive was not created.' }

        if ($Verify) {
            $tmp = Join-Path $env:TEMP ('enc7z-' + [Guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $tmp | Out-Null
            Expand-7Zip -ArchiveFileName $Out -TargetPath $tmp -SecurePassword $Secure
            $srcFiles = @($Items | ForEach-Object {
                    if ($_.PSIsContainer) { Get-ChildItem -LiteralPath $_.FullName -Recurse -File -Force } else { $_ }
                })
            $outFiles = @(Get-ChildItem -LiteralPath $tmp -Recurse -File -Force)
            $srcBytes = ($srcFiles | Measure-Object Length -Sum).Sum
            $outBytes = ($outFiles | Measure-Object Length -Sum).Sum
            if ($srcFiles.Count -ne $outFiles.Count -or $srcBytes -ne $outBytes) {
                throw "Verification failed: source has $($srcFiles.Count) files / $srcBytes bytes, archive has $($outFiles.Count) files / $outBytes bytes."
            }
        }
        $result.Ok = $true
    }
    catch {
        $result.Error = $_.Exception.Message
        if (Test-Path -LiteralPath $Out) { Remove-Item -LiteralPath $Out -Force -ErrorAction SilentlyContinue }
    }
    finally {
        if ($tmp -and (Test-Path -LiteralPath $tmp)) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    }
    $result
}

$plain = $null
try {
    if (-not $Paths -or $Paths.Count -eq 0) { Show-Msg 'No files were passed to the script.' 'Warning'; return }
    $cfg = Get-Config

    # ---- 1. Validate input ----
    $items = @(); $skipped = @(); $cloud = $false
    foreach ($p in $Paths) {
        if (-not (Test-Path -LiteralPath $p)) { $skipped += "$p (not found)"; continue }
        $it = Get-Item -LiteralPath $p -Force
        $attr = [int]$it.Attributes
        $isCloud = ($attr -band 0x400000) -or ($attr -band 0x40000) -or ($attr -band 0x1000)  # recall flags / offline
        if ($isCloud) { $cloud = $true }
        elseif ($attr -band [int][IO.FileAttributes]::ReparsePoint) { $skipped += "$p (symlink/junction)"; continue }
        $items += $it
    }
    if ($items.Count -eq 0) { Show-Msg ("Nothing to encrypt:`n" + ($skipped -join "`n")) 'Warning'; return }

    # ---- 2. Plan output ----
    $outDir = Split-Path $items[0].FullName -Parent
    if ($items.Count -eq 1) {
        $defaultName = $items[0].Name + '.7z'
    }
    else {
        $folderName = Split-Path $outDir -Leaf
        if ([string]::IsNullOrWhiteSpace($folderName)) { $folderName = 'Archive' }
        $defaultName = $folderName + '.7z'
    }

    # ---- 3. Dialog ----
    $form = New-Object Windows.Forms.Form -Property @{
        Text = if ($items.Count -eq 1) { "Encrypt: $($items[0].Name)" } else { "Encrypt $($items.Count) items" }
        ClientSize = New-Object Drawing.Size(430, 290); FormBorderStyle = 'FixedDialog'
        StartPosition = 'CenterScreen'; TopMost = $true; MaximizeBox = $false; MinimizeBox = $false
    }
    function New-Ctl($type, $x, $y, $w, $h, $props = @{}) {
        $c = New-Object $type -Property $props
        $c.Location = New-Object Drawing.Point($x, $y); $c.Size = New-Object Drawing.Size($w, $h)
        $form.Controls.Add($c); $c
    }
    $null     = New-Ctl Windows.Forms.Label 15 18 95 20 @{ Text = 'Archive name:' }
    $txtName  = New-Ctl Windows.Forms.TextBox 115 15 300 22 @{ Text = $defaultName }
    $null     = New-Ctl Windows.Forms.Label 15 46 95 20 @{ Text = 'Saved to:' }
    $null     = New-Ctl Windows.Forms.Label 115 46 300 20 @{ Text = $outDir; AutoEllipsis = $true }
    $null     = New-Ctl Windows.Forms.Label 15 72 400 20 @{ Text = $(if ([bool]$cfg.encryptFilenames) { 'Format: 7z, AES-256 (file names encrypted too)' } else { 'Format: 7z, AES-256 (file names visible)' }); ForeColor = 'DimGray' }
    $null     = New-Ctl Windows.Forms.Label 15 102 95 20 @{ Text = 'Password:' }
    $txtPw1   = New-Ctl Windows.Forms.TextBox 115 99 300 22 @{ UseSystemPasswordChar = $true }
    $null     = New-Ctl Windows.Forms.Label 15 132 95 20 @{ Text = 'Confirm:' }
    $txtPw2   = New-Ctl Windows.Forms.TextBox 115 129 300 22 @{ UseSystemPasswordChar = $true }
    $chkShow  = New-Ctl Windows.Forms.CheckBox 115 158 140 20 @{ Text = 'Show password' }
    $lblStat  = New-Ctl Windows.Forms.Label 260 160 155 20 @{ Text = ''; TextAlign = 'MiddleRight' }
    $chkDel   = New-Ctl Windows.Forms.CheckBox 15 190 400 20 @{ Text = 'Permanently delete originals after verified success'; Checked = [bool]$cfg.deleteOriginals }
    $lblNote  = New-Ctl Windows.Forms.Label 15 214 400 36 @{ ForeColor = 'DarkRed'; Text = '' }
    $btnOk    = New-Ctl Windows.Forms.Button 245 252 80 28 @{ Text = 'Encrypt'; Enabled = $false; DialogResult = 'OK' }
    $btnCn    = New-Ctl Windows.Forms.Button 335 252 80 28 @{ Text = 'Cancel'; DialogResult = 'Cancel' }
    $form.AcceptButton = $btnOk; $form.CancelButton = $btnCn

    $notes = @()
    if ($skipped) { $notes += "Skipped: $($skipped.Count) item(s) (symlink or missing)." }
    if ($cloud)   { $notes += 'Some items are cloud-only (OneDrive) and will be downloaded.' }
    $lblNote.Text = $notes -join ' '
    $chkDel.Add_CheckedChanged({
            $lblNote.Text = (@($notes) + $(if ($chkDel.Checked) { 'Deleted files bypass the Recycle Bin and may still be recoverable on SSDs.' }) | Where-Object { $_ }) -join ' '
        })

    $update = {
        $nameOk = $txtName.Text.Trim().Length -gt 0 -and $txtName.Text.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -lt 0
        $match  = $txtPw1.Text.Length -gt 0 -and $txtPw1.Text -ceq $txtPw2.Text
        $long   = $txtPw1.Text.Length -ge [int]$cfg.minPasswordLength
        $lblStat.Text = if ($txtPw1.Text.Length -eq 0) { '' } elseif (-not $long) { "min. $($cfg.minPasswordLength) characters" } else { 'strength: ' + (Get-PasswordStrength $txtPw1.Text) }
        $btnOk.Enabled = $nameOk -and $match -and $long
    }
    $txtName.Add_TextChanged($update); $txtPw1.Add_TextChanged($update); $txtPw2.Add_TextChanged($update)
    $chkShow.Add_CheckedChanged({
            $txtPw1.UseSystemPasswordChar = -not $chkShow.Checked
            $txtPw2.UseSystemPasswordChar = -not $chkShow.Checked
        })

    if ($form.ShowDialog() -ne 'OK') { return }   # cancelled: leave nothing behind

    $plain  = $txtPw1.Text
    $secure = ConvertTo-SecureString -String $plain -AsPlainText -Force
    $plain  = $null; $txtPw1.Text = ''; $txtPw2.Text = ''
    $deleteOriginals = $chkDel.Checked
    $name = $txtName.Text.Trim()
    if (-not $name.ToLower().EndsWith('.7z')) { $name += '.7z' }
    $out = Get-UniquePath (Join-Path $outDir $name)
    $verify = [bool]$cfg.verify -or $deleteOriginals

    # ---- 4. Load pinned module (hash-checked) ----
    $modDir   = Join-Path $root 'Modules'
    $manifest = Get-ChildItem -LiteralPath $modDir -Recurse -Filter '7Zip4PowerShell.psd1' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $manifest) { throw "7Zip4PowerShell module not found in $modDir. Re-run Install.ps1." }
    $dll = Get-ChildItem -LiteralPath $manifest.DirectoryName -Recurse -Filter '7Zip4Powershell.dll' | Select-Object -First 1
    if ($cfg.moduleDllSha256) {
        $hash = (Get-FileHash -LiteralPath $dll.FullName -Algorithm SHA256).Hash
        if ($hash -ne $cfg.moduleDllSha256) { throw 'Module integrity check failed (hash mismatch). Re-run Install.ps1 if you updated it on purpose.' }
    }

    # ---- 5. Encrypt (+ verify) with a progress window ----
    $prog = New-Object Windows.Forms.Form -Property @{
        Text = $title; ClientSize = New-Object Drawing.Size(340, 80); FormBorderStyle = 'FixedDialog'
        StartPosition = 'CenterScreen'; TopMost = $true; ControlBox = $false
    }
    $lbl = New-Object Windows.Forms.Label -Property @{ Text = $(if ($verify) { 'Encrypting and verifying...' } else { 'Encrypting...' }); Left = 15; Top = 12; Width = 310 }
    $bar = New-Object Windows.Forms.ProgressBar -Property @{ Style = 'Marquee'; Left = 15; Top = 40; Width = 310; Height = 20 }
    $prog.Controls.AddRange(@($lbl, $bar)); $prog.Show()

    $rs = [runspacefactory]::CreateRunspace(); $rs.ApartmentState = 'STA'; $rs.Open()
    $ps = [powershell]::Create(); $ps.Runspace = $rs
    [void]$ps.AddScript($work).AddArgument($manifest.FullName).AddArgument($items).AddArgument($out).AddArgument($secure).AddArgument($verify).AddArgument([bool]$cfg.encryptFilenames)
    $async = $ps.BeginInvoke()
    while (-not $async.IsCompleted) { [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 50 }
    $result = $ps.EndInvoke($async) | Select-Object -Last 1
    $ps.Dispose(); $rs.Dispose(); $secure.Dispose(); $prog.Close()

    if (-not $result.Ok) {
        Show-Msg "Encryption failed:`n$($result.Error)" 'Error'
        return
    }

    # ---- 6. Clean up originals (permanent delete, only after verification; not a secure wipe) ----
    $delMsg = ''
    if ($deleteOriginals) {
        foreach ($i in $items) {
            try {
                Remove-Item -LiteralPath $i.FullName -Recurse -Force -ErrorAction Stop
            }
            catch { $delMsg += "`nCould not delete: $($i.FullName)" }
        }
    }

    # ---- 7. Report: silent on success; only problems get a dialog ----
    if ($delMsg) { Show-Msg "The archive was created:`n$out`n$delMsg" 'Warning' }
}
catch {
    Show-Msg "Unexpected error:`n$($_.Exception.Message)" 'Error'
}
finally {
    $plain = $null
}
