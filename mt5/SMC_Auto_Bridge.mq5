//+------------------------------------------------------------------+
//|                                              SMC_Auto_Bridge.mq5 |
//|     Frank Miller Smart Money Concepts (SMC) Live MT5 Auto-Bridge |
//|   Pure A+ Autonomous Execution & Institutional Risk Manager v4.2 |
//+------------------------------------------------------------------+
#property copyright "SMC Desk — Frank Miller Smart Money Concepts"
#property version   "4.20"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\OrderInfo.mqh>
#include <Trade\PositionInfo.mqh>

input string InpServerUrl         = "http://localhost:8095"; // Local SMC Desk Server URL
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

// Full Broker Symbol Arrays (immune to MQL5 255-char input string truncation)
string DERIV_SYMS[] = {
   "Volatility 15 (1s) Index", "Volatility 75 (1s) Index", "Volatility 75 Index",
   "Volatility 10 (1s) Index", "Volatility 25 (1s) Index", "Volatility 50 (1s) Index",
   "Volatility 100 (1s) Index", "Volatility 10 Index", "Volatility 25 Index",
   "Volatility 50 Index", "Volatility 100 Index", "Boom 1000 Index",
   "Crash 1000 Index", "Boom 500 Index", "Crash 500 Index",
   "Boom 300 Index", "Crash 300 Index", "Step Index",
   "Jump 10 Index", "Jump 25 Index", "Jump 50 Index",
   "Jump 75 Index", "Jump 100 Index", "Range Break 100 Index",
   "Range Break 200 Index", "DEX 600 UP Index", "DEX 600 DOWN Index",
   "DEX 900 UP Index", "DEX 900 DOWN Index", "EURUSD",
   "GBPUSD", "USDJPY", "XAUUSD"
};

string WELTRADE_SYMS[] = {
   "FX Vol 20", "FX Vol 40", "FX Vol 60", "FX Vol 80", "FX Vol 99",
   "SFX Vol 20", "SFX Vol 40", "SFX Vol 60", "SFX Vol 80", "SFX Vol 99",
   "PainX 400", "GainX 400", "PainX 600", "GainX 600", "PainX 800",
   "GainX 800", "PainX 999", "GainX 999", "PainX 1200", "GainX 1200",
   "FlipX 1", "FlipX 2", "FlipX 3", "FlipX 4", "FlipX 5",
   "SwitchX 600", "SwitchX 1200", "SwitchX 1800",
   "BreakX 600", "BreakX 1200", "BreakX 1800",
   "MAX PainX 1000", "MAX GainX 1000", "MAX PainX 2000", "MAX GainX 2000"
};

CTrade        g_trade;
COrderInfo    g_order;
CPositionInfo g_pos;

datetime g_lastLog        = 0;
string   g_lastCmdId      = "";
double   g_dayStartEquity = 0.0;
int      g_currentDay     = -1;
int      g_rrCursor       = 0;
string   g_brokerSyms[];
int      g_brokerSymCount = 0;

//+------------------------------------------------------------------+
//| Detect whether this MT5 instance is connected to Weltrade        |
//+------------------------------------------------------------------+
bool IsWeltradeBroker()
{
   string srv = AccountInfoString(ACCOUNT_SERVER);
   string cmp = AccountInfoString(ACCOUNT_COMPANY);
   StringToUpper(srv);
   StringToUpper(cmp);
   if(StringFind(srv, "WELTRADE") >= 0 || StringFind(cmp, "WELTRADE") >= 0 || AccountInfoInteger(ACCOUNT_LOGIN) == 43374418)
      return true;
   return false;
}

//+------------------------------------------------------------------+
//| Build Validated Symbol List for Current Broker                   |
//+------------------------------------------------------------------+
void InitBrokerSymbols()
{
   bool isWt = IsWeltradeBroker();
   int n = isWt ? ArraySize(WELTRADE_SYMS) : ArraySize(DERIV_SYMS);
   ArrayResize(g_brokerSyms, 0);
   g_brokerSymCount = 0;

   for(int i = 0; i < n; i++)
   {
      string s = isWt ? WELTRADE_SYMS[i] : DERIV_SYMS[i];
      StringTrimLeft(s);
      StringTrimRight(s);
      if(StringLen(s) == 0) continue;

      if(SymbolSelect(s, true))
      {
         ArrayResize(g_brokerSyms, g_brokerSymCount + 1);
         g_brokerSyms[g_brokerSymCount] = s;
         g_brokerSymCount++;
      }
   }

   // Export clean catalog file immediately
   string catJson = "[";
   for(int i = 0; i < g_brokerSymCount; i++)
   {
      if(i > 0) catJson += ",";
      catJson += "\"" + g_brokerSyms[i] + "\"";
   }
   catJson += "]";
   string catFile = IsWeltradeBroker() ? "smc_bridge\\catalog_weltrade.json" : "smc_bridge\\catalog_deriv.json";
   int fhCat = FileOpen(catFile, FILE_WRITE | FILE_TXT | FILE_COMMON | FILE_SHARE_READ);
   if(fhCat != INVALID_HANDLE)
   {
      FileWriteString(fhCat, catJson);
      FileClose(fhCat);
   }
}

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

   InitBrokerSymbols();
   EventSetTimer(1); // 1-second real-time tick & active chart sync

   Print("=================================================================");
   Print("SMC_Auto_Bridge v4.20 (REAL-TIME 1S SYNC + PURE A+ RISK GUARD) initialized");
   Print("Account #", AccountInfoInteger(ACCOUNT_LOGIN), " (", AccountInfoString(ACCOUNT_SERVER), ") | Symbols=", g_brokerSymCount);
   Print("Balance: $", DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2),
         " | Equity: $", DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2));
   Print("=================================================================");
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   Print("SMC_Auto_Bridge v4.20 stopped.");
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
   if((StringFind(up, "BOOM") >= 0 || StringFind(up, "GAINX") >= 0) && !isBuy)
      return true;
   if((StringFind(up, "CRASH") >= 0 || StringFind(up, "PAINX") >= 0) && isBuy)
      return true;
   return false;
}

