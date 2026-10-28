//+------------------------------------------------------------------+
//|                                              SMC_Auto_Bridge.mq5 |
//|     Frank Miller Smart Money Concepts (SMC) Live MT5 Auto-Bridge |
//|   Pure A+ Autonomous Execution & Institutional Risk Manager v4.0 |
//+------------------------------------------------------------------+
#property copyright "SMC Desk — Frank Miller Smart Money Concepts"
#property version   "4.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\OrderInfo.mqh>
#include <Trade\PositionInfo.mqh>

input string InpServerUrl         = "http://localhost:8095"; // Local SMC Desk Server URL
input string InpSymbols           = "Volatility 75 (1s) Index,Volatility 75 Index,Volatility 100 (1s) Index,Volatility 100 Index,Volatility 50 (1s) Index,Volatility 50 Index,Volatility 25 (1s) Index,Volatility 25 Index,Volatility 15 (1s) Index,Volatility 10 (1s) Index,Volatility 10 Index,Boom 1000 Index,Crash 1000 Index,Boom 500 Index,Crash 500 Index,Boom 300 Index,Crash 300 Index,Step Index,Jump 10 Index,Jump 25 Index,Jump 50 Index,Jump 75 Index,Jump 100 Index,Range Break 100 Index,Range Break 200 Index,DEX 600 UP,DEX 600 DOWN,DEX 900 UP,DEX 900 DOWN,PainX 400,GainX 400,PainX 600,GainX 600,PainX 800,GainX 800,PainX 999,GainX 999,PainX 1200,GainX 1200,FX Vol 20,FX Vol 40,FX Vol 60,FX Vol 80,FX Vol 99,SFX Vol 20,SFX Vol 40,SFX Vol 60,SFX Vol 80,SFX Vol 99,SwitchX 600,BreakX 600,XAUUSD,EURUSD,GBPUSD"; // Monitored Symbols
input int    InpFullBars          = 500;      // Historical bars exported every sync
input long   InpMagicNumber       = 20260401; // Magic Number for SMC Auto-Trades
input bool   InpEnableAutoExe     = true;     // Enable Pure A+ Auto-Trading & X1-X3 Trailing
input bool   InpNativeAPlusScan   = true;     // Run Native MQL5 Pure A+ Scanner (H1 -> M5)
input double InpRiskPercent       = 1.00;     // Risk per Pure A+ Trade (% of Equity)
input double InpMaxRiskPercent    = 2.50;     // Hard Max Risk Cap per Trade (%)
input int    InpMaxOpenTrades     = 3;        // Max Concurrent Trades Across Account
input double InpMaxDailyLossPct   = 4.00;     // Daily Drawdown Circuit Breaker (%)
input double InpMinRR             = 2.50;     // Minimum TP2 Reward-to-Risk Ratio (Ch. 7)
input int    InpCooldownMinutes   = 60;       // Per-Symbol Cooldown Between Trades (Min)
input int    InpPendingExpiryMin  = 180;      // Expire Unfilled Pending Limit Orders (Min)

CTrade        g_trade;
COrderInfo    g_order;
CPositionInfo g_pos;

datetime g_lastLog        = 0;
datetime g_lastAPlusScan  = 0;
string   g_lastCmdId      = "";
double   g_dayStartEquity = 0.0;
int      g_currentDay     = -1;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   g_trade.SetExpertMagicNumber(InpMagicNumber);
   g_trade.SetDeviationInPoints(30);
   g_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);

   MqlDateTime dt;
   TimeCurrent(dt);
   g_currentDay = dt.day_of_year;

   EventSetTimer(2);
   Print("=================================================================");
   Print("SMC_Auto_Bridge v4.00 (PURE A+ ONLY + RISK MANAGER) initialized");
   Print("Account #", AccountInfoInteger(ACCOUNT_LOGIN), " (", AccountInfoString(ACCOUNT_SERVER), ")");
   Print("Balance: $", DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2),
         " | Equity: $", DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2));
   Print("Risk Rules: ", DoubleToString(InpRiskPercent, 2), "% Risk/Trade | Max ",
         InpMaxOpenTrades, " Open Trades | Max Daily DD ", DoubleToString(InpMaxDailyLossPct, 1),
         "% | Min R:R 1:", DoubleToString(InpMinRR, 1));
   Print("=================================================================");
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   Print("SMC_Auto_Bridge v4.00 stopped.");
}

//+------------------------------------------------------------------+
//| Configure Dynamic Symbol Filling Mode (FOK / IOC / RETURN)       |
//+------------------------------------------------------------------+
void ConfigureSymbolFilling(const string sym)
{
   uint filling = (uint)SymbolInfoInteger(sym, SYMBOL_FILLING_MODE);
   if((filling & SYMBOL_FILLING_FOK) != 0)
      g_trade.SetTypeFilling(ORDER_FILLING_FOK);
   else if((filling & SYMBOL_FILLING_IOC) != 0)
      g_trade.SetTypeFilling(ORDER_FILLING_IOC);
   else
      g_trade.SetTypeFilling(ORDER_FILLING_RETURN);
}

