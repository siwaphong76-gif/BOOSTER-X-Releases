#requires -Version 5.1
<#
.SYNOPSIS
    ตัวติดตั้ง BOOSTER X แบบคำสั่งเดียวผ่าน PowerShell
.DESCRIPTION
    ดาวน์โหลด Release ตาม PRODUCT_CHANNEL.json ตรวจ SHA-256 ตรวจ PACKAGE_INTEGRITY.json
    ติดตั้งแบบสลับโฟลเดอร์พร้อม Rollback สร้าง Shortcut และรายการถอนการติดตั้ง
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

function Write-Status {
    param([string]$Message, [ConsoleColor]$Color = [ConsoleColor]::Gray)
    if (-not $Silent) { Write-Host $Message -ForegroundColor $Color }
    if ($LogPath) {
        Add-Content -LiteralPath $LogPath -Value ((Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + '  ' + $Message) -Encoding UTF8
    }
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
        'User-Agent' = 'BOOSTER-X-Installer/1.5'
        'Cache-Control' = 'no-cache'
        'Pragma' = 'no-cache'
    }
    $lastError = $null
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
            Write-Status "กำลังดาวน์โหลดไฟล์โปรแกรม (ครั้งที่ $attempt/3)..." Cyan
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
        Write-Status 'Microsoft Edge WebView2 Runtime พร้อมใช้งาน' Green
        return
    }

    $bootstrapper = Join-Path $WorkRoot 'MicrosoftEdgeWebview2Setup.exe'
    Write-Status 'กำลังเตรียม Microsoft Edge WebView2 Runtime...' Cyan
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
    Write-Status 'ติดตั้ง Microsoft Edge WebView2 Runtime สำเร็จ' Green
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
    Write-Status "ตรวจสอบไฟล์ภายในแพ็กเกจครบ $($entries.Count) รายการแล้ว" Green
}

function Stop-InstalledApplication {
    if (-not (Test-Path -LiteralPath $InstallRoot)) { return }
    $installPrefix = [IO.Path]::GetFullPath($InstallRoot).TrimEnd('\') + '\'
    try {
        $processes = @(Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object {
            $_.ExecutablePath -and ([IO.Path]::GetFullPath($_.ExecutablePath)).StartsWith($installPrefix, [StringComparison]::OrdinalIgnoreCase)
        })
        foreach ($process in $processes) {
            Write-Status ("กำลังปิดโปรแกรมเดิม: PID " + $process.ProcessId) Yellow
            Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
        }
        if ($processes.Count -gt 0) { Start-Sleep -Milliseconds 800 }
    }
    catch {
        Write-Status ("คำเตือน: ตรวจโปรเซสเดิมไม่สำเร็จ — " + $_.Exception.Message) Yellow
    }
}

function New-BoosterShortcut {
    param([string]$ShortcutPath)
    $launcher = Join-Path $InstallRoot 'Launch-BOOSTER-X.ps1'
    if (-not (Test-Path -LiteralPath $launcher)) { Fail 'BX-INS-060' 'ไม่พบ Launch-BOOSTER-X.ps1 หลังติดตั้ง' }
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($ShortcutPath)
    $shortcut.TargetPath = (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')
    $shortcut.Arguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + $launcher + '"'
    $shortcut.WorkingDirectory = $InstallRoot
    $exe = Join-Path $InstallRoot 'BOOSTER X.exe'
    if (Test-Path -LiteralPath $exe) { $shortcut.IconLocation = '"' + $exe + '",0' }
    $shortcut.Description = 'เปิด BOOSTER X'
    $shortcut.Save()
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
    $answer = Read-Host 'ถอนการติดตั้ง BOOSTER X หรือไม่? พิมพ์ Y เพื่อยืนยัน'
    if ($answer -notmatch '^(Y|YES|ย)$') { Write-Host 'ยกเลิกการถอนการติดตั้ง'; exit 0 }
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
    Write-Host 'ถอนการติดตั้ง BOOSTER X สำเร็จ' -ForegroundColor Green
    if (-not $RemoveUserData) { Write-Host "เก็บ Settings, Snapshots, Recovery และ Logs ไว้ที่: $dataRoot" -ForegroundColor Yellow }
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
            Write-Status ("ต้องซ่อมแซม: ไม่พบ " + $required) Yellow
            return $false
        }
    }
    try {
        Test-PackageIntegrity $InstallRoot
        return $true
    }
    catch {
        Write-Status ("ต้องซ่อมแซม: " + $_.Exception.Message) Yellow
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
        ('RecoveryLog: ' + (Join-Path $DataRoot 'recovery.log')),
        ('WebViewLog: ' + (Join-Path $DataRoot 'webview-init-error.log'))
    )
    [IO.File]::WriteAllLines($LaunchFailureLog, $lines, (New-Object Text.UTF8Encoding($true)))
}

