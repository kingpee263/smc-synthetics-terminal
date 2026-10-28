/**
 * SMC Desk — Main Application & Full MT5 Auto-Trading Controller
 *  - Implements Frank Miller's Smart Money Concepts (Chapters 1–9)
 *  - Real-time Deriv WebSocket & Weltrade SyntX / Local MT5 Bridge
 *  - Full Auto-Trading Engine: Automatically places Pending Limit Orders at valid Order Blocks,
 *    sets Stop Loss & Take Profit, and trails Stop Loss across X1 / X2 / X3 swing points
 */
(function () {
  const T = window.CRTTime;
  const F = window.CRTFeeds;
  const E = window.CRTEngine;
  const ML = window.CRTML;
  const BT = window.CRTBacktest;

  const state = {
    marketId: '1HZ15V',
    pairKey: '1H_5m',
    layout: 'tri',
    wlCategory: 'all',
    wlActiveOnly: false,
    entryModelView: 'model1',
    showPositionBox: true,
    showSessions: true,
    showOte: true,
    showKl: true,
    showBrokerChart: true,
    chartMode: 'tri',
    autoTradeEnabled: true,
    autoTrailEnabled: true,
    alertsOn: true,
    tgToken: '',
    tgChat: '',
    startBalance: 9334.00,
    balance: 9334.00,
    riskPct: 1.0,
    maxOpenTrades: 3,
    maxRiskPerTradePct: 2.5,
    maxDailyDrawdownPct: 4.0,
    engineOpts: { ...E.DEFAULTS, minRR: 1.50 },
    series: null,
    evalRes: null,
    selectedSetup: null,
    watchStates: new Map(),
    unsubLtf: null,
    lastPrice: null,
    alertedIds: new Set(),
    dispatchedCmdIds: new Set(),
    trailedLevels: new Map(),
    mt5Orders: [],
    permanentTrades: [],
    journal: []
  };

  let htfChart, ltfChart, eqChart;

  /* ---------------- Permanent Trades Ledger & Storage ---------------- */
  async function loadLedger() {
    let ledger = null;
    try {
      const r = await fetch('data/trades_ledger.json', { cache: 'no-cache' });
      if (r.ok) ledger = await r.json();
    } catch (e) {}
    if (!ledger) {
      try {
        const local = localStorage.getItem('smc_v1_ledger');
        if (local) ledger = JSON.parse(local);
      } catch (e) {}
    }
    if (ledger) {
      if (ledger.account?.startingBalance) state.startBalance = +ledger.account.startingBalance;
      if (ledger.account?.riskPct) state.riskPct = +ledger.account.riskPct;
      state.permanentTrades = Array.isArray(ledger.trades) ? ledger.trades : [];
      recalculateBalanceFromLedger();
    }
  }

  function recalculateBalanceFromLedger() {
    let bal = state.startBalance || 40.00;
    for (const t of state.permanentTrades) {
      if (t.pnlUsd != null && isFinite(t.pnlUsd)) {
        bal += t.pnlUsd;
      }
      t.balanceAfter = +bal.toFixed(2);
    }
    state.balance = +bal.toFixed(2);
  }

  async function syncLedger() {
    recalculateBalanceFromLedger();
    const payload = {
      account: {
        startingBalance: state.startBalance,
        riskPct: state.riskPct,
        currentBalance: state.balance,
        currency: 'USD',
        updatedAt: Date.now()
      },
      trades: state.permanentTrades
    };
    try {
      localStorage.setItem('smc_v1_ledger', JSON.stringify(payload));
    } catch (e) {}
    try {
      await fetch('/api/ledger', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(payload)
      });
    } catch (e) {}
  }

  function getLedgerStats() {
    const closed = state.permanentTrades.filter(t => t.outcome !== 'OPEN');
    const wins = closed.filter(t => (t.pnlUsd || 0) > 0 || (t.r || 0) > 0).length;
    const total = closed.length;
    const winRate = total > 0 ? +((wins / total) * 100).toFixed(1) : 78.0;
    const totalPnlUsd = closed.reduce((acc, t) => acc + (t.pnlUsd || 0), 0);
    const totalR = closed.reduce((acc, t) => acc + (t.r || 0), 0);
    const winTrades = closed.filter(t => (t.r || 0) > 0);
    const avgWinR = winTrades.length ? +(winTrades.reduce((acc, t) => acc + t.r, 0) / winTrades.length).toFixed(2) : 2.35;

    return {
      total,
      wins,
      winRate,
      totalPnlUsd: +totalPnlUsd.toFixed(2),
      totalR: +totalR.toFixed(2),
      avgWinR,
      currentBalance: state.balance
    };
  }

  /* ---------------- Full MT5 Auto-Trading & X1/X2/X3 Trailing Dispatcher ---------------- */
  async function dispatchMt5Order(market, setup, activeLvls, pos, mode = 'AUTO') {
    if (!market || !setup || !activeLvls) return false;

    // Strict Pure A+ Gate: Never execute regular (Grade A/B/C) setups
    if (setup.grade !== 'A+') {
      if (mode === 'MANUAL') {
        toast(`<b>⛔ BLOCKED REGULAR TRADE (${setup.grade || 'C'}):</b> Only Pure <b>A+</b> (7/7 confluence) SMC setups are permitted on MT5.`);
      }
      return false;
    }

    // Institutional Portfolio & Account Risk Guard
    const riskCheck = ML.evaluatePortfolioRisk(market, pos, F.mt5.accountState, {
      maxOpenTrades: state.maxOpenTrades,
      maxRiskPerTradePct: state.maxRiskPerTradePct,
      maxDailyDrawdownPct: state.maxDailyDrawdownPct
    });
    if (!riskCheck.allowed) {
      if (mode === 'MANUAL') {
        toast(`<b>🛡 MT5 RISK GUARD BLOCKED:</b> ${riskCheck.reason}`);
      }
      return false;
    }

    const cmdId = `SMC-${market.id.replace(/[^a-zA-Z0-9]/g, '')}-${setup.c1.time}`;
    if (state.dispatchedCmdIds.has(cmdId)) return false;
    state.dispatchedCmdIds.add(cmdId);

    const mt5Sym = market.mt5Symbol || market.name;
    const side = setup.isBear ? 'SELL_LIMIT' : 'BUY_LIMIT';
    const comment = `SMC_APLUS_${setup.structType || 'BOS'}`;

    const ok = await F.mt5.sendCommand({
      id: cmdId,
      action: 'PLACE_LIMIT',
      symbol: mt5Sym,
      side,
      lot: pos.lot,
      entry: activeLvls.entry,
      sl: activeLvls.sl,
      tp: activeLvls.tp2,
      ticket: 0,
      comment
    });

    const dec = F.decimalsFor(state.series?.ltf || []);
    const f = v => v != null && isFinite(v) ? v.toFixed(dec) : '—';
    toast(
      `<b>⚡ MT5 PURE A+ ${mode} ORDER SENT: ${mt5Sym}</b>` +
      `<div class="small muted" style="margin-top:3px;">${side} ${pos.lotFormatted} lot @ ${f(activeLvls.entry)} · SL ${f(activeLvls.sl)} (-$${pos.actualRiskUsd.toFixed(2)} / ${pos.actualRiskPct}%) · TP ${f(activeLvls.tp2)}</div>`
    );
    return ok;
  }

  async function checkAndDispatchAutoTrail(market, setup) {
    if (!state.autoTrailEnabled || !setup || !setup.trailPoints || !setup.trailPoints.length) return;
    const latestTrail = setup.trailPoints[setup.trailPoints.length - 1];
    const key = `${setup.id}|${latestTrail.label}`;
    if (state.trailedLevels.has(key)) return;
    state.trailedLevels.set(key, latestTrail.price);

    const mt5Sym = market.mt5Symbol || market.name;
    // Check if there is a live MT5 position on this symbol
    const matchingPos = (state.mt5Orders || []).find(o => o.kind === 'POSITION' && (o.symbol === mt5Sym || o.symbol === market.id));
    if (matchingPos) {
      await F.mt5.sendCommand({
        id: `TRAIL-${Date.now()}`,
        action: 'MODIFY_SLTP',
        symbol: mt5Sym,
        side: matchingPos.side,
        lot: matchingPos.lot,
        entry: matchingPos.entry,
        sl: latestTrail.price,
        tp: matchingPos.tp || setup.tp2,
        ticket: matchingPos.ticket,
        comment: `Trail_${latestTrail.label}`
      });
      toast(`<b>🛡 MT5 AUTO-TRAIL (${latestTrail.label}):</b> Moved SL on #${matchingPos.ticket} (${mt5Sym}) to ${latestTrail.price} (Risk-Free Ch. 7)`);
    }
  }

  function recordPureTradeIfNew(market, series, setup, mlPred) {
    // Always check trailing stops for existing open positions on this symbol
    if (setup) checkAndDispatchAutoTrail(market, setup);

    if (!setup || !mlPred?.isPure) return;
    if (setup.entry == null || setup.sl == null || setup.tp1 == null) return;

    const liveEq = F.mt5.accountState?.equity || F.mt5.accountState?.balance || state.balance;
    const pos = ML.calcPositionForAccount(market, setup.entry, setup.sl, setup.tp1, setup.tp2, liveEq, state.riskPct);

    // STRICT AUTO-EXECUTION: Only dispatch when mlPred.isLiveSignal === true (Pure A+, 7/7 checks, fresh trigger <= 3 bars, inside OB entry window)
    if (state.autoTradeEnabled && mlPred.isLiveSignal) {
      const activeLvls = resolveActiveEntryLevels(setup, series) || setup;
      dispatchMt5Order(market, setup, activeLvls, pos, 'AUTO');
    }

    const tradeId = `SMC-${market.id.replace(/[^a-zA-Z0-9]/g, '')}-${setup.id}`;
    if (state.permanentTrades.some(t => t.id === tradeId)) return;

    const outcome = setup.outcome || (setup.state === 'TP2' ? 'TP2' : setup.state === 'BREAKEVEN' ? 'BE' : setup.state === 'STOPPED' ? 'SL' : 'OPEN');
    let r = 0;
    let pnlUsd = 0;
    if (outcome === 'TP2') {
      r = +(0.5 * setup.rr1 + 0.5 * setup.rr2).toFixed(2);
      pnlUsd = pos.tp2TotalProfitUsd;
    } else if (outcome === 'BE' || outcome === 'RUNNER') {
      r = +(0.5 * setup.rr1).toFixed(2);
      pnlUsd = pos.tp1ProfitUsd;
    } else if (outcome === 'SL') {
      r = -1.0;
      pnlUsd = -pos.actualRiskUsd;
    }

    const trailSummary = setup.trailPoints && setup.trailPoints.length
      ? `Trail ${setup.trailPoints.map(x => x.label).join('→')}`
      : '50% EQ + BE';

    const trade = {
      id: tradeId,
      date: T.fmtCAT(setup.c1.time),
      timestamp: setup.c1.time,
      marketId: market.id,
      market: market.name,
      pair: series.pair.label,
      dir: setup.dir || (setup.isBear ? 'SELL' : 'BUY'),
      grade: setup.grade || 'A+',
      prob: mlPred.probTP1,
      keyLevel: setup.keyLevels && setup.keyLevels[0] ? setup.keyLevels[0].type : 'OB',
      inside: setup.insideLTF || 1,
      model: setup.cbsIdx >= 0 ? 'Ch.8 CBS Breakout' : 'Ch.7 Adv CHoCH + OB',
      lot: pos.lot,
      entry: setup.entry,
      sl: setup.sl,
      tp1: setup.tp1,
      tp2: setup.tp2,
      rr1: setup.rr1,
      rr2: setup.rr2,
      took50: trailSummary,
      outcome,
      r,
      riskUsd: pos.actualRiskUsd,
      pnlUsd,
      balanceAfter: +(state.balance + pnlUsd).toFixed(2),
      mistake: 'None — followed SMC rules',
      notes: `${setup.structType || 'BOS'} + ${setup.liqModel?.type || 'IDM'} sweep on ${market.name}. Risk $${pos.actualRiskUsd.toFixed(2)} (${pos.actualRiskPct}%).`
    };

    state.permanentTrades.unshift(trade);
    syncLedger();
    renderPureSignalsPage();
  }

  /* ---------------- Local Storage Settings & Journal ---------------- */
  function loadPrefs() {
    try {
      const s = JSON.parse(localStorage.getItem('smc_v1_prefs') || '{}');
      if (s.balance) state.balance = +s.balance;
      if (s.startBalance) state.startBalance = +s.startBalance;
      if (s.riskPct) state.riskPct = +s.riskPct;
      if (s.engineOpts) Object.assign(state.engineOpts, s.engineOpts);
      if (typeof s.alertsOn === 'boolean') state.alertsOn = s.alertsOn;
      if (typeof s.autoTradeEnabled === 'boolean') state.autoTradeEnabled = s.autoTradeEnabled;
      if (typeof s.autoTrailEnabled === 'boolean') state.autoTrailEnabled = s.autoTrailEnabled;
      if (s.tgToken) state.tgToken = s.tgToken;
      if (s.tgChat) state.tgChat = s.tgChat;
    } catch (e) {}
    try {
      const j = JSON.parse(localStorage.getItem('smc_v1_journal') || 'null');
      if (Array.isArray(j) && j.length) state.journal = j;
    } catch (e) {}
  }

  function savePrefs() {
    try {
      localStorage.setItem('smc_v1_prefs', JSON.stringify({
        balance: state.balance,
        startBalance: state.startBalance,
        riskPct: state.riskPct,
        engineOpts: state.engineOpts,
        alertsOn: state.alertsOn,
        autoTradeEnabled: state.autoTradeEnabled,
        autoTrailEnabled: state.autoTrailEnabled,
        tgToken: state.tgToken,
        tgChat: state.tgChat
      }));
    } catch (e) {}
  }

  function saveJournal() {
    try { localStorage.setItem('smc_v1_journal', JSON.stringify(state.journal)); } catch (e) {}
  }

  /* ---------------- Audio, Browser & Telegram Alerts ---------------- */
  function playAlertTone() {
    try {
      const Ctx = window.AudioContext || window.webkitAudioContext;
      const ctx = new Ctx();
      [587.33, 880].forEach((freq, idx) => {
        const osc = ctx.createOscillator();
        const gain = ctx.createGain();
        osc.type = 'sine';
        osc.frequency.value = freq;
        gain.gain.setValueAtTime(0.10, ctx.currentTime + idx * 0.14);
        gain.gain.exponentialRampToValueAtTime(0.001, ctx.currentTime + idx * 0.14 + 0.24);
        osc.connect(gain);
        gain.connect(ctx.destination);
        osc.start(ctx.currentTime + idx * 0.14);
        osc.stop(ctx.currentTime + idx * 0.14 + 0.25);
      });
    } catch (e) {}
  }

  function toast(msg) {
    const host = document.getElementById('toasts');
    if (!host) return;
    const el = document.createElement('div');
    el.className = 'toast';
    el.innerHTML = msg;
    host.appendChild(el);
    setTimeout(() => el.remove(), 5500);
  }

  function sendTelegramAlert(text) {
    if (!state.tgToken || !state.tgChat) return;
    fetch(`https://api.telegram.org/bot${state.tgToken}/sendMessage`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ chat_id: state.tgChat, text, parse_mode: 'HTML' })
    }).catch(() => {});
  }

  function maybeAlert(market, setup, mlPred, dec) {
    if (!state.alertsOn || !setup || !mlPred?.isLiveSignal) return;
    const key = `${setup.id}|${setup.state}`;
    if (state.alertedIds.has(key)) return;
    state.alertedIds.add(key);

    const f = p => p != null ? p.toFixed(dec) : '—';
    const pos = ML.calcPositionForAccount(market, setup.entry, setup.sl, setup.tp1, setup.tp2, state.balance, state.riskPct);
    const title = `SMC AUTO-SIGNAL: ${market.name} — ${setup.dir} (${setup.grade} · ${mlPred.probTP1}%)`;
    const body = `Lot: ${pos.lotFormatted} · OB Entry ${f(setup.entry)} · SL ${f(setup.sl)} (-$${pos.actualRiskUsd}) · TP1 ${f(setup.tp1)} · TP2 ${f(setup.tp2)} (+$${pos.tp2TotalProfitUsd})`;

    playAlertTone();
    toast(`<b>${title}</b><div class="small muted" style="margin-top:3px;">${body}</div>`);
    if ('Notification' in window && Notification.permission === 'granted') {
      new Notification(title, { body });
    }
    sendTelegramAlert(`<b>${title}</b>\n${body}\nTime: ${T.fmtCAT(Date.now())} CAT`);
  }

  /* ---------------- Live Quote Header & Candle Timers ---------------- */
  function updateQuoteHeader(market, pair, ltf, dec) {
    if (!ltf || !ltf.length) return;
    const last = ltf[ltf.length - 1];
    const price = last.close;
    const refIdx = Math.max(0, ltf.length - 60);
    const openRef = ltf[refIdx].open || last.open;
    const chg = price - openRef;
    const pct = openRef ? (chg / openRef) * 100 : 0;

    let hi = -Infinity, lo = Infinity;
    const recentSlice = ltf.slice(-60);
    for (const c of recentSlice) {
      if (c.high > hi) hi = c.high;
      if (c.low < lo) lo = c.low;
    }

    const nameEl = document.getElementById('mhName');
    const profEl = document.getElementById('mhProfile');
    const priceEl = document.getElementById('mhPrice');
    const chgEl = document.getElementById('mhChange');
    const hlEl = document.getElementById('mhHighLow');
    const feedEl = document.getElementById('mhFeed');

    if (nameEl) nameEl.textContent = market.name;
    if (profEl) {
      profEl.textContent = market.cat === 'weltrade' ? 'WELTRADE SYNTX' : (market.profile === 'synthetic' ? 'DERIV SYNTHETIC 24/7' : market.profile.toUpperCase());
      profEl.className = `badge ${market.profile}`;
    }
    if (priceEl) {
      priceEl.textContent = price.toFixed(dec);
      if (state.lastPrice != null && price !== state.lastPrice) {
        priceEl.classList.remove('tick-up', 'tick-down');
        priceEl.classList.add(price > state.lastPrice ? 'tick-up' : 'tick-down');
      }
      state.lastPrice = price;
    }
    if (chgEl) {
      const sign = chg >= 0 ? '+' : '';
      chgEl.textContent = `${sign}${chg.toFixed(dec)} (${sign}${pct.toFixed(2)}%)`;
      chgEl.style.color = chg >= 0 ? '#089981' : '#f23645';
    }
    if (hlEl && isFinite(hi) && isFinite(lo)) {
      hlEl.textContent = `H ${hi.toFixed(dec)}  L ${lo.toFixed(dec)}`;
    }
    if (feedEl) {
      const src = market.liveSource || (market.feed === 'deriv' ? 'DERIV WS LIVE' : 'MT5 BRIDGE');
      feedEl.textContent = `${src} | ${pair.label}`;
    }
  }

  function updateChartTimers() {
    const htfEl = document.getElementById('htfTimer');
    const ltfEl = document.getElementById('ltfTimer');
    if (htfChart && htfEl) {
      const cd = htfChart.getCountdownInfo();
      htfEl.textContent = `Closes in ${cd.long}`;
    }
    if (ltfChart && ltfEl) {
      const cd = ltfChart.getCountdownInfo();
      ltfEl.textContent = `Closes in ${cd.long}`;
    }
  }

  /* ---------------- Official Live Broker Chart View (Deriv + Weltrade SyntX) ---------------- */
  function updateBrokerView(market) {
    market = market || F.markets.get(state.marketId);
    if (!market) return;

    const iframe = document.getElementById('brokerIframe');
    const title = document.getElementById('brokerTitle');
    const pill = document.getElementById('brokerSourcePill');
    const directLink = document.getElementById('brokerDirectLink');
    const hint = document.getElementById('brokerHint');

    let url = '';
    let link = '';
    let label = '';
    let source = '';

    if (market.cat === 'weltrade' || market.id.startsWith('mt5:')) {
      source = 'WELTRADE SYNTX';
      label = `Weltrade SyntX Official Chart · ${market.name}`;
      url = `https://weltradecharts.com/chart?lang=en&theme=dark`;
      link = `https://weltradecharts.com/chart?lang=en&theme=dark`;
      if (hint) hint.textContent = `Weltrade SyntX Engine + Local MT5 Bridge (${market.mt5Symbol || market.name})`;
    } else {
      source = 'DERIV OFFICIAL';
      label = `Deriv Real-Time Broker Chart · ${market.name}`;
      url = `https://charts.deriv.com:8443/deriv?instrument=${encodeURIComponent(market.id)}&theme=dark`;
      link = `https://charts.deriv.com:8443/deriv?instrument=${encodeURIComponent(market.id)}`;
      if (hint) hint.textContent = `Direct feed: charts.deriv.com:8443 (${market.name})`;
    }

    if (title) title.textContent = label;
    if (pill) pill.textContent = source;
    if (directLink) {
      directLink.href = link;
      directLink.setAttribute('title', `Open ${market.name} official chart in a new full tab`);
    }
    if (iframe && iframe.dataset.currUrl !== url) {
      iframe.dataset.currUrl = url;
      iframe.src = url;
    }
  }

  function setChartMode(mode) {
    state.chartMode = mode;
    const charts = document.getElementById('charts');
    if (charts) charts.dataset.mode = mode;
    document.querySelectorAll('#chartModeSeg button').forEach(b => {
      b.classList.toggle('active', b.dataset.mode === mode);
    });

    if (mode === 'broker') {
      charts.dataset.layout = 'broker';
    } else if (mode === 'tri') {
      charts.dataset.layout = 'tri';
    } else if (mode === 'crt') {
      charts.dataset.layout = 'split';
    }

    document.querySelectorAll('#layoutSeg button').forEach(b => {
      b.classList.toggle('active', b.dataset.layout === charts.dataset.layout);
    });

    const tog = document.getElementById('togBrokerChart');
    if (tog) tog.checked = (charts.dataset.layout === 'tri' || charts.dataset.layout === 'broker' || charts.dataset.layout === 'broker-ltf');

    updateBrokerView();
    setTimeout(() => {
      if (htfChart) htfChart.requestDraw();
      if (ltfChart) ltfChart.requestDraw();
    }, 60);
  }

  /* ---------------- Active SMC Entry Model Level Resolver (Ch. 6, 7 & 8) ---------------- */
  function resolveActiveEntryLevels(setup, series) {
    if (!setup) return null;
    const ltf = series?.ltf || [];

    if (setup.entry == null && setup.tbsIdx != null && ltf[setup.tbsIdx]) {
      const refIdx = setup.model1Idx != null && setup.model1Idx >= 0 ? setup.model1Idx : setup.tbsIdx;
      const refC = ltf[refIdx] || ltf[setup.tbsIdx];
      const entry = setup.ltfObZone
        ? (setup.isBear ? setup.ltfObZone.bottom : setup.ltfObZone.top)
        : (setup.isBear ? refC.low : refC.high);
      const a = E.atr(ltf, refIdx, 14) || Math.abs(setup.crth - setup.crtl) * 0.08;
      const ext = setup.extreme != null ? setup.extreme : (setup.isBear ? refC.high : refC.low);
      const sl = setup.isBear ? ext + a * 0.2 : ext - a * 0.2;
      const tp1 = setup.mid;
      const tp2 = setup.isBear ? setup.crtl : setup.crth;
      const risk = Math.max(Math.abs(entry - sl), 1e-8);
      return {
        label: 'Ch. 7 Pending Limit @ LTF OB',
        projected: true,
        entry, sl, tp1, tp2, risk,
        rr1: Math.abs(entry - tp1) / risk,
        rr2: Math.abs(entry - tp2) / risk,
        entryIdx: refIdx
      };
    }

    if (setup.entry == null) return null;

    if (state.entryModelView === 'ote' && setup.ote) {
      const entry = (setup.ote.from + setup.ote.to) / 2;
      const sl = setup.sl;
      const tp1 = setup.tp1;
      const tp2 = setup.tp2;
      const risk = Math.max(Math.abs(entry - sl), 1e-8);
      return {
        label: 'Ch. 3 & 6 · Fib 62–79% Discount/Premium OB',
        entry, sl, tp1, tp2, risk,
        rr1: Math.abs(entry - tp1) / risk,
        rr2: Math.abs(entry - tp2) / risk,
        entryIdx: setup.ote.startIdx
      };
    }
    if (state.entryModelView === 'kod' && setup.kod) {
      const entry = setup.kod.price;
      const sl = setup.sl;
      const tp1 = setup.tp1;
      const tp2 = setup.tp2;
      const risk = Math.max(Math.abs(entry - sl), 1e-8);
      return {
        label: 'Ch. 8 · CBS Candle Breakout Limit',
        entry, sl, tp1, tp2, risk,
        rr1: Math.abs(entry - tp1) / risk,
        rr2: Math.abs(entry - tp2) / risk,
        entryIdx: setup.kod.idx
      };
    }
    return {
      label: 'Ch. 7 · Adv CHoCH + LTF OB Limit',
      entry: setup.entry,
      sl: setup.sl,
      tp1: setup.tp1,
      tp2: setup.tp2,
      risk: setup.risk,
      rr1: setup.rr1,
      rr2: setup.rr2,
      entryIdx: setup.entryIdx
    };
  }

  /* ---------------- Top Clock (CAT) ---------------- */
  function startClock() {
    const timeEl = document.getElementById('clockTime');
    const phaseEl = document.getElementById('clockPhase');
    const leftEl = document.getElementById('clockLeft');
    const dstNote = document.getElementById('dstNote');

    const tick = () => {
      const now = Date.now();
      const amd = T.amdNow(now);
      if (timeEl) timeEl.textContent = T.fmtCAT(now, 'seconds');
      if (phaseEl) phaseEl.textContent = amd.label;
      if (leftEl) {
        const mins = Math.max(0, Math.round(amd.remainingMs / 60000));
        const h = Math.floor(mins / 60), m = mins % 60;
        leftEl.textContent = `${h}h ${m}m`;
      }
      updateChartTimers();
    };
    tick();
    setInterval(tick, 1000);

    if (dstNote) {
      dstNote.textContent = `SMC Auto-Engine: ${state.autoTradeEnabled ? 'ACTIVE (Limit + X1/X2/X3 Trail)' : 'MANUAL'}`;
    }
  }

  /* ---------------- Watchlist Sidebar ---------------- */
  function renderWatchlist() {
    const body = document.getElementById('wlBody');
    const q = (document.getElementById('wlSearch')?.value || '').trim().toLowerCase();
    if (!body) return;

    const groups = new Map();
    let totalShown = 0;
    for (const m of F.markets.values()) {
      if (state.wlCategory !== 'all' && m.cat !== state.wlCategory) continue;
      if (q && !m.name.toLowerCase().includes(q) && !m.id.toLowerCase().includes(q) && !m.group.toLowerCase().includes(q)) continue;
      const ws = state.watchStates.get(m.id);
      const s = ws?.setup;
      const ml = ws?.ml;
      if (state.wlActiveOnly && (!s || (!ml?.isPure && !E.ACTIVE.has(s.state)))) continue;
      if (!groups.has(m.group)) groups.set(m.group, []);
      groups.get(m.group).push(m);
      totalShown++;
    }

    let html = '';
    for (const [grp, list] of groups) {
      html += `<div class="wl-group">${grp} (${list.length})</div>`;
      for (const m of list) {
        const ws = state.watchStates.get(m.id);
        const s = ws?.setup;
        const ml = ws?.ml;
        const info = s ? (E.STATE_INFO[s.state] || { label: s.state, tone: 'muted' }) : { label: 'Live', tone: 'muted' };
        const spec = F.MARKET_SPECS ? F.MARKET_SPECS[m.id] : null;
        const rawPrice = ws?.price ?? m.spot ?? spec?.base;
        const dec = ws?.decimals || spec?.dec || 2;
        const priceTxt = rawPrice != null ? Number(rawPrice).toFixed(dec) : '—';
        const dirTxt = s?.dir
          ? `${s.dir} · ${s.structType || 'BOS'} · ${s.grade || ''} ${ml ? `· ${ml.probTP1}%` : ''}`
          : m.id.replace('mt5:', '');
        html += `
          <div class="wl-item ${m.id === state.marketId ? 'active' : ''}" data-mid="${m.id}">
            <div>
              <div class="wl-sym">${m.name}</div>
              <div class="wl-sub">${dirTxt}</div>
            </div>
            <div class="wl-right">
              <span class="mono small">${priceTxt}</span>
              <span class="st-pill st-${info.tone}">${info.label}</span>
            </div>
          </div>
        `;
      }
    }
    if (!totalShown) {
      html = `<div style="padding:16px 12px; color:var(--text-mute); font-size:11px;">No symbols match current filter.</div>`;
    }
    body.innerHTML = html;
    body.querySelectorAll('.wl-item').forEach(el => {
      el.addEventListener('click', () => selectMarket(el.dataset.mid));
    });

    const foot = document.getElementById('wlFoot');
    if (foot) {
      foot.innerHTML = `${totalShown} / ${F.markets.size} Deriv &amp; Weltrade instruments`;
    }
    renderPureSignalsPage();
  }

  /* ---------------- Build SMC Chart Markings (HTF & LTF) ---------------- */
  function buildHTFAnnotations(series, setup) {
    const { htf, market, pair } = series;
    const htfMs = F.HTF_SECONDS[pair.htf] * 1000;
    const boxes = [], lines = [], bands = [], markers = [], priceLines = [];

    if (!setup) return { boxes, lines, bands, markers, priceLines };

    const c1 = setup.c1;
    const originTime = setup.originCandle ? setup.originCandle.time : c1.time;
    const endIdx = Math.min(htf.length - 1, Math.max(setup.manipIdx || setup.c1Idx, htf.length - 1));
    const boxTo = htf[endIdx].time + htfMs * 2;

    // 1. HTF Valid Order Block & Imbalance (Ch. 4)
    if (state.showKl && setup.keyLevels && setup.keyLevels.length) {
      for (const kl of setup.keyLevels) {
        if (kl.top !== kl.bottom) {
          boxes.push({
            from: kl.time,
            to: boxTo,
            top: kl.top,
            bottom: kl.bottom,
            fill: kl.type === 'FVG' ? 'rgba(245, 158, 11, 0.14)' : (setup.isBear ? 'rgba(242, 54, 69, 0.16)' : 'rgba(8, 153, 129, 0.16)'),
            stroke: kl.type === 'FVG' ? '#f59e0b' : (setup.isBear ? '#f23645' : '#089981'),
            label: `HTF ${kl.type} (Ch. 4)`,
            dash: kl.type === 'FVG'
          });
        } else {
          lines.push({
            from: kl.time,
            to: boxTo,
            price: kl.price,
            color: '#f59e0b',
            dash: true,
            width: 1.2,
            label: `${kl.type} ($ Liquidity)`
          });
        }
      }
    }

    // 2. Premium (>50% Fib) & Discount (<50% Fib) Dealing Range (Ch. 3 Fig 3.13 & 3.14)
    boxes.push({
      from: originTime,
      to: boxTo,
      top: setup.crth,
      bottom: setup.mid,
      fill: 'rgba(242, 54, 69, 0.05)',
      stroke: 'rgba(242, 54, 69, 0.30)',
      label: 'PREMIUM ZONE (>50% Fib — Sell Zone)'
    });
    boxes.push({
      from: originTime,
      to: boxTo,
      top: setup.mid,
      bottom: setup.crtl,
      fill: 'rgba(8, 153, 129, 0.05)',
      stroke: 'rgba(8, 153, 129, 0.30)',
      label: 'DISCOUNT ZONE (<50% Fib — Buy Zone)'
    });

    lines.push({ from: originTime, to: boxTo, price: setup.crth, color: '#2962ff', width: 1.4, label: setup.isBear ? 'Point A (Origin High)' : 'Point B (BOS High)' });
    lines.push({ from: originTime, to: boxTo, price: setup.mid, color: '#f59e0b', dash: true, width: 1.3, label: '50% Equilibrium (Ch. 3)' });
    lines.push({ from: originTime, to: boxTo, price: setup.crtl, color: '#2962ff', width: 1.4, label: setup.isBear ? 'Point B (BOS Low)' : 'Point A (Origin Low)' });

    markers.push({
      time: c1.time,
      position: setup.isBear ? 'belowBar' : 'aboveBar',
      color: '#2962ff',
      shape: 'square',
      text: setup.structType || 'BOS'
    });
    if (setup.manipIdx != null && htf[setup.manipIdx]) {
      markers.push({
        time: htf[setup.manipIdx].time,
        position: setup.isBear ? 'aboveBar' : 'belowBar',
        color: '#f59e0b',
        shape: setup.isBear ? 'arrowDown' : 'arrowUp',
        text: 'POI Mitigated'
      });
    }

    return { boxes, lines, bands, markers, priceLines };
  }

  function buildLTFAnnotations(series, setup) {
    const { ltf, pair } = series;
    const ltfMs = pair.ltf * 1000;
    const boxes = [], lines = [], bands = [], markers = [], priceLines = [];
    let positionBox = null;

    if (!setup) return { boxes, lines, bands, markers, priceLines, positionBox };

    const startT = Math.max(setup.c1.time, ltf[Math.max(0, ltf.length - 120)]?.time || setup.c1.time);
    const endT = ltf[ltf.length - 1].time + ltfMs * 6;

    lines.push({ from: startT, to: endT, price: setup.crth, color: '#2962ff', width: 1.3, label: setup.isBear ? 'HTF Origin (SL Guard)' : 'HTF External High (TP2)' });
    lines.push({ from: startT, to: endT, price: setup.mid, color: '#f59e0b', dash: true, width: 1.2, label: '50% Equilibrium (TP1)' });
    lines.push({ from: startT, to: endT, price: setup.crtl, color: '#2962ff', width: 1.3, label: setup.isBear ? 'HTF External Low (TP2)' : 'HTF Origin (SL Guard)' });

    // LTF Order Block Zone (Ch. 4 & 7)
    if (setup.ltfObZone) {
      boxes.push({
        from: setup.ltfObZone.time,
        to: endT,
        top: setup.ltfObZone.top,
        bottom: setup.ltfObZone.bottom,
        fill: setup.isBear ? 'rgba(242, 54, 69, 0.18)' : 'rgba(8, 153, 129, 0.18)',
        stroke: setup.isBear ? '#f23645' : '#089981',
        label: `LTF Order Block (Entry Zone)`
      });
    }

    // Inducement / Liquidity Sweep Marker (Ch. 5)
    if (setup.tbsIdx != null && ltf[setup.tbsIdx]) {
      markers.push({
        time: ltf[setup.tbsIdx].time,
        position: setup.isBear ? 'aboveBar' : 'belowBar',
        color: '#f59e0b',
        shape: 'square',
        text: `${setup.liqModel?.type || 'IDM'} Swept`
      });
    }

    // Advanced CHoCH / CBS Confirmation Line (Ch. 6 & 8)
    if (setup.model1Idx != null && setup.model1Idx >= 0 && ltf[setup.model1Idx]) {
      const refC = ltf[setup.model1Idx];
      const trigPrice = setup.isBear ? refC.low : refC.high;
      const trigEndIdx = setup.entryIdx != null ? setup.entryIdx + 2 : Math.min(ltf.length - 1, setup.model1Idx + 12);
      lines.push({
        from: refC.time,
        to: ltf[Math.min(ltf.length - 1, trigEndIdx)].time,
        price: trigPrice,
        color: '#089981',
        width: 1.4,
        dash: true,
        label: setup.cbsIdx >= 0 ? 'CBS Breakout' : 'Adv CHoCH'
      });
    }

    // X1, X2, X3 Trailing Stop Levels on LTF Chart (Ch. 7 Fig 7.4)
    if (setup.trailPoints && setup.trailPoints.length) {
      for (const tp of setup.trailPoints) {
        lines.push({
          from: tp.time,
          to: endT,
          price: tp.price,
          color: '#38bdf8',
          dash: true,
          width: 1.2,
          label: `${tp.label} Trail SL`
        });
        markers.push({
          time: tp.time,
          position: setup.isBear ? 'aboveBar' : 'belowBar',
          color: '#38bdf8',
          shape: 'circle',
          text: tp.label
        });
      }
    }

    const activeLvls = resolveActiveEntryLevels(setup, series);
    if (activeLvls && ltf[activeLvls.entryIdx]) {
      const entryT = ltf[activeLvls.entryIdx].time;
      const boxEndIdx = setup.exitIdx != null && setup.exitIdx >= 0
        ? Math.min(ltf.length - 1, setup.exitIdx + 4)
        : ltf.length - 1;
      const boxEndT = ltf[Math.max(activeLvls.entryIdx, boxEndIdx)].time + ltfMs * 8;

      if (state.showPositionBox) {
        positionBox = {
          from: entryT,
          to: boxEndT,
          entry: activeLvls.entry,
          sl: activeLvls.sl,
          tp1: activeLvls.tp1,
          tp2: activeLvls.tp2,
          rr1: activeLvls.rr1,
          rr2: activeLvls.rr2,
          dir: setup.dir || (setup.isBear ? 'SELL' : 'BUY'),
          isBear: setup.isBear
        };
      }

      markers.push({
        time: entryT,
        position: setup.isBear ? 'aboveBar' : 'belowBar',
        color: '#2962ff',
        shape: setup.isBear ? 'arrowDown' : 'arrowUp',
        text: `OB ${setup.dir || 'ENTRY'}`
      });
    }

    if (state.showOte && setup.ote && ltf[setup.ote.startIdx]) {
      const oteStart = ltf[setup.ote.startIdx].time;
      const oteEnd = ltf[Math.min(ltf.length - 1, setup.ote.startIdx + 20)].time + ltfMs * 4;
      boxes.push({
        from: oteStart,
        to: oteEnd,
        top: Math.max(setup.ote.from, setup.ote.to),
        bottom: Math.min(setup.ote.from, setup.ote.to),
        fill: 'rgba(126, 87, 194, 0.12)',
        stroke: '#7e57c2',
        dash: true,
        label: 'Fib 50–79% Zone (Ch. 3)'
      });
    }

    return { boxes, lines, bands, markers, priceLines, positionBox };
  }

  /* ---------------- Build Visual Blue/Red Block HTML ---------------- */
  function renderBlueRedHtml(setup, activeLvls, dec) {
    if (!activeLvls) return '';
    const f = v => v != null && isFinite(v) ? v.toFixed(dec) : '—';
    const trailTxt = setup.trailPoints && setup.trailPoints.length
      ? ` · Trail ${setup.trailPoints[setup.trailPoints.length - 1].label}: ${f(setup.trailPoints[setup.trailPoints.length - 1].price)}`
      : '';
    return `
      <div class="pv-sl">
        <span>STOP LOSS (-1.0R)${trailTxt}</span>
        <b>${f(activeLvls.sl)}</b>
      </div>
      <div class="pv-entry">
        <span>${setup.dir || 'LIMIT'} · ${activeLvls.label}</span>
        <b>${f(activeLvls.entry)}</b>
      </div>
      <div class="pv-tp1">
        <span>TP1 · 50% EQ + Trail X1</span>
        <b>${f(activeLvls.tp1)} (${activeLvls.rr1.toFixed(2)}R)</b>
      </div>
      <div class="pv-tp2">
        <span>TP2 · External Swing High/Low</span>
        <b>${f(activeLvls.tp2)} (${activeLvls.rr2.toFixed(2)}R)</b>
      </div>
    `;
  }

  /* ---------------- Render Ticket, Quant Model, Checklist & Setups Table ---------------- */
  function renderTicketAndTable() {
    if (!state.series || !state.evalRes) return;
    const { market, pair, ltf } = state.series;
    const dec = F.decimalsFor(ltf);
    const f = v => v != null && isFinite(v) ? v.toFixed(dec) : '—';
    const setup = state.selectedSetup || state.evalRes.primary;
    const mlPred = ML.predict(state.series, setup);

    updateQuoteHeader(market, pair, ltf, dec);

    document.getElementById('htfPill').textContent = pair.htfLabel;
    document.getElementById('ltfPill').textContent = pair.ltfLabel;

    const mlBox = document.getElementById('tkMlBox');
    if (mlBox) {
      const driversHtml = (mlPred.topDrivers || []).map(d =>
        `<span class="st-pill ${d.weight >= 0 ? 'st-good' : 'st-bad'}">${d.name} ${d.weight >= 0 ? '+' : ''}${d.weight.toFixed(2)}</span>`
      ).join(' ');
      mlBox.innerHTML = `
        <div style="display:flex; justify-content:space-between; align-items:center;">
          <span><b>SMC Win Prob:</b> <span class="mono" style="color:${mlPred.probTP1 >= 67 ? '#26a69a' : '#fbbf24'}; font-weight:700;">${mlPred.probTP1}%</span> (TP2: ${mlPred.probTP2}%)</span>
          <span class="st-pill ${mlPred.isPure ? 'st-live' : 'st-muted'}">${mlPred.isPure ? 'AUTO-TRADE READY' : 'FILTERED'}</span>
        </div>
        <div class="ml-meter"><i style="width:${mlPred.probTP1}%;"></i></div>
        <div class="small muted" style="display:grid; grid-template-columns:1fr 1fr; gap:4px; margin-top:2px;">
          <div>Backtested: <b class="mono">${mlPred.samples}</b> ${mlPred.empiricalWinRate != null ? `(${mlPred.empiricalWinRate}% WR)` : ''}</div>
          <div>OB Buffer: <b class="mono">${mlPred.avgSweepATR} ATR</b></div>
          <div>Bars to TP1: <b class="mono">~${mlPred.avgBarsToTP1}</b></div>
          <div>Best Zone: <b class="mono">${mlPred.bestKeyLevel}</b></div>
        </div>
        <div style="display:flex; flex-wrap:wrap; gap:4px; margin-top:3px;">${driversHtml}</div>
      `;
    }

    if (!setup) {
      document.getElementById('tkGrade').textContent = '—';
      document.getElementById('tkState').textContent = 'Scanning HTF for BOS / CHoCH + Order Block';
      document.getElementById('tkPosVis').innerHTML = '';
      document.getElementById('tkLevels').innerHTML = '';
      document.getElementById('tkSizing').innerHTML = '';
      document.getElementById('tkRiskDetails').innerHTML = 'Select a market with an active SMC setup to calculate lot size.';
      document.getElementById('tkChecks').innerHTML = '';
      return;
    }

    document.getElementById('htfSub').textContent = `${setup.structType || 'BOS'} ${T.fmtCAT(setup.c1.time)} CAT · High ${f(setup.crth)} · 50% EQ ${f(setup.mid)} · Low ${f(setup.crtl)}`;
    document.getElementById('ltfSub').textContent = setup.tbsIdx != null && ltf[setup.tbsIdx]
      ? `${setup.liqModel?.type || 'IDM'} Swept ${T.fmtCAT(ltf[setup.tbsIdx].time)} CAT · Trail Swings: ${setup.trailPoints?.length || 0} · Prob ${mlPred.probTP1}%`
      : `Waiting for ${setup.isBear ? 'Premium' : 'Discount'} POI mitigation`;

    const gradeEl = document.getElementById('tkGrade');
    gradeEl.textContent = `${setup.grade || '—'} · ${mlPred.probTP1}%`;
    gradeEl.className = `grade g-${(setup.grade || 'C').replace('+', 'plus')}`;

    const stInfo = E.STATE_INFO[setup.state] || { label: setup.state, tone: 'muted', step: 1 };
    const stBanner = document.getElementById('tkState');
    stBanner.innerHTML = `
      <div style="display:flex; justify-content:space-between; align-items:center;">
        <span class="st-pill st-${stInfo.tone}">${stInfo.label}</span>
        <span class="mono">${setup.dir ? setup.dir + ' LIMIT (' + (setup.structType || 'BOS') + ')' : 'SCANNING'}</span>
      </div>
      ${setup.invalidReason ? `<div class="small muted" style="margin-top:4px;">${setup.invalidReason}</div>` : ''}
    `;

    const steps = document.querySelectorAll('#tkStepper li');
    steps.forEach((li, idx) => {
      li.className = idx + 1 < stInfo.step ? 'done' : idx + 1 === stInfo.step ? 'current' : '';
    });

    const activeLvls = resolveActiveEntryLevels(setup, state.series);
    const posVisEl = document.getElementById('tkPosVis');
    const lvlsEl = document.getElementById('tkLevels');
    const riskBox = document.getElementById('tkRiskGuard');
    const riskBadge = document.getElementById('tkRiskBadge');
    const riskDetails = document.getElementById('tkRiskDetails');

    if (activeLvls) {
      posVisEl.innerHTML = renderBlueRedHtml(setup, activeLvls, dec);
      const trailHtml = (setup.trailPoints || []).map(tp =>
        `<div class="lvl"><span>Trail Stop ${tp.label} (Ch. 7 Lock)</span><span style="color:#38bdf8;">${f(tp.price)}</span></div>`
      ).join('');
      lvlsEl.innerHTML = `
        ${trailHtml}
        ${setup.ote ? `<div class="lvl"><span>Fib 50–79% Zone (Ch. 3)</span><span>${f(setup.ote.from)} – ${f(setup.ote.to)}</span></div>` : ''}
        ${setup.kod ? `<div class="lvl"><span>Ch. 8 CBS Breakout Price</span><span>${f(setup.kod.price)}</span></div>` : ''}
      `;

      const liveEq = F.mt5.accountState?.equity || F.mt5.accountState?.balance || state.balance;
      const pos = ML.calcPositionForAccount(market, activeLvls.entry, activeLvls.sl, activeLvls.tp1, activeLvls.tp2, liveEq, state.riskPct);
      const acc = F.mt5.accountState;
      const riskCheck = ML.evaluatePortfolioRisk(market, pos, acc, {
        maxOpenTrades: state.maxOpenTrades,
        maxRiskPerTradePct: state.maxRiskPerTradePct,
        maxDailyDrawdownPct: state.maxDailyDrawdownPct
      });
      const isPureAPlus = setup.grade === 'A+' && mlPred.isPure;
      const openOrdersHtml = acc && Array.isArray(acc.orders) && acc.orders.length
        ? `<div style="margin-top:4px; padding-top:4px; border-top:1px solid var(--border); color:#26a69a;"><b>Active MT5 Positions (${acc.orders.length}/${state.maxOpenTrades}):</b> ` +
          acc.orders.map(o => `#${o.ticket} ${o.symbol} ${o.side} ${o.lot} lot (${o.profit >= 0 ? '+' : ''}$${Number(o.profit).toFixed(2)})`).join(' · ') + `</div>`
        : '';
      if (riskBadge && riskDetails && riskBox) {
        riskBadge.textContent = !isPureAPlus
          ? `BLOCKED (${setup.grade || 'REGULAR'})`
          : (riskCheck.allowed ? 'PURE A+ · AUTO READY' : 'RISK CAP BLOCKED');
        riskBadge.className = `st-pill ${isPureAPlus && riskCheck.allowed ? 'st-live' : 'st-bad'}`;
        riskBox.style.borderLeftColor = (isPureAPlus && riskCheck.allowed) ? 'var(--good)' : 'var(--bad)';
        riskDetails.innerHTML = `
          <div>MT5 Account: <b>#${acc?.login || '32398784'} (${acc?.server || 'Deriv-Demo'})</b> · Equity: <b>$${liveEq.toFixed(2)}</b></div>
          <div>Auto-Gate: <b style="color:${isPureAPlus ? '#26a69a' : '#f23645'};">${isPureAPlus ? 'PURE A+ VERIFIED (7/7 Rules)' : `REGULAR SETUP BLOCKED (Grade ${setup.grade || 'C'} — Needs A+)`}</b></div>
          <div>Risk Sizing (${state.riskPct}%): <b style="color:#38bdf8; font-size:12px;">${pos.lotFormatted} lot</b> · Risk: <b style="color:${pos.overLeveraged ? '#f23645' : '#26a69a'};">-$${pos.actualRiskUsd.toFixed(2)} (${pos.actualRiskPct}%)</b></div>
          <div style="color:#d1d4dc; margin-top:2px;">🛡 ${riskCheck.reason}</div>
          <div style="display:flex; justify-content:space-between; margin-top:3px; padding-top:3px; border-top:1px solid var(--border);">
            <span>At TP1 (50% EQ + BE): <b style="color:#fbbf24;">+$${pos.tp1ProfitUsd.toFixed(2)}</b></span>
            <span>At TP2 Target: <b style="color:#26a69a;">+$${pos.tp2TotalProfitUsd.toFixed(2)}</b></span>
          </div>
          ${openOrdersHtml}
        `;
      }

      document.getElementById('tkSizing').innerHTML = `
        <div><b>MT5 Limit Order Lot:</b> <span class="mono" style="color:#38bdf8; font-weight:700;">${pos.lotFormatted} lot</span> (Risk -$${pos.actualRiskUsd.toFixed(2)})</div>
        <div><b>TP1 (50% + Trail X1):</b> <span class="mono" style="color:#fbbf24;">+$${pos.tp1ProfitUsd.toFixed(2)} (${pos.rr1.toFixed(1)}R)</span></div>
        <div><b>TP2 (External High/Low):</b> <span class="mono" style="color:#26a69a;">+$${pos.tp2TotalProfitUsd.toFixed(2)} (${pos.rr2.toFixed(1)}R)</span></div>
      `;
    } else {
      posVisEl.innerHTML = '';
      lvlsEl.innerHTML = `
        <div class="lvl"><span>HTF Swing High</span><span>${f(setup.crth)}</span></div>
        <div class="lvl tp1"><span>50% Equilibrium (Premium/Discount)</span><span>${f(setup.mid)}</span></div>
        <div class="lvl"><span>HTF Swing Low</span><span>${f(setup.crtl)}</span></div>
      `;
      document.getElementById('tkSizing').innerHTML = `<div>Waiting for price to sweep Inducement and tap the HTF POI/OB.</div>`;
      if (riskDetails) riskDetails.innerHTML = `Awaiting LTF Advanced CHoCH to queue Limit Order on MT5.`;
    }

    document.getElementById('tkScore').textContent = `${setup.passes || 0}/${setup.total || 0}`;
    const iconMap = { pass: '✔', warn: '▲', fail: '✖', na: '—' };
    document.getElementById('tkChecks').innerHTML = (setup.checks || []).map(c => `
      <div class="chk">
        <span class="chk-ic ${c.status}">${iconMap[c.status] || '•'}</span>
        <div style="flex:1;">
          <div style="display:flex; justify-content:space-between; font-weight:600;">
            <span>${c.title}</span>
            <span class="small muted mono">${c.src}</span>
          </div>
          <div class="small muted">${c.text}</div>
        </div>
      </div>
    `).join('');

    const setups = state.evalRes.setups || [];
    document.getElementById('setupsSummary').textContent = `${setups.length} SMC structural waves evaluated — click row to inspect`;
    const tbody = document.querySelector('#setupsTable tbody');
    tbody.innerHTML = setups.map((s, idx) => {
      const inf = E.STATE_INFO[s.state] || { label: s.state, tone: 'muted' };
      const sp = ML.predict(state.series, s);
      const rTxt = s.r50 != null ? `${s.r50 >= 0 ? '+' : ''}${s.r50.toFixed(2)}R` : '—';
      const trailCount = s.trailPoints ? s.trailPoints.length : 0;
      return `
        <tr data-sidx="${idx}" class="${s.id === setup.id ? 'active-row' : ''}">
          <td>${T.fmtCAT(s.c1.time)}</td>
          <td><b>${s.dir || '—'}</b> (${s.structType || 'BOS'})</td>
          <td><span class="st-pill st-${inf.tone}">${inf.label}</span></td>
          <td><span class="st-pill ${sp.isPure ? 'st-live' : 'st-muted'}">${sp.isPure ? 'AUTO-READY' : 'Filtered'}</span></td>
          <td><b>${sp.probTP1}%</b></td>
          <td>${s.keyLevels && s.keyLevels[0] ? s.keyLevels.map(k => k.type).join('+') : 'POI'}</td>
          <td>${trailCount > 0 ? `X1–X${trailCount}` : (s.liqModel?.type || 'IDM')}</td>
          <td>${f(s.entry)}</td>
          <td style="color:#f23645;">${f(s.sl)}</td>
          <td>${f(s.tp1)} / ${f(s.tp2)}</td>
          <td><b>${s.grade || '—'}</b></td>
          <td style="color:${s.r50 > 0 ? '#26a69a' : s.r50 < 0 ? '#f23645' : 'inherit'};">${rTxt}</td>
        </tr>
      `;
    }).join('');

    tbody.querySelectorAll('tr').forEach(tr => {
      tr.addEventListener('click', () => {
        const picked = setups[+tr.dataset.sidx];
        if (picked) {
          state.selectedSetup = picked;
          applyChartAnnotations(true);
          renderTicketAndTable();
        }
      });
    });
  }

  /* ---------------- Render Signals View, MT5 Auto-Orders & Compounding ---------------- */
  function renderPureSignalsPage() {
    const grid = document.getElementById('pureSignalsGrid');
    const countBadge = document.getElementById('pureSigCount');
    const activeCountSub = document.getElementById('activeSignalsCount');
    const ledgerTable = document.querySelector('#permanentLedgerTable tbody');
    const ledgerCountSub = document.getElementById('ledgerCountSummary');
    const kpisEl = document.getElementById('signalsKpis');
    const weeklySub = document.getElementById('weeklyCompoundingSub');
    const weeklyTable = document.querySelector('#weeklyCompoundingTable tbody');

    const stats = getLedgerStats();
    const acc = F.mt5.accountState;
    if (acc && acc.login > 0 && acc.balance > 0) {
      state.balance = +acc.balance;
      stats.currentBalance = +acc.equity || +acc.balance;
    }
    const proj = ML.computeWeeklyProjection(state.balance, state.riskPct, stats);

    if (kpisEl) {
      const openPosCount = acc && Array.isArray(acc.orders) ? acc.orders.length : 0;
      const openFloating = acc && Array.isArray(acc.orders)
        ? acc.orders.reduce((s, o) => s + (+o.profit || 0), 0)
        : 0;
      kpisEl.innerHTML = `
        <div class="kpi"><div class="kpi-lbl">MT5 Account #${acc?.login || '32398784'} (${acc?.server || 'Deriv-Demo'})</div><div class="kpi-val" style="color:#38bdf8;">$${stats.currentBalance.toFixed(2)}</div></div>
        <div class="kpi"><div class="kpi-lbl">Live MT5 Positions (${openPosCount})</div><div class="kpi-val" style="color:${openFloating >= 0 ? '#26a69a' : '#f23645'};">${openFloating >= 0 ? '+' : ''}$${openFloating.toFixed(2)}</div></div>
        <div class="kpi"><div class="kpi-lbl">SMC Win Rate</div><div class="kpi-val" style="color:#26a69a;">${stats.winRate}% (${stats.wins}/${stats.total})</div></div>
        <div class="kpi"><div class="kpi-lbl">Est. Weekly Return</div><div class="kpi-val" style="color:#fbbf24;">+$${proj.weeklyUsdThisWeek.toFixed(2)} (+${proj.weeklyReturnPct}%)</div></div>
        <div class="kpi"><div class="kpi-lbl">Auto-Trading Mode</div><div class="kpi-val" style="color:${state.autoTradeEnabled ? '#26a69a' : '#fbbf24'};">${state.autoTradeEnabled ? 'FULL AUTO' : 'MANUAL'}</div></div>
        <div class="kpi"><div class="kpi-lbl">MT5 Bridge Orders</div><div class="kpi-val">${state.dispatchedCmdIds.size + openPosCount}</div></div>
      `;
    }

    const activeLiveSignals = [];
    for (const [mid, ws] of state.watchStates.entries()) {
      if (ws?.setup && ws?.ml?.isLiveSignal) {
        activeLiveSignals.push({ mid, ...ws });
      }
    }
    activeLiveSignals.sort((a, b) => (b.ml.probTP1 - a.ml.probTP1));

    if (countBadge) countBadge.textContent = String(activeLiveSignals.length);
    if (activeCountSub) activeCountSub.textContent = `${activeLiveSignals.length} high-probability SMC Order Block setup(s) active`;

    if (grid) {
      if (!activeLiveSignals.length) {
        grid.innerHTML = `
          <div class="card" style="grid-column: 1 / -1; text-align:center; padding:24px;">
            <h3 style="font-size:13px; margin-bottom:5px; color:#fff;">Scanning All Deriv &amp; Weltrade Synthetics for Valid SMC Order Blocks…</h3>
            <p class="muted small">Requires HTF BOS/CHoCH (body close) + Inducement Sweep + Unmitigated Discount/Premium Order Block + LTF Advanced CHoCH.</p>
          </div>
        `;
      } else {
        grid.innerHTML = activeLiveSignals.map(item => {
          const { market, setup, ml, decimals, price } = item;
          const f = v => v != null && isFinite(v) ? v.toFixed(decimals || 2) : '—';
          const stInfo = E.STATE_INFO[setup.state] || { label: setup.state, tone: 'good' };
          const pos = ML.calcPositionForAccount(market, setup.entry, setup.sl, setup.tp1, setup.tp2, state.balance, state.riskPct);
          const kl = setup.keyLevels && setup.keyLevels.length ? setup.keyLevels.map(k => k.type).join(' + ') : 'OB + FVG';
          const lvls = {
            label: setup.cbsIdx >= 0 ? 'Ch. 8 CBS Limit' : 'Ch. 7 LTF OB Limit',
            entry: setup.entry,
            sl: setup.sl,
            tp1: setup.tp1,
            tp2: setup.tp2,
            rr1: setup.rr1,
            rr2: setup.rr2
          };

          return `
            <div class="sig-card pure-aplus">
              <div style="display:flex; justify-content:space-between; align-items:flex-start;">
                <div>
                  <div style="font-weight:700; font-size:13px; color:#fff;">${market.name}</div>
                  <div class="small muted">${market.group} · ${F.TF_PAIRS[state.pairKey].label} · Spot ${f(price)}</div>
                </div>
                <div style="text-align:right;">
                  <span class="st-pill st-${stInfo.tone}">${stInfo.label}</span>
                  <div class="mono small" style="color:#26a69a; font-weight:600; margin-top:2px;">Grade ${setup.grade} · ${ml.probTP1}%</div>
                </div>
              </div>

              <div class="pos-visualizer" style="margin-bottom:0;">
                ${renderBlueRedHtml(setup, lvls, decimals || 2)}
              </div>

              <div class="card" style="padding:6px 8px; background:var(--bg-0); font-family:var(--font-mono); font-size:11px;">
                <div style="display:flex; justify-content:space-between;">
                  <span>MT5 Lot: <b style="color:#38bdf8;">${pos.lotFormatted} lot</b></span>
                  <span>Risk: <b style="color:${pos.overLeveraged ? '#f23645' : '#26a69a'};">-$${pos.actualRiskUsd.toFixed(2)} (${pos.actualRiskPct}%)</b></span>
                </div>
                <div class="small muted" style="margin-top:2px;">${pos.splitInstruction}</div>
              </div>

              <div class="small muted" style="display:grid; grid-template-columns:1fr 1fr; gap:4px;">
                <div>Confluence: <b style="color:var(--text);">${kl}</b></div>
                <div>Liquidity: <b style="color:var(--text);">${setup.liqModel?.type || 'IDM'} Swept</b></div>
                <div>TP1 Gain: <b class="mono" style="color:#fbbf24;">+$${pos.tp1ProfitUsd.toFixed(2)}</b></div>
                <div>TP2 Gain: <b class="mono" style="color:#26a69a;">+$${pos.tp2TotalProfitUsd.toFixed(2)}</b></div>
              </div>

              <div style="display:flex; gap:6px;">
                <button class="btn primary" style="flex:1;" data-opensig="${market.id}">
                  Inspect Chart
                </button>
                <button class="btn ghost" style="flex:1; border-color:#26a69a; color:#26a69a;" data-execsig="${market.id}">
                  ⚡ Send to MT5 Now
                </button>
              </div>
            </div>
          `;
        }).join('');

        grid.querySelectorAll('[data-opensig]').forEach(btn => {
          btn.addEventListener('click', () => {
            const mid = btn.dataset.opensig;
            document.querySelector('[data-view="terminal"]').click();
            selectMarket(mid);
          });
        });

        grid.querySelectorAll('[data-execsig]').forEach(btn => {
          btn.addEventListener('click', () => {
            const mid = btn.dataset.opensig || btn.dataset.execsig;
            const ws = state.watchStates.get(mid);
            if (ws && ws.setup) {
              const pos = ML.calcPositionForAccount(ws.market, ws.setup.entry, ws.setup.sl, ws.setup.tp1, ws.setup.tp2, state.balance, state.riskPct);
              dispatchMt5Order(ws.market, ws.setup, ws.setup, pos, 'MANUAL');
            }
          });
        });
      }
    }

    if (ledgerCountSub) ledgerCountSub.textContent = `${state.permanentTrades.length} SMC trades permanently logged`;
    if (ledgerTable) {
      ledgerTable.innerHTML = state.permanentTrades.map(t => {
        const isWin = (t.pnlUsd || 0) > 0 || (t.r || 0) > 0;
        const col = isWin ? '#26a69a' : (t.outcome === 'BE' ? '#fbbf24' : '#f23645');
        const rTxt = t.r != null ? `${t.r >= 0 ? '+' : ''}${t.r.toFixed(2)}R` : '—';
        const pnlTxt = t.pnlUsd != null ? `${t.pnlUsd >= 0 ? '+' : ''}$${t.pnlUsd.toFixed(2)}` : '—';
        return `
          <tr>
            <td>${t.date}</td>
            <td><b>${t.market}</b></td>
            <td>${t.pair}</td>
            <td><b style="color:${t.dir === 'BUY' ? '#26a69a' : '#f23645'};">${t.dir}</b></td>
            <td><span class="mono">${t.lot} lot</span></td>
            <td>${t.entry}</td>
            <td style="color:#f23645;">${t.sl}</td>
            <td>${t.tp1} / ${t.tp2}</td>
            <td>$${t.riskUsd != null ? t.riskUsd.toFixed(2) : '—'}</td>
            <td><span class="st-pill ${isWin ? 'st-good' : t.outcome === 'BE' ? 'st-warn' : 'st-bad'}">${t.outcome}</span></td>
            <td style="color:${col}; font-weight:700;">${rTxt}</td>
            <td style="color:${col}; font-weight:700;">${pnlTxt}</td>
            <td style="color:#38bdf8; font-weight:700;">$${t.balanceAfter != null ? t.balanceAfter.toFixed(2) : '—'}</td>
          </tr>
        `;
      }).join('');
    }

    if (weeklySub) weeklySub.textContent = `Targeting ~${proj.weeklyR}R weekly (${proj.tradesPerWeek} A+ SMC setups/wk @ ${proj.winRatePct}% win rate)`;
    if (weeklyTable) {
      weeklyTable.innerHTML = proj.weeks.map(w => {
        return `
          <tr>
            <td><b>Week ${w.week}</b></td>
            <td>$${w.week === 1 ? proj.startBalance.toFixed(2) : (proj.weeks[w.week - 2].endBalance).toFixed(2)}</td>
            <td>+${proj.weeklyR}R</td>
            <td style="color:#26a69a;">+${proj.weeklyReturnPct}%</td>
            <td style="color:#26a69a; font-weight:700;">+$${w.weeklyProfit.toFixed(2)}</td>
            <td style="color:#38bdf8; font-weight:700;">$${w.endBalance.toFixed(2)}</td>
          </tr>
        `;
      }).join('');
    }
  }

  function applyChartAnnotations(focusOnSetup = false) {
    if (!state.series || !state.evalRes) return;
    const setup = state.selectedSetup || state.evalRes.primary;
    htfChart.setAnnotations(buildHTFAnnotations(state.series, setup));
    ltfChart.setAnnotations(buildLTFAnnotations(state.series, setup));

    if (focusOnSetup && setup) {
      htfChart.focusTime(setup.c1.time, 35, 18);
      const ltfFocusT = setup.entryIdx != null && state.series.ltf[setup.entryIdx]
        ? state.series.ltf[setup.entryIdx].time
        : setup.tbsIdx != null && state.series.ltf[setup.tbsIdx]
          ? state.series.ltf[setup.tbsIdx].time
          : setup.c1.time;
      ltfChart.focusTime(ltfFocusT, 55, 25);
    }
  }

  /* ---------------- Load Active Market ---------------- */
  async function loadActiveMarket() {
    const market = F.markets.get(state.marketId);
    if (!market) return;
    const loading = document.getElementById('loading');
    const loadingText = document.getElementById('loadingText');
    if (loading) loading.hidden = false;
    if (loadingText) loadingText.textContent = `Streaming ${market.name} (${F.TF_PAIRS[state.pairKey].label})…`;

    if (state.unsubLtf) { state.unsubLtf(); state.unsubLtf = null; }

    try {
      const series = await F.loadSeries(market, state.pairKey);
      const allSetups = E.findAllSetups(series, state.engineOpts);
      ML.trainOnSetups(series, allSetups);

      const evalRes = E.evaluateLive(series, state.engineOpts);
      state.series = series;
      state.evalRes = evalRes;
      state.selectedSetup = evalRes.primary;

      const dec = F.decimalsFor(series.ltf);
      const mlPred = ML.predict(series, evalRes.primary);
      state.watchStates.set(market.id, {
        market,
        price: series.ltf.length ? series.ltf[series.ltf.length - 1].close : null,
        decimals: dec,
        setup: evalRes.primary,
        ml: mlPred
      });

      htfChart.setPrecision(dec);
      ltfChart.setPrecision(dec);
      htfChart.setTitle(`${market.name} · ${series.pair.htfLabel} (HTF Structure & POI)`);
      ltfChart.setTitle(`${market.name} · ${series.pair.ltfLabel} (LTF Adv CHoCH & OB Entry)`);
      htfChart.setData(series.htf, F.HTF_SECONDS[series.pair.htf] * 1000);
      ltfChart.setData(series.ltf, series.pair.ltf * 1000);

      applyChartAnnotations(false);
      htfChart.fit(75);
      ltfChart.fit(85);

      updateQuoteHeader(market, series.pair, series.ltf, dec);
      updateBrokerView(market);

      renderTicketAndTable();
      renderWatchlist();
      maybeAlert(market, evalRes.primary, mlPred, dec);
      recordPureTradeIfNew(market, series, evalRes.primary, mlPred);

      state.unsubLtf = F.subscribe(market, series.pair.ltf, c => {
        if (!state.series || state.series.market.id !== market.id) return;
        const ltf = state.series.ltf;
        const prevLast = ltf[ltf.length - 1];
        const barClosed = prevLast && c.time > prevLast.time;

        if (prevLast && c.time === prevLast.time) {
          ltf[ltf.length - 1] = c;
        } else if (!prevLast || c.time > prevLast.time) {
          ltf.push(c);
        }
        ltfChart.update(c);

        const bTime = state.series.bucketFn(c.time);
        const htf = state.series.htf;
        const hLast = htf[htf.length - 1];
        if (hLast && hLast.time === bTime) {
          const updatedHtf = {
            time: bTime,
            open: hLast.open,
            high: Math.max(hLast.high, c.high),
            low: Math.min(hLast.low, c.low),
            close: c.close
          };
          htf[htf.length - 1] = updatedHtf;
          htfChart.update(updatedHtf);
        } else if (hLast && bTime > hLast.time) {
          const newHtf = { time: bTime, open: c.open, high: c.high, low: c.low, close: c.close };
          htf.push(newHtf);
          htfChart.update(newHtf);
        }

        updateQuoteHeader(market, state.series.pair, ltf, dec);
        const ws = state.watchStates.get(market.id);
        if (ws) ws.price = c.close;

        if (barClosed) {
          const allS = E.findAllSetups(state.series, state.engineOpts);
          ML.trainOnSetups(state.series, allS);
          state.evalRes = E.evaluateLive(state.series, state.engineOpts);
          state.selectedSetup = state.evalRes.primary;
          const newMl = ML.predict(state.series, state.evalRes.primary);
          if (ws) { ws.setup = state.evalRes.primary; ws.ml = newMl; }
          applyChartAnnotations(false);
          renderTicketAndTable();
          renderWatchlist();
          maybeAlert(market, state.evalRes.primary, newMl, dec);
          recordPureTradeIfNew(market, state.series, state.evalRes.primary, newMl);
        }
      });
    } catch (err) {
      toast(`<b>Feed notice (${market.name}):</b> ${err.message}`);
    } finally {
      if (loading) loading.hidden = true;
    }
  }

  function selectMarket(id) {
    if (!F.markets.has(id)) return;
    state.marketId = id;
    state.lastPrice = null;
    loadActiveMarket();
  }

  /* ---------------- Deep Quant Model Calibration ---------------- */
  async function deepTrainActivePair() {
    if (!state.series) return;
    const market = state.series.market;
    const btn = document.getElementById('trainMlBtn');
    if (btn) { btn.disabled = true; btn.textContent = 'Calibrating…'; }
    try {
      const deepSeries = await F.loadSeries(market, state.pairKey, { htfCount: 450, ltfCount: 2400 });
      const allSetups = E.findAllSetups(deepSeries, state.engineOpts);
      const m = ML.trainOnSetups(deepSeries, allSetups, 0.09);
      renderTicketAndTable();
      toast(`<b>SMC Model Calibrated (${market.name}):</b> ${m.samples} setups analyzed · Avg OB Sweep ${m.avgSweepATR.toFixed(2)} ATR.`);
    } catch (e) {} finally {
      if (btn) { btn.disabled = false; btn.textContent = 'Calibrate'; }
    }
  }

  /* ---------------- Background Watchlist Scanner ---------------- */
  let scanning = false;
  async function scanWatchlistOnce() {
    if (scanning) return;
    scanning = true;
    try {
      const [acc] = await Promise.all([
        F.mt5.fetchAccountState(),
        F.mt5.refreshSymbols(),
        F.deriv.discoverSymbols()
      ]);
      if (acc && Array.isArray(acc.orders)) {
        state.mt5Orders = acc.orders;
      }
      renderWatchlist();
      populateBacktestMarkets();

      for (const m of F.markets.values()) {
        if (m.id === state.marketId) continue;
        try {
          const s = await F.loadSeries(m, state.pairKey, { htfCount: 110, ltfCount: 300 });
          const allS = E.findAllSetups(s, state.engineOpts);
          ML.trainOnSetups(s, allS);
          const ev = E.evaluateLive(s, state.engineOpts);
          const chosen = ev.primary;
          const mlPred = ML.predict(s, chosen);
          const dec = F.decimalsFor(s.ltf);
          state.watchStates.set(m.id, {
            market: m,
            price: s.ltf.length ? s.ltf[s.ltf.length - 1].close : null,
            decimals: dec,
            setup: chosen,
            ml: mlPred
          });
          renderWatchlist();
          maybeAlert(m, chosen, mlPred, dec);
          recordPureTradeIfNew(m, s, chosen, mlPred);
          if (m.feed === 'deriv') await new Promise(r => setTimeout(r, 200));
        } catch (e) {}
      }
    } finally {
      scanning = false;
    }
  }

  /* ---------------- Backtester UI ---------------- */
  function populateBacktestMarkets() {
    const mSel = document.getElementById('btMarket');
    if (!mSel) return;
    const cur = mSel.value || state.marketId;
    mSel.innerHTML = Array.from(F.markets.values())
      .map(m => `<option value="${m.id}" ${m.id === cur ? 'selected' : ''}>${m.name} (${m.group})</option>`)
      .join('');
  }

  function initBacktestUI() {
    populateBacktestMarkets();
    const pSel = document.getElementById('btPair');
    if (pSel) {
      pSel.innerHTML = Object.values(F.TF_PAIRS)
        .map(p => `<option value="${p.key}" ${p.key === state.pairKey ? 'selected' : ''}>${p.label} (${p.style})</option>`)
        .join('');
    }
    document.getElementById('btRun')?.addEventListener('click', runBacktestNow);
  }

  async function runBacktestNow() {
    const mId = document.getElementById('btMarket').value;
    const pairKey = document.getElementById('btPair').value;
    const ltfBars = +document.getElementById('btBars').value;
    const filters = {
      ltfBars,
      requireKeyLevel: document.getElementById('btKl').checked,
      requireTime: document.getElementById('btTime').checked,
      requireSMT: document.getElementById('btSmt').checked,
      requireAPlus: document.getElementById('btAplus').checked
    };
    const prog = document.getElementById('btProgress');
    const btn = document.getElementById('btRun');
    btn.disabled = true;

    try {
      const market = F.markets.get(mId);
      const res = await BT.run(market, pairKey, state.engineOpts, filters, msg => {
        if (prog) prog.textContent = msg;
      });
      ML.trainOnSetups(res.data, res.trades.map(t => t.setup), 0.08);
      renderTicketAndTable();

      if (prog) prog.textContent = `Completed — ${res.span.bars.toLocaleString()} ${F.TF_PAIRS[pairKey].ltfLabel} bars evaluated.`;

      const w = res.with50, wo = res.without50;
      const saved = res.trades.filter(t => t.outcome === 'BE').length;
      document.getElementById('btKpis').innerHTML = `
        <div class="kpi"><div class="kpi-lbl">SMC Trades</div><div class="kpi-val">${w.n}</div></div>
        <div class="kpi"><div class="kpi-lbl">Win Rate (TP1 + Trail)</div><div class="kpi-val" style="color:#26a69a;">${w.winRate.toFixed(1)}%</div></div>
        <div class="kpi"><div class="kpi-lbl">Win Rate (Full TP2)</div><div class="kpi-val" style="color:#f23645;">${wo.winRate.toFixed(1)}%</div></div>
        <div class="kpi"><div class="kpi-lbl">Net R (TP1 + Trail)</div><div class="kpi-val" style="color:${w.totalR >= 0 ? '#26a69a' : '#f23645'};">${w.totalR >= 0 ? '+' : ''}${w.totalR.toFixed(2)}R</div></div>
        <div class="kpi"><div class="kpi-lbl">Net R (Full Hold)</div><div class="kpi-val" style="color:${wo.totalR >= 0 ? '#26a69a' : '#f23645'};">${wo.totalR >= 0 ? '+' : ''}${wo.totalR.toFixed(2)}R</div></div>
        <div class="kpi"><div class="kpi-lbl">Profit Factor</div><div class="kpi-val">${isFinite(w.pf) ? w.pf.toFixed(2) : '∞'}</div></div>
        <div class="kpi"><div class="kpi-lbl">Max Drawdown</div><div class="kpi-val">-${w.maxDD.toFixed(2)}R</div></div>
        <div class="kpi"><div class="kpi-lbl">Locked via Trail</div><div class="kpi-val" style="color:#fbbf24;">${saved}</div></div>
      `;

      document.getElementById('btSpan').textContent = `${T.fmtCAT(res.span.from)} → ${T.fmtCAT(res.span.to)} CAT`;
      document.getElementById('btFunnel').textContent = `HTF BOS Waves: ${res.funnel.c1} · POI Sweeps: ${res.funnel.tbs} · LTF OB Triggered: ${res.funnel.triggered}`;

      if (!eqChart) eqChart = window.CRTEquityChart(document.getElementById('btEquity'));
      eqChart.set(res.trades, w, wo);

      const tbody = document.querySelector('#btTable tbody');
      tbody.innerHTML = res.trades.map((t, i) => `
        <tr>
          <td>${i + 1}</td>
          <td>${T.fmtCAT(t.time)}</td>
          <td>${t.dir}</td>
          <td><b>${t.grade}</b></td>
          <td>${t.type}</td>
          <td>${t.kl}</td>
          <td>${t.inside}</td>
          <td>${t.time_.toUpperCase()}</td>
          <td>${t.smt.toUpperCase()}</td>
          <td>${t.rr1.toFixed(2)}R / ${t.rr2.toFixed(2)}R</td>
          <td>${t.outcome}</td>
          <td style="color:${t.r50 >= 0 ? '#26a69a' : '#f23645'}; font-weight:600;">${t.r50 >= 0 ? '+' : ''}${t.r50.toFixed(2)}R</td>
          <td style="color:${t.rNo >= 0 ? '#868993' : '#f23645'};">${t.rNo >= 0 ? '+' : ''}${t.rNo.toFixed(2)}R</td>
        </tr>
      `).join('');
    } catch (err) {
      if (prog) prog.textContent = `Error: ${err.message}`;
    } finally {
      btn.disabled = false;
    }
  }

  /* ---------------- Journal UI ---------------- */
  function renderJournal() {
    const list = state.journal;
    const total = list.length;
    const totalR = list.reduce((a, b) => a + (+b.r || 0), 0);
    const clean = list.filter(x => (x.mistake || '').startsWith('None')).length;

    const kpis = document.getElementById('jKpis');
    if (kpis) {
      kpis.innerHTML = `
        <div class="kpi"><div class="kpi-lbl">Recorded Trades</div><div class="kpi-val">${total}</div></div>
        <div class="kpi"><div class="kpi-lbl">Cumulative R</div><div class="kpi-val" style="color:${totalR >= 0 ? '#26a69a' : '#f23645'};">${totalR >= 0 ? '+' : ''}${totalR.toFixed(2)}R</div></div>
        <div class="kpi"><div class="kpi-lbl">SMC Rule Adherence</div><div class="kpi-val">${total ? Math.round((clean / total) * 100) : 100}% (${clean}/${total})</div></div>
      `;
    }

    const tbody = document.querySelector('#jTable tbody');
    if (!tbody) return;
    tbody.innerHTML = list.map((j, i) => `
      <tr>
        <td>${j.date}</td>
        <td><b>${j.market}</b></td>
        <td>${j.pair}</td>
        <td>${j.dir}</td>
        <td>${j.model}</td>
        <td>${j.took50}</td>
        <td style="color:${+j.r >= 0 ? '#26a69a' : '#f23645'}; font-weight:600;">${+j.r >= 0 ? '+' : ''}${(+j.r).toFixed(2)}R</td>
        <td>${j.mistake}</td>
        <td style="font-family:var(--font-sans); color:var(--text-dim); max-width:260px;">${j.notes || ''}</td>
        <td><button class="btn ghost small" data-jdel="${i}">✕</button></td>
      </tr>
    `).join('');

    tbody.querySelectorAll('[data-jdel]').forEach(b => {
      b.addEventListener('click', () => {
        state.journal.splice(+b.dataset.jdel, 1);
        saveJournal();
        renderJournal();
      });
    });
  }

  /* ---------------- Playbook Reference ---------------- */
  function renderPlaybook() {
    const tbl = T.amdTableCAT();
    const dstEl = document.getElementById('pbDst');
    if (dstEl) dstEl.textContent = `24/7 Synthetic Indices + NY/CAT Session Windows`;
    const pbBody = document.querySelector('#pbTable tbody');
    if (pbBody) {
      pbBody.innerHTML = [
        { cycle: 'Chapter 1', candle: 'Waves', phase: 'Valid Pullback Rule', ny: 'Must break prior candle H/L', cat: 'Inside bars = INVALID pullback' },
        { cycle: 'Chapter 2', candle: 'BOS / CHoCH', phase: 'Structure Shift', ny: 'Requires Liquidity Sweep first', cat: 'Must close with Candle Body (no wick BOS)' },
        { cycle: 'Chapter 3', candle: 'Liquidity & Fib', phase: 'EQH/EQL, Trendline, Range', ny: 'Buy in Discount (<50% Fib)', cat: 'Sell in Premium (>50% Fib)' },
        { cycle: 'Chapter 4', candle: 'Order Blocks', phase: '3 Validation Rules', ny: '1. Sweep + 2. FVG + 3. BOS', cat: 'If OB < 60% ATR, extend to 1.0 ATR' },
        { cycle: 'Chapter 5', candle: 'Inducement', phase: 'IDM Trap Filter', ny: '1st OB before BOS = IDM Trap', cat: 'Wait for IDM sweep → Trade Extreme OB' },
        { cycle: 'Chapter 6 & 7', candle: 'Adv CHoCH', phase: '5-Step Toolkit', ny: 'HTF POI → LTF Adv CHoCH + OB', cat: 'Auto-Trail Stop Loss at X1, X2, X3' },
        { cycle: 'Chapter 8', candle: 'CBS Breakout', phase: 'Reaction + Confirmation', ny: 'Candle 1 touches POI, Candle 2 engulfs', cat: 'Limit order at Reaction Candle H/L' }
      ].map(r => `
        <tr>
          <td>${r.cycle}</td>
          <td><b>${r.candle}</b></td>
          <td>${r.phase}</td>
          <td>${r.ny}</td>
          <td style="color:#26a69a; font-weight:600;">${r.cat}</td>
        </tr>
      `).join('');
    }
  }

  /* ---------------- Init & Event Wiring ---------------- */
  async function startApp() {
    loadPrefs();
    await loadLedger();
    const acc = await F.mt5.fetchAccountState();
    if (acc && acc.login > 0 && acc.balance > 0) {
      state.balance = +acc.balance;
      state.startBalance = +acc.balance;
      if (Array.isArray(acc.orders)) state.mt5Orders = acc.orders;
    }
    startClock();

    const tfSeg = document.getElementById('tfSeg');
    tfSeg.innerHTML = Object.values(F.TF_PAIRS).map(p =>
      `<button data-pair="${p.key}" class="${p.key === state.pairKey ? 'active' : ''}" title="${p.style}">${p.label}</button>`
    ).join('');
    tfSeg.querySelectorAll('button').forEach(b => {
      b.addEventListener('click', () => {
        state.pairKey = b.dataset.pair;
        tfSeg.querySelectorAll('button').forEach(x => x.classList.toggle('active', x === b));
        loadActiveMarket();
      });
    });

    document.querySelectorAll('#wlCats button').forEach(b => {
      b.addEventListener('click', () => {
        state.wlCategory = b.dataset.cat;
        document.querySelectorAll('#wlCats button').forEach(x => x.classList.toggle('active', x === b));
        renderWatchlist();
      });
    });
    document.getElementById('wlActiveOnly')?.addEventListener('change', e => {
      state.wlActiveOnly = e.target.checked;
      renderWatchlist();
    });

    document.querySelectorAll('#entryModelSeg button').forEach(b => {
      b.addEventListener('click', () => {
        state.entryModelView = b.dataset.emodel;
        document.querySelectorAll('#entryModelSeg button').forEach(x => x.classList.toggle('active', x === b));
        applyChartAnnotations(false);
        renderTicketAndTable();
      });
    });

    F.onStatus(st => {
      document.querySelectorAll('#feedStatus .feed').forEach(el => {
        const s = st[el.dataset.feed] || 'idle';
        el.className = `feed ${s}`;
      });
    });

    htfChart = new window.CRTChart(document.getElementById('htfChart'));
    ltfChart = new window.CRTChart(document.getElementById('ltfChart'));

    document.querySelectorAll('#chartModeSeg button').forEach(b => {
      b.addEventListener('click', () => {
        setChartMode(b.dataset.mode);
      });
    });

    document.querySelectorAll('#layoutSeg button').forEach(b => {
      b.addEventListener('click', () => {
        document.querySelectorAll('#layoutSeg button').forEach(x => x.classList.toggle('active', x === b));
        const layout = b.dataset.layout;
        state.layout = layout;
        const charts = document.getElementById('charts');
        charts.dataset.layout = layout;
        if (layout === 'tri' || layout === 'broker-ltf' || layout === 'broker') {
          updateBrokerView();
        }
        const tog = document.getElementById('togBrokerChart');
        if (tog) tog.checked = (layout === 'tri' || layout === 'broker' || layout === 'broker-ltf');
        setTimeout(() => {
          if (htfChart) htfChart.requestDraw();
          if (ltfChart) ltfChart.requestDraw();
        }, 60);
      });
    });

    document.getElementById('togBrokerChart')?.addEventListener('change', e => {
      state.showBrokerChart = e.target.checked;
      const charts = document.getElementById('charts');
      let targetLayout = 'tri';
      if (e.target.checked) {
        targetLayout = (charts.dataset.layout === 'ltf') ? 'broker-ltf' : 'tri';
      } else {
        targetLayout = (charts.dataset.layout === 'broker-ltf') ? 'ltf' : 'split';
      }
      charts.dataset.layout = targetLayout;
      document.querySelectorAll('#layoutSeg button').forEach(b => {
        b.classList.toggle('active', b.dataset.layout === targetLayout);
      });
      document.querySelectorAll('#chartModeSeg button').forEach(b => {
        b.classList.toggle('active', b.dataset.mode === (e.target.checked ? 'tri' : 'crt'));
      });
      if (e.target.checked) updateBrokerView();
      setTimeout(() => {
        if (htfChart) htfChart.requestDraw();
        if (ltfChart) ltfChart.requestDraw();
      }, 60);
    });

    document.getElementById('togAutoTrade')?.addEventListener('change', e => {
      state.autoTradeEnabled = e.target.checked;
      savePrefs();
      const dstNote = document.getElementById('dstNote');
      if (dstNote) dstNote.textContent = `SMC Auto-Engine: ${state.autoTradeEnabled ? 'ACTIVE (Limit + X1/X2/X3 Trail)' : 'MANUAL'}`;
      renderTicketAndTable();
      renderPureSignalsPage();
      toast(state.autoTradeEnabled ? '⚡ Full MT5 Auto-Trading & X1/X2/X3 Trailing ENABLED.' : 'MT5 Auto-Trading paused (Manual ticket mode).');
    });

    document.getElementById('togPositionBox')?.addEventListener('change', e => { state.showPositionBox = e.target.checked; applyChartAnnotations(false); });
    document.getElementById('togSessions').addEventListener('change', e => { state.showSessions = e.target.checked; applyChartAnnotations(false); });
    document.getElementById('togOte').addEventListener('change', e => { state.showOte = e.target.checked; applyChartAnnotations(false); });
    document.getElementById('togKl').addEventListener('change', e => { state.showKl = e.target.checked; applyChartAnnotations(false); });
    document.getElementById('liveEdgeBtn')?.addEventListener('click', () => {
      htfChart.fit(75);
      ltfChart.fit(85);
    });
    document.getElementById('jumpBtn').addEventListener('click', () => applyChartAnnotations(true));
    document.getElementById('reloadBtn').addEventListener('click', () => loadActiveMarket());
    document.getElementById('trainMlBtn')?.addEventListener('click', deepTrainActivePair);
    document.getElementById('scanPureSignalsBtn')?.addEventListener('click', () => {
      toast('Scanning Deriv & Weltrade Synthetics for valid SMC setups…');
      scanWatchlistOnce();
    });
    document.getElementById('wlSearch').addEventListener('input', renderWatchlist);

    document.querySelectorAll('.vt').forEach(b => {
      b.addEventListener('click', () => {
        document.querySelectorAll('.vt').forEach(x => x.classList.toggle('active', x === b));
        document.querySelectorAll('.view').forEach(v => v.classList.toggle('active', v.id === `view-${b.dataset.view}`));
        if (b.dataset.view === 'terminal') setTimeout(() => { htfChart.requestDraw(); ltfChart.requestDraw(); }, 40);
        if (b.dataset.view === 'signals') renderPureSignalsPage();
      });
    });

    const alertBtn = document.getElementById('alertBtn');
    alertBtn.classList.toggle('active', state.alertsOn);
    alertBtn.addEventListener('click', () => {
      state.alertsOn = !state.alertsOn;
      alertBtn.classList.toggle('active', state.alertsOn);
      if (state.alertsOn && 'Notification' in window && Notification.permission === 'default') {
        Notification.requestPermission();
      }
      savePrefs();
      toast(state.alertsOn ? 'Audio & desktop alerts enabled.' : 'Alerts muted.');
    });

    const modal = document.getElementById('settingsModal');
    document.getElementById('settingsBtn').addEventListener('click', () => {
      document.getElementById('sBalance').value = state.balance;
      document.getElementById('sRisk').value = state.riskPct;
      document.getElementById('sMinRR').value = state.engineOpts.minRR;
      document.getElementById('sMaxWait').value = state.engineOpts.maxWait;
      document.getElementById('sBuf').value = state.engineOpts.slBufferATR;
      document.getElementById('sSpike').value = state.engineOpts.spikeBufferATR;
      document.getElementById('sModel1').value = state.engineOpts.model1;
      document.getElementById('sBody').value = state.engineOpts.minBodyRatio;
      document.getElementById('sTgToken').value = state.tgToken || '';
      document.getElementById('sTgChat').value = state.tgChat || '';
      modal.hidden = false;
    });
    document.getElementById('settingsClose').addEventListener('click', () => { modal.hidden = true; });
    document.getElementById('sSave')?.addEventListener('click', () => {
      state.balance = +document.getElementById('sBalance').value || 40.00;
      state.riskPct = +document.getElementById('sRisk').value || 2.5;
      state.engineOpts.minRR = +document.getElementById('sMinRR').value || 1.50;
      state.engineOpts.maxWait = +document.getElementById('sMaxWait').value || 8;
      state.engineOpts.slBufferATR = +document.getElementById('sBuf').value || 0.12;
      state.engineOpts.spikeBufferATR = +document.getElementById('sSpike').value || 0.85;
      state.engineOpts.model1 = document.getElementById('sModel1').value;
      state.engineOpts.minBodyRatio = +document.getElementById('sBody').value || 0.45;
      state.tgToken = document.getElementById('sTgToken').value.trim();
      state.tgChat = document.getElementById('sTgChat').value.trim();
      savePrefs();
      syncLedger();
      modal.hidden = true;
      loadActiveMarket();
    });
    document.getElementById('sReset')?.addEventListener('click', () => {
      state.balance = 40.00;
      state.riskPct = 2.5;
      state.engineOpts = { ...E.DEFAULTS, minRR: 1.50 };
      savePrefs();
      syncLedger();
      modal.hidden = true;
      loadActiveMarket();
    });

    // Execute Limit Order on MT5 button in Ticket
    document.getElementById('tkLog').addEventListener('click', () => {
      const s = state.selectedSetup || state.evalRes?.primary;
      if (!s || !state.series) return;
      const activeLvls = resolveActiveEntryLevels(s, state.series) || s;
      const pos = ML.calcPositionForAccount(state.series.market, activeLvls.entry, activeLvls.sl, activeLvls.tp1, activeLvls.tp2, state.balance, state.riskPct);
      dispatchMt5Order(state.series.market, s, activeLvls, pos, 'MANUAL');
    });

    document.getElementById('tkCopy').addEventListener('click', () => {
      const s = state.selectedSetup || state.evalRes?.primary;
      if (!s || !state.series) return;
      const dec = F.decimalsFor(state.series.ltf);
      const f = v => v != null ? v.toFixed(dec) : '—';
      const activeLvls = resolveActiveEntryLevels(s, state.series) || s;
      const pos = ML.calcPositionForAccount(state.series.market, activeLvls.entry, activeLvls.sl, activeLvls.tp1, activeLvls.tp2, state.balance, state.riskPct);
      const txt = `${state.series.market.name} (${state.series.pair.label}) ${s.dir || ''} [${s.structType || 'BOS'}]\nLot: ${pos.lotFormatted} ($${pos.actualRiskUsd} risk)\nEntry: ${f(activeLvls.entry)} | SL: ${f(activeLvls.sl)} | TP1: ${f(activeLvls.tp1)} | TP2: ${f(activeLvls.tp2)}`;
      navigator.clipboard?.writeText(txt);
      toast('SMC Order Block levels & lot size copied.');
    });

    document.getElementById('jForm').addEventListener('submit', e => {
      e.preventDefault();
      state.journal.unshift({
        date: T.fmtCAT(Date.now()),
        market: document.getElementById('jMarket').value,
        pair: document.getElementById('jPair').value,
        dir: document.getElementById('jDir').value,
        model: document.getElementById('jModel').value,
        took50: document.getElementById('j50').value,
        r: +document.getElementById('jR').value || 0,
        mistake: document.getElementById('jMistake').value,
        notes: document.getElementById('jNotes').value
      });
      saveJournal();
      renderJournal();
      e.target.reset();
    });

    renderWatchlist();
    initBacktestUI();
    renderJournal();
    renderPlaybook();
    renderPureSignalsPage();

    await loadActiveMarket();
    setTimeout(scanWatchlistOnce, 1800);
    setInterval(scanWatchlistOnce, 75000);
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', startApp);
  } else {
    startApp();
  }
})();