//+------------------------------------------------------------------+
//| Snap Price to Valid Symbol Tick Size & Digits                    |
//+------------------------------------------------------------------+
double NormalizePrice(const string sym, double price)
{
   int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   double tickSize = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize > 0.0)
      price = MathRound(price / tickSize) * tickSize;
   return NormalizeDouble(price, digits);
}

//+------------------------------------------------------------------+
//| Sanitize Symbol Name for File Export                             |
//+------------------------------------------------------------------+
string SanitizeSym(string s)
{
   string out = "";
   int len = StringLen(s);
   for(int i = 0; i < len; i++)
   {
      ushort ch = StringGetCharacter(s, i);
      if((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') || ch == '_' || ch == '-')
         out += ShortToString(ch);
      else if(ch == ' ' || ch == '(' || ch == ')')
         out += "_";
   }
   return out;
}

//+------------------------------------------------------------------+
//| Spike Direction Guard for Boom / Crash / PainX / GainX           |
//+------------------------------------------------------------------+
bool IsCounterSpikeTrade(const string sym, bool isBuy)
{
   string up = sym;
   StringToUpper(up);
   // Boom & GainX spike UP -> never auto-SELL against upward spikes
   if((StringFind(up, "BOOM") >= 0 || StringFind(up, "GAINX") >= 0) && !isBuy)
      return true;
   // Crash & PainX spike DOWN -> never auto-BUY against downward spikes
   if((StringFind(up, "CRASH") >= 0 || StringFind(up, "PAINX") >= 0) && isBuy)
      return true;
   return false;
}

//+------------------------------------------------------------------+
//| Institutional Portfolio & Symbol Risk Guard                      |
//+------------------------------------------------------------------+
bool CanOpenNewTrade(const string sym, const string comment, string &outReason)
{
   // 1. Strict Pure A+ Filter: Block any regular trade that is not explicitly A+
   if(StringFind(comment, "APLUS") < 0 && StringFind(comment, "A+") < 0)
   {
      outReason = "Regular Trade Blocked (Requires Pure A+ 7/7 Confluence)";
      return false;
   }

   // 2. Update Daily High-Water / Day Start Equity & Check Daily Drawdown Circuit Breaker
   MqlDateTime dt;
   TimeCurrent(dt);
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   if(dt.day_of_year != g_currentDay || g_dayStartEquity <= 0.0)
   {
      g_currentDay = dt.day_of_year;
      g_dayStartEquity = MathMax(bal, eq);
   }
   if(g_dayStartEquity > 0.0)
   {
      double ddPct = ((g_dayStartEquity - eq) / g_dayStartEquity) * 100.0;
      if(ddPct >= InpMaxDailyLossPct)
      {
         outReason = StringFormat("Daily Drawdown Circuit Breaker Active (%.2f%% >= %.2f%%)", ddPct, InpMaxDailyLossPct);
         return false;
      }
   }

   // 3. Single Exposure Per Symbol & Max Concurrent Open/Pending Trades
   int activeTotal = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      activeTotal++;
      if(PositionGetString(POSITION_SYMBOL) == sym)
      {
         outReason = "Symbol already has an open position (" + sym + ")";
         return false;
      }
   }
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong t = OrderGetTicket(i);
      if(t == 0) continue;
      activeTotal++;
      if(OrderGetString(ORDER_SYMBOL) == sym)
      {
         outReason = "Symbol already has a pending limit order (" + sym + ")";
         return false;
      }
   }
   if(activeTotal >= InpMaxOpenTrades)
   {
      outReason = StringFormat("Max concurrent trades reached (%d/%d)", activeTotal, InpMaxOpenTrades);
      return false;
   }

   // 4. Per-Symbol Cooldown Guard (prevent churning / rapid re-entries)
   if(InpCooldownMinutes > 0 && HistorySelect(TimeCurrent() - InpCooldownMinutes * 60, TimeCurrent()))
   {
      int deals = HistoryDealsTotal();
      for(int d = deals - 1; d >= 0; d--)
      {
         ulong dticket = HistoryDealGetTicket(d);
         if(dticket == 0) continue;
         if(HistoryDealGetString(dticket, DEAL_SYMBOL) == sym &&
            HistoryDealGetInteger(dticket, DEAL_MAGIC) == InpMagicNumber)
         {
            outReason = StringFormat("Symbol cooldown active (%d min between setups on %s)", InpCooldownMinutes, sym);
            return false;
         }
      }
   }

   outReason = "Approved";
   return true;
}

