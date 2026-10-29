//+------------------------------------------------------------------+
//|                                              SMC_Auto_Bridge.mq5 |
//|     Frank Miller Smart Money Concepts (SMC) Live MT5 Auto-Bridge |
//|   Pure A+ Autonomous Execution & Institutional Risk Manager v4.2 |
//+------------------------------------------------------------------+
#property copyright "SMC Desk — Frank Miller Smart Money Concepts"
#property version   "4.30"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\OrderInfo.mqh>
#include <Trade\PositionInfo.mqh>

input string InpServerUrl         = "http://localhost:8095"; // Local SMC Desk Server URL
input int    InpFullBars          = 500;      // Historical bars exported every sync
input long   InpMagicNumber       = 20260401; // Magic Number for SMC Auto-Trades
input bool   InpEnableAutoExe     = true;     // Enable Pure A+ Auto-Trading & X1-X3 Trailing
input bool   InpNativeAPlusScan   = true;     // Run Native MQL5 Pure A+ Scanner (H1 -> M5)
input bool   InpEnablePartialTP1  = true;     // Bank 50% Volume at TP1 (1.5R) + Move SL to BE
input double InpPartialTP1R       = 1.50;     // R-Multiple Trigger for 50% Partial TP1 Banking
input double InpMaxSpreadToSLPct  = 18.0;     // Max Spread as % of SL Distance (Spread Guard)
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
   int fhCat = FileOpen(catFile, FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_COMMON);
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
//| Spike Direction Guard for Boom / Crash / PainX / GainX / DEX     |
//+------------------------------------------------------------------+
bool IsCounterSpikeTrade(const string sym, bool isBuy)
{
   string up = sym;
   StringToUpper(up);
   if((StringFind(up, "BOOM") >= 0 || StringFind(up, "GAINX") >= 0 || StringFind(up, "DEX 600 UP") >= 0 || StringFind(up, "DEX 900 UP") >= 0) && !isBuy)
      return true;
   if((StringFind(up, "CRASH") >= 0 || StringFind(up, "PAINX") >= 0 || StringFind(up, "DEX 600 DOWN") >= 0 || StringFind(up, "DEX 900 DOWN") >= 0) && isBuy)
      return true;
   return false;
}

//+------------------------------------------------------------------+
//| Index-Specific Spike Exhaustion & Spread-to-SL Filter            |
//+------------------------------------------------------------------+
bool PassIndexVolatilityAndSpreadFilter(const string sym, bool isBuy, double riskDist, string &outReason)
{
   if(IsCounterSpikeTrade(sym, isBuy))
   {
      outReason = "Counter-spike direction blocked on " + sym;
      return false;
   }

   double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
   double bid = SymbolInfoDouble(sym, SYMBOL_BID);
   if(ask > 0.0 && bid > 0.0 && riskDist > 0.0)
   {
      double spreadDist = MathMax(0.0, ask - bid);
      double spreadRatioPct = (spreadDist / riskDist) * 100.0;
      if(spreadRatioPct > InpMaxSpreadToSLPct)
      {
         outReason = StringFormat("Spread Guard: Spread is %.1f%% of SL (> %.1f%% max)", spreadRatioPct, InpMaxSpreadToSLPct);
         return false;
      }
   }

   // Post-Spike Chasing Guard on Boom/Crash/PainX/GainX/Jump/BreakX
   string up = sym;
   StringToUpper(up);
   bool isSpikeIndex = (StringFind(up, "BOOM") >= 0 || StringFind(up, "CRASH") >= 0 ||
                        StringFind(up, "PAINX") >= 0 || StringFind(up, "GAINX") >= 0 ||
                        StringFind(up, "JUMP") >= 0 || StringFind(up, "BREAKX") >= 0);
   if(isSpikeIndex && Bars(sym, PERIOD_M1) >= 20)
   {
      MqlRates m1[];
      ArraySetAsSeries(m1, true);
      int copied = CopyRates(sym, PERIOD_M1, 0, 16, m1);
      if(copied >= 15)
      {
         double avgRng = 0.0;
         for(int i = 2; i < 15; i++)
            avgRng += MathMax(m1[i].high - m1[i].low, 1e-8);
         avgRng /= 13.0;

         double lastBarMove = isBuy ? (m1[0].close - m1[0].open) : (m1[0].open - m1[0].close);
         double prevBarMove = isBuy ? (m1[1].close - m1[1].open) : (m1[1].open - m1[1].close);
         if(avgRng > 0.0 && (lastBarMove > avgRng * 3.5 || prevBarMove > avgRng * 4.0))
         {
            outReason = "Spike Exhaustion Guard: Waiting for post-spike pullback on " + sym;
            return false;
         }
      }
   }

   outReason = "OK";
   return true;
}