//+------------------------------------------------------------------+
//| Institutional Portfolio & Symbol Risk Guard                      |
//+------------------------------------------------------------------+
bool CanOpenNewTrade(const string sym, const string comment, string &outReason)
{
   if(StringFind(comment, "APLUS") < 0 && StringFind(comment, "A+") < 0)
   {
      outReason = "Regular Trade Blocked (Requires Pure A+ 7/7 Confluence)";
      return false;
   }

   MqlDateTime dt;
   TimeCurrent(dt);
   if(dt.day_of_year != g_currentDay)
   {
      g_currentDay = dt.day_of_year;
      g_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   }
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double refCap = MathMax(g_dayStartEquity, balance);
   if(refCap > 0.0)
   {
      double ddPct = ((refCap - equity) / refCap) * 100.0;
      if(ddPct >= InpMaxDailyLossPct)
      {
         outReason = StringFormat("Daily Drawdown Breaker Active (%.2f%% >= %.2f%%)", ddPct, InpMaxDailyLossPct);
         return false;
      }
   }

   int openCount = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      string pSym = PositionGetString(POSITION_SYMBOL);
      if(pSym == sym)
      {
         outReason = "Position already open on " + sym;
         return false;
      }
      openCount++;
   }

   for(int j = OrdersTotal() - 1; j >= 0; j--)
   {
      ulong ot = OrderGetTicket(j);
      if(ot == 0) continue;
      string oSym = OrderGetString(ORDER_SYMBOL);
      if(oSym == sym)
      {
         outReason = "Pending order already working on " + sym;
         return false;
      }
      openCount++;
   }

   if(openCount >= InpMaxOpenTrades)
   {
      outReason = StringFormat("Max Open Trades Reached (%d/%d)", openCount, InpMaxOpenTrades);
      return false;
   }

   if(HistorySelect(TimeCurrent() - InpCooldownMinutes * 60, TimeCurrent()))
   {
      int deals = HistoryDealsTotal();
      for(int d = deals - 1; d >= 0; d--)
      {
         ulong dticket = HistoryDealGetTicket(d);
         if(dticket == 0) continue;
         if(HistoryDealGetString(dticket, DEAL_SYMBOL) == sym &&
            HistoryDealGetInteger(dticket, DEAL_MAGIC) == InpMagicNumber &&
            HistoryDealGetInteger(dticket, DEAL_ENTRY) == DEAL_ENTRY_IN)
         {
            outReason = StringFormat("Cooldown active on %s (%d min)", sym, InpCooldownMinutes);
            return false;
         }
      }
   }

   outReason = "OK";
   return true;
}

//+------------------------------------------------------------------+
//| Exact Risk-Managed Lot Size Calculation Using OrderCalcProfit    |
//+------------------------------------------------------------------+
double CalculateRiskLot(const string sym, bool isBuy, double entryPrice, double slPrice, double &outRiskUsd)
{
   outRiskUsd = 0.0;
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity <= 0.0) equity = AccountInfoDouble(ACCOUNT_BALANCE);
   if(equity <= 0.0) return 0.0;

   double riskPct = MathMin(MathMax(InpRiskPercent, 0.10), InpMaxRiskPercent);
   double targetRiskUsd = equity * (riskPct / 100.0);

   double volMin  = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   double volMax  = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
   double volStep = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   if(volMin <= 0.0)  volMin = 0.01;
   if(volMax <= 0.0)  volMax = 100.0;
   if(volStep <= 0.0) volStep = 0.01;

   double slDist = MathAbs(entryPrice - slPrice);
   if(slDist <= 0.0) return 0.0;

   double lossForOneLot = 0.0;
   ENUM_ORDER_TYPE calcType = isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   if(OrderCalcProfit(calcType, sym, 1.0, entryPrice, slPrice, lossForOneLot))
      lossForOneLot = MathAbs(lossForOneLot);

   if(lossForOneLot <= 0.0)
   {
      double tickVal  = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
      double tickSize = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
      double contract = SymbolInfoDouble(sym, SYMBOL_TRADE_CONTRACT_SIZE);
      if(tickVal > 0.0 && tickSize > 0.0)
         lossForOneLot = (slDist / tickSize) * tickVal;
      else if(contract > 0.0)
         lossForOneLot = slDist * contract;
      else
         lossForOneLot = slDist;
   }

   if(lossForOneLot <= 0.0) return 0.0;

   double rawLots = targetRiskUsd / lossForOneLot;
   double snappedLots = MathFloor(rawLots / volStep) * volStep;
   if(snappedLots < volMin)
   {
      double minLotLoss = lossForOneLot * volMin;
      double minLotRiskPct = (minLotLoss / equity) * 100.0;
      if(minLotRiskPct > InpMaxRiskPercent)
      {
         Print("SMC_Auto_Bridge [RISK GUARD] Blocked ", sym, ": Min lot (", volMin,
               ") risks $", DoubleToString(minLotLoss, 2), " (", DoubleToString(minLotRiskPct, 2),
               "% > Max ", DoubleToString(InpMaxRiskPercent, 2), "%)");
         return 0.0;
      }
      snappedLots = volMin;
   }
   if(snappedLots > volMax) snappedLots = volMax;

   int lotDigits = 2;
   if(volStep >= 1.0) lotDigits = 0;
   else if(volStep >= 0.1) lotDigits = 1;
   else if(volStep >= 0.01) lotDigits = 2;
   else lotDigits = 3;

   snappedLots = NormalizeDouble(snappedLots, lotDigits);
   outRiskUsd  = snappedLots * lossForOneLot;
   return snappedLots;
}