//+------------------------------------------------------------------+
//| Exact MT5 Native Risk-Based Lot Size Calculator                  |
//+------------------------------------------------------------------+
double CalculateRiskLot(const string sym, bool isBuy, double entry, double sl, double requestedRiskPct, double &outRiskUsd, string &outReason)
{
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(eq <= 0.0) eq = AccountInfoDouble(ACCOUNT_BALANCE);
   double slDist = MathAbs(entry - sl);
   if(slDist <= 0.0)
   {
      outReason = "Invalid Stop Loss distance (0)";
      return 0.0;
   }

   double safeRiskPct = MathMin(MathMax(requestedRiskPct, 0.25), InpMaxRiskPercent);
   double targetRiskUsd = eq * (safeRiskPct / 100.0);

   // Calculate exact loss for 1.0 lot using MT5 OrderCalcProfit
   double profitOneLot = 0.0;
   ENUM_ORDER_TYPE ordType = isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   bool calcOk = OrderCalcProfit(ordType, sym, 1.0, entry, sl, profitOneLot);
   double lossPerOneLot = MathAbs(profitOneLot);

   if(!calcOk || lossPerOneLot <= 0.0)
   {
      double tickVal  = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
      double tickSize = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
      if(tickVal > 0.0 && tickSize > 0.0)
         lossPerOneLot = (slDist / tickSize) * tickVal;
      else
         lossPerOneLot = slDist;
   }

   double minVol  = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   double maxVol  = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
   double stepVol = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   if(minVol <= 0.0) minVol = 0.01;
   if(maxVol <= 0.0) maxVol = 50.0;
   if(stepVol <= 0.0) stepVol = 0.01;

   // Check if even minimum volume exceeds Hard Max Risk Cap
   double minLotRiskUsd = minVol * lossPerOneLot;
   double minLotRiskPct = (eq > 0.0) ? (minLotRiskUsd / eq) * 100.0 : 100.0;
   if(minLotRiskPct > InpMaxRiskPercent)
   {
      outReason = StringFormat("Blocked: Min lot (%.3f) risks $%.2f (%.2f%% > %.2f%% max cap)",
                               minVol, minLotRiskUsd, minLotRiskPct, InpMaxRiskPercent);
      return 0.0;
   }

   double rawLot = targetRiskUsd / lossPerOneLot;
   double steps  = MathFloor((rawLot + 1e-7) / stepVol);
   double lot    = MathMax(minVol, steps * stepVol);
   lot = MathMin(maxVol, lot);

   int volDigits = 2;
   if(stepVol < 0.01) volDigits = 3;
   else if(stepVol >= 0.1) volDigits = 1;
   lot = NormalizeDouble(lot, volDigits);

   outRiskUsd = lot * lossPerOneLot;
   outReason  = StringFormat("Lot %.3f ($%.2f risk = %.2f%% of $%.2f)", lot, outRiskUsd, (outRiskUsd / eq) * 100.0, eq);
   return lot;
}

//+------------------------------------------------------------------+
//| Execute Verified Pure A+ Trade with Full Risk & Stops Guard      |
//+------------------------------------------------------------------+
bool ExecuteVerifiedAPlusTrade(const string cmdId, const string sym, bool isBuy, double entry, double sl, double tp, const string comment)
{
   SymbolSelect(sym, true);
   ConfigureSymbolFilling(sym);

   if(IsCounterSpikeTrade(sym, isBuy))
   {
      Print("SMC Risk Guard [", cmdId, "] BLOCKED counter-spike trade on ", sym);
      return false;
   }

   string riskReason = "";
   if(!CanOpenNewTrade(sym, comment, riskReason))
   {
      Print("SMC Risk Guard [", cmdId, "] BLOCKED on ", sym, ": ", riskReason);
      return false;
   }

   entry = NormalizePrice(sym, entry);
   sl    = NormalizePrice(sym, sl);
   tp    = NormalizePrice(sym, tp);

   double riskDist = MathAbs(entry - sl);
   double rewDist  = MathAbs(tp - entry);
   if(riskDist <= 0.0 || (rewDist / riskDist) < 1.50)
   {
      Print("SMC Risk Guard [", cmdId, "] BLOCKED on ", sym, ": R:R ", DoubleToString(rewDist / MathMax(riskDist, 1e-8), 2), " below minimum 1.50R");
      return false;
   }

   double riskUsd = 0.0;
   string sizeReason = "";
   double lot = CalculateRiskLot(sym, isBuy, entry, sl, InpRiskPercent, riskUsd, sizeReason);
   if(lot <= 0.0)
   {
      Print("SMC Risk Guard [", cmdId, "] BLOCKED sizing on ", sym, ": ", sizeReason);
      return false;
   }

   double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
   double bid = SymbolInfoDouble(sym, SYMBOL_BID);
   double point = SymbolInfoDouble(sym, SYMBOL_POINT);
   int stopsLvl = (int)SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL);
   double minStopDist = MathMax((double)stopsLvl * point, riskDist * 0.08);

   bool ok = false;
   datetime expTime = TimeCurrent() + InpPendingExpiryMin * 60;

   if(isBuy)
   {
      if(sl >= entry || tp <= entry) return false;
      // If current Ask is right inside the Order Block entry zone (within 35% of SL distance), execute Market BUY
      if(MathAbs(ask - entry) <= riskDist * 0.35 && (ask - sl) > minStopDist && (tp - ask) > minStopDist)
         ok = g_trade.Buy(lot, sym, ask, sl, tp, comment);
      else if(entry < ask - minStopDist)
         ok = g_trade.BuyLimit(lot, entry, sym, sl, tp, ORDER_TIME_SPECIFIED, expTime, comment);
      else if(entry > ask + minStopDist)
         ok = g_trade.BuyStop(lot, entry, sym, sl, tp, ORDER_TIME_SPECIFIED, expTime, comment);
      else if((ask - sl) > minStopDist && (tp - ask) > minStopDist)
         ok = g_trade.Buy(lot, sym, ask, sl, tp, comment);
   }
   else
   {
      if(sl <= entry || tp >= entry) return false;
      // If current Bid is right inside the Order Block entry zone (within 35% of SL distance), execute Market SELL
      if(MathAbs(bid - entry) <= riskDist * 0.35 && (sl - bid) > minStopDist && (bid - tp) > minStopDist)
         ok = g_trade.Sell(lot, sym, bid, sl, tp, comment);
      else if(entry > bid + minStopDist)
         ok = g_trade.SellLimit(lot, entry, sym, sl, tp, ORDER_TIME_SPECIFIED, expTime, comment);
      else if(entry < bid - minStopDist)
         ok = g_trade.SellStop(lot, entry, sym, sl, tp, ORDER_TIME_SPECIFIED, expTime, comment);
      else if((sl - bid) > minStopDist && (bid - tp) > minStopDist)
         ok = g_trade.Sell(lot, sym, bid, sl, tp, comment);
   }

   Print("SMC Pure A+ Execution [", cmdId, "] ", sym, " ", (isBuy ? "BUY" : "SELL"),
         " | ", sizeReason, " | Entry=", entry, " SL=", sl, " TP=", tp,
         " -> ", (ok ? "SUCCESS" : "FAILED (" + g_trade.ResultRetcodeDescription() + ")"));
   return ok;
}

