//+------------------------------------------------------------------+
//| DynamicProfitLock_EA.mq5                                          |
//| Standalone EA: continuously adjusts SL on magic=0 (manual)       |
//| positions to lock in a percentage of unrealized profit, using     |
//| discrete tiers that tighten as profit grows.                      |
//|                                                                   |
//| Tier table:                                                        |
//|   $0-$50=30%  $50-$200=50%  $200-$500=70%                        |
//|   $500-$1000=80%  $1000+=90%                                      |
//|                                                                   |
//| Chart labels: when InpShowChartLabels=true, a label is drawn      |
//| on the chart for each managed position showing ticket, symbol,    |
//| direction, lock%, and current profit. Label updates each time     |
//| the SL is tightened. Labels are removed on EA deinit.            |
//|                                                                   |
//| InpSymbolFilter: comma-separated symbols to SKIP.                 |
//|   "" = manage ALL, "XAUUSD" = skip gold,                         |
//|   "XAUUSD,USDJPY" = skip both.                                   |
//+------------------------------------------------------------------+
#property copyright "DynamicProfitLock EA"
#property version   "1.02"
#property strict

#include <Trade/Trade.mqh>

//--- inputs
input double InpMinProfit        = 1.0;    // Minimum profit ($) before SL is adjusted
input int    InpCheckEveryNTicks = 5;      // Evaluate every N ticks (1=every tick)
input bool   InpLogAdjustments   = true;   // Log SL changes to Experts tab
input string InpSymbolFilter     = "";     // Symbols to SKIP (comma-separated)
input bool   InpShowChartLabels  = true;   // Show adjustment labels on chart
input int    InpLabelFontSize    = 9;      // Chart label font size
input color  InpLabelColor       = clrDodgerBlue; // Chart label color

//--- state
CTrade  g_trade;
int     g_tickCount   = 0;
string  g_skipSymbols[];
string  g_labelPrefix = "DPL_";  // prefix for all chart objects created by this EA

//+------------------------------------------------------------------+
void ParseSymbolFilter()
{
   ArrayResize(g_skipSymbols, 0);
   if(StringLen(InpSymbolFilter) == 0) return;
   string parts[];
   int count = StringSplit(InpSymbolFilter, ',', parts);
   ArrayResize(g_skipSymbols, count);
   for(int i = 0; i < count; i++)
   {
      g_skipSymbols[i] = parts[i];
      StringTrimLeft(g_skipSymbols[i]);
      StringTrimRight(g_skipSymbols[i]);
   }
}

//+------------------------------------------------------------------+
bool IsSkipped(const string symbol)
{
   const int n = ArraySize(g_skipSymbols);
   for(int i = 0; i < n; i++)
      if(g_skipSymbols[i] == symbol) return true;
   return false;
}

//+------------------------------------------------------------------+
double LockInPct(const double profit)
{
   if(profit <   50.0) return 0.30;
   if(profit <  200.0) return 0.50;
   if(profit <  500.0) return 0.70;
   if(profit < 1000.0) return 0.80;
   return 0.90;
}

//+------------------------------------------------------------------+
double ComputeNewSL(const long type, const double entry, const double profit,
                     const double lockPct, const string symbol, const double volume)
{
   const double tickSize  = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   const double tickValue = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
   if(tickSize <= 0.0 || tickValue <= 0.0 || volume <= 0.0) return 0.0;
   const double dollarPerPoint = (tickValue / tickSize) * volume;
   if(dollarPerPoint <= 0.0) return 0.0;
   const double priceDist = (profit * lockPct) / dollarPerPoint;
   if(type == POSITION_TYPE_BUY)  return entry + priceDist;
   if(type == POSITION_TYPE_SELL) return entry - priceDist;
   return 0.0;
}

//+------------------------------------------------------------------+
bool IsImprovement(const long type, const double candidate, const double currentSL)
{
   if(currentSL == 0.0) return true;
   if(type == POSITION_TYPE_BUY)  return candidate > currentSL;
   if(type == POSITION_TYPE_SELL) return candidate < currentSL;
   return false;
}

//+------------------------------------------------------------------+
double NormalizePrice(const string symbol, const double price)
{
   return NormalizeDouble(price, (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS));
}