//+------------------------------------------------------------------+
//| Execute Verified Pure A+ Trade with Full Risk & Stops Validation |
//+------------------------------------------------------------------+
bool ExecuteVerifiedAPlusTrade(const string cmdId, const string sym, bool isBuy,
                               double entry, double sl, double tp, const string comment)
{
   if(!SymbolInfoInteger(sym, SYMBOL_SELECT))
      SymbolSelect(sym, true);

   string blockReason = "";
   if(!CanOpenNewTrade(sym, comment, blockReason))
   {
      Print("SMC_Auto_Bridge [", cmdId, "] SKIPPED ", sym, ": ", blockReason);
      return false;
   }

   if(IsCounterSpikeTrade(sym, isBuy))
   {
      Print("SMC_Auto_Bridge [", cmdId, "] BLOCKED counter-spike trade on ", sym);
      return false;
   }

   entry = NormalizePrice(sym, entry);
   sl    = NormalizePrice(sym, sl);
   tp    = NormalizePrice(sym, tp);

   double riskDist   = MathAbs(entry - sl);
   double rewardDist = MathAbs(tp - entry);
   if(riskDist <= 0.0 || rewardDist <= 0.0) return false;

   double rr = rewardDist / riskDist;
   if(rr < InpMinRR - 0.05)
   {
      Print("SMC_Auto_Bridge [", cmdId, "] BLOCKED ", sym, ": R:R ", DoubleToString(rr, 2),
            " < Minimum Required 1:", DoubleToString(InpMinRR, 2));
      return false;
   }

   double actualRiskUsd = 0.0;
   double lots = CalculateRiskLot(sym, isBuy, entry, sl, actualRiskUsd);
   if(lots <= 0.0) return false;

   ConfigureSymbolFilling(sym);

   double ask   = SymbolInfoDouble(sym, SYMBOL_ASK);
   double bid   = SymbolInfoDouble(sym, SYMBOL_BID);
   double point = SymbolInfoDouble(sym, SYMBOL_POINT);
   int stopsLvl = (int)SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL);
   double minStopDist = MathMax((double)stopsLvl * point, point * 10.0);

   bool ok = false;
   string execMode = "";

   if(isBuy)
   {
      if(MathAbs(ask - entry) <= riskDist * 0.35 || entry >= ask - minStopDist)
      {
         double mktSl = (sl < ask - minStopDist) ? sl : NormalizePrice(sym, ask - MathMax(riskDist, minStopDist * 1.5));
         double mktTp = (tp > ask + minStopDist) ? tp : NormalizePrice(sym, ask + MathMax(rewardDist, minStopDist * 3.0));
         execMode = "MARKET_BUY_APLUS";
         ok = g_trade.Buy(lots, sym, 0.0, mktSl, mktTp, comment);
      }
      else
      {
         execMode = "BUY_LIMIT_APLUS";
         ok = g_trade.BuyLimit(lots, entry, sym, sl, tp, ORDER_TIME_GTC, 0, comment);
      }
   }
   else
   {
      if(MathAbs( entry - bid ) <= riskDist * 0.35 || entry <= bid + minStopDist)
      {
         double mktSl = (sl > bid + minStopDist) ? sl : NormalizePrice(sym, bid + MathMax(riskDist, minStopDist * 1.5));
         double mktTp = (tp < bid - minStopDist) ? tp : NormalizePrice(sym, bid - MathMax(rewardDist, minStopDist * 3.0));
         execMode = "MARKET_SELL_APLUS";
         ok = g_trade.Sell(lots, sym, 0.0, mktSl, mktTp, comment);
      }
      else
      {
         execMode = "SELL_LIMIT_APLUS";
         ok = g_trade.SellLimit(lots, entry, sym, sl, tp, ORDER_TIME_GTC, 0, comment);
      }
   }

   Print("SMC_Auto_Bridge [", cmdId, "] ", execMode, " ", sym,
         " Lot=", lots, " (Risk=$", DoubleToString(actualRiskUsd, 2), ", RR=1:", DoubleToString(rr, 2), ")",
         " Entry=", entry, " SL=", sl, " TP=", tp,
         " -> ", (ok ? "EXECUTED" : "FAILED (" + IntegerToString(GetLastError()) + " / " + g_trade.ResultRetcodeDescription() + ")"));
   return ok;
}

