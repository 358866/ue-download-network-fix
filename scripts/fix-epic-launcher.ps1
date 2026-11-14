<#
.SYNOPSIS
  Repair the Epic Games Launcher download path (EOS + system proxy + env vars).

.DESCRIPTION
  Applies the three fixes described in README.md:
    1. repair the Epic Online Services component
    2. turn off the Windows system proxy
    3. relaunch the launcher with a valid PROCESSOR_ARCHITECTURE

  Nothing is changed silently: every step prints what it does, and the script
  prints the exact command to restore the system proxy afterwards.

.PARAMETER DryRun
  Report what would happen, change nothing.

.PARAMETER KeepSystemProxy
  Skip step 2 and leave the Windows system proxy as it is.

.PARAMETER RestoreProxy
  Only re-enable the Windows system proxy, then exit.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\scripts\fix-epic-launcher.ps1

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\scripts\fix-epic-launcher.ps1 -DryRun
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$KeepSystemProxy,
    [switch]$RestoreProxy,
    [string]$LauncherPath = "C:\Program Files\Epic Games\Launcher\Portal\Binaries\Win64\EpicGamesLauncher.exe",
    [string]$EosDir = "C:\Program Files (x86)\Epic Games\Epic Online Services"
)

$ErrorActionPreference = "Stop"
$proxyKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings"

function Write-Step([string]$text) {
    Write-Host ""
    Write-Host "== $text ==" -ForegroundColor Cyan
}

function Get-ProxyEnabled {
    try {
        return [int](Get-ItemProperty -LiteralPath $proxyKey -Name ProxyEnable -ErrorAction Stop).ProxyEnable
    } catch {
        return 0
    }
}

function Set-ProxyEnabled([int]$value) {
    if ($DryRun) {
        Write-Host "  [dry-run] ProxyEnable would be set to $value"
        return
    }
    New-Item -Path $proxyKey -Force | Out-Null
    Set-ItemProperty -LiteralPath $proxyKey -Name ProxyEnable -Value $value
    Write-Host "  ProxyEnable = $value"
}

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($id)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

Write-Host "Epic launcher download fix" -ForegroundColor Green
if ($DryRun) { Write-Host "DRY RUN - nothing will be changed" -ForegroundColor Yellow }

if ($RestoreProxy) {
    Write-Step "Restore Windows system proxy"
    Set-ProxyEnabled 1
    Write-Host "  Done. If you normally keep the system proxy off, set it back to 0 instead."
    return
}

$before = Get-ProxyEnabled
Write-Step "Current state"
Write-Host "  Windows system proxy (ProxyEnable): $before"
Write-Host "  Launcher path: $LauncherPath"
Write-Host "  EOS directory: $EosDir"
Write-Host "  Running as administrator: $(Test-Admin)"

if (-not $KeepSystemProxy) {
    Write-Step "Step 2/3 - disable the Windows system proxy"
    if ($before -eq 0) {
        Write-Host "  Already disabled."
    } else {
        Set-ProxyEnabled 0
    }
    Write-Host "  Restore later with:"
    Write-Host "    powershell -ExecutionPolicy Bypass -File .\scripts\fix-epic-launcher.ps1 -RestoreProxy" -ForegroundColor DarkGray
} else {
    Write-Step "Step 2/3 - skipped (-KeepSystemProxy)"
}

Write-Step "Step 1/3 - repair Epic Online Services"
$updater = Join-Path $EosDir "EpicOnlineServices - Update.cmd"
if (-not (Test-Path -LiteralPath $updater)) {
    Write-Host "  Not found: $updater" -ForegroundColor Yellow
    Write-Host "  If Epic is installed elsewhere, pass -EosDir <path>."
} elseif (-not (Test-Admin)) {
    Write-Host "  Skipped: this step needs an elevated PowerShell." -ForegroundColor Yellow
    Write-Host "  Re-run the script as administrator, or run:" -ForegroundColor Yellow
    Write-Host "    Push-Location `"$EosDir`"; & `".\EpicOnlineServices - Update.cmd`" /b; Pop-Location" -ForegroundColor DarkGray
} elseif ($DryRun) {
    Write-Host "  [dry-run] would run: `"$updater`" /b"
} else {
    Push-Location -LiteralPath $EosDir
    try {
        & $updater /b
        Write-Host "  EOS updater exit code: $LASTEXITCODE"
    } finally {
        Pop-Location
    }
}

Write-Step "Step 3/3 - launch the launcher with a valid architecture"
if (-not (Test-Path -LiteralPath $LauncherPath)) {
    Write-Host "  Launcher not found: $LauncherPath" -ForegroundColor Yellow
    Write-Host "  Pass -LauncherPath <path> if it is installed elsewhere."
    return
}

$env:PROCESSOR_ARCHITECTURE = "AMD64"
$env:PROCESSOR_ARCHITEW6432 = "AMD64"
if (-not $env:PROCESSOR_IDENTIFIER) {
    $env:PROCESSOR_IDENTIFIER = "AMD64 Family 25 Model 97 Stepping 2, AuthenticAMD"
}
Write-Host "  PROCESSOR_ARCHITECTURE = $env:PROCESSOR_ARCHITECTURE"
Write-Host "  PROCESSOR_ARCHITEW6432 = $env:PROCESSOR_ARCHITEW6432"

if ($DryRun) {
    Write-Host "  [dry-run] would start: $LauncherPath"
} else {
    Start-Process -FilePath $LauncherPath
    Write-Host "  Launcher started. Open Library and press Continue on the engine version."
}

Write-Step "Done"
Write-Host "Next: watch the install directory grow. Use .\scripts\check-epic-cdn.ps1 for a live rate." -ForegroundColor Green
Write-Host "If the download stalls again, keep TUN and the system proxy off for the whole download." -ForegroundColor Green