ulong g_partialClosedTickets[];
int   g_partialClosedCount = 0;

bool HasTicketAlreadyBankedTP1(ulong ticket)
{
   for(int i = 0; i < g_partialClosedCount; i++)
   {
      if(g_partialClosedTickets[i] == ticket)
         return true;
   }
   return false;
}

void MarkTicketBankedTP1(ulong ticket)
{
   if(HasTicketAlreadyBankedTP1(ticket)) return;
   ArrayResize(g_partialClosedTickets, g_partialClosedCount + 1);
   g_partialClosedTickets[g_partialClosedCount] = ticket;
   g_partialClosedCount++;
}

//+------------------------------------------------------------------+
//| Balance-Tiered Account Growth & Micro-Capital Protection Matrix  |
//+------------------------------------------------------------------+
void GetAccountGrowthTier(double equity, string &outTierName, double &outBaseRiskPct, double &outMaxRiskPct, int &outMaxTrades, double &outDailyLossCapPct, double &outDailyProfitLockPct)
{
   if(equity < 100.0)
   {
      outTierName           = "TIER_1_MICRO_SEED ($10-$99)";
      outBaseRiskPct        = 0.75;
      outMaxRiskPct         = 1.50;
      outMaxTrades          = 1;
      outDailyLossCapPct    = 2.50;
      outDailyProfitLockPct = 4.50;
   }
   else if(equity < 250.0)
   {
      outTierName           = "TIER_2_MICRO_ELEVATION ($100-$249)";
      outBaseRiskPct        = 0.85;
      outMaxRiskPct         = 1.65;
      outMaxTrades          = 1;
      outDailyLossCapPct    = 2.80;
      outDailyProfitLockPct = 5.00;
   }
   else if(equity < 500.0)
   {
      outTierName           = "TIER_3_GROWTH_STARTER ($250-$499)";
      outBaseRiskPct        = 0.90;
      outMaxRiskPct         = 1.85;
      outMaxTrades          = 2;
      outDailyLossCapPct    = 3.00;
      outDailyProfitLockPct = 5.00;
   }
   else if(equity < 2500.0)
   {
      outTierName           = "TIER_4_INSTITUTIONAL ($500-$2,499)";
      outBaseRiskPct        = InpRiskPercent;
      outMaxRiskPct         = 2.20;
      outMaxTrades          = InpMaxOpenTrades;
      outDailyLossCapPct    = 3.50;
      outDailyProfitLockPct = 5.50;
   }
   else
   {
      outTierName           = "TIER_5_PRO_COMPOUNDER ($2,500+)";
      outBaseRiskPct        = InpRiskPercent;
      outMaxRiskPct         = InpMaxRiskPercent;
      outMaxTrades          = InpMaxOpenTrades;
      outDailyLossCapPct    = InpMaxDailyLossPct;
      outDailyProfitLockPct = 6.50;
   }
}