//+------------------------------------------------------------------+
//| Manage Open Positions: Auto-Breakeven @ 1.5R + M5 Swing Trailing |
//+------------------------------------------------------------------+
void ManageOpenPositionsAndTrailing()
{
   if(!InpEnableAutoExe) return;

   for(int j = OrdersTotal() - 1; j >= 0; j--)
   {
      ulong ot = OrderGetTicket(j);
      if(ot == 0) continue;
      long setupTime = OrderGetInteger(ORDER_TIME_SETUP);
      string oComm   = OrderGetString(ORDER_COMMENT);
      if((StringFind(oComm, "SMC_") >= 0 || OrderGetInteger(ORDER_MAGIC) == InpMagicNumber) &&
         (TimeCurrent() - setupTime > InpPendingExpiryMin * 60))
      {
         g_trade.OrderDelete(ot);
         Print("SMC_Auto_Bridge: Expired stale pending order #", ot, " on ", OrderGetString(ORDER_SYMBOL));
      }
   }

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;

      string sym   = PositionGetString(POSITION_SYMBOL);
      long   type  = PositionGetInteger(POSITION_TYPE);
      double openP = PositionGetDouble(POSITION_PRICE_OPEN);
      double curP  = PositionGetDouble(POSITION_PRICE_CURRENT);
      double curSl = PositionGetDouble(POSITION_SL);
      double curTp = PositionGetDouble(POSITION_TP);
      bool   isBuy = (type == POSITION_TYPE_BUY);

      double point    = SymbolInfoDouble(sym, SYMBOL_POINT);
      int    stopsLvl = (int)SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL);
      double minDist  = MathMax((double)stopsLvl * point, point * 10.0);

      double targetDist = MathAbs(curTp - openP);
      double initRisk   = (curSl > 0.0 && ((isBuy && curSl < openP) || (!isBuy && curSl > openP)))
                          ? MathAbs(openP - curSl)
                          : (targetDist > 0.0 ? targetDist / 3.0 : 0.0);
      if(initRisk <= 0.0) continue;

      double profitDist = isBuy ? (curP - openP) : (openP - curP);
      double currentR   = profitDist / initRisk;

      double candidateSl = curSl;

      if(currentR >= 1.35)
      {
         double bePlus = isBuy ? (openP + initRisk * 0.15) : (openP - initRisk * 0.15);
         if(isBuy && (curSl == 0.0 || bePlus > candidateSl + point))
            candidateSl = bePlus;
         else if(!isBuy && (curSl == 0.0 || bePlus < candidateSl - point))
            candidateSl = bePlus;
      }

      if(currentR >= 1.50 && Bars(sym, PERIOD_M5) > 25)
      {
         MqlRates m5[];
         ArraySetAsSeries(m5, true);
         int copied = CopyRates(sym, PERIOD_M5, 0, 20, m5);
         if(copied >= 10)
         {
            for(int k = 2; k <= copied - 3; k++)
            {
               if(isBuy)
               {
                  bool isSwingLow = (m5[k].low < m5[k-1].low && m5[k].low <= m5[k+1].low);
                  if(isSwingLow && m5[k].low > openP && m5[k].low < curP - minDist)
                  {
                     if(m5[k].low > candidateSl + point * 2)
                        candidateSl = m5[k].low;
                     break;
                  }
               }
               else
               {
                  bool isSwingHigh = (m5[k].high > m5[k-1].high && m5[k].high >= m5[k+1].high);
                  if(isSwingHigh && m5[k].high < openP && m5[k].high > curP + minDist)
                  {
                     if(curSl == 0.0 || m5[k].high < candidateSl - point * 2)
                        candidateSl = m5[k].high;
                     break;
                  }
               }
            }
         }
      }

      candidateSl = NormalizePrice(sym, candidateSl);
      bool shouldModify = false;
      if(isBuy && candidateSl > curSl + point * 2 && candidateSl < curP - minDist)
         shouldModify = true;
      if(!isBuy && (curSl == 0.0 || candidateSl < curSl - point * 2) && candidateSl > curP + minDist)
         shouldModify = true;

      if(shouldModify)
      {
         ConfigureSymbolFilling(sym);
         if(g_trade.PositionModify(ticket, candidateSl, curTp))
            Print("SMC_Auto_Bridge [X1-X3 TRAIL] Ticket #", ticket, " (", sym, ") SL trailed: ", curSl, " -> ", candidateSl);
      }
   }
}

