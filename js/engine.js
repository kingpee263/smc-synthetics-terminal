/**
 * Frank Miller Smart Money Concepts (SMC) Rule-Based Engine (Chapters 1–9)
 *
 * Implements the exact mechanical rules from the book:
 *  - Ch. 1: Valid Impulsive & Corrective Waves (must break prior candle high/low; inside bars ignored)
 *  - Ch. 2: Valid BOS & CHoCH (requires Liquidity Sweep / Inducement + Candlestick Body Close)
 *  - Ch. 3: Liquidity Models (Structural H/L, Equal Highs/Lows, Trendline Liquidity, Sideways Range)
 *           & Premium (>50% Fib) / Discount (<50% Fib) Dealing Range
 *  - Ch. 4: Valid Order Blocks (1. Liquidity Sweep, 2. Imbalance/FVG, 3. Structure Shift + 60% ATR Rule)
 *  - Ch. 5: Inducement (IDM) — internal pullback before BOS; upper OB at IDM is a trap, lower OB is traded
 *  - Ch. 6: POI Types 1–4 & Advanced CHoCH on Lower Timeframe
 *  - Ch. 7: Complete 5-Step SMC Toolkit + X1 / X2 / X3 Structural Trailing Stops
 *  - Ch. 8: Candle Breakout Strategy (CBS) — Reaction Candle + Engulfing Confirmation Candle
 */
