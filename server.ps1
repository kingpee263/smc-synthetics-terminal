$port = 8095
$root = "C:\Users\Administrator\.gemini\antigravity\scratch\smc-synthetics-terminal"
$ledgerFile  = Join-Path $root "data\trades_ledger.json"
$clientsFile = Join-Path $root "data\client_accounts.json"
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
