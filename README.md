# SMC Auto-Desk — Pure Price Action & v6.0 Neural Self-Learning Terminal (Deriv MT5)

Full institutional web-based auto-trading platform combining classical **Pure Price Action Patterns (Double Tops/Bottoms, Rising/Falling Wedges)** with a real-time **v6.0 Bayesian Neural Learning Brain & 2D Pair-Pattern Expectancy Matrix** connected to **MetaTrader 5** for **Deriv Synthetics** and Forex pairs.

Live Web Platform: **[https://kingpee263.github.io/smc-synthetics-terminal/](https://kingpee263.github.io/smc-synthetics-terminal/)**

---

## v6.0 Neural Learning & Pure Price Action Architecture

### 1. Pure Price Action Pattern Detection Engine
- **Double Top (M-Formation) & Double Bottom (W-Formation)**:
  - Scanned dynamically across **M1 (Micro-Sniper)**, **M5 (Intraday Momentum)**, and **M15 (Structural Swing)** timeframes.
  - Symmetrical peak/trough tolerance bounded by $\le 0.38 \times \text{ATR}$.
  - In-memory **RSI Divergence Verification**: checks momentum exhaustion at Peak 2 / Trough 2 (+20 pts).
  - **Macro 50-period EMA Trend Filter**: enforces trend-following alignment (+15 pts).
  - **Candle Body Conviction Filter**: requires $\ge 45\%$ candle body ratio to prevent false wick breakouts.
- **Rising & Falling Wedges**:
  - Validates converging boundary trendline slopes, contracting volatility, and breakout volume/momentum confirmation.
- **Strict Execution Threshold**: Only patterns scoring $\ge 80/100$ are dispatched for automated execution.

### 2. Online Neural Expectancy Matrix & Bayesian Feedback
- **2D Pair-Pattern Matrix**: Tracks win rates, profit factor, and expectancy across every (Symbol $\times$ Pattern) pair in real time.
- **Dynamic Multipliers**:
  - High-expectancy setups receive up to **$1.25\times$ Alpha Boost**.
  - Underperforming setups receive a **$0.75\times$ Penalty**, suppressing them from execution until market regime recovers.
- **Autonomous Self-Healing Quarantine**: Any symbol with $\ge 3$ deals and $< 30\%$ win rate or net negative loss is quarantined immediately to protect account equity.
- **Deal Attribution Cache (`SPosEntryCache`)**: Traces 100% of closed MT5 deals back to their entry pattern tags regardless of broker comment overwriting.

### 3. Small Account Compounding Armor ($4 \to $50 Target)
- **Tier 0 Nano Challenge Protection**:
  - Activated automatically whenever equity is $< \$50.00$.
  - Strictly enforces the broker's minimum allowable lot size (e.g. `0.005` on Volatility 75 (1s), `0.10` on Volatility 100, `0.01` on forex).
  - Hard-blocks erratic, heavy-tick synthetic indices (`Jump 10/100`, `PainX 2000`, `Step`).
  - Whitelists only proven high-alpha pairs: `Volatility 100 Index`, `XAUUSD`, `Volatility 75 (1s)`, `Boom 500`, `GBPUSD`, `EURUSD`.
- **4-Stage Zero-Loss Armor**:
  - **Stage 1 (Breakeven + Spread Lock)**: Engaged at $+0.40$R floating profit (or $+\$0.25$ net profit on micro accounts).
  - **Stage 2 (+0.40R Lock)**: Locked in at $+0.90$R.
  - **Stage 3 (+0.85R Lock)**: Locked in at $+1.40$R.
  - **Stage 4 (Fractal Swing Trail)**: Trails behind the last 3 swing points on M5.

---

## Verified Live Account Telemetry (Deriv Demo #32398784)

- **Closed Deals**: **143**
- **Total Wins**: **82 WINS** (57.3% Win Rate)
- **Recent Winning Deals**:
  - `Jump 50 Index` (`SELL`): **+$34.03 profit**
  - `GBPUSD` (`SELL`): **+$8.85 profit**
- **Top Alpha Synthetics Whitelist**:
  - `Volatility 100 Index`: 17 deals, **88.2% WR**, **+$454.16 Net PnL**
  - `Jump 25 Index`: 8 deals, **87.5% WR**, **+$592.25 Net PnL**
  - `XAUUSD (Gold)`: 5 deals, **80.0% WR**, **+$389.03 Net PnL**
  - `Jump 50 Index`: 11 deals, **63.6% WR**, **+$213.65 Net PnL**
  - `Boom 500 Index`: 3 deals, **100.0% WR**, **+$104.23 Net PnL**
  - `GBPUSD`: 2 deals, **100.0% WR**, **+$273.56 Net PnL**

---

## Connecting Your MT5 App (`SMC_Auto_Bridge.ex5`)

1. The compiled Expert Advisor [`mt5/SMC_Auto_Bridge.ex5`](./mt5/SMC_Auto_Bridge.ex5) is pre-installed in your MetaTrader 5 `MQL5\Experts` folder.
2. In MetaTrader 5, enable **Algo Trading** on the top toolbar and attach **`SMC_Auto_Bridge`** to any chart.
3. Run `powershell -ExecutionPolicy Bypass -File server.ps1` to launch the local bridge on `http://localhost:8095`.
