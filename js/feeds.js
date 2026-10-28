/**
 * Real-Time Market Data & MT5 Auto-Trading Execution Engine
 *  - STRICT 100% REAL DATA ONLY: Zero synthetic/random math candle generators.
 *  - Primary Source: Your Running Windows MetaTrader 5 App (Common\Files\smc_bridge via /api/mt5)
 *  - Secondary Source (when opened remotely on GitHub Pages): Official Deriv WebSocket API
 */
(function () {
  const T = window.CRTTime;

  /* ---------------- Complete Deriv & Weltrade MT5 Catalog ---------------- */
  const STATIC_MARKETS = [
    // 1. Deriv Volatility Indices (Standard & 1s)
    { id: '1HZ15V', name: 'Volatility 15 (1s) Index', group: 'Deriv MT5 Volatility (1s)', cat: 'deriv_vol', feed: 'mt5', mt5Symbol: 'Volatility 15 (1s) Index', derivSymbol: '1HZ15V', profile: 'synthetic', dec: 3 },
    { id: '1HZ75V', name: 'Volatility 75 (1s) Index', group: 'Deriv MT5 Volatility (1s)', cat: 'deriv_vol', feed: 'mt5', mt5Symbol: 'Volatility 75 (1s) Index', derivSymbol: '1HZ75V', profile: 'synthetic', dec: 2 },
    { id: 'R_75', name: 'Volatility 75 Index', group: 'Deriv MT5 Volatility', cat: 'deriv_vol', feed: 'mt5', mt5Symbol: 'Volatility 75 Index', derivSymbol: 'R_75', profile: 'synthetic', dec: 2 },
    { id: '1HZ10V', name: 'Volatility 10 (1s) Index', group: 'Deriv MT5 Volatility (1s)', cat: 'deriv_vol', feed: 'mt5', mt5Symbol: 'Volatility 10 (1s) Index', derivSymbol: '1HZ10V', profile: 'synthetic', dec: 2 },
    { id: '1HZ25V', name: 'Volatility 25 (1s) Index', group: 'Deriv MT5 Volatility (1s)', cat: 'deriv_vol', feed: 'mt5', mt5Symbol: 'Volatility 25 (1s) Index', derivSymbol: '1HZ25V', profile: 'synthetic', dec: 2 },
    { id: '1HZ50V', name: 'Volatility 50 (1s) Index', group: 'Deriv MT5 Volatility (1s)', cat: 'deriv_vol', feed: 'mt5', mt5Symbol: 'Volatility 50 (1s) Index', derivSymbol: '1HZ50V', profile: 'synthetic', dec: 2 },
    { id: '1HZ100V', name: 'Volatility 100 (1s) Index', group: 'Deriv MT5 Volatility (1s)', cat: 'deriv_vol', feed: 'mt5', mt5Symbol: 'Volatility 100 (1s) Index', derivSymbol: '1HZ100V', profile: 'synthetic', dec: 2 },
    { id: 'R_10', name: 'Volatility 10 Index', group: 'Deriv MT5 Volatility', cat: 'deriv_vol', feed: 'mt5', mt5Symbol: 'Volatility 10 Index', derivSymbol: 'R_10', profile: 'synthetic', dec: 3 },
    { id: 'R_25', name: 'Volatility 25 Index', group: 'Deriv MT5 Volatility', cat: 'deriv_vol', feed: 'mt5', mt5Symbol: 'Volatility 25 Index', derivSymbol: 'R_25', profile: 'synthetic', dec: 3 },
    { id: 'R_50', name: 'Volatility 50 Index', group: 'Deriv MT5 Volatility', cat: 'deriv_vol', feed: 'mt5', mt5Symbol: 'Volatility 50 Index', derivSymbol: 'R_50', profile: 'synthetic', dec: 4 },
    { id: 'R_100', name: 'Volatility 100 Index', group: 'Deriv MT5 Volatility', cat: 'deriv_vol', feed: 'mt5', mt5Symbol: 'Volatility 100 Index', derivSymbol: 'R_100', profile: 'synthetic', dec: 2 },

    // 2. Deriv Boom & Crash Indices
    { id: 'BOOM1000', name: 'Boom 1000 Index', group: 'Deriv MT5 Boom & Crash', cat: 'deriv_boom', feed: 'mt5', mt5Symbol: 'Boom 1000 Index', derivSymbol: 'BOOM1000', profile: 'synthetic', spike: 'up', dec: 3 },
    { id: 'CRASH1000', name: 'Crash 1000 Index', group: 'Deriv MT5 Boom & Crash', cat: 'deriv_boom', feed: 'mt5', mt5Symbol: 'Crash 1000 Index', derivSymbol: 'CRASH1000', profile: 'synthetic', spike: 'down', dec: 3 },
    { id: 'BOOM500', name: 'Boom 500 Index', group: 'Deriv MT5 Boom & Crash', cat: 'deriv_boom', feed: 'mt5', mt5Symbol: 'Boom 500 Index', derivSymbol: 'BOOM500', profile: 'synthetic', spike: 'up', dec: 3 },
    { id: 'CRASH500', name: 'Crash 500 Index', group: 'Deriv MT5 Boom & Crash', cat: 'deriv_boom', feed: 'mt5', mt5Symbol: 'Crash 500 Index', derivSymbol: 'CRASH500', profile: 'synthetic', spike: 'down', dec: 3 },
    { id: 'BOOM300N', name: 'Boom 300 Index', group: 'Deriv MT5 Boom & Crash', cat: 'deriv_boom', feed: 'mt5', mt5Symbol: 'Boom 300 Index', derivSymbol: 'BOOM300N', profile: 'synthetic', spike: 'up', dec: 3 },
    { id: 'CRASH300N', name: 'Crash 300 Index', group: 'Deriv MT5 Boom & Crash', cat: 'deriv_boom', feed: 'mt5', mt5Symbol: 'Crash 300 Index', derivSymbol: 'CRASH300N', profile: 'synthetic', spike: 'down', dec: 3 },

    // 3. Deriv Step & Jump Indices
    { id: 'stpRNG', name: 'Step Index', group: 'Deriv MT5 Step & Jump', cat: 'deriv_step', feed: 'mt5', mt5Symbol: 'Step Index', derivSymbol: 'stpRNG', profile: 'synthetic', dec: 1 },
    { id: 'JD10', name: 'Jump 10 Index', group: 'Deriv MT5 Step & Jump', cat: 'deriv_step', feed: 'mt5', mt5Symbol: 'Jump 10 Index', derivSymbol: 'JD10', profile: 'synthetic', dec: 2 },
    { id: 'JD25', name: 'Jump 25 Index', group: 'Deriv MT5 Step & Jump', cat: 'deriv_step', feed: 'mt5', mt5Symbol: 'Jump 25 Index', derivSymbol: 'JD25', profile: 'synthetic', dec: 2 },
    { id: 'JD50', name: 'Jump 50 Index', group: 'Deriv MT5 Step & Jump', cat: 'deriv_step', feed: 'mt5', mt5Symbol: 'Jump 50 Index', derivSymbol: 'JD50', profile: 'synthetic', dec: 2 },
    { id: 'JD75', name: 'Jump 75 Index', group: 'Deriv MT5 Step & Jump', cat: 'deriv_step', feed: 'mt5', mt5Symbol: 'Jump 75 Index', derivSymbol: 'JD75', profile: 'synthetic', dec: 2 },
    { id: 'JD100', name: 'Jump 100 Index', group: 'Deriv MT5 Step & Jump', cat: 'deriv_step', feed: 'mt5', mt5Symbol: 'Jump 100 Index', derivSymbol: 'JD100', profile: 'synthetic', dec: 2 },

    // 4. Deriv Range Break & DEX Indices
    { id: 'RDBULL', name: 'Range Break 100 Index', group: 'Deriv MT5 Range Break & DEX', cat: 'deriv_dex', feed: 'mt5', mt5Symbol: 'Range Break 100 Index', derivSymbol: 'RDBULL', profile: 'synthetic', dec: 2 },
    { id: 'RDBEAR', name: 'Range Break 200 Index', group: 'Deriv MT5 Range Break & DEX', cat: 'deriv_dex', feed: 'mt5', mt5Symbol: 'Range Break 200 Index', derivSymbol: 'RDBEAR', profile: 'synthetic', dec: 2 },
    { id: 'DEX600UP', name: 'DEX 600 UP', group: 'Deriv MT5 Range Break & DEX', cat: 'deriv_dex', feed: 'mt5', mt5Symbol: 'DEX 600 UP', derivSymbol: 'DEX600UP', profile: 'synthetic', spike: 'up', dec: 2 },
    { id: 'DEX600DN', name: 'DEX 600 DOWN', group: 'Deriv MT5 Range Break & DEX', cat: 'deriv_dex', feed: 'mt5', mt5Symbol: 'DEX 600 DOWN', derivSymbol: 'DEX600DN', profile: 'synthetic', spike: 'down', dec: 2 },
    { id: 'DEX900UP', name: 'DEX 900 UP', group: 'Deriv MT5 Range Break & DEX', cat: 'deriv_dex', feed: 'mt5', mt5Symbol: 'DEX 900 UP', derivSymbol: 'DEX900UP', profile: 'synthetic', spike: 'up', dec: 2 },
    { id: 'DEX900DN', name: 'DEX 900 DOWN', group: 'Deriv MT5 Range Break & DEX', cat: 'deriv_dex', feed: 'mt5', mt5Symbol: 'DEX 900 DOWN', derivSymbol: 'DEX900DN', profile: 'synthetic', spike: 'down', dec: 2 },

    // 5. Weltrade SyntX Indices (Streamed from MT5 when logged into Weltrade MT5)
    { id: 'mt5:PainX 400', name: 'PainX 400 Index', group: 'Weltrade MT5 SyntX', cat: 'weltrade', feed: 'mt5', mt5Symbol: 'PainX 400', profile: 'synthetic', spike: 'down', dec: 2 },
    { id: 'mt5:GainX 400', name: 'GainX 400 Index', group: 'Weltrade MT5 SyntX', cat: 'weltrade', feed: 'mt5', mt5Symbol: 'GainX 400', profile: 'synthetic', spike: 'up', dec: 2 },
    { id: 'mt5:PainX 600', name: 'PainX 600 Index', group: 'Weltrade MT5 SyntX', cat: 'weltrade', feed: 'mt5', mt5Symbol: 'PainX 600', profile: 'synthetic', spike: 'down', dec: 2 },
    { id: 'mt5:GainX 600', name: 'GainX 600 Index', group: 'Weltrade MT5 SyntX', cat: 'weltrade', feed: 'mt5', mt5Symbol: 'GainX 600', profile: 'synthetic', spike: 'up', dec: 2 },
    { id: 'mt5:PainX 800', name: 'PainX 800 Index', group: 'Weltrade MT5 SyntX', cat: 'weltrade', feed: 'mt5', mt5Symbol: 'PainX 800', profile: 'synthetic', spike: 'down', dec: 2 },
    { id: 'mt5:GainX 800', name: 'GainX 800 Index', group: 'Weltrade MT5 SyntX', cat: 'weltrade', feed: 'mt5', mt5Symbol: 'GainX 800', profile: 'synthetic', spike: 'up', dec: 2 },
    { id: 'mt5:PainX 999', name: 'PainX 999 Index', group: 'Weltrade MT5 SyntX', cat: 'weltrade', feed: 'mt5', mt5Symbol: 'PainX 999', profile: 'synthetic', spike: 'down', dec: 2 },
    { id: 'mt5:GainX 999', name: 'GainX 999 Index', group: 'Weltrade MT5 SyntX', cat: 'weltrade', feed: 'mt5', mt5Symbol: 'GainX 999', profile: 'synthetic', spike: 'up', dec: 2 },
    { id: 'mt5:PainX 1200', name: 'PainX 1200 Index', group: 'Weltrade MT5 SyntX', cat: 'weltrade', feed: 'mt5', mt5Symbol: 'PainX 1200', profile: 'synthetic', spike: 'down', dec: 2 },
    { id: 'mt5:GainX 1200', name: 'GainX 1200 Index', group: 'Weltrade MT5 SyntX', cat: 'weltrade', feed: 'mt5', mt5Symbol: 'GainX 1200', profile: 'synthetic', spike: 'up', dec: 2 },
    { id: 'mt5:FlipX 600', name: 'FlipX / SwitchX 600', group: 'Weltrade MT5 SyntX', cat: 'weltrade', feed: 'mt5', mt5Symbol: 'SwitchX 600', profile: 'synthetic', dec: 2 },
    { id: 'mt5:BreakX 600', name: 'BreakX 600', group: 'Weltrade MT5 SyntX', cat: 'weltrade', feed: 'mt5', mt5Symbol: 'BreakX 600', profile: 'synthetic', dec: 2 },
    { id: 'mt5:FX Vol 20', name: 'FX Vol 20', group: 'Weltrade MT5 SyntX', cat: 'weltrade', feed: 'mt5', mt5Symbol: 'FX Vol 20', profile: 'synthetic', dec: 4 },
    { id: 'mt5:FX Vol 40', name: 'FX Vol 40', group: 'Weltrade MT5 SyntX', cat: 'weltrade', feed: 'mt5', mt5Symbol: 'FX Vol 40', profile: 'synthetic', dec: 4 },
    { id: 'mt5:FX Vol 60', name: 'FX Vol 60', group: 'Weltrade MT5 SyntX', cat: 'weltrade', feed: 'mt5', mt5Symbol: 'FX Vol 60', profile: 'synthetic', dec: 4 },
    { id: 'mt5:FX Vol 80', name: 'FX Vol 80', group: 'Weltrade MT5 SyntX', cat: 'weltrade', feed: 'mt5', mt5Symbol: 'FX Vol 80', profile: 'synthetic', dec: 4 },
    { id: 'mt5:FX Vol 99', name: 'FX Vol 99', group: 'Weltrade MT5 SyntX', cat: 'weltrade', feed: 'mt5', mt5Symbol: 'FX Vol 99', profile: 'synthetic', dec: 4 },

    // 6. Real Forex & Metals from MT5
    { id: 'frxEURUSD', name: 'EUR/USD', group: 'MT5 Forex & Metals', cat: 'forex', feed: 'mt5', mt5Symbol: 'EURUSD', derivSymbol: 'frxEURUSD', profile: 'forex', dec: 5 },
    { id: 'frxGBPUSD', name: 'GBP/USD', group: 'MT5 Forex & Metals', cat: 'forex', feed: 'mt5', mt5Symbol: 'GBPUSD', derivSymbol: 'frxGBPUSD', profile: 'forex', dec: 5 },
    { id: 'frxUSDJPY', name: 'USD/JPY', group: 'MT5 Forex & Metals', cat: 'forex', feed: 'mt5', mt5Symbol: 'USDJPY', derivSymbol: 'frxUSDJPY', profile: 'forex', dec: 3 },
    { id: 'frxXAUUSD', name: 'XAU/USD (Gold)', group: 'MT5 Forex & Metals', cat: 'forex', feed: 'mt5', mt5Symbol: 'XAUUSD', derivSymbol: 'frxXAUUSD', profile: 'forex', dec: 2 }
  ];

  const markets = new Map(STATIC_MARKETS.map(m => [m.id, m]));

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
      case '15m': return { base: 900, count: 250, bucket: null };
      case '1h': return { base: 3600, count: 250, bucket: null };
      case '4h': return ny ? { base: 3600, count: 400, bucket: 'ny4h' } : { base: 14400, count: 250, bucket: null };
      case '1d': return ny ? { base: 3600, count: 500, bucket: 'nyday' } : { base: 86400, count: 250, bucket: null };
    }
    return { base: 3600, count: 250, bucket: null };
  }
  const HTF_SECONDS = { '15m': 900, '1h': 3600, '4h': 14400, '1d': 86400 };

  function bucketFnFor(recipe, htf) {
    return recipe.bucket ? T.BUCKETS[recipe.bucket] : T.fixedBucket(HTF_SECONDS[htf]);
  }

  /* ---------------- Status bus ---------------- */
  const status = { deriv: 'idle', mt5: 'idle' };
  const statusListeners = [];
  function setStatus(feed, s) {
    status[feed] = s;
    statusListeners.forEach(fn => fn({ ...status }));
  }

  /* ---------------- Deriv Official WebSocket (Only used if remote / GitHub Pages) ---------------- */
  const DERIV_ENDPOINTS = [
    'wss://ws.derivws.com/websockets/v3?app_id=1089',
    'wss://ws.binaryws.com/websockets/v3?app_id=1089',
    'wss://green.derivws.com/websockets/v3?app_id=1089'
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
    }

    get url() {
      return DERIV_ENDPOINTS[this.epIdx % DERIV_ENDPOINTS.length];
    }

    connect() {
      if (this.ws && (this.ws.readyState === 0 || this.ws.readyState === 1)) return this.openPromise;
      setStatus('deriv', 'connecting');
      let opened = false;
      let openReject = null;
      try {
        this.ws = new WebSocket(this.url);
      } catch (e) {
        setStatus('deriv', 'offline');
        return Promise.reject(e);
      }

      const connTimeout = setTimeout(() => {
        if (!opened && this.ws && this.ws.readyState !== 1) {
          try { this.ws.close(); } catch (e) {}
          if (openReject) openReject(new Error('Deriv timeout'));
        }
      }, 12000);

      this.openPromise = new Promise((resolve, reject) => {
        openReject = reject;
        this.ws.onopen = () => {
          opened = true;
          clearTimeout(connTimeout);
          setStatus('deriv', 'live');
          const toSend = this.queue.splice(0);
          for (const raw of toSend) this.ws.send(raw);
          for (const [key, s] of this.subReqs) {
            if (!s.inflight) this._subscribe(key, s.req, s.cb);
          }
          resolve();
        };
      });

      this.ws.onmessage = ev => {
        try { this._onMessage(JSON.parse(ev.data)); } catch (e) {}
      };

      this.ws.onclose = () => {
        clearTimeout(connTimeout);
        this.subs.clear();
        for (const [, s] of this.subReqs) s.inflight = false;
        if (!opened) this.epIdx = (this.epIdx + 1) % DERIV_ENDPOINTS.length;
        setStatus('deriv', 'offline');
      };

      return this.openPromise;
    }

    _onMessage(msg) {
      const subId = (msg.subscription && msg.subscription.id) || (msg.ohlc && msg.ohlc.id);
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

    send(req, timeoutMs = 12000) {
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
          try { this.ws.send(payload); } catch (e) { this.queue.push(payload); }
        } else {
          this.queue.push(payload);
        }
      });
    }

    async discoverSymbols() { return; }

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
      return await this.candles(symbol, gran, Math.min(total, 4999), 'latest');
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

  /* ---------------- Primary Source: Live Windows MT5 App Bridge ---------------- */
  const MT5_TF = { 60: '60', 300: '300', 900: '900', 3600: '3600', 14400: '14400', 86400: '86400' };
  const mt5 = {
    bridgeUrl: 'http://localhost:8095', // Connects directly to local MT5 bridge even if opened from GitHub Pages
    bridgeOnline: false,
    symbols: [],
    accountState: null,

    getBaseUrl() {
      if (window.location.hostname === 'localhost' || window.location.hostname === '127.0.0.1') {
        return '';
      }
      return this.bridgeUrl;
    },

    async fetchAccountState() {
      try {
        const ctrl = new AbortController();
        const tid = setTimeout(() => ctrl.abort(), 1500);
        const r = await fetch(`${this.getBaseUrl()}/api/mt5/account`, { cache: 'no-store', signal: ctrl.signal });
        clearTimeout(tid);
        if (r.ok) {
          const data = await r.json();
          if (data && typeof data === 'object' && data.login > 0) {
            this.accountState = data;
            this.bridgeOnline = true;
            setStatus('mt5', 'live');
            return data;
          }
        }
      } catch (e) {}
      return this.accountState;
    },

    async sendCommand(cmd) {
      try {
        const r = await fetch(`${this.getBaseUrl()}/api/mt5/command`, {
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
        const tid = setTimeout(() => ctrl.abort(), 1800);
        const r = await fetch(`${this.getBaseUrl()}/api/mt5/symbols`, { cache: 'no-store', signal: ctrl.signal });
        clearTimeout(tid);
        if (!r.ok) throw new Error('MT5 bridge offline');
        const data = await r.json();
        this.symbols = data.symbols || [];
        this.bridgeOnline = this.symbols.length > 0 || (this.accountState && this.accountState.login > 0);
        setStatus('mt5', this.bridgeOnline ? 'live' : 'offline');
        return this.symbols;
      } catch (e) {
        this.bridgeOnline = false;
        setStatus('mt5', 'offline');
        return [];
      }
    },

    async candles(market, gran, kind = 'full', count = 500) {
      const symbol = market.mt5Symbol || market.id.replace('mt5:', '') || market.name;
      try {
        const ctrl = new AbortController();
        const tid = setTimeout(() => ctrl.abort(), 2000);
        const r = await fetch(`${this.getBaseUrl()}/api/mt5/candles?symbol=${encodeURIComponent(symbol)}&tf=${MT5_TF[gran] || gran}&kind=${kind}`, { cache: 'no-store', signal: ctrl.signal });
        clearTimeout(tid);
        if (r.ok) {
          const rows = await r.json();
          if (Array.isArray(rows) && rows.length) {
            this.bridgeOnline = true;
            setStatus('mt5', 'live');
            market.liveSource = `MT5 APP LIVE (${this.accountState?.server || 'Deriv-Demo'} #${this.accountState?.login || '32398784'})`;
            return rows.map(a => ({ time: a[0] * 1000, open: +a[1], high: +a[2], low: +a[3], close: +a[4] }));
          }
        }
      } catch (e) {}
      return [];
    },

    subscribe(market, gran, cb) {
      const pollTimer = setInterval(async () => {
        try {
          const rows = await this.candles(market, gran, 'live', 5);
          if (rows.length) cb(rows[rows.length - 1]);
        } catch (e) {}
      }, 1500);
      return () => clearInterval(pollTimer);
    }
  };

  /* ---------------- Unified Cache (100% Real MT5 & Deriv Feed Only) ---------------- */
  const cache = new Map();
  const MARKET_SPECS = {}; // No artificial math specs

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

  async function getCandles(market, gran, count) {
    const key = `${market.id}|${gran}`;
    const have = cache.get(key);
    let data = null;

    // 1. ALWAYS query your Windows MT5 App first
    try {
      const full = await mt5.candles(market, gran, 'full', count);
      if (Array.isArray(full) && full.length) {
        data = have ? merge(have, full) : full;
        market.spot = data[data.length - 1].close;
      }
    } catch (e) {}

    // 2. If MT5 doesn't have this symbol cached yet and it's a Deriv symbol, query real Deriv WebSocket
    if ((!data || !data.length) && market.derivSymbol) {
      try {
        const wsData = await deriv.history(market.derivSymbol, gran, count);
        if (Array.isArray(wsData) && wsData.length) {
          data = have ? merge(have, wsData) : wsData;
          market.spot = data[data.length - 1].close;
          market.liveSource = 'DERIV OFFICIAL WS LIVE';
        }
      } catch (e) {}
    }

    if (!data || !data.length) {
      if (have && have.length) return have.slice(-count);
      throw new Error(`Symbol ${market.mt5Symbol || market.name} is not active on your current MT5 broker login (${mt5.accountState?.server || 'Deriv-Demo'})`);
    }

    cache.set(key, data);
    return data.slice(-count);
  }

  async function getHistory(market, gran, total) {
    return await getCandles(market, gran, total);
  }

  function subscribe(market, gran, cb) {
    const key = `${market.id}|${gran}`;
    const wrapped = c => {
      if (!c || !Number.isFinite(c.time)) return;
      cache.set(key, merge(cache.get(key) || [], [c]));
      market.spot = c.close;
      cb(c);
    };

    const unsubMt5 = mt5.subscribe(market, gran, wrapped);
    let unsubWs = null;
    if (!mt5.bridgeOnline && market.derivSymbol) {
      unsubWs = deriv.subscribe(market.derivSymbol, gran, wrapped);
    }
    return () => {
      if (unsubMt5) unsubMt5();
      if (unsubWs) unsubWs();
    };
  }

  async function loadSeries(market, pairKey, opts = {}) {
    const pair = TF_PAIRS[pairKey] || TF_PAIRS['1H_5m'];
    const recipe = htfRecipe(pair.htf, market.profile);
    const bucketFn = bucketFnFor(recipe, pair.htf);
    const htfCount = opts.htfCount || recipe.count;
    const ltfCount = opts.ltfCount || 450;

    const htfBaseP = getCandles(market, recipe.base, htfCount);
    const ltfP = recipe.base === pair.ltf ? htfBaseP : getCandles(market, pair.ltf, ltfCount);

    const [htfBase, ltfRaw] = await Promise.all([htfBaseP, ltfP]);
    const ltf = ltfRaw.slice(-ltfCount);
    const htf = recipe.bucket ? T.aggregate(htfBase, bucketFn) : htfBase.slice();
    return { market, pair, recipe, bucketFn, htf, ltf, smtHtf: null, smtMarket: null, loadedAt: Date.now() };
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