//+------------------------------------------------------------------+
//| Balance-Tiered Symbol Filter (Blocks Heavy Indices on Micro Acc) |
//+------------------------------------------------------------------+
bool IsSymbolSafeForAccountTier(const string sym, double equity, string &outBlockReason)
{
   string up = sym;
   StringToUpper(up);

   // Universal Toxic Asset Quarantine: Block erratic/toxic pairs across ALL account tiers
   if(StringFind(up, "PAINX 1200") >= 0 || StringFind(up, "PAINX 600") >= 0 ||
      StringFind(up, "VOLATILITY 50 INDEX") >= 0 || StringFind(up, "1HZ50V") >= 0)
   {
      outBlockReason = StringFormat("Tier-C Toxic Asset Guard: Blocked %s (quarantined due to erratic wicks / negative edge)", sym);
      return false;
   }

   // Tier 1 Micro Seed ($10 - $99): Block heavy tick-value / wide-swing indices that can blow micro margin
   if(equity < 100.0)
   {
      if(StringFind(up, "SFX VOL 80") >= 0 || StringFind(up, "SFX VOL 99") >= 0 ||
         StringFind(up, "GAINX 1200") >= 0 ||
         StringFind(up, "MAX PAINX 2000") >= 0 || StringFind(up, "MAX GAINX 2000") >= 0 ||
         StringFind(up, "BREAKX 1800") >= 0 || StringFind(up, "SWITCHX 1800") >= 0 ||
         StringFind(up, "JUMP 100") >= 0 || StringFind(up, "BOOM 1000") >= 0 || StringFind(up, "CRASH 1000") >= 0)
      {
         outBlockReason = StringFormat("Balance-Tier Shield ($%.2f < $100): Blocked heavy index %s (Only Micro-Safe symbols allowed)", equity, sym);
         return false;
      }
   }
   // Tier 2 Growth Starter ($100 - $249): Block ultra-heavy 1800/2000 indices
   else if(equity < 250.0)
   {
      if(StringFind(up, "MAX PAINX 2000") >= 0 || StringFind(up, "MAX GAINX 2000") >= 0 ||
         StringFind(up, "SFX VOL 99") >= 0)
      {
         outBlockReason = StringFormat("Balance-Tier Shield ($%.2f < $250): Blocked ultra-heavy index %s", equity, sym);
         return false;
      }
   }
   return true;
}

