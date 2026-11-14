<#
.SYNOPSIS
  Diagnose the Epic download path: CDN reachability, install rate, EOS state.

.DESCRIPTION
  Read-only. Runs four checks and prints a short verdict:
    1. Epic CDN reachability and handshake time
    2. Unreal Engine install directory growth rate (optional)
    3. whether Epic Online Services is listening
    4. the last relevant lines from the launcher log

.PARAMETER InstallDir
  Unreal Engine install directory, e.g. "E:\UE\Install\UE_5.8".

.PARAMETER Seconds
  How long to sample the install directory. Default 30.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\scripts\check-epic-cdn.ps1

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\scripts\check-epic-cdn.ps1 -InstallDir "E:\UE\Install\UE_5.8" -Seconds 60
#>
[CmdletBinding()]
param(
    [string]$InstallDir = "",
    [int]$Seconds = 30
)

$ErrorActionPreference = "Continue"

function Write-Step([string]$text) {
    Write-Host ""
    Write-Host "== $text ==" -ForegroundColor Cyan
}

Write-Host "Epic download diagnostic" -ForegroundColor Green
Write-Host ("Time: " + (Get-Date -Format "yyyy-MM-dd HH:mm:ss"))

$launcher = Get-Process -Name "EpicGamesLauncher" -ErrorAction SilentlyContinue
if ($launcher) {
    Write-Host ("Launcher running, pid " + ($launcher.Id -join ", "))
} else {
    Write-Host "Launcher not running (start it before judging the download path)" -ForegroundColor Yellow
}

Write-Step "1. Epic CDN"
$cdn = "https://cdn2.unrealengine.com/"
try {
    $raw = & curl.exe -sS -I --ssl-no-revoke --max-time 10 -o NUL -w "%{http_code}|%{time_total}" $cdn 2>&1
    $code, $elapsed = $raw.Trim().Split("|")
    if ($code -eq "302" -or $code -eq "301") {
        Write-Host "  reachable, HTTP $code, handshake $elapsed s" -ForegroundColor Green
    } elseif ($code -eq "403") {
        Write-Host "  reachable, HTTP 403, handshake $elapsed s" -ForegroundColor Green
        Write-Host "  403 is the normal S3 root response, not a block."
    } else {
        Write-Host "  HTTP $code, handshake $elapsed s" -ForegroundColor Yellow
    }
} catch {
    Write-Host "  unreachable: $($_.Exception.Message)" -ForegroundColor Red
}

Write-Step "2. Install rate"
if ($InstallDir -and (Test-Path -LiteralPath $InstallDir)) {
    $before = (Get-ChildItem -LiteralPath $InstallDir -Recurse -File -ErrorAction SilentlyContinue |
               Measure-Object -Property Length -Sum).Sum
    Write-Host ("  sampling {0} for {1}s ..." -f $InstallDir, $Seconds)
    Start-Sleep -Seconds $Seconds
    $after = (Get-ChildItem -LiteralPath $InstallDir -Recurse -File -ErrorAction SilentlyContinue |
              Measure-Object -Property Length -Sum).Sum
    $rate = (($after - $before) / 1MB) / $Seconds
    Write-Host ("  {0:N1} MB/s over {1}s" -f $rate, $Seconds) -ForegroundColor Green
    if ($rate -lt 0.1) {
        if ($launcher) {
            Write-Host "  No growth while the launcher is running: check system proxy and TUN mode." -ForegroundColor Yellow
        } else {
            Write-Host "  No growth, but nothing is downloading either. Start the launcher to test." -ForegroundColor DarkGray
        }
    }
} elseif ($InstallDir) {
    Write-Host "  not found: $InstallDir" -ForegroundColor Yellow
} else {
    Write-Host "  skipped (pass -InstallDir <path> to measure)"
}

Write-Step "3. Epic Online Services"
$eos = Get-NetTCPConnection -State Listen -LocalPort 35783 -ErrorAction SilentlyContinue
if ($eos) {
    Write-Host "  listening on 35783" -ForegroundColor Green
} else {
    Write-Host "  not listening on 35783" -ForegroundColor Yellow
}
$proc = Get-Process -Name "EpicOnlineServices" -ErrorAction SilentlyContinue
if ($proc) {
    Write-Host ("  process running, pid " + ($proc.Id -join ", "))
} else {
    Write-Host "  process not running" -ForegroundColor Yellow
}

Write-Step "4. Launcher log"
$log = Join-Path $env:LOCALAPPDATA "EpicGamesLauncher\Saved\Logs\EpicGamesLauncher.log"
if (Test-Path -LiteralPath $log) {
    Select-String -LiteralPath $log -Pattern "EoshPatcher|exchange code|EoshState|IS-EO-SERVICE_UNAVAILABLE|II-E1007" |
        Select-Object -Last 8 |
        ForEach-Object { Write-Host ("  " + $_.Line.Trim()) }
} else {
    Write-Host "  log not found: $log" -ForegroundColor Yellow
}

Write-Step "Verdict"
if (-not $launcher) {
    Write-Host "  Launcher is not running. Start it, then re-run this script." -ForegroundColor Yellow
} elseif ($eos) {
    Write-Host "  EOS looks alive. If speed is still low, check TUN and the CDN path." -ForegroundColor Green
} else {
    Write-Host "  Launcher is running but EOS is not listening." -ForegroundColor Yellow
    Write-Host "  Run fix-epic-launcher.ps1 as administrator." -ForegroundColor Yellow
}
