/**
 * Institutional Candlestick Chart Renderer
 *  - Authentic TradingView Pro dark palette (#131722 canvas, #089981 bull, #f23645 bear)
 *  - Real-time current price line + live tick updates anchored to the right edge
 *  - TradingView-style Blue & Red Long/Short Position Tool (Red = Stop Loss, Blue = TP1/TP2)
 *  - Native Canvas candlestick fallback if CDN is unreachable
 */
(function () {
  const T = window.CRTTime;

  const THEME = {
    bg: '#131722',
    grid: 'rgba(42, 46, 57, 0.55)',
    border: '#2a2e39',
    text: '#868993',
    up: '#089981',
    down: '#f23645',
    wickUp: '#089981',
    wickDown: '#f23645'
  };

  function cleanCandles(raw) {
    if (!Array.isArray(raw) || !raw.length) return [];
    const sorted = raw
      .filter(c => c && isFinite(c.time) && isFinite(c.open) && isFinite(c.high) && isFinite(c.low) && isFinite(c.close))
      .slice()
      .sort((a, b) => a.time - b.time);
    const out = [];
    for (const c of sorted) {
      const hi = Math.max(c.open, c.high, c.low, c.close);
      const lo = Math.min(c.open, c.high, c.low, c.close);
      const item = { time: c.time, open: c.open, high: hi, low: lo, close: c.close };
      if (out.length && T.toChartTime(out[out.length - 1].time) === T.toChartTime(item.time)) {
        out[out.length - 1] = item;
      } else {
        out.push(item);
      }
    }
    return out;
  }

  function roundedRect(ctx, x, y, w, h, r) {
    const rr = Math.min(r, Math.abs(w) / 2, Math.abs(h) / 2);
    ctx.beginPath();
    ctx.moveTo(x + rr, y);
    ctx.lineTo(x + w - rr, y);
    ctx.quadraticCurveTo(x + w, y, x + w, y + rr);
    ctx.lineTo(x + w, y + h - rr);
    ctx.quadraticCurveTo(x + w, y + h, x + w - rr, y + h);
    ctx.lineTo(x + rr, y + h);
    ctx.quadraticCurveTo(x, y + h, x, y + h - rr);
    ctx.lineTo(x, y + rr);
    ctx.quadraticCurveTo(x, y, x + rr, y);
    ctx.closePath();
  }

  class CRTChart {
    constructor(container, { title = '', onHover = null } = {}) {
      this.container = container;
      this.data = [];
      this.ann = null;
      this.granMs = 60000;
      this.decimals = 2;
      this.onHover = onHover;
      container.innerHTML = '';
      container.style.position = 'relative';

      this.mount = document.createElement('div');
      Object.assign(this.mount.style, {
        position: 'absolute',
        inset: '0',
        width: '100%',
        height: '100%',
        zIndex: '1'
      });
      container.appendChild(this.mount);

      this.hasLWC = typeof window.LightweightCharts !== 'undefined';

      if (this.hasLWC) {
        const w = Math.max(container.clientWidth || 540, 300);
        const h = Math.max(container.clientHeight || 400, 260);
        this.chart = LightweightCharts.createChart(this.mount, {
          width: w,
          height: h,
          layout: {
            background: { color: THEME.bg },
            textColor: THEME.text,
            fontFamily: '-apple-system, BlinkMacSystemFont, "Trebuchet MS", Roboto, Ubuntu, sans-serif',
            fontSize: 11
          },
          grid: {
            vertLines: { color: THEME.grid },
            horzLines: { color: THEME.grid }
          },
          rightPriceScale: {
            borderColor: THEME.border,
            scaleMargins: { top: 0.08, bottom: 0.08 },
            autoScale: true
          },
          timeScale: {
            borderColor: THEME.border,
            timeVisible: true,
            secondsVisible: false,
            rightOffset: 8,
            barSpacing: 8,
            minBarSpacing: 2
          },
          crosshair: {
            mode: LightweightCharts.CrosshairMode.Normal,
            vertLine: { color: '#758696', width: 1, style: 3, labelBackgroundColor: '#2a2e39' },
            horzLine: { color: '#758696', width: 1, style: 3, labelBackgroundColor: '#2a2e39' }
          },
          localization: {
            timeFormatter: t => T.fmtCAT(T.fromChartTime(t)) + ' CAT'
          }
        });

        this.series = this.chart.addCandlestickSeries({
          upColor: THEME.up,
          downColor: THEME.down,
          borderUpColor: THEME.up,
          borderDownColor: THEME.down,
          wickUpColor: THEME.wickUp,
          wickDownColor: THEME.wickDown,
          lastValueVisible: true,
          priceLineVisible: true,
          priceLineWidth: 1,
          priceLineStyle: 2
        });
        this.priceLines = [];
      }

      this.canvas = document.createElement('canvas');
      Object.assign(this.canvas.style, { position: 'absolute', inset: '0', pointerEvents: 'none', zIndex: '2' });
      container.appendChild(this.canvas);

      // Subtle top-left OHLC & watermark bar inside the chart
      this.ohlcEl = document.createElement('div');
      this.ohlcEl.className = 'chart-ohlc-bar';
      container.appendChild(this.ohlcEl);

      this.titleEl = document.createElement('div');
      this.titleEl.className = 'chart-watermark';
      this.titleEl.textContent = title;
      container.appendChild(this.titleEl);

      const onResize = () => {
        if (this.chart) {
          const rw = Math.max(this.container.clientWidth, 260);
          const rh = Math.max(this.container.clientHeight, 240);
          this.chart.applyOptions({ width: rw, height: rh });
        }
        this.requestDraw();
      };

      if (this.chart) {
        this.chart.timeScale().subscribeVisibleLogicalRangeChange(() => this.requestDraw());
        this.chart.subscribeCrosshairMove(param => {
          this.updateOhlcBar(param);
          this.requestDraw();
        });
      }
      new ResizeObserver(onResize).observe(container);
      container.addEventListener('wheel', () => this.requestDraw(), { passive: true });
      container.addEventListener('mouseup', () => this.requestDraw());
      this.countdownTimer = setInterval(() => this.requestDraw(), 1000);
    }

    getCountdownInfo() {
      const g = Math.max(this.granMs || 60000, 60000);
      const now = Date.now();
      const last = this.data.length ? this.data[this.data.length - 1] : null;
      let closeMs = (Math.floor(now / g) + 1) * g;
      if (last && last.time + g > now && last.time <= now + g) {
        closeMs = last.time + g;
      }
      const remSec = Math.max(0, Math.floor((closeMs - now) / 1000));
      const h = Math.floor(remSec / 3600);
      const m = Math.floor((remSec % 3600) / 60);
      const s = remSec % 60;
      const pad = n => String(n).padStart(2, '0');
      const short = h > 0 ? `${pad(h)}:${pad(m)}:${pad(s)}` : `${pad(m)}:${pad(s)}`;
      const long = h > 0 ? `${h}h ${pad(m)}m ${pad(s)}s` : `${m}m ${pad(s)}s`;
      return { remSec, short, long };
    }

    updateOhlcBar(param) {
      if (!this.ohlcEl || !this.data.length) return;
      const dec = this.decimals || 2;
      let bar = null;
      if (param && param.time && this.series && param.seriesData) {
        bar = param.seriesData.get(this.series);
      }
      if (!bar) {
        bar = this.data[this.data.length - 1];
      }
      if (!bar || !isFinite(bar.open)) return;
      const isUp = bar.close >= bar.open;
      const chg = bar.close - bar.open;
      const pct = bar.open ? (chg / bar.open) * 100 : 0;
      const col = isUp ? '#089981' : '#f23645';
      this.ohlcEl.innerHTML = `
        <span class="ohlc-item">O <b style="color:${col}">${bar.open.toFixed(dec)}</b></span>
        <span class="ohlc-item">H <b style="color:${col}">${bar.high.toFixed(dec)}</b></span>
        <span class="ohlc-item">L <b style="color:${col}">${bar.low.toFixed(dec)}</b></span>
        <span class="ohlc-item">C <b style="color:${col}">${bar.close.toFixed(dec)}</b></span>
        <span class="ohlc-item" style="color:${col}">${chg >= 0 ? '+' : ''}${chg.toFixed(dec)} (${pct >= 0 ? '+' : ''}${pct.toFixed(2)}%)</span>
      `;
    }

    setTitle(t) {
      if (this.titleEl) this.titleEl.textContent = t;
    }

    setPrecision(decimals) {
      this.decimals = decimals;
      if (this.series) {
        this.series.applyOptions({
          priceFormat: { type: 'price', precision: decimals, minMove: Math.pow(10, -decimals) }
        });
      }
    }

    setData(candles, granMs) {
      this.granMs = granMs || this.granMs || 60000;
      const cleaned = cleanCandles(candles);
      this.data = cleaned;
      if (this.series && cleaned.length) {
        try {
          const lwcData = cleaned.map(c => ({
            time: T.toChartTime(c.time),
            open: c.open,
            high: c.high,
            low: c.low,
            close: c.close
          }));
          this.series.setData(lwcData);
          this.fit(85);
        } catch (err) {
          console.warn('LWC setData fallback:', err);
        }
      }
      this.updateOhlcBar(null);
      this.requestDraw();
    }

    update(c) {
      if (!c || !isFinite(c.time) || !isFinite(c.close)) return;
      const hi = Math.max(c.open, c.high, c.low, c.close);
      const lo = Math.min(c.open, c.high, c.low, c.close);
      const clean = { time: c.time, open: c.open, high: hi, low: lo, close: c.close };

      const last = this.data[this.data.length - 1];
      if (last && T.toChartTime(clean.time) < T.toChartTime(last.time)) return;
      if (last && T.toChartTime(clean.time) === T.toChartTime(last.time)) {
        this.data[this.data.length - 1] = clean;
      } else {
        this.data.push(clean);
      }
      if (this.series) {
        try {
          this.series.update({
            time: T.toChartTime(clean.time),
            open: clean.open,
            high: clean.high,
            low: clean.low,
            close: clean.close
          });
        } catch (e) {}
      }
      this.updateOhlcBar(null);
      this.requestDraw();
    }

    fit(bars = 85) {
      const n = this.data.length;
      if (!n || !this.chart) return;
      this.chart.timeScale().setVisibleLogicalRange({
        from: Math.max(0, n - bars),
        to: n + 6
      });
      if (this.chart.priceScale) {
        try { this.chart.priceScale('right').applyOptions({ autoScale: true }); } catch (e) {}
      }
      this.requestDraw();
    }

    focusTime(ms, barsBefore = 45, barsAfter = 25) {
      if (!this.chart || !this.data.length || !isFinite(ms)) {
        this.fit(85);
        return;
      }
      const idx = this.indexOf(ms);
      if (!isFinite(idx)) {
        this.fit(85);
        return;
      }
      const from = Math.max(0, idx - barsBefore);
      const to = Math.min(this.data.length + 8, Math.max(from + 20, idx + barsAfter));
      this.chart.timeScale().setVisibleLogicalRange({ from, to });
      this.requestDraw();
    }

    indexOf(ms) {
      const d = this.data;
      if (!d.length || !isFinite(ms)) return 0;
      const g = Math.max(this.granMs || 60000, 1000);
      if (ms <= d[0].time) return (ms - d[0].time) / g;
      if (ms >= d[d.length - 1].time) return d.length - 1 + (ms - d[d.length - 1].time) / g;
      let lo = 0, hi = d.length - 1;
      while (hi - lo > 1) {
        const mid = (lo + hi) >> 1;
        if (d[mid].time <= ms) lo = mid; else hi = mid;
      }
      const span = Math.max(d[hi].time - d[lo].time, 1);
      return lo + Math.min(1, (ms - d[lo].time) / Math.min(span, g));
    }

    x(ms) {
      if (!this.chart) return null;
      return this.chart.timeScale().logicalToCoordinate(this.indexOf(ms));
    }
    y(p) {
      if (!this.series || !isFinite(p)) return null;
      return this.series.priceToCoordinate(p);
    }

    setAnnotations(ann) {
      this.ann = ann;
      if (this.series) {
        this.priceLines.forEach(pl => {
          try { this.series.removePriceLine(pl); } catch (e) {}
        });
        this.priceLines = (ann?.priceLines || []).map(p => this.series.createPriceLine({
          price: p.price,
          color: p.color,
          lineWidth: p.width || 1,
          lineStyle: p.style ?? 2,
          axisLabelVisible: true,
          title: p.title
        }));

        const snap = ms => {
          if (!this.data.length) return null;
          const i = Math.round(Math.max(0, Math.min(this.data.length - 1, this.indexOf(ms))));
          return this.data[i] ? T.toChartTime(this.data[i].time) : null;
        };
        const rawMarkers = (ann?.markers || [])
          .map(m => ({ ...m, time: snap(m.time) }))
          .filter(m => m.time != null)
          .sort((a, b) => a.time - b.time);
        try { this.series.setMarkers(rawMarkers); } catch (e) {}
      }
      this.requestDraw();
    }

    requestDraw() {
      if (this.raf) return;
      this.raf = requestAnimationFrame(() => { this.raf = null; this.draw(); });
    }

    draw() {
      const rect = this.container.getBoundingClientRect();
      const dpr = window.devicePixelRatio || 1;
      const cv = this.canvas;
      if (cv.width !== Math.round(rect.width * dpr) || cv.height !== Math.round(rect.height * dpr)) {
        cv.width = Math.round(rect.width * dpr);
        cv.height = Math.round(rect.height * dpr);
        cv.style.width = rect.width + 'px';
        cv.style.height = rect.height + 'px';
      }
      const ctx = cv.getContext('2d');
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
      ctx.clearRect(0, 0, rect.width, rect.height);
      if (!this.data.length) return;

      if (!this.hasLWC) {
        this.drawFallbackCandles(ctx, rect.width, rect.height);
        return;
      }
      if (!this.ann) return;

      const rightScaleW = this.chart.priceScale('right').width() || 68;
      const timeScaleH = this.chart.timeScale().height() || 26;
      const plotW = rect.width - rightScaleW;
      const plotH = rect.height - timeScaleH;

      ctx.save();
      ctx.beginPath();
      ctx.rect(0, 0, plotW, plotH);
      ctx.clip();

      // 1. Session bands
      for (const b of this.ann.bands || []) {
        const x1 = this.x(b.from), x2 = this.x(b.to);
        if (x1 == null || x2 == null || x2 < 0 || x1 > plotW) continue;
        ctx.fillStyle = b.fill;
        ctx.fillRect(x1, 0, x2 - x1, plotH);
        if (x2 - x1 > 46) {
          ctx.fillStyle = b.labelColor || 'rgba(134, 137, 147, 0.55)';
          ctx.font = '500 9px -apple-system, BlinkMacSystemFont, sans-serif';
          ctx.fillText(b.label, Math.max(x1, 0) + 4, plotH - 6);
        }
      }

      // 2. Boxes (CRT Range, Key Levels, Inside Candles, OTE Zone)
      for (const b of this.ann.boxes || []) {
        const x1 = this.x(b.from), x2 = this.x(b.to);
        const y1 = this.y(b.top), y2 = this.y(b.bottom);
        if ([x1, x2, y1, y2].some(v => v == null)) continue;
        const h = Math.max(Math.abs(y2 - y1), 2);
        const top = Math.min(y1, y2);
        if (b.fill) { ctx.fillStyle = b.fill; ctx.fillRect(x1, top, x2 - x1, h); }
        if (b.stroke) {
          ctx.strokeStyle = b.stroke;
          ctx.lineWidth = b.lineWidth || 1;
          ctx.setLineDash(b.dash ? [4, 3] : []);
          ctx.strokeRect(x1 + 0.5, top + 0.5, x2 - x1, h);
          ctx.setLineDash([]);
        }
        if (b.label) {
          this.tag(ctx, b.label, Math.max(x1, 2) + 4, (b.labelPos === 'bottom' ? top + h - 10 : top + 10), b.labelColor || b.stroke || '#868993', plotW);
        }
      }

      // 3. Structural Horizontal Rays (CRTH, 50% Midpoint, CRTL, Model #1)
      for (const l of this.ann.lines || []) {
        const x1 = l.from != null ? this.x(l.from) : 0;
        const x2 = l.to != null ? this.x(l.to) : plotW;
        const y = this.y(l.price);
        if (x1 == null || x2 == null || y == null) continue;
        ctx.strokeStyle = l.color;
        ctx.lineWidth = l.width || 1.2;
        ctx.setLineDash(l.dash ? [5, 4] : []);
        ctx.beginPath();
        ctx.moveTo(x1, Math.round(y) + 0.5);
        ctx.lineTo(x2, Math.round(y) + 0.5);
        ctx.stroke();
        ctx.setLineDash([]);
        if (l.label) this.tag(ctx, l.label, Math.min(Math.max(x1, 2) + 4, plotW - 110), y - 9, l.color, plotW);
      }

      // 4. TradingView Long/Short Position Tool (Red Stop-Loss Zone + Blue Target Zone)
      if (this.ann && this.ann.positionBox) {
        this.drawPositionBox(ctx, this.ann.positionBox, plotW, plotH);
      }

      // 5. Live Candle Close Countdown Pill at Current Price (TradingView style)
      const lastBar = this.data[this.data.length - 1];
      if (lastBar) {
        const yLast = this.y(lastBar.close);
        if (yLast != null && yLast > 12 && yLast < plotH - 18) {
          const cd = this.getCountdownInfo();
          const isUp = lastBar.close >= lastBar.open;
          const badgeBg = isUp ? 'rgba(8, 153, 129, 0.92)' : 'rgba(242, 54, 69, 0.92)';
          const txt = `Closes in ${cd.long}`;
          ctx.font = '600 10px "JetBrains Mono", monospace';
          const tw = ctx.measureText(txt).width + 10;
          this.pill(ctx, txt, plotW - tw - 4, yLast + 14, badgeBg, '#ffffff', plotW);
        }
      }

      ctx.restore();
    }

    drawPositionBox(ctx, pos, plotW) {
      const x1 = this.x(pos.from);
      const x2 = Math.min(plotW - 6, Math.max((this.x(pos.to) ?? (x1 + 130)), (x1 ?? 0) + 100));
      const yEntry = this.y(pos.entry);
      const ySL = this.y(pos.sl);
      const yTP1 = this.y(pos.tp1);
      const yTP2 = this.y(pos.tp2);
      if ([x1, yEntry, ySL, yTP1, yTP2].some(v => v == null)) return;
      if (x2 < 0 || x1 > plotW) return;

      const boxW = Math.max(72, x2 - x1);
      const dec = this.decimals || 2;

      // A. RED ZONE — Stop Loss Risk Zone
      const slTop = Math.min(yEntry, ySL);
      const slH = Math.max(Math.abs(ySL - yEntry), 4);
      ctx.fillStyle = 'rgba(242, 54, 69, 0.24)';
      ctx.fillRect(x1, slTop, boxW, slH);
      ctx.strokeStyle = 'rgba(242, 54, 69, 0.85)';
      ctx.lineWidth = 1.25;
      ctx.strokeRect(x1 + 0.5, slTop + 0.5, boxW, slH);

      // B. BLUE ZONE — Profit Target Zone (Entry to TP2)
      const tpTop = Math.min(yEntry, yTP2);
      const tpH = Math.max(Math.abs(yTP2 - yEntry), 6);
      ctx.fillStyle = 'rgba(41, 98, 255, 0.22)';
      ctx.fillRect(x1, tpTop, boxW, tpH);
      ctx.strokeStyle = 'rgba(41, 98, 255, 0.85)';
      ctx.lineWidth = 1.25;
      ctx.strokeRect(x1 + 0.5, tpTop + 0.5, boxW, tpH);

      // C. Entry Line
      ctx.strokeStyle = '#d1d4dc';
      ctx.lineWidth = 1.8;
      ctx.beginPath();
      ctx.moveTo(x1, yEntry);
      ctx.lineTo(x1 + boxW, yEntry);
      ctx.stroke();

      // D. 50% Equilibrium TP1 + Breakeven Line
      ctx.strokeStyle = '#f59e0b';
      ctx.lineWidth = 1.4;
      ctx.setLineDash([5, 4]);
      ctx.beginPath();
      ctx.moveTo(x1, yTP1);
      ctx.lineTo(x1 + boxW, yTP1);
      ctx.stroke();
      ctx.setLineDash([]);

      // E. Compact TradingView-style Position Labels
      this.pill(ctx, `SL ${pos.sl.toFixed(dec)} (-1R)`, x1 + 5, ySL + (pos.isBear ? -10 : 10), '#b91c1c', '#ffffff', plotW);
      this.pill(ctx, `${pos.dir} ${pos.entry.toFixed(dec)}`, x1 + 5, yEntry, '#1d4ed8', '#ffffff', plotW);
      this.pill(ctx, `TP1 50% ${pos.tp1.toFixed(dec)} (${pos.rr1.toFixed(1)}R)`, x1 + 5, yTP1, '#b45309', '#ffffff', plotW);
      this.pill(ctx, `TP2 ${pos.tp2.toFixed(dec)} (${pos.rr2.toFixed(1)}R)`, x1 + 5, yTP2 + (pos.isBear ? 10 : -10), '#047857', '#ffffff', plotW);
    }

    pill(ctx, text, x, y, bg, fg, maxX) {
      ctx.save();
      ctx.font = '600 10px "JetBrains Mono", monospace';
      const w = ctx.measureText(text).width + 10;
      const h = 16;
      const xx = Math.max(4, Math.min(x, maxX - w - 4));
      const yy = y - h / 2;
      ctx.fillStyle = bg;
      roundedRect(ctx, xx, yy, w, h, 3);
      ctx.fill();
      ctx.fillStyle = fg;
      ctx.textBaseline = 'middle';
      ctx.fillText(text, xx + 5, y + 0.5);
      ctx.restore();
    }

    tag(ctx, text, x, y, color, maxX) {
      ctx.font = '500 10px -apple-system, BlinkMacSystemFont, sans-serif';
      const w = ctx.measureText(text).width + 8;
      const xx = Math.max(2, Math.min(x, maxX - w - 2));
      ctx.fillStyle = 'rgba(19, 23, 34, 0.88)';
      ctx.fillRect(xx, y - 7, w, 14);
      ctx.fillStyle = color;
      ctx.textBaseline = 'middle';
      ctx.fillText(text, xx + 4, y + 0.5);
      ctx.textBaseline = 'alphabetic';
    }

    drawFallbackCandles(ctx, width, height) {
      const candles = this.data.slice(-85);
      if (!candles.length) return;
      ctx.fillStyle = THEME.bg;
      ctx.fillRect(0, 0, width, height);
      const padL = 10, padR = 72, padT = 24, padB = 24;
      const pw = width - padL - padR, ph = height - padT - padB;
      let minP = Infinity, maxP = -Infinity;
      candles.forEach(c => { if (c.low < minP) minP = c.low; if (c.high > maxP) maxP = c.high; });
      const m = (maxP - minP) * 0.08 || 1;
      minP -= m; maxP += m;
      const py = p => padT + ((maxP - p) / (maxP - minP)) * ph;
      const step = pw / candles.length;
      const cw = Math.max(3, step * 0.68);
      candles.forEach((c, i) => {
        const cx = padL + (i + 0.5) * step;
        const bull = c.close >= c.open;
        const col = bull ? THEME.up : THEME.down;
        ctx.strokeStyle = col;
        ctx.beginPath(); ctx.moveTo(cx, py(c.high)); ctx.lineTo(cx, py(c.low)); ctx.stroke();
        const top = Math.min(py(c.open), py(c.close));
        const bh = Math.max(2, Math.abs(py(c.close) - py(c.open)));
        ctx.fillStyle = col;
        ctx.fillRect(cx - cw / 2, top, cw, bh);
      });
    }

    destroy() { if (this.chart) this.chart.remove(); }
  }

  function equityChart(container) {
    container.innerHTML = '';
    if (typeof window.LightweightCharts === 'undefined') return { set() {} };
    const w = Math.max(container.clientWidth || 600, 300);
    const h = Math.max(container.clientHeight || 250, 220);
    const chart = LightweightCharts.createChart(container, {
      width: w,
      height: h,
      layout: { background: { color: THEME.bg }, textColor: THEME.text, fontFamily: '-apple-system, BlinkMacSystemFont, sans-serif', fontSize: 11 },
      grid: { vertLines: { color: THEME.grid }, horzLines: { color: THEME.grid } },
      rightPriceScale: { borderColor: THEME.border },
      timeScale: { borderColor: THEME.border, timeVisible: true },
      localization: { timeFormatter: t => T.fmtCAT(T.fromChartTime(t)) + ' CAT', priceFormatter: p => p.toFixed(1) + 'R' }
    });
    new ResizeObserver(() => {
      chart.applyOptions({
        width: Math.max(container.clientWidth, 260),
        height: Math.max(container.clientHeight, 200)
      });
    }).observe(container);
    const a = chart.addLineSeries({ color: '#089981', lineWidth: 2, title: 'With 50% rule' });
    const b = chart.addLineSeries({ color: '#f23645', lineWidth: 2, lineStyle: 2, title: 'Without 50% rule' });
    return {
      set(trades, with50, without50) {
        let last = 0;
        const times = trades.map(t => { let ct = T.toChartTime(t.exitTime); if (ct <= last) ct = last + 1; last = ct; return ct; });
        a.setData(times.map((t, i) => ({ time: t, value: with50.curve[i] })));
        b.setData(times.map((t, i) => ({ time: t, value: without50.curve[i] })));
        chart.timeScale().fitContent();
      }
    };
  }

  window.CRTChart = CRTChart;
  window.CRTEquityChart = equityChart;
})();