//+------------------------------------------------------------------+
//| Evaluate Pure A+ 7/7 Confluence on a Specific HTF->LTF Pair      |
//+------------------------------------------------------------------+
bool EvaluateTimeframePairPureAPlus(const string sym, ENUM_TIMEFRAMES tfH, ENUM_TIMEFRAMES tfL, const string pairTag)
{
   if(Bars(sym, tfH) < 80 || Bars(sym, tfL) < 120) return false;

   MqlRates htf[], ltf[];
   ArraySetAsSeries(htf, false);
   ArraySetAsSeries(ltf, false);

   int cH = CopyRates(sym, tfH, 0, 80, htf);
   int cL = CopyRates(sym, tfL, 0, 120, ltf);
   if(cH < 50 || cL < 60) return false;

   double htfAtr = 0.0;
   for(int i = cH - 15; i < cH - 1; i++)
      htfAtr += (htf[i].high - htf[i].low);
   htfAtr /= 14.0;
   if(htfAtr <= 0.0) return false;

   double ltfAtr = 0.0;
   for(int i = cL - 15; i < cL - 1; i++)
      ltfAtr += (ltf[i].high - ltf[i].low);
   ltfAtr /= 14.0;
   if(ltfAtr <= 0.0) ltfAtr = htfAtr * 0.25;

   double curPrice = ltf[cL - 1].close;

   // Scan recent HTF impulse waves (last 18 HTF bars)
   for(int impIdx = cH - 2; impIdx >= cH - 16; impIdx--)
   {
      if(impIdx < 8) break;
      double body = MathAbs(htf[impIdx].close - htf[impIdx].open);
      double rng  = MathMax(htf[impIdx].high - htf[impIdx].low, 1e-8);
      if(body / rng < 0.42) continue;

      bool isBull = (htf[impIdx].close >= htf[impIdx].open);
      int origIdx = impIdx - 1;
      for(int k = impIdx; k >= MathMax(2, impIdx - 6); k--)
      {
         if(isBull  && htf[k].low  <= htf[origIdx].low)  origIdx = k;
         if(!isBull && htf[k].high >= htf[origIdx].high) origIdx = k;
      }

      double pointA = isBull ? htf[origIdx].low : htf[origIdx].high;
      double pointB = isBull ? MathMax(htf[impIdx].high, htf[MathMin(cH - 1, impIdx + 1)].high)
                             : MathMin(htf[impIdx].low,  htf[MathMin(cH - 1, impIdx + 1)].low);
      double legRange = MathAbs(pointB - pointA);
      if(legRange < htfAtr * 1.4) continue;

      // 1. Check HTF BOS/CHoCH body close beyond prior structure + prior pullback sweep
      double priorSwing = isBull ? -1e18 : 1e18;
      bool sweptPrior = false;
      for(int k = MathMax(1, origIdx - 8); k < origIdx; k++)
      {
         if(isBull  && htf[k].high > priorSwing) priorSwing = htf[k].high;
         if(!isBull && htf[k].low  < priorSwing) priorSwing = htf[k].low;
         if(isBull  && htf[k].low  < htf[k - 1].low)   sweptPrior = true;
         if(!isBull && htf[k].high > htf[k - 1].high)  sweptPrior = true;
      }
      bool brokeBos = isBull ? (htf[impIdx].close > priorSwing) : (htf[impIdx].close < priorSwing);
      if(!brokeBos || !sweptPrior) continue;

      // 2. Check Premium (>50%) / Discount (<50%) Equilibrium
      double eq50 = (pointA + pointB) * 0.5;
      if(isBull  && curPrice >= eq50) continue;
      if(!isBull && curPrice <= eq50) continue;
      if(IsCounterSpikeTrade(sym, isBull)) continue;

      // 3. Check Valid HTF Order Block (Sweep + FVG + 60% ATR Rule)
      bool obSwept = isBull
         ? (htf[origIdx].low <= htf[origIdx - 1].low || htf[origIdx].low <= htf[origIdx - 2].low)
         : (htf[origIdx].high >= htf[origIdx - 1].high || htf[origIdx].high >= htf[origIdx - 2].high);
      bool obFvg = false;
      for(int off = 0; off <= 2 && (origIdx + off + 2) < cH; off++)
      {
         if(isBull  && htf[origIdx + off + 2].low  > htf[origIdx + off].high) { obFvg = true; break; }
         if(!isBull && htf[origIdx + off + 2].high < htf[origIdx + off].low)  { obFvg = true; break; }
      }
      if(!obSwept || !obFvg) continue;

      double obTop = htf[origIdx].high;
      double obBot = htf[origIdx].low;
      if((obTop - obBot) < htfAtr * 0.60)
      {
         double midOb = (obTop + obBot) * 0.5;
         obTop = midOb + htfAtr * 0.50;
         obBot = midOb - htfAtr * 0.50;
      }
      // Allow Discount/Premium Fib 50-79% OTE + OB confluence zone
      double poiTop = isBull ? MathMax(obTop, pointA + legRange * 0.38) : obTop;
      double poiBot = isBull ? obBot : MathMin(obBot, pointA - legRange * 0.38);

      // 4. Check LTF POI Mitigation + Inducement Sweep + LTF Advanced CHoCH in last 14 LTF bars
      int tapIdx = -1;
      double poiExtreme = isBull ? 1e18 : -1e18;
      int extremeIdx = -1;
      int ltfPullbacks = 0;

      for(int m = cL - 14; m < cL; m++)
      {
         if(m < 2) continue;
         if(isBull  && ltf[m].high > ltf[m - 1].high) ltfPullbacks++;
         if(!isBull && ltf[m].low  < ltf[m - 1].low)  ltfPullbacks++;

         bool inPoi = isBull
            ? (ltf[m].low <= poiTop && ltf[m].close >= pointA - htfAtr * 0.25)
            : (ltf[m].high >= poiBot && ltf[m].close <= pointA + htfAtr * 0.25);
         if(inPoi && tapIdx < 0) tapIdx = m;

         if(tapIdx >= 0)
         {
            if(isBull  && ltf[m].low  < poiExtreme) { poiExtreme = ltf[m].low;  extremeIdx = m; }
            if(!isBull && ltf[m].high > poiExtreme) { poiExtreme = ltf[m].high; extremeIdx = m; }
         }
      }
      if(tapIdx < 0 || extremeIdx < 0 || ltfPullbacks < 1) continue;

      // 5. Find minor LTF swing prior to extremeIdx and check if recent LTF candle closed beyond it (Adv CHoCH)
      double minorSwing = isBull ? -1e18 : 1e18;
      for(int m = MathMax(1, extremeIdx - 5); m <= extremeIdx; m++)
      {
         if(isBull  && ltf[m].high > minorSwing) minorSwing = ltf[m].high;
         if(!isBull && ltf[m].low  < minorSwing) minorSwing = ltf[m].low;
      }

      bool chochRecent = false;
      for(int m = MathMax(extremeIdx + 1, cL - 4); m < cL; m++)
      {
         if(isBull  && ltf[m].close > minorSwing && ltf[m].close > ltf[m].open) { chochRecent = true; break; }
         if(!isBull && ltf[m].close < minorSwing && ltf[m].close < ltf[m].open) { chochRecent = true; break; }
      }
      if(!chochRecent) continue;

      // 6. Compute Entry, Stop Loss, TP1 (50% EQ), TP2 (External Point B) & Verify R:R
      double sl = isBull ? (poiExtreme - ltfAtr * 0.20) : (poiExtreme + ltfAtr * 0.20);
      double risk = MathAbs(curPrice - sl);
      if(risk <= ltfAtr * 0.15) risk = ltfAtr * 0.35;

      double rawTp1 = eq50;
      double rawTp2 = pointB;
      double tp1 = (isBull ? (rawTp1 > curPrice + risk * 1.50) : (rawTp1 < curPrice - risk * 1.50))
                   ? rawTp1
                   : (isBull ? (curPrice + risk * 2.0) : (curPrice - risk * 2.0));
      double tp2 = (isBull ? (rawTp2 > curPrice + risk * InpMinRR) : (rawTp2 < curPrice - risk * InpMinRR))
                   ? rawTp2
                   : (isBull ? (curPrice + risk * 3.2) : (curPrice - risk * 3.2));

      double rr1 = MathAbs(tp1 - curPrice) / risk;
      double rr2 = MathAbs(tp2 - curPrice) / risk;

      if(rr1 >= 1.50 && rr2 >= InpMinRR)
      {
         string cmdId = "NATIVE_APLUS_" + pairTag + "_" + (isBull ? "BUY_" : "SELL_") + sym + "_" + IntegerToString((int)ltf[cL - 1].time);
         string comm  = "SMC_APLUS_7of7_" + pairTag + "_" + (isBull ? "BUY" : "SELL");
         if(ExecuteVerifiedAPlusTrade(cmdId, sym, isBull, curPrice, sl, tp2, comm))
            return true;
      }
   }
   return false;
}