function Start-BoosterAndVerify {
    $launcher = Join-Path $InstallRoot 'Launch-BOOSTER-X.ps1'
    if (-not (Test-Path -LiteralPath $launcher)) { Fail 'BX-LAUNCH-001' 'ไม่พบ Launcher หลังติดตั้ง ระบบจะซ่อมแซมในการเรียกครั้งถัดไป' }

    if (Test-BoosterProcessRunning) {
        Write-Status 'BOOSTER X ทำงานอยู่แล้ว กำลังเรียกหน้าต่างกลับมา...' Cyan
    }
    else {
        Write-Status 'กำลังเปิด BOOSTER X...' Cyan
    }

    $powerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + $launcher + '"'
    try {
        $launcherProcess = Start-Process -FilePath $powerShell -ArgumentList $arguments -WorkingDirectory $InstallRoot -Wait -PassThru
    }
    catch {
        Write-LaunchFailure $_.Exception.Message
        Fail 'BX-LAUNCH-002' ("Launcher เริ่มทำงานไม่สำเร็จ: " + $_.Exception.Message + "`nLog: " + $LaunchFailureLog)
    }
    if ($launcherProcess.ExitCode -ne 0) {
        $message = 'Launcher ส่งรหัสผิดพลาด ' + $launcherProcess.ExitCode
        Write-LaunchFailure $message
        Fail 'BX-LAUNCH-003' ($message + "`nLog: " + $LaunchFailureLog)
    }

    for ($attempt = 1; $attempt -le 12; $attempt++) {
        Start-Sleep -Seconds 1
        if (Test-BoosterProcessRunning) {
            Remove-Item -LiteralPath $LaunchFailureLog -Force -ErrorAction SilentlyContinue
            Write-Status 'เปิด BOOSTER X สำเร็จ' Green
            return
        }
    }

    $message = 'โปรแกรมเริ่มทำงานแล้วปิดตัวก่อนแสดงหน้าต่าง กรุณาดู Recovery/WebView log ที่ระบุไว้'
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

    Write-Status '============================================================' Cyan
    Write-Status ' ตัวติดตั้ง BOOSTER X' White
    Write-Status '============================================================' Cyan
    Write-Status ('Manifest: ' + $ManifestUrl) DarkGray

    if ($ManifestUrl -notmatch '^https://') { Fail 'BX-INS-003' 'Manifest URL ต้องใช้ HTTPS เท่านั้น' }
    $manifestHost = ([Uri]$ManifestUrl).DnsSafeHost.ToLowerInvariant()
    if ($manifestHost -ne 'raw.githubusercontent.com') { Fail 'BX-INS-004' 'Manifest ต้องมาจาก raw.githubusercontent.com เท่านั้น' }

    $manifestRequestUrl = $ManifestUrl + $(if ($ManifestUrl.Contains('?')) { '&' } else { '?' }) + 't=' + [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    Write-Status 'กำลังตรวจสอบเวอร์ชันล่าสุด...' Cyan
    try {
        $rawManifest = Invoke-RestMethod -Uri $manifestRequestUrl -UseBasicParsing -Headers @{'User-Agent'='BOOSTER-X-Installer/1.5';'Cache-Control'='no-cache'} -TimeoutSec 30
    }
    catch { Fail 'BX-INS-005' ("ดาวน์โหลด Manifest ไม่สำเร็จ: " + $_.Exception.Message) }
    $manifest = Get-NormalizedManifest $rawManifest
    $installedVersion = Get-InstalledVersion

    Write-Status ("เวอร์ชันที่จะติดตั้ง: " + $manifest.Version) White
    if (-not [string]::IsNullOrWhiteSpace($installedVersion)) { Write-Status ("เวอร์ชันที่ติดตั้งอยู่: " + $installedVersion) Yellow }

    $sameVersion = -not [string]::IsNullOrWhiteSpace($installedVersion) -and $installedVersion.Trim() -eq $manifest.Version
    if (-not $Force -and $sameVersion -and (Test-InstalledPackageHealthy)) {
        Write-Status 'โปรแกรมเป็นเวอร์ชันล่าสุดและไฟล์ครบ ไม่ต้องดาวน์โหลดใหม่' Green
        Write-Status ('ตำแหน่ง: ' + $InstallRoot) DarkGray
        if (-not $NoLaunch) { Start-BoosterAndVerify }
        return
    }

    if (Test-Path -LiteralPath $InstallRoot) {
        Write-Status 'พบโปรแกรมเดิมที่ต้องอัปเดตหรือซ่อมแซม ระบบจะดำเนินการอัตโนมัติ' Yellow
    }
    else {
        Write-Status 'ยังไม่พบโปรแกรม ระบบจะติดตั้งให้อัตโนมัติ' Cyan
    }

    New-Item -ItemType Directory -Force -Path $WorkRoot | Out-Null
    Ensure-WebView2Runtime
    Invoke-DownloadFile -Url $manifest.DownloadUrl -Destination $DownloadPartial
    $downloadLength = (Get-Item -LiteralPath $DownloadPartial).Length
    if ($manifest.Size -gt 0 -and $downloadLength -ne $manifest.Size) {
        Fail 'BX-INS-021' ("ขนาดไฟล์ไม่ตรงกับ Manifest: ได้ $downloadLength bytes, ควรเป็น $($manifest.Size) bytes")
    }
    if ($downloadLength -gt 1GB) { Fail 'BX-INS-022' 'ไฟล์ดาวน์โหลดมีขนาดเกินขีดจำกัด 1 GB' }
    Write-Status 'กำลังตรวจสอบ SHA-256 ของไฟล์ดาวน์โหลด...' Cyan
    $actualHash = (Get-FileHash -LiteralPath $DownloadPartial -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -ne $manifest.Sha256) { Fail 'BX-INS-023' ("SHA-256 ไม่ตรง ไฟล์จะไม่ถูกติดตั้ง`nExpected: $($manifest.Sha256)`nActual:   $actualHash") }
    Move-Item -LiteralPath $DownloadPartial -Destination $DownloadZip -Force
    Write-Status 'SHA-256 ถูกต้อง' Green

    Write-Status 'กำลังตรวจสอบและแตกไฟล์อย่างปลอดภัย...' Cyan
    Expand-SafeZip -ZipPath $DownloadZip -Destination $ExtractRoot
    $packageRoot = Resolve-PackageRoot $ExtractRoot
    Test-PackageIntegrity $packageRoot

    foreach ($required in @('BOOSTER X.exe','BOOSTER X Updater.exe','Launch-BOOSTER-X.ps1','RUN BOOSTER X.cmd','PACKAGE_INTEGRITY.json')) {
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

    New-Item -ItemType Directory -Force -Path $StartMenuRoot | Out-Null
    New-BoosterShortcut $DesktopShortcut
    New-BoosterShortcut $StartMenuShortcut
    Write-UninstallScript
    Register-Uninstall $manifest.Version

    Write-Status 'ติดตั้งและตรวจสอบไฟล์ BOOSTER X สำเร็จ' Green
    Write-Status ('เวอร์ชัน: ' + $manifest.Version) White
    Write-Status ('ตำแหน่ง: ' + $InstallRoot) DarkGray
    Write-Status ('บันทึกการติดตั้ง: ' + $LogPath) DarkGray

    if (-not $NoLaunch) {
        $preserveInstalledFiles = -not $BackupCreated
        try { Start-BoosterAndVerify }
        catch {
            if ($preserveInstalledFiles) { $InstallCommitted = $false }
            throw
        }
    }
    if ($BackupCreated) { Remove-Item -LiteralPath $BackupRoot -Recurse -Force -ErrorAction SilentlyContinue }
    $BackupCreated = $false
    $InstallCommitted = $false
    Write-Status 'BOOSTER X พร้อมใช้งาน' Green
}
catch {
    $message = $_.Exception.Message
    try { Write-Status ('ติดตั้ง/เปิดโปรแกรมไม่สำเร็จ: ' + $message) Red } catch { Write-Host ('ติดตั้ง/เปิดโปรแกรมไม่สำเร็จ: ' + $message) -ForegroundColor Red }
    try {
        if ($InstallCommitted -and (Test-Path -LiteralPath $InstallRoot)) { Remove-Item -LiteralPath $InstallRoot -Recurse -Force -ErrorAction SilentlyContinue }
        if ($BackupCreated -and (Test-Path -LiteralPath $BackupRoot)) {
            Move-Item -LiteralPath $BackupRoot -Destination $InstallRoot -Force
            Write-Status 'คืนโปรแกรมเวอร์ชันเดิมสำเร็จ' Yellow
        }
    }
    catch { Write-Host ('คำเตือน: คืนโปรแกรมเดิมไม่สำเร็จ — ' + $_.Exception.Message) -ForegroundColor Red }
    if (-not $Silent) {
        Write-Host 'โปรแกรมเดิมและข้อมูลผู้ใช้จะไม่ถูกลบโดยตั้งใจ' -ForegroundColor Yellow
        Write-Host ('ดูรายละเอียดที่: ' + $LogPath) -ForegroundColor DarkGray
    }
    exit 1
}
finally {
    Remove-Item -LiteralPath $WorkRoot -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $IncomingRoot -Recurse -Force -ErrorAction SilentlyContinue
}
