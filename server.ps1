$port = 8095
$root = "C:\Users\Administrator\.gemini\antigravity\scratch\smc-synthetics-terminal"
$ledgerFile = Join-Path $root "data\trades_ledger.json"
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

$mt5Cache = @{}
$mt5Meta  = @{}
$mt5AccountState = '{"login":0,"server":"Standby","balance":40.00,"equity":40.00,"freeMargin":40.00,"updated":0,"orders":[]}'

$commonSmcDir = "C:\Users\Administrator\AppData\Roaming\MetaQuotes\Terminal\Common\Files\smc_bridge"
$commonCrtDir = "C:\Users\Administrator\AppData\Roaming\MetaQuotes\Terminal\Common\Files\crt_bridge"
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
  "DEX 600 UP" = "DEX600UP"
  "DEX 600 DOWN" = "DEX600DN"
  "DEX 900 UP" = "DEX900UP"
  "DEX 900 DOWN" = "DEX900DN"
  "DEX 1500 UP" = "DEX1500UP"
  "DEX 1500 DOWN" = "DEX1500DN"
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
          $bytes = [System.Text.Encoding]::UTF8.GetBytes('{"account":{"startingBalance":40,"riskPct":2.5},"trades":[]}')
        }
        $res.ContentType = "application/json; charset=utf-8"
        $res.OutputStream.Write($bytes, 0, $bytes.Length)
        $res.OutputStream.Close()
        continue
      }
    }

    # 2. MT5 Account & Active Positions / Pending Orders State (Deriv #32398784 + Weltrade #43374418)
    if ($path -eq "/api/mt5/account") {
      if ($req.HttpMethod -eq "POST") {
        $reader = New-Object System.IO.StreamReader($req.InputStream)
        $body = $reader.ReadToEnd()
        $reader.Close()
        if ($body -and $body.Length -gt 10) {
          $mt5AccountState = $body
        }
        $bytes = [System.Text.Encoding]::UTF8.GetBytes('{"ok":true}')
        $res.ContentType = "application/json"
        $res.OutputStream.Write($bytes, 0, $bytes.Length)
        $res.OutputStream.Close()
        continue
      } else {
        $accDerivFile = Join-Path $commonSmcDir "account_deriv.json"
        $accWtFile    = Join-Path $commonSmcDir "account_weltrade.json"
        $accMainFile  = Join-Path $commonSmcDir "account_state.json"

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
          orders     = $combinedOrders
          deriv      = if ($derivObj) { $derivObj } else { @{ broker = "deriv"; login = 32398784; server = "Deriv-Demo"; balance = 9363.52; equity = 9363.52; freeMargin = 9363.52; updated = 0; orders = @() } }
          weltrade   = if ($wtObj)    { $wtObj }    else { @{ broker = "weltrade"; login = 43374418; server = "Weltrade-Demo"; balance = 9339.86; equity = 9366.36; freeMargin = 9366.36; updated = 0; orders = @() } }
        }

        $jsonOut = $payloadObj | ConvertTo-Json -Depth 6 -Compress
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($jsonOut)
        $res.ContentType = "application/json; charset=utf-8"
        $res.OutputStream.Write($bytes, 0, $bytes.Length)
        $res.OutputStream.Close()
        continue
      }
    }

    # 3. MT5 Command Queue (Routes to Deriv #32398784 or Weltrade #43374418)
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
        } catch {}
      }
      $bytes = [System.Text.Encoding]::UTF8.GetBytes('{"ok":true,"queued":true}')
      $res.ContentType = "application/json"
      $res.OutputStream.Write($bytes, 0, $bytes.Length)
      $res.OutputStream.Close()
      continue
    }

    # 4. MT5 Candle Push
    if ($path -eq "/api/mt5/push" -and $req.HttpMethod -eq "POST") {
      $sym = $req.QueryString["symbol"]
      $tf  = $req.QueryString["tf"]
      $reader = New-Object System.IO.StreamReader($req.InputStream)
      $body = $reader.ReadToEnd()
      $reader.Close()
      if ($sym -and $tf) {
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $candidates = if ($allLookup.ContainsKey($sym)) { $allLookup[$sym] } else { @($sym) }
        foreach ($c in $candidates) {
          $mt5Cache["$c|$tf"] = $body
          $mt5Meta[$c] = @{ updated = $now }
        }
      }
      $bytes = [System.Text.Encoding]::UTF8.GetBytes('{"ok":true}')
      $res.ContentType = "application/json"
      $res.OutputStream.Write($bytes, 0, $bytes.Length)
      $res.OutputStream.Close()
      continue
    }

    # 5. MT5 Active Symbols
    if ($path -eq "/api/mt5/symbols") {
      foreach ($dirPath in @($commonSmcDir, $commonCrtDir)) {
        if (Test-Path $dirPath) {
          Get-ChildItem $dirPath -Filter "*_*.json" -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne "account_state.json" } | ForEach-Object {
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

    # 6. MT5 Candles
    if ($path -eq "/api/mt5/candles") {
      $sym = $req.QueryString["symbol"]
      $tf  = [int]($req.QueryString["tf"] -as [int])
      if (-not $tf) { $tf = 300 }

      $candidates = if ($allLookup.ContainsKey($sym)) { $allLookup[$sym] } else { @($sym) }
      $json = "[]"

      foreach ($c in $candidates) {
        $key = "$c|$tf"
        if ($mt5Cache.ContainsKey($key)) {
          $json = $mt5Cache[$key]
          break
        }
      }

      if ($json -eq "[]") {
        foreach ($dirPath in @($commonSmcDir, $commonCrtDir)) {
          if (Test-Path $dirPath) {
            foreach ($c in $candidates) {
              $safeC = $c -replace '[^A-Za-z0-9_-]', '_'
              $fPath = Join-Path $dirPath "${safeC}_${tf}.json"
              if (Test-Path $fPath) {
                try {
                  $json = [System.IO.File]::ReadAllText($fPath, [System.Text.Encoding]::UTF8)
                  $mt5Cache["$sym|$tf"] = $json
                  break
                } catch {}
              }
            }
          }
          if ($json -ne "[]") { break }
        }
      }

      $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
      $res.ContentType = "application/json"
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
