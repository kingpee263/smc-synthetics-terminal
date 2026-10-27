# SMC Auto-Desk — Frank Miller Smart Money Concepts Web Platform (Deriv & Weltrade MT5)

Full institutional web-based auto-trading platform implementing **Frank Miller's *Smart Money Concepts: Unlocking the Path to High Probability Trading*** (Chapters 1–9) connected to **MetaTrader 5** for **Deriv Synthetics** and **Weltrade SyntX**.

Live Web Platform: **[https://kingpee263.github.io/smc-synthetics-terminal/](https://kingpee263.github.io/smc-synthetics-terminal/)**

---

## Core Strategy Rules Implemented (Chapters 1–9)

1. **Chapter 1 · Impulsive & Valid Corrective Waves**:
   - Filters out inside bars. A pullback is only valid when price breaks below the prior candle's low (in an uptrend) or above the prior candle's high (in a downtrend).
2. **Chapter 2 · BOS & CHoCH (Body-Close Confirmed)**:
   - **Break of Structure (BOS)** requires: (1) A valid liquidity sweep of a pullback/inducement first, and (2) A full **candlestick body close** beyond the prior major high/low (wick-only breaks are rejected).
   - **Change of Character (CHoCH)** requires a candlestick body close beyond the origin low/high of the most recent BOS.
3. **Chapter 3 · Liquidity Models & Premium/Discount Zones**:
   - Automatically detects **Structural Highs/Lows**, **Equal Highs/Lows (Double/Triple Tops & Bottoms)**, **Trendline Liquidity (`TLQ`)**, and **Sideways Ranges (`RNG`)**.
   - Divides every `A → B` impulse range at the **50% Fibonacci Equilibrium**: strictly **Buys in Discount (`< 50%`)** and **Sells in Premium (`> 50%`)**.
4. **Chapter 4 · Powerful Order Blocks (`OB`) & Imbalance (`FVG`)**:
   - Validates an Order Block only if it has: (1) **Liquidity Sweep** of the preceding candle, (2) **3-Candle Imbalance / FVG**, and (3) **Market Structure Shift (`BOS` / `CHoCH`)**.
   - **60% ATR Rule**: Automatically extends small Order Blocks (`< 60%` of 14-period ATR) to `1.0 × ATR` for safer stop-loss placement.
   - Disregards mitigated Order Blocks (Rule No. 3).
5. **Chapter 5 · Inducement (`IDM`) Trap Filter**:
   - Marks the first internal pullback before a BOS as an **Inducement (`IDM`) trap** and waits for price to sweep it before entering at the extreme unmitigated Order Block.
6. **Chapters 6 & 7 · POI Types 1–4, Advanced CHoCH & `X1 / X2 / X3` Trailing Stops**:
   - Drops from the Higher Timeframe (`H4 / H1 / M15`) to the Lower Timeframe (`M15 / M5 / M1`) when price taps the HTF POI, waits for an **Advanced CHoCH**, places a **Pending Limit Order** at the LTF Order Block, and automatically trails the Stop Loss across structural swings **`X1 → X2 → X3`**.
7. **Chapter 8 · Candle Breakout Strategy (`CBS`)**:
   - Detects the 2-candle **Reaction Candle + Engulfing Confirmation Candle** inside the POI for both single-timeframe and 2-timeframe refined entries.

---

## Supported Synthetic & Forex Markets

- **Deriv Volatility Indices**: `Volatility 10, 25, 50, 75, 100` & `1s Volatility 10, 15, 25, 30, 50, 75, 90, 100, 150, 200, 250`
- **Deriv Boom & Crash Indices (with Spike-Direction Protection)**: `Boom 300, 500, 600, 900, 1000` & `Crash 300, 500, 600, 900, 1000`
- **Deriv Step, Jump, Range Break & DEX Indices**: `Step 100–500`, `Jump 10–100`, `Range Break 100/200`, `DEX 600/900/1500 UP & DOWN`, `Drift Switch 10/20/30`
- **Weltrade SyntX Indices**: `PainX 400, 600, 800, 999, 1200`, `GainX 400, 600, 800, 999, 1200`, `FlipX / SwitchX 600`, `BreakX 600`, `FX Vol 20–99`, `SFX Vol 20–99`
- **Book Forex & Metals Pairs**: `XAU/USD (Gold)`, `EUR/USD`, `GBP/USD`, `AUD/USD`

---

## Connecting Your MT5 App (`SMC_Auto_Bridge.ex5`)

1. The compiled Expert Advisor [`mt5/SMC_Auto_Bridge.ex5`](./mt5/SMC_Auto_Bridge.ex5) is pre-installed in your MetaTrader 5 `MQL5\Experts` folder.
2. In MetaTrader 5, enable **Algo Trading** on the top toolbar and attach **`SMC_Auto_Bridge`** to any chart.
3. Run `start-local.bat` (or `powershell -ExecutionPolicy Bypass -File server.ps1`) to launch the local bridge on `http://localhost:8095`.