void EvaluateSymbolPureAPlus(const string sym)
{
   if(!InpEnableAutoExe || !InpNativeAPlusScan) return;
   string reason = "";
   if(!CanOpenNewTrade(sym, "SMC_APLUS_NATIVE", reason)) return;

   // Primary Author Timeframe Pair: H1 -> M5 (Ch. 6, 7 & 9)
   if(EvaluateTimeframePairPureAPlus(sym, PERIOD_H1, PERIOD_M5, "H1_M5"))
      return;
   // Fast Intraday Sniper Pair: M15 -> M1 (Ch. 7 & 8)
   EvaluateTimeframePairPureAPlus(sym, PERIOD_M15, PERIOD_M1, "M15_M1");
}

//+------------------------------------------------------------------+
//| Export Live Account State & Active Orders to SMC Web Terminal    |
//+------------------------------------------------------------------+
void ExportAccountAndOrders()
{
   long   login  = AccountInfoInteger(ACCOUNT_LOGIN);
   string srv    = AccountInfoString(ACCOUNT_SERVER);
   double bal    = AccountInfoDouble(ACCOUNT_BALANCE);
   double eq     = AccountInfoDouble(ACCOUNT_EQUITY);
   double margin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   string broker = IsWeltradeBroker() ? "weltrade" : "deriv";

   string posJson = "[";
   bool firstPos = true;

   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      string sym    = PositionGetString(POSITION_SYMBOL);
      long   type   = PositionGetInteger(POSITION_TYPE);
      double vol    = PositionGetDouble(POSITION_VOLUME);
      double openP  = PositionGetDouble(POSITION_PRICE_OPEN);
      double curP   = PositionGetDouble(POSITION_PRICE_CURRENT);
      double sl     = PositionGetDouble(POSITION_SL);
      double tp     = PositionGetDouble(POSITION_TP);
      double profit = PositionGetDouble(POSITION_PROFIT);
      long   timeO  = PositionGetInteger(POSITION_TIME);
      string comm   = PositionGetString(POSITION_COMMENT);
      int    dec    = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
      if(dec < 0 || dec > 8) dec = 2;

      if(!firstPos) posJson += ",";
      firstPos = false;
      posJson += StringFormat(
         "{\"ticket\":%I64u,\"kind\":\"POSITION\",\"broker\":\"%s\",\"symbol\":\"%s\",\"side\":\"%s\",\"lot\":%.3f,\"entry\":%.*f,\"current\":%.*f,\"sl\":%.*f,\"tp\":%.*f,\"profit\":%.2f,\"time\":%I64d,\"comment\":\"%s\"}",
         ticket, broker, sym, (type == POSITION_TYPE_BUY ? "BUY" : "SELL"),
         vol, dec, openP, dec, curP, dec, sl, dec, tp, profit, timeO, comm
      );
   }

   for(int j = 0; j < OrdersTotal(); j++)
   {
      ulong ticket = OrderGetTicket(j);
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
         "{\"ticket\":%I64u,\"kind\":\"PENDING\",\"broker\":\"%s\",\"symbol\":\"%s\",\"side\":\"%s\",\"lot\":%.3f,\"entry\":%.*f,\"current\":%.*f,\"sl\":%.*f,\"tp\":%.*f,\"profit\":0.00,\"time\":%I64d,\"comment\":\"%s\"}",
         ticket, broker, sym, sideStr,
         vol, dec, openP, dec, curP, dec, sl, dec, tp, timeO, comm
      );
   }
   posJson += "]";

   string stateJson = StringFormat(
      "{\"broker\":\"%s\",\"login\":%I64d,\"server\":\"%s\",\"balance\":%.2f,\"equity\":%.2f,\"freeMargin\":%.2f,\"updated\":%I64d,\"orders\":%s}",
      broker, login, srv, bal, eq, margin, (long)TimeCurrent(), posJson
   );

   string brokerFile = IsWeltradeBroker() ? "smc_bridge\\account_weltrade.json" : "smc_bridge\\account_deriv.json";
   int fhB = FileOpen(brokerFile, FILE_WRITE | FILE_TXT | FILE_COMMON | FILE_SHARE_READ);
   if(fhB != INVALID_HANDLE)
   {
      FileWriteString(fhB, stateJson);
      FileClose(fhB);
   }

   int fh = FileOpen("smc_bridge\\account_state.json", FILE_WRITE | FILE_TXT | FILE_COMMON | FILE_SHARE_READ);
   if(fh != INVALID_HANDLE)
   {
      FileWriteString(fh, stateJson);
      FileClose(fh);
   }
}