//+------------------------------------------------------------------+
//| Auto-Breakeven at TP1 (50% EQ) & X1/X2/X3 Structural Trailing    |
//+------------------------------------------------------------------+
void ManageOpenPositionsAndTrailing()
{
   if(!InpEnableAutoExe) return;

   // 1. Clean up stale pending limit orders older than InpPendingExpiryMin
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong oticket = OrderGetTicket(i);
      if(oticket == 0) continue;
      if(OrderGetInteger(ORDER_MAGIC) != InpMagicNumber) continue;
      datetime setupT = (datetime)OrderGetInteger(ORDER_TIME_SETUP);
      if(InpPendingExpiryMin > 0 && (TimeCurrent() - setupT) > InpPendingExpiryMin * 60)
      {
         g_trade.OrderDelete(oticket);
         Print("SMC Risk Manager: Expired stale pending order #", oticket);
      }
   }

   // 2. Manage Open Positions: Auto-Breakeven at 50% EQ (TP1) + X1/X2/X3 Swing Trailing (Ch. 7 Fig 7.4)
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;

      string sym   = PositionGetString(POSITION_SYMBOL);
      long   type  = PositionGetInteger(POSITION_TYPE);
      bool   isBuy = (type == POSITION_TYPE_BUY);
      double openP = PositionGetDouble(POSITION_PRICE_OPEN);
      double curP  = PositionGetDouble(POSITION_PRICE_CURRENT);
      double curSL = PositionGetDouble(POSITION_SL);
      double curTP = PositionGetDouble(POSITION_TP);
      datetime posTime = (datetime)PositionGetInteger(POSITION_TIME);

      double point = SymbolInfoDouble(sym, SYMBOL_POINT);
      int stopsLvl = (int)SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL);
      double minDist = MathMax((double)stopsLvl * point, point * 10.0);

      double targetDist = (curTP > 0.0) ? MathAbs(curTP - openP) : 0.0;
      double currentGain = isBuy ? (curP - openP) : (openP - curP);

      double candidateSL = curSL;
      bool shouldModify = false;

      // A. Chapter 7 Breakeven Lock when price reaches 45% of TP2 distance (TP1 50% Equilibrium)
      if(targetDist > 0.0 && currentGain >= targetDist * 0.45)
      {
         double beBuffer = targetDist * 0.04;
         double bePrice  = isBuy ? NormalizePrice(sym, openP + beBuffer) : NormalizePrice(sym, openP - beBuffer);
         if(isBuy && (curSL == 0.0 || curSL < openP) && bePrice < curP - minDist)
         {
            candidateSL  = bePrice;
            shouldModify = true;
         }
         else if(!isBuy && (curSL == 0.0 || curSL > openP) && bePrice > curP + minDist)
         {
            candidateSL  = bePrice;
            shouldModify = true;
         }
      }

      // B. Chapter 7 Fig 7.4: X1 / X2 / X3 Structural Swing Trailing on M5
      MqlRates m5[];
      ArraySetAsSeries(m5, true); // index 0 = newest bar
      int copied = CopyRates(sym, PERIOD_M5, 0, 30, m5);
      if(copied >= 6)
      {
         for(int k = 2; k < copied - 2; k++)
         {
            if(m5[k].time <= posTime) break;
            if(isBuy)
            {
               // Confirmed M5 swing low in profit above openP
               bool isSwingLow = (m5[k].low < m5[k - 1].low && m5[k].low <= m5[k + 1].low && m5[k - 1].close > m5[k].high);
               if(isSwingLow && m5[k].low > openP && m5[k].low < curP - minDist)
               {
                  double swingSL = NormalizePrice(sym, m5[k].low);
                  if(curSL == 0.0 || swingSL > candidateSL + point * 5.0)
                  {
                     candidateSL  = swingSL;
                     shouldModify = true;
                  }
                  break;
               }
            }
            else
            {
               // Confirmed M5 swing high in profit below openP
               bool isSwingHigh = (m5[k].high > m5[k - 1].high && m5[k].high >= m5[k + 1].high && m5[k - 1].close < m5[k].low);
               if(isSwingHigh && m5[k].high < openP && m5[k].high > curP + minDist)
               {
                  double swingSL = NormalizePrice(sym, m5[k].high);
                  if(curSL == 0.0 || swingSL < candidateSL - point * 5.0)
                  {
                     candidateSL  = swingSL;
                     shouldModify = true;
                  }
                  break;
               }
            }
         }
      }

      if(shouldModify && MathAbs(candidateSL - curSL) > point * 3.0)
      {
         ConfigureSymbolFilling(sym);
         if(g_trade.PositionModify(ticket, candidateSL, curTP))
         {
            Print("SMC Auto-Trail (Ch. 7 X1/X2/X3 + BE): Locked SL on #", ticket, " (", sym, ") -> ", candidateSL);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Native MQL5 Autonomous Pure A+ SMC Scanner (H1 -> M5)            |
//| Enforces all 7 Frank Miller Book Rules before executing on MT5   |
//+------------------------------------------------------------------+
bool EvaluateSymbolPureAPlus(const string sym)
{
   MqlRates h1[], m5[];
   ArraySetAsSeries(h1, false);
   ArraySetAsSeries(m5, false);

   int nH1 = CopyRates(sym, PERIOD_H1, 0, 60, h1);
   int nM5 = CopyRates(sym, PERIOD_M5, 0, 140, m5);
   if(nH1 < 30 || nM5 < 60) return false;

   // Compute 14-bar ATR on H1 and M5
   double atrH1 = 0.0, atrM5 = 0.0;
   for(int k = nH1 - 14; k < nH1; k++) atrH1 += (h1[k].high - h1[k].low);
   atrH1 /= 14.0;
   for(int k = nM5 - 14; k < nM5; k++) atrM5 += (m5[k].high - m5[k].low);
   atrM5 /= 14.0;
   if(atrH1 <= 0.0 || atrM5 <= 0.0) return false;

   // Scan recent H1 impulse waves (last 6 closed H1 bars)
   for(int i = nH1 - 2; i >= nH1 - 7; i--)
   {
      double range = h1[i].high - h1[i].low;
      double body  = MathAbs(h1[i].close - h1[i].open);
      if(range <= 0.0 || (body / range) < 0.50) continue;

      bool isBullLeg = (h1[i].close > h1[i].open);
      bool isBuy     = isBullLeg; // Buy in Discount after Bullish BOS; Sell in Premium after Bearish BOS

      if(IsCounterSpikeTrade(sym, isBuy)) continue;

      // 1. Find Origin (Point A) and Swing Extreme (Point B)
      int originIdx = i - 1;
      for(int k = i; k >= MathMax(2, i - 5); k--)
      {
         if(isBullLeg && h1[k].low <= h1[originIdx].low) originIdx = k;
         if(!isBullLeg && h1[k].high >= h1[originIdx].high) originIdx = k;
      }

      // 2. Rule Ch. 1 & 2: Must break prior H1 structure with a Candlestick Body Close + Valid Pullback Sweep
      double priorSwing = isBullLeg ? -1e18 : 1e18;
      bool sweptPullback = false;
      for(int k = MathMax(2, originIdx - 6); k < originIdx; k++)
      {
         if(isBullLeg && h1[k].high > priorSwing) priorSwing = h1[k].high;
         if(!isBullLeg && h1[k].low < priorSwing) priorSwing = h1[k].low;
         // Valid non-inside-bar pullback check (Ch. 1)
         bool inside = (h1[k].high <= h1[k - 1].high && h1[k].low >= h1[k - 1].low);
         if(!inside)
         {
            if(isBullLeg && h1[k].low < h1[k - 1].low) sweptPullback = true;
            if(!isBullLeg && h1[k].high > h1[k - 1].high) sweptPullback = true;
         }
      }
      bool bosBodyConfirmed = isBullLeg ? (h1[i].close > priorSwing) : (h1[i].close < priorSwing);
      if(!bosBodyConfirmed || !sweptPullback) continue;

      // 3. Rule Ch. 4: Valid H1 Order Block at Origin (Requires BOTH Liquidity Sweep + Imbalance/FVG)
      bool obSweptPrev = isBullLeg ? (h1[originIdx].low < h1[originIdx - 1].low)
                                   : (h1[originIdx].high > h1[originIdx - 1].high);
      bool obHasFvg    = false;
      if(originIdx + 2 < nH1)
      {
         if(isBullLeg && h1[originIdx + 2].low > h1[originIdx].high) obHasFvg = true;
         if(!isBullLeg && h1[originIdx + 2].high < h1[originIdx].low) obHasFvg = true;
      }
      if(!obSweptPrev || !obHasFvg) continue;

      double obTop = h1[originIdx].high;
      double obBot = h1[originIdx].low;
      if((obTop - obBot) < 0.60 * atrH1) // Ch. 4 60% ATR Rule
      {
         double midOb = (obTop + obBot) * 0.5;
         obTop = midOb + 0.5 * atrH1;
         obBot = midOb - 0.5 * atrH1;
      }

      double pointA = isBullLeg ? h1[originIdx].low : h1[originIdx].high;
      double pointB = isBullLeg ? h1[i].high : h1[i].low;
      double eqMid  = (pointA + pointB) * 0.5; // 50% Fib Equilibrium (Ch. 3)

      // 4. Rule Ch. 3 & 5: Check M5 for Inducement (IDM) Sweep + POI Tap inside Discount (<50%) / Premium (>50%)
      datetime startT = h1[i].time + 3600;
      int m5TapIdx = -1;
      bool idmSwept = false;
      for(int m = 5; m < nM5 - 2; m++)
      {
         if(m5[m].time < startT) continue;
         if(isBuy && m5[m].low < m5[m - 1].low && m5[m].high > m5[m - 1].high) idmSwept = true;
         if(!isBuy && m5[m].high > m5[m - 1].high && m5[m].low < m5[m - 1].low) idmSwept = true;

         if(isBuy && m5[m].low <= obTop && m5[m].low <= eqMid) { m5TapIdx = m; break; }
         if(!isBuy && m5[m].high >= obBot && m5[m].high >= eqMid) { m5TapIdx = m; break; }
      }
      if(m5TapIdx < 0 || !idmSwept) continue;

      // 5. Rule Ch. 6 & 7: M5 Advanced CHoCH Body-Close Confirmation on the Just-Closed M5 Candle (nM5 - 2)
      int lastClosedM5 = nM5 - 2;
      if(lastClosedM5 <= m5TapIdx || (lastClosedM5 - m5TapIdx) > 16) continue;

      double poiExtreme = isBuy ? m5[m5TapIdx].low : m5[m5TapIdx].high;
      double minorStructure = isBuy ? -1e18 : 1e18;
      for(int m = m5TapIdx; m < lastClosedM5; m++)
      {
         if(isBuy && m5[m].low < poiExtreme) poiExtreme = m5[m].low;
         if(!isBuy && m5[m].high > poiExtreme) poiExtreme = m5[m].high;
         if(isBuy && m5[m].high > minorStructure) minorStructure = m5[m].high;
         if(!isBuy && m5[m].low < minorStructure) minorStructure = m5[m].low;
      }

      // Fresh M5 Advanced CHoCH body close on bar [lastClosedM5]
      bool freshChoch = isBuy
         ? (m5[lastClosedM5].close > minorStructure && m5[lastClosedM5 - 1].close <= minorStructure)
         : (m5[lastClosedM5].close < minorStructure && m5[lastClosedM5 - 1].close >= minorStructure);
      if(!freshChoch) continue;

      double entry = m5[lastClosedM5].close;
      // Strict Premium / Discount verification at entry (Ch. 3)
      if(isBuy && entry > eqMid) continue;
      if(!isBuy && entry < eqMid) continue;

      double sl = isBuy ? (poiExtreme - 0.20 * atrM5) : (poiExtreme + 0.20 * atrM5);
      double tp = pointB;
      double risk = MathAbs(entry - sl);
      double reward = MathAbs(tp - entry);
      if(risk <= 0.0 || (reward / risk) < InpMinRR) continue;

      string cmdId = StringFormat("APLUS_%s_%I64d", SanitizeSym(sym), (long)h1[i].time);
      if(cmdId == g_lastCmdId) return false;
      g_lastCmdId = cmdId;

      return ExecuteVerifiedAPlusTrade(cmdId, sym, isBuy, entry, sl, tp, "SMC_APLUS_AUTO");
   }
   return false;
}

//+------------------------------------------------------------------+
//| Export Live Account & Open Positions / Pending Orders State      |
//+------------------------------------------------------------------+
void ExportAccountAndOrders()
{
   double bal    = AccountInfoDouble(ACCOUNT_BALANCE);
   double eq     = AccountInfoDouble(ACCOUNT_EQUITY);
   double margin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   long   login  = AccountInfoInteger(ACCOUNT_LOGIN);
   string srv    = AccountInfoString(ACCOUNT_SERVER);

   string posJson = "[";
   bool firstPos = true;
   int totalPos = PositionsTotal();
   for(int i = 0; i < totalPos; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      string sym   = PositionGetString(POSITION_SYMBOL);
      long   type  = PositionGetInteger(POSITION_TYPE);
      double vol   = PositionGetDouble(POSITION_VOLUME);
      double openP = PositionGetDouble(POSITION_PRICE_OPEN);
      double curP  = PositionGetDouble(POSITION_PRICE_CURRENT);
      double sl    = PositionGetDouble(POSITION_SL);
      double tp    = PositionGetDouble(POSITION_TP);
      double prof  = PositionGetDouble(POSITION_PROFIT);
      long   timeO = PositionGetInteger(POSITION_TIME);
      string comm  = PositionGetString(POSITION_COMMENT);
      int    dec   = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
      if(dec < 0 || dec > 8) dec = 2;

      if(!firstPos) posJson += ",";
      firstPos = false;
      posJson += StringFormat(
         "{\"ticket\":%I64u,\"kind\":\"POSITION\",\"symbol\":\"%s\",\"side\":\"%s\",\"lot\":%.3f,\"entry\":%.*f,\"current\":%.*f,\"sl\":%.*f,\"tp\":%.*f,\"profit\":%.2f,\"time\":%I64d,\"comment\":\"%s\"}",
         ticket, sym, (type == POSITION_TYPE_BUY ? "BUY" : "SELL"),
         vol, dec, openP, dec, curP, dec, sl, dec, tp, prof, timeO, comm
      );
   }

   int totalOrd = OrdersTotal();
   for(int i = 0; i < totalOrd; i++)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0) continue;
      string sym   = OrderGetString(ORDER_SYMBOL);
      long   type  = OrderGetInteger(ORDER_TYPE);
      double vol   = OrderGetDouble(ORDER_VOLUME_CURRENT);
      double openP = OrderGetDouble(ORDER_PRICE_OPEN);
      double curP  = OrderGetDouble(ORDER_PRICE_CURRENT);
      double sl    = OrderGetDouble(ORDER_SL);
      double tp    = OrderGetDouble(ORDER_TP);
      long   timeO = OrderGetInteger(ORDER_TIME_SETUP);
      string comm  = OrderGetString(ORDER_COMMENT);
      int    dec   = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
      if(dec < 0 || dec > 8) dec = 2;

      string sideStr = (type == ORDER_TYPE_BUY_LIMIT || type == ORDER_TYPE_BUY_STOP || type == ORDER_TYPE_BUY) ? "BUY_LIMIT" : "SELL_LIMIT";

      if(!firstPos) posJson += ",";
      firstPos = false;
      posJson += StringFormat(
         "{\"ticket\":%I64u,\"kind\":\"PENDING\",\"symbol\":\"%s\",\"side\":\"%s\",\"lot\":%.3f,\"entry\":%.*f,\"current\":%.*f,\"sl\":%.*f,\"tp\":%.*f,\"profit\":0.00,\"time\":%I64d,\"comment\":\"%s\"}",
         ticket, sym, sideStr,
         vol, dec, openP, dec, curP, dec, sl, dec, tp, timeO, comm
      );
   }
   posJson += "]";

   string stateJson = StringFormat(
      "{\"login\":%I64d,\"server\":\"%s\",\"balance\":%.2f,\"equity\":%.2f,\"freeMargin\":%.2f,\"updated\":%I64d,\"orders\":%s}",
      login, srv, bal, eq, margin, (long)TimeCurrent(), posJson
   );

   int fh = FileOpen("smc_bridge\\account_state.json", FILE_WRITE | FILE_TXT | FILE_COMMON | FILE_SHARE_READ);
   if(fh != INVALID_HANDLE)
   {
      FileWriteString(fh, stateJson);
      FileClose(fh);
   }
}

