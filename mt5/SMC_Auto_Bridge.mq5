//+------------------------------------------------------------------+
//|                                              SMC_Auto_Bridge.mq5 |
//|   Price Action & Continuous Self-Learning Quant Auto-Desk v5.10  |
//|   Pure Price Action: Double Tops/Bottoms, Rising & Falling Wedges |
//|   Online Learning Brain + Bayesian Smoothed Alpha Performance    |
//+------------------------------------------------------------------+
#property copyright "SMC Desk — Price Action & Online Learning Engine"
#property version   "5.10"
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
input bool   InpQuickScalpCloseOnProfit = true; // Auto-Bank & Close Quick Scalps immediately when green
input double InpQuickScalpMinProfitUsd  = 0.50; // Minimum net profit ($) to auto-close Quick Scalp trade
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
//| Continuous Online Learning & Pattern Expectancy Matrix Structs  |
//+------------------------------------------------------------------+
struct SPatternStats
{
   string   name;
   int      totalDeals;
   int      wins;
   int      losses;
   double   netPnl;
   double   winRate;
   double   expectancyR;
   double   adaptiveMultiplier;
   int      consecutiveLosses;
   bool     isQuarantined;
   datetime quarantineExpiry;
};

struct SSymbolStats
{
   string   symbol;
   int      totalDeals;
   int      wins;
   int      losses;
   double   netPnl;
   double   winRate;
   double   bayesianWinRate;
   bool     isAlpha;
   bool     isQuarantined;
   datetime quarantineExpiry;
};