//+------------------------------------------------------------------+
//| Draw or update a chart label for a managed position               |
//+------------------------------------------------------------------+
void UpdateChartLabel(const ulong ticket, const string symbol, const long type,
                       const double profit, const double lockPct, const double newSL)
{
   if(!InpShowChartLabels) return;

   const string name = g_labelPrefix + IntegerToString((long)ticket);
   const string text = StringFormat("#%d %s %s | DPL:%.0f%%:$%.2f | SL:%.5f",
                                     ticket, symbol,
                                     type == POSITION_TYPE_BUY ? "BUY" : "SELL",
                                     lockPct * 100.0, profit, newSL);

   // Use the new SL price as the vertical anchor on the chart
   const datetime labelTime = TimeCurrent();

   if(ObjectFind(0, name) < 0)
   {
      // Create new label
      ObjectCreate(0, name, OBJ_TEXT, 0, labelTime, newSL);
   }
   else
   {
      // Update existing label position
      ObjectSetInteger(0, name, OBJPROP_TIME, labelTime);
      ObjectSetDouble(0, name, OBJPROP_PRICE, newSL);
   }

   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_COLOR, InpLabelColor);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, InpLabelFontSize);
   ObjectSetInteger(0, name, OBJPROP_ANCHOR, ANCHOR_LEFT);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, false);
   ChartRedraw(0);
}

//+------------------------------------------------------------------+
//| Remove all chart labels created by this EA                        |
//+------------------------------------------------------------------+
void RemoveAllLabels()
{
   const int total = ObjectsTotal(0);
   for(int i = total - 1; i >= 0; i--)
   {
      const string name = ObjectName(0, i);
      if(StringFind(name, g_labelPrefix) == 0)
         ObjectDelete(0, name);
   }
   ChartRedraw(0);
}

//+------------------------------------------------------------------+
void EvaluateAllPositions()
{
   const int total = PositionsTotal();
   for(int i = total - 1; i >= 0; i--)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != 0) continue;

      const string symbol = PositionGetString(POSITION_SYMBOL);
      if(IsSkipped(symbol)) continue;

      const long   type      = PositionGetInteger(POSITION_TYPE);
      const double entry     = PositionGetDouble(POSITION_PRICE_OPEN);
      const double currentSL = PositionGetDouble(POSITION_SL);
      const double currentTP = PositionGetDouble(POSITION_TP);
      const double profit    = PositionGetDouble(POSITION_PROFIT);
      const double volume    = PositionGetDouble(POSITION_VOLUME);

      if(profit < InpMinProfit) continue;

      const double lockPct  = LockInPct(profit);
      const double newSLRaw = ComputeNewSL(type, entry, profit, lockPct, symbol, volume);
      if(newSLRaw <= 0.0) continue;

      const double newSL = NormalizePrice(symbol, newSLRaw);
      if(!IsImprovement(type, newSL, currentSL)) continue;

      if(g_trade.PositionModify(ticket, newSL, currentTP))
      {
         if(InpLogAdjustments)
            PrintFormat("DPL_EA: ticket=%d %s %s profit=%.2f lock=%.0f%% SL %.5f -> %.5f",
                        ticket, symbol,
                        type == POSITION_TYPE_BUY ? "BUY" : "SELL",
                        profit, lockPct * 100.0, currentSL, newSL);

         // Update chart label
         UpdateChartLabel(ticket, symbol, type, profit, lockPct, newSL);
      }
      else
      {
         PrintFormat("DPL_EA: MODIFY FAILED ticket=%d retcode=%d",
                     ticket, (int)g_trade.ResultRetcode());
      }
   }
}

//+------------------------------------------------------------------+
int OnInit()
{
   g_trade.LogLevel(LOG_LEVEL_ERRORS);
   g_tickCount = 0;
   ParseSymbolFilter();

   const int skipCount = ArraySize(g_skipSymbols);
   if(skipCount > 0)
   {
      string skipList = "";
      for(int i = 0; i < skipCount; i++)
         skipList += (i > 0 ? ", " : "") + g_skipSymbols[i];
      PrintFormat("DPL_EA started — managing magic=0 positions, SKIPPING: %s", skipList);
   }
   else
      Print("DPL_EA started — managing ALL magic=0 positions (no symbol filter)");

   if(InpShowChartLabels)
      Print("DPL_EA: chart labels ENABLED");

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   RemoveAllLabels();
   Print("DPL_EA stopped (reason ", reason, ") — chart labels removed");
}

//+------------------------------------------------------------------+
void OnTick()
{
   g_tickCount++;
   if(g_tickCount < InpCheckEveryNTicks) return;
   g_tickCount = 0;
   EvaluateAllPositions();
}
//+------------------------------------------------------------------+