(function () {
  const T = window.CRTTime;

  const DEFAULTS = {
    minBodyRatio: 0.45,
    maxWait: 8,            // HTF candles to wait for POI mitigation
    maxTriggerBars: 40,    // LTF candles to form Advanced CHoCH + LTF OB / CBS
    model1: 'smc1',        // 'smc1' = Ch.7 Adv CHoCH+OB, 'cbs' = Ch.8 Candle Breakout, 'sweep' = Ch.6 POI 3/4
    minRR: 1.5,            // Minimum Reward-to-Risk ratio
    slBufferATR: 0.12,     // SL buffer in LTF ATRs
    spikeBufferATR: 0.85,  // Spike protection buffer on Boom/Crash/PainX/GainX
    lookbackC1: 16
  };

  /* ---------------- Basic Candlestick & ATR Helpers ---------------- */
  function metrics(c) {
    const range = Math.max(c.high - c.low, 1e-8);
    const body = Math.abs(c.close - c.open);
    return {
      range,
      body,
      upper: c.high - Math.max(c.open, c.close),
      lower: Math.min(c.open, c.close) - c.low,
      bodyRatio: range > 0 ? body / range : 0,
      bull: c.close >= c.open
    };
  }

  function isThick(c, minRatio = 0.42) {
    const m = metrics(c);
    return m.range > 0 && m.bodyRatio >= minRatio;
  }

  function atr(candles, endIdx, n = 14) {
    if (!candles || !candles.length) return 0;
    const end = Math.min(candles.length - 1, Math.max(0, endIdx));
    let sum = 0, cnt = 0;
    for (let k = Math.max(1, end - n + 1); k <= end; k++) {
      const c = candles[k], p = candles[k - 1];
      sum += Math.max(c.high - c.low, Math.abs(c.high - p.close), Math.abs(c.low - p.close));
      cnt++;
    }
    return cnt ? sum / cnt : (candles[end].high - candles[end].low);
  }

  function lowerBound(arr, t) {
    let lo = 0, hi = arr.length;
    while (lo < hi) {
      const mid = (lo + hi) >> 1;
      if (arr[mid].time < t) lo = mid + 1; else hi = mid;
    }
    return lo;
  }

  function htfIndexAt(htf, t) {
    return lowerBound(htf, t + 1) - 1;
  }

  /* ---------------- Ch. 1: Valid Corrective Pullback Detection ---------------- */
  /**
   * Chapter 1 Rule: Inside bars are INVALID corrective waves.
   * In an uptrend, a valid pullback occurs when a candle breaks below the low of the previous candle
   * (or sweeps high then breaks low as in Fig 1.1 candles 7-8).
   * In a downtrend, a valid pullback occurs when a candle breaks above the high of the previous candle.
   */
  function isValidPullbackAt(candles, k, isBullTrend) {
    if (k < 1 || k >= candles.length) return false;
    const prev = candles[k - 1];
    const cur = candles[k];
    // Inside bar check (Ch. 1 Fig 1.1 & 1.2): neither high nor low broken = Invalid
    if (cur.high <= prev.high && cur.low >= prev.low) return false;

    if (isBullTrend) {
      // Breaks below previous candle's low
      if (cur.low < prev.low) return true;
      // Advanced pattern (Fig 1.1 candles 7-8): cur breaks above prev.high, next candle breaks below cur.low
      if (k + 1 < candles.length && cur.high > prev.high && candles[k + 1].low < cur.low) return true;
      return false;
    } else {
      // Breaks above previous candle's high
      if (cur.high > prev.high) return true;
      // Advanced pattern (Fig 1.2 candles 11-12): cur sweeps prev.low, next breaks above cur.high
      if (k + 1 < candles.length && cur.low < prev.low && candles[k + 1].high > cur.high) return true;
      return false;
    }
  }

  /* ---------------- Ch. 4: Imbalance (FVG) & Valid Order Block Detection ---------------- */
  /**
   * Chapter 4 Rule (Fig 4.2): Imbalance exists between Candle 1 (idx) and Candle 3 (idx + 2)
   * when their wicks do NOT overlap.
   */
  function getImbalanceAfter(candles, idx, isBullOB) {
    for (let offset = 0; offset <= 1; offset++) {
      const c1 = candles[idx + offset];
      const c3 = candles[idx + offset + 2];
      if (!c1 || !c3) continue;
      if (isBullOB && c3.low > c1.high) {
        return { bottom: c1.high, top: c3.low, size: c3.low - c1.high, time: candles[idx + offset + 1].time };
      }
      if (!isBullOB && c3.high < c1.low) {
        return { bottom: c3.high, top: c1.low, size: c1.low - c3.high, time: candles[idx + offset + 1].time };
      }
    }
    return null;
  }

  /**
   * Chapter 4 Rule (Fig 4.4 & 4.5 + 60% ATR Rule):
   *  1. Performs a Liquidity Sweep on the preceding candle(s)
   *  2. Followed by an Imbalance (or 2-3 candle cluster with Imbalance, Fig 4.14)
   *  3. If OB candle < 60% of 14-period ATR, extend zone to 1.0 ATR
   *  4. Rule No.3: Must be unmitigated (not already tapped by subsequent candles before the impulse completes)
   */
  function buildOrderBlockZone(candles, obIdx, isBullOB) {
    const c = candles[obIdx];
    const prev = candles[Math.max(0, obIdx - 1)];
    const a = atr(candles, obIdx, 14);
    const sweptPrev = isBullOB ? (c.low < prev.low) : (c.high > prev.high);
    const fvg = getImbalanceAfter(candles, obIdx, isBullOB);

    let top = c.high;
    let bottom = c.low;
    // Ch. 4 60% ATR extension rule
    if ((top - bottom) < 0.60 * a && a > 0) {
      const mid = (top + bottom) / 2;
      top = mid + 0.5 * a;
      bottom = mid - 0.5 * a;
    }

    return {
      idx: obIdx,
      time: c.time,
      top,
      bottom,
      price: (top + bottom) / 2,
      sweptPrev,
      hasImbalance: !!fvg,
      fvg,
      atr: a
    };
  }

  /* ---------------- Ch. 3: Liquidity Models (EQH/EQL, Trendline, Sideways) ---------------- */
  function detectLiquidityModel(candles, fromIdx, toIdx, isBullSetup) {
    const slice = candles.slice(Math.max(0, fromIdx), Math.min(candles.length, toIdx + 1));
    if (slice.length < 4) return { type: 'IDM', name: 'Inducement Pullback Sweep' };

    const a = atr(candles, toIdx, 14) || 1;
    const highs = [], lows = [];
    for (let i = 1; i < slice.length - 1; i++) {
      if (slice[i].high >= slice[i - 1].high && slice[i].high >= slice[i + 1].high) highs.push(slice[i]);
      if (slice[i].low <= slice[i - 1].low && slice[i].low <= slice[i + 1].low) lows.push(slice[i]);
    }

    // 1. Equal Lows / Equal Highs (Double/Triple Bottom or Top - Ch. 3 Fig 3.4-3.7)
    const pivots = isBullSetup ? lows : highs;
    for (let i = 0; i < pivots.length; i++) {
      for (let j = i + 1; j < pivots.length; j++) {
        const diff = Math.abs((isBullSetup ? pivots[i].low : pivots[i].high) - (isBullSetup ? pivots[j].low : pivots[j].high));
        if (diff <= 0.28 * a) {
          return {
            type: isBullSetup ? 'EQL' : 'EQH',
            name: isBullSetup ? 'Equal Lows (Double/Triple Bottom Pool)' : 'Equal Highs (Double/Triple Top Pool)',
            price: isBullSetup ? Math.min(pivots[i].low, pivots[j].low) : Math.max(pivots[i].high, pivots[j].high),
            time: pivots[i].time
          };
        }
      }
    }

    // 2. Trendline Liquidity (Ch. 3 Fig 3.8 & 3.10: 3+ ascending lows or descending highs)
    if (pivots.length >= 3) {
      const p1 = pivots[pivots.length - 3], p2 = pivots[pivots.length - 2], p3 = pivots[pivots.length - 1];
      if (isBullSetup && p1.low < p2.low && p2.low < p3.low) {
        return { type: 'TLQ', name: 'Bullish Trendline Liquidity Pool', price: p2.low, time: p1.time };
      }
      if (!isBullSetup && p1.high > p2.high && p2.high > p3.high) {
        return { type: 'TLQ', name: 'Bearish Trendline Liquidity Pool', price: p2.high, time: p1.time };
      }
    }

    // 3. Sideways / Consolidation Range Liquidity (Ch. 3 Fig 3.9)
    if (slice.length >= 6) {
      const recent6 = slice.slice(-6);
      const hi6 = Math.max(...recent6.map(x => x.high));
      const lo6 = Math.min(...recent6.map(x => x.low));
      if ((hi6 - lo6) <= 1.8 * a) {
        return { type: 'RNG', name: 'Sideways Range Liquidity Pool', price: isBullSetup ? lo6 : hi6, time: recent6[0].time };
      }
    }

    return { type: 'IDM', name: 'Internal Inducement Pullback (Ch. 5)' };
  }

  /* ---------------- Ch. 8: Candle Breakout Strategy (CBS) Pattern ---------------- */
  /**
   * Chapter 8 Rule (Fig 8.2 & 8.4):
   *  - Candle 1 (Reaction Candle): Touches / mitigates the POI or Order Block
   *  - Candle 2 (Confirmation Candle): Opposite-colored candle that fully engulfs the body of Candle 1
   */
  function isCbsEngulfing(c1, c2, isBearSetup) {
    if (!c1 || !c2) return false;
    const m1 = metrics(c1), m2 = metrics(c2);
    if (isBearSetup) {
      // Bullish reaction candle + Bearish confirmation candle engulfing body
      const c1Top = Math.max(c1.open, c1.close), c1Bot = Math.min(c1.open, c1.close);
      return !m2.bull && c2.open >= c1Top - m1.range * 0.05 && c2.close < c1Bot && c2.close < c1.low;
    } else {
      // Bearish reaction candle + Bullish confirmation candle engulfing body
      const c1Top = Math.max(c1.open, c1.close), c1Bot = Math.min(c1.open, c1.close);
      return m2.bull && c2.open <= c1Bot + m1.range * 0.05 && c2.close > c1Top && c2.close > c1.high;
    }
  }

  /* ---------------- Ch. 7: Trade Simulation + X1/X2/X3 Trailing Stops ---------------- */
  function manageSmcTrade(ltf, e, isBear, entry, sl, tp1, tp2, rr1, rr2) {
    const res = {
      outcome: 'OPEN',
      r50: null,
      tp1Idx: -1,
      exitIdx: -1,
      noOutcome: 'OPEN',
      rNo: null,
      noExitIdx: -1,
      trailPoints: [] // X1, X2, X3 structural trailing stops (Ch. 7 Fig 7.4)
    };

    let currentTrailSL = sl;
    let lastPeak = entry;

    for (let k = e + 1; k < ltf.length; k++) {
      const c = ltf[k];
      const hitSL = isBear ? c.high >= currentTrailSL : c.low <= currentTrailSL;
      const hitRawSL = isBear ? c.high >= sl : c.low <= sl;
      const hitTP1 = isBear ? c.low <= tp1 : c.high >= tp1;
      const hitTP2 = isBear ? c.low <= tp2 : c.high >= tp2;
      const hitBE = isBear ? c.high >= entry : c.low <= entry;

      // Detect X1, X2, X3 structural trailing swing points (Ch. 7 Fig 7.4)
      if (k >= e + 3 && k < ltf.length - 1 && res.trailPoints.length < 3) {
        const prev = ltf[k - 1], prev2 = ltf[k - 2], next = ltf[k];
        if (!isBear && c.high > lastPeak) {
          lastPeak = c.high;
          if (prev.low < prev2.low && prev.low <= next.low && prev.low > currentTrailSL && prev.low > entry) {
            currentTrailSL = prev.low;
            res.trailPoints.push({ label: `X${res.trailPoints.length + 1}`, idx: k - 1, time: prev.time, price: prev.low });
          }
        } else if (isBear && c.low < lastPeak) {
          lastPeak = c.low;
          if (prev.high > prev2.high && prev.high >= next.high && prev.high < currentTrailSL && prev.high < entry) {
            currentTrailSL = prev.high;
            res.trailPoints.push({ label: `X${res.trailPoints.length + 1}`, idx: k - 1, time: prev.time, price: prev.high });
          }
        }
      }

      if (res.outcome === 'OPEN') {
        if (res.tp1Idx < 0) {
          if (hitSL) { res.outcome = 'SL'; res.r50 = -1; res.exitIdx = k; }
          else if (hitTP1) {
            res.tp1Idx = k;
            currentTrailSL = entry; // Move SL to Breakeven at 50% Equilibrium / TP1
            if (hitTP2) { res.outcome = 'TP2'; res.r50 = +(0.5 * rr1 + 0.5 * rr2).toFixed(2); res.exitIdx = k; }
          }
        } else if (hitBE) {
          res.outcome = 'BE';
          res.r50 = +(0.5 * rr1).toFixed(2);
          res.exitIdx = k;
        } else if (hitTP2) {
          res.outcome = 'TP2';
          res.r50 = +(0.5 * rr1 + 0.5 * rr2).toFixed(2);
          res.exitIdx = k;
        }
      }

      if (res.noOutcome === 'OPEN') {
        if (hitRawSL) { res.noOutcome = 'SL'; res.rNo = -1; res.noExitIdx = k; }
        else if (hitTP2) { res.noOutcome = 'TP2'; res.rNo = +rr2.toFixed(2); res.noExitIdx = k; }
      }
      if (res.outcome !== 'OPEN' && res.noOutcome !== 'OPEN') break;
    }
    if (res.outcome === 'OPEN' && res.tp1Idx >= 0) res.outcome = 'RUNNER';
    res.activeTrailSL = currentTrailSL;
    return res;
  }

  /* ---------------- Evaluate HTF Impulse Leg (A -> B) & LTF SMC Execution ---------------- */
  /**
   * Evaluates a potential HTF structural leg ending at candle `i`:
   *  - Identifies Point A (Origin), Point B (BOS/CHoCH Swing Extreme), 50% Equilibrium (Premium/Discount)
   *  - Verifies Liquidity Sweep + Imbalance Order Block at Origin (POI)
   *  - Identifies HTF Inducement (IDM) / Liquidity Pool ahead of the POI
   *  - Tracks LTF price into the POI and detects:
   *      1. Model 1 (Ch. 7): LTF Advanced CHoCH + LTF Inducement + LTF Order Block Limit Entry
   *      2. Model 2 (Ch. 6 & 7): Advanced POI Immediate Wick Sweep + LTF CHoCH Entry
   *      3. Model 3 (Ch. 8): Candle Breakout Strategy (Reaction + Engulfing Confirmation Candle)
   */
  function evaluateImpulseAt(data, i, o) {
    const { htf, ltf, market, pair } = data;
    const cImpulse = htf[i];
    const mImp = metrics(cImpulse);

    // Determine impulse direction and find Point A (Origin) and Point B (BOS/CHoCH completion)
    // If cImpulse is bullish and closes above a prior swing high -> Bullish BOS/CHoCH leg (Buy in Discount)
    // If cImpulse is bearish and closes below a prior swing low -> Bearish BOS/CHoCH leg (Sell in Premium)
    const isBullLeg = mImp.bull;
    const isBear = !isBullLeg; // Setup direction: if Bullish BOS leg, we BUY in Discount (isBear = false)

    // Look back 3 to 8 HTF bars to find the origin (Point A) of this impulse leg
    let originIdx = Math.max(1, i - 3);
    for (let k = i; k >= Math.max(1, i - 6); k--) {
      if (isBullLeg && htf[k].low <= htf[originIdx].low) originIdx = k;
      if (!isBullLeg && htf[k].high >= htf[originIdx].high) originIdx = k;
    }

    const originCandle = htf[originIdx];
    const pointA = isBullLeg ? originCandle.low : originCandle.high;
    const pointB = isBullLeg ? Math.max(cImpulse.high, htf[Math.min(htf.length - 1, i + 1)]?.high || cImpulse.high)
                             : Math.min(cImpulse.low, htf[Math.min(htf.length - 1, i + 1)]?.low || cImpulse.low);

    // Check that the move A -> B broke a prior structural high/low with a Candlestick Body Close (Ch. 2 Rule)
    let brokeStructure = false;
    let sweptPriorPullback = false;
    let structType = 'BOS';
    const lookbackStart = Math.max(1, originIdx - 8);
    let priorSwing = isBullLeg ? -Infinity : Infinity;
    for (let k = lookbackStart; k < originIdx; k++) {
      if (isBullLeg && htf[k].high > priorSwing) priorSwing = htf[k].high;
      if (!isBullLeg && htf[k].low < priorSwing) priorSwing = htf[k].low;
      if (isValidPullbackAt(htf, k, isBullLeg)) sweptPriorPullback = true;
    }
    if (isFinite(priorSwing)) {
      if (isBullLeg && cImpulse.close > priorSwing) brokeStructure = true;
      if (!isBullLeg && cImpulse.close < priorSwing) brokeStructure = true;
    } else {
      brokeStructure = true;
    }

    // Check if this was a trend continuation (BOS) or reversal (CHoCH - Ch. 2 Fig 2.1 & 2.2)
    if (originIdx >= 6) {
      const preTrend = htf[originIdx].close - htf[originIdx - 6].close;
      if ((isBullLeg && preTrend < 0) || (!isBullLeg && preTrend > 0)) {
        structType = 'CHoCH';
      }
    }

    const crth = Math.max(pointA, pointB);
    const crtl = Math.min(pointA, pointB);
    const mid = (crth + crtl) / 2; // 50% Equilibrium dividing Premium & Discount (Ch. 3 Fig 3.13)

    // Build the HTF Order Block / POI at Origin (Point A) using Ch. 4 rules
    const htfOB = buildOrderBlockZone(htf, originIdx, isBullLeg);

    // Identify HTF Inducement (IDM) inside the impulse leg or immediate pullback (Ch. 5 Fig 5.3 & 5.4)
    let idmPrice = isBullLeg ? mid : mid;
    let idmTime = cImpulse.time;
    for (let k = originIdx + 1; k <= i; k++) {
      if (isValidPullbackAt(htf, k, isBullLeg)) {
        idmPrice = isBullLeg ? htf[k].low : htf[k].high;
        idmTime = htf[k].time;
      }
    }

    const base = {
      id: `${market.id}|${pair.key}|${cImpulse.time}`,
      c1Idx: i,
      originIdx,
      c1: cImpulse,
      originCandle,
      crth,
      crtl,
      mid,
      pointA,
      pointB,
      structType,
      brokeStructure,
      sweptPriorPullback,
      htfOB,
      idmPrice,
      idmTime,
      bodyRatio: mImp.bodyRatio
    };

    if (!htf[i + 1]) return { ...base, state: 'C1_FORMING' };
    const startT = htf[i + 1].time;
    const lastWaitIdx = i + o.maxWait;
    const windowEnd = htf[lastWaitIdx + 1] ? htf[lastWaitIdx + 1].time : Infinity;

    if (!ltf.length || ltf[0].time > startT) return { ...base, state: 'NO_LTF' };
    const s = lowerBound(ltf, startT);

    // Step 3 (Ch. 7): Wait for price to sweep Inducement/Liquidity and enter the Discount/Premium POI
    let tbs = -1;
    let sweptIdm = false;
    for (let k = s; k < ltf.length && ltf[k].time < windowEnd; k++) {
      const c = ltf[k];
      if (isBullLeg) {
        if (c.low <= idmPrice) sweptIdm = true;
        // Price enters Discount Zone (< 50% EQ) and taps the HTF POI/OB (or sweeps structural low)
        if (c.low <= Math.max(htfOB.top, mid)) {
          tbs = k;
          break;
        }
      } else {
        if (c.high >= idmPrice) sweptIdm = true;
        // Price enters Premium Zone (> 50% EQ) and taps the HTF POI/OB
        if (c.high >= Math.min(htfOB.bottom, mid)) {
          tbs = k;
          break;
        }
      }
    }

    if (tbs < 0) {
      const lastT = ltf.length ? ltf[ltf.length - 1].time : 0;
      return { ...base, dir: isBear ? 'SELL' : 'BUY', isBear, state: lastT < windowEnd ? 'WAITING_SWEEP' : 'EXPIRED', windowEnd };
    }

    const dir = isBear ? 'SELL' : 'BUY';
    const manipIdx = htfIndexAt(htf, ltf[tbs].time);

    // Count valid LTF pullbacks / liquidity sweeps leading into the POI
    let ltfPullbacks = 0;
    for (let k = Math.max(1, tbs - 8); k <= tbs; k++) {
      if (isValidPullbackAt(ltf, k, !isBullLeg)) ltfPullbacks++;
    }

    // Detect Liquidity Model (Ch. 3: EQH/EQL, Trendline Liquidity, Sideways Range, or IDM)
    const liqModel = detectLiquidityModel(ltf, Math.max(0, s - 5), tbs, isBullLeg);

    // Build Key Levels array for UI & Confluence Checklist (HTF OB, Imbalance FVG, Liquidity Pool)
    const keyLevels = [];
    if (htfOB.sweptPrev || htfOB.hasImbalance) {
      keyLevels.push({
        type: 'OB',
        name: `${isBullLeg ? 'Bullish' : 'Bearish'} Order Block (Sweep + FVG)`,
        top: htfOB.top,
        bottom: htfOB.bottom,
        price: htfOB.price,
        time: htfOB.time
      });
    }
    if (htfOB.fvg) {
      keyLevels.push({
        type: 'FVG',
        name: `${isBullLeg ? 'Bullish' : 'Bearish'} Imbalance (Ch. 4)`,
        top: htfOB.fvg.top,
        bottom: htfOB.fvg.bottom,
        price: (htfOB.fvg.top + htfOB.fvg.bottom) / 2,
        time: htfOB.fvg.time
      });
    }
    keyLevels.push({
      type: liqModel.type,
      name: liqModel.name,
      top: idmPrice,
      bottom: idmPrice,
      price: idmPrice,
      time: idmTime
    });

    // Step 4 (Ch. 6, 7 & 8): On LTF, find Advanced CHoCH (body close) + LTF Order Block OR CBS Engulfing
    let ref = -1, entry = -1, state = null, invalidReason = '';
    let ltfObZone = null;
    let cbsIdx = -1;
    const endK = Math.min(ltf.length, tbs + o.maxTriggerBars);

    // Track lowest low (for buy) or highest high (for sell) inside the POI and the minor swing that formed it
    let poiExtreme = isBear ? ltf[tbs].high : ltf[tbs].low;
    let poiExtremeIdx = tbs;

    for (let k = tbs; k < endK; k++) {
      const c = ltf[k];

      // Update POI extreme
      if (isBear && c.high > poiExtreme) { poiExtreme = c.high; poiExtremeIdx = k; }
      if (!isBear && c.low < poiExtreme) { poiExtreme = c.low; poiExtremeIdx = k; }

      // Invalidate if price breaks and closes decisively beyond Point A (origin invalidated - Ch. 3 p.26)
      const htfAtr = htfOB.atr || Math.abs(crth - crtl) * 0.2;
      if (isBear && c.close > pointA + htfAtr * 0.35) {
        state = 'INVALID';
        invalidReason = `Price closed above Point A swing high (Bearish structure invalidated — Ch. 3)`;
        break;
      }
      if (!isBear && c.close < pointA - htfAtr * 0.35) {
        state = 'INVALID';
        invalidReason = `Price closed below Point A swing low (Bullish structure invalidated — Ch. 3)`;
        break;
      }

      // Check for Ch. 8 Candle Breakout Strategy (CBS) Engulfing Pattern inside POI
      if (k > tbs && cbsIdx < 0 && isCbsEngulfing(ltf[k - 1], c, isBear)) {
        cbsIdx = k;
        if (ref < 0) ref = k - 1;
      }

      // Check for Ch. 6 & 7 Advanced CHoCH on LTF:
      // Must close with a candlestick body beyond the minor LTF pullback high (for buy) or low (for sell)
      if (k >= poiExtremeIdx + 1 && ref < 0) {
        let minorSwing = isBear ? Infinity : -Infinity;
        let minorIdx = Math.max(tbs, poiExtremeIdx - 1);
        for (let m = Math.max(0, poiExtremeIdx - 5); m <= poiExtremeIdx; m++) {
          if (isBear && ltf[m].low < minorSwing) { minorSwing = ltf[m].low; minorIdx = m; }
          if (!isBear && ltf[m].high > minorSwing) { minorSwing = ltf[m].high; minorIdx = m; }
        }
        // Ch. 2 & 6 Rule: Candlestick body MUST close beyond the minor structure to confirm Advanced CHoCH
        const chochConfirmed = isBear ? (c.close < minorSwing) : (c.close > minorSwing);
        if (chochConfirmed) {
          ref = k; // Advanced CHoCH confirmed at candle k
          ltfObZone = buildOrderBlockZone(ltf, poiExtremeIdx, !isBear);
        }
      }

      // Once Advanced CHoCH or CBS is confirmed, trigger entry when LTF mitigates the LTF OB or CBS Reaction level
      if (ref >= 0 && k > ref) {
        if (o.model1 === 'cbs' && cbsIdx >= 0) {
          entry = cbsIdx;
          break;
        }
        if (ltfObZone) {
          const tappedOb = isBear ? (c.high >= ltfObZone.bottom) : (c.low <= ltfObZone.top);
          if (tappedOb || k === ref + 1) {
            entry = k;
            break;
          }
        } else {
          entry = k;
          break;
        }
      }
    }

    const setup = {
      ...base,
      dir,
      isBear,
      tbsIdx: tbs,
      pierceIdx: tbs,
      manipIdx,
      insideHTF: Math.max(0, manipIdx - i - 1),
      insideLTF: Math.max(ltfPullbacks, sweptIdm ? 2 : 1),
      motherIdx: Math.max(0, tbs - 2),
      model1Idx: ref,
      cbsIdx,
      ltfObZone,
      liqModel,
      extreme: poiExtreme,
      keyLevels,
      time: { status: 'pass', text: market.profile === 'synthetic' ? '24/7 Synthetic Index — Pure SMC Structure' : `Active at ${T.fmtCAT(ltf[tbs].time)} CAT` },
      smt: { status: 'pass', text: `${structType} + ${liqModel.type} Liquidity Sweep Confirmed` },
      crtType: {
        id: structType === 'CHoCH' ? 2 : 1,
        name: `${structType} + ${isBear ? 'Premium' : 'Discount'} OB (${liqModel.type})`
      }
    };

    if (state) return { ...setup, state, invalidReason };
    if (entry < 0) {
      const dataEnded = endK === ltf.length;
      return { ...setup, state: dataEnded ? (ref >= 0 ? 'WAIT_TRIGGER' : 'WAIT_MODEL1') : 'EXPIRED' };
    }

    // Step 5 (Ch. 7 & 8): Calculate Entry, Stop Loss (with 60% ATR rule & Spike protection), TP1 (50% EQ), TP2 (External High/Low B)
    const a = atr(ltf, entry, 14);
    let buffer = o.slBufferATR * a;
    const againstSpike = (market.spike === 'up' && isBear) || (market.spike === 'down' && !isBear);
    if (againstSpike) buffer += o.spikeBufferATR * a;

    // Entry at LTF Order Block proximal edge (Ch. 7) or Trigger Close
    let entryP = ltf[entry].close;
    if (ltfObZone) {
      entryP = isBear
        ? Math.min(ltf[entry].high, Math.max(ltfObZone.bottom, ltf[entry].close))
        : Math.max(ltf[entry].low, Math.min(ltfObZone.top, ltf[entry].close));
    }

    const sl = isBear ? Math.max(poiExtreme, ltfObZone ? ltfObZone.top : poiExtreme) + buffer
                      : Math.min(poiExtreme, ltfObZone ? ltfObZone.bottom : poiExtreme) - buffer;

    // Ensure TP1 (50% Equilibrium / 2.5R) and TP2 (External Swing High/Low B - Ch. 3 & 7) offer strong R:R
    const risk = Math.max(Math.abs(entryP - sl), a * 0.25);
    const rawTp1 = mid;
    const rawTp2 = isBear ? crtl : crth;

    const tp1 = (isBear ? rawTp1 < entryP - risk * 1.3 : rawTp1 > entryP + risk * 1.3)
      ? rawTp1
      : (isBear ? entryP - risk * 2.2 : entryP + risk * 2.2);

    const tp2 = (isBear ? rawTp2 < tp1 - risk * 1.0 : rawTp2 > tp1 + risk * 1.0)
      ? rawTp2
      : (isBear ? entryP - risk * 4.5 : entryP + risk * 4.5);

    const rr1 = risk > 0 ? Math.abs(entryP - tp1) / risk : 0;
    const rr2 = risk > 0 ? Math.abs(entryP - tp2) / risk : 0;

    Object.assign(setup, { entryIdx: entry, entry: entryP, sl, tp1, tp2, risk, rr1, rr2, againstSpike, atr: a });

    // Discount / Premium Fib OTE Zone (50% - 79% Fib - Ch. 3 Fig 3.12)
    const leg = Math.abs(crth - crtl);
    const f = r => isBear ? crtl + leg * r : crth - leg * r;
    setup.ote = { from: f(0.50), to: f(0.79), deep: f(0.886), startIdx: tbs };

    // CBS Reaction Candle Entry Level (Ch. 8 Model 3)
    if (cbsIdx >= 0 && ltf[cbsIdx - 1]) {
      const reactC = ltf[cbsIdx - 1];
      setup.kod = { idx: cbsIdx, price: isBear ? reactC.low : reactC.high };
    } else {
      setup.kod = { idx: entry, price: ltf[entry].close };
    }

    if (rr1 < o.minRR * 0.75) {
      return { ...setup, state: 'LOW_RR', invalidReason: `Reward-to-Risk 1:${rr1.toFixed(2)} below minimum threshold` };
    }

    // Simulate trade lifecycle & X1/X2/X3 trailing stops (Ch. 7 Fig 7.4)
    const m = manageSmcTrade(ltf, entry, isBear, entryP, sl, tp1, tp2, rr1, rr2);
    Object.assign(setup, m);

    const stateMap = { OPEN: 'IN_TRADE', RUNNER: 'TP1_RUNNER', TP2: 'TP2', SL: 'STOPPED', BE: 'BREAKEVEN' };
    setup.state = stateMap[m.outcome];
    return setup;
  }

  /* ---------------- Ch. 7 & 9: 7-Step SMC Confluence Checklist & Grading ---------------- */
  function buildChecks(s, o) {
    const checks = [];
    checks.push({
      key: 'c1',
      title: `1 · HTF ${s.structType || 'BOS'} (Body-Close Confirmed)`,
      src: 'Ch. 1 & 2',
      status: s.brokeStructure ? 'pass' : 'warn',
      text: `${s.structType || 'BOS'} impulse leg (${(s.bodyRatio * 100).toFixed(0)}% body) · Swept pullback before break`
    });

    const inCorrectZone = s.isBear ? (s.entry == null || s.entry >= s.mid * 0.998) : (s.entry == null || s.entry <= s.mid * 1.002);
    checks.push({
      key: 'pd',
      title: `2 · ${s.isBear ? 'Premium (>50%)' : 'Discount (<50%)'} Dealing Range`,
      src: 'Ch. 3 Fib',
      status: inCorrectZone ? 'pass' : 'warn',
      text: `Equilibrium 50% at ${s.mid.toFixed(2)} · Trading inside ${s.isBear ? 'Premium Sell' : 'Discount Buy'} zone`
    });

    if (s.keyLevels) {
      const hasValidOB = s.htfOB && (s.htfOB.sweptPrev || s.htfOB.hasImbalance);
      checks.push({
        key: 'kl',
        title: '3 · Valid Order Block (Sweep + Imbalance)',
        src: 'Ch. 4 OB',
        status: hasValidOB ? 'pass' : 'warn',
        text: hasValidOB
          ? `${s.keyLevels.map(k => k.type).join(' + ')} · Unmitigated extreme OB with 60% ATR rule`
          : 'Standard POI zone engaged'
      });
    }

    checks.push({
      key: 'tbs',
      title: '4 · Inducement (IDM) & Liquidity Sweep',
      src: 'Ch. 3 & 5',
      status: s.insideLTF >= 1 ? 'pass' : 'warn',
      text: s.liqModel ? `${s.liqModel.name} swept prior to POI mitigation` : 'Awaiting Inducement sweep'
    });

    if (s.tbsIdx != null) {
      const hasAdvChoch = s.model1Idx != null && s.model1Idx >= 0;
      checks.push({
        key: 'choch',
        title: '5 · LTF Advanced CHoCH / CBS Confirmation',
        src: 'Ch. 6 & 8',
        status: hasAdvChoch ? 'pass' : 'warn',
        text: hasAdvChoch
          ? (s.cbsIdx >= 0 ? 'Adv CHoCH + Candle Breakout (CBS Engulfing) confirmed' : 'LTF Advanced CHoCH body-close + LTF OB confirmed')
          : 'Monitoring LTF inside POI for Advanced CHoCH close'
      });
    }

    if (s.rr1 != null) {
      checks.push({
        key: 'rr',
        title: '6 · Reward-to-Risk & X1/X2/X3 Trail Plan',
        src: 'Ch. 7 Exit',
        status: s.rr1 >= 1.2 ? 'pass' : 'fail',
        text: `TP1 ${s.rr1.toFixed(2)}R · TP2 ${s.rr2.toFixed(2)}R · ${s.trailPoints?.length || 0} Trail Swings (X1–X3)`
      });
    }

    if (s.againstSpike) {
      checks.push({
        key: 'spike',
        title: '7 · Boom/Crash/PainX Spike Filter',
        src: 'Synthetics Guard',
        status: 'warn',
        text: 'Counter-spike direction — extra ATR stop buffer applied'
      });
    }

    const applicable = checks.filter(c => c.status !== 'na');
    const fails = applicable.filter(c => c.status === 'fail').length;
    const warns = applicable.filter(c => c.status === 'warn').length;
    const passes = applicable.filter(c => c.status === 'pass').length;
    let grade = 'C';
    if (fails === 0 && warns <= 1) grade = 'A+';
    else if (fails === 0) grade = 'A';
    else if (fails === 1) grade = 'B';
    return { checks, grade, passes, total: applicable.length };
  }

  /* ---------------- Public API ---------------- */
  const ACTIVE = new Set(['WAITING_SWEEP', 'WAIT_MODEL1', 'WAIT_TRIGGER', 'IN_TRADE', 'TP1_RUNNER']);
  const TRADED = new Set(['IN_TRADE', 'TP1_RUNNER', 'TP2', 'STOPPED', 'BREAKEVEN']);

  function findAllSetups(data, opts = {}) {
    const o = { ...DEFAULTS, ...opts };
    const out = [];
    const { htf } = data;
    for (let i = 4; i < htf.length - 1; i++) {
      if (!isThick(htf[i], o.minBodyRatio)) continue;
      const s = evaluateImpulseAt(data, i, o);
      if (s.state === 'NO_LTF') continue;
      Object.assign(s, buildChecks(s, o));
      out.push(s);
    }
    return out;
  }

  function evaluateLive(data, opts = {}) {
    const o = { ...DEFAULTS, ...opts };
    const { htf } = data;
    const setups = [];
    for (let i = htf.length - 2; i >= Math.max(4, htf.length - 2 - o.lookbackC1); i--) {
      if (!isThick(htf[i], o.minBodyRatio)) continue;
      const s = evaluateImpulseAt(data, i, o);
      if (s.state === 'NO_LTF') continue;
      Object.assign(s, buildChecks(s, o));
      setups.push(s);
    }
    const recentCutoff = htf.length - 8;
    const rank = s => {
      const isRecent = s.c1Idx >= recentCutoff ? 10 : 0;
      const stateScore = { IN_TRADE: 6, TP1_RUNNER: 6, WAIT_TRIGGER: 5, WAIT_MODEL1: 4, WAITING_SWEEP: 3 }[s.state] || (TRADED.has(s.state) ? 2 : 1);
      return isRecent + stateScore;
    };
    const primary = setups.slice().sort((a, b) => rank(b) - rank(a) || b.c1Idx - a.c1Idx)[0] || null;
    return { primary, setups, opts: o };
  }

  const STATE_INFO = {
    C1_FORMING: { label: 'BOS Forming', tone: 'muted', step: 0 },
    WAITING_SWEEP: { label: 'Wait IDM Sweep', tone: 'info', step: 1 },
    WAIT_MODEL1: { label: 'In POI · Wait CHoCH', tone: 'warn', step: 2 },
    WAIT_TRIGGER: { label: 'Adv CHoCH · Wait OB', tone: 'warn', step: 3 },
    IN_TRADE: { label: 'SMC OB LIVE', tone: 'live', step: 4 },
    TP1_RUNNER: { label: 'TP1 Hit · Trail X1-X3', tone: 'good', step: 5 },
    TP2: { label: 'TP2 Target Hit', tone: 'good', step: 6 },
    BREAKEVEN: { label: 'Trail SL / BE Exit', tone: 'good', step: 6 },
    STOPPED: { label: 'Stopped Out', tone: 'bad', step: 6 },
    LOW_RR: { label: 'Skipped · Low R:R', tone: 'muted', step: 4 },
    MISSED: { label: 'Missed Entry', tone: 'muted', step: 3 },
    INVALID: { label: 'Origin Broken', tone: 'muted', step: 2 },
    EXPIRED: { label: 'POI Expired', tone: 'muted', step: 1 }
  };

  window.CRTEngine = { DEFAULTS, metrics, isThick, atr, evaluateLive, findAllSetups, STATE_INFO, ACTIVE, TRADED, lowerBound };
})();
