//+------------------------------------------------------------------+
//|                                              SMC_Auto_Bridge.mq5 |
//|     Frank Miller Smart Money Concepts (SMC) Live MT5 Auto-Bridge |
//|     Deriv Synthetics & Weltrade SyntX Full Auto-Execution Engine |
//+------------------------------------------------------------------+
#property copyright "SMC Desk — Frank Miller Smart Money Concepts"
#property version   "3.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\OrderInfo.mqh>
#include <Trade\PositionInfo.mqh>

input string InpServerUrl     = "http://localhost:8095"; // Local SMC Desk Server URL
input string InpSymbols       = "Volatility 75 (1s) Index,Volatility 75 Index,Volatility 100 (1s) Index,Volatility 100 Index,Volatility 50 (1s) Index,Volatility 50 Index,Volatility 25 (1s) Index,Volatility 25 Index,Volatility 15 (1s) Index,Volatility 10 (1s) Index,Volatility 10 Index,Boom 1000 Index,Crash 1000 Index,Boom 500 Index,Crash 500 Index,Boom 300 Index,Crash 300 Index,Step Index,Jump 10 Index,Jump 25 Index,Jump 50 Index,Jump 75 Index,Jump 100 Index,Range Break 100 Index,Range Break 200 Index,DEX 600 UP,DEX 600 DOWN,DEX 900 UP,DEX 900 DOWN,PainX 400,GainX 400,PainX 600,GainX 600,PainX 800,GainX 800,PainX 999,GainX 999,PainX 1200,GainX 1200,FX Vol 20,FX Vol 40,FX Vol 60,FX Vol 80,FX Vol 99,SFX Vol 20,SFX Vol 40,SFX Vol 60,SFX Vol 80,SFX Vol 99,SwitchX 600,BreakX 600,XAUUSD,EURUSD,GBPUSD"; // Monitored Symbols
input int    InpFullBars      = 600;     // Historical bars on initial sync
input long   InpMagicNumber   = 20260401;// Magic Number for SMC Auto-Trades
input bool   InpEnableAutoExe = true;    // Allow Web Terminal Auto-Trading & Trailing Stops

CTrade        g_trade;
COrderInfo    g_order;
CPositionInfo g_pos;

bool     g_initialSent = false;
datetime g_lastLog     = 0;
string   g_lastCmdId   = "";

int OnInit()
{
   g_trade.SetExpertMagicNumber(InpMagicNumber);
   g_trade.SetDeviationInPoints(30);
   g_trade.SetTypeFilling(ORDER_FILLING_FOK);
   EventSetTimer(1);
   Print("=================================================================");
   Print("SMC_Auto_Bridge v3.00 initialized on Account #", AccountInfoInteger(ACCOUNT_LOGIN),
         " (", AccountInfoString(ACCOUNT_SERVER), ")");
   Print("Balance: $", DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2),
         " | Equity: $", DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2));
   Print("Common Files Path: Common\\Files\\smc_bridge");
   Print("=================================================================");
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   Print("SMC_Auto_Bridge stopped.");
}

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

   if(StringLen(InpServerUrl) > 5)
   {
      string url = InpServerUrl + "/api/mt5/account";
      char post[], result[];
      string headers = "Content-Type: application/json\r\n";
      StringToCharArray(stateJson, post, 0, StringLen(stateJson));
      string resHeaders;
      WebRequest("POST", url, headers, 400, post, result, resHeaders);
   }
}

