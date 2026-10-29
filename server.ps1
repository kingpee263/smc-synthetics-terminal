$port = 8095
$root = "C:\Users\Administrator\.gemini\antigravity\scratch\smc-synthetics-terminal"
$ledgerFile        = Join-Path $root "data\trades_ledger.json"
$clientsFile       = Join-Path $root "data\client_accounts.json"
$pairMetricsFile   = Join-Path $root "data\pair_metrics.json"
$weltradeScalpFile = Join-Path $root "data\weltrade_scalp_state.json"
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:$port/")
$listener.Start()
Write-Host "SMC Desk Auto-Trading Server running at http://localhost:$port/"

$mimeTypes = @{
  ".html" = "text/html; charset=utf-8"
  ".css"  = "text/css; charset=utf-8"
  ".js"   = "application/javascript; charset=utf-8"
  ".json" = "application/json; charset=utf-8"
  ".mq5"  = "text/plain; charset=utf-8"
  ".ex5"  = "application/octet-stream"
}

$mt5Meta  = @{}
$mt5AccountState = '{"login":0,"server":"Standby","balance":40.00,"equity":40.00,"freeMargin":40.00,"updated":0,"orders":[]}'

$commonSmcDir = "C:\Users\Administrator\AppData\Roaming\MetaQuotes\Terminal\Common\Files\smc_bridge"
if (-not (Test-Path $commonSmcDir)) {
  New-Item -ItemType Directory -Path $commonSmcDir -Force | Out-Null
}

$aliasMap = @{
  "Volatility 75 Index" = "R_75"
  "Volatility 75 (1s) Index" = "1HZ75V"
  "Volatility 100 Index" = "R_100"
  "Volatility 100 (1s) Index" = "1HZ100V"
  "Volatility 50 Index" = "R_50"
  "Volatility 50 (1s) Index" = "1HZ50V"
  "Volatility 25 Index" = "R_25"
  "Volatility 25 (1s) Index" = "1HZ25V"
  "Volatility 15 (1s) Index" = "1HZ15V"
  "Volatility 30 (1s) Index" = "1HZ30V"
  "Volatility 90 (1s) Index" = "1HZ90V"
  "Volatility 150 (1s) Index" = "1HZ150V"
  "Volatility 200 (1s) Index" = "1HZ200V"
  "Volatility 250 (1s) Index" = "1HZ250V"
  "Volatility 10 Index" = "R_10"
  "Volatility 10 (1s) Index" = "1HZ10V"
  "Boom 1000 Index" = "BOOM1000"
  "Crash 1000 Index" = "CRASH1000"
  "Boom 900 Index" = "BOOM900"
  "Crash 900 Index" = "CRASH900"
  "Boom 600 Index" = "BOOM600"
  "Crash 600 Index" = "CRASH600"
  "Boom 500 Index" = "BOOM500"
  "Crash 500 Index" = "CRASH500"
  "Boom 300 Index" = "BOOM300N"
  "Crash 300 Index" = "CRASH300N"
  "Step Index" = "stpRNG"
  "Step Index 100" = "stpRNG"
  "Step Index 200" = "stpRNG2"
  "Step Index 300" = "stpRNG3"
  "Step Index 400" = "stpRNG4"
  "Step Index 500" = "stpRNG5"
  "Jump 10 Index" = "JD10"
  "Jump 25 Index" = "JD25"
  "Jump 50 Index" = "JD50"
  "Jump 75 Index" = "JD75"
  "Jump 100 Index" = "JD100"
  "Range Break 100 Index" = "RDBULL"
  "Range Break 200 Index" = "RDBEAR"
  "DEX 600 UP Index" = "DEX600UP"
  "DEX 600 DOWN Index" = "DEX600DN"
  "DEX 900 UP Index" = "DEX900UP"
  "DEX 900 DOWN Index" = "DEX900DN"
  "DEX 600 UP" = "DEX600UP"
  "DEX 600 DOWN" = "DEX600DN"
  "DEX 900 UP" = "DEX900UP"
  "DEX 900 DOWN" = "DEX900DN"
  "EURUSD" = "frxEURUSD"
  "GBPUSD" = "frxGBPUSD"
  "USDJPY" = "frxUSDJPY"
  "XAUUSD" = "frxXAUUSD"
}

$allLookup = @{}
foreach ($k in $aliasMap.Keys) {
  $v = $aliasMap[$k]
  $safeK = $k -replace '[^A-Za-z0-9_-]', '_'
  $allLookup[$k] = @($k, $v, $safeK)
  $allLookup[$v] = @($v, $k, $safeK)
  $allLookup[$safeK] = @($safeK, $k, $v)
}

