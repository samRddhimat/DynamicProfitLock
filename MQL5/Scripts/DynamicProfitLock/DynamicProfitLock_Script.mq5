//+------------------------------------------------------------------+
//| DynamicProfitLock_Script.mq5                                      |
//| On-demand script: adjusts SL on all magic=0 (manual) positions   |
//| to lock in a percentage of current unrealized profit, using       |
//| discrete tiers that tighten as profit grows.                      |
//|                                                                   |
//| Tier table:                                                        |
//|   $0-$50=30%  $50-$200=50%  $200-$500=70%                        |
//|   $500-$1000=80%  $1000+=90%                                      |
//|                                                                   |
//| Chart labels: when InpShowChartLabels=true, a label is drawn      |
//| on the chart for each adjusted position showing ticket, symbol,   |
//| direction, lock%, and profit at time of adjustment.               |
//| NOTE: script labels persist after the script exits (unlike the    |
//| EA which cleans up on deinit). Run the script again with          |
//| InpClearLabels=true to remove all DPL labels from the chart.     |
//|                                                                   |
//| InpSymbolFilter: comma-separated symbols to SKIP.                 |
//+------------------------------------------------------------------+
#property script_show_inputs
#property strict

#include <Trade/Trade.mqh>

//--- inputs
input double InpMinProfit       = 1.0;    // Minimum profit ($) before SL is adjusted
input bool   InpPrintDetails    = true;   // Print per-position detail to Experts log
input string InpSymbolFilter    = "";     // Symbols to SKIP (comma-separated)
input bool   InpShowChartLabels = true;   // Show adjustment labels on chart
input bool   InpClearLabels     = false;  // Set true to ONLY clear existing DPL labels
input int    InpLabelFontSize   = 7;      // Chart label font size
input color  InpLabelColor      = clrDodgerBlue; // Chart label color

CTrade  g_trade;
string  g_skipSymbols[];
string  g_labelPrefix = "DPL_";

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
                     const double lockPct, const string symbol)
{
   const double tickSize  = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   const double tickValue = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
   const double volume    = PositionGetDouble(POSITION_VOLUME);
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
void DrawLabel(const ulong ticket, const string symbol, const long type,
                const double profit, const double lockPct, const double newSL)
{
   if(!InpShowChartLabels) return;

   const string name = g_labelPrefix + IntegerToString((long)ticket);
   const string text = StringFormat("#%d %s %s | DPL:%.0f%%:$%.2f | SL:%.5f",
                                     ticket, symbol,
                                     type == POSITION_TYPE_BUY ? "BUY" : "SELL",
                                     lockPct * 100.0, profit, newSL);

   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_TEXT, 0, TimeCurrent(), newSL);
   else
   {
      ObjectSetInteger(0, name, OBJPROP_TIME, TimeCurrent());
      ObjectSetDouble(0, name, OBJPROP_PRICE, newSL);
   }

   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_COLOR, InpLabelColor);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, InpLabelFontSize);
   ObjectSetInteger(0, name, OBJPROP_ANCHOR, ANCHOR_LEFT);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
}

//+------------------------------------------------------------------+
void ClearAllLabels()
{
   int removed = 0;
   const int total = ObjectsTotal(0);
   for(int i = total - 1; i >= 0; i--)
   {
      const string name = ObjectName(0, i);
      if(StringFind(name, g_labelPrefix) == 0)
      {
         ObjectDelete(0, name);
         removed++;
      }
   }
   ChartRedraw(0);
   PrintFormat("DPL Script: removed %d chart labels", removed);
}

//+------------------------------------------------------------------+
void OnStart()
{
   g_trade.LogLevel(LOG_LEVEL_ERRORS);

   // Label-clear-only mode
   if(InpClearLabels)
   {
      ClearAllLabels();
      return;
   }

   ParseSymbolFilter();

   int adjusted = 0;
   int skipped  = 0;
   int noProfit = 0;
   int filtered = 0;

   const int total = PositionsTotal();
   for(int i = total - 1; i >= 0; i--)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != 0) continue;

      const string symbol = PositionGetString(POSITION_SYMBOL);
      if(IsSkipped(symbol))
      {
         filtered++;
         if(InpPrintDetails)
            PrintFormat("FILTERED ticket=%d %s: symbol in skip list", ticket, symbol);
         continue;
      }

      const long   type      = PositionGetInteger(POSITION_TYPE);
      const double entry     = PositionGetDouble(POSITION_PRICE_OPEN);
      const double currentSL = PositionGetDouble(POSITION_SL);
      const double currentTP = PositionGetDouble(POSITION_TP);
      const double profit    = PositionGetDouble(POSITION_PROFIT);

      if(profit < InpMinProfit)
      {
         noProfit++;
         if(InpPrintDetails)
            PrintFormat("SKIP ticket=%d %s: profit=%.2f below minimum %.2f",
                        ticket, symbol, profit, InpMinProfit);
         continue;
      }

      const double lockPct  = LockInPct(profit);
      const double newSLRaw = ComputeNewSL(type, entry, profit, lockPct, symbol);
      if(newSLRaw <= 0.0)
      {
         skipped++;
         if(InpPrintDetails)
            PrintFormat("SKIP ticket=%d %s: could not compute new SL", ticket, symbol);
         continue;
      }

      const double newSL = NormalizePrice(symbol, newSLRaw);
      if(!IsImprovement(type, newSL, currentSL))
      {
         skipped++;
         if(InpPrintDetails)
            PrintFormat("SKIP ticket=%d %s: new SL %.5f not better than current %.5f",
                        ticket, symbol, newSL, currentSL);
         continue;
      }

      if(g_trade.PositionModify(ticket, newSL, currentTP))
      {
         adjusted++;
         PrintFormat("ADJUSTED ticket=%d %s %s: profit=%.2f lock=%.0f%% SL %.5f -> %.5f",
                     ticket, symbol,
                     type == POSITION_TYPE_BUY ? "BUY" : "SELL",
                     profit, lockPct * 100.0, currentSL, newSL);

         DrawLabel(ticket, symbol, type, profit, lockPct, newSL);
      }
      else
      {
         skipped++;
         PrintFormat("FAILED ticket=%d %s: modify retcode=%d",
                     ticket, symbol, (int)g_trade.ResultRetcode());
      }
   }

   ChartRedraw(0);
   PrintFormat("=== DPL Script done: %d adjusted, %d skipped, %d below min profit, %d symbol-filtered ===",
               adjusted, skipped, noProfit, filtered);
}
//+------------------------------------------------------------------+