SPatternStats g_patterns[4];
SSymbolStats  g_symbolStats[];
int           g_symbolStatsCount = 0;
datetime      g_lastBrainUpdate  = 0;

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

   // Initialize Online Learning Pattern Structs
   g_patterns[0].name = "DOUBLE_TOP";     g_patterns[0].adaptiveMultiplier = 1.0; g_patterns[0].isQuarantined = false; g_patterns[0].quarantineExpiry = 0;
   g_patterns[1].name = "DOUBLE_BOTTOM";  g_patterns[1].adaptiveMultiplier = 1.0; g_patterns[1].isQuarantined = false; g_patterns[1].quarantineExpiry = 0;
   g_patterns[2].name = "RISING_WEDGE";   g_patterns[2].adaptiveMultiplier = 1.0; g_patterns[2].isQuarantined = false; g_patterns[2].quarantineExpiry = 0;
   g_patterns[3].name = "FALLING_WEDGE";  g_patterns[3].adaptiveMultiplier = 1.0; g_patterns[3].isQuarantined = false; g_patterns[3].quarantineExpiry = 0;

   InitBrokerSymbols();
   EventSetTimer(1); // 1-second real-time tick & active chart sync

   Print("=================================================================");
   Print("Price Action & Online Self-Learning Bridge v5.10 initialized");
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
   if(equity < 25.0)
   {
      // $4 -> $50 in 1 Week Nano Challenge Blueprint (~+44% daily compound with 1 sniper trade at a time)
      outTierName           = "TIER_0_NANO_CHALLENGE ($4->$50)";
      outBaseRiskPct        = 10.00;
      outMaxRiskPct         = 24.00;
      outMaxTrades          = 1;
      outDailyLossCapPct    = 28.00;
      outDailyProfitLockPct = 55.00;
   }
   else if(equity < 100.0)
   {
      outTierName           = "TIER_1_MICRO_SEED ($25-$99)";
      outBaseRiskPct        = 3.50;
      outMaxRiskPct         = 8.00;
      outMaxTrades          = 2;
      outDailyLossCapPct    = 10.00;
      outDailyProfitLockPct = 35.00;
   }
   else if(equity < 250.0)
   {
      outTierName           = "TIER_2_MICRO_ELEVATION ($100-$249)";
      outBaseRiskPct        = 1.25;
      outMaxRiskPct         = 2.50;
      outMaxTrades          = 2;
      outDailyLossCapPct    = 4.00;
      outDailyProfitLockPct = 15.00;
   }
   else if(equity < 500.0)
   {
      outTierName           = "TIER_3_GROWTH_STARTER ($250-$499)";
      outBaseRiskPct        = 1.00;
      outMaxRiskPct         = 2.00;
      outMaxTrades          = 2;
      outDailyLossCapPct    = 3.50;
      outDailyProfitLockPct = 10.00;
   }
   else if(equity < 2500.0)
   {
      outTierName           = "TIER_4_INSTITUTIONAL ($500-$2,499)";
      outBaseRiskPct        = InpRiskPercent;
      outMaxRiskPct         = 2.20;
      outMaxTrades          = InpMaxOpenTrades;
      outDailyLossCapPct    = 3.50;
      outDailyProfitLockPct = 6.50;
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

   // Dynamic ML Deal History Quarantine: If symbol has >= 3 closed deals in last 14 days with < 30% win rate and net loss
   if(HistorySelect(TimeCurrent() - 14 * 86400, TimeCurrent()))
   {
      int symDeals = 0, symWins = 0;
      double symNetPnl = 0.0;
      int totalD = HistoryDealsTotal();
      for(int d = totalD - 1; d >= 0; d--)
      {
         ulong dt = HistoryDealGetTicket(d);
         if(dt == 0) continue;
         long entryT = HistoryDealGetInteger(dt, DEAL_ENTRY);
         if(entryT != DEAL_ENTRY_OUT && entryT != DEAL_ENTRY_INOUT) continue;
         if(HistoryDealGetString(dt, DEAL_SYMBOL) != sym) continue;
         double p = HistoryDealGetDouble(dt, DEAL_PROFIT) + HistoryDealGetDouble(dt, DEAL_SWAP) + HistoryDealGetDouble(dt, DEAL_COMMISSION);
         symDeals++;
         symNetPnl += p;
         if(p >= 0.0) symWins++;
      }
      if(symDeals >= 3 && ((double)symWins / (double)symDeals) < 0.30 && symNetPnl < -1.0)
      {
         outBlockReason = StringFormat("ML Live Deal Quarantine: Blocked %s (%d/%d wins, Net $%.2f in last 14d)", sym, symWins, symDeals, symNetPnl);
         return false;
      }
   }

   // Micro-Safe Whitelist Guard for Small Accounts (< $50)
   if(equity < 50.0)
   {
      // Prohibit dangerous/high-tick instruments that can gap/spike
      if(StringFind(up, "JUMP") >= 0 || StringFind(up, "BOOM") >= 0 || 
         StringFind(up, "CRASH") >= 0 || StringFind(up, "STEP") >= 0 ||
         StringFind(up, "RANGE BREAK") >= 0 || StringFind(up, "DEX") >= 0 ||
         StringFind(up, "PAINX") >= 0 || StringFind(up, "GAINX") >= 0 ||
         StringFind(up, "BREAKX") >= 0 || StringFind(up, "SWITCHX") >= 0)
      {
         outBlockReason = StringFormat("Micro Account ($%.2f < $50): %s blocked (Jump/Boom/Crash/Step/Spike excluded)", equity, sym);
         return false;
      }

      // Explicitly allow only micro-safe volatility synthetics and major forex
      bool isAllowedMicro = (StringFind(up, "VOLATILITY 75 (1S)") >= 0 ||
                             StringFind(up, "VOLATILITY 10 (1S)") >= 0 ||
                             StringFind(up, "VOLATILITY 50 (1S)") >= 0 ||
                             StringFind(up, "VOLATILITY 100 (1S)") >= 0 ||
                             StringFind(up, "VOLATILITY 25 (1S)") >= 0 ||
                             StringFind(up, "VOLATILITY 75 INDEX") >= 0 ||
                             StringFind(up, "VOLATILITY 10 INDEX") >= 0 ||
                             StringFind(up, "EURUSD") >= 0 ||
                             StringFind(up, "USDJPY") >= 0 ||
                             StringFind(up, "GBPUSD") >= 0);
      if(!isAllowedMicro)
      {
         outBlockReason = StringFormat("Micro Account ($%.2f < $50): %s not on micro-safe whitelist", equity, sym);
         return false;
      }
   }
   // Tier 1 ($50 - $99): Block heavy tick-value / high-margin indices
   else if(equity < 100.0)
   {
      if(StringFind(up, "SFX VOL 80") >= 0 || StringFind(up, "SFX VOL 99") >= 0 ||
         StringFind(up, "GAINX 1200") >= 0 ||
         StringFind(up, "MAX PAINX 2000") >= 0 || StringFind(up, "MAX GAINX 2000") >= 0 ||
         StringFind(up, "BREAKX 1800") >= 0 || StringFind(up, "SWITCHX 1800") >= 0 ||
         StringFind(up, "JUMP 100") >= 0 || StringFind(up, "JUMP 75") >= 0 || StringFind(up, "JUMP 50") >= 0 ||
         StringFind(up, "VOLATILITY 100 INDEX") >= 0 || StringFind(up, "VOLATILITY 250") >= 0 || StringFind(up, "VOLATILITY 200") >= 0)
      {
         outBlockReason = StringFormat("Balance-Tier Shield ($%.2f < $100): Blocked heavy index %s", equity, sym);
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
   bool isPatternTrade = (StringFind(comment, "PA_") >= 0 || StringFind(comment, "PATTERN") >= 0 ||
                          StringFind(comment, "DOUBLE") >= 0 || StringFind(comment, "WEDGE") >= 0 ||
                          StringFind(comment, "APLUS") >= 0 || StringFind(comment, "A+") >= 0);
   bool isQuickScalp   = (StringFind(comment, "SCALP") >= 0);

   if(!isPatternTrade && !isQuickScalp)
   {
      outReason = "Trade Blocked (Requires Double Top/Bottom, Rising/Falling Wedge, or Quick Scalp)";
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

   // Online Learning Brain Dynamic Symbol Quarantine Guard
   for(int sq = 0; sq < g_symbolStatsCount; sq++)
   {
      if(g_symbolStats[sq].symbol == sym)
      {
         if(g_symbolStats[sq].isQuarantined && TimeCurrent() < g_symbolStats[sq].quarantineExpiry)
         {
            outReason = StringFormat("ML Brain Dynamic Quarantine: Blocked %s (WinRate=%.1f%%, Net=$%.2f)",
                                     sym, g_symbolStats[sq].winRate, g_symbolStats[sq].netPnl);
            return false;
         }
         break;
      }
   }

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

   double effectivePct = (equity < 100.0) ? tierBaseRisk : MathMin(outAdaptivePct, tierBaseRisk * 1.35);
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
      double nanoAllowedUsd = (equity < 25.0) ? MathMax(1.05, equity * 0.25) : ((equity < 100.0) ? MathMax(2.25, equity * 0.08) : 0.0);
      if(minLotRiskPct > tierMaxRisk && minLotLoss > nanoAllowedUsd)
      {
         Print("SMC_Auto_Bridge [", tierName, " SHIELD] Blocked ", sym, ": Min lot (", volMin,
               ") risks $", DoubleToString(minLotLoss, 2), " (", DoubleToString(minLotRiskPct, 2),
               "% > Tier Max ", DoubleToString(tierMaxRisk, 2), "%)");
         return 0.0;
      }
      snappedLots = volMin;
   }
   if(snappedLots > volMax) snappedLots = volMax;

   // Hard Anti-Overleverage Cap: Never allow tight stop distances to explode lot size (e.g. 43 lots on V10)
   if(equity < 35.0)
   {
      snappedLots = volMin; // Strictly 1 minimum micro-lot on $4-$35 accounts
   }
   else
   {
      double maxSafeMult = MathMax(2.0, MathMin(15.0, equity / 250.0));
      double maxSafeLots = NormalizeDouble(MathFloor((volMin * maxSafeMult) / volStep) * volStep, 3);
      if(maxSafeLots < volMin) maxSafeLots = volMin;
      if(snappedLots > maxSafeLots)
         snappedLots = maxSafeLots;
   }

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

   double point = SymbolInfoDouble(sym, SYMBOL_POINT);
   int stopsLvl = (int)SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL);
   double minStopDist = MathMax((double)stopsLvl * point, point * 10.0);

   // Smart Nano Stop-Loss Clamping for $4 -> $50 Challenge Accounts (equity < $50)
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity <= 0.0) equity = AccountInfoDouble(ACCOUNT_BALANCE);
   if(equity > 0.0 && equity < 50.0)
   {
      double volMin = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
      if(volMin <= 0.0) volMin = 0.01;
      double minLotLoss = 0.0;
      ENUM_ORDER_TYPE cType = isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
      if(OrderCalcProfit(cType, sym, volMin, entry, sl, minLotLoss))
         minLotLoss = MathAbs(minLotLoss);
      double maxNanoRiskUsd = (equity < 25.0) ? MathMax(1.25, equity * 0.15) : MathMax(1.85, equity * 0.06);
      if(minLotLoss > maxNanoRiskUsd && minLotLoss > 0.0)
      {
         double scale = maxNanoRiskUsd / minLotLoss;
         double clampedDist = MathMax(riskDist * scale, minStopDist * 1.6);
         if(clampedDist < riskDist)
         {
            sl = NormalizePrice(sym, isBuy ? (entry - clampedDist) : (entry + clampedDist));
            riskDist = MathAbs(entry - sl);
            Print("SMC_Auto_Bridge [NANO SL CLAMP] Tightened ", sym, " SL to ", sl, " to cap min-lot risk near $", DoubleToString(maxNanoRiskUsd, 2), " on $", DoubleToString(equity, 2), " account");
         }
         // Verify post-clamp risk; if broker minimum stop distance still forces >$1.80 risk on a $10 account (e.g. SFX Vol 60), hard-block!
         double postClampLoss = 0.0;
         if(OrderCalcProfit(cType, sym, volMin, entry, sl, postClampLoss))
            postClampLoss = MathAbs(postClampLoss);
         if(postClampLoss > maxNanoRiskUsd * 1.35)
         {
            Print("SMC_Auto_Bridge [$10 SHIELD] Blocked ", sym, ": Even at minimum stop distance, min lot risks $", DoubleToString(postClampLoss, 2));
            return false;
         }
      }
   }

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
      double curNetPnl  = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      string posComm    = PositionGetString(POSITION_COMMENT);

      // ===================================================================
      // 0. QUICK SCALP AUTO-BANKER: Close instantly when in profit
      // If position has "SCALP" comment and is green (+$0.50+ or >= +0.50R)
      // ===================================================================
      if(InpQuickScalpCloseOnProfit && StringFind(posComm, "SCALP") >= 0)
      {
         if(curNetPnl >= InpQuickScalpMinProfitUsd || currentR >= 0.50)
         {
            ConfigureSymbolFilling(sym);
            if(g_trade.PositionClose(ticket))
            {
               Print("SMC_Auto_Bridge [QUICK SCALP BANKED] Ticket #", ticket, " (", sym,
                     "): Closed in GREEN Profit! Net=+$", DoubleToString(curNetPnl, 2),
                     " (R=+", DoubleToString(currentR, 2), ") Comment=", posComm);
               continue;
            }
         }
      }

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
      // Nano Challenge (<$50): Jumps SL to Breakeven+ at +0.50R or +$0.35
      // Standard Accounts: Jumps SL to Breakeven+ at +0.65R
      // Stage 2: Ratchet SL to +0.35R profit lock at +1.10R
      // Stage 3: Ratchet SL to +0.85R profit lock at +1.65R
      // ===================================================================
      double accEq = AccountInfoDouble(ACCOUNT_EQUITY);
      bool isNanoAcc = (accEq > 0.0 && accEq < 55.0);
      bool triggerBeArmor = isNanoAcc ? (currentR >= 0.40 || curNetPnl >= 0.25) : (currentR >= 0.60);

      if(triggerBeArmor)
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

      if(currentR >= (isNanoAcc ? 0.90 : 1.10))
      {
         double lock12 = isBuy ? (openP + initRisk * 0.40) : (openP - initRisk * 0.40);
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

      if(currentR >= (isNanoAcc ? 1.40 : 1.65))
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
//| Price Action Technical Indicators (Fast In-Memory RSI & EMA)    |
//+------------------------------------------------------------------+
double CalculateRSI(const MqlRates &rates[], int idx, int period = 14)
{
   if(idx < period + 1) return 50.0;
   double gains = 0.0, losses = 0.0;
   for(int i = idx - period + 1; i <= idx; i++)
   {
      double diff = rates[i].close - rates[i-1].close;
      if(diff > 0.0) gains += diff;
      else losses -= diff;
   }
   double avgGain = gains / (double)period;
   double avgLoss = losses / (double)period;
   if(avgLoss <= 1e-12) return 100.0;
   if(avgGain <= 1e-12) return 0.0;
   double rs = avgGain / avgLoss;
   return 100.0 - (100.0 / (1.0 + rs));
}

double CalculateEMA(const MqlRates &rates[], int idx, int period = 50)
{
   if(idx < 5) return rates[idx].close;
   int p = MathMin(period, idx);
   double k = 2.0 / (p + 1.0);
   int start = MathMax(0, idx - p * 2);
   double ema = rates[start].close;
   for(int i = start + 1; i <= idx; i++)
   {
      ema = (rates[i].close * k) + (ema * (1.0 - k));
   }
   return ema;
}

//+------------------------------------------------------------------+
//| Volatility Regime Detector: ATR(14) vs SMA_ATR(50)               |
//| Distinguishes between dead chop, expansion momentum, and chaos   |
//+------------------------------------------------------------------+
double GetVolatilityRegimeRatio(const string sym, ENUM_TIMEFRAMES tf)
{
   MqlRates r[];
   ArraySetAsSeries(r, true);
   int copied = CopyRates(sym, tf, 0, 55, r);
   if(copied < 40) return 1.0;

   double atr14 = 0.0;
   for(int i = 0; i < 14; i++)
      atr14 += (r[i].high - r[i].low);
   atr14 /= 14.0;

   double atr50 = 0.0;
   for(int i = 0; i < copied; i++)
      atr50 += (r[i].high - r[i].low);
   atr50 /= (double)copied;

   if(atr50 <= 1e-12) return 1.0;
   return (atr14 / atr50);
}

//+------------------------------------------------------------------+
//| Export ML Brain State to Common Bridge File (smc_bridge\ml_brain.json)|
//+------------------------------------------------------------------+
void ExportMLBrainJson()
{
   string json = "{\n";
   json += "  \"version\": \"5.10_ONLINE_LEARNING\",\n";
   json += "  \"updated\": " + IntegerToString((long)TimeCurrent()) + ",\n";
   json += "  \"patterns\": [\n";
   for(int p = 0; p < 4; p++)
   {
      if(p > 0) json += ",\n";
      json += StringFormat("    {\"name\":\"%s\",\"deals\":%d,\"wins\":%d,\"losses\":%d,\"winRate\":%.1f,\"expectancyR\":%.2f,\"multiplier\":%.2f,\"quarantined\":%s}",
                           g_patterns[p].name, g_patterns[p].totalDeals, g_patterns[p].wins, g_patterns[p].losses,
                           g_patterns[p].winRate, g_patterns[p].expectancyR, g_patterns[p].adaptiveMultiplier,
                           (g_patterns[p].isQuarantined ? "true" : "false"));
   }
   json += "\n  ],\n";

   json += "  \"alphaSymbols\": [";
   bool firstAlpha = true;
   for(int s = 0; s < g_symbolStatsCount; s++)
   {
      if(g_symbolStats[s].isAlpha)
      {
         if(!firstAlpha) json += ",";
         firstAlpha = false;
         json += StringFormat("{\"symbol\":\"%s\",\"deals\":%d,\"winRate\":%.1f,\"netPnl\":%.2f}",
                              g_symbolStats[s].symbol, g_symbolStats[s].totalDeals, g_symbolStats[s].winRate, g_symbolStats[s].netPnl);
      }
   }
   json += "],\n";

   json += "  \"quarantinedSymbols\": [";
   bool firstQ = true;
   for(int s = 0; s < g_symbolStatsCount; s++)
   {
      if(g_symbolStats[s].isQuarantined)
      {
         if(!firstQ) json += ",";
         firstQ = false;
         json += "\"" + g_symbolStats[s].symbol + "\"";
      }
   }
   json += "]\n";
   json += "}";

   int fh = FileOpen("smc_bridge\\ml_brain.json", FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_COMMON);
   if(fh != INVALID_HANDLE)
   {
      FileWriteString(fh, json);
      FileClose(fh);
   }
}

//+------------------------------------------------------------------+
//| Continuous Online Learning Brain: Recalculate Weights from History|
//+------------------------------------------------------------------+
void UpdateOnlineLearningBrain()
{
   if(TimeCurrent() - g_lastBrainUpdate < 15) return;
   g_lastBrainUpdate = TimeCurrent();

   // Reset counters
   for(int p = 0; p < 4; p++)
   {
      g_patterns[p].totalDeals = 0;
      g_patterns[p].wins = 0;
      g_patterns[p].losses = 0;
      g_patterns[p].netPnl = 0.0;
   }

   // Initialize / reset symbol stats
   if(g_symbolStatsCount != g_brokerSymCount)
   {
      ArrayResize(g_symbolStats, g_brokerSymCount);
      g_symbolStatsCount = g_brokerSymCount;
      for(int s = 0; s < g_symbolStatsCount; s++)
      {
         g_symbolStats[s].symbol = g_brokerSyms[s];
         g_symbolStats[s].totalDeals = 0;
         g_symbolStats[s].wins = 0;
         g_symbolStats[s].losses = 0;
         g_symbolStats[s].netPnl = 0.0;
         g_symbolStats[s].winRate = 0.0;
         g_symbolStats[s].bayesianWinRate = 0.50;
         g_symbolStats[s].isAlpha = false;
         g_symbolStats[s].isQuarantined = false;
         g_symbolStats[s].quarantineExpiry = 0;
      }
   }
   else
   {
      for(int s = 0; s < g_symbolStatsCount; s++)
      {
         g_symbolStats[s].totalDeals = 0;
         g_symbolStats[s].wins = 0;
         g_symbolStats[s].losses = 0;
         g_symbolStats[s].netPnl = 0.0;
      }
   }

   // Scan past 14 days of closed deals
   if(HistorySelect(TimeCurrent() - 14 * 86400, TimeCurrent()))
   {
      int totalDeals = HistoryDealsTotal();
      for(int d = totalDeals - 1; d >= 0; d--)
      {
         ulong dt = HistoryDealGetTicket(d);
         if(dt == 0) continue;
         long entryType = HistoryDealGetInteger(dt, DEAL_ENTRY);
         if(entryType != DEAL_ENTRY_OUT && entryType != DEAL_ENTRY_INOUT) continue;

         string sym = HistoryDealGetString(dt, DEAL_SYMBOL);
         if(StringLen(sym) == 0) continue;

         double pnl = HistoryDealGetDouble(dt, DEAL_PROFIT) + HistoryDealGetDouble(dt, DEAL_SWAP) + HistoryDealGetDouble(dt, DEAL_COMMISSION);
         string comm = HistoryDealGetString(dt, DEAL_COMMENT);
         StringToUpper(comm);

         // Map deal to pattern
         int pIdx = -1;
         if(StringFind(comm, "DOUBLE_TOP") >= 0 || StringFind(comm, "PA_DT") >= 0) pIdx = 0;
         else if(StringFind(comm, "DOUBLE_BOTTOM") >= 0 || StringFind(comm, "PA_DB") >= 0) pIdx = 1;
         else if(StringFind(comm, "RISING_WEDGE") >= 0 || StringFind(comm, "PA_RW") >= 0) pIdx = 2;
         else if(StringFind(comm, "FALLING_WEDGE") >= 0 || StringFind(comm, "PA_FW") >= 0) pIdx = 3;

         if(pIdx >= 0)
         {
            g_patterns[pIdx].totalDeals++;
            g_patterns[pIdx].netPnl += pnl;
            if(pnl >= 0.0) g_patterns[pIdx].wins++;
            else           g_patterns[pIdx].losses++;
         }

         // Map deal to symbol
         for(int s = 0; s < g_symbolStatsCount; s++)
         {
            if(g_symbolStats[s].symbol == sym)
            {
               g_symbolStats[s].totalDeals++;
               g_symbolStats[s].netPnl += pnl;
               if(pnl >= 0.0) g_symbolStats[s].wins++;
               else           g_symbolStats[s].losses++;
               break;
            }
         }
      }
   }

   // Recalculate Bayesian Win Rates, Expectancy and Multipliers
   for(int p = 0; p < 4; p++)
   {
      int deals = g_patterns[p].totalDeals;
      int wins  = g_patterns[p].wins;
      double smoothWr = ((double)wins + 2.0) / ((double)deals + 4.0);
      g_patterns[p].winRate = (deals > 0) ? (((double)wins / (double)deals) * 100.0) : 50.0;
      g_patterns[p].expectancyR = (smoothWr * 2.20) - ((1.0 - smoothWr) * 0.70);

      // Adaptive Multiplier: Boost high-performing patterns, penalize lagging patterns
      if(deals >= 2)
      {
         if(smoothWr >= 0.65 && g_patterns[p].netPnl > 0.0)
            g_patterns[p].adaptiveMultiplier = 1.18; // +18% score boost
         else if(smoothWr >= 0.55)
            g_patterns[p].adaptiveMultiplier = 1.08; // +8% score boost
         else if(smoothWr <= 0.38)
            g_patterns[p].adaptiveMultiplier = 0.82; // -18% score penalty
         else
            g_patterns[p].adaptiveMultiplier = 1.00;
      }
      else
      {
         g_patterns[p].adaptiveMultiplier = 1.00;
      }

      // Dynamic quarantine check: if >= 3 deals with winRate < 25% and netPnl < -$5.00
      if(deals >= 3 && g_patterns[p].winRate < 25.0 && g_patterns[p].netPnl < -5.0)
      {
         g_patterns[p].isQuarantined = true;
         g_patterns[p].quarantineExpiry = TimeCurrent() + 7200; // 2 hour quarantine
      }
      else if(g_patterns[p].isQuarantined && TimeCurrent() > g_patterns[p].quarantineExpiry)
      {
         g_patterns[p].isQuarantined = false;
      }
   }

   // Recalculate Symbol Stats and Alpha Classification
   for(int s = 0; s < g_symbolStatsCount; s++)
   {
      int deals = g_symbolStats[s].totalDeals;
      int wins  = g_symbolStats[s].wins;
      double bayesWr = ((double)wins + 2.0) / ((double)deals + 4.0);
      g_symbolStats[s].bayesianWinRate = bayesWr;
      g_symbolStats[s].winRate = (deals > 0) ? (((double)wins / (double)deals) * 100.0) : 50.0;

      // Alpha Tier A: Proven winning synthetic
      if(deals >= 2 && bayesWr >= 0.58 && g_symbolStats[s].netPnl > 0.0)
         g_symbolStats[s].isAlpha = true;
      else
         g_symbolStats[s].isAlpha = false;

      // Symbol quarantine
      if(deals >= 3 && g_symbolStats[s].winRate < 30.0 && g_symbolStats[s].netPnl < -5.0)
      {
         g_symbolStats[s].isQuarantined = true;
         g_symbolStats[s].quarantineExpiry = TimeCurrent() + 14400; // 4 hour quarantine
      }
      else if(g_symbolStats[s].isQuarantined && TimeCurrent() > g_symbolStats[s].quarantineExpiry)
      {
         g_symbolStats[s].isQuarantined = false;
      }
   }

   // Export ml_brain.json
   ExportMLBrainJson();
}

bool IsPatternQuarantined(int patternIdx)
{
   if(patternIdx < 0 || patternIdx >= 4) return false;
   if(g_patterns[patternIdx].isQuarantined && TimeCurrent() < g_patterns[patternIdx].quarantineExpiry)
      return true;
   return false;
}

double GetPatternMultiplier(int patternIdx)
{
   if(patternIdx < 0 || patternIdx >= 4) return 1.0;
   return g_patterns[patternIdx].adaptiveMultiplier;
}

bool IsSymbolAlphaTier(const string sym)
{
   for(int s = 0; s < g_symbolStatsCount; s++)
   {
      if(g_symbolStats[s].symbol == sym)
         return g_symbolStats[s].isAlpha;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Price Action Pattern Detection Engine                            |
//| Patterns: Double Top, Double Bottom, Rising Wedge, Falling Wedge |
//| Confluence: RSI Regular Divergence + EMA(50) Macro Trend Filter |
//| Confluence: M15 Macro Confirmation + ATR Volatility Regime Filter|
//| Online Learning: Dynamic Pattern Multiplier + Alpha Symbol Boost |
//+------------------------------------------------------------------+

// 1. Double Top Pattern (Bearish Reversal / "M" Formation)
bool DetectDoubleTop(const string sym, const MqlRates &rates[], int totalBars, double atr,
                     double &outEntry, double &outSl, double &outTp, double &outScore, string &outTag)
{
   if(totalBars < 40 || atr <= 0.0) return false;
   if(IsCounterSpikeTrade(sym, false)) return false; // Sells blocked on Boom indices
   if(IsPatternQuarantined(0)) return false; // Online Learning pattern quarantine

   int curBar = totalBars - 1;
   double curPrice = rates[curBar].close;

   // Real body pureness check: ensure current trigger candle has decisive real body (no dojis)
   double barRange = rates[curBar].high - rates[curBar].low;
   if(barRange <= 0.0) return false;
   double bodySize = MathAbs(rates[curBar].close - rates[curBar].open);
   double bodyRatio = bodySize / barRange;
   if(bodyRatio < 0.25) return false; // Reject doji / indecision candle

   // Identify recent swing highs in last 45 bars
   int p1Idx = -1, p2Idx = -1;
   double p1Price = -1e18, p2Price = -1e18;

   for(int i = curBar - 2; i >= MathMax(3, curBar - 45); i--)
   {
      bool isHigh = (rates[i].high > rates[i-1].high && rates[i].high > rates[i-2].high &&
                     rates[i].high >= rates[i+1].high && rates[i].high >= rates[i+2].high);
      if(isHigh)
      {
         if(p2Idx < 0)
         {
            p2Idx = i;
            p2Price = rates[i].high;
         }
         else if(p1Idx < 0 && (p2Idx - i) >= 4)
         {
            p1Idx = i;
            p1Price = rates[i].high;
            break;
         }
      }
   }

   if(p1Idx < 0 || p2Idx < 0) return false;

   // Find Neckline (lowest low between Peak 1 and Peak 2)
   int neckIdx = p1Idx;
   double neckPrice = 1e18;
   for(int k = p1Idx + 1; k < p2Idx; k++)
   {
      if(rates[k].low < neckPrice)
      {
         neckPrice = rates[k].low;
         neckIdx = k;
      }
   }

   if(neckPrice >= 1e17) return false;

   // Pattern Geometry & Validation Rules
   double patternHeight = MathMax(p1Price, p2Price) - neckPrice;
   if(patternHeight < atr * 0.90) return false;

   double peakDiff = MathAbs(p1Price - p2Price);
   if(peakDiff > atr * 0.38) return false; // Peaks roughly equal within ATR tolerance

   // Invalidation check
   if(curPrice > MathMax(p1Price, p2Price) + atr * 0.20) return false;

   // Execution Triggers
   bool isNeckBreak = (curPrice <= neckPrice + atr * 0.15 && rates[curBar].close < rates[curBar].open);
   bool isPeakRejection = (curPrice < p2Price - atr * 0.30 && rates[curBar].close < rates[curBar].open &&
                           (curBar - p2Idx) <= 8);

   if(!isNeckBreak && !isPeakRejection) return false;

   // 1. Bearish RSI Divergence: Peak 2 RSI is lower than Peak 1 RSI (momentum exhausting)
   double rsiP1 = CalculateRSI(rates, p1Idx, 14);
   double rsiP2 = CalculateRSI(rates, p2Idx, 14);
   bool hasBearishDiv = (rsiP2 <= rsiP1 - 1.0);
   bool isOverbought   = (rsiP1 >= 58.0 || rsiP2 >= 55.0);

   double divScore = 0.0;
   if(hasBearishDiv) divScore += 20.0;
   if(isOverbought)  divScore += 10.0;
   if(rsiP2 > rsiP1 + 6.0) divScore -= 18.0; // Severe Hidden Bullish Divergence penalty

   // 2. Macro EMA(50) Trend Alignment
   double ema50 = CalculateEMA(rates, curBar, 50);
   bool withTrend = (rates[curBar].close <= ema50 + atr * 0.25);
   double trendScore = withTrend ? 15.0 : 0.0;

   // 3. Volatility Regime Bonus/Penalty
   double volRatio = GetVolatilityRegimeRatio(sym, PERIOD_M5);
   double volScore = 0.0;
   if(volRatio >= 0.85 && volRatio <= 1.85) volScore += 10.0; // Institutional expansion zone
   else if(volRatio < 0.70) volScore -= 14.0; // Dead chop guard
   else if(volRatio > 2.30) volScore -= 10.0; // Hyper-spike risk

   // 4. Decisive Real Candle Body Bonus
   double bodyBonus = (bodyRatio >= 0.45) ? 8.0 : 0.0;

   // 5. Alpha Symbol Bonus from Online Learning Brain
   double alphaBonus = IsSymbolAlphaTier(sym) ? 8.0 : 0.0;

   outEntry = curPrice;
   outSl = MathMax(p1Price, p2Price) + atr * 0.25;
   double risk = MathAbs(outSl - outEntry);
   if(risk <= atr * 0.15) risk = atr * 0.35;

   outTp = outEntry - MathMax(patternHeight * 1.25, risk * InpMinRR);
   double rr = MathAbs(outTp - outEntry) / risk;
   if(rr < InpMinRR - 0.05) return false;

   double symmScore   = MathMax(0.0, 1.0 - (peakDiff / (atr * 0.40))) * 25.0;
   double heightScore = MathMin(1.0, patternHeight / (atr * 2.5)) * 20.0;
   double trigScore   = isNeckBreak ? 18.0 : 12.0;

   double rawScore = symmScore + heightScore + trigScore + divScore + trendScore + volScore + bodyBonus + alphaBonus;
   double mult = GetPatternMultiplier(0);
   outScore = MathMin(99.0, MathMax(0.0, rawScore * mult));

   outTag = isNeckBreak ? "DOUBLE_TOP_NECK_BREAK" : "DOUBLE_TOP_PEAK_REJECT";
   if(hasBearishDiv) outTag += "_RSI_DIV";

   return (outScore >= 82.0); // Strict elite quality threshold
}

// 2. Double Bottom Pattern (Bullish Reversal / "W" Formation)
bool DetectDoubleBottom(const string sym, const MqlRates &rates[], int totalBars, double atr,
                        double &outEntry, double &outSl, double &outTp, double &outScore, string &outTag)
{
   if(totalBars < 40 || atr <= 0.0) return false;
   if(IsCounterSpikeTrade(sym, true)) return false; // Buys blocked on Crash indices
   if(IsPatternQuarantined(1)) return false; // Online Learning pattern quarantine

   int curBar = totalBars - 1;
   double curPrice = rates[curBar].close;

   // Real body pureness check: ensure current trigger candle has decisive real body (no dojis)
   double barRange = rates[curBar].high - rates[curBar].low;
   if(barRange <= 0.0) return false;
   double bodySize = MathAbs(rates[curBar].close - rates[curBar].open);
   double bodyRatio = bodySize / barRange;
   if(bodyRatio < 0.25) return false; // Reject doji / indecision candle

   // Identify recent swing lows in last 45 bars
   int t1Idx = -1, t2Idx = -1;
   double t1Price = 1e18, t2Price = 1e18;

   for(int i = curBar - 2; i >= MathMax(3, curBar - 45); i--)
   {
      bool isLow = (rates[i].low < rates[i-1].low && rates[i].low < rates[i-2].low &&
                    rates[i].low <= rates[i+1].low && rates[i].low <= rates[i+2].low);
      if(isLow)
      {
         if(t2Idx < 0)
         {
            t2Idx = i;
            t2Price = rates[i].low;
         }
         else if(t1Idx < 0 && (t2Idx - i) >= 4)
         {
            t1Idx = i;
            t1Price = rates[i].low;
            break;
         }
      }
   }

   if(t1Idx < 0 || t2Idx < 0) return false;

   // Find Neckline (highest high between Trough 1 and Trough 2)
   int neckIdx = t1Idx;
   double neckPrice = -1e18;
   for(int k = t1Idx + 1; k < t2Idx; k++)
   {
      if(rates[k].high > neckPrice)
      {
         neckPrice = rates[k].high;
         neckIdx = k;
      }
   }

   if(neckPrice <= -1e17) return false;

   double patternHeight = neckPrice - MathMin(t1Price, t2Price);
   if(patternHeight < atr * 0.90) return false;

   double troughDiff = MathAbs(t1Price - t2Price);
   if(troughDiff > atr * 0.38) return false;

   if(curPrice < MathMin(t1Price, t2Price) - atr * 0.20) return false;

   bool isNeckBreak = (curPrice >= neckPrice - atr * 0.15 && rates[curBar].close > rates[curBar].open);
   bool isTroughRejection = (curPrice > t2Price + atr * 0.30 && rates[curBar].close > rates[curBar].open &&
                             (curBar - t2Idx) <= 8);

   if(!isNeckBreak && !isTroughRejection) return false;

   // 1. Bullish RSI Divergence: Trough 2 RSI is higher than Trough 1 RSI (buyers accumulating)
   double rsiT1 = CalculateRSI(rates, t1Idx, 14);
   double rsiT2 = CalculateRSI(rates, t2Idx, 14);
   bool hasBullishDiv = (rsiT2 >= rsiT1 + 1.0);
   bool isOversold    = (rsiT1 <= 42.0 || rsiT2 <= 45.0);

   double divScore = 0.0;
   if(hasBullishDiv) divScore += 20.0;
   if(isOversold)    divScore += 10.0;
   if(rsiT2 < rsiT1 - 6.0) divScore -= 18.0; // Severe Hidden Bearish Divergence penalty

   // 2. Macro EMA(50) Trend Alignment
   double ema50 = CalculateEMA(rates, curBar, 50);
   bool withTrend = (rates[curBar].close >= ema50 - atr * 0.25);
   double trendScore = withTrend ? 15.0 : 0.0;

   // 3. Volatility Regime Bonus/Penalty
   double volRatio = GetVolatilityRegimeRatio(sym, PERIOD_M5);
   double volScore = 0.0;
   if(volRatio >= 0.85 && volRatio <= 1.85) volScore += 10.0;
   else if(volRatio < 0.70) volScore -= 14.0;
   else if(volRatio > 2.30) volScore -= 10.0;

   // 4. Decisive Real Candle Body Bonus
   double bodyBonus = (bodyRatio >= 0.45) ? 8.0 : 0.0;

   // 5. Alpha Symbol Bonus from Online Learning Brain
   double alphaBonus = IsSymbolAlphaTier(sym) ? 8.0 : 0.0;

   outEntry = curPrice;
   outSl = MathMin(t1Price, t2Price) - atr * 0.25;
   double risk = MathAbs(outEntry - outSl);
   if(risk <= atr * 0.15) risk = atr * 0.35;

   outTp = outEntry + MathMax(patternHeight * 1.25, risk * InpMinRR);
   double rr = MathAbs(outTp - outEntry) / risk;
   if(rr < InpMinRR - 0.05) return false;

   double symmScore   = MathMax(0.0, 1.0 - (troughDiff / (atr * 0.40))) * 25.0;
   double heightScore = MathMin(1.0, patternHeight / (atr * 2.5)) * 20.0;
   double trigScore   = isNeckBreak ? 18.0 : 12.0;

   double rawScore = symmScore + heightScore + trigScore + divScore + trendScore + volScore + bodyBonus + alphaBonus;
   double mult = GetPatternMultiplier(1);
   outScore = MathMin(99.0, MathMax(0.0, rawScore * mult));

   outTag = isNeckBreak ? "DOUBLE_BOTTOM_NECK_BREAK" : "DOUBLE_BOTTOM_TROUGH_REJECT";
   if(hasBullishDiv) outTag += "_RSI_DIV";

   return (outScore >= 82.0); // Strict elite quality threshold
}

// 3. Rising Wedge Pattern (Ascending Wedge - Bearish Breakdown)
bool DetectRisingWedge(const string sym, const MqlRates &rates[], int totalBars, double atr,
                      double &outEntry, double &outSl, double &outTp, double &outScore, string &outTag)
{
   if(totalBars < 40 || atr <= 0.0) return false;
   if(IsCounterSpikeTrade(sym, false)) return false;
   if(IsPatternQuarantined(2)) return false; // Online Learning pattern quarantine

   int curBar = totalBars - 1;
   double curPrice = rates[curBar].close;

   // Real body pureness check
   double barRange = rates[curBar].high - rates[curBar].low;
   if(barRange <= 0.0) return false;
   double bodyRatio = MathAbs(rates[curBar].close - rates[curBar].open) / barRange;
   if(bodyRatio < 0.25) return false;

   int h1 = -1, h2 = -1, l1 = -1, l2 = -1;
   double hp1 = 0, hp2 = 0, lp1 = 0, lp2 = 0;

   for(int i = curBar - 2; i >= MathMax(2, curBar - 35); i--)
   {
      if(rates[i].high > rates[i-1].high && rates[i].high >= rates[i+1].high)
      {
         if(h2 < 0) { h2 = i; hp2 = rates[i].high; }
         else if(h1 < 0 && (h2 - i) >= 4) { h1 = i; hp1 = rates[i].high; }
      }
      if(rates[i].low < rates[i-1].low && rates[i].low <= rates[i+1].low)
      {
         if(l2 < 0) { l2 = i; lp2 = rates[i].low; }
         else if(l1 < 0 && (l2 - i) >= 4) { l1 = i; lp1 = rates[i].low; }
      }
      if(h1 >= 0 && h2 >= 0 && l1 >= 0 && l2 >= 0) break;
   }

   if(h1 < 0 || h2 < 0 || l1 < 0 || l2 < 0) return false;

   // Higher Highs & Higher Lows
   if(hp2 <= hp1 || lp2 <= lp1) return false;

   double slopeH = (hp2 - hp1) / (double)(h2 - h1);
   double slopeL = (lp2 - lp1) / (double)(l2 - l1);

   // Convergence: Support line rises steeper than resistance line
   if(slopeL <= slopeH || slopeL <= 0.0 || slopeH <= 0.0) return false;

   double initWidth = MathAbs(hp1 - lp1);
   double apexWidth = MathAbs(hp2 - lp2);
   if(initWidth < atr * 0.90 || apexWidth >= initWidth * 0.90) return false;

   // Breakdown Trigger: Current price breaks below support line
   double supAtNow = lp1 + slopeL * (double)(curBar - l1);
   if(curPrice >= supAtNow + atr * 0.05) return false;
   if(rates[curBar].close >= rates[curBar].open) return false;

   // RSI Bearish Momentum Exhaustion Check
   double rsiH1 = CalculateRSI(rates, h1, 14);
   double rsiH2 = CalculateRSI(rates, h2, 14);
   bool wedgeBearDiv = (rsiH2 <= rsiH1);
   double wedgeDivScore = wedgeBearDiv ? 18.0 : 0.0;

   // Volatility Regime
   double volRatio = GetVolatilityRegimeRatio(sym, PERIOD_M5);
   double volScore = (volRatio >= 0.85 && volRatio <= 1.85) ? 10.0 : ((volRatio < 0.70) ? -14.0 : 0.0);
   double alphaBonus = IsSymbolAlphaTier(sym) ? 8.0 : 0.0;

   outEntry = curPrice;
   outSl = hp2 + atr * 0.25;
   double risk = MathAbs(outSl - outEntry);
   if(risk <= atr * 0.15) risk = atr * 0.35;

   outTp = outEntry - MathMax(initWidth * 1.2, risk * InpMinRR);
   double rr = MathAbs(outTp - outEntry) / risk;
   if(rr < InpMinRR - 0.05) return false;

   double convScore = MathMin(1.0, (slopeL - slopeH) / slopeL) * 25.0;
   double contractScore = MathMin(1.0, (initWidth - apexWidth) / initWidth) * 25.0;

   double rawScore = convScore + contractScore + wedgeDivScore + volScore + alphaBonus + 20.0;
   double mult = GetPatternMultiplier(2);
   outScore = MathMin(99.0, MathMax(0.0, rawScore * mult));

   outTag = "RISING_WEDGE_BREAKDOWN";
   if(wedgeBearDiv) outTag += "_RSI_DIV";

   return (outScore >= 82.0);
}

// 4. Falling Wedge Pattern (Descending Wedge - Bullish Breakout)
bool DetectFallingWedge(const string sym, const MqlRates &rates[], int totalBars, double atr,
                       double &outEntry, double &outSl, double &outTp, double &outScore, string &outTag)
{
   if(totalBars < 40 || atr <= 0.0) return false;
   if(IsCounterSpikeTrade(sym, true)) return false;
   if(IsPatternQuarantined(3)) return false; // Online Learning pattern quarantine

   int curBar = totalBars - 1;
   double curPrice = rates[curBar].close;

   // Real body pureness check
   double barRange = rates[curBar].high - rates[curBar].low;
   if(barRange <= 0.0) return false;
   double bodyRatio = MathAbs(rates[curBar].close - rates[curBar].open) / barRange;
   if(bodyRatio < 0.25) return false;

   int h1 = -1, h2 = -1, l1 = -1, l2 = -1;
   double hp1 = 0, hp2 = 0, lp1 = 0, lp2 = 0;

   for(int i = curBar - 2; i >= MathMax(2, curBar - 35); i--)
   {
      if(rates[i].high > rates[i-1].high && rates[i].high >= rates[i+1].high)
      {
         if(h2 < 0) { h2 = i; hp2 = rates[i].high; }
         else if(h1 < 0 && (h2 - i) >= 4) { h1 = i; hp1 = rates[i].high; }
      }
      if(rates[i].low < rates[i-1].low && rates[i].low <= rates[i+1].low)
      {
         if(l2 < 0) { l2 = i; lp2 = rates[i].low; }
         else if(l1 < 0 && (l2 - i) >= 4) { l1 = i; lp1 = rates[i].low; }
      }
      if(h1 >= 0 && h2 >= 0 && l1 >= 0 && l2 >= 0) break;
   }

   if(h1 < 0 || h2 < 0 || l1 < 0 || l2 < 0) return false;

   // Lower Highs & Lower Lows
   if(hp2 >= hp1 || lp2 >= lp1) return false;

   double slopeH = (hp2 - hp1) / (double)(h2 - h1);
   double slopeL = (lp2 - lp1) / (double)(l2 - l1);

   // Convergence: Resistance falls steeper than support (slopeH < slopeL < 0)
   if(slopeH >= slopeL || slopeH >= 0.0 || slopeL >= 0.0) return false;

   double initWidth = MathAbs(hp1 - lp1);
   double apexWidth = MathAbs(hp2 - lp2);
   if(initWidth < atr * 0.90 || apexWidth >= initWidth * 0.90) return false;

   // Breakout Trigger: Current price breaks above resistance line
   double resAtNow = hp1 + slopeH * (double)(curBar - h1);
   if(curPrice <= resAtNow - atr * 0.05) return false;
   if(rates[curBar].close <= rates[curBar].open) return false;

   // RSI Bullish Momentum Accumulation Check
   double rsiL1 = CalculateRSI(rates, l1, 14);
   double rsiL2 = CalculateRSI(rates, l2, 14);
   bool wedgeBullDiv = (rsiL2 >= rsiL1);
   double wedgeDivScore = wedgeBullDiv ? 18.0 : 0.0;

   // Volatility Regime
   double volRatio = GetVolatilityRegimeRatio(sym, PERIOD_M5);
   double volScore = (volRatio >= 0.85 && volRatio <= 1.85) ? 10.0 : ((volRatio < 0.70) ? -14.0 : 0.0);
   double alphaBonus = IsSymbolAlphaTier(sym) ? 8.0 : 0.0;

   outEntry = curPrice;
   outSl = lp2 - atr * 0.25;
   double risk = MathAbs(outEntry - outSl);
   if(risk <= atr * 0.15) risk = atr * 0.35;

   outTp = outEntry + MathMax(initWidth * 1.2, risk * InpMinRR);
   double rr = MathAbs(outTp - outEntry) / risk;
   if(rr < InpMinRR - 0.05) return false;

   double convScore = MathMin(1.0, (slopeL - slopeH) / MathAbs(slopeH)) * 25.0;
   double contractScore = MathMin(1.0, (initWidth - apexWidth) / initWidth) * 25.0;

   double rawScore = convScore + contractScore + wedgeDivScore + volScore + alphaBonus + 20.0;
   double mult = GetPatternMultiplier(3);
   outScore = MathMin(99.0, MathMax(0.0, rawScore * mult));

   outTag = "FALLING_WEDGE_BREAKOUT";
   if(wedgeBullDiv) outTag += "_RSI_DIV";

   return (outScore >= 82.0);
}

//+------------------------------------------------------------------+
//| Multi-Timeframe Price Action Pattern Scanner                     |
//+------------------------------------------------------------------+
bool EvaluateTimeframePriceAction(const string sym, ENUM_TIMEFRAMES tf, const string tfTag)
{
   if(Bars(sym, tf) < 55) return false;

   MqlRates rates[];
   ArraySetAsSeries(rates, false);
   int c = CopyRates(sym, tf, 0, 80, rates);
   if(c < 45) return false;

   double atr = 0.0;
   for(int i = c - 15; i < c - 1; i++)
      atr += (rates[i].high - rates[i].low);
   atr /= 14.0;
   if(atr <= 0.0) return false;

   double entry = 0, sl = 0, tp = 0, score = 0;
   string tag = "";

   // 1. Detect Double Top (M-Pattern)
   if(DetectDoubleTop(sym, rates, c, atr, entry, sl, tp, score, tag))
   {
      string cmdId = "PA_DT_" + tfTag + "_" + sym + "_" + IntegerToString((int)rates[c - 1].time);
      string comm  = "PA_DOUBLE_TOP_" + tfTag + "_SCORE" + IntegerToString((int)score);
      if(ExecuteVerifiedAPlusTrade(cmdId, sym, false, entry, sl, tp, comm))
         return true;
   }

   // 2. Detect Double Bottom (W-Pattern)
   if(DetectDoubleBottom(sym, rates, c, atr, entry, sl, tp, score, tag))
   {
      string cmdId = "PA_DB_" + tfTag + "_" + sym + "_" + IntegerToString((int)rates[c - 1].time);
      string comm  = "PA_DOUBLE_BOTTOM_" + tfTag + "_SCORE" + IntegerToString((int)score);
      if(ExecuteVerifiedAPlusTrade(cmdId, sym, true, entry, sl, tp, comm))
         return true;
   }

   // 3. Detect Rising Wedge (Bearish Breakdown)
   if(DetectRisingWedge(sym, rates, c, atr, entry, sl, tp, score, tag))
   {
      string cmdId = "PA_RW_" + tfTag + "_" + sym + "_" + IntegerToString((int)rates[c - 1].time);
      string comm  = "PA_RISING_WEDGE_" + tfTag + "_SCORE" + IntegerToString((int)score);
      if(ExecuteVerifiedAPlusTrade(cmdId, sym, false, entry, sl, tp, comm))
         return true;
   }

   // 4. Detect Falling Wedge (Bullish Breakout)
   if(DetectFallingWedge(sym, rates, c, atr, entry, sl, tp, score, tag))
   {
      string cmdId = "PA_FW_" + tfTag + "_" + sym + "_" + IntegerToString((int)rates[c - 1].time);
      string comm  = "PA_FALLING_WEDGE_" + tfTag + "_SCORE" + IntegerToString((int)score);
      if(ExecuteVerifiedAPlusTrade(cmdId, sym, true, entry, sl, tp, comm))
         return true;
   }

   return false;
}

void EvaluateSymbolPureAPlus(const string sym)
{
   if(!InpEnableAutoExe || !InpNativeAPlusScan) return;
   string reason = "";
   if(!CanOpenNewTrade(sym, "PA_PATTERN", reason)) return;

   // Priority 1: M5 Intraday sniper patterns
   if(EvaluateTimeframePriceAction(sym, PERIOD_M5, "M5"))
      return;

   // Priority 2: M15 Structural patterns
   EvaluateTimeframePriceAction(sym, PERIOD_M15, "M15");
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
      else if(action == "PLACE_MARKET" && p >= 8)
      {
         string sym     = parts[2];
         string side    = parts[3];
         double lotReq  = StringToDouble(parts[4]);
         double entry   = StringToDouble(parts[5]);
         double sl      = StringToDouble(parts[6]);
         double tp      = StringToDouble(parts[7]);
         string comment = (p >= 10) ? parts[9] : "QUICK_SCALP_M1";
         bool   isBuy   = (side == "BUY" || side == "BUY_LIMIT");

         if(!SymbolInfoInteger(sym, SYMBOL_SELECT))
            SymbolSelect(sym, true);

         string blockReason = "";
         if(!CanOpenNewTrade(sym, comment, blockReason))
         {
            Print("SMC_Auto_Bridge [", cmdId, "] QUICK SCALP SKIPPED ", sym, ": ", blockReason);
         }
         else
         {
            ConfigureSymbolFilling(sym);
            double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
            double bid = SymbolInfoDouble(sym, SYMBOL_BID);
            if(ask <= 0.0 || bid <= 0.0)
            {
               MqlTick tick;
               if(SymbolInfoTick(sym, tick))
               {
                  ask = tick.ask;
                  bid = tick.bid;
               }
            }
            if(ask <= 0.0 || bid <= 0.0)
            {
               sym = _Symbol;
               ConfigureSymbolFilling(sym);
               ask = SymbolInfoDouble(sym, SYMBOL_ASK);
               bid = SymbolInfoDouble(sym, SYMBOL_BID);
            }
            double point = SymbolInfoDouble(sym, SYMBOL_POINT);
            int stopsLvl = (int)SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL);
            double spreadDist = MathMax(ask - bid, point * 10.0);
            double minStopDist = MathMax((double)stopsLvl * point, spreadDist * 2.0);
            double atrDist = 0.0;
            MqlRates atrRates[];
            int cAtr = CopyRates(sym, PERIOD_M5, 0, 14, atrRates);
            if(cAtr > 0)
            {
               for(int a = 0; a < cAtr; a++) atrDist += (atrRates[a].high - atrRates[a].low);
               atrDist /= (double)cAtr;
            }
            double safeSlDist = MathMax(minStopDist * 2.5, (atrDist > 0.0 ? atrDist * 1.2 : spreadDist * 5.0));

            double volMin  = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
            double volMax  = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
            double volStep = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
            if(volMin <= 0.0) volMin = 0.01;
            if(volStep <= 0.0) volStep = 0.01;
            double lots = (lotReq > 0.0) ? lotReq : volMin;
            lots = MathFloor(lots / volStep) * volStep;
            if(lots < volMin) lots = volMin;
            if(volMax > 0.0 && lots > volMax) lots = volMax;

            double mktSl = sl;
            double mktTp = tp;
            if(isBuy)
            {
               if(mktSl <= 0.0 || mktSl >= bid - minStopDist)
                  mktSl = NormalizePrice(sym, bid - safeSlDist);
               if(mktTp <= 0.0 || mktTp <= ask + minStopDist)
                  mktTp = NormalizePrice(sym, ask + safeSlDist * 2.5);
               bool ok = g_trade.Buy(lots, sym, 0.0, mktSl, mktTp, comment);
               if(!ok)
                  ok = g_trade.Buy(lots, sym, 0.0, 0.0, 0.0, comment);
               Print("SMC_Auto_Bridge [", cmdId, "] QUICK SCALP BUY MARKET ", sym, " Lot=", lots,
                     " SL=", mktSl, " TP=", mktTp, " -> ", (ok ? "EXECUTED" : "FAILED (" + IntegerToString(GetLastError()) + ")"));
            }
            else
            {
               if(mktSl <= 0.0 || mktSl <= ask + minStopDist)
                  mktSl = NormalizePrice(sym, ask + safeSlDist);
               if(mktTp <= 0.0 || mktTp >= bid - minStopDist)
                  mktTp = NormalizePrice(sym, bid - safeSlDist * 2.5);
               bool ok = g_trade.Sell(lots, sym, 0.0, mktSl, mktTp, comment);
               if(!ok)
                  ok = g_trade.Sell(lots, sym, 0.0, 0.0, 0.0, comment);
               Print("SMC_Auto_Bridge [", cmdId, "] QUICK SCALP SELL MARKET ", sym, " Lot=", lots,
                     " SL=", mktSl, " TP=", mktTp, " -> ", (ok ? "EXECUTED" : "FAILED (" + IntegerToString(GetLastError()) + ")"));
            }
         }
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
   // 0. Update Online Machine Learning Brain & Dynamic Pattern Expectancy Weights
   UpdateOnlineLearningBrain();

   // 1. Execute trades, trail stops, export live account & live bid/ask quotes every 1 second
   ProcessCommandQueue();
   ManageOpenPositionsAndTrailing();
   ExportAccountAndOrders();
   ExportLiveQuotes();

   if(g_brokerSymCount <= 0)
      InitBrokerSymbols();

   // 2. Priority 1-second sync & ML Pure A+ scan for the symbol currently viewed in the browser (and chart symbol)
   string activeSym = GetActivePrioritySymbol();
   if(StringLen(activeSym) > 0)
   {
      ExportSymbolTimeframes(activeSym, true);
      EvaluateSymbolPureAPlus(activeSym);
   }
   if(_Symbol != activeSym)
   {
      ExportSymbolTimeframes(_Symbol, false);
      EvaluateSymbolPureAPlus(_Symbol);
   }

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
      Print("PA_Pattern_Bridge v5.10 [ONLINE SELF-LEARNING & PRICE ACTION]: ActiveSym='", activeSym, "' | Watchlist=", g_brokerSymCount,
            " | Patterns: Double Tops/Bottoms, Wedges | Account #", AccountInfoInteger(ACCOUNT_LOGIN));
   }
}
//+------------------------------------------------------------------+