//+------------------------------------------------------------------+
//| Institutional Portfolio, Balance-Tier & Symbol Risk Guard        |
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
   if(equity <= 0.0) equity = balance;

   string tierName = ""; double tierBaseRisk = 1.0, tierMaxRisk = 2.5, tierDdCap = 4.0, tierProfitLock = 5.0;
   int tierMaxTrades = InpMaxOpenTrades;
   GetAccountGrowthTier(equity, tierName, tierBaseRisk, tierMaxRisk, tierMaxTrades, tierDdCap, tierProfitLock);

   if(!IsSymbolSafeForAccountTier(sym, equity, outReason))
      return false;

   double refCap = MathMax(g_dayStartEquity, balance);
   if(refCap > 0.0)
   {
      double ddPct = ((refCap - equity) / refCap) * 100.0;
      if(ddPct >= tierDdCap)
      {
         outReason = StringFormat("[%s] Daily Drawdown Breaker Active (%.2f%% >= %.2f%%)", tierName, ddPct, tierDdCap);
         return false;
      }
      if(g_dayStartEquity > 0.0)
      {
         double dayGainPct = ((equity - g_dayStartEquity) / g_dayStartEquity) * 100.0;
         if(dayGainPct >= tierProfitLock)
         {
            outReason = StringFormat("[%s] Daily Profit Target Locked (+%.2f%% >= +%.2f%% goal)", tierName, dayGainPct, tierProfitLock);
            return false;
         }
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

   if(openCount >= tierMaxTrades)
   {
      outReason = StringFormat("[%s] Max Concurrent Trades Reached (%d/%d)", tierName, openCount, tierMaxTrades);
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
//| Algorithmic Spike-Cycle Hazard Predictor (Boom/Crash/PainX/GainX)|
//+------------------------------------------------------------------+
double GetSpikeCycleHazard(const string sym, bool isBuy, int &outBarsSinceSpike, long &outTicksSinceSpike, int &outExpectedInterval)
{
   outBarsSinceSpike   = 0;
   outTicksSinceSpike  = 0;
   outExpectedInterval = 0;

   string up = sym;
   StringToUpper(up);
   bool isSpikeIdx = (StringFind(up, "BOOM") >= 0 || StringFind(up, "CRASH") >= 0 ||
                      StringFind(up, "PAINX") >= 0 || StringFind(up, "GAINX") >= 0 ||
                      StringFind(up, "BREAKX") >= 0 || StringFind(up, "DEX") >= 0);
   if(!isSpikeIdx) return 0.0;

   if(StringFind(up, "300") >= 0)       outExpectedInterval = 300;
   else if(StringFind(up, "400") >= 0)  outExpectedInterval = 400;
   else if(StringFind(up, "500") >= 0)  outExpectedInterval = 500;
   else if(StringFind(up, "600") >= 0)  outExpectedInterval = 600;
   else if(StringFind(up, "800") >= 0)  outExpectedInterval = 800;
   else if(StringFind(up, "900") >= 0)  outExpectedInterval = 900;
   else if(StringFind(up, "999") >= 0 || StringFind(up, "1000") >= 0) outExpectedInterval = 1000;
   else if(StringFind(up, "1200") >= 0) outExpectedInterval = 1200;
   else if(StringFind(up, "1800") >= 0) outExpectedInterval = 1800;
   else if(StringFind(up, "2000") >= 0) outExpectedInterval = 2000;
   else outExpectedInterval = 600;

   if(Bars(sym, PERIOD_M1) < 30) return 50.0;

   MqlRates m1[];
   ArraySetAsSeries(m1, true);
   int copied = CopyRates(sym, PERIOD_M1, 0, 60, m1);
   if(copied < 20) return 50.0;

   double avgRng = 0.0;
   for(int i = 1; i < copied; i++)
      avgRng += MathMax(m1[i].high - m1[i].low, 1e-8);
   avgRng /= (double)(copied - 1);

   bool isUpSpikeIdx = (StringFind(up, "BOOM") >= 0 || StringFind(up, "GAINX") >= 0 || StringFind(up, "UP") >= 0);
   for(int i = 0; i < copied; i++)
   {
      double move = isUpSpikeIdx ? (m1[i].close - m1[i].open) : (m1[i].open - m1[i].close);
      if(avgRng > 0.0 && move >= avgRng * 2.2)
         break;
      outBarsSinceSpike++;
      outTicksSinceSpike += (m1[i].tick_volume > 0 ? m1[i].tick_volume : 60);
   }

   double ratio = (double)outTicksSinceSpike / (double)MathMax(outExpectedInterval, 100);
   double hazard = (1.0 - MathExp(-MathPow(ratio, 1.35))) * 100.0;
   return MathMin(99.0, MathMax(5.0, hazard));
}

//+------------------------------------------------------------------+
//| Adaptive Streak-Protected Risk Engine (0.50% -> 1.00% -> 1.35%)  |
//+------------------------------------------------------------------+
void GetAccountStreakAndAdaptiveRisk(const string sym, bool isBuy, double rr, double &outRiskPct, string &outModeTag, int &outStreak)
{
   outStreak  = 0;
   outRiskPct = InpRiskPercent;
   outModeTag = "STANDARD_1.0%";

   if(HistorySelect(TimeCurrent() - 7 * 86400, TimeCurrent()))
   {
      int totalDeals = HistoryDealsTotal();
      int firstSign  = 0;
      for(int d = totalDeals - 1; d >= 0; d--)
      {
         ulong dt = HistoryDealGetTicket(d);
         if(dt == 0) continue;
         long entryType = HistoryDealGetInteger(dt, DEAL_ENTRY);
         if(entryType != DEAL_ENTRY_OUT && entryType != DEAL_ENTRY_INOUT) continue;
         string dSym = HistoryDealGetString(dt, DEAL_SYMBOL);
         if(StringLen(dSym) == 0) continue;

         double netPnl = HistoryDealGetDouble(dt, DEAL_PROFIT) + HistoryDealGetDouble(dt, DEAL_SWAP) + HistoryDealGetDouble(dt, DEAL_COMMISSION);
         if(MathAbs(netPnl) < 0.01) continue; // ignore scratch breakevens

         int sign = (netPnl > 0.0) ? 1 : -1;
         if(firstSign == 0)
         {
            firstSign = sign;
            outStreak = sign;
         }
         else if(sign == firstSign)
         {
            outStreak += sign;
         }
         else
         {
            break;
         }
      }
   }

   double eq     = AccountInfoDouble(ACCOUNT_EQUITY);
   double bal    = AccountInfoDouble(ACCOUNT_BALANCE);
   double refCap = MathMax(g_dayStartEquity, bal);
   double ddPct  = (refCap > 0.0 && eq < refCap) ? (((refCap - eq) / refCap) * 100.0) : 0.0;

   int barsSince = 0; long ticksSince = 0; int expInt = 0;
   double spikeHaz = GetSpikeCycleHazard(sym, isBuy, barsSince, ticksSince, expInt);

   if(outStreak <= -2 || ddPct >= 2.0)
   {
      outRiskPct = 0.50;
      outModeTag = "DEFENSIVE_0.50%";
   }
   else if(outStreak == -1)
   {
      outRiskPct = 0.75;
      outModeTag = "CAUTIOUS_0.75%";
   }
   else if(outStreak >= 1 && (rr >= 3.20 || spikeHaz >= 75.0))
   {
      outRiskPct = MathMin(1.35, InpMaxRiskPercent);
      outModeTag = (spikeHaz >= 75.0) ? "ULTRA_SPIKE_SNIPER_1.35%" : "ULTRA_APLUS_1.35%";
   }
   else
   {
      outRiskPct = InpRiskPercent;
      outModeTag = (spikeHaz >= 75.0) ? "SPIKE_SNIPER_1.00%" : "STANDARD_1.00%";
   }
}

//+------------------------------------------------------------------+
//| Exact Risk-Managed Lot Size Calculation Using OrderCalcProfit    |
//+------------------------------------------------------------------+
double CalculateRiskLot(const string sym, bool isBuy, double entryPrice, double slPrice, double rr, double &outRiskUsd, double &outAdaptivePct, string &outRiskMode)
{
   outRiskUsd = 0.0;
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity <= 0.0) equity = AccountInfoDouble(ACCOUNT_BALANCE);
   if(equity <= 0.0) return 0.0;

   int streak = 0;
   GetAccountStreakAndAdaptiveRisk(sym, isBuy, rr, outAdaptivePct, outRiskMode, streak);

   string tierName = ""; double tierBaseRisk = 1.0, tierMaxRisk = InpMaxRiskPercent, tierDdCap = 4.0, tierProfitLock = 5.0;
   int tierMaxTrades = InpMaxOpenTrades;
   GetAccountGrowthTier(equity, tierName, tierBaseRisk, tierMaxRisk, tierMaxTrades, tierDdCap, tierProfitLock);

   double effectivePct = MathMin(outAdaptivePct, tierBaseRisk * 1.35);
   double riskPct = MathMin(MathMax(effectivePct, 0.10), tierMaxRisk);
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
      if(minLotRiskPct > tierMaxRisk)
      {
         Print("SMC_Auto_Bridge [", tierName, " SHIELD] Blocked ", sym, ": Min lot (", volMin,
               ") risks $", DoubleToString(minLotLoss, 2), " (", DoubleToString(minLotRiskPct, 2),
               "% > Tier Max ", DoubleToString(tierMaxRisk, 2), "%)");
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

   entry = NormalizePrice(sym, entry);
   sl    = NormalizePrice(sym, sl);
   tp    = NormalizePrice(sym, tp);

   double riskDist   = MathAbs(entry - sl);
   double rewardDist = MathAbs(tp - entry);
   if(riskDist <= 0.0 || rewardDist <= 0.0) return false;

   string filterReason = "";
   if(!PassIndexVolatilityAndSpreadFilter(sym, isBuy, riskDist, filterReason))
   {
      Print("SMC_Auto_Bridge [", cmdId, "] BLOCKED ", sym, ": ", filterReason);
      return false;
   }

   double rr = rewardDist / riskDist;
   if(rr < InpMinRR - 0.05)
   {
      Print("SMC_Auto_Bridge [", cmdId, "] BLOCKED ", sym, ": R:R ", DoubleToString(rr, 2),
            " < Minimum Required 1:", DoubleToString(InpMinRR, 2));
      return false;
   }

   double actualRiskUsd = 0.0;
   double adaptivePct   = InpRiskPercent;
   string riskModeTag   = "STANDARD_1.0%";
   double lots = CalculateRiskLot(sym, isBuy, entry, sl, rr, actualRiskUsd, adaptivePct, riskModeTag);
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
//| Manage Open Positions: 50% Partial TP1 @ 1.5R + BE + X1-X3 Trail |
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

      string sym    = PositionGetString(POSITION_SYMBOL);
      long   type   = PositionGetInteger(POSITION_TYPE);
      double curVol = PositionGetDouble(POSITION_VOLUME);
      double openP  = PositionGetDouble(POSITION_PRICE_OPEN);
      double curP   = PositionGetDouble(POSITION_PRICE_CURRENT);
      double curSl  = PositionGetDouble(POSITION_SL);
      double curTp  = PositionGetDouble(POSITION_TP);
      bool   isBuy  = (type == POSITION_TYPE_BUY);

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

      // Check whether SL is already locked at/beyond Breakeven
      bool alreadyAtBE = isBuy ? (curSl >= openP - point) : (curSl > 0.0 && curSl <= openP + point);

      // 1. Partial TP1 Banking: Close 50% of volume at +1.50R and lock SL to Breakeven + 0.15R
      if(InpEnablePartialTP1 && currentR >= InpPartialTP1R && !alreadyAtBE && !HasTicketAlreadyBankedTP1(ticket))
      {
         double volMin  = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
         double volStep = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
         if(volMin <= 0.0)  volMin  = 0.01;
         if(volStep <= 0.0) volStep = 0.01;

         int lotDigits = 2;
         if(volStep >= 1.0) lotDigits = 0;
         else if(volStep >= 0.1) lotDigits = 1;
         else if(volStep >= 0.01) lotDigits = 2;
         else lotDigits = 3;

         double halfVol = MathFloor((curVol * 0.50) / volStep) * volStep;
         halfVol = NormalizeDouble(halfVol, lotDigits);

         MarkTicketBankedTP1(ticket);

         if(curVol >= volMin * 2.0 && halfVol >= volMin && (curVol - halfVol) >= volMin - 1e-6)
         {
            ConfigureSymbolFilling(sym);
            if(g_trade.PositionClosePartial(ticket, halfVol))
            {
               Print("SMC_Auto_Bridge [PARTIAL TP1 BANKED] Ticket #", ticket, " (", sym,
                     "): Closed 50% (", halfVol, " lots) at +", DoubleToString(currentR, 2), "R! Moving runner SL to Breakeven+");
            }
         }
      }

      double candidateSl = curSl;

      // ===================================================================
      // ZERO-LOSS PROFIT ARMOR: NEVER LET A WINNER CLOSE IN A LOSS
      // Stage 1: Jump SL to Breakeven + Buffer at +0.70R (Zero-Loss Armor)
      // Stage 2: Ratchet SL to +0.35R profit lock at +1.20R
      // Stage 3: Ratchet SL to +0.85R profit lock at +1.70R
      // ===================================================================
      if(currentR >= 0.70)
      {
         double armBuffer = MathMax(point * 6.0, minDist * 0.25);
         double beArmed = isBuy ? (openP + armBuffer) : (openP - armBuffer);
         if(isBuy)
         {
            if(curSl == 0.0 || beArmed > candidateSl + point)
               candidateSl = beArmed;
         }
         else
         {
            if(curSl == 0.0 || beArmed < candidateSl - point)
               candidateSl = beArmed;
         }
      }

      if(currentR >= 1.20)
      {
         double lock12 = isBuy ? (openP + initRisk * 0.35) : (openP - initRisk * 0.35);
         if(isBuy)
         {
            if(curSl == 0.0 || lock12 > candidateSl + point)
               candidateSl = lock12;
         }
         else
         {
            if(curSl == 0.0 || lock12 < candidateSl - point)
               candidateSl = lock12;
         }
      }

      if(currentR >= 1.70)
      {
         double lock17 = isBuy ? (openP + initRisk * 0.85) : (openP - initRisk * 0.85);
         if(isBuy)
         {
            if(curSl == 0.0 || lock17 > candidateSl + point)
               candidateSl = lock17;
         }
         else
         {
            if(curSl == 0.0 || lock17 < candidateSl - point)
               candidateSl = lock17;
         }
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
         {
            string armorTag = (currentR >= 1.70) ? "PROFIT_LOCK_+0.85R" : (currentR >= 1.20 ? "PROFIT_LOCK_+0.35R" : (currentR >= 0.70 ? "ZERO_LOSS_ARMOR_BE+" : "X1-X3_TRAIL"));
            Print("SMC_Auto_Bridge [", armorTag, "] Ticket #", ticket, " (", sym, ") SL guarded: ", curSl, " -> ", candidateSl, " (R=", DoubleToString(currentR, 2), ")");
         }
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
//| Export Live Account State, Active Orders & Closed Deal Analytics |
//+------------------------------------------------------------------+
void ExportAccountAndOrders()
{
   long   login  = AccountInfoInteger(ACCOUNT_LOGIN);
   string srv    = AccountInfoString(ACCOUNT_SERVER);
   double bal    = AccountInfoDouble(ACCOUNT_BALANCE);
   double eq     = AccountInfoDouble(ACCOUNT_EQUITY);
   double margin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   string broker = IsWeltradeBroker() ? "weltrade" : "deriv";

   double floatingPnl = 0.0;
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

      floatingPnl += profit;
      bool isBuy = (type == POSITION_TYPE_BUY);
      bool atBE  = isBuy ? (sl >= openP && openP > 0) : (sl > 0 && sl <= openP);
      bool tp1Banked = HasTicketAlreadyBankedTP1(ticket) || atBE;

      if(!firstPos) posJson += ",";
      firstPos = false;
      posJson += StringFormat(
         "{\"ticket\":%I64u,\"kind\":\"POSITION\",\"broker\":\"%s\",\"symbol\":\"%s\",\"side\":\"%s\",\"lot\":%.3f,\"entry\":%.*f,\"current\":%.*f,\"sl\":%.*f,\"tp\":%.*f,\"profit\":%.2f,\"tp1Banked\":%s,\"time\":%I64d,\"comment\":\"%s\"}",
         ticket, broker, sym, (isBuy ? "BUY" : "SELL"),
         vol, dec, openP, dec, curP, dec, sl, dec, tp, profit, (tp1Banked ? "true" : "false"), timeO, comm
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
         "{\"ticket\":%I64u,\"kind\":\"PENDING\",\"broker\":\"%s\",\"symbol\":\"%s\",\"side\":\"%s\",\"lot\":%.3f,\"entry\":%.*f,\"current\":%.*f,\"sl\":%.*f,\"tp\":%.*f,\"profit\":0.00,\"tp1Banked\":false,\"time\":%I64d,\"comment\":\"%s\"}",
         ticket, broker, sym, sideStr,
         vol, dec, openP, dec, curP, dec, sl, dec, tp, timeO, comm
      );
   }
   posJson += "]";

   // Calculate 7-Day Closed Trade Analytics & Recent Closed History
   int    closedCount = 0;
   int    winCount    = 0;
   int    lossCount   = 0;
   double realizedPnl = 0.0;
   string histJson    = "[";
   bool   firstHist   = true;
   int    histExported = 0;

   if(HistorySelect(TimeCurrent() - 7 * 86400, TimeCurrent()))
   {
      int totalDeals = HistoryDealsTotal();
      for(int d = totalDeals - 1; d >= 0; d--)
      {
         ulong dt = HistoryDealGetTicket(d);
         if(dt == 0) continue;
         long entryType = HistoryDealGetInteger(dt, DEAL_ENTRY);
         if(entryType != DEAL_ENTRY_OUT && entryType != DEAL_ENTRY_INOUT) continue;

         string dSym  = HistoryDealGetString(dt, DEAL_SYMBOL);
         if(StringLen(dSym) == 0) continue;
         double dProf = HistoryDealGetDouble(dt, DEAL_PROFIT) + HistoryDealGetDouble(dt, DEAL_SWAP) + HistoryDealGetDouble(dt, DEAL_COMMISSION);
         double dVol  = HistoryDealGetDouble(dt, DEAL_VOLUME);
         double dPrc  = HistoryDealGetDouble(dt, DEAL_PRICE);
         long   dTime = HistoryDealGetInteger(dt, DEAL_TIME);
         long   dType = HistoryDealGetInteger(dt, DEAL_TYPE);

         closedCount++;
         realizedPnl += dProf;
         if(dProf >= 0.0) winCount++;
         else             lossCount++;

         if(histExported < 12)
         {
            if(!firstHist) histJson += ",";
            firstHist = false;
            histExported++;
            histJson += StringFormat(
               "{\"ticket\":%I64u,\"broker\":\"%s\",\"symbol\":\"%s\",\"side\":\"%s\",\"lot\":%.3f,\"closePrice\":%.4f,\"profit\":%.2f,\"time\":%I64d}",
               dt, broker, dSym, (dType == DEAL_TYPE_SELL ? "BUY" : "SELL"), dVol, dPrc, dProf, dTime
            );
         }
      }
   }
   histJson += "]";

   double winRatePct = (closedCount > 0) ? ((double)winCount / (double)closedCount) * 100.0 : 0.0;
   double refCap     = MathMax(g_dayStartEquity, bal);
   double dailyDdPct = (refCap > 0.0 && eq < refCap) ? (((refCap - eq) / refCap) * 100.0) : 0.0;

   double curAdaptivePct = InpRiskPercent;
   string curAdaptiveMode = "STANDARD_1.00%";
   int    curStreak = 0;
   GetAccountStreakAndAdaptiveRisk(_Symbol, true, 2.6, curAdaptivePct, curAdaptiveMode, curStreak);

   string tierName = ""; double tierBaseRisk = 1.0, tierMaxRisk = 2.5, tierDdCap = 4.0, tierProfitLock = 5.0;
   int tierMaxTrades = InpMaxOpenTrades;
   GetAccountGrowthTier(eq > 0 ? eq : bal, tierName, tierBaseRisk, tierMaxRisk, tierMaxTrades, tierDdCap, tierProfitLock);
   double dayGainPct = (g_dayStartEquity > 0.0 && eq > g_dayStartEquity) ? (((eq - g_dayStartEquity) / g_dayStartEquity) * 100.0) : 0.0;

   string stateJson = StringFormat(
      "{\"broker\":\"%s\",\"login\":%I64d,\"server\":\"%s\",\"balance\":%.2f,\"equity\":%.2f,\"freeMargin\":%.2f,\"floatingPnl\":%.2f,\"realizedPnl\":%.2f,\"closedCount\":%d,\"winCount\":%d,\"lossCount\":%d,\"winRatePct\":%.1f,\"dailyDdPct\":%.2f,\"dailyProfitPct\":%.2f,\"partialTpCount\":%d,\"adaptiveRiskPct\":%.2f,\"adaptiveMode\":\"%s\",\"currentStreak\":%d,\"tierName\":\"%s\",\"tierMaxRiskPct\":%.2f,\"tierMaxTrades\":%d,\"tierProfitLockPct\":%.2f,\"updated\":%I64d,\"orders\":%s,\"history\":%s}",
      broker, login, srv, bal, eq, margin, floatingPnl, realizedPnl, closedCount, winCount, lossCount, winRatePct, dailyDdPct, dayGainPct, g_partialClosedCount, curAdaptivePct, curAdaptiveMode, curStreak, tierName, tierMaxRisk, tierMaxTrades, tierProfitLock, (long)TimeCurrent(), posJson, histJson
   );

   string brokerFile = IsWeltradeBroker() ? "smc_bridge\\account_weltrade.json" : "smc_bridge\\account_deriv.json";
   int fhB = FileOpen(brokerFile, FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_COMMON);
   if(fhB != INVALID_HANDLE)
   {
      FileWriteString(fhB, stateJson);
      FileClose(fhB);
   }

   if(login > 0)
   {
      string loginFile = "smc_bridge\\account_" + IntegerToString(login) + ".json";
      int fhL = FileOpen(loginFile, FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_COMMON);
      if(fhL != INVALID_HANDLE)
      {
         FileWriteString(fhL, stateJson);
         FileClose(fhL);
      }
   }

   int fh = FileOpen("smc_bridge\\account_state.json", FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_COMMON);
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
   int fh = FileOpen(qFile, FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_COMMON);
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
      int fileHandle = FileOpen(filePath, FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_COMMON);
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

   int fh = FileOpen(cmdPath, FILE_READ | FILE_TXT | FILE_ANSI | FILE_COMMON);
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

   long login = AccountInfoInteger(ACCOUNT_LOGIN);
   if(login > 0)
   {
      string clientQueue = "smc_bridge\\commands_" + IntegerToString(login) + ".txt";
      ProcessQueueFile(clientQueue);
   }
}

//+------------------------------------------------------------------+
//| Read Active Symbol Requested by Browser for Instant 1s Priority  |
//+------------------------------------------------------------------+
string GetActivePrioritySymbol()
{
   string activeFile = IsWeltradeBroker() ? "smc_bridge\\active_weltrade.txt" : "smc_bridge\\active_deriv.txt";
   if(!FileIsExist(activeFile, FILE_COMMON)) return _Symbol;

   int fh = FileOpen(activeFile, FILE_READ | FILE_TXT | FILE_ANSI | FILE_COMMON);
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