//+------------------------------------------------------------------+
//| Export Live 1-Second Bid/Ask Quotes for All Broker Symbols       |
//+------------------------------------------------------------------+
void ExportLiveQuotes()
{
   string broker = IsWeltradeBroker() ? "weltrade" : "deriv";
   string qJson = "{";
   bool first = true;

   for(int i = 0; i < g_brokerSymCount; i++)
   {
      string sym = g_brokerSyms[i];
      double bid = SymbolInfoDouble(sym, SYMBOL_BID);
      double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
      if(bid <= 0.0) continue;

      int dec = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
      if(dec < 0 || dec > 8) dec = 2;
      long t = (long)SymbolInfoInteger(sym, SYMBOL_TIME);
      if(t <= 0) t = (long)TimeCurrent();

      if(!first) qJson += ",";
      first = false;
      qJson += StringFormat("\"%s\":{\"bid\":%.*f,\"ask\":%.*f,\"digits\":%d,\"time\":%I64d,\"broker\":\"%s\"}",
                            sym, dec, bid, dec, ask, dec, t, broker);
   }
   qJson += "}";

   string qFile = IsWeltradeBroker() ? "smc_bridge\\quotes_weltrade.json" : "smc_bridge\\quotes_deriv.json";
   int fh = FileOpen(qFile, FILE_WRITE | FILE_TXT | FILE_COMMON | FILE_SHARE_READ);
   if(fh != INVALID_HANDLE)
   {
      FileWriteString(fh, qJson);
      FileClose(fh);
   }
}