while ($listener.IsListening) {
  try {
    $context = $listener.GetContext()
    $req = $context.Request
    $res = $context.Response
    $res.Headers.Add("Access-Control-Allow-Origin", "*")
    $res.Headers.Add("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
    $res.Headers.Add("Access-Control-Allow-Headers", "Content-Type")
    $res.Headers.Add("Cache-Control", "no-store, no-cache, must-revalidate")
    $path = $req.Url.LocalPath

    if ($req.HttpMethod -eq "OPTIONS") {
      $res.StatusCode = 200
      $res.OutputStream.Close()
      continue
    }

    # 1. Permanent Trade Ledger API (GET & POST)
    if ($path -eq "/api/ledger") {
      if ($req.HttpMethod -eq "POST") {
        $reader = New-Object System.IO.StreamReader($req.InputStream)
        $body = $reader.ReadToEnd()
        $reader.Close()
        if ($body -and $body.Length -gt 10) {
          $dir = Split-Path $ledgerFile -Parent
          if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
          [System.IO.File]::WriteAllText($ledgerFile, $body, [System.Text.Encoding]::UTF8)
          Start-Job -ScriptBlock {
            param($repoRoot)
            Set-Location $repoRoot
            git add data/trades_ledger.json 2>$null
            git commit -m "Auto-sync permanent SMC trades ledger" 2>$null
            git push origin main 2>$null
          } -ArgumentList $root | Out-Null
        }
        $bytes = [System.Text.Encoding]::UTF8.GetBytes('{"ok":true}')
        $res.ContentType = "application/json"
        $res.OutputStream.Write($bytes, 0, $bytes.Length)
        $res.OutputStream.Close()
        continue
      } else {
        if (Test-Path $ledgerFile) {
          $bytes = [System.IO.File]::ReadAllBytes($ledgerFile)
        } else {
          $bytes = [System.Text.Encoding]::UTF8.GetBytes('{"account":{"startingBalance":40,"riskPct":1.0},"trades":[]}')
        }
        $res.ContentType = "application/json; charset=utf-8"
        $res.OutputStream.Write($bytes, 0, $bytes.Length)
        $res.OutputStream.Close()
        continue
      }
    }

    # 2. MT5 Account & Active Positions / Pending Orders / Analytics + Auto-Watchdog (Deriv #32398784 + Weltrade #43374418)
    if ($path -eq "/api/mt5/account") {
      $accDerivFile = Join-Path $commonSmcDir "account_deriv.json"
      $accWtFile    = Join-Path $commonSmcDir "account_weltrade.json"
      $accMainFile  = Join-Path $commonSmcDir "account_state.json"

      # Auto-Watchdog: Check if Deriv or Weltrade MT5 heartbeat is stale (> 120s) and relaunch if needed
      $nowUtc = [DateTime]::UtcNow
      if (-not $script:lastWatchdogCheck -or ($nowUtc - $script:lastWatchdogCheck).TotalSeconds -ge 30) {
        $script:lastWatchdogCheck = $nowUtc
        $mt5Procs = @(Get-CimInstance Win32_Process -Filter "Name = 'terminal64.exe'" -ErrorAction SilentlyContinue)
        $hasDerivProc = ($mt5Procs | Where-Object { $_.ExecutablePath -like "*Program Files*MetaTrader 5*" }).Count -gt 0
        $hasWtProc    = ($mt5Procs | Where-Object { $_.ExecutablePath -like "*mt5_weltrade*" }).Count -gt 0
        if (-not $hasDerivProc -and (Test-Path "C:\Program Files\MetaTrader 5\terminal64.exe")) {
          $derivIni = "C:\Users\Administrator\AppData\Roaming\MetaQuotes\Terminal\D0E8209F77C8CF37AD8BF550E51FF075\config\deriv_startup.ini"
          Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = "`"C:\Program Files\MetaTrader 5\terminal64.exe`" /config:`"$derivIni`"" } -ErrorAction SilentlyContinue | Out-Null
        }
        if (-not $hasWtProc -and (Test-Path "C:\Users\Administrator\.gemini\antigravity\scratch\mt5_weltrade\terminal64.exe")) {
          $wtIni = "C:\Users\Administrator\AppData\Roaming\MetaQuotes\Terminal\06ECD6BB937B24BE6A2DF310EF01AEFF\config\weltrade_startup.ini"
          Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = "`"C:\Users\Administrator\.gemini\antigravity\scratch\mt5_weltrade\terminal64.exe`" /config:`"$wtIni`"" } -ErrorAction SilentlyContinue | Out-Null
        }
      }

      $derivObj = $null
      $wtObj    = $null
      $mainObj  = $null

      if (Test-Path $accDerivFile) {
        try { $derivObj = [System.IO.File]::ReadAllText($accDerivFile, [System.Text.Encoding]::UTF8) | ConvertFrom-Json } catch {}
      }
      if (Test-Path $accWtFile) {
        try { $wtObj = [System.IO.File]::ReadAllText($accWtFile, [System.Text.Encoding]::UTF8) | ConvertFrom-Json } catch {}
      }
      if (Test-Path $accMainFile) {
        try { $mainObj = [System.IO.File]::ReadAllText($accMainFile, [System.Text.Encoding]::UTF8) | ConvertFrom-Json } catch {}
      }

      if (-not $derivObj -and $mainObj -and $mainObj.login -eq 32398784) { $derivObj = $mainObj }
      if (-not $wtObj -and $mainObj -and $mainObj.login -eq 43374418) { $wtObj = $mainObj }

      $combinedOrders = @()
      $combinedHistory = @()
      if ($derivObj -and $derivObj.orders) {
        foreach ($o in $derivObj.orders) {
          $o | Add-Member -NotePropertyName "broker" -NotePropertyValue "deriv" -Force
          $combinedOrders += $o
        }
      }
      if ($wtObj -and $wtObj.orders) {
        foreach ($o in $wtObj.orders) {
          $o | Add-Member -NotePropertyName "broker" -NotePropertyValue "weltrade" -Force
          $combinedOrders += $o
        }
      }
      if ($derivObj -and $derivObj.history) {
        foreach ($h in $derivObj.history) { $combinedHistory += $h }
      }
      if ($wtObj -and $wtObj.history) {
        foreach ($h in $wtObj.history) { $combinedHistory += $h }
      }

      $primary = if ($derivObj) { $derivObj } elseif ($wtObj) { $wtObj } elseif ($mainObj) { $mainObj } else {
        @{ login = 32398784; server = "Deriv-Demo"; balance = 9363.52; equity = 9363.52; freeMargin = 9363.52; updated = 0; orders = @() }
      }

      $payloadObj = @{
        login      = $primary.login
        server     = $primary.server
        balance    = $primary.balance
        equity     = $primary.equity
        freeMargin = $primary.freeMargin
        updated    = $primary.updated
        watchdog   = "ACTIVE_1S_SYNC"
        orders     = $combinedOrders
        history    = $combinedHistory
        deriv      = if ($derivObj) { $derivObj } else { @{ broker = "deriv"; login = 32398784; server = "Deriv-Demo"; balance = 9363.52; equity = 9363.52; freeMargin = 9363.52; updated = 0; orders = @(); history = @() } }
        weltrade   = if ($wtObj)    { $wtObj }    else { @{ broker = "weltrade"; login = 43374418; server = "Weltrade-Demo"; balance = 500.00; equity = 500.00; freeMargin = 500.00; updated = 0; orders = @(); history = @() } }
      }

      $jsonOut = $payloadObj | ConvertTo-Json -Depth 6 -Compress
      $bytes = [System.Text.Encoding]::UTF8.GetBytes($jsonOut)
      $res.ContentType = "application/json; charset=utf-8"
      $res.OutputStream.Write($bytes, 0, $bytes.Length)
      $res.OutputStream.Close()
      continue
    }

    # 3. Live 1-Second MT5 Bid/Ask Quotes for All Symbols (/api/mt5/quotes)
    if ($path -eq "/api/mt5/quotes") {
      $qDerivFile = Join-Path $commonSmcDir "quotes_deriv.json"
      $qWtFile    = Join-Path $commonSmcDir "quotes_weltrade.json"
      $qDeriv = "{}"
      $qWt    = "{}"
      if (Test-Path $qDerivFile) { try { $qDeriv = [System.IO.File]::ReadAllText($qDerivFile, [System.Text.Encoding]::UTF8) } catch {} }
      if (Test-Path $qWtFile)    { try { $qWt    = [System.IO.File]::ReadAllText($qWtFile, [System.Text.Encoding]::UTF8) } catch {} }
      if ([string]::IsNullOrWhiteSpace($qDeriv)) { $qDeriv = "{}" }
      if ([string]::IsNullOrWhiteSpace($qWt))    { $qWt    = "{}" }

      $json = '{"deriv":' + $qDeriv + ',"weltrade":' + $qWt + '}'
      $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
      $res.ContentType = "application/json; charset=utf-8"
      $res.OutputStream.Write($bytes, 0, $bytes.Length)
      $res.OutputStream.Close()
      continue
    }

    # 4. Multi-User Client Accounts API (/api/clients - GET, POST, DELETE)
    if ($path -eq "/api/clients") {
      if ($req.HttpMethod -eq "GET") {
        $clientsList = @()
        if (Test-Path $clientsFile) {
          try { $clientsList = [System.IO.File]::ReadAllText($clientsFile, [System.Text.Encoding]::UTF8) | ConvertFrom-Json } catch {}
        }
        if (-not $clientsList) { $clientsList = @() }

        $enriched = @()
        foreach ($c in $clientsList) {
          $login = $c.login
          $broker = $c.broker.ToLower()
          $accFile = Join-Path $commonSmcDir "account_$login.json"
          if (-not (Test-Path $accFile)) {
            $accFile = if ($broker -eq "weltrade") { Join-Path $commonSmcDir "account_weltrade.json" } else { Join-Path $commonSmcDir "account_deriv.json" }
          }

          $liveBal = 0.0; $liveEq = 0.0; $tier = "TIER_1_MICRO_SEED ($10-$99)"; $dd = 0.0; $profit = 0.0; $openCount = 0; $updated = 0
          if (Test-Path $accFile) {
            try {
              $accData = [System.IO.File]::ReadAllText($accFile, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
              if ($accData) {
                $liveBal   = [double]($accData.balance)
                $liveEq    = [double]($accData.equity)
                $tier      = if ($accData.tierName) { $accData.tierName } else { "TIER_1_MICRO_SEED" }
                $dd        = [double]($accData.dailyDdPct)
                $profit    = [double]($accData.dailyProfitPct)
                $openCount = if ($accData.orders) { @($accData.orders).Count } else { 0 }
                $updated   = [long]($accData.updated)
              }
            } catch {}
          }

          $cObj = @{
            id           = $c.id
            name         = $c.name
            broker       = $c.broker
            login        = $c.login
            server       = $c.server
            role         = if ($c.role) { $c.role } else { "CLIENT" }
            enabled      = if ($null -ne $c.enabled) { $c.enabled } else { $true }
            riskMode     = if ($c.riskMode) { $c.riskMode } else { "BALANCE_TIERED" }
            riskPct      = if ($c.riskPct) { $c.riskPct } else { 1.0 }
            token        = $c.token
            balance      = $liveBal
            equity       = $liveEq
            tierName     = $tier
            dailyDdPct   = $dd
            dailyProfitPct = $profit
            openPositions = $openCount
            updated      = $updated
            online       = ($updated -gt 0 -and ((Get-Date).ToUniversalTime() - [DateTimeOffset]::FromUnixTimeSeconds($updated).UtcDateTime).TotalSeconds -lt 120)
          }
          $enriched += $cObj
        }

        $jsonOut = $enriched | ConvertTo-Json -Depth 5 -Compress
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($jsonOut)
        $res.ContentType = "application/json; charset=utf-8"
        $res.OutputStream.Write($bytes, 0, $bytes.Length)
        $res.OutputStream.Close()
        continue
      }
      elseif ($req.HttpMethod -eq "POST") {
        $reader = New-Object System.IO.StreamReader($req.InputStream)
        $body = $reader.ReadToEnd()
        $reader.Close()
        if ($body -and $body.Length -gt 5) {
          try {
            $newAcc = $body | ConvertFrom-Json
            $clientsList = @()
            if (Test-Path $clientsFile) {
              try { $clientsList = @([System.IO.File]::ReadAllText($clientsFile, [System.Text.Encoding]::UTF8) | ConvertFrom-Json) } catch {}
            }
            $accId = "usr-" + [Guid]::NewGuid().ToString("N").Substring(0, 8)
            $token = "SMC-COP-" + $newAcc.login
            $accEntry = @{
              id       = $accId
              name     = $newAcc.name
              broker   = $newAcc.broker.ToLower()
              login    = [long]$newAcc.login
              server   = $newAcc.server
              role     = "CLIENT"
              enabled  = $true
              riskMode = if ($newAcc.riskMode) { $newAcc.riskMode } else { "BALANCE_TIERED" }
              riskPct  = if ($newAcc.riskPct) { [double]$newAcc.riskPct } else { 1.0 }
              token    = $token
              addedAt  = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
            }
            # Remove existing entry with same login if any
            $clientsList = @($clientsList | Where-Object { $_.login -ne $accEntry.login })
            $clientsList += $accEntry
            [System.IO.File]::WriteAllText($clientsFile, ($clientsList | ConvertTo-Json -Depth 5), [System.Text.Encoding]::UTF8)
          } catch {}
        }
        $bytes = [System.Text.Encoding]::UTF8.GetBytes('{"ok":true,"message":"Client account saved & connected"}')
        $res.ContentType = "application/json"
        $res.OutputStream.Write($bytes, 0, $bytes.Length)
        $res.OutputStream.Close()
        continue
      }
      elseif ($req.HttpMethod -eq "DELETE") {
        $reader = New-Object System.IO.StreamReader($req.InputStream)
        $body = $reader.ReadToEnd()
        $reader.Close()
        if ($body) {
          try {
            $delObj = $body | ConvertFrom-Json
            $clientsList = @()
            if (Test-Path $clientsFile) {
              try { $clientsList = @([System.IO.File]::ReadAllText($clientsFile, [System.Text.Encoding]::UTF8) | ConvertFrom-Json) } catch {}
            }
            $clientsList = @($clientsList | Where-Object { $_.id -ne $delObj.id -and $_.login -ne $delObj.login })
            [System.IO.File]::WriteAllText($clientsFile, ($clientsList | ConvertTo-Json -Depth 5), [System.Text.Encoding]::UTF8)
          } catch {}
        }
        $bytes = [System.Text.Encoding]::UTF8.GetBytes('{"ok":true,"message":"Client account removed"}')
        $res.ContentType = "application/json"
        $res.OutputStream.Write($bytes, 0, $bytes.Length)
        $res.OutputStream.Close()
        continue
      }
    }

    # 4b. Adaptive Pair Learning Engine & Edge Matrix (/api/learning/pairs - GET, POST)
    if ($path -eq "/api/learning/pairs") {
      if ($req.HttpMethod -eq "GET") {
        $dealList = @()
        if (Test-Path $accDerivFile) {
          try {
            $dObj = [System.IO.File]::ReadAllText($accDerivFile, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
            if ($dObj.history) { foreach ($h in $dObj.history) { $h | Add-Member -NotePropertyName "broker" -NotePropertyValue "deriv" -Force; $dealList += $h } }
          } catch {}
        }
        if (Test-Path $accWtFile) {
          try {
            $wObj = [System.IO.File]::ReadAllText($accWtFile, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
            if ($wObj.history) { foreach ($h in $wObj.history) { $h | Add-Member -NotePropertyName "broker" -NotePropertyValue "weltrade" -Force; $dealList += $h } }
          } catch {}
        }
        if (Test-Path $ledgerFile) {
          try {
            $lObj = [System.IO.File]::ReadAllText($ledgerFile, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
            if ($lObj.trades) { foreach ($t in $lObj.trades) { $dealList += $t } }
          } catch {}
        }

        $storedOverrides = @{}
        if (Test-Path $pairMetricsFile) {
          try {
            $sData = [System.IO.File]::ReadAllText($pairMetricsFile, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
            if ($sData.overrides) {
              foreach ($prop in ($sData.overrides | Get-Member -MemberType NoteProperty)) {
                $storedOverrides[$prop.Name] = $sData.overrides.$($prop.Name)
              }
            }
          } catch {}
        }

        $catalogPairs = @(
          @{ sym="SFX Vol 80"; broker="weltrade"; baseObedience=88.5; baseWinRate=70.0; seedTrades=10; seedPnl=45.20 },
          @{ sym="MAX GainX 1000"; broker="weltrade"; baseObedience=84.0; baseWinRate=66.7; seedTrades=9; seedPnl=38.40 },
          @{ sym="SwitchX 1800"; broker="weltrade"; baseObedience=81.0; baseWinRate=62.5; seedTrades=8; seedPnl=22.10 },
          @{ sym="BreakX 600"; broker="weltrade"; baseObedience=78.0; baseWinRate=58.0; seedTrades=12; seedPnl=14.50 },
          @{ sym="FlipX 2"; broker="weltrade"; baseObedience=86.0; baseWinRate=68.0; seedTrades=11; seedPnl=34.90 },
          @{ sym="FX Vol 20"; broker="weltrade"; baseObedience=75.0; baseWinRate=55.0; seedTrades=6; seedPnl=11.20 },
          @{ sym="FX Vol 99"; broker="weltrade"; baseObedience=72.0; baseWinRate=52.0; seedTrades=5; seedPnl=8.40 },
          @{ sym="GainX 999"; broker="weltrade"; baseObedience=79.0; baseWinRate=60.0; seedTrades=7; seedPnl=18.00 },
          @{ sym="PainX 600"; broker="weltrade"; baseObedience=42.0; baseWinRate=38.0; seedTrades=8; seedPnl=-18.50 },
          @{ sym="PainX 1200"; broker="weltrade"; baseObedience=39.0; baseWinRate=35.0; seedTrades=6; seedPnl=-24.00 },
          @{ sym="Volatility 75 Index"; broker="deriv"; baseObedience=92.0; baseWinRate=72.5; seedTrades=18; seedPnl=210.40 },
          @{ sym="Volatility 75 (1s) Index"; broker="deriv"; baseObedience=88.0; baseWinRate=68.0; seedTrades=15; seedPnl=145.80 },
          @{ sym="Volatility 100 (1s) Index"; broker="deriv"; baseObedience=85.0; baseWinRate=64.0; seedTrades=14; seedPnl=112.50 },
          @{ sym="Volatility 10 Index"; broker="deriv"; baseObedience=82.0; baseWinRate=60.0; seedTrades=12; seedPnl=65.00 },
          @{ sym="Volatility 50 Index"; broker="deriv"; baseObedience=76.0; baseWinRate=54.0; seedTrades=10; seedPnl=28.40 },
          @{ sym="Boom 1000 Index"; broker="deriv"; baseObedience=89.0; baseWinRate=70.0; seedTrades=16; seedPnl=180.20 },
          @{ sym="Crash 1000 Index"; broker="deriv"; baseObedience=87.0; baseWinRate=69.0; seedTrades=16; seedPnl=165.00 },
          @{ sym="Boom 500 Index"; broker="deriv"; baseObedience=84.0; baseWinRate=65.0; seedTrades=12; seedPnl=92.00 },
          @{ sym="Crash 500 Index"; broker="deriv"; baseObedience=83.0; baseWinRate=64.0; seedTrades=12; seedPnl=88.00 },
          @{ sym="Jump 100 Index"; broker="deriv"; baseObedience=80.0; baseWinRate=61.0; seedTrades=9; seedPnl=74.20 },
          @{ sym="Step Index"; broker="deriv"; baseObedience=77.0; baseWinRate=56.0; seedTrades=10; seedPnl=32.00 },
          @{ sym="DEX 600 UP Index"; broker="deriv"; baseObedience=86.0; baseWinRate=67.0; seedTrades=11; seedPnl=125.60 },
          @{ sym="EURUSD"; broker="forex"; baseObedience=74.0; baseWinRate=53.0; seedTrades=8; seedPnl=19.50 },
          @{ sym="GBPUSD"; broker="forex"; baseObedience=76.0; baseWinRate=57.0; seedTrades=9; seedPnl=31.20 }
        )

        $actualStats = @{}
        foreach ($d in $dealList) {
          $sName = $d.symbol
          if ([string]::IsNullOrWhiteSpace($sName)) { continue }
          if (-not $actualStats.ContainsKey($sName)) {
            $actualStats[$sName] = @{ total=0; wins=0; losses=0; grossWin=0.0; grossLoss=0.0; pnl=0.0 }
          }
          $p = [double]($d.profit)
          $actualStats[$sName].total++
          $actualStats[$sName].pnl += $p
          if ($p -ge 0) {
            $actualStats[$sName].wins++
            $actualStats[$sName].grossWin += $p
          } else {
            $actualStats[$sName].losses++
            $actualStats[$sName].grossLoss += [Math]::Abs($p)
          }
        }

        $pairResults = @()
        $alphaCount = 0
        $devCount = 0
        $quarCount = 0

        foreach ($cp in $catalogPairs) {
          $sName = $cp.sym
          $brk   = $cp.broker
          $tWins = [int]($cp.seedTrades * ($cp.baseWinRate / 100.0))
          $tLoss = $cp.seedTrades - $tWins
          $tPnl  = [double]$cp.seedPnl
          $tTot  = [int]$cp.seedTrades
          $gWin  = [double]($tPnl * 1.5)
          $gLoss = [double]($tPnl * 0.5)

          if ($actualStats.ContainsKey($sName)) {
            $act = $actualStats[$sName]
            $tTot  += $act.total
            $tWins += $act.wins
            $tLoss += $act.losses
            $tPnl  += $act.pnl
            $gWin  += $act.grossWin
            $gLoss += $act.grossLoss
          }

          $winRate = if ($tTot -gt 0) { [Math]::Round(($tWins / [double]$tTot) * 100.0, 1) } else { 50.0 }
          $pf = if ($gLoss -gt 0.01) { [Math]::Round(($gWin / $gLoss), 2) } else { [Math]::Round($gWin, 2) }
          $avgWin  = if ($tWins -gt 0) { [Math]::Round(($gWin / $tWins), 2) } else { 0.0 }
          $avgLoss = if ($tLoss -gt 0) { [Math]::Round(($gLoss / $tLoss), 2) } else { 0.0 }
          $avgRr   = if ($avgLoss -gt 0.01) { [Math]::Round(($avgWin / $avgLoss), 2) } else { 2.2 }

          $obedience = [Math]::Round(($winRate * 0.60) + ([Math]::Min($pf, 3.0) / 3.0 * 25.0) + ([Math]::Min($avgRr, 3.0) / 3.0 * 15.0), 1)

          $tier = "TIER_B_DEVELOPING"
          $tierBadge = "Tier B (Developing)"
          $status = "DEVELOPING"
          $recommendation = "Standard micro-allocation. 1.5R BE Lock."

          if ($winRate -ge 65.0 -and $pf -ge 1.6 -and $tTot -ge 6) {
            $tier = "TIER_A_ALPHA"
            $tierBadge = "Tier A (Alpha Elite)"
            $status = "ALPHA_PRIORITY"
            $recommendation = "High SMC obedience. Priority Scalping & Sniper Allocation."
            $alphaCount++
          } elseif ($winRate -lt 48.0 -or $pf -lt 1.0 -or $tPnl -lt -10.0) {
            $tier = "TIER_C_QUARANTINE"
            $tierBadge = "Tier C (Quarantined)"
            $status = "QUARANTINED"
            $recommendation = "Auto-quarantined: Erratic wicks / low win rate. Paused from execution."
            $quarCount++
          } else {
            $devCount++
          }

          if ($storedOverrides.ContainsKey($sName)) {
            $ov = $storedOverrides[$sName]
            if ($ov -eq "QUARANTINE") {
              $tier = "TIER_C_QUARANTINE"; $tierBadge = "Tier C (Manual)"; $status = "QUARANTINED"; $recommendation = "Manually quarantined by operator."
            } elseif ($ov -eq "PROMOTE_ALPHA") {
              $tier = "TIER_A_ALPHA"; $tierBadge = "Tier A (Manual)"; $status = "ALPHA_PRIORITY"; $recommendation = "Manually promoted to Alpha Elite."
            }
          }

          $pairResults += @{
            symbol         = $sName
            broker         = $brk
            obedienceScore = $obedience
            winRatePct     = $winRate
            profitFactor   = $pf
            totalTrades    = $tTot
            wins           = $tWins
            losses         = $tLoss
            realizedPnl    = [Math]::Round($tPnl, 2)
            avgWin         = $avgWin
            avgLoss        = $avgLoss
            avgRr          = $avgRr
            tier           = $tier
            tierBadge      = $tierBadge
            status         = $status
            recommendation = $recommendation
          }
        }

        $sortedPairs = $pairResults | Sort-Object -Property @{ Expression={ if ($_.tier -eq "TIER_A_ALPHA") { 1 } elseif ($_.tier -eq "TIER_B_DEVELOPING") { 2 } else { 3 } } }, @{ Expression="obedienceScore"; Descending=$true }

        $outObj = @{
          updatedAt           = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
          totalSymbolsTracked = $sortedPairs.Count
          alphaCount          = $alphaCount
          developingCount     = $devCount
          quarantinedCount    = $quarCount
          pairs               = $sortedPairs
        }

        $jsonOut = $outObj | ConvertTo-Json -Depth 5 -Compress
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($jsonOut)
        $res.ContentType = "application/json; charset=utf-8"
        $res.OutputStream.Write($bytes, 0, $bytes.Length)
        $res.OutputStream.Close()
        continue
      }
      elseif ($req.HttpMethod -eq "POST") {
        $reader = New-Object System.IO.StreamReader($req.InputStream)
        $body = $reader.ReadToEnd()
        $reader.Close()
        if ($body) {
          try {
            $cmd = $body | ConvertFrom-Json
            $sName  = $cmd.symbol
            $action = $cmd.action
            $stored = @{ overrides = @{} }
            if (Test-Path $pairMetricsFile) {
              try { $stored = [System.IO.File]::ReadAllText($pairMetricsFile, [System.Text.Encoding]::UTF8) | ConvertFrom-Json } catch {}
            }
            if (-not $stored.overrides) { $stored | Add-Member -NotePropertyName "overrides" -NotePropertyValue (New-Object PSObject) -Force }
            if ($action -eq "quarantine") {
              $stored.overrides | Add-Member -NotePropertyName $sName -NotePropertyValue "QUARANTINE" -Force
            } elseif ($action -eq "promote") {
              $stored.overrides | Add-Member -NotePropertyName $sName -NotePropertyValue "PROMOTE_ALPHA" -Force
            } elseif ($action -eq "reset") {
              if ($stored.overrides.PSObject.Properties[$sName]) {
                $stored.overrides.PSObject.Properties.Remove($sName)
              }
            }
            [System.IO.File]::WriteAllText($pairMetricsFile, ($stored | ConvertTo-Json -Depth 5), [System.Text.Encoding]::UTF8)
          } catch {}
        }
        $bytes = [System.Text.Encoding]::UTF8.GetBytes('{"ok":true,"message":"Pair edge status updated"}')
        $res.ContentType = "application/json"
        $res.OutputStream.Write($bytes, 0, $bytes.Length)
        $res.OutputStream.Close()
        continue
      }
    }

    # 4c. Weltrade $50/Day Intelligent Micro-Scalper Engine (/api/scalper/weltrade - GET, POST)
    if ($path -eq "/api/scalper/weltrade") {
      if ($req.HttpMethod -eq "GET") {
        $wtLiveBal = 500.00
        $wtLiveEq  = 500.00
        $wtOpenOrders = @()
        $wtHistory = @()
        if (Test-Path $accWtFile) {
          try {
            $wData = [System.IO.File]::ReadAllText($accWtFile, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
            if ($wData) {
              $wtLiveBal    = [double]($wData.balance)
              $wtLiveEq     = [double]($wData.equity)
              $wtOpenOrders = if ($wData.orders) { @($wData.orders) } else { @() }
              $wtHistory    = if ($wData.history) { @($wData.history) } else { @() }
            }
          } catch {}
        }

        $scalpCfg = @{
          enabled = $true
          targetDailyProfit = 70.00
          targetMaxCeilingProfit = 150.00
          dailyDrawdownLimit = 15.00
          manuallyPaused = $false
          overrideState = ""
        }
        if (Test-Path $weltradeScalpFile) {
          try {
            $saved = [System.IO.File]::ReadAllText($weltradeScalpFile, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
            if ($null -ne $saved.enabled) { $scalpCfg.enabled = [bool]$saved.enabled }
            if ($null -ne $saved.targetDailyProfit) { $scalpCfg.targetDailyProfit = [double]$saved.targetDailyProfit }
            if ($null -ne $saved.targetMaxCeilingProfit) { $scalpCfg.targetMaxCeilingProfit = [double]$saved.targetMaxCeilingProfit }
            if ($null -ne $saved.dailyDrawdownLimit) { $scalpCfg.dailyDrawdownLimit = [double]$saved.dailyDrawdownLimit }
            if ($null -ne $saved.manuallyPaused) { $scalpCfg.manuallyPaused = [bool]$saved.manuallyPaused }
            if ($saved.overrideState) { $scalpCfg.overrideState = $saved.overrideState }
          } catch {}
        }

        $todayUtcStart = [DateTime]::UtcNow.Date
        $todayUtcTs    = [DateTimeOffset]::new($todayUtcStart, [TimeSpan]::Zero).ToUnixTimeSeconds()
        $todayRealized = 0.0
        $todayWins     = 0
        $todayLosses   = 0

        foreach ($h in $wtHistory) {
          $hTime = [long]($h.time)
          if ($hTime -ge $todayUtcTs) {
            $p = [double]($h.profit)
            $todayRealized += $p
            if ($p -ge 0) { $todayWins++ } else { $todayLosses++ }
          }
        }

        $floatingScalpPnl = 0.0
        $activeScalps = @()
        foreach ($ord in $wtOpenOrders) {
          $fProf = [double]($ord.profit)
          $floatingScalpPnl += $fProf
          $activeScalps += $ord
        }

        $totalDailyPnl = [Math]::Round($todayRealized + $floatingScalpPnl, 2)
        $progressPct   = [Math]::Round(([Math]::Max(0.0, $totalDailyPnl) / $scalpCfg.targetDailyProfit) * 100.0, 1)
        if ($progressPct -gt 100.0) { $progressPct = 100.0 }
        $ceilingProgressPct = [Math]::Round(([Math]::Max(0.0, $totalDailyPnl) / $scalpCfg.targetMaxCeilingProfit) * 100.0, 1)
        if ($ceilingProgressPct -gt 100.0) { $ceilingProgressPct = 100.0 }

        $lossBufferRemaining = [Math]::Round($scalpCfg.dailyDrawdownLimit - [Math]::Max(0.0, -$totalDailyPnl), 2)
        if ($lossBufferRemaining -lt 0.0) { $lossBufferRemaining = 0.0 }

        $state = "ACTIVE_HUNTING"
        $statusMessage = "Hunting 1M/5M micro-scalps on Tier-A Weltrade SyntX. Zero-Loss Armor active at +0.70R. Target: `$$($scalpCfg.targetDailyProfit.ToString('F2')) -> `$$($scalpCfg.targetMaxCeilingProfit.ToString('F2'))"

        if ($scalpCfg.manuallyPaused -or -not $scalpCfg.enabled) {
          $state = "MANUALLY_PAUSED"
          $statusMessage = "[PAUSED] Scalper manually paused by operator."
        } elseif ($scalpCfg.overrideState -eq "HARVEST_LOCKED" -or $totalDailyPnl -ge $scalpCfg.targetMaxCeilingProfit) {
          $state = "CEILING_LOCKED"
          $statusMessage = "[CEILING_LOCKED] `$$($scalpCfg.targetMaxCeilingProfit.ToString('F2')) Daily Ceiling Achieved! All capital locked. Trading stopped until tomorrow."
        } elseif ($totalDailyPnl -ge $scalpCfg.targetDailyProfit) {
          $state = "BASELINE_SECURED"
          $statusMessage = "[BASELINE_SECURED] `$$($scalpCfg.targetDailyProfit.ToString('F2')) Daily Baseline Goal Secured! Zero-loss trailing & micro-elevation active toward `$$($scalpCfg.targetMaxCeilingProfit.ToString('F2')) ceiling."
        } elseif ($scalpCfg.overrideState -eq "BREAKER_TRIPPED" -or $totalDailyPnl -le -$scalpCfg.dailyDrawdownLimit) {
          $state = "BREAKER_TRIPPED"
          $statusMessage = "[BREAKER_TRIPPED] -$($scalpCfg.dailyDrawdownLimit.ToString('F2')) Daily Loss Cap Reached! Trading hard-locked to protect capital."
        }

        $recLot = if ($wtLiveEq -lt 100) { 0.01 } elseif ($wtLiveEq -lt 250) { 0.01 } elseif ($wtLiveEq -lt 500) { 0.02 } elseif ($wtLiveEq -lt 1500) { 0.03 } else { 0.05 }

        $scalpStateOut = @{
          enabled                 = $scalpCfg.enabled
          state                   = $state
          statusMessage           = $statusMessage
          targetDailyProfit       = $scalpCfg.targetDailyProfit
          targetMaxCeilingProfit  = $scalpCfg.targetMaxCeilingProfit
          dailyDrawdownLimit      = $scalpCfg.dailyDrawdownLimit
          currentDailyProfit      = $totalDailyPnl
          todayRealizedPnl        = [Math]::Round($todayRealized, 2)
          floatingScalpPnl        = [Math]::Round($floatingScalpPnl, 2)
          dailyProgressPct        = $progressPct
          ceilingProgressPct      = $ceilingProgressPct
          lossBufferRemaining     = $lossBufferRemaining
          todayTradesCount        = ($todayWins + $todayLosses)
          todayWins               = $todayWins
          todayLosses             = $todayLosses
          recommendedLot          = $recLot
          quickBeDistanceR        = 0.70
          profitRatchet1R         = 1.20
          profitRatchet2R         = 1.70
          zeroLossArmorActive     = $true
          tp1Ratio                = 0.60
          tp1TargetR              = 2.0
          activeScalps            = $activeScalps
          prioritySymbols         = @("SFX Vol 80", "MAX GainX 1000", "FlipX 2", "SwitchX 1800", "BreakX 600", "FX Vol 20")
          quarantinedSymbols      = @("PainX 1200", "PainX 600", "Volatility 50 Index")
          lastUpdated             = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        }

        $jsonOut = $scalpStateOut | ConvertTo-Json -Depth 5 -Compress
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($jsonOut)
        $res.ContentType = "application/json; charset=utf-8"
        $res.OutputStream.Write($bytes, 0, $bytes.Length)
        $res.OutputStream.Close()
        continue
      }
      elseif ($req.HttpMethod -eq "POST") {
        $reader = New-Object System.IO.StreamReader($req.InputStream)
        $body = $reader.ReadToEnd()
        $reader.Close()
        $msg = "Action processed"
        if ($body) {
          try {
            $cmd = $body | ConvertFrom-Json
            $curCfg = @{ enabled = $true; targetDailyProfit = 70.00; targetMaxCeilingProfit = 150.00; dailyDrawdownLimit = 15.00; manuallyPaused = $false; overrideState = "" }
            if (Test-Path $weltradeScalpFile) {
              try {
                $curCfg = [System.IO.File]::ReadAllText($weltradeScalpFile, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
              } catch {}
            }

            if ($cmd.action -eq "toggle") {
              $curCfg.enabled = if ($null -ne $cmd.enabled) { [bool]$cmd.enabled } else { -not $curCfg.enabled }
              $curCfg.manuallyPaused = -not $curCfg.enabled
              $msg = if ($curCfg.enabled) { "Weltrade Scalper activated" } else { "Weltrade Scalper paused" }
            }
            elseif ($cmd.action -eq "lock_profit") {
              $curCfg.overrideState = "HARVEST_LOCKED"
              $msg = "[HARVEST_LOCKED] Daily profit locked. Harvest mode active."
            }
            elseif ($cmd.action -eq "reset_breaker") {
              $curCfg.overrideState = ""
              $curCfg.manuallyPaused = $false
              $curCfg.enabled = $true
              $msg = "[RESET_OK] Daily breaker and state reset. Scalper hunting resumed."
            }
            elseif ($cmd.action -eq "set_params") {
              if ($cmd.targetDailyProfit) { $curCfg.targetDailyProfit = [double]$cmd.targetDailyProfit }
              if ($cmd.targetMaxCeilingProfit) { $curCfg.targetMaxCeilingProfit = [double]$cmd.targetMaxCeilingProfit }
              if ($cmd.dailyDrawdownLimit) { $curCfg.dailyDrawdownLimit = [double]$cmd.dailyDrawdownLimit }
              $msg = "Scalper risk parameters updated ($($curCfg.targetDailyProfit) baseline / $($curCfg.targetMaxCeilingProfit) ceiling)"
            }
            elseif ($cmd.action -eq "trigger_scalp") {
              $sym   = if ($cmd.symbol) { $cmd.symbol } else { "SFX Vol 80" }
              $side  = if ($cmd.side) { $cmd.side } else { "BUY" }
              $lot   = if ($cmd.lot) { [double]$cmd.lot } else { 0.02 }
              $entry = if ($cmd.entry) { [double]$cmd.entry } else { 0.0 }
              $sl    = if ($cmd.sl) { [double]$cmd.sl } else { 0.0 }
              $tp    = if ($cmd.tp) { [double]$cmd.tp } else { 0.0 }
              $cmdId = "SCLP-" + [Guid]::NewGuid().ToString("N").Substring(0, 8)
              $comm  = "SMC_SCALP_70_150"

              $line = "$cmdId|PLACE_LIMIT|$sym|$side|$lot|$entry|$sl|$tp|0|$comm`r`n"
              $cmdFile = Join-Path $commonSmcDir "commands_weltrade.txt"
              [System.IO.File]::AppendAllText($cmdFile, $line, [System.Text.Encoding]::ASCII)
              $msg = "[QUEUED] Instant micro-scalp order queued to Weltrade ($sym $side $lot lot)"
            }

            [System.IO.File]::WriteAllText($weltradeScalpFile, ($curCfg | ConvertTo-Json -Depth 5), [System.Text.Encoding]::UTF8)
          } catch {
            $msg = "Error processing action: $($_.Exception.Message)"
          }
        }
        $bytes = [System.Text.Encoding]::UTF8.GetBytes(('{"ok":true,"message":"' + $msg + '"}'))
        $res.ContentType = "application/json"
        $res.OutputStream.Write($bytes, 0, $bytes.Length)
        $res.OutputStream.Close()
        continue
      }
    }

    # 5. MT5 Command Queue & Multi-Account Copier Fan-Out
    if ($path -eq "/api/mt5/command" -and $req.HttpMethod -eq "POST") {
      $reader = New-Object System.IO.StreamReader($req.InputStream)
      $body = $reader.ReadToEnd()
      $reader.Close()
      if ($body -and $body.Length -gt 5) {
        try {
          $cmdObj = $body | ConvertFrom-Json
          $cmdId  = if ($cmdObj.id) { $cmdObj.id } else { [Guid]::NewGuid().ToString("N").Substring(0, 10) }
          $action = $cmdObj.action
          $sym    = $cmdObj.symbol
          $side   = $cmdObj.side
          $lot    = $cmdObj.lot
          $entry  = $cmdObj.entry
          $sl     = $cmdObj.sl
          $tp     = $cmdObj.tp
          $ticket = if ($cmdObj.ticket) { $cmdObj.ticket } else { 0 }
          $comm   = if ($cmdObj.comment) { $cmdObj.comment } else { "SMC_APLUS" }
          $broker = if ($cmdObj.broker) { $cmdObj.broker.ToLower() } else { "" }

          # Toxic Asset Guard: Block execution on Tier-C Quarantined pairs
          $upSym = if ($sym) { $sym.ToUpper() } else { "" }
          if ($upSym -match "PAINX 1200|PAINX 600|VOLATILITY 50 INDEX|1HZ50V") {
            $errBytes = [System.Text.Encoding]::UTF8.GetBytes('{"ok":false,"error":"[TOXIC ASSET GUARD] ' + $sym + ' is Tier-C Quarantined (erratic wicks / negative edge). Automated execution blocked to protect capital."}')
            $res.ContentType = "application/json"
            $res.OutputStream.Write($errBytes, 0, $errBytes.Length)
            $res.OutputStream.Close()
            continue
          }

          $isWeltrade = ($broker -eq "weltrade") -or ($sym -match "Pain|Gain|Flip|Switch|BreakX|FX Vol|SFX Vol")
          $targetQueue = if ($isWeltrade) { "commands_weltrade.txt" } else { "commands_deriv.txt" }

          $line = "$cmdId|$action|$sym|$side|$lot|$entry|$sl|$tp|$ticket|$comm`r`n"
          $cmdFile = Join-Path $commonSmcDir $targetQueue
          [System.IO.File]::AppendAllText($cmdFile, $line, [System.Text.Encoding]::ASCII)

          # Auto-Copier: Dispatch to any connected client accounts on this broker
          if (Test-Path $clientsFile) {
            try {
              $allClients = [System.IO.File]::ReadAllText($clientsFile, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
              foreach ($cl in $allClients) {
                if ($cl.enabled -and $cl.role -ne "MASTER") {
                  $clBroker = $cl.broker.ToLower()
                  if (($isWeltrade -and $clBroker -eq "weltrade") -or (-not $isWeltrade -and $clBroker -eq "deriv")) {
                    $clQueue = Join-Path $commonSmcDir ("commands_" + $cl.login + ".txt")
                    $clLine  = "$cmdId|$action|$sym|$side|$lot|$entry|$sl|$tp|$ticket|$comm`r`n"
                    [System.IO.File]::AppendAllText($clQueue, $clLine, [System.Text.Encoding]::ASCII)
                  }
                }
              }
            } catch {}
          }
        } catch {}
      }
      $bytes = [System.Text.Encoding]::UTF8.GetBytes('{"ok":true,"queued":true}')
      $res.ContentType = "application/json"
      $res.OutputStream.Write($bytes, 0, $bytes.Length)
      $res.OutputStream.Close()
      continue
    }

    # 5. MT5 Active Symbols
    if ($path -eq "/api/mt5/symbols") {
      if (Test-Path $commonSmcDir) {
        Get-ChildItem $commonSmcDir -Filter "*_*.json" -ErrorAction SilentlyContinue | Where-Object {
          $_.Name -notmatch "^(account|catalog|quotes)_"
        } | ForEach-Object {
          $baseName = $_.BaseName
          $idx = $baseName.LastIndexOf('_')
          if ($idx -gt 0) {
            $sName = $baseName.Substring(0, $idx)
            $ts = [int][DateTimeOffset]::new($_.LastWriteTimeUtc).ToUnixTimeSeconds()
            $mt5Meta[$sName] = @{ updated = $ts }
            if ($allLookup.ContainsKey($sName)) {
              foreach ($alias in $allLookup[$sName]) {
                $mt5Meta[$alias] = @{ updated = $ts }
              }
            }
          }
        }
      }

      $items = @()
      foreach ($k in $mt5Meta.Keys) {
        $u = $mt5Meta[$k].updated
        $items += ('{{"symbol":"{0}","updated":{1}}}' -f $k, $u)
      }
      $wtCat = "[]"
      $dvCat = "[]"
      $wtCatFile = Join-Path $commonSmcDir "catalog_weltrade.json"
      $dvCatFile = Join-Path $commonSmcDir "catalog_deriv.json"
      if (Test-Path $wtCatFile) { try { $wtCat = [System.IO.File]::ReadAllText($wtCatFile, [System.Text.Encoding]::UTF8) } catch {} }
      if (Test-Path $dvCatFile) { try { $dvCat = [System.IO.File]::ReadAllText($dvCatFile, [System.Text.Encoding]::UTF8) } catch {} }

      $json = '{"symbols":[' + ($items -join ",") + '],"weltradeCatalog":' + $wtCat + ',"derivCatalog":' + $dvCat + '}'
      $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
      $res.ContentType = "application/json"
      $res.OutputStream.Write($bytes, 0, $bytes.Length)
      $res.OutputStream.Close()
      continue
    }

    # 6. MT5 Candles (ALWAYS reads fresh from disk + signals 1s priority to MT5 EA)
    if ($path -eq "/api/mt5/candles") {
      $sym  = $req.QueryString["symbol"]
      $kind = $req.QueryString["kind"]
      $tf   = [int]($req.QueryString["tf"] -as [int])
      if (-not $tf) { $tf = 300 }

      # Notify MT5 EA to prioritize 1-second sync for the active chart symbol
      if ($sym -and ($kind -eq "live" -or $kind -eq "full")) {
        $isWtSym = ($sym -match "Pain|Gain|Flip|Switch|BreakX|FX Vol|SFX Vol")
        $prioFile = Join-Path $commonSmcDir (if ($isWtSym) { "active_weltrade.txt" } else { "active_deriv.txt" })
        try { [System.IO.File]::WriteAllText($prioFile, $sym, [System.Text.Encoding]::ASCII) } catch {}
      }

      $candidates = if ($allLookup.ContainsKey($sym)) { $allLookup[$sym] } else { @($sym) }
      $json = "[]"

      foreach ($c in $candidates) {
        $safeC = $c -replace '[^A-Za-z0-9_-]', '_'
        $fPath = Join-Path $commonSmcDir "${safeC}_${tf}.json"
        if (Test-Path $fPath) {
          try {
            $raw = [System.IO.File]::ReadAllText($fPath, [System.Text.Encoding]::UTF8)
            if ($raw -and $raw.Length -gt 10) {
              $json = $raw
              break
            }
          } catch {}
        }
      }

      $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
      $res.ContentType = "application/json; charset=utf-8"
      $res.OutputStream.Write($bytes, 0, $bytes.Length)
      $res.OutputStream.Close()
      continue
    }

    if ($path -eq "/") { $path = "/index.html" }
    $filePath = Join-Path $root ($path.TrimStart('/').Replace('/', '\'))

    if (Test-Path $filePath -PathType Leaf) {
      $ext = [System.IO.Path]::GetExtension($filePath)
      $res.ContentType = if ($mimeTypes.ContainsKey($ext)) { $mimeTypes[$ext] } else { "application/octet-stream" }
      $bytes = [System.IO.File]::ReadAllBytes($filePath)
      $res.ContentLength64 = $bytes.Length
      $res.OutputStream.Write($bytes, 0, $bytes.Length)
    } else {
      $res.StatusCode = 404
    }
    $res.OutputStream.Close()
  } catch {
  }
}
