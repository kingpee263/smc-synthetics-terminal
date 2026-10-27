/**
 * Real backtester — replays the exact live engine over real historical candles.
 * One trade at a time per market (no overlapping positions). Entry at the close of the
 * trigger candle; same-bar SL/TP ambiguity resolved as a loss; spreads/commissions ignored.
 */
(function () {
  const F = window.CRTFeeds;
  const E = window.CRTEngine;
  const T = window.CRTTime;

  async function loadHistory(market, pairKey, ltfBars, onProgress) {
    const pair = F.TF_PAIRS[pairKey];
    const recipe = F.htfRecipe(pair.htf, market.profile);
    const bucketFn = F.bucketFnFor(recipe, pair.htf);
    onProgress && onProgress(`Downloading ${ltfBars.toLocaleString()} × ${pair.ltfLabel} candles…`);
    const ltf = await F.getHistory(market, pair.ltf, ltfBars);
    if (!ltf.length) throw new Error('No history returned');
    // HTF must cover the LTF span (+ lookback for key levels)
    const spanMs = ltf[ltf.length - 1].time - ltf[0].time;
    const htfSec = F.HTF_SECONDS[pair.htf];
    const baseBars = Math.min(30000, Math.ceil((spanMs / 1000 + htfSec * 40) / recipe.base));
    onProgress && onProgress(`Downloading ${baseBars.toLocaleString()} HTF base candles…`);
    const htfBase = recipe.base === pair.ltf ? ltf : await F.getHistory(market, recipe.base, baseBars);
    const htf = recipe.bucket ? T.aggregate(htfBase, bucketFn) : htfBase;
    let smtHtf = null, smtMarket = null;
    if (market.smt) {
      smtMarket = F.markets.get(market.smt);
      try {
        onProgress && onProgress(`Downloading SMT partner ${smtMarket.name}…`);
        const sb = await F.getHistory(smtMarket, recipe.base, baseBars);
        smtHtf = recipe.bucket ? T.aggregate(sb, bucketFn) : sb;
      } catch (e) { smtHtf = null; }
    }
    return { market, pair, recipe, bucketFn, htf, ltf, smtHtf, smtMarket };
  }

  function passesFilters(s, f) {
    const st = key => (s.checks.find(c => c.key === key) || {}).status;
    if (f.requireKeyLevel && st('kl') !== 'pass') return false;
    if (f.requireTime && st('time') === 'fail') return false;
    if (f.requireSMT && st('smt') === 'fail') return false;
    if (f.requireAPlus && st('tbs') !== 'pass') return false;
    if (f.minGrade) {
      const order = { 'A+': 3, A: 2, B: 1, C: 0 };
      if (order[s.grade] < order[f.minGrade]) return false;
    }
    return true;
  }

  function stats(trades, key) {
    const rs = trades.map(t => t[key]);
    const n = rs.length;
    const wins = rs.filter(r => r > 0).length;
    const be = rs.filter(r => r === 0).length;
    const total = rs.reduce((a, b) => a + b, 0);
    const grossW = rs.filter(r => r > 0).reduce((a, b) => a + b, 0);
    const grossL = -rs.filter(r => r < 0).reduce((a, b) => a + b, 0);
    let eq = 0, peak = 0, dd = 0, streak = 0, maxStreak = 0;
    const curve = [];
    for (const r of rs) {
      eq += r;
      peak = Math.max(peak, eq);
      dd = Math.max(dd, peak - eq);
      streak = r < 0 ? streak + 1 : 0;
      maxStreak = Math.max(maxStreak, streak);
      curve.push(eq);
    }
    return {
      n, wins, be, losses: n - wins - be,
      winRate: n ? (wins / n) * 100 : 0,
      totalR: total, avgR: n ? total / n : 0,
      pf: grossL > 0 ? grossW / grossL : (grossW > 0 ? Infinity : 0),
      maxDD: dd, maxLossStreak: maxStreak, curve
    };
  }

  async function run(market, pairKey, engineOpts, filters, onProgress) {
    const data = await loadHistory(market, pairKey, filters.ltfBars || 20000, onProgress);
    onProgress && onProgress('Replaying strategy candle by candle…');
    await new Promise(r => setTimeout(r, 20));
    const all = E.findAllSetups(data, engineOpts);
    const funnel = {
      c1: all.length,
      tbs: all.filter(s => s.tbsIdx != null).length,
      triggered: all.filter(s => s.entryIdx != null).length,
      lowRR: all.filter(s => s.state === 'LOW_RR').length,
      invalid: all.filter(s => s.state === 'INVALID' || s.state === 'MISSED').length
    };
    const closed = all
      .filter(s => s.r50 != null && s.rNo != null && passesFilters(s, filters))
      .sort((a, b) => a.entryIdx - b.entryIdx);

    // one position at a time
    const trades = [];
    let busyUntil = -1;
    for (const s of closed) {
      if (s.entryIdx <= busyUntil) continue;
      trades.push(s);
      busyUntil = Math.max(s.exitIdx, s.noExitIdx);
    }
    const ltf = data.ltf;
    return {
      data,
      trades: trades.map(s => ({
        setup: s,
        time: ltf[s.entryIdx].time,
        exitTime: ltf[s.exitIdx].time,
        dir: s.dir,
        grade: s.grade,
        type: s.crtType ? s.crtType.name : '',
        kl: s.keyLevels && s.keyLevels[0] ? s.keyLevels[0].type : '—',
        inside: s.insideLTF,
        smt: s.smt.status,
        time_: s.time.status,
        outcome: s.outcome,
        r50: s.r50,
        rNo: s.rNo,
        rr1: s.rr1,
        rr2: s.rr2
      })),
      with50: stats(trades, 'r50'),
      without50: stats(trades, 'rNo'),
      funnel,
      span: { from: ltf[0].time, to: ltf[ltf.length - 1].time, bars: ltf.length }
    };
  }

  window.CRTBacktest = { run };
})();
