# BOOSTER X bootstrap is intentionally UTF-8 without BOM and has no param/CmdletBinding block so it can be
# executed reliably through both `irm | iex` and a downloaded .ps1 file.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$bxUrl = 'https://raw.githubusercontent.com/siwaphong76-gif/BOOSTER-X-Releases/main/install-core.ps1'
$bxBootstrapRoot = Join-Path $env:LOCALAPPDATA 'BOOSTER X\Bootstrap'
$bxScriptPath = Join-Path $bxBootstrapRoot 'install-core.ps1'
$bxTempPath = $bxScriptPath + '.download'

try {
    New-Item -ItemType Directory -Path $bxBootstrapRoot -Force | Out-Null
    Remove-Item -LiteralPath $bxTempPath -Force -ErrorAction SilentlyContinue

    $bxHeaders = @{
        'User-Agent' = 'BOOSTER-X-Bootstrap/1.7.0'
        'Cache-Control' = 'no-cache'
        'Pragma' = 'no-cache'
    }
    $bxRequestUrl = $bxUrl + '?t=' + [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    Invoke-WebRequest -UseBasicParsing -Uri $bxRequestUrl -Headers $bxHeaders -OutFile $bxTempPath -TimeoutSec 60 -MaximumRedirection 5

    if (-not (Test-Path -LiteralPath $bxTempPath -PathType Leaf)) {
        throw 'Installer download failed: the downloaded file was not found.'
    }
    $bxInfo = Get-Item -LiteralPath $bxTempPath
    if ($bxInfo.Length -lt 4096 -or $bxInfo.Length -gt 2MB) {
        throw "Installer download size is invalid: $($bxInfo.Length) bytes"
    }
    $bxFirstLine = Get-Content -LiteralPath $bxTempPath -TotalCount 1 -Encoding UTF8
    if ($bxFirstLine -notmatch '^#requires\s+-Version\s+5\.1') {
        throw 'The downloaded content is not a valid BOOSTER X installer core.'
    }

    Move-Item -LiteralPath $bxTempPath -Destination $bxScriptPath -Force
}
catch {
    # A previously downloaded core remains useful when GitHub is temporarily
    # unavailable. The core itself will only open an already verified install.
    if (-not (Test-Path -LiteralPath $bxScriptPath -PathType Leaf)) { throw }
    Write-Warning ('Unable to download the latest installer. Using the cached bootstrap core: ' + $_.Exception.Message)
}

$bxPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$bxProcess = Start-Process -FilePath $bxPowerShell -ArgumentList @(
    '-NoLogo',
    '-NoProfile',
    '-ExecutionPolicy', 'Bypass',
    '-File', ('"' + $bxScriptPath + '"')
) -Wait -PassThru

if ($bxProcess.ExitCode -ne 0) {
    throw "BOOSTER X Installer exited with code $($bxProcess.ExitCode)"
}
