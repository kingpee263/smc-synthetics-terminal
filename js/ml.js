/**
 * Online Per-Pair SMC Quant Engine & MT5 Auto-Trading Risk Manager (js/ml.js)
 *
 * 1. Online Logistic Regression (SGD with L2 regularization) + empirical pair movement profiling
 *    for Frank Miller's Smart Money Concepts (BOS/CHoCH, IDM Sweep, Order Block + Imbalance, CBS).
 * 2. Strict 6-Gate Ex-Ante Anti-Random SMC Filter.
 * 3. Broker Contract & Lot-Size Calculator for Deriv Synthetics (Volatility, Boom/Crash, Step, Jump, DEX)
 *    and Weltrade SyntX (PainX, GainX, FlipX/SwitchX, FX Vol, SFX Vol, BreakX).
 */
(function () {
  const E = window.CRTEngine;
  const STORAGE_KEY = 'smc_ml_pair_models_v1';

  const FEATURE_NAMES = [
    'BOS / CHoCH Impulse Force',
    'POI Mitigation Tightness (ATR)',
    'Inducement (IDM) Sweep Depth',
    'LTF Advanced CHoCH Displacement',
    'CBS Engulfing / OB Strength',
    'Valid Order Block (Sweep + FVG)',
    'Unmitigated Imbalance (FVG)',
    'Liquidity Pool Model (EQH/EQL/TLQ)',
    'Premium / Discount Alignment',
    'Boom/Crash/PainX Spike Harmony'
  ];

  const PRIOR_WEIGHTS = [0.65, 0.40, 0.85, 0.55, 0.75, 0.80, 0.70, 0.60, 0.55, 0.80];
  const PRIOR_BIAS = 0.36;

  const models = new Map();

  function sigmoid(z) {
    if (z > 12) return 0.9999;
    if (z < -12) return 0.0001;
    return 1 / (1 + Math.exp(-z));
  }

  function loadModels() {
    try {
      const raw = JSON.parse(localStorage.getItem(STORAGE_KEY) || '{}');
      for (const [k, v] of Object.entries(raw)) {
        if (v && Array.isArray(v.weights) && v.weights.length === FEATURE_NAMES.length) {
          models.set(k, v);
        }
      }
    } catch (e) {}
  }

  function saveModels() {
    try {
      const obj = {};
      for (const [k, v] of models.entries()) {
        obj[k] = {
          weights: v.weights.map(w => +w.toFixed(4)),
          bias: +v.bias.toFixed(4),
          samples: v.samples,
          wins: v.wins,
          tp2Wins: v.tp2Wins,
          avgSweepATR: +(v.avgSweepATR || 0.42).toFixed(3),
          avgBarsToTP1: Math.round(v.avgBarsToTP1 || 11),
          klStats: v.klStats || {},
          seenIds: (v.seenIds || []).slice(-200),
          updatedAt: v.updatedAt || Date.now()
        };
      }
      localStorage.setItem(STORAGE_KEY, JSON.stringify(obj));
    } catch (e) {}
  }

  function getModel(marketId) {
    if (!models.has(marketId)) {
      models.set(marketId, {
        weights: PRIOR_WEIGHTS.slice(),
        bias: PRIOR_BIAS,
        samples: 0,
        wins: 0,
        tp2Wins: 0,
        avgSweepATR: 0.42,
        avgBarsToTP1: 11,
        klStats: { OB: { w: 0, n: 0 }, FVG: { w: 0, n: 0 }, EQL: { w: 0, n: 0 }, EQH: { w: 0, n: 0 }, TLQ: { w: 0, n: 0 }, IDM: { w: 0, n: 0 } },
        seenIds: [],
        updatedAt: Date.now()
      });
    }
    return models.get(marketId);
  }

  function extractFeatures(series, setup) {
    const { htf, ltf, market } = series;
    const c1Idx = setup.c1Idx;
    const tbsIdx = setup.tbsIdx ?? (ltf.length - 1);
    const m1Idx = setup.model1Idx != null && setup.model1Idx >= 0 ? setup.model1Idx : tbsIdx;

    const fBody = Math.min(1, Math.max(0, (setup.bodyRatio - 0.40) / 0.45));

    const ltfAtr = Math.max(setup.atr || E.atr(ltf, Math.min(ltf.length - 1, tbsIdx), 14), 1e-8);
    const sweptPrice = setup.isBear ? setup.crth : setup.crtl;
    const sweepDist = setup.extreme != null ? Math.abs(setup.extreme - sweptPrice) : ltfAtr * 0.4;
    const sweepATR = Math.min(3.0, sweepDist / ltfAtr);
    const fSweep = 1 - Math.min(1, sweepATR / 2.2);

    const fInside = Math.min(1, (setup.insideLTF || 1) / 3);

    const tbsC = ltf[tbsIdx];
    const fTbs = tbsC ? E.metrics(tbsC).bodyRatio : 0.5;

    const m1C = ltf[m1Idx];
    const fM1 = m1C ? E.metrics(m1C).bodyRatio : 0.55;

    const kls = setup.keyLevels || [];
    const hasOB = kls.some(k => k.type === 'OB') ? 1 : 0;
    const hasFVG = kls.some(k => k.type === 'FVG') ? 1 : 0;
    const hasLiqPool = kls.some(k => ['EQL', 'EQH', 'TLQ', 'RNG', 'IDM'].includes(k.type)) ? 1 : 0;

    let fTrend = 0.65;
    if (c1Idx >= 6 && htf[c1Idx] && htf[c1Idx - 6]) {
      const slope = htf[c1Idx].close - htf[c1Idx - 6].close;
      fTrend = (setup.isBear ? slope < 0 : slope > 0) ? 0.85 : 0.45;
    }

    let fHarmony = 0.75;
    if (market.spike) {
      const withSpike = (market.spike === 'down' && setup.isBear) || (market.spike === 'up' && !setup.isBear);
      fHarmony = withSpike ? 1.0 : -0.4;
    }

    return {
      x: [fBody, fSweep, fInside, fTbs, fM1, hasOB, hasFVG, hasLiqPool, fTrend, fHarmony],
      sweepATR
    };
  }

  function trainOnSetups(series, setups, lr = 0.08) {
    if (!series || !Array.isArray(setups)) return getModel(series?.market?.id || '1HZ75V');
    const m = getModel(series.market.id);
    const seen = new Set(m.seenIds || []);
    let updated = false;

    for (const s of setups) {
      if (s.r50 == null || s.tbsIdx == null) continue;
      if (seen.has(s.id)) continue;
      seen.add(s.id);
      updated = true;

      const { x, sweepATR } = extractFeatures(series, s);
      const y = s.r50 > 0 ? 1 : 0;

      let z = m.bias;
      for (let i = 0; i < x.length; i++) z += m.weights[i] * x[i];
      const pred = sigmoid(z);
      const err = y - pred;

      for (let i = 0; i < x.length; i++) {
        const reg = 0.025 * (PRIOR_WEIGHTS[i] - m.weights[i]);
        m.weights[i] += lr * (err * x[i] + reg);
      }
      m.bias += lr * (err + 0.025 * (PRIOR_BIAS - m.bias));

      m.samples += 1;
      if (y === 1) m.wins += 1;
      if (s.outcome === 'TP2') m.tp2Wins += 1;
      m.avgSweepATR = (m.avgSweepATR * (m.samples - 1) + sweepATR) / m.samples;

      if (s.tp1Idx != null && s.tp1Idx > s.entryIdx) {
        const bars = s.tp1Idx - s.entryIdx;
        m.avgBarsToTP1 = (m.avgBarsToTP1 * 0.85) + (bars * 0.15);
      }

      if (s.keyLevels && s.keyLevels.length) {
        for (const kl of s.keyLevels) {
          if (!m.klStats[kl.type]) m.klStats[kl.type] = { w: 0, n: 0 };
          m.klStats[kl.type].n += 1;
          if (y === 1) m.klStats[kl.type].w += 1;
        }
      }
    }

    if (updated) {
      m.seenIds = Array.from(seen).slice(-200);
      m.updatedAt = Date.now();
      saveModels();
    }
    return m;
  }

  function predict(series, setup) {
    const m = getModel(series.market.id);
    if (!setup || setup.tbsIdx == null) {
      const baseRate = m.samples >= 5 ? (m.wins / m.samples) : 0.72;
      return {
        probTP1: Math.round(baseRate * 100),
        probTP2: Math.round(baseRate * 62),
        samples: m.samples,
        empiricalWinRate: m.samples ? Math.round((m.wins / m.samples) * 100) : null,
        avgSweepATR: +m.avgSweepATR.toFixed(2),
        avgBarsToTP1: Math.round(m.avgBarsToTP1),
        recommendedSLBufferATR: +(Math.max(0.12, m.avgSweepATR * 0.35)).toFixed(2),
        bestKeyLevel: bestKeyLevelFor(m),
        topDrivers: topDriversFor(m),
        isPure: false,
        isLiveSignal: false
      };
    }

    const { x } = extractFeatures(series, setup);
    let z = m.bias;
    for (let i = 0; i < x.length; i++) z += m.weights[i] * x[i];
    const logisticProb = sigmoid(z);

    const bayesRate = (m.wins + 5) / (m.samples + 7);
    const blended = 0.65 * logisticProb + 0.35 * bayesRate;
    const probTP1 = Math.min(96, Math.max(25, Math.round(blended * 100)));
    const tp2Ratio = m.wins > 0 ? Math.max(0.48, m.tp2Wins / m.wins) : 0.60;
    const probTP2 = Math.min(90, Math.max(20, Math.round(probTP1 * tp2Ratio)));

    const pred = {
      probTP1,
      probTP2,
      samples: m.samples,
      empiricalWinRate: m.samples ? Math.round((m.wins / m.samples) * 100) : null,
      avgSweepATR: +m.avgSweepATR.toFixed(2),
      avgBarsToTP1: Math.round(m.avgBarsToTP1),
      recommendedSLBufferATR: +(Math.max(0.12, m.avgSweepATR * 0.35)).toFixed(2),
      bestKeyLevel: bestKeyLevelFor(m),
      topDrivers: topDriversFor(m)
    };
    pred.isPure = isPureSignal(series.market, setup, pred);
    pred.isLiveSignal = pred.isPure && (setup.state === 'IN_TRADE' || setup.state === 'TP1_RUNNER' || setup.state === 'WAIT_TRIGGER');
    return pred;
  }

  function bestKeyLevelFor(m) {
    let best = 'OB + FVG', bestRate = -1;
    for (const [k, st] of Object.entries(m.klStats || {})) {
      if (st.n >= 1) {
        const r = st.w / st.n;
        if (r > bestRate) { bestRate = r; best = `${k} (${Math.round(r * 100)}%)`; }
      }
    }
    return best;
  }

  function topDriversFor(m) {
    return FEATURE_NAMES
      .map((name, i) => ({ name, weight: m.weights[i] }))
      .sort((a, b) => Math.abs(b.weight) - Math.abs(a.weight))
      .slice(0, 4);
  }

  /**
   * STRICT 6-GATE SMC EX-ANTE FILTER (Frank Miller Chapters 1–9)
   */
  function isPureSignal(market, setup, mlPred) {
    if (!setup || setup.entry == null || setup.sl == null || setup.tp1 == null) return false;
    // Gate 1: Valid active or completed state
    const validStates = new Set(['IN_TRADE', 'TP1_RUNNER', 'WAIT_TRIGGER', 'TP2', 'BREAKEVEN', 'STOPPED']);
    if (!validStates.has(setup.state)) return false;
    // Gate 2: Mandatory HTF Order Block / Imbalance / Liquidity Pool
    if (!setup.keyLevels || setup.keyLevels.length === 0) return false;
    // Gate 3: Minimum Reward-to-Risk ratio >= 1.20R on TP1 and >= 2.0R on TP2
    if (!setup.rr1 || setup.rr1 < 1.20 || !setup.rr2 || setup.rr2 < 2.0) return false;
    // Gate 4: Grade A or A+ only
    if (setup.grade !== 'A+' && setup.grade !== 'A') return false;
    // Gate 5: Boom / Crash / PainX / GainX spike direction harmony
    if (setup.againstSpike && (setup.insideLTF || 0) < 2) return false;
    // Gate 6: Quant model TP1 probability >= 67%
    if ((mlPred?.probTP1 || 0) < 67) return false;
    return true;
  }

  /* ---------------- Broker Contract Specifications & Risk Engine ---------------- */
  function getContractSpec(market) {
    const id = market?.id || '';
    const name = (market?.name || '').toUpperCase();

    // 1. Weltrade SyntX (PainX, GainX, FlipX/SwitchX, FX Vol, SFX Vol, BreakX)
    if (market?.feed === 'mt5' || id.startsWith('mt5:')) {
      return { minLot: 0.01, lotStep: 0.01, maxLot: 50, usdPerPointPerLot: 1.0, lotDecimals: 2 };
    }
    // 2. Deriv Volatility 75 (Standard & 1s)
    if (id === 'R_75') {
      return { minLot: 0.001, lotStep: 0.001, maxLot: 50, usdPerPointPerLot: 1.0, lotDecimals: 3 };
    }
    if (id === '1HZ75V' || id === '1HZ50V' || id === 'R_50' || id === '1HZ150V' || id === '1HZ200V' || id === '1HZ250V') {
      return { minLot: 0.005, lotStep: 0.005, maxLot: 50, usdPerPointPerLot: 1.0, lotDecimals: 3 };
    }
    if (id === '1HZ100V' || id === 'R_100' || id === '1HZ90V') {
      return { minLot: 0.01, lotStep: 0.01, maxLot: 50, usdPerPointPerLot: 1.0, lotDecimals: 2 };
    }
    if (id === 'R_10' || id === 'R_25' || id === '1HZ10V' || id === '1HZ15V' || id === '1HZ25V' || id === '1HZ30V') {
      return { minLot: 0.10, lotStep: 0.01, maxLot: 100, usdPerPointPerLot: 1.0, lotDecimals: 2 };
    }
    // 3. Deriv Step Index
    if (id.startsWith('stpRNG') || name.includes('STEP')) {
      return { minLot: 0.10, lotStep: 0.01, maxLot: 50, usdPerPointPerLot: 10.0, lotDecimals: 2 };
    }
    // 4. Deriv Boom & Crash
    if (id.startsWith('BOOM') || id.startsWith('CRASH')) {
      const is300 = id.includes('300');
      return { minLot: is300 ? 0.05 : 0.20, lotStep: 0.01, maxLot: 50, usdPerPointPerLot: 1.0, lotDecimals: 2 };
    }
    // 5. Deriv Jump / DEX / Range Break / Drift Switch
    if (id.startsWith('JD') || id.startsWith('DEX') || id.startsWith('DSI') || id.startsWith('RD')) {
      return { minLot: 0.01, lotStep: 0.01, maxLot: 50, usdPerPointPerLot: 1.0, lotDecimals: 2 };
    }
    // 6. Metals (Gold)
    if (id.includes('XAU')) {
      return { minLot: 0.01, lotStep: 0.01, maxLot: 50, usdPerPointPerLot: 100.0, lotDecimals: 2 };
    }
    // 7. Forex Majors
    if (market?.profile === 'forex') {
      const isJpy = id.includes('JPY');
      return { minLot: 0.01, lotStep: 0.01, maxLot: 100, usdPerPointPerLot: isJpy ? 1000.0 : 100000.0, lotDecimals: 2 };
    }
    return { minLot: 0.01, lotStep: 0.01, maxLot: 100, usdPerPointPerLot: 1.0, lotDecimals: 2 };
  }

  function calcPositionForAccount(market, entry, sl, tp1, tp2, balance = 40, riskPct = 2.5) {
    const spec = getContractSpec(market);
    const slDist = Math.max(Math.abs(entry - sl), 1e-6);
    const tp1Dist = Math.abs(tp1 - entry);
    const tp2Dist = Math.abs(tp2 - entry);
    const rr1 = tp1Dist / slDist;
    const rr2 = tp2Dist / slDist;

    const targetRiskUsd = balance * (riskPct / 100);
    const riskPerOneLot = slDist * spec.usdPerPointPerLot;
    const rawLots = riskPerOneLot > 0 ? targetRiskUsd / riskPerOneLot : spec.minLot;

    const steps = Math.max(1, Math.round(rawLots / spec.lotStep));
    const lot = +(Math.max(spec.minLot, steps * spec.lotStep)).toFixed(spec.lotDecimals);
    const minLotRiskUsd = spec.minLot * riskPerOneLot;

    const actualRiskUsd = +(lot * riskPerOneLot).toFixed(2);
    const actualRiskPct = +((actualRiskUsd / Math.max(balance, 1)) * 100).toFixed(1);

    const canSplitTwoOrders = lot >= spec.minLot * 2;
    const halfLot1 = canSplitTwoOrders
      ? +(Math.floor((lot / 2) / spec.lotStep) * spec.lotStep).toFixed(spec.lotDecimals)
      : lot;
    const halfLot2 = canSplitTwoOrders
      ? +(lot - halfLot1).toFixed(spec.lotDecimals)
      : 0;

    const tp1ProfitUsd = +(0.5 * actualRiskUsd * rr1).toFixed(2);
    const tp2TotalProfitUsd = +(tp1ProfitUsd + 0.5 * actualRiskUsd * rr2).toFixed(2);

    const overLeveraged = actualRiskPct > Math.max(riskPct * 2.0, 5.5);

    return {
      lot,
      lotFormatted: lot.toFixed(spec.lotDecimals),
      minLot: spec.minLot,
      lotDecimals: spec.lotDecimals,
      canSplitTwoOrders,
      splitInstruction: canSplitTwoOrders
        ? `Auto-Split: ${halfLot1.toFixed(spec.lotDecimals)} lot (TP1) + ${halfLot2.toFixed(spec.lotDecimals)} lot (TP2 + Trail X1–X3)`
        : `Order ${lot.toFixed(spec.lotDecimals)} lot → Bank 50% at TP1 & Auto-Trail SL at X1/X2/X3`,
      targetRiskUsd: +targetRiskUsd.toFixed(2),
      actualRiskUsd,
      actualRiskPct,
      minLotRiskUsd: +minLotRiskUsd.toFixed(2),
      tp1ProfitUsd,
      tp2TotalProfitUsd,
      rr1,
      rr2,
      overLeveraged,
      riskStatus: overLeveraged
        ? `Min lot (${spec.minLot}) risks $${actualRiskUsd.toFixed(2)} (${actualRiskPct}%) — use tighter LTF OB or lower-tick pair`
        : `Approved · Risking $${actualRiskUsd.toFixed(2)} (${actualRiskPct}% of $${balance.toFixed(2)})`
    };
  }

  function computeWeeklyProjection(balance = 40, riskPct = 2.5, ledgerStats = null) {
    const winRate = ledgerStats?.winRate && ledgerStats.total >= 3 ? ledgerStats.winRate / 100 : 0.78;
    const avgWinR = ledgerStats?.avgWinR && ledgerStats.total >= 3 ? ledgerStats.avgWinR : 2.35;
    const avgLossR = 1.0;
    const expectancyR = (winRate * avgWinR) - ((1 - winRate) * avgLossR);
    const tradesPerWeek = ledgerStats?.tradesPerWeek || 6;
    const weeklyR = +(expectancyR * tradesPerWeek).toFixed(2);
    const weeklyReturnRate = Math.max(0.05, (weeklyR * (riskPct / 100)));
    const weeklyUsdThisWeek = +(balance * weeklyReturnRate).toFixed(2);

    const weeks = [];
    let eq = balance;
    for (let w = 1; w <= 8; w++) {
      const profit = eq * weeklyReturnRate;
      eq += profit;
      weeks.push({
        week: w,
        endBalance: +eq.toFixed(2),
        weeklyProfit: +profit.toFixed(2)
      });
    }

    return {
      startBalance: balance,
      riskPct,
      riskUsdPerTrade: +(balance * (riskPct / 100)).toFixed(2),
      winRatePct: +(winRate * 100).toFixed(1),
      expectancyR: +expectancyR.toFixed(2),
      tradesPerWeek,
      weeklyR,
      weeklyReturnPct: +(weeklyReturnRate * 100).toFixed(1),
      weeklyUsdThisWeek,
      weeks
    };
  }

  loadModels();

  window.CRTML = {
    FEATURE_NAMES,
    getModel,
    trainOnSetups,
    predict,
    isPureSignal,
    getContractSpec,
    calcPositionForAccount,
    computeWeeklyProjection
  };
})();
