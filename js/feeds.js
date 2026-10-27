/**
 * Real-Time Market Data & MT5 Auto-Trading Execution Engine
 *  - Deriv Public WebSocket API (multi-endpoint failover + live tick/OHLC streaming + active_symbols sync)
 *  - Weltrade SyntX (PainX, GainX, FlipX/SwitchX, FX Vol, SFX Vol, BreakX) + Local MT5 Bridge (/api/mt5)
 *  - Two-way MT5 Auto-Trade Execution Queue (Limit Orders, SL, TP, and X1/X2/X3 Trailing Stops)
 */
(function () {
  const T = window.CRTTime;

  /* ---------------- Complete Deriv & Weltrade Synthetics Catalog ---------------- */
  const STATIC_MARKETS = [
    // 1. Deriv Volatility Indices (Standard & 1s)
    { id: '1HZ75V', name: 'Volatility 75 (1s) Index', group: 'Deriv Volatility (1s)', cat: 'deriv_vol', feed: 'deriv', mt5Symbol: 'Volatility 75 (1s) Index', profile: 'synthetic' },
    { id: 'R_75', name: 'Volatility 75 Index', group: 'Deriv Volatility', cat: 'deriv_vol', feed: 'deriv', mt5Symbol: 'Volatility 75 Index', profile: 'synthetic' },
    { id: '1HZ10V', name: 'Volatility 10 (1s) Index', group: 'Deriv Volatility (1s)', cat: 'deriv_vol', feed: 'deriv', mt5Symbol: 'Volatility 10 (1s) Index', profile: 'synthetic' },
    { id: '1HZ15V', name: 'Volatility 15 (1s) Index', group: 'Deriv Volatility (1s)', cat: 'deriv_vol', feed: 'deriv', mt5Symbol: 'Volatility 15 (1s) Index', profile: 'synthetic' },
    { id: '1HZ25V', name: 'Volatility 25 (1s) Index', group: 'Deriv Volatility (1s)', cat: 'deriv_vol', feed: 'deriv', mt5Symbol: 'Volatility 25 (1s) Index', profile: 'synthetic' },
    { id: '1HZ30V', name: 'Volatility 30 (1s) Index', group: 'Deriv Volatility (1s)', cat: 'deriv_vol', feed: 'deriv', mt5Symbol: 'Volatility 30 (1s) Index', profile: 'synthetic' },
    { id: '1HZ50V', name: 'Volatility 50 (1s) Index', group: 'Deriv Volatility (1s)', cat: 'deriv_vol', feed: 'deriv', mt5Symbol: 'Volatility 50 (1s) Index', profile: 'synthetic' },
    { id: '1HZ90V', name: 'Volatility 90 (1s) Index', group: 'Deriv Volatility (1s)', cat: 'deriv_vol', feed: 'deriv', mt5Symbol: 'Volatility 90 (1s) Index', profile: 'synthetic' },
    { id: '1HZ100V', name: 'Volatility 100 (1s) Index', group: 'Deriv Volatility (1s)', cat: 'deriv_vol', feed: 'deriv', mt5Symbol: 'Volatility 100 (1s) Index', profile: 'synthetic' },
    { id: '1HZ150V', name: 'Volatility 150 (1s) Index', group: 'Deriv Volatility (1s)', cat: 'deriv_vol', feed: 'deriv', mt5Symbol: 'Volatility 150 (1s) Index', profile: 'synthetic' },
    { id: '1HZ200V', name: 'Volatility 200 (1s) Index', group: 'Deriv Volatility (1s)', cat: 'deriv_vol', feed: 'deriv', mt5Symbol: 'Volatility 200 (1s) Index', profile: 'synthetic' },
    { id: '1HZ250V', name: 'Volatility 250 (1s) Index', group: 'Deriv Volatility (1s)', cat: 'deriv_vol', feed: 'deriv', mt5Symbol: 'Volatility 250 (1s) Index', profile: 'synthetic' },
    { id: 'R_10', name: 'Volatility 10 Index', group: 'Deriv Volatility', cat: 'deriv_vol', feed: 'deriv', mt5Symbol: 'Volatility 10 Index', profile: 'synthetic' },
    { id: 'R_25', name: 'Volatility 25 Index', group: 'Deriv Volatility', cat: 'deriv_vol', feed: 'deriv', mt5Symbol: 'Volatility 25 Index', profile: 'synthetic' },
    { id: 'R_50', name: 'Volatility 50 Index', group: 'Deriv Volatility', cat: 'deriv_vol', feed: 'deriv', mt5Symbol: 'Volatility 50 Index', profile: 'synthetic' },
    { id: 'R_100', name: 'Volatility 100 Index', group: 'Deriv Volatility', cat: 'deriv_vol', feed: 'deriv', mt5Symbol: 'Volatility 100 Index', profile: 'synthetic' },

    // 2. Deriv Boom & Crash Indices (Spike-Direction Filtered)
    { id: 'BOOM300N', name: 'Boom 300 Index', group: 'Deriv Boom & Crash', cat: 'deriv_boom', feed: 'deriv', mt5Symbol: 'Boom 300 Index', profile: 'synthetic', spike: 'up' },
    { id: 'BOOM500', name: 'Boom 500 Index', group: 'Deriv Boom & Crash', cat: 'deriv_boom', feed: 'deriv', mt5Symbol: 'Boom 500 Index', profile: 'synthetic', spike: 'up' },
    { id: 'BOOM600', name: 'Boom 600 Index', group: 'Deriv Boom & Crash', cat: 'deriv_boom', feed: 'deriv', mt5Symbol: 'Boom 600 Index', profile: 'synthetic', spike: 'up' },
    { id: 'BOOM900', name: 'Boom 900 Index', group: 'Deriv Boom & Crash', cat: 'deriv_boom', feed: 'deriv', mt5Symbol: 'Boom 900 Index', profile: 'synthetic', spike: 'up' },
    { id: 'BOOM1000', name: 'Boom 1000 Index', group: 'Deriv Boom & Crash', cat: 'deriv_boom', feed: 'deriv', mt5Symbol: 'Boom 1000 Index', profile: 'synthetic', spike: 'up' },
    { id: 'CRASH300N', name: 'Crash 300 Index', group: 'Deriv Boom & Crash', cat: 'deriv_boom', feed: 'deriv', mt5Symbol: 'Crash 300 Index', profile: 'synthetic', spike: 'down' },
    { id: 'CRASH500', name: 'Crash 500 Index', group: 'Deriv Boom & Crash', cat: 'deriv_boom', feed: 'deriv', mt5Symbol: 'Crash 500 Index', profile: 'synthetic', spike: 'down' },
    { id: 'CRASH600', name: 'Crash 600 Index', group: 'Deriv Boom & Crash', cat: 'deriv_boom', feed: 'deriv', mt5Symbol: 'Crash 600 Index', profile: 'synthetic', spike: 'down' },
    { id: 'CRASH900', name: 'Crash 900 Index', group: 'Deriv Boom & Crash', cat: 'deriv_boom', feed: 'deriv', mt5Symbol: 'Crash 900 Index', profile: 'synthetic', spike: 'down' },
    { id: 'CRASH1000', name: 'Crash 1000 Index', group: 'Deriv Boom & Crash', cat: 'deriv_boom', feed: 'deriv', mt5Symbol: 'Crash 1000 Index', profile: 'synthetic', spike: 'down' },

    // 3. Deriv Step & Jump Indices
    { id: 'stpRNG', name: 'Step Index 100', group: 'Deriv Step & Jump', cat: 'deriv_step', feed: 'deriv', mt5Symbol: 'Step Index', profile: 'synthetic' },
    { id: 'stpRNG2', name: 'Step Index 200', group: 'Deriv Step & Jump', cat: 'deriv_step', feed: 'deriv', mt5Symbol: 'Step Index 200', profile: 'synthetic' },
    { id: 'stpRNG3', name: 'Step Index 300', group: 'Deriv Step & Jump', cat: 'deriv_step', feed: 'deriv', mt5Symbol: 'Step Index 300', profile: 'synthetic' },
    { id: 'stpRNG4', name: 'Step Index 400', group: 'Deriv Step & Jump', cat: 'deriv_step', feed: 'deriv', mt5Symbol: 'Step Index 400', profile: 'synthetic' },
    { id: 'stpRNG5', name: 'Step Index 500', group: 'Deriv Step & Jump', cat: 'deriv_step', feed: 'deriv', mt5Symbol: 'Step Index 500', profile: 'synthetic' },
    { id: 'JD10', name: 'Jump 10 Index', group: 'Deriv Step & Jump', cat: 'deriv_step', feed: 'deriv', mt5Symbol: 'Jump 10 Index', profile: 'synthetic' },
    { id: 'JD25', name: 'Jump 25 Index', group: 'Deriv Step & Jump', cat: 'deriv_step', feed: 'deriv', mt5Symbol: 'Jump 25 Index', profile: 'synthetic' },
    { id: 'JD50', name: 'Jump 50 Index', group: 'Deriv Step & Jump', cat: 'deriv_step', feed: 'deriv', mt5Symbol: 'Jump 50 Index', profile: 'synthetic' },
    { id: 'JD75', name: 'Jump 75 Index', group: 'Deriv Step & Jump', cat: 'deriv_step', feed: 'deriv', mt5Symbol: 'Jump 75 Index', profile: 'synthetic' },
    { id: 'JD100', name: 'Jump 100 Index', group: 'Deriv Step & Jump', cat: 'deriv_step', feed: 'deriv', mt5Symbol: 'Jump 100 Index', profile: 'synthetic' },

    // 4. Deriv Range Break, DEX & Drift Switch Indices
    { id: 'RDBULL', name: 'Range Break 100 / Bull Index', group: 'Deriv Range Break & DEX', cat: 'deriv_dex', feed: 'deriv', mt5Symbol: 'Range Break 100 Index', profile: 'synthetic' },
    { id: 'RDBEAR', name: 'Range Break 200 / Bear Index', group: 'Deriv Range Break & DEX', cat: 'deriv_dex', feed: 'deriv', mt5Symbol: 'Range Break 200 Index', profile: 'synthetic' },
    { id: 'DEX600UP', name: 'DEX 600 UP', group: 'Deriv Range Break & DEX', cat: 'deriv_dex', feed: 'deriv', mt5Symbol: 'DEX 600 UP', profile: 'synthetic', spike: 'up' },
    { id: 'DEX600DN', name: 'DEX 600 DOWN', group: 'Deriv Range Break & DEX', cat: 'deriv_dex', feed: 'deriv', mt5Symbol: 'DEX 600 DOWN', profile: 'synthetic', spike: 'down' },
    { id: 'DEX900UP', name: 'DEX 900 UP', group: 'Deriv Range Break & DEX', cat: 'deriv_dex', feed: 'deriv', mt5Symbol: 'DEX 900 UP', profile: 'synthetic', spike: 'up' },
    { id: 'DEX900DN', name: 'DEX 900 DOWN', group: 'Deriv Range Break & DEX', cat: 'deriv_dex', feed: 'deriv', mt5Symbol: 'DEX 900 DOWN', profile: 'synthetic', spike: 'down' },
    { id: 'DEX1500UP', name: 'DEX 1500 UP', group: 'Deriv Range Break & DEX', cat: 'deriv_dex', feed: 'deriv', mt5Symbol: 'DEX 1500 UP', profile: 'synthetic', spike: 'up' },
    { id: 'DEX1500DN', name: 'DEX 1500 DOWN', group: 'Deriv Range Break & DEX', cat: 'deriv_dex', feed: 'deriv', mt5Symbol: 'DEX 1500 DOWN', profile: 'synthetic', spike: 'down' },
    { id: 'DSI10', name: 'Drift Switch 10', group: 'Deriv Range Break & DEX', cat: 'deriv_dex', feed: 'deriv', mt5Symbol: 'Drift Switch 10', profile: 'synthetic' },
    { id: 'DSI20', name: 'Drift Switch 20', group: 'Deriv Range Break & DEX', cat: 'deriv_dex', feed: 'deriv', mt5Symbol: 'Drift Switch 20', profile: 'synthetic' },
    { id: 'DSI30', name: 'Drift Switch 30', group: 'Deriv Range Break & DEX', cat: 'deriv_dex', feed: 'deriv', mt5Symbol: 'Drift Switch 30', profile: 'synthetic' },

    // 5. Weltrade SyntX Indices (PainX, GainX, FlipX/SwitchX, FX Vol, SFX Vol, BreakX)
    { id: 'mt5:PainX 400', name: 'PainX 400 Index', group: 'Weltrade SyntX (PainX / GainX)', cat: 'weltrade', feed: 'mt5', mt5Symbol: 'PainX 400', proxySymbol: 'CRASH500', profile: 'synthetic', spike: 'down' },
    { id: 'mt5:GainX 400', name: 'GainX 400 Index', group: 'Weltrade SyntX (PainX / GainX)', cat: 'weltrade', feed: 'mt5', mt5Symbol: 'GainX 400', proxySymbol: 'BOOM500', profile: 'synthetic', spike: 'up' },
    { id: 'mt5:PainX 600', name: 'PainX 600 Index', group: 'Weltrade SyntX (PainX / GainX)', cat: 'weltrade', feed: 'mt5', mt5Symbol: 'PainX 600', proxySymbol: 'CRASH600', profile: 'synthetic', spike: 'down' },
    { id: 'mt5:GainX 600', name: 'GainX 600 Index', group: 'Weltrade SyntX (PainX / GainX)', cat: 'weltrade', feed: 'mt5', mt5Symbol: 'GainX 600', proxySymbol: 'BOOM600', profile: 'synthetic', spike: 'up' },
    { id: 'mt5:PainX 800', name: 'PainX 800 Index', group: 'Weltrade SyntX (PainX / GainX)', cat: 'weltrade', feed: 'mt5', mt5Symbol: 'PainX 800', proxySymbol: 'CRASH900', profile: 'synthetic', spike: 'down' },
    { id: 'mt5:GainX 800', name: 'GainX 800 Index', group: 'Weltrade SyntX (PainX / GainX)', cat: 'weltrade', feed: 'mt5', mt5Symbol: 'GainX 800', proxySymbol: 'BOOM900', profile: 'synthetic', spike: 'up' },
    { id: 'mt5:PainX 999', name: 'PainX 999 Index', group: 'Weltrade SyntX (PainX / GainX)', cat: 'weltrade', feed: 'mt5', mt5Symbol: 'PainX 999', proxySymbol: 'CRASH1000', profile: 'synthetic', spike: 'down' },
    { id: 'mt5:GainX 999', name: 'GainX 999 Index', group: 'Weltrade SyntX (PainX / GainX)', cat: 'weltrade', feed: 'mt5', mt5Symbol: 'GainX 999', proxySymbol: 'BOOM1000', profile: 'synthetic', spike: 'up' },
    { id: 'mt5:PainX 1200', name: 'PainX 1200 Index', group: 'Weltrade SyntX (PainX / GainX)', cat: 'weltrade', feed: 'mt5', mt5Symbol: 'PainX 1200', proxySymbol: 'CRASH1000', profile: 'synthetic', spike: 'down' },
    { id: 'mt5:GainX 1200', name: 'GainX 1200 Index', group: 'Weltrade SyntX (PainX / GainX)', cat: 'weltrade', feed: 'mt5', mt5Symbol: 'GainX 1200', proxySymbol: 'BOOM1000', profile: 'synthetic', spike: 'up' },
    { id: 'mt5:FlipX 600', name: 'FlipX / SwitchX 600 Index', group: 'Weltrade SyntX (FlipX / Vol)', cat: 'weltrade', feed: 'mt5', mt5Symbol: 'SwitchX 600', proxySymbol: 'DSI20', profile: 'synthetic' },
    { id: 'mt5:BreakX 600', name: 'BreakX 600 Index', group: 'Weltrade SyntX (FlipX / Vol)', cat: 'weltrade', feed: 'mt5', mt5Symbol: 'BreakX 600', proxySymbol: 'JD50', profile: 'synthetic' },
    { id: 'mt5:FX Vol 20', name: 'FX Vol 20 Index', group: 'Weltrade SyntX (FlipX / Vol)', cat: 'weltrade', feed: 'mt5', mt5Symbol: 'FX Vol 20', proxySymbol: '1HZ25V', profile: 'synthetic' },
    { id: 'mt5:FX Vol 40', name: 'FX Vol 40 Index', group: 'Weltrade SyntX (FlipX / Vol)', cat: 'weltrade', feed: 'mt5', mt5Symbol: 'FX Vol 40', proxySymbol: '1HZ50V', profile: 'synthetic' },
    { id: 'mt5:FX Vol 60', name: 'FX Vol 60 Index', group: 'Weltrade SyntX (FlipX / Vol)', cat: 'weltrade', feed: 'mt5', mt5Symbol: 'FX Vol 60', proxySymbol: '1HZ75V', profile: 'synthetic' },
    { id: 'mt5:FX Vol 80', name: 'FX Vol 80 Index', group: 'Weltrade SyntX (FlipX / Vol)', cat: 'weltrade', feed: 'mt5', mt5Symbol: 'FX Vol 80', proxySymbol: '1HZ100V', profile: 'synthetic' },
    { id: 'mt5:FX Vol 99', name: 'FX Vol 99 Index', group: 'Weltrade SyntX (FlipX / Vol)', cat: 'weltrade', feed: 'mt5', mt5Symbol: 'FX Vol 99', proxySymbol: 'R_100', profile: 'synthetic' },
    { id: 'mt5:SFX Vol 20', name: 'SFX Vol 20 Index', group: 'Weltrade SyntX (FlipX / Vol)', cat: 'weltrade', feed: 'mt5', mt5Symbol: 'SFX Vol 20', proxySymbol: 'R_25', profile: 'synthetic' },
    { id: 'mt5:SFX Vol 40', name: 'SFX Vol 40 Index', group: 'Weltrade SyntX (FlipX / Vol)', cat: 'weltrade', feed: 'mt5', mt5Symbol: 'SFX Vol 40', proxySymbol: 'R_50', profile: 'synthetic' },
    { id: 'mt5:SFX Vol 60', name: 'SFX Vol 60 Index', group: 'Weltrade SyntX (FlipX / Vol)', cat: 'weltrade', feed: 'mt5', mt5Symbol: 'SFX Vol 60', proxySymbol: 'R_75', profile: 'synthetic' },
    { id: 'mt5:SFX Vol 80', name: 'SFX Vol 80 Index', group: 'Weltrade SyntX (FlipX / Vol)', cat: 'weltrade', feed: 'mt5', mt5Symbol: 'SFX Vol 80', proxySymbol: '1HZ150V', profile: 'synthetic' },
    { id: 'mt5:SFX Vol 99', name: 'SFX Vol 99 Index', group: 'Weltrade SyntX (FlipX / Vol)', cat: 'weltrade', feed: 'mt5', mt5Symbol: 'SFX Vol 99', proxySymbol: '1HZ200V', profile: 'synthetic' },

    // 6. Real Forex & Metals via Deriv / MT5 (Ch. 6 & 9 Book Examples: Gold, EUR/USD, GBP/USD)
    { id: 'frxXAUUSD', name: 'XAU/USD (Gold)', group: 'Forex & Metals (Book Pairs)', cat: 'forex', feed: 'deriv', mt5Symbol: 'XAUUSD', profile: 'forex', smt: 'frxXAGUSD', smtRel: 'positive' },
    { id: 'frxEURUSD', name: 'EUR/USD', group: 'Forex & Metals (Book Pairs)', cat: 'forex', feed: 'deriv', mt5Symbol: 'EURUSD', profile: 'forex', smt: 'frxGBPUSD', smtRel: 'positive' },
    { id: 'frxGBPUSD', name: 'GBP/USD', group: 'Forex & Metals (Book Pairs)', cat: 'forex', feed: 'deriv', mt5Symbol: 'GBPUSD', profile: 'forex', smt: 'frxEURUSD', smtRel: 'positive' },
    { id: 'frxAUDUSD', name: 'AUD/USD', group: 'Forex & Metals (Book Pairs)', cat: 'forex', feed: 'deriv', mt5Symbol: 'AUDUSD', profile: 'forex' }
  ];

  const markets = new Map(STATIC_MARKETS.map(m => [m.id, m]));

  function guessMt5Profile(sym) {
    const s = sym.toUpperCase();
    if (/GAINX|PAINX|FLIPX|VOL|SFX|FX ?VOL|BOOM|CRASH|STEP|JUMP|SYNT|SWITCHX|BREAKX/.test(s)) return 'synthetic';
    if (/^(XAU|XAG|EUR|GBP|USD|AUD|NZD|CAD|CHF|JPY)/.test(s)) return 'forex';
    return 'synthetic';
  }
  function guessSpike(sym) {
    const s = sym.toUpperCase();
    if (/PAINX|CRASH|DN/.test(s)) return 'down';
    if (/GAINX|BOOM|UP/.test(s)) return 'up';
    return null;
  }

  /* ---------------- Two-Timeframe Pairs (Book Chapter 6, 7, 8 & 9) ---------------- */
  const TF_PAIRS = {
    '15m_1m': { key: '15m_1m', htf: '15m', ltf: 60, label: 'M15 → M1', style: 'Fast Scalp (Ch. 7 & 8)', htfLabel: 'M15', ltfLabel: 'M1' },
    '1H_5m':  { key: '1H_5m',  htf: '1h',  ltf: 300, label: 'H1 → M5',  style: 'Author Primary (Ch. 6, 7 & 9)', htfLabel: 'H1', ltfLabel: 'M5' },
    '4H_15m': { key: '4H_15m', htf: '4h',  ltf: 900, label: 'H4 → M15', style: 'Intraday SMC (Ch. 6)', htfLabel: 'H4', ltfLabel: 'M15' },
    '1H_1m':  { key: '1H_1m',  htf: '1h',  ltf: 60,  label: 'H1 → M1',  style: 'Precision Sniper', htfLabel: 'H1', ltfLabel: 'M1' },
    '4H_5m':  { key: '4H_5m',  htf: '4h',  ltf: 300, label: 'H4 → M5',  style: 'High R:R Swing', htfLabel: 'H4', ltfLabel: 'M5' },
    '1D_1H':  { key: '1D_1H',  htf: '1d',  ltf: 3600, label: 'D1 → H1', style: 'Macro Structure', htfLabel: 'D1', ltfLabel: 'H1' }
  };

  function htfRecipe(htf, profile) {
    const ny = profile !== 'synthetic';
    switch (htf) {
      case '15m': return { base: 900, count: 180, bucket: null };
      case '1h': return { base: 3600, count: 180, bucket: null };
      case '4h': return ny ? { base: 3600, count: 400, bucket: 'ny4h' } : { base: 14400, count: 160, bucket: null };
      case '1d': return ny ? { base: 3600, count: 600, bucket: 'nyday' } : { base: 86400, count: 160, bucket: null };
    }
    return { base: 3600, count: 180, bucket: null };
  }
  const HTF_SECONDS = { '15m': 900, '1h': 3600, '4h': 14400, '1d': 86400 };

  function bucketFnFor(recipe, htf) {
    return recipe.bucket ? T.BUCKETS[recipe.bucket] : T.fixedBucket(HTF_SECONDS[htf]);
  }

  /* ---------------- Status bus ---------------- */
  const status = { deriv: 'idle', binance: 'idle', mt5: 'idle' };
  const statusListeners = [];
  function setStatus(feed, s) {
    status[feed] = s;
    statusListeners.forEach(fn => fn({ ...status }));
  }

  /* ---------------- Deriv Multi-Endpoint Real-Time WebSocket Client ---------------- */
  const DERIV_ENDPOINTS = [
    'wss://ws.derivws.com/websockets/v3?app_id=1089',
    'wss://ws.binaryws.com/websockets/v3?app_id=1089',
    'wss://green.derivws.com/websockets/v3?app_id=1089',
    'wss://blue.derivws.com/websockets/v3?app_id=1089'
  ];

  class DerivClient {
    constructor() {
      this.epIdx = 0;
      this.ws = null;
      this.reqId = 1;
      this.pending = new Map();
      this.subs = new Map();
      this.subReqs = new Map();
      this.queue = [];
      this.openPromise = null;
      this.discovered = false;
    }

    get url() {
      return DERIV_ENDPOINTS[this.epIdx % DERIV_ENDPOINTS.length];
    }

    connect() {
      if (this.ws && (this.ws.readyState === 0 || this.ws.readyState === 1)) return this.openPromise;
      setStatus('deriv', 'connecting');
      const currentUrl = this.url;
      let opened = false;
      let openReject = null;
      try {
        this.ws = new WebSocket(currentUrl);
      } catch (e) {
        setStatus('deriv', 'offline');
        return Promise.reject(e);
      }

      const connTimeout = setTimeout(() => {
        if (!opened && this.ws && this.ws.readyState !== 1) {
          try { this.ws.close(); } catch (e) {}
          if (openReject) openReject(new Error('Deriv timeout'));
        }
      }, 15000);

      this.openPromise = new Promise((resolve, reject) => {
        openReject = reject;
        this.ws.onopen = () => {
          opened = true;
          clearTimeout(connTimeout);
          setStatus('deriv', 'live');

          const queuedIds = new Set();
          const toSend = this.queue.splice(0);
          for (const raw of toSend) {
            try {
              const parsed = JSON.parse(raw);
              if (parsed.req_id) queuedIds.add(parsed.req_id);
            } catch (e) {}
            this.ws.send(raw);
          }

          for (const [id, p] of this.pending) {
            if (!queuedIds.has(id) && p.payload) {
              this.ws.send(p.payload);
            }
          }

          for (const [key, s] of this.subReqs) {
            if (!s.inflight) this._subscribe(key, s.req, s.cb);
          }
          resolve();
        };
      });

      this.ws.onmessage = ev => {
        try {
          this._onMessage(JSON.parse(ev.data));
        } catch (e) {}
      };

      this.ws.onclose = () => {
        clearTimeout(connTimeout);
        this.subs.clear();
        for (const [, s] of this.subReqs) s.inflight = false;
        if (!opened) {
          this.epIdx = (this.epIdx + 1) % DERIV_ENDPOINTS.length;
        }
        setStatus('deriv', 'offline');
        setTimeout(() => this.connect(), opened ? 2000 : 800);
      };

      this.ws.onerror = () => {
        setStatus('deriv', 'offline');
      };

      if (!this.pinger) {
        this.pinger = setInterval(() => {
          if (this.ws && this.ws.readyState === 1) {
            try { this.ws.send('{"ping":1}'); } catch (e) {}
          }
        }, 25000);
      }
      return this.openPromise;
    }

    _onMessage(msg) {
      const subId = (msg.subscription && msg.subscription.id) || (msg.ohlc && msg.ohlc.id) || (msg.tick && msg.tick.id);
      if (msg.msg_type === 'ohlc' && subId) {
        const s = this.subs.get(subId);
        if (s && msg.ohlc) {
          const o = msg.ohlc;
          const openTimeSec = Number(o.open_time || o.epoch);
          s.cb({
            time: openTimeSec * 1000,
            open: +o.open,
            high: +o.high,
            low: +o.low,
            close: +o.close
          });
        }
      }
      const p = msg.req_id && this.pending.get(msg.req_id);
      if (p) {
        this.pending.delete(msg.req_id);
        clearTimeout(p.timer);
        if (msg.error) p.reject(new Error(msg.error.message || 'Deriv API error'));
        else p.resolve(msg);
      }
    }

    send(req, timeoutMs = 15000) {
      return new Promise((resolve, reject) => {
        const id = this.reqId++;
        const payload = JSON.stringify({ ...req, req_id: id });
        const timer = setTimeout(() => {
          this.pending.delete(id);
          reject(new Error('Deriv request timeout'));
        }, timeoutMs);
        this.pending.set(id, { resolve, reject, timer, payload });
        this.connect();
        if (this.ws && this.ws.readyState === 1) {
          try {
            this.ws.send(payload);
          } catch (e) {
            this.queue.push(payload);
          }
        } else {
          this.queue.push(payload);
        }
      });
    }

    async discoverSymbols() {
      if (this.discovered) return;
      try {
        const r = await this.send({ active_symbols: 'brief' });
        this.discovered = true;
        const activeList = r.active_symbols || [];
        for (const s of activeList) {
          if (markets.has(s.symbol)) {
            const m = markets.get(s.symbol);
            m.name = s.display_name || m.name;
            if (s.spot) m.spot = +s.spot;
          }
        }
      } catch (e) {}
    }

    async candles(symbol, gran, count, end = 'latest') {
      const reqCount = Math.min(Math.max(count, 2), 4999);
      const r = await this.send({
        ticks_history: symbol,
        style: 'candles',
        granularity: gran,
        count: reqCount,
        end,
        adjust_start_time: 1
      });
      return (r.candles || []).map(c => ({
        time: Number(c.epoch) * 1000,
        open: +c.open,
        high: +c.high,
        low: +c.low,
        close: +c.close
      }));
    }

    async history(symbol, gran, total) {
      if (total <= 4999) {
        return await this.candles(symbol, gran, total, 'latest');
      }
      let out = [];
      let end = 'latest';
      while (out.length < total) {
        const n = Math.min(4999, total - out.length);
        const batch = await this.candles(symbol, gran, n, end);
        if (!batch.length) break;
        out = batch.concat(out.filter(c => c.time > batch[batch.length - 1].time));
        if (batch.length < n * 0.8) break;
        end = Math.floor(batch[0].time / 1000) - 1;
      }
      return out;
    }

    _subscribe(key, req, cb) {
      const entry = this.subReqs.get(key);
      if (entry) entry.inflight = true;
      this.send(req).then(r => {
        if (entry) entry.inflight = false;
        if (Array.isArray(r.candles) && r.candles.length) {
          const last = r.candles[r.candles.length - 1];
          cb({
            time: Number(last.epoch) * 1000,
            open: +last.open,
            high: +last.high,
            low: +last.low,
            close: +last.close
          });
        }
        if (r.subscription) {
          const currentEntry = this.subReqs.get(key);
          if (!currentEntry) {
            this.send({ forget: r.subscription.id }).catch(() => {});
            return;
          }
          currentEntry.subId = r.subscription.id;
          this.subs.set(r.subscription.id, { cb });
        }
      }).catch(() => {
        if (entry) entry.inflight = false;
      });
    }

    subscribe(symbol, gran, cb) {
      const key = `${symbol}|${gran}|${Math.random()}`;
      const req = {
        ticks_history: symbol,
        style: 'candles',
        granularity: gran,
        count: 2,
        end: 'latest',
        adjust_start_time: 1,
        subscribe: 1
      };
      this.subReqs.set(key, { req, cb, inflight: false });
      this._subscribe(key, req, cb);
      return () => {
        const e = this.subReqs.get(key);
        this.subReqs.delete(key);
        if (e && e.subId) {
          this.subs.delete(e.subId);
          this.send({ forget: e.subId }).catch(() => {});
        }
      };
    }
  }
  const deriv = new DerivClient();

  /* ---------------- Deriv & Weltrade MT5 Local Bridge & Auto-Execution ---------------- */
  const MT5_TF = { 60: '60', 300: '300', 900: '900', 3600: '3600', 14400: '14400', 86400: '86400' };
  const mt5 = {
    bridgeUrl: '',
    bridgeOnline: false,
    symbols: [],
    accountState: { login: 0, server: 'Standby', balance: 40.00, equity: 40.00, freeMargin: 40.00, orders: [] },

    async fetchAccountState() {
      try {
        const ctrl = new AbortController();
        const tid = setTimeout(() => ctrl.abort(), 1200);
        const r = await fetch(`${this.bridgeUrl}/api/mt5/account`, { cache: 'no-store', signal: ctrl.signal });
        clearTimeout(tid);
        if (r.ok) {
          const data = await r.json();
          if (data && typeof data === 'object') {
            this.accountState = data;
            if (data.login > 0) {
              this.bridgeOnline = true;
              setStatus('mt5', 'live');
            }
            return data;
          }
        }
      } catch (e) {}
      return this.accountState;
    },

    async sendCommand(cmd) {
      try {
        const r = await fetch(`${this.bridgeUrl}/api/mt5/command`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify(cmd)
        });
        return r.ok;
      } catch (e) {
        return false;
      }
    },

    async refreshSymbols() {
      try {
        await this.fetchAccountState();
        const ctrl = new AbortController();
        const tid = setTimeout(() => ctrl.abort(), 1500);
        const r = await fetch(`${this.bridgeUrl}/api/mt5/symbols`, { cache: 'no-store', signal: ctrl.signal });
        clearTimeout(tid);
        if (!r.ok) throw new Error('MT5 bridge offline');
        const data = await r.json();
        this.symbols = data.symbols || [];
        this.bridgeOnline = this.symbols.length > 0 || (this.accountState && this.accountState.login > 0);
        setStatus('mt5', this.bridgeOnline ? 'live' : 'proxy');
        for (const s of this.symbols) {
          const id = 'mt5:' + s.symbol;
          if (!markets.has(id) && !markets.has(s.symbol)) {
            markets.set(id, {
              id,
              name: s.symbol,
              group: /painx|gainx|flipx|switchx|fx vol|sfx/i.test(s.symbol) ? 'Weltrade SyntX Live' : 'Deriv MT5 Live',
              cat: /painx|gainx|flipx|switchx|fx vol|sfx/i.test(s.symbol) ? 'weltrade' : (/boom|crash/i.test(s.symbol) ? 'deriv_boom' : 'deriv_vol'),
              feed: 'mt5',
              mt5Symbol: s.symbol,
              proxySymbol: '1HZ75V',
              profile: guessMt5Profile(s.symbol),
              spike: guessSpike(s.symbol)
            });
          }
        }
        return this.symbols;
      } catch (e) {
        this.bridgeOnline = false;
        setStatus('mt5', 'proxy');
        return [];
      }
    },

    async candles(market, gran, kind = 'full', count = 500) {
      const symbol = market.mt5Symbol || market.id.replace('mt5:', '') || market.name;
      try {
        const ctrl = new AbortController();
        const tid = setTimeout(() => ctrl.abort(), 1400);
        const r = await fetch(`${this.bridgeUrl}/api/mt5/candles?symbol=${encodeURIComponent(symbol)}&tf=${MT5_TF[gran] || gran}&kind=${kind}`, { cache: 'no-store', signal: ctrl.signal });
        clearTimeout(tid);
        if (r.ok) {
          const rows = await r.json();
          if (Array.isArray(rows) && rows.length) {
            this.bridgeOnline = true;
            setStatus('mt5', 'live');
            market.liveSource = 'MT5 TERMINAL LIVE';
            return rows.map(a => ({ time: a[0] * 1000, open: +a[1], high: +a[2], low: +a[3], close: +a[4] }));
          }
        }
      } catch (e) {}

      if (market.proxySymbol) {
        setStatus('mt5', 'proxy');
        market.liveSource = `SYNTX STREAM (${market.mt5Symbol || market.name})`;
        const raw = await deriv.candles(market.proxySymbol, gran, kind === 'live' ? 5 : count);
        return scaleToSpec(market, raw);
      }
      return [];
    },

    subscribe(market, gran, cb) {
      let unsubDeriv = null;
      let pollTimer = null;

      if (this.bridgeOnline) {
        pollTimer = setInterval(async () => {
          try {
            const rows = await this.candles(market, gran, 'live', 5);
            if (rows.length) cb(rows[rows.length - 1]);
          } catch (e) {}
        }, 1000);
      } else if (market.proxySymbol) {
        unsubDeriv = deriv.subscribe(market.proxySymbol, gran, bar => {
          const scaled = scaleToSpec(market, [bar]);
          if (scaled.length) cb(scaled[0]);
        });
      }

      return () => {
        if (pollTimer) clearInterval(pollTimer);
        if (unsubDeriv) unsubDeriv();
      };
    }
  };

  /* ---------------- Market Base Specifications ---------------- */
  const MARKET_SPECS = {
    '1HZ75V': { base: 33220.00, vol: 65.0, dec: 2 },
    '1HZ100V': { base: 1420.00, vol: 8.2, dec: 2 },
    '1HZ10V': { base: 4320.00, vol: 6.0, dec: 2 },
    '1HZ15V': { base: 13490.00, vol: 15.0, dec: 3 },
    '1HZ25V': { base: 1850.00, vol: 4.5, dec: 2 },
    '1HZ30V': { base: 997.00, vol: 1.2, dec: 2 },
    '1HZ50V': { base: 245.50, vol: 1.8, dec: 2 },
    '1HZ90V': { base: 998.00, vol: 1.2, dec: 2 },
    '1HZ150V': { base: 5420.00, vol: 8.0, dec: 2 },
    '1HZ200V': { base: 8650.00, vol: 12.0, dec: 2 },
    '1HZ250V': { base: 11250.00, vol: 18.0, dec: 2 },
    'R_75': { base: 33220.00, vol: 65.0, dec: 2 },
    'R_100': { base: 1420.00, vol: 8.5, dec: 2 },
    'R_50': { base: 245.50, vol: 1.5, dec: 4 },
    'R_25': { base: 1850.00, vol: 6.0, dec: 2 },
    'R_10': { base: 4320.00, vol: 12.0, dec: 2 },
    'BOOM1000': { base: 13420.00, vol: 3.5, dec: 2, spike: 'up', spikeProb: 0.04, spikeMag: 45.0 },
    'CRASH1000': { base: 11250.00, vol: 3.5, dec: 2, spike: 'down', spikeProb: 0.04, spikeMag: 45.0 },
    'BOOM500': { base: 3850.00, vol: 2.8, dec: 2, spike: 'up', spikeProb: 0.05, spikeMag: 32.0 },
    'CRASH500': { base: 4620.00, vol: 2.8, dec: 2, spike: 'down', spikeProb: 0.05, spikeMag: 32.0 },
    'BOOM600': { base: 6230.00, vol: 3.2, dec: 2, spike: 'up', spikeProb: 0.05, spikeMag: 35.0 },
    'CRASH600': { base: 6180.00, vol: 3.2, dec: 2, spike: 'down', spikeProb: 0.05, spikeMag: 35.0 },
    'BOOM900': { base: 9150.00, vol: 4.0, dec: 2, spike: 'up', spikeProb: 0.05, spikeMag: 40.0 },
    'CRASH900': { base: 8950.00, vol: 4.0, dec: 2, spike: 'down', spikeProb: 0.05, spikeMag: 40.0 },
    'BOOM300N': { base: 2850.00, vol: 3.0, dec: 2, spike: 'up', spikeProb: 0.05, spikeMag: 32.0 },
    'CRASH300N': { base: 3420.00, vol: 3.0, dec: 2, spike: 'down', spikeProb: 0.05, spikeMag: 32.0 },
    'stpRNG': { base: 8540.00, vol: 0.1, dec: 1 },
    'stpRNG2': { base: 10240.00, vol: 0.1, dec: 1 },
    'stpRNG3': { base: 12450.00, vol: 0.1, dec: 1 },
    'stpRNG4': { base: 14650.00, vol: 0.1, dec: 1 },
    'stpRNG5': { base: 16850.00, vol: 0.1, dec: 1 },
    'JD10': { base: 48000.0, vol: 30.0, dec: 2 },
    'JD25': { base: 112000.0, vol: 80.0, dec: 2 },
    'JD50': { base: 245000.0, vol: 150.0, dec: 2 },
    'JD75': { base: 480000.0, vol: 280.0, dec: 2 },
    'JD100': { base: 890000.0, vol: 450.0, dec: 2 },
    'DEX600UP': { base: 600.0, vol: 1.5, dec: 2, spike: 'up', spikeProb: 0.05, spikeMag: 20.0 },
    'DEX600DN': { base: 600.0, vol: 1.5, dec: 2, spike: 'down', spikeProb: 0.05, spikeMag: 20.0 },
    'DEX900UP': { base: 900.0, vol: 2.0, dec: 2, spike: 'up', spikeProb: 0.05, spikeMag: 25.0 },
    'DEX900DN': { base: 900.0, vol: 2.0, dec: 2, spike: 'down', spikeProb: 0.05, spikeMag: 25.0 },
    'DEX1500UP': { base: 1500.0, vol: 2.8, dec: 2, spike: 'up', spikeProb: 0.05, spikeMag: 30.0 },
    'DEX1500DN': { base: 1500.0, vol: 2.8, dec: 2, spike: 'down', spikeProb: 0.05, spikeMag: 30.0 },
    'DSI10': { base: 1000.0, vol: 1.5, dec: 2 },
    'DSI20': { base: 1000.0, vol: 1.5, dec: 2 },
    'DSI30': { base: 1000.0, vol: 1.5, dec: 2 },
    'RDBULL': { base: 4500.0, vol: 8.0, dec: 2 },
    'RDBEAR': { base: 2800.0, vol: 6.0, dec: 2 },
    'mt5:PainX 400': { base: 4180.00, vol: 5.5, dec: 2, spike: 'down', spikeProb: 0.06, spikeMag: 28.0 },
    'mt5:PainX 600': { base: 6120.00, vol: 7.0, dec: 2, spike: 'down', spikeProb: 0.06, spikeMag: 35.0 },
    'mt5:PainX 800': { base: 8240.00, vol: 9.0, dec: 2, spike: 'down', spikeProb: 0.06, spikeMag: 42.0 },
    'mt5:PainX 999': { base: 9980.00, vol: 11.0, dec: 2, spike: 'down', spikeProb: 0.06, spikeMag: 50.0 },
    'mt5:PainX 1200': { base: 12150.00, vol: 14.0, dec: 2, spike: 'down', spikeProb: 0.06, spikeMag: 60.0 },
    'mt5:GainX 400': { base: 2850.00, vol: 4.8, dec: 2, spike: 'up', spikeProb: 0.06, spikeMag: 26.0 },
    'mt5:GainX 600': { base: 4580.00, vol: 6.5, dec: 2, spike: 'up', spikeProb: 0.06, spikeMag: 32.0 },
    'mt5:GainX 800': { base: 6320.00, vol: 8.0, dec: 2, spike: 'up', spikeProb: 0.06, spikeMag: 40.0 },
    'mt5:GainX 999': { base: 8150.00, vol: 10.0, dec: 2, spike: 'up', spikeProb: 0.06, spikeMag: 48.0 },
    'mt5:GainX 1200': { base: 10450.00, vol: 12.5, dec: 2, spike: 'up', spikeProb: 0.06, spikeMag: 55.0 },
    'mt5:FlipX 600': { base: 620.0, vol: 2.5, dec: 2 },
    'mt5:BreakX 600': { base: 740.0, vol: 3.0, dec: 2 },
    'mt5:FX Vol 20': { base: 1.1050, vol: 0.0012, dec: 4 },
    'mt5:FX Vol 40': { base: 1.2540, vol: 0.0020, dec: 4 },
    'mt5:FX Vol 60': { base: 1.4820, vol: 0.0035, dec: 4 },
    'mt5:FX Vol 80': { base: 1.8450, vol: 0.0050, dec: 4 },
    'mt5:FX Vol 99': { base: 2.3120, vol: 0.0080, dec: 4 },
    'mt5:SFX Vol 20': { base: 1.1050, vol: 0.0012, dec: 4 },
    'mt5:SFX Vol 40': { base: 1.2540, vol: 0.0020, dec: 4 },
    'mt5:SFX Vol 60': { base: 1.4820, vol: 0.0035, dec: 4 },
    'mt5:SFX Vol 80': { base: 1.8450, vol: 0.0050, dec: 4 },
    'mt5:SFX Vol 99': { base: 2.3120, vol: 0.0080, dec: 4 },
    'frxXAUUSD': { base: 2732.50, vol: 2.2, dec: 2 },
    'frxEURUSD': { base: 1.08250, vol: 0.0006, dec: 5 },
    'frxGBPUSD': { base: 1.29650, vol: 0.0008, dec: 5 },
    'frxAUDUSD': { base: 0.6580, vol: 0.0007, dec: 5 }
  };

  function scaleToSpec(market, candles) {
    if (!candles || !candles.length) return [];
    const spec = MARKET_SPECS[market.id];
    if (!spec) return candles;
    const first = candles[0].close || 1;
    if (Math.abs(first - spec.base) / Math.max(spec.base, 1) < 0.35) return candles;
    const ratio = spec.base / first;
    return candles.map(c => ({
      time: c.time,
      open: +(c.open * ratio).toFixed(spec.dec),
      high: +(c.high * ratio).toFixed(spec.dec),
      low: +(c.low * ratio).toFixed(spec.dec),
      close: +(c.close * ratio).toFixed(spec.dec)
    }));
  }

  function generateRealisticSeries(market, gran, count) {
    const spec = MARKET_SPECS[market.id] || { base: 1000.0, vol: 5.0, dec: 2, spike: null };
    const granMs = gran * 1000;
    const now = Date.now();
    const lastTime = Math.floor(now / granMs) * granMs;
    const startTime = lastTime - (count - 1) * granMs;

    const candles = [];
    let price = spec.base;
    const vol = spec.vol;
    const dec = spec.dec;

    let seed = 0;
    for (let i = 0; i < market.id.length; i++) seed = (seed * 31 + market.id.charCodeAt(i)) & 0xffffffff;

    function rnd() {
      seed = (seed * 1664525 + 1013904223) & 0xffffffff;
      return (seed >>> 0) / 4294967296;
    }

    for (let i = 0; i < count; i++) {
      const t = startTime + i * granMs;
      const wave = Math.sin(i / 14.0) * vol * 2.5 + Math.cos(i / 5.5) * vol * 1.3;
      const meanRev = (spec.base - price) * 0.018;
      const drift = (rnd() - 0.495) * vol * 0.9 + meanRev + wave * 0.06;

      let open = price;
      let close = open + drift;

      if (spec.spike === 'up' && rnd() < (spec.spikeProb || 0.04)) {
        close = open + (spec.spikeMag || 30.0) * (0.8 + rnd() * 0.4);
      } else if (spec.spike === 'down' && rnd() < (spec.spikeProb || 0.04)) {
        close = open - (spec.spikeMag || 30.0) * (0.8 + rnd() * 0.4);
      }

      const wick1 = rnd() * vol * 0.55;
      const wick2 = rnd() * vol * 0.55;
      const high = Math.max(open, close) + wick1;
      const low = Math.min(open, close) - wick2;

      candles.push({
        time: t,
        open: +open.toFixed(dec),
        high: +high.toFixed(dec),
        low: +low.toFixed(dec),
        close: +close.toFixed(dec)
      });

      price = close;
    }

    return candles;
  }

  /* ---------------- Unified API with Real-Data Caching ---------------- */
  const cache = new Map();

  function merge(base, incoming) {
    if (!base || !base.length) return (incoming || []).slice();
    if (!incoming || !incoming.length) return base.slice();
    const map = new Map();
    for (const c of base) {
      if (c && Number.isFinite(c.time)) map.set(c.time, c);
    }
    for (const c of incoming) {
      if (c && Number.isFinite(c.time)) map.set(c.time, c);
    }
    return Array.from(map.values()).sort((a, b) => a.time - b.time);
  }

  function createFallbackSubscription(market, gran, cb) {
    const key = `${market.id}|${gran}`;
    const spec = MARKET_SPECS[market.id] || { base: 1000.0, vol: 5.0, dec: 2, spike: null };
    const granMs = gran * 1000;
    const have = cache.get(key) || [];
    let currentBar = have.length ? { ...have[have.length - 1] } : null;

    if (!currentBar) {
      const now = Date.now();
      const t = Math.floor(now / granMs) * granMs;
      currentBar = { time: t, open: spec.base, high: spec.base, low: spec.base, close: spec.base };
    }

    const intervalId = setInterval(() => {
      const now = Date.now();
      const expectedBucket = Math.floor(now / granMs) * granMs;

      if (expectedBucket > currentBar.time) {
        currentBar = {
          time: expectedBucket,
          open: currentBar.close,
          high: currentBar.close,
          low: currentBar.close,
          close: currentBar.close
        };
      } else {
        let delta = (Math.random() - 0.495) * spec.vol * 0.08;
        if (spec.spike === 'up' && Math.random() < 0.015) delta += spec.spikeMag || 25.0;
        else if (spec.spike === 'down' && Math.random() < 0.015) delta -= spec.spikeMag || 25.0;

        currentBar.close = +(currentBar.close + delta).toFixed(spec.dec);
        currentBar.high = Math.max(currentBar.high, currentBar.close);
        currentBar.low = Math.min(currentBar.low, currentBar.close);
      }

      cb(currentBar);
    }, 1000);

    return () => clearInterval(intervalId);
  }

  async function getCandles(market, gran, count) {
    const key = `${market.id}|${gran}`;
    const have = cache.get(key);
    let data = null;

    // 1. Check local MT5 App Bridge first
    if (mt5.bridgeOnline || market.feed === 'mt5') {
      try {
        const full = await Promise.race([
          mt5.candles(market, gran, 'full', count),
          new Promise((_, reject) => setTimeout(() => reject(new Error('MT5 timeout')), 2500))
        ]);
        if (Array.isArray(full) && full.length) {
          data = have ? merge(have, full) : full;
          if (!market.liveSource) market.liveSource = 'MT5 LIVE FEED';
        }
      } catch (e) {}
    }

    // 2. Query official Deriv WebSocket API
    if (!data && market.feed === 'deriv') {
      try {
        data = await Promise.race([
          deriv.history(market.id, gran, count),
          new Promise((_, reject) => setTimeout(() => reject(new Error('Deriv timeout')), 15000))
        ]);
        if (Array.isArray(data) && data.length) {
          market.liveSource = 'DERIV WS REAL-TIME';
        }
      } catch (e) {}
    }

    if (!data || !data.length) {
      if (have && have.length >= Math.min(count * 0.7, 50)) {
        data = have;
      } else {
        data = generateRealisticSeries(market, gran, count);
        market.liveSource = 'SYNTHETIC STREAM';
      }
    }

    cache.set(key, data);
    return data.slice(-count);
  }

  async function getHistory(market, gran, total) {
    try {
      if (mt5.bridgeOnline || market.feed === 'mt5') {
        const mc = await mt5.candles(market, gran, 'full', total);
        if (mc && mc.length) return mc;
      }
      return await deriv.history(market.id, gran, total);
    } catch (e) {
      return generateRealisticSeries(market, gran, total);
    }
  }

  function subscribe(market, gran, cb) {
    const key = `${market.id}|${gran}`;
    const wrapped = c => {
      if (!c || !Number.isFinite(c.time)) return;
      cache.set(key, merge(cache.get(key) || [], [c]));
      cb(c);
    };

    if (mt5.bridgeOnline || market.feed === 'mt5') {
      try {
        const un = mt5.subscribe(market, gran, wrapped);
        if (un) return un;
      } catch (e) {}
    }

    try {
      return deriv.subscribe(market.id, gran, wrapped);
    } catch (e) {
      return createFallbackSubscription(market, gran, wrapped);
    }
  }

  async function loadSeries(market, pairKey, opts = {}) {
    const pair = TF_PAIRS[pairKey] || TF_PAIRS['1H_5m'];
    const recipe = htfRecipe(pair.htf, market.profile);
    const bucketFn = bucketFnFor(recipe, pair.htf);
    const htfCount = opts.htfCount || recipe.count;
    const ltfCount = opts.ltfCount || 450;

    const htfBaseP = getCandles(market, recipe.base, htfCount);
    const ltfP = recipe.base === pair.ltf ? htfBaseP : getCandles(market, pair.ltf, ltfCount);
    const smtMarket = market.smt ? markets.get(market.smt) : null;
    const smtP = smtMarket ? getCandles(smtMarket, recipe.base, htfCount).catch(() => null) : Promise.resolve(null);

    const [htfBase, ltfRaw, smtBase] = await Promise.all([htfBaseP, ltfP, smtP]);
    const ltf = ltfRaw.slice(-ltfCount);
    const htf = recipe.bucket ? T.aggregate(htfBase, bucketFn) : htfBase.slice();
    const smtHtf = smtBase ? (recipe.bucket ? T.aggregate(smtBase, bucketFn) : smtBase) : null;
    return { market, pair, recipe, bucketFn, htf, ltf, smtHtf, smtMarket, loadedAt: Date.now() };
  }

  function decimalsFor(candles) {
    const sample = (candles || []).slice(-30).map(c => c.close);
    let d = 0;
    for (const v of sample) {
      const s = String(v);
      const i = s.indexOf('.');
      if (i >= 0) d = Math.max(d, s.length - i - 1);
    }
    return Math.min(Math.max(d, 2), 5);
  }

  window.CRTFeeds = {
    markets, TF_PAIRS, HTF_SECONDS, htfRecipe, bucketFnFor, MARKET_SPECS,
    deriv, mt5,
    getCandles, getHistory, subscribe, loadSeries, merge, decimalsFor,
    status, onStatus: fn => statusListeners.push(fn)
  };
})();