//+------------------------------------------------------------------+
//| Execute Incoming Auto-Trade & X1/X2/X3 Trailing Stop Commands    |
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
      // Pipe-delimited format:
      // CMD_ID|ACTION|SYMBOL|SIDE|LOT|ENTRY|SL|TP|TICKET|COMMENT
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
         double lot     = StringToDouble(parts[4]);
         double entry   = StringToDouble(parts[5]);
         double sl      = StringToDouble(parts[6]);
         double tp      = StringToDouble(parts[7]);
         string comment = (p >= 10) ? parts[9] : "SMC_Auto";

         SymbolSelect(sym, true);
         int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
         entry = NormalizeDouble(entry, digits);
         sl    = NormalizeDouble(sl, digits);
         tp    = NormalizeDouble(tp, digits);

         double minVol  = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
         double stepVol = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
         if(minVol > 0 && lot < minVol) lot = minVol;
         if(stepVol > 0) lot = MathFloor(lot / stepVol + 0.0001) * stepVol;

         double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
         double bid = SymbolInfoDouble(sym, SYMBOL_BID);

         bool ok = false;
         if(side == "BUY" || side == "BUY_LIMIT")
         {
            if(entry < ask && entry > 0)
               ok = g_trade.BuyLimit(lot, entry, sym, sl, tp, ORDER_TIME_GTC, 0, comment);
            else if(entry > ask)
               ok = g_trade.BuyStop(lot, entry, sym, sl, tp, ORDER_TIME_GTC, 0, comment);
            else
               ok = g_trade.Buy(lot, sym, ask, sl, tp, comment);
         }
         else if(side == "SELL" || side == "SELL_LIMIT")
         {
            if(entry > bid && entry > 0)
               ok = g_trade.SellLimit(lot, entry, sym, sl, tp, ORDER_TIME_GTC, 0, comment);
            else if(entry < bid && entry > 0)
               ok = g_trade.SellStop(lot, entry, sym, sl, tp, ORDER_TIME_GTC, 0, comment);
            else
               ok = g_trade.Sell(lot, sym, bid, sl, tp, comment);
         }
         Print("SMC_Auto_Bridge [", cmdId, "] ", action, " ", sym, " ", side, " Lot=", lot,
               " Entry=", entry, " SL=", sl, " TP=", tp, " -> ", (ok ? "SUCCESS" : "FAILED"));
      }
      else if(action == "MODIFY_SLTP" && p >= 9)
      {
         string sym    = parts[2];
         double newSl  = StringToDouble(parts[6]);
         double newTp  = StringToDouble(parts[7]);
         ulong  ticket = (ulong)StringToInteger(parts[8]);
         int    digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
         newSl = NormalizeDouble(newSl, digits);
         newTp = NormalizeDouble(newTp, digits);

         if(PositionSelectByTicket(ticket))
         {
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
//| Main Timer: Process Commands, Export Positions & Stream OHLCV    |
//+------------------------------------------------------------------+
void OnTimer()
{
   ProcessCommandQueue();
   ExportAccountAndOrders();

   string syms[];
   int n = StringSplit(InpSymbols, ',', syms);
   if(n <= 0)
   {
      ArrayResize(syms, 1);
      syms[0] = _Symbol;
      n = 1;
   }

   // Always include active chart & all open charts in MT5
   long chartId = ChartFirst();
   while(chartId >= 0)
   {
      string cs = ChartSymbol(chartId);
      if(StringLen(cs) > 0)
      {
         bool exists = false;
         for(int s = 0; s < n; s++)
         {
            if(syms[s] == cs) { exists = true; break; }
         }
         if(!exists)
         {
            ArrayResize(syms, n + 1);
            syms[n] = cs;
            n++;
         }
      }
      chartId = ChartNext(chartId);
   }

   // Include M1, M3, M5, M15, M30, H1, H4, D1 for Frank Miller SMC models (Ch. 6-8)
   ENUM_TIMEFRAMES tfs[6] = {PERIOD_M1, PERIOD_M5, PERIOD_M15, PERIOD_H1, PERIOD_H4, PERIOD_D1};
   int tfSec[6]           = {60, 300, 900, 3600, 14400, 86400};

   int count = g_initialSent ? 15 : InpFullBars;
   string kind = g_initialSent ? "live" : "full";
   int exportedCount = 0;

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

         if(StringLen(InpServerUrl) > 5)
         {
            string url = InpServerUrl + "/api/mt5/push?symbol=" + sym + "&tf=" + IntegerToString(tfSec[t]) + "&kind=" + kind;
            char post[], result[];
            string headers = "Content-Type: application/json\r\n";
            StringToCharArray(json, post, 0, StringLen(json));
            string resHeaders;
            WebRequest("POST", url, headers, 500, post, result, resHeaders);
         }
      }
   }

   if(TimeCurrent() - g_lastLog > 30)
   {
      g_lastLog = TimeCurrent();
      Print("SMC_Auto_Bridge: Active sync for ", n, " symbols (", exportedCount, " series updated). Account=", AccountInfoInteger(ACCOUNT_LOGIN));
   }

   g_initialSent = true;
}
//+------------------------------------------------------------------+