//+------------------------------------------------------------------+
//| Execute Incoming Web Terminal Pure A+ & Trailing Commands        |
//+------------------------------------------------------------------+
void ProcessCommandQueue()
{
   if(!InpEnableAutoExe) return;

   string cmdPath = "smc_bridge\\commands_queue.txt";
   if(!FileIsExist(cmdPath, FILE_COMMON)) return;

   int fh = FileOpen(cmdPath, FILE_READ | FILE_TXT | FILE_COMMON | FILE_SHARE_READ | FILE_SHARE_WRITE);
   if(fh == INVALID_HANDLE) return;

   string lines[];
   int count = 0;
   while(!FileIsEnding(fh))
   {
      string line = FileReadString(fh);
      StringTrimLeft(line);
      StringTrimRight(line);
      if(StringLen(line) > 3)
      {
         ArrayResize(lines, count + 1);
         lines[count] = line;
         count++;
      }
   }
   FileClose(fh);
   FileDelete(cmdPath, FILE_COMMON);

   for(int i = 0; i < count; i++)
   {
      string parts[];
      int p = StringSplit(lines[i], '|', parts);
      if(p < 2) continue;

      string cmdId  = parts[0];
      string action = parts[1];
      if(cmdId == g_lastCmdId) continue;
      g_lastCmdId = cmdId;

      if(action == "PLACE_LIMIT" && p >= 8)
      {
         string sym     = parts[2];
         string side    = parts[3];
         double entry   = StringToDouble(parts[5]);
         double sl      = StringToDouble(parts[6]);
         double tp      = StringToDouble(parts[7]);
         string comment = (p >= 10) ? parts[9] : "SMC_APLUS";
         bool   isBuy   = (side == "BUY" || side == "BUY_LIMIT");

         ExecuteVerifiedAPlusTrade(cmdId, sym, isBuy, entry, sl, tp, comment);
      }
      else if(action == "MODIFY_SLTP" && p >= 9)
      {
         string sym    = parts[2];
         double newSl  = StringToDouble(parts[6]);
         double newTp  = StringToDouble(parts[7]);
         ulong  ticket = (ulong)StringToInteger(parts[8]);
         newSl = NormalizePrice(sym, newSl);
         newTp = NormalizePrice(sym, newTp);

         if(PositionSelectByTicket(ticket))
         {
            ConfigureSymbolFilling(sym);
            double curTp = (newTp > 0) ? newTp : PositionGetDouble(POSITION_TP);
            bool ok = g_trade.PositionModify(ticket, newSl, curTp);
            Print("SMC_Auto_Bridge [", cmdId, "] TRAIL SL (X1/X2/X3) Ticket#", ticket,
                  " NewSL=", newSl, " -> ", (ok ? "SUCCESS" : "FAILED"));
         }
      }
      else if(action == "CLOSE" && p >= 9)
      {
         ulong ticket = (ulong)StringToInteger(parts[8]);
         if(PositionSelectByTicket(ticket))
            g_trade.PositionClose(ticket);
         else if(OrderSelect(ticket))
            g_trade.OrderDelete(ticket);
      }
   }
}

