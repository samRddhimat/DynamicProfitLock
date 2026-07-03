//+------------------------------------------------------------------+
//| DynamicProfitLock_Script.mq5                                      |
//| On-demand script: adjusts SL on all magic=0 (manual) positions   |
//| to lock in a percentage of current unrealized profit, using       |
//| discrete tiers that tighten as profit grows.                      |
//|                                                                   |
//| Tier table (agreed spec):                                         |
//|   $0    - $50   : lock in 30% of profit                          |
//|   $50   - $200  : lock in 50% of profit                          |
//|   $200  - $500  : lock in 70% of profit                          |
//|   $500  - $1000 : lock in 80% of profit                          |
//|   $1000+        : lock in 90% of profit                          |
//|                                                                   |
//| Usage: drag onto any chart. Runs once, adjusts qualifying         |
//| positions, prints a summary, then exits.                          |
//|                                                                   |
//| Parameters:                                                        |
//|   InpMinProfit    : minimum profit ($) before SL is adjusted.    |
//|   InpPrintDetails : print per-position detail to Experts log.    |
//|   InpSymbolFilter : comma-separated list of symbols to SKIP.     |
//|                     "" = manage ALL symbols.                      |
//|                     "XAUUSD" = skip XAUUSD only.                 |
//|                     "XAUUSD,USDJPY" = skip both.                 |
//+------------------------------------------------------------------+
#property script_show_inputs
#property strict

#include <Trade/Trade.mqh>

//--- inputs
input double InpMinProfit    = 1.0;   // Minimum profit ($) before SL is adjusted
input bool   InpPrintDetails = true;  // Print per-position detail to Experts log
input string InpSymbolFilter = "";    // Symbols to SKIP (comma-separated, e.g. "XAUUSD,USDJPY")

CTrade  g_trade;
string  g_skipSymbols[];

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
double ComputeNewSL(const long   type,
                     const double entry,
                     const double profit,
                     const double lockPct,
                     const string symbol)
{
   const double tickSize  = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   const double tickValue = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
   const double volume    = PositionGetDouble(POSITION_VOLUME);

   if(tickSize <= 0.0 || tickValue <= 0.0 || volume <= 0.0) return 0.0;

   const double dollarPerPoint = (tickValue / tickSize) * volume;
   if(dollarPerPoint <= 0.0) return 0.0;

   const double protectAmount = profit * lockPct;
   const double priceDist     = protectAmount / dollarPerPoint;

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
void OnStart()
{
   g_trade.LogLevel(LOG_LEVEL_ERRORS);
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

      const string symbol    = PositionGetString(POSITION_SYMBOL);

      // Skip symbols in the exclude list
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
      }
      else
      {
         skipped++;
         PrintFormat("FAILED ticket=%d %s: modify retcode=%d",
                     ticket, symbol, (int)g_trade.ResultRetcode());
      }
   }

   PrintFormat("=== DPL Script done: %d adjusted, %d skipped, %d below min profit, %d symbol-filtered ===",
               adjusted, skipped, noProfit, filtered);
}
//+------------------------------------------------------------------+