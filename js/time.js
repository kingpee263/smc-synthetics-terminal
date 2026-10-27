/**
 * Time engine — Central African Time (CAT, UTC+2, no DST) display,
 * New York time (with real US DST rules) for PDF 2's AMD windows,
 * and NY-aligned candle bucketing so HTF candles match PDF 2's Candle 1/2/3.
 * All internal timestamps are UTC milliseconds.
 */
(function () {
  const HOUR = 3600e3;
  const DAY = 24 * HOUR;
  const CAT_OFFSET = 2 * HOUR;

  // nth Sunday of a month (month 0-based) → day of month
  function nthSunday(year, month, n) {
    const firstDow = new Date(Date.UTC(year, month, 1)).getUTCDay();
    return 1 + ((7 - firstDow) % 7) + (n - 1) * 7;
  }

  // US DST: 2nd Sunday of March 02:00 EST (07:00 UTC) → 1st Sunday of November 02:00 EDT (06:00 UTC)
  const dstCache = {};
  function dstRange(year) {
    if (!dstCache[year]) {
      dstCache[year] = {
        start: Date.UTC(year, 2, nthSunday(year, 2, 2), 7),
        end: Date.UTC(year, 10, nthSunday(year, 10, 1), 6)
      };
    }
    return dstCache[year];
  }

  function nyOffsetHours(ms) {
    const r = dstRange(new Date(ms).getUTCFullYear());
    return ms >= r.start && ms < r.end ? -4 : -5;
  }
  function isNYDst(ms) { return nyOffsetHours(ms) === -4; }

  // "Wall clock" encoded as a UTC Date (read with getUTC*)
  const nyWall = ms => new Date(ms + nyOffsetHours(ms) * HOUR);
  const catWall = ms => new Date(ms + CAT_OFFSET);

  // Convert an NY wall-clock value (encoded as UTC ms) back to real UTC ms
  function nyWallToUtc(wallMs) {
    const guess = wallMs + 5 * HOUR;
    return wallMs - nyOffsetHours(guess) * HOUR;
  }

  // Convert an NY wall clock hour on a given CAT date to CAT hour (for tables)
  function nyHourToCatHour(nyHour, refMs = Date.now()) {
    return (nyHour - nyOffsetHours(refMs) + 2 + 24) % 24;
  }

  const pad = n => String(n).padStart(2, '0');
  const DOW = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];

  function fmtCAT(ms, mode = 'datetime') {
    const d = catWall(ms);
    const hm = `${pad(d.getUTCHours())}:${pad(d.getUTCMinutes())}`;
    if (mode === 'time') return hm;
    if (mode === 'seconds') return `${hm}:${pad(d.getUTCSeconds())}`;
    return `${DOW[d.getUTCDay()]} ${pad(d.getUTCDate())}/${pad(d.getUTCMonth() + 1)} ${hm}`;
  }
  function fmtNY(ms) {
    const d = nyWall(ms);
    return `${pad(d.getUTCHours())}:${pad(d.getUTCMinutes())} NY`;
  }
  const fmtHour = h => `${pad(Math.floor(h))}:${pad(Math.round((h % 1) * 60))}`;

  /* ---------------- Candle bucketing ---------------- */
  // Forex trading day starts 17:00 NY → shift wall clock +7h so the trading day is a calendar day.
  const floorDay = ms => Math.floor(ms / DAY) * DAY;

  const BUCKETS = {
    // NY 4H candles: 17,21,01,05,09,13 NY (PDF 2: 01–05 Acc, 05–09 Manip, 09–13 Dist)
    ny4h(ms) {
      const w = nyWall(ms);
      const h = w.getUTCHours();
      const back = (h - 1 + 24) % 4;
      const wallStart = Date.UTC(w.getUTCFullYear(), w.getUTCMonth(), w.getUTCDate(), h) - back * HOUR;
      return nyWallToUtc(wallStart);
    },
    nyday(ms) {
      const w = nyWall(ms).getTime() + 7 * HOUR;
      return nyWallToUtc(floorDay(w) - 7 * HOUR);
    },
    nyweek(ms) {
      const w = nyWall(ms).getTime() + 7 * HOUR;
      const day = floorDay(w);
      const dow = (new Date(day).getUTCDay() + 6) % 7; // Mon = 0
      return nyWallToUtc(day - dow * DAY - 7 * HOUR);
    },
    nymonth(ms) {
      const w = new Date(nyWall(ms).getTime() + 7 * HOUR);
      return nyWallToUtc(Date.UTC(w.getUTCFullYear(), w.getUTCMonth(), 1) - 7 * HOUR);
    },
    utcweek(ms) {
      const day = floorDay(ms);
      const dow = (new Date(day).getUTCDay() + 6) % 7;
      return day - dow * DAY;
    },
    utcmonth(ms) {
      const d = new Date(ms);
      return Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), 1);
    }
  };

  function fixedBucket(granSec) {
    const g = granSec * 1000;
    return ms => Math.floor(ms / g) * g;
  }

  function aggregate(candles, bucketFn) {
    const out = [];
    let cur = null;
    for (const c of candles) {
      const b = bucketFn(c.time);
      if (!cur || cur.time !== b) {
        cur = { time: b, open: c.open, high: c.high, low: c.low, close: c.close };
        out.push(cur);
      } else {
        if (c.high > cur.high) cur.high = c.high;
        if (c.low < cur.low) cur.low = c.low;
        cur.close = c.close;
      }
    }
    return out;
  }

  /* ---------------- AMD phase (PDF 2 p.12–14) ---------------- */
  // Windows in NY hours
  const AMD_4H = [
    { from: 1, to: 5, phase: 'Accumulation', candle: 'C1', key: 'acc' },
    { from: 5, to: 9, phase: 'Manipulation', candle: 'C2', key: 'man' },
    { from: 9, to: 13, phase: 'Distribution', candle: 'C3', key: 'dis' }
  ];
  const AMD_NY = [
    { from: 9, to: 9.5, phase: 'NY Accumulation', candle: 'C1', key: 'acc' },
    { from: 9.5, to: 10.5, phase: 'NY Manipulation', candle: 'C2', key: 'man' },
    { from: 10.5, to: 11, phase: 'NY Distribution', candle: 'C3', key: 'dis' }
  ];

  function amdNow(ms = Date.now()) {
    const w = nyWall(ms);
    const h = w.getUTCHours() + w.getUTCMinutes() / 60 + w.getUTCSeconds() / 3600;
    const micro = AMD_NY.find(x => h >= x.from && h < x.to);
    const cycle = AMD_4H.find(x => h >= x.from && h < x.to);
    const active = micro || cycle;
    let nextChangeH;
    if (active) nextChangeH = active.to;
    else nextChangeH = h < 1 ? 1 : 25; // next 01:00 NY
    const remainingMs = (nextChangeH - h) * HOUR;
    return {
      active,
      micro,
      cycle,
      nyHour: h,
      remainingMs,
      isDst: isNYDst(ms),
      label: active ? `${active.candle} · ${active.phase}` : 'Off-cycle (Asia / post-NY)'
    };
  }

  // CAT session table for the playbook, using the DST state at refMs
  function amdTableCAT(refMs = Date.now()) {
    const off = -nyOffsetHours(refMs) + 2; // NY → CAT hours
    const conv = h => fmtHour((h + off + 24) % 24);
    return {
      offset: off,
      isDst: isNYDst(refMs),
      rows: [
        ...AMD_4H.map(r => ({ cycle: '4H Session (PDF 2 p.14)', ...r, ny: `${fmtHour(r.from)}–${fmtHour(r.to)}`, cat: `${conv(r.from)}–${conv(r.to)}` })),
        ...AMD_NY.map(r => ({ cycle: 'NY Open (PDF 2 p.14)', ...r, ny: `${fmtHour(r.from)}–${fmtHour(r.to)}`, cat: `${conv(r.from)}–${conv(r.to)}` }))
      ]
    };
  }

  // Session bands (UTC ms) covering [fromMs, toMs] for chart shading
  function sessionBands(fromMs, toMs) {
    const bands = [];
    let dayWall = floorDay(nyWall(fromMs).getTime()) - DAY;
    const endWall = nyWall(toMs).getTime() + DAY;
    while (dayWall <= endWall) {
      for (const r of AMD_4H) {
        bands.push({
          key: r.key,
          label: `${r.candle} ${r.phase}`,
          from: nyWallToUtc(dayWall + r.from * HOUR),
          to: nyWallToUtc(dayWall + r.to * HOUR)
        });
      }
      dayWall += DAY;
    }
    return bands.filter(b => b.to >= fromMs && b.from <= toMs);
  }

  function nextUsClockChange(ms = Date.now()) {
    const y = new Date(ms).getUTCFullYear();
    const cands = [dstRange(y).start, dstRange(y).end, dstRange(y + 1).start].filter(t => t > ms);
    return cands[0];
  }

  window.CRTTime = {
    HOUR, DAY, CAT_OFFSET,
    nyOffsetHours, isNYDst, nyWall, catWall, nyWallToUtc, nyHourToCatHour,
    fmtCAT, fmtNY, fmtHour,
    BUCKETS, fixedBucket, aggregate,
    amdNow, amdTableCAT, sessionBands, nextUsClockChange,
    toChartTime: ms => Math.floor(ms / 1000) + 7200, // chart axis shows CAT
    fromChartTime: t => (t - 7200) * 1000
  };
})();
