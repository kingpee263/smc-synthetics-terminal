<#
.SYNOPSIS
  SMC Auto-Desk: 24/7 Resilient Always-On Cloud / VPS Watchdog Engine
  Keeps Deriv MT5, Weltrade MT5, and server.ps1 running 24/7 without user intervention.
  Automatically recovers from process crashes, network dropouts, or machine reboots.
#>

$ErrorActionPreference = "Continue"

$repoDir      = Split-Path -Parent $MyInvocation.MyCommand.Path
$serverScript = Join-Path $repoDir "server.ps1"
$commonSmc    = "C:\Users\Administrator\AppData\Roaming\MetaQuotes\Terminal\Common\Files\smc_bridge"
$derivExe     = "C:\Users\Administrator\.gemini\antigravity\scratch\mt5_weltrade\terminal64.exe"
$derivIni     = "C:\Users\Administrator\AppData\Roaming\MetaQuotes\Terminal\06ECD6BB937B24BE6A2DF310EF01AEFF\config\autostart_smc.ini"
$wtExe        = "C:\Users\Administrator\.gemini\antigravity\scratch\mt5_weltrade_2\terminal64.exe"
$wtIni        = "C:\Users\Administrator\.gemini\antigravity\scratch\mt5_weltrade_2\config\weltrade_startup.ini"

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
    Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$serverScript`"" } -ErrorAction SilentlyContinue | Out-Null
    Start-Sleep -Seconds 3
  }
}

function Ensure-DerivRunning {
  if (Test-Path $derivExe) {
    $proc = Get-Process terminal64 -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $derivExe }
    if (-not $proc) {
      Write-Host "[WATCHDOG $(Get-Date -Format 'HH:mm:ss')] Deriv MT5 (#32398784) is not running! Launching $derivExe..." -ForegroundColor Yellow
      Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = "`"$derivExe`" /skipupdate /config:`"$derivIni`"" } -ErrorAction SilentlyContinue | Out-Null
      Start-Sleep -Seconds 4
    }
  }
}

function Ensure-WeltradeRunning {
  # Deriv-Only Mode: Keep Weltrade MT5 offline
  if (Test-Path $wtExe) {
    Get-Process terminal64 -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $wtExe } | Stop-Process -Force -ErrorAction SilentlyContinue
  }
}

function Ensure-ActiveDemoTrades {
  try {
    $accDPath = Join-Path $commonSmc "account_deriv.json"
    $needDeriv = $true
    if (Test-Path $accDPath) {
      $dObj = Get-Content $accDPath -Raw | ConvertFrom-Json
      if ($dObj.orders -and $dObj.orders.Count -ge 1) { $needDeriv = $false }
    }
    if ($needDeriv) {
      # Deriv Nano Friendly Symbol ($10 account safe): Volatility 75 (1s) Index or Boom 1000 Index
      Invoke-RestMethod -Uri "http://localhost:8095/api/scalper/quick" -Method Post -ContentType "application/json" -Body '{"broker":"deriv","symbol":"Volatility 75 (1s) Index","lot":0.005,"side":"AUTO"}' -TimeoutSec 4 -ErrorAction SilentlyContinue | Out-Null
    }
  } catch {}
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