//+------------------------------------------------------------------+
//| Main Timer: Process Commands, Manage Trailing & Stream OHLCV     |
//+------------------------------------------------------------------+
void OnTimer()
{
   ProcessCommandQueue();
   ManageOpenPositionsAndTrailing();
   ExportAccountAndOrders();

   string syms[];
   int n = StringSplit(InpSymbols, ',', syms);
   if(n <= 0)
   {
      ArrayResize(syms, 1);
      syms[0] = _Symbol;
      n = 1;
   }

   int mwTotal = SymbolsTotal(true);
   for(int m = 0; m < mwTotal; m++)
   {
      string mws = SymbolName(m, true);
      if(StringLen(mws) > 0)
      {
         bool exists = false;
         for(int s = 0; s < n; s++)
         {
            if(syms[s] == mws) { exists = true; break; }
         }
         if(!exists)
         {
            ArrayResize(syms, n + 1);
            syms[n] = mws;
            n++;
         }
      }
   }

   ENUM_TIMEFRAMES tfs[6] = {PERIOD_M1, PERIOD_M5, PERIOD_M15, PERIOD_H1, PERIOD_H4, PERIOD_D1};
   int tfSec[6]           = {60, 300, 900, 3600, 14400, 86400};

   int count = InpFullBars;
   int exportedCount = 0;
   bool runAPlusScanNow = (InpEnableAutoExe && InpNativeAPlusScan && (TimeCurrent() - g_lastAPlusScan >= 15));
   if(runAPlusScanNow) g_lastAPlusScan = TimeCurrent();

   for(int s = 0; s < n; s++)
   {
      string sym = syms[s];
      StringTrimLeft(sym);
      StringTrimRight(sym);
      if(StringLen(sym) == 0) continue;

      if(!SymbolInfoInteger(sym, SYMBOL_SELECT))
         SymbolSelect(sym, true);

      double bid = SymbolInfoDouble(sym, SYMBOL_BID);
      if(bid <= 0 && !SymbolInfoInteger(sym, SYMBOL_VISIBLE))
         continue;

      if(runAPlusScanNow)
         EvaluateSymbolPureAPlus(sym);

      for(int t = 0; t < 6; t++)
      {
         MqlRates rates[];
         ArraySetAsSeries(rates, false);
         int copied = CopyRates(sym, tfs[t], 0, count, rates);
         if(copied <= 0) continue;

         int dec = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
         if(dec < 0 || dec > 8) dec = 2;
         string fmt = "%I64d,%." + IntegerToString(dec) + "f,%." + IntegerToString(dec) + "f,%." + IntegerToString(dec) + "f,%." + IntegerToString(dec) + "f";

         string json = "[";
         for(int i = 0; i < copied; i++)
         {
            if(i > 0) json += ",";
            json += "[" + StringFormat(fmt,
               (long)rates[i].time,
               rates[i].open,
               rates[i].high,
               rates[i].low,
               rates[i].close) + "]";
         }
         json += "]";

         string safeSym = SanitizeSym(sym);
         string filePath = "smc_bridge\\" + safeSym + "_" + IntegerToString(tfSec[t]) + ".json";
         int fileHandle = FileOpen(filePath, FILE_WRITE | FILE_TXT | FILE_COMMON | FILE_SHARE_READ);
         if(fileHandle != INVALID_HANDLE)
         {
            FileWriteString(fileHandle, json);
            FileClose(fileHandle);
            exportedCount++;
         }
      }
   }

   if(TimeCurrent() - g_lastLog > 30)
   {
      g_lastLog = TimeCurrent();
      Print("SMC_Auto_Bridge v4.00 (Pure A+ & Risk Guard): Synced ", n, " symbols (", exportedCount, " series). Account #", AccountInfoInteger(ACCOUNT_LOGIN));
   }
}
//+------------------------------------------------------------------+
