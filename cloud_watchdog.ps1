<#
.SYNOPSIS
  SMC Auto-Desk: 24/7 Resilient Always-On Cloud / VPS Watchdog Engine
  Keeps Deriv MT5, Weltrade MT5, and server.ps1 running 24/7 without user intervention.
  Automatically recovers from process crashes, network dropouts, or machine reboots.
#>

$ErrorActionPreference = "Continue"

$repoDir    = Split-Path -Parent $MyInvocation.MyCommand.Path
$serverScript = Join-Path $repoDir "server.ps1"
$commonSmc  = "C:\Users\Administrator\AppData\Roaming\MetaQuotes\Terminal\Common\Files\smc_bridge"
$derivExe   = "C:\Program Files\MetaTrader 5\terminal64.exe"
$wtExe      = "C:\Users\Administrator\.gemini\antigravity\scratch\mt5_weltrade\terminal64.exe"

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "  SMC 24/7 AUTONOMOUS CLOUD / VPS ENGINE WATCHDOG ACTIVE  " -ForegroundColor Green
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "Repository Directory: $repoDir"
Write-Host "Common Bridge:        $commonSmc"

if (-not (Test-Path $commonSmc)) {
  New-Item -ItemType Directory -Path $commonSmc -Force | Out-Null
}

function Ensure-ServerRunning {
  $listener = Get-NetTCPConnection -LocalPort 8095 -State Listen -ErrorAction SilentlyContinue
  if (-not $listener) {
    Write-Host "[WATCHDOG $(Get-Date -Format 'HH:mm:ss')] server.ps1 port 8095 not listening! Restarting background server..." -ForegroundColor Yellow
    Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$serverScript`"" -WindowStyle Hidden
    Start-Sleep -Seconds 3
  }
}

function Ensure-DerivRunning {
  if (Test-Path $derivExe) {
    $proc = Get-Process terminal64 -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $derivExe }
    if (-not $proc) {
      Write-Host "[WATCHDOG $(Get-Date -Format 'HH:mm:ss')] Deriv MT5 is not running! Launching $derivExe..." -ForegroundColor Yellow
      Start-Process -FilePath $derivExe -WindowStyle Minimized
      Start-Sleep -Seconds 4
    }
  }
}

function Ensure-WeltradeRunning {
  if (Test-Path $wtExe) {
    $proc = Get-Process terminal64 -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $wtExe }
    if (-not $proc) {
      Write-Host "[WATCHDOG $(Get-Date -Format 'HH:mm:ss')] Weltrade MT5 is not running! Launching $wtExe..." -ForegroundColor Yellow
      Start-Process -FilePath $wtExe -WindowStyle Minimized
      Start-Sleep -Seconds 4
    }
  }
}

function Keep-MachineAwake {
  # Prevent Windows from going into Sleep or Idle Standby when running on a 24/7 host
  try {
    Add-Type -TypeDefinition @"
    using System;
    using System.Runtime.InteropServices;
    public class PowerManagement {
      [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
      public static extern uint SetThreadExecutionState(uint esFlags);
      public const uint ES_CONTINUOUS = 0x80000000;
      public const uint ES_SYSTEM_REQUIRED = 0x00000001;
      public const uint ES_AWAYMODE_REQUIRED = 0x00000040;
    }
"@
    [PowerManagement]::SetThreadExecutionState([PowerManagement]::ES_CONTINUOUS -bor [PowerManagement]::ES_SYSTEM_REQUIRED -bor [PowerManagement]::ES_AWAYMODE_REQUIRED) | Out-Null
  } catch {}
}

# Initial checks
Keep-MachineAwake
Ensure-ServerRunning
Ensure-DerivRunning
Ensure-WeltradeRunning

Write-Host "`n[ONLINE] All services verified live. Watchdog monitoring loop running every 15 seconds..." -ForegroundColor Green
Write-Host "Press Ctrl+C to terminate the watchdog (do not close this window to stay 24/7 online).`n"

$loopCount = 0
while ($true) {
  Start-Sleep -Seconds 15
  $loopCount++

  Ensure-ServerRunning
  Ensure-DerivRunning
  Ensure-WeltradeRunning

  if ($loopCount % 20 -eq 0) {
    Keep-MachineAwake
    Write-Host "[HEARTBEAT $(Get-Date -Format 'HH:mm:ss')] 24/7 Watchdog alive. Deriv MT5, Weltrade MT5, & server.ps1 healthy." -ForegroundColor DarkCyan
  }
}
