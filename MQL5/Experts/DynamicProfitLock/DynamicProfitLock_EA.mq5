//+------------------------------------------------------------------+
//| DynamicProfitLock_EA.mq5                                          |
//| Standalone EA: continuously adjusts SL on magic=0 (manual)       |
//| positions to lock in a percentage of unrealized profit, using     |
//| discrete tiers that tighten as profit grows.                      |
//|                                                                   |
//| Tier table (agreed spec):                                         |
//|   $0    - $50   : lock in 30% of profit                          |
//|   $50   - $200  : lock in 50% of profit                          |
//|   $200  - $500  : lock in 70% of profit                          |
//|   $500  - $1000 : lock in 80% of profit                          |
//|   $1000+        : lock in 90% of profit                          |
//|                                                                   |
//| Design:                                                           |
//| - Attaches to ANY chart (symbol doesn't matter — it scans ALL     |
//|   open positions across the account, not just the chart symbol).  |
//| - Evaluates every tick. In practice SL rarely needs updating      |
//|   more than once per few seconds, but tick-level evaluation       |
//|   ensures the fastest possible response when profit jumps.        |
//| - Only modifies SL when the new computed value is a genuine       |
//|   improvement over the current one (never-loosen principle).      |
//| - Does NOT touch TP. Does NOT close positions. SL management only.|
//| - Completely independent of InstitutionalEA — different magic      |
//|   filter (0 vs InpMagicNumber), different chart, no shared state. |
//|                                                                   |
//| Parameters:                                                        |
//|   InpMinProfit      : minimum unrealized profit ($) before the    |
//|                       EA starts adjusting SL. Prevents noise-     |
//|                       driven SL moves on barely-profitable trades. |
//|   InpCheckEveryNTicks: how often to re-evaluate (1 = every tick,  |
//|                        10 = every 10th tick). Use higher values   |
//|                        on fast symbols to reduce CPU load.        |
//|   InpLogAdjustments : print to Experts log when SL is changed.   |
//+------------------------------------------------------------------+
#property copyright "DynamicProfitLock EA"
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>

//--- inputs
input double InpMinProfit        = 1.0;   // Minimum profit ($) before SL is adjusted
input int    InpCheckEveryNTicks = 5;     // Evaluate every N ticks (1=every tick)
input bool   InpLogAdjustments   = true;  // Log SL changes to Experts tab

//--- state
CTrade g_trade;
int    g_tickCount = 0;

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
                     const string symbol,
                     const double volume)
{
   const double tickSize  = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   const double tickValue = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);

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
void EvaluateAllPositions()
{
   const int total = PositionsTotal();
   for(int i = total - 1; i >= 0; i--)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != 0) continue;

      const string symbol    = PositionGetString(POSITION_SYMBOL);
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
   Print("DynamicProfitLock EA started — managing magic=0 positions");
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   Print("DynamicProfitLock EA stopped (reason ", reason, ")");
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
