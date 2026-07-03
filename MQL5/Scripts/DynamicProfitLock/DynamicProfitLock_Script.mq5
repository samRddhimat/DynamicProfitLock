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
//| Usage: drag onto any chart. The script runs once, adjusts all     |
//| qualifying positions, prints a summary, then exits. It does NOT   |
//| loosen an existing SL — if the computed new SL would be worse     |
//| than the current SL, it is skipped (never-loosen principle).     |
//|                                                                   |
//| Only manages positions with magic number = 0 (manually placed).   |
//| Does NOT touch InstitutionalEA positions (different magic).       |
//+------------------------------------------------------------------+
#property script_show_inputs
#property strict

#include <Trade/Trade.mqh>

//--- inputs
input double InpMinProfit    = 1.0;  // Minimum profit ($) before SL is adjusted
input bool   InpPrintDetails = true; // Print per-position detail to Experts log

CTrade g_trade;

//+------------------------------------------------------------------+
//| Compute lock-in percentage from current profit (discrete tiers)   |
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
//| Compute the SL price that locks in the target profit amount       |
//+------------------------------------------------------------------+
double ComputeNewSL(const long   type,
                     const double entry,
                     const double profit,
                     const double lockPct,
                     const string symbol)
{
   // How much dollar profit to protect
   const double protectAmount = profit * lockPct;

   // We need to find the price distance from entry that corresponds
   // to protectAmount in dollars, for 1 lot equivalent. Since the
   // position may not be 1 lot, we use OrderCalcProfit to work
   // backward: find the price at which P&L = protectAmount.
   // Simpler and broker-accurate: use tick value to convert.
   const double tickSize  = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   const double tickValue = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
   const double volume    = PositionGetDouble(POSITION_VOLUME);

   if(tickSize <= 0.0 || tickValue <= 0.0 || volume <= 0.0) return 0.0;

   // Dollar value per point per lot -> scale by actual volume
   const double dollarPerPoint = (tickValue / tickSize) * volume;
   if(dollarPerPoint <= 0.0) return 0.0;

   // Price distance that corresponds to protectAmount
   const double priceDist = protectAmount / dollarPerPoint;

   // SL sits priceDist away from entry in the PROFIT direction
   // (for a buy: entry + dist; for a sell: entry - dist)
   if(type == POSITION_TYPE_BUY)
      return entry + priceDist;
   else
      return entry - priceDist;
}

//+------------------------------------------------------------------+
//| Is 'candidate' a genuine improvement over 'current' SL?          |
//+------------------------------------------------------------------+
bool IsImprovement(const long type, const double candidate, const double currentSL)
{
   if(currentSL == 0.0) return true; // no existing SL, anything is better
   if(type == POSITION_TYPE_BUY)  return candidate > currentSL;
   if(type == POSITION_TYPE_SELL) return candidate < currentSL;
   return false;
}

//+------------------------------------------------------------------+
//| Normalize price to symbol digits                                  |
//+------------------------------------------------------------------+
double NormalizePrice(const string symbol, const double price)
{
   return NormalizeDouble(price, (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS));
}

//+------------------------------------------------------------------+
void OnStart()
{
   g_trade.LogLevel(LOG_LEVEL_ERRORS);

   int adjusted = 0;
   int skipped  = 0;
   int noProfit = 0;

   const int total = PositionsTotal();
   for(int i = total - 1; i >= 0; i--)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;

      // Only magic = 0 (manually placed)
      if(PositionGetInteger(POSITION_MAGIC) != 0) continue;

      const string symbol  = PositionGetString(POSITION_SYMBOL);
      const long   type    = PositionGetInteger(POSITION_TYPE);
      const double entry   = PositionGetDouble(POSITION_PRICE_OPEN);
      const double currentSL = PositionGetDouble(POSITION_SL);
      const double currentTP = PositionGetDouble(POSITION_TP);
      const double profit  = PositionGetDouble(POSITION_PROFIT);

      // Skip if not profitable enough
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

      // Never loosen — skip if new SL is not an improvement
      if(!IsImprovement(type, newSL, currentSL))
      {
         skipped++;
         if(InpPrintDetails)
            PrintFormat("SKIP ticket=%d %s: new SL %.5f not better than current %.5f",
                        ticket, symbol, newSL, currentSL);
         continue;
      }

      // Apply the new SL
      if(g_trade.PositionModify(ticket, newSL, currentTP))
      {
         adjusted++;
         PrintFormat("ADJUSTED ticket=%d %s %s: profit=%.2f lock=%.0f%% newSL=%.5f (was %.5f)",
                     ticket, symbol,
                     type == POSITION_TYPE_BUY ? "BUY" : "SELL",
                     profit, lockPct * 100.0, newSL, currentSL);
      }
      else
      {
         skipped++;
         PrintFormat("FAILED ticket=%d %s: modify retcode=%d",
                     ticket, symbol, (int)g_trade.ResultRetcode());
      }
   }

   PrintFormat("=== DynamicProfitLock Script complete: %d adjusted, %d skipped, %d below min profit ===",
               adjusted, skipped, noProfit);
}
//+------------------------------------------------------------------+
