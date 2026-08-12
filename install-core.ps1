#requires -Version 5.1
<#
.SYNOPSIS
    ตัวติดตั้ง BOOSTER X แบบคำสั่งเดียวผ่าน PowerShell
.DESCRIPTION
    ดาวน์โหลด Release ตาม PRODUCT_CHANNEL.json ตรวจ SHA-256 ตรวจ PACKAGE_INTEGRITY.json
    ติดตั้งแบบสลับโฟลเดอร์พร้อม Rollback ลบ Shortcut รุ่นเก่า และสร้างรายการถอนการติดตั้ง
.NOTES
    Script นี้ไม่ลบ Settings, Snapshots, Recovery หรือ Logs เดิมระหว่างอัปเดต
#>

[CmdletBinding()]
param(
    [string]$ManifestUrl = 'https://raw.githubusercontent.com/siwaphong76-gif/BOOSTER-X-Releases/main/PRODUCT_CHANNEL.json',
    [switch]$Silent,
    [switch]$NoLaunch,
    [switch]$Force
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$ProductName = 'BOOSTER X'
$InstallRoot = Join-Path $env:LOCALAPPDATA 'Programs\BOOSTER X'
$DataRoot = Join-Path $env:LOCALAPPDATA 'BOOSTER X'
$LogRoot = Join-Path $DataRoot 'Logs'
$LaunchFailureLog = Join-Path $LogRoot 'last-launch-error.log'
$StartMenuRoot = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\BOOSTER X'
$DesktopShortcut = Join-Path ([Environment]::GetFolderPath('Desktop')) 'BOOSTER X.lnk'
$StartMenuShortcut = Join-Path $StartMenuRoot 'BOOSTER X.lnk'
$UninstallScript = Join-Path $DataRoot 'Uninstall-BOOSTER-X.ps1'
$UninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\BOOSTER X'
$InstallId = [Guid]::NewGuid().ToString('N')
$WorkRoot = Join-Path (Join-Path $env:LOCALAPPDATA 'Programs') ('.BOOSTERX-install-' + $InstallId)
$DownloadPartial = Join-Path $WorkRoot 'BOOSTER_X.zip.partial'
$DownloadZip = Join-Path $WorkRoot 'BOOSTER_X.zip'
$ExtractRoot = Join-Path $WorkRoot 'extracted'
$IncomingRoot = Join-Path (Split-Path -Parent $InstallRoot) ('.BOOSTERX-incoming-' + $InstallId)
$BackupRoot = Join-Path (Split-Path -Parent $InstallRoot) ('.BOOSTERX-backup-' + $InstallId)
$LogPath = $null
$BackupCreated = $false
$InstallCommitted = $false
$PreserveCommittedInstall = $false

function Get-ConsoleSafeText {
    param([string]$Message)
    if ([string]::IsNullOrWhiteSpace($Message) -or $Message -notmatch '[^\x00-\x7F]') { return $Message }
    $errorCode = [regex]::Match($Message, '\[BX-[A-Z0-9-]+\]')
    if ($errorCode.Success) {
        return ($errorCode.Value + '  OPERATION FAILED - DETAILS SAVED TO DIAGNOSTIC LOG')
    }
    return 'NOTICE  //  OPERATION DETAILS SAVED TO DIAGNOSTIC LOG'
}

function Write-Status {
    param([string]$Message, [ConsoleColor]$Color = [ConsoleColor]::Gray)
    if (-not $Silent) { Write-Host (Get-ConsoleSafeText $Message) -ForegroundColor $Color }
    if ($LogPath) {
        Add-Content -LiteralPath $LogPath -Value ((Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + '  ' + $Message) -Encoding UTF8
    }
}

function Write-Diagnostic {
    param([string]$Message)
    if ($LogPath) {
        Add-Content -LiteralPath $LogPath -Value ((Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + '  [DIAGNOSTIC] ' + $Message) -Encoding UTF8
    }
}

function Initialize-InstallerConsole {
    if ($Silent) { return }
    try {
        $utf8 = New-Object Text.UTF8Encoding($false)
        [Console]::InputEncoding = $utf8
        [Console]::OutputEncoding = $utf8
        $global:OutputEncoding = $utf8
    }
    catch { }
    try {
        $Host.UI.RawUI.WindowTitle = 'BOOSTER X - SECURE PERFORMANCE DEPLOYMENT'
        $Host.UI.RawUI.BackgroundColor = [ConsoleColor]::Black
        $Host.UI.RawUI.ForegroundColor = [ConsoleColor]::Gray
    }
    catch { }
    try { Clear-Host } catch { }

    $logo = @(
        ' ____   ___   ___  ____ _____ _____ ____     __  __',
        '| __ ) / _ \ / _ \/ ___|_   _| ____|  _ \    \ \/ /',
        '|  _ \| | | | | | \___ \ | | |  _| | |_) |    \  / ',
        '| |_) | |_| | |_| |___) || | | |___|  _ <     /  \ ',
        '|____/ \___/ \___/|____/ |_| |_____|_| \_\   /_/\_\'
    )
    $colors = @('Cyan','Cyan','Blue','Magenta','DarkMagenta')

    Write-Host ''
    Write-Host '  ==============================================================' -ForegroundColor Cyan
    for ($index = 0; $index -lt $logo.Count; $index++) {
        Write-Host ('  ' + $logo[$index]) -ForegroundColor $colors[$index]
    }
    Write-Host ''
    Write-Host '              SECURE GAMING PERFORMANCE DEPLOYMENT' -ForegroundColor White
    Write-Host '  ==============================================================' -ForegroundColor Cyan
    Write-Host ''
}

function Fail([string]$Code, [string]$Message) {
    throw "[$Code] $Message"
}

function Test-IsWindows {
    return ($env:OS -eq 'Windows_NT')
}

function Get-PropertyValue {
    param([object]$Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Get-NormalizedManifest {
    param([object]$RawManifest)
    $payload = Get-PropertyValue $RawManifest 'payload'
    if ($null -eq $payload) { $payload = $RawManifest }

    $version = [string](Get-PropertyValue $payload 'version')
    $downloadUrl = [string](Get-PropertyValue $payload 'downloadUrl')
    $sha256 = [string](Get-PropertyValue $payload 'sha256')
    $sizeValue = Get-PropertyValue $payload 'size'
    $publishedAt = [string](Get-PropertyValue $payload 'publishedAt')

    if ([string]::IsNullOrWhiteSpace($version)) { Fail 'BX-INS-010' 'Manifest ไม่มีหมายเลขเวอร์ชัน' }
    if ([string]::IsNullOrWhiteSpace($downloadUrl)) { Fail 'BX-INS-011' 'Manifest ไม่มีลิงก์ดาวน์โหลด กรุณาอัปเดต PRODUCT_CHANNEL.json ก่อนเผยแพร่' }
    if ($downloadUrl -notmatch '^https://') { Fail 'BX-INS-012' 'ลิงก์ดาวน์โหลดต้องใช้ HTTPS เท่านั้น' }
    if ($sha256 -notmatch '^[A-Fa-f0-9]{64}$') { Fail 'BX-INS-013' 'ค่า SHA-256 ใน Manifest ไม่ถูกต้อง' }

    $uri = [Uri]$downloadUrl
    $allowedHosts = @('github.com','objects.githubusercontent.com','release-assets.githubusercontent.com')
    if ($allowedHosts -notcontains $uri.DnsSafeHost.ToLowerInvariant()) {
        Fail 'BX-INS-014' ("โดเมนดาวน์โหลดไม่ได้รับอนุญาต: " + $uri.DnsSafeHost)
    }

    $size = 0L
    if ($null -ne $sizeValue -and -not [string]::IsNullOrWhiteSpace([string]$sizeValue)) {
        if (-not [Int64]::TryParse([string]$sizeValue, [ref]$size) -or $size -lt 1) {
            Fail 'BX-INS-015' 'ขนาดไฟล์ใน Manifest ไม่ถูกต้อง'
        }
    }

    [pscustomobject]@{
        Version = $version.Trim()
        DownloadUrl = $downloadUrl.Trim()
        Sha256 = $sha256.ToLowerInvariant()
        Size = $size
        PublishedAt = $publishedAt
    }
}

function Invoke-DownloadFile {
    param([string]$Url, [string]$Destination)
    $headers = @{
        'User-Agent' = 'BOOSTER-X-Installer/1.7.7'
        'Cache-Control' = 'no-cache'
        'Pragma' = 'no-cache'
    }
    $lastError = $null
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
            Write-Status " DOWNLOAD         //  PACKAGE ATTEMPT $attempt OF 3" Cyan
            Invoke-WebRequest -Uri $Url -Headers $headers -UseBasicParsing -OutFile $Destination -MaximumRedirection 8 -TimeoutSec 180
            if (-not (Test-Path -LiteralPath $Destination)) { throw 'ไม่พบไฟล์หลังดาวน์โหลด' }
            if ((Get-Item -LiteralPath $Destination).Length -lt 1024) { throw 'ไฟล์ที่ดาวน์โหลดมีขนาดเล็กผิดปกติ' }
            return
        }
        catch {
            $lastError = $_
            if ($attempt -lt 3) { Start-Sleep -Seconds (2 * $attempt) }
        }
    }
    Fail 'BX-INS-020' ("ดาวน์โหลดไม่สำเร็จ: " + $lastError.Exception.Message)
}

function Test-WebView2Runtime {
    $roots = @(
        (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\EdgeWebView\Application'),
        (Join-Path $env:ProgramFiles 'Microsoft\EdgeWebView\Application'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\EdgeWebView\Application')
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        if (Get-ChildItem -LiteralPath $root -Filter 'msedgewebview2.exe' -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1) {
            return $true
        }
    }
    return $false
}

function Ensure-WebView2Runtime {
    if (Test-WebView2Runtime) {
        Write-Status ' RUNTIME          //  WEBVIEW2 READY' Green
        return
    }

    $bootstrapper = Join-Path $WorkRoot 'MicrosoftEdgeWebview2Setup.exe'
    Write-Status ' RUNTIME          //  PREPARING WEBVIEW2' Cyan
    try {
        Invoke-WebRequest -Uri 'https://go.microsoft.com/fwlink/p/?LinkId=2124703' -UseBasicParsing -OutFile $bootstrapper -MaximumRedirection 8 -TimeoutSec 180
    }
    catch { Fail 'BX-INS-060' ('ดาวน์โหลด WebView2 Runtime ไม่สำเร็จ: ' + $_.Exception.Message) }

    if (-not (Test-Path -LiteralPath $bootstrapper) -or (Get-Item -LiteralPath $bootstrapper).Length -lt 100000) {
        Fail 'BX-INS-061' 'ไฟล์ติดตั้ง WebView2 Runtime มีขนาดไม่ถูกต้อง'
    }
    $signature = Get-AuthenticodeSignature -LiteralPath $bootstrapper
    if ($signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid -or
        $null -eq $signature.SignerCertificate -or
        $signature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') {
        Fail 'BX-INS-062' ('ลายเซ็นดิจิทัลของ WebView2 Runtime ไม่ผ่าน: ' + $signature.Status)
    }

    $process = Start-Process -FilePath $bootstrapper -ArgumentList @('/silent','/install') -Wait -PassThru
    if ($process.ExitCode -notin @(0, 3010)) { Fail 'BX-INS-063' ('ติดตั้ง WebView2 Runtime ไม่สำเร็จ รหัส: ' + $process.ExitCode) }
    Start-Sleep -Seconds 2
    if (-not (Test-WebView2Runtime)) { Fail 'BX-INS-064' 'ติดตั้ง WebView2 Runtime แล้ว แต่ยังตรวจไม่พบ Runtime' }
    Write-Status ' RUNTIME          //  WEBVIEW2 INSTALLED' Green
}

function Test-ZipEntryPath {
    param([string]$EntryName)
    if ([string]::IsNullOrWhiteSpace($EntryName)) { return }
    $name = $EntryName.Replace('/', '\')
    if ($name.StartsWith('\') -or $name.StartsWith('/') -or $name -match '^[A-Za-z]:') {
        Fail 'BX-INS-030' ("พบ Path แบบ Absolute ใน ZIP: " + $EntryName)
    }
    if ($name.IndexOf([char]0) -ge 0 -or $name.Contains(':')) {
        Fail 'BX-INS-031' ("พบชื่อไฟล์ที่ไม่ปลอดภัยใน ZIP: " + $EntryName)
    }
    $parts = @($name.Split('\') | Where-Object { $_ -ne '' })
    foreach ($part in $parts) {
        if ($part -eq '.' -or $part -eq '..') { Fail 'BX-INS-032' ("พบ Path Traversal ใน ZIP: " + $EntryName) }
        if ($part.EndsWith('.') -or $part.EndsWith(' ')) { Fail 'BX-INS-033' ("ชื่อไฟล์ลงท้ายด้วยจุดหรือช่องว่าง: " + $EntryName) }
        $stem = [IO.Path]::GetFileNameWithoutExtension($part).ToUpperInvariant()
        if ($stem -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$') {
            Fail 'BX-INS-034' ("พบชื่ออุปกรณ์ Windows ที่ไม่ปลอดภัย: " + $EntryName)
        }
    }
}

function Expand-SafeZip {
    param([string]$ZipPath, [string]$Destination)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    $rootFull = [IO.Path]::GetFullPath($Destination).TrimEnd('\') + '\'
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $archive = [IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        foreach ($entry in $archive.Entries) {
            Test-ZipEntryPath $entry.FullName
            if ([string]::IsNullOrWhiteSpace($entry.FullName)) { continue }
            $relative = $entry.FullName.Replace('/', '\')
            $target = [IO.Path]::GetFullPath((Join-Path $Destination $relative))
            if (-not $target.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) {
                Fail 'BX-INS-035' ("ZIP พยายามเขียนไฟล์ออกนอกพื้นที่ติดตั้ง: " + $entry.FullName)
            }
            if (-not $seen.Add($target)) { Fail 'BX-INS-036' ("พบ Path ซ้ำใน ZIP: " + $entry.FullName) }

            # Unix symbolic link marker in external attributes.
            $unixMode = (($entry.ExternalAttributes -shr 16) -band 0xF000)
            if ($unixMode -eq 0xA000) { Fail 'BX-INS-037' ("ไม่อนุญาต Symbolic Link ใน ZIP: " + $entry.FullName) }

            if ($entry.FullName.EndsWith('/') -or $entry.FullName.EndsWith('\')) {
                New-Item -ItemType Directory -Force -Path $target | Out-Null
                continue
            }
            $parent = Split-Path -Parent $target
            New-Item -ItemType Directory -Force -Path $parent | Out-Null
            $input = $entry.Open()
            try {
                $output = New-Object IO.FileStream($target, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
                try { $input.CopyTo($output) } finally { $output.Dispose() }
            }
            finally { $input.Dispose() }
        }
    }
    finally { $archive.Dispose() }
}

function Resolve-PackageRoot {
    param([string]$ExtractedRoot)
    if (Test-Path -LiteralPath (Join-Path $ExtractedRoot 'BOOSTER X.exe')) { return $ExtractedRoot }
    $dirs = @(Get-ChildItem -LiteralPath $ExtractedRoot -Directory -Force)
    $files = @(Get-ChildItem -LiteralPath $ExtractedRoot -File -Force)
    if ($dirs.Count -eq 1 -and $files.Count -eq 0 -and (Test-Path -LiteralPath (Join-Path $dirs[0].FullName 'BOOSTER X.exe'))) {
        return $dirs[0].FullName
    }
    Fail 'BX-INS-040' 'โครงสร้างแพ็กเกจไม่ถูกต้อง: ไม่พบ BOOSTER X.exe ที่ Root ของแพ็กเกจ'
}

function Test-PackageIntegrity {
    param([string]$PackageRoot)
    $manifestPath = Join-Path $PackageRoot 'PACKAGE_INTEGRITY.json'
    if (-not (Test-Path -LiteralPath $manifestPath)) { Fail 'BX-INS-041' 'ไม่พบ PACKAGE_INTEGRITY.json' }
    try { $integrity = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { Fail 'BX-INS-042' ("อ่าน PACKAGE_INTEGRITY.json ไม่สำเร็จ: " + $_.Exception.Message) }
    if ([string](Get-PropertyValue $integrity 'format') -ne 'BOOSTER-X-PACKAGE-1') { Fail 'BX-INS-043' 'รูปแบบ PACKAGE_INTEGRITY.json ไม่รองรับ' }
    $entries = @(Get-PropertyValue $integrity 'files')
    if ($entries.Count -lt 1) { Fail 'BX-INS-044' 'PACKAGE_INTEGRITY.json ไม่มีรายการไฟล์' }

    $rootFull = [IO.Path]::GetFullPath($PackageRoot).TrimEnd('\') + '\'
    $expected = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $entries) {
        $relative = [string](Get-PropertyValue $entry 'path')
        $expectedHash = [string](Get-PropertyValue $entry 'sha256')
        $expectedSizeValue = Get-PropertyValue $entry 'size'
        Test-ZipEntryPath $relative
        if ($expectedHash -notmatch '^[A-Fa-f0-9]{64}$') { Fail 'BX-INS-045' ("Hash ภายในแพ็กเกจไม่ถูกต้อง: " + $relative) }
        $full = [IO.Path]::GetFullPath((Join-Path $PackageRoot $relative.Replace('/', '\')))
        if (-not $full.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) { Fail 'BX-INS-046' ("Path ภายใน Manifest ไม่ปลอดภัย: " + $relative) }
        if (-not $expected.Add($full)) { Fail 'BX-INS-047' ("รายการไฟล์ซ้ำใน Manifest: " + $relative) }
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { Fail 'BX-INS-048' ("ไฟล์ในแพ็กเกจหาย: " + $relative) }
        $item = Get-Item -LiteralPath $full
        $expectedSize = [Int64]$expectedSizeValue
        if ($item.Length -ne $expectedSize) { Fail 'BX-INS-049' ("ขนาดไฟล์ไม่ตรง: " + $relative) }
        $actualHash = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actualHash -ne $expectedHash.ToLowerInvariant()) { Fail 'BX-INS-050' ("SHA-256 ภายในแพ็กเกจไม่ตรง: " + $relative) }
    }

    $actualFiles = @(Get-ChildItem -LiteralPath $PackageRoot -File -Recurse -Force | Where-Object { $_.FullName -ne $manifestPath })
    foreach ($file in $actualFiles) {
        if (-not $expected.Contains([IO.Path]::GetFullPath($file.FullName))) {
            Fail 'BX-INS-051' ("พบไฟล์ที่ไม่ได้อยู่ใน PACKAGE_INTEGRITY.json: " + $file.FullName.Substring($rootFull.Length))
        }
    }
    Write-Status " INTEGRITY        //  $($entries.Count) PACKAGE FILES VERIFIED" Green
}

function Stop-InstalledApplication {
    if (-not (Test-Path -LiteralPath $InstallRoot)) { return }
    $installPrefix = [IO.Path]::GetFullPath($InstallRoot).TrimEnd('\') + '\'
    try {
        $processes = @(Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object {
            $_.ExecutablePath -and ([IO.Path]::GetFullPath($_.ExecutablePath)).StartsWith($installPrefix, [StringComparison]::OrdinalIgnoreCase)
        })
        foreach ($process in $processes) {
            Write-Status (" PROCESS          //  CLOSING ACTIVE BUILD - PID " + $process.ProcessId) Yellow
            Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
        }
        if ($processes.Count -gt 0) { Start-Sleep -Milliseconds 800 }
    }
    catch {
        Write-Diagnostic ("Process inspection warning: " + $_.Exception.Message)
        Write-Status ' PROCESS          //  INSPECTION WARNING - CONTINUING SAFELY' Yellow
    }
}

function Remove-LegacyLaunchShortcuts {
    foreach ($shortcut in @($DesktopShortcut, $StartMenuShortcut)) {
        if (-not (Test-Path -LiteralPath $shortcut -PathType Leaf)) { continue }
        try {
            Remove-Item -LiteralPath $shortcut -Force -ErrorAction Stop
            Write-Diagnostic ('Removed legacy launch shortcut: ' + $shortcut)
        }
        catch {
            Write-Diagnostic ('Unable to remove legacy launch shortcut: ' + $shortcut + ' // ' + $_.Exception.Message)
            Write-Status ' ACCESS POLICY    //  LEGACY SHORTCUT CLEANUP WARNING' Yellow
        }
    }
}

function Write-UninstallScript {
    $content = @'
#requires -Version 5.1
[CmdletBinding()]
param([switch]$RemoveUserData, [switch]$Silent)
$ErrorActionPreference = 'Stop'
$product = 'BOOSTER X'
$installRoot = Join-Path $env:LOCALAPPDATA 'Programs\BOOSTER X'
$dataRoot = Join-Path $env:LOCALAPPDATA 'BOOSTER X'
$desktop = Join-Path ([Environment]::GetFolderPath('Desktop')) 'BOOSTER X.lnk'
$startMenuRoot = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\BOOSTER X'
$uninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\BOOSTER X'
if (-not $Silent) {
    $answer = Read-Host 'Uninstall BOOSTER X? Type Y to confirm'
    if ($answer -notmatch '^(Y|YES)$') { Write-Host 'Uninstall cancelled'; exit 0 }
}
$exe = Join-Path $installRoot 'BOOSTER X.exe'
if (Test-Path -LiteralPath $exe -PathType Leaf) {
    if (-not $Silent) { Write-Host 'Restoring BOOSTER X session settings before uninstall...' -ForegroundColor Cyan }
    $recovery = Start-Process -FilePath $exe -WorkingDirectory $installRoot -ArgumentList '--restore-and-exit' -Wait -PassThru
    if ($recovery.ExitCode -ne 0) {
        throw "BOOSTER X recovery failed with exit code $($recovery.ExitCode). Uninstall stopped to preserve system state."
    }
}
elseif (Test-Path -LiteralPath (Join-Path $dataRoot 'pending-transaction.json')) {
    throw 'BOOSTER X.exe is missing while a recovery transaction is pending. Run the install command once to repair before uninstalling.'
}
try {
    $prefix = [IO.Path]::GetFullPath($installRoot).TrimEnd('\') + '\'
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        $_.ExecutablePath -and ([IO.Path]::GetFullPath($_.ExecutablePath)).StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
    } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
} catch {}
Remove-Item -LiteralPath $desktop -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $startMenuRoot -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $uninstallKey -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $installRoot -Recurse -Force -ErrorAction SilentlyContinue
if ($RemoveUserData) { Remove-Item -LiteralPath $dataRoot -Recurse -Force -ErrorAction SilentlyContinue }
if (-not $Silent) {
    Write-Host 'BOOSTER X was uninstalled successfully' -ForegroundColor Green
    if (-not $RemoveUserData) { Write-Host 'Settings, snapshots, recovery data and logs were preserved' -ForegroundColor Yellow }
}
'@
    [IO.File]::WriteAllText($UninstallScript, $content, (New-Object Text.UTF8Encoding($true)))
}

function Register-Uninstall {
    param([string]$Version)
    New-Item -Path $UninstallKey -Force | Out-Null
    $uninstallCommand = 'powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + $UninstallScript + '"'
    New-ItemProperty -Path $UninstallKey -Name DisplayName -Value 'BOOSTER X' -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $UninstallKey -Name DisplayVersion -Value $Version -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $UninstallKey -Name Publisher -Value 'BOOSTER X' -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $UninstallKey -Name InstallLocation -Value $InstallRoot -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $UninstallKey -Name DisplayIcon -Value (Join-Path $InstallRoot 'BOOSTER X.exe') -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $UninstallKey -Name UninstallString -Value $uninstallCommand -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $UninstallKey -Name QuietUninstallString -Value ($uninstallCommand + ' -Silent') -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $UninstallKey -Name NoModify -Value 1 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path $UninstallKey -Name NoRepair -Value 1 -PropertyType DWord -Force | Out-Null
}

function Get-InstalledVersion {
    try { return [string](Get-ItemPropertyValue -Path $UninstallKey -Name DisplayVersion -ErrorAction Stop) } catch { return '' }
}

function Test-InstalledPackageHealthy {
    foreach ($required in @('BOOSTER X.exe','BOOSTER X Updater.exe','Launch-BOOSTER-X.ps1','PACKAGE_INTEGRITY.json')) {
        if (-not (Test-Path -LiteralPath (Join-Path $InstallRoot $required))) {
            Write-Status (" REPAIR           //  MISSING " + $required) Yellow
            return $false
        }
    }
    try {
        Test-PackageIntegrity $InstallRoot
        return $true
    }
    catch {
        Write-Diagnostic ("Repair required: " + $_.Exception.Message)
        Write-Status ' REPAIR           //  PACKAGE INTEGRITY REFRESH REQUIRED' Yellow
        return $false
    }
}

function Test-BoosterProcessRunning {
    $installPrefix = [IO.Path]::GetFullPath($InstallRoot).TrimEnd('\') + '\'
    try {
        $match = Get-CimInstance Win32_Process -Filter "Name='BOOSTER X.exe'" -ErrorAction Stop | Where-Object {
            $_.ExecutablePath -and ([IO.Path]::GetFullPath($_.ExecutablePath)).StartsWith($installPrefix, [StringComparison]::OrdinalIgnoreCase)
        } | Select-Object -First 1
        if ($null -ne $match) { return $true }
    }
    catch { }
    return (@(Get-Process -Name 'BOOSTER X' -ErrorAction SilentlyContinue).Count -gt 0)
}

function Write-LaunchFailure {
    param([string]$Message)
    $lines = @(
        'BOOSTER X LAUNCH FAILURE',
        ('Time: ' + (Get-Date).ToString('O')),
        ('InstallRoot: ' + $InstallRoot),
        ('Message: ' + $Message),
        ('StartupLog: ' + (Join-Path $LogRoot 'startup-latest.log')),
        ('LauncherLog: ' + (Join-Path $LogRoot 'launcher-startup-error.log')),
        ('RecoveryLog: ' + (Join-Path $DataRoot 'recovery.log')),
        ('WebViewLog: ' + (Join-Path $DataRoot 'webview-init-error.log'))
    )
    [IO.File]::WriteAllLines($LaunchFailureLog, $lines, (New-Object Text.UTF8Encoding($true)))
}

function Start-BoosterAndVerify {
    $launcher = Join-Path $InstallRoot 'Launch-BOOSTER-X.ps1'
    if (-not (Test-Path -LiteralPath $launcher)) { Fail 'BX-LAUNCH-001' 'ไม่พบ Launcher หลังติดตั้ง ระบบจะซ่อมแซมในการเรียกครั้งถัดไป' }

    if (Test-BoosterProcessRunning) {
        Write-Status ' LAUNCH           //  ACTIVE INSTANCE DETECTED' Cyan
    }
    else {
        Write-Status ' LAUNCH           //  STARTING BOOSTER X' Cyan
    }

    $powerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $readyFile = Join-Path $LogRoot ('startup-ready-installer-' + [Guid]::NewGuid().ToString('N') + '.json')
    Remove-Item -LiteralPath $readyFile -Force -ErrorAction SilentlyContinue
    $arguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + $launcher + '" -Silent -ReadyFile "' + $readyFile + '" -StartupTimeoutSeconds 45'
    try {
        $launcherProcess = Start-Process -FilePath $powerShell -ArgumentList $arguments -WorkingDirectory $InstallRoot -Wait -PassThru
    }
    catch {
        Write-LaunchFailure $_.Exception.Message
        Fail 'BX-LAUNCH-002' ("Launcher เริ่มทำงานไม่สำเร็จ: " + $_.Exception.Message + "`nLog: " + $LaunchFailureLog)
    }
    if ($launcherProcess.ExitCode -ne 0) {
        $startupLog = Join-Path $LogRoot 'startup-latest.log'
        $message = 'Launcher ส่งรหัสผิดพลาด ' + $launcherProcess.ExitCode + '. Startup log: ' + $startupLog
        Write-LaunchFailure $message
        Fail 'BX-LAUNCH-003' ($message + "`nLog: " + $LaunchFailureLog)
    }

    if (Test-Path -LiteralPath $readyFile -PathType Leaf) {
        try {
            $ready = Get-Content -LiteralPath $readyFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if ([string]$ready.status -eq 'READY') {
                Remove-Item -LiteralPath $readyFile -Force -ErrorAction SilentlyContinue
                Remove-Item -LiteralPath $LaunchFailureLog -Force -ErrorAction SilentlyContinue
                Write-Status (" LAUNCH           //  UI READY - PID " + $ready.processId) Green
                return
            }
        }
        catch {
            Write-Diagnostic ("UI ready handshake warning: " + $_.Exception.Message)
            Write-Status ' LAUNCH           //  UI HANDSHAKE WARNING' Yellow
        }
    }

    $message = 'โปรแกรมไม่ส่งสัญญาณ UI_READY กรุณาดู startup-latest.log และ launcher-startup-error.log'
    Write-LaunchFailure $message
    Fail 'BX-LAUNCH-004' ($message + "`nLog: " + $LaunchFailureLog)
}

try {
    if (-not (Test-IsWindows)) { Fail 'BX-INS-001' 'ตัวติดตั้งรองรับ Windows เท่านั้น' }
    if ([Environment]::Is64BitOperatingSystem -eq $false) { Fail 'BX-INS-002' 'BOOSTER X รองรับ Windows 64-bit เท่านั้น' }

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    New-Item -ItemType Directory -Force -Path $LogRoot | Out-Null
    $LogPath = Join-Path $LogRoot ('install-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')
    [IO.File]::WriteAllText($LogPath, "BOOSTER X INSTALL LOG`r`n", (New-Object Text.UTF8Encoding($true)))

    Initialize-InstallerConsole
    Write-Diagnostic ('Manifest: ' + $ManifestUrl)
    Write-Diagnostic ('Install root: ' + $InstallRoot)

    if ($ManifestUrl -notmatch '^https://') { Fail 'BX-INS-003' 'Manifest URL ต้องใช้ HTTPS เท่านั้น' }
    $manifestHost = ([Uri]$ManifestUrl).DnsSafeHost.ToLowerInvariant()
    if ($manifestHost -ne 'raw.githubusercontent.com') { Fail 'BX-INS-004' 'Manifest ต้องมาจาก raw.githubusercontent.com เท่านั้น' }

    $manifestRequestUrl = $ManifestUrl + $(if ($ManifestUrl.Contains('?')) { '&' } else { '?' }) + 't=' + [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    Write-Status ' CHANNEL          //  CHECKING LATEST RELEASE' Cyan
    try {
        $rawManifest = Invoke-RestMethod -Uri $manifestRequestUrl -UseBasicParsing -Headers @{'User-Agent'='BOOSTER-X-Installer/1.7.7';'Cache-Control'='no-cache'} -TimeoutSec 30
    }
    catch {
        $manifestError = $_.Exception.Message
        $offlinePackageHealthy = (Test-Path -LiteralPath $InstallRoot) -and (Test-InstalledPackageHealthy)
        if ($offlinePackageHealthy) {
            Write-Diagnostic ('Release channel offline: ' + $manifestError)
            Write-Status ' CHANNEL          //  OFFLINE - USING VERIFIED LOCAL BUILD' Yellow
            if (-not $NoLaunch) { Start-BoosterAndVerify }
            return
        }
        Fail 'BX-INS-005' ("ดาวน์โหลด Manifest ไม่สำเร็จและไม่พบโปรแกรมที่สมบูรณ์สำหรับเปิดแบบ Offline: " + $manifestError)
    }
    $manifest = Get-NormalizedManifest $rawManifest
    $installedVersion = Get-InstalledVersion
    Remove-LegacyLaunchShortcuts

    Write-Status (" RELEASE CHANNEL  //  V" + $manifest.Version) White
    if (-not [string]::IsNullOrWhiteSpace($installedVersion)) { Write-Status (" LOCAL BUILD      //  V" + $installedVersion) DarkGray }

    $sameVersion = -not [string]::IsNullOrWhiteSpace($installedVersion) -and $installedVersion.Trim() -eq $manifest.Version
    $installedPackageHealthy = (Test-Path -LiteralPath $InstallRoot) -and (Test-InstalledPackageHealthy)
    if (-not $Force -and $sameVersion -and $installedPackageHealthy) {
        Write-Status ' STATUS           //  READY - INTEGRITY VERIFIED' Green
        Write-Diagnostic ('Verified install root: ' + $InstallRoot)
        if (-not $NoLaunch) { Start-BoosterAndVerify }
        return
    }

    if (Test-Path -LiteralPath $InstallRoot) {
        Write-Status ' MODE             //  SMART UPDATE OR REPAIR' Yellow
    }
    else {
        Write-Status ' MODE             //  CLEAN DEPLOYMENT' Cyan
    }

    New-Item -ItemType Directory -Force -Path $WorkRoot | Out-Null
    Ensure-WebView2Runtime
    Invoke-DownloadFile -Url $manifest.DownloadUrl -Destination $DownloadPartial
    $downloadLength = (Get-Item -LiteralPath $DownloadPartial).Length
    if ($manifest.Size -gt 0 -and $downloadLength -ne $manifest.Size) {
        Fail 'BX-INS-021' ("ขนาดไฟล์ไม่ตรงกับ Manifest: ได้ $downloadLength bytes, ควรเป็น $($manifest.Size) bytes")
    }
    if ($downloadLength -gt 1GB) { Fail 'BX-INS-022' 'ไฟล์ดาวน์โหลดมีขนาดเกินขีดจำกัด 1 GB' }
    Write-Status ' SECURITY         //  VERIFYING PACKAGE SHA-256' Cyan
    $actualHash = (Get-FileHash -LiteralPath $DownloadPartial -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -ne $manifest.Sha256) { Fail 'BX-INS-023' ("SHA-256 ไม่ตรง ไฟล์จะไม่ถูกติดตั้ง`nExpected: $($manifest.Sha256)`nActual:   $actualHash") }
    Move-Item -LiteralPath $DownloadPartial -Destination $DownloadZip -Force
    Write-Status ' SECURITY         //  SHA-256 VERIFIED' Green

    Write-Status ' DEPLOYMENT       //  VALIDATING AND EXTRACTING PACKAGE' Cyan
    Expand-SafeZip -ZipPath $DownloadZip -Destination $ExtractRoot
    $packageRoot = Resolve-PackageRoot $ExtractRoot
    Test-PackageIntegrity $packageRoot

    foreach ($required in @('BOOSTER X.exe','BOOSTER X Updater.exe','Launch-BOOSTER-X.ps1','PACKAGE_INTEGRITY.json')) {
        if (-not (Test-Path -LiteralPath (Join-Path $packageRoot $required))) { Fail 'BX-INS-052' ("แพ็กเกจขาดไฟล์สำคัญ: " + $required) }
    }

    Stop-InstalledApplication
    Remove-Item -LiteralPath $IncomingRoot -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path $IncomingRoot | Out-Null
    Get-ChildItem -LiteralPath $packageRoot -Force | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $IncomingRoot -Recurse -Force }
    Test-PackageIntegrity $IncomingRoot

    if (Test-Path -LiteralPath $InstallRoot) {
        Remove-Item -LiteralPath $BackupRoot -Recurse -Force -ErrorAction SilentlyContinue
        Move-Item -LiteralPath $InstallRoot -Destination $BackupRoot
        $BackupCreated = $true
    }
    Move-Item -LiteralPath $IncomingRoot -Destination $InstallRoot
    $InstallCommitted = $true
    Test-PackageIntegrity $InstallRoot

    Remove-LegacyLaunchShortcuts
    Write-Status ' ACCESS POLICY    //  POWERSHELL-ONLY LAUNCH' Cyan
    Write-UninstallScript
    Register-Uninstall $manifest.Version

    Write-Status ' STATUS           //  DEPLOYMENT VERIFIED' Green
    Write-Status (" ACTIVE BUILD     //  V" + $manifest.Version) White
    Write-Diagnostic ('Installed to: ' + $InstallRoot)
    Write-Diagnostic ('Install log: ' + $LogPath)

    if (-not $NoLaunch) {
        $preserveInstalledFiles = -not $installedPackageHealthy
        try { Start-BoosterAndVerify }
        catch {
            if ($preserveInstalledFiles) {
                $InstallCommitted = $false
                if ($BackupCreated -and (Test-Path -LiteralPath $BackupRoot)) {
                    Remove-Item -LiteralPath $BackupRoot -Recurse -Force -ErrorAction SilentlyContinue
                    $BackupCreated = $false
                }
                $PreserveCommittedInstall = $true
                Write-Status ' RECOVERY         //  VERIFIED BUILD PRESERVED FOR SELF-REPAIR' Yellow
            }
            throw
        }
    }
    if ($BackupCreated) { Remove-Item -LiteralPath $BackupRoot -Recurse -Force -ErrorAction SilentlyContinue }
    $BackupCreated = $false
    $InstallCommitted = $false
    Write-Status ' BOOSTER X        //  READY TO LAUNCH' Green
}
catch {
    $message = $_.Exception.Message
    try { Write-Diagnostic ('Installer failure: ' + $message) } catch { }
    try { Write-Status ' ERROR            //  OPERATION FAILED - SEE DIAGNOSTIC LOG' Red } catch { Write-Host ' ERROR            //  OPERATION FAILED - SEE DIAGNOSTIC LOG' -ForegroundColor Red }
    try {
        if (-not $PreserveCommittedInstall -and $InstallCommitted -and (Test-Path -LiteralPath $InstallRoot)) { Remove-Item -LiteralPath $InstallRoot -Recurse -Force -ErrorAction SilentlyContinue }
        if ($BackupCreated -and (Test-Path -LiteralPath $BackupRoot)) {
            Move-Item -LiteralPath $BackupRoot -Destination $InstallRoot -Force
            Write-Status ' RECOVERY         //  PREVIOUS BUILD RESTORED' Yellow
        }
    }
    catch {
        try { Write-Diagnostic ('Rollback failure: ' + $_.Exception.Message) } catch { }
        Write-Host ' RECOVERY         //  ROLLBACK WARNING - SEE DIAGNOSTIC LOG' -ForegroundColor Red
    }
    if (-not $Silent) {
        Write-Host ' SAFETY           //  EXISTING BUILD AND USER DATA PRESERVED' -ForegroundColor Yellow
        Write-Host ' SUPPORT          //  DIAGNOSTIC LOG CREATED' -ForegroundColor DarkGray
    }
    exit 1
}
finally {
    Remove-Item -LiteralPath $WorkRoot -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $IncomingRoot -Recurse -Force -ErrorAction SilentlyContinue
}