//+------------------------------------------------------------------+
//| Export All 6 Timeframes for a Single Symbol (Fast & Non-Blocking)|
//+------------------------------------------------------------------+
int ExportSymbolTimeframes(const string sym, bool forceWaitIfNeeded)
{
   if(StringLen(sym) == 0) return 0;
   if(!SymbolInfoInteger(sym, SYMBOL_SELECT))
      SymbolSelect(sym, true);

   double bid = SymbolInfoDouble(sym, SYMBOL_BID);
   if(bid <= 0.0 && !forceWaitIfNeeded) return 0;

   ENUM_TIMEFRAMES tfs[6] = {PERIOD_M1, PERIOD_M5, PERIOD_M15, PERIOD_H1, PERIOD_H4, PERIOD_D1};
   int tfSec[6]           = {60, 300, 900, 3600, 14400, 86400};
   int dec = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   if(dec < 0 || dec > 8) dec = 2;
   string fmt = "%I64d,%." + IntegerToString(dec) + "f,%." + IntegerToString(dec) + "f,%." + IntegerToString(dec) + "f,%." + IntegerToString(dec) + "f";
   string safeSym = SanitizeSym(sym);

   int exported = 0;
   for(int t = 0; t < 6; t++)
   {
      // Non-blocking history check: calling Bars() triggers async download in MT5 without freezing OnTimer!
      int availBars = Bars(sym, tfs[t]);
      if(availBars < 5 && !forceWaitIfNeeded)
         continue;

      MqlRates rates[];
      ArraySetAsSeries(rates, false);
      int copied = CopyRates(sym, tfs[t], 0, InpFullBars, rates);
      if(copied <= 0) continue;

      // Snap the forming candle's close/high/low to the exact live MT5 Bid price
      if(bid > 0.0)
      {
         rates[copied - 1].close = bid;
         if(bid > rates[copied - 1].high) rates[copied - 1].high = bid;
         if(bid < rates[copied - 1].low)  rates[copied - 1].low  = bid;
      }

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

      string filePath = "smc_bridge\\" + safeSym + "_" + IntegerToString(tfSec[t]) + ".json";
      int fileHandle = FileOpen(filePath, FILE_WRITE | FILE_TXT | FILE_COMMON | FILE_SHARE_READ);
      if(fileHandle != INVALID_HANDLE)
      {
         FileWriteString(fileHandle, json);
         FileClose(fileHandle);
         exported++;
      }
   }
   return exported;
}

//+------------------------------------------------------------------+
//| Execute Incoming Web Terminal Pure A+ & Trailing Commands        |
//+------------------------------------------------------------------+
void ProcessQueueFile(const string cmdPath)
{
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

void ProcessCommandQueue()
{
   if(!InpEnableAutoExe) return;
   string brokerQueue = IsWeltradeBroker() ? "smc_bridge\\commands_weltrade.txt" : "smc_bridge\\commands_deriv.txt";
   ProcessQueueFile(brokerQueue);
   ProcessQueueFile("smc_bridge\\commands_queue.txt");
}

//+------------------------------------------------------------------+
//| Read Active Symbol Requested by Browser for Instant 1s Priority  |
//+------------------------------------------------------------------+
string GetActivePrioritySymbol()
{
   string activeFile = IsWeltradeBroker() ? "smc_bridge\\active_weltrade.txt" : "smc_bridge\\active_deriv.txt";
   if(!FileIsExist(activeFile, FILE_COMMON)) return _Symbol;

   int fh = FileOpen(activeFile, FILE_READ | FILE_TXT | FILE_COMMON | FILE_SHARE_READ | FILE_SHARE_WRITE);
   if(fh == INVALID_HANDLE) return _Symbol;
   string s = FileReadString(fh);
   FileClose(fh);
   StringTrimLeft(s);
   StringTrimRight(s);
   return (StringLen(s) > 0) ? s : _Symbol;
}

//+------------------------------------------------------------------+
//| Main 1-Second Timer: Instant Quotes + Priority Chart + RR Batch  |
//+------------------------------------------------------------------+
void OnTimer()
{
   // 1. Execute trades, trail stops, export live account & live bid/ask quotes every 1 second
   ProcessCommandQueue();
   ManageOpenPositionsAndTrailing();
   ExportAccountAndOrders();
   ExportLiveQuotes();

   if(g_brokerSymCount <= 0)
      InitBrokerSymbols();

   // 2. Priority 1-second sync for the symbol currently viewed in the browser (and chart symbol)
   string activeSym = GetActivePrioritySymbol();
   if(StringLen(activeSym) > 0)
      ExportSymbolTimeframes(activeSym, true);
   if(_Symbol != activeSym)
      ExportSymbolTimeframes(_Symbol, false);

   // 3. Non-blocking round-robin sync for 4 symbols per second across the broker watchlist
   int batchSize = 4;
   int exportedSeries = 0;
   for(int b = 0; b < batchSize && g_brokerSymCount > 0; b++)
   {
      int idx = (g_rrCursor + b) % g_brokerSymCount;
      string sym = g_brokerSyms[idx];
      if(sym != activeSym && sym != _Symbol)
      {
         exportedSeries += ExportSymbolTimeframes(sym, false);
         EvaluateSymbolPureAPlus(sym);
      }
   }
   g_rrCursor = (g_brokerSymCount > 0) ? ((g_rrCursor + batchSize) % g_brokerSymCount) : 0;

   if(TimeCurrent() - g_lastLog > 30)
   {
      g_lastLog = TimeCurrent();
      Print("SMC_Auto_Bridge v4.20 [1s LIVE]: ActiveSym='", activeSym, "' | Watchlist=", g_brokerSymCount,
            " | Account #", AccountInfoInteger(ACCOUNT_LOGIN));
   }
}
//+------------------------------------------------------------------+
