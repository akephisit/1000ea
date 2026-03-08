//+------------------------------------------------------------------+
//| ZigZag_Hedge_2Levels_Fixed_AddOrMul_V8.mq5                       |
//| Start BUY market, then alternate SELL STOP / BUY STOP            |
//| between 2 fixed levels (Upper/Lower) with lot progression.       |
//| Lot progression: ADD (fixed step) or MULTIPLY                    |
//| Fix: prevent duplicate pendings + safe position loop + deal guard|
//| + Fix: Market-Closed guard + retry close/pending when reopened   |
//+------------------------------------------------------------------+
#property copyright "OpenAI"
#property version   "1.08"
#property strict

#include <Trade/Trade.mqh>
CTrade trade;

//------------------------- INPUTS ----------------------------------
// Core
input bool     InpAutoStart            = true;       // Auto start when attached
input double   InpStartLot             = 0.01;       // First BUY lot (Safe for $100)

// ABCD (Structure-break) start direction using ZigZag pivots
enum ABCD_START_MODE { ABCD_START_ALWAYS_BUY=0, ABCD_START_USE_ABCD_ELSE_BUY=1, ABCD_START_REQUIRE_ABCD=2 };
input ABCD_START_MODE InpABCDStartMode = ABCD_START_USE_ABCD_ELSE_BUY; // Start direction mode
input bool     InpABCDDynamicRefresh   = true;       // Refresh ABCD signal when new pivots form (won't alter existing positions)
input ENUM_TIMEFRAMES InpABCDTimeframe = PERIOD_CURRENT; // Timeframe to read ZigZag pivots from
input int      InpABCDLookbackBars     = 600;        // ZigZag scan window (bars)
input int      InpABCDConfirmBars      = 5;          // Ignore pivots too close to bar 0 (reduce repaint)
input int      InpABCDMinLegPoints     = 50;         // Minimum leg size (points) to accept pivots
input string   InpZigZagPath           = "Examples\\ZigZag"; // iCustom path (e.g., Examples\\ZigZag)
input int      InpZigZagDepth          = 12;
input int      InpZigZagDeviation      = 5;
input int      InpZigZagBackstep       = 3;

// Lot progression
enum LOT_MODE { LOT_ADD=0, LOT_MUL=1 };
input LOT_MODE InpLotMode              = LOT_ADD;    // Lot mode: ADD or MULTIPLY
input double   InpLotAdd               = 0.01;       // ADD: +each leg (0.01->0.02->0.03...)
input double   InpLotMultiplier        = 2.0;        // MUL: *each leg (0.01->0.02->0.04...)

input double   InpFirstOppLot          = 0.00;       // First opposite lot override (0 = auto by mode)
input int      InpStepPoints           = 5000;       // Base distance between Upper/Lower (Exness Gold: 5000-8000 points)
input int      InpMaxCycles            = 0;          // Max triggered legs (0=unlimited)

// Auto ATR Distance (Dynamic Step)
input bool     InpAutoATRStep          = true;       // Enable Auto ATR Step Distance
input int      InpATRStepPeriod        = 14;         // ATR Period for Step
input double   InpATRStepMultiplier    = 1.0;        // ATR Multiplier for Step
input int      InpMinStepPoints        = 3000;       // Minimum Step Points (Protect tight sideways)
input int      InpMaxStepPoints        = 12000;      // Maximum Step Points (0 = disable limit)

// Trailing Stop (When One-Sided)
input bool     InpUseTrailing          = true;       // Enable Trailing Stop
input int      InpTrailingStartPoints  = 1500;       // Trailing Start (Points profit, ex. 1500 pts)
input int      InpTrailingDistancePoints = 800;      // Trailing Distance (Points, ex. 800 pts)

// Safety / Exit
input bool     InpCloseAllOnProfit     = true;       // Close all when profit target hit
input double   InpProfitTargetMoney    = 10.0;       // Profit target (10% of $100)
input bool     InpCloseAllOnLoss       = true;       // Close all when loss limit hit
input double   InpLossLimitMoney       = -50.0;      // Loss limit (-50% max DD)

// Per-order optional SL/TP (points). 0 = not set
input int      InpTP_Points            = 0;          // TakeProfit points for each position (0 disable)
input int      InpSL_Points            = 0;          // StopLoss points for each position (0 disable)

// Trade settings
input ulong    InpMagic                = 20260210;   // Magic number
input int      InpSlippagePoints       = 20;         // Slippage (points)
input string   InpComment              = "ZZH2L_V8"; // Order comment
input bool     InpOnePendingOnly       = true;       // Keep only 1 pending opposite at a time

// Recovery / Persistence
input bool     InpUseTerminalGlobalVar = true;       // Persist levels using Terminal GlobalVariables

// Debug / stability
input bool     InpDebugPrint           = false;      // Print debug logs
input int      InpTxnCooldownMs        = 300;        // Cooldown after deal (ms) to avoid OnTick placing extra pending
input int      InpTimerSeconds         = 2;          // Timer interval to retry close/pending (seconds)

// Anti-sideway / risk guard
input int      InpSidewayATRPeriod     = 14;         // ATR period for sideway filter (0 disable)
input int      InpSidewayMinATRPoints  = 0;          // If ATR(points) < this => pause new pending (0 disable)
input double   InpMaxLotLimit          = 0.50;       // Hard cap/guard for next lot (Exness 100$)
input bool     InpPauseOnMaxLot        = true;       // If next lot would exceed cap => stop placing new legs

// Pending maintenance after restart / market reopen
input bool     InpFollowPriceForPending = true;      // If true, opposite pending is kept ~InpStepPoints away from current price
input bool     InpRepricePendingOnNewBar = true;     // Throttle reprice to once per bar (PERIOD_CURRENT)
input int      InpPendingRepriceThresholdPoints = 200; // Reprice if pending differs by this many points (0=auto: Step/5, min 10)

//------------------------- STATE -----------------------------------
enum ZZ_SIDE { SIDE_NONE=0, SIDE_BUY=1, SIDE_SELL=2 };

double  gUpperPrice = 0.0;
double  gLowerPrice = 0.0;
ZZ_SIDE gLastTriggered = SIDE_NONE;
double  gNextLot = 0.0;         // lot for next pending
int     gCycles = 0;            // triggered legs
bool    gStarted = false;

ulong   gLastDealProcessed = 0; // guard for OnTradeTransaction
ulong   gLastDealMs        = 0; // used for cooldown

bool    gPendingCloseAll   = false; // ✅ ถ้าปิดไม่ได้เพราะ market closed -> รอปิดเมื่อเปิด
bool    gMarketWasClosed   = false; // ✅ ใช้ detect เปิด/ปิด

//------------------------- ABCD (ZigZag pivots) ---------------------
enum ABCD_SIGNAL { ABCD_NONE=0, ABCD_BUY=1, ABCD_SELL=2 };

int         gZigZagHandle  = INVALID_HANDLE;
ABCD_SIGNAL gAbcdSignal    = ABCD_NONE;
datetime    gAbcdPivotTime = 0;   // time of last pivot used in signal
datetime    gLastTfBarTime = 0;   // reduce repeated scanning

//------------------------- Anti-sideway / max lot state ------------
int      gAtrHandle        = INVALID_HANDLE;
int      gAtrStepHandle    = INVALID_HANDLE;
datetime gLastAtrBarTime   = 0;
bool     gPausedBySideway  = false;
bool     gPausedByMaxLot   = false;

// Pending reprice throttle
datetime gLastPendingRepriceBarTime = 0;

//------------------------- DYNAMIC STEP ----------------------------
int GetCurrentStepPoints()
{
   if(!InpAutoATRStep) return InpStepPoints;
   
   if(gAtrStepHandle == INVALID_HANDLE)
   {
      gAtrStepHandle = iATR(_Symbol, PERIOD_CURRENT, InpATRStepPeriod);
      if(gAtrStepHandle == INVALID_HANDLE) return InpStepPoints;
   }
   
   double atr[];
   ArraySetAsSeries(atr, true);
   // shift=1 to use last completed bar to avoid tick noise jitter
   if(CopyBuffer(gAtrStepHandle, 0, 1, 1, atr) <= 0) return InpStepPoints;
   
   double atrPts = atr[0] / _Point;
   int step = (int)MathRound(atrPts * InpATRStepMultiplier);
   
   if(step < InpMinStepPoints) step = InpMinStepPoints;
   if(InpMaxStepPoints > 0 && step > InpMaxStepPoints) step = InpMaxStepPoints;
   
   return step;
}

//------------------------- UTIL ------------------------------------
void DPrint(const string msg){ if(InpDebugPrint) Print(msg); }

string GVName(const string key)
{
   return StringFormat("ZZH2LV8_%s_%I64u_%s", _Symbol, (long)InpMagic, key);
}

bool SaveState()
{
   if(!InpUseTerminalGlobalVar) return true;
   GlobalVariableSet(GVName("upper"), gUpperPrice);
   GlobalVariableSet(GVName("lower"), gLowerPrice);
   GlobalVariableSet(GVName("nextlot"), gNextLot);
   GlobalVariableSet(GVName("cycles"), (double)gCycles);
   GlobalVariableSet(GVName("last"), (double)gLastTriggered);
   GlobalVariableSet(GVName("started"), gStarted ? 1.0 : 0.0);
   GlobalVariableSet(GVName("pclose"), gPendingCloseAll ? 1.0 : 0.0);
   return true;
}

bool LoadState()
{
   if(!InpUseTerminalGlobalVar) return false;

   bool ok = true;
   if(GlobalVariableCheck(GVName("upper")))   gUpperPrice = GlobalVariableGet(GVName("upper")); else ok=false;
   if(GlobalVariableCheck(GVName("lower")))   gLowerPrice = GlobalVariableGet(GVName("lower")); else ok=false;
   if(GlobalVariableCheck(GVName("nextlot"))) gNextLot    = GlobalVariableGet(GVName("nextlot")); else ok=false;
   if(GlobalVariableCheck(GVName("cycles")))  gCycles     = (int)GlobalVariableGet(GVName("cycles")); else ok=false;
   if(GlobalVariableCheck(GVName("last")))    gLastTriggered = (ZZ_SIDE)(int)GlobalVariableGet(GVName("last")); else ok=false;
   if(GlobalVariableCheck(GVName("started"))) gStarted = (GlobalVariableGet(GVName("started")) > 0.5); else ok=false;
   if(GlobalVariableCheck(GVName("pclose")))  gPendingCloseAll = (GlobalVariableGet(GVName("pclose")) > 0.5); else gPendingCloseAll=false;

   return ok;
}

double NormalizeLot(double lots)
{
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(lots < minLot) lots = minLot;
   if(lots > maxLot) lots = maxLot;

   double steps = MathRound(lots / step);
   lots = steps * step;

   int volDigits = 2;
   if(step >= 1.0) volDigits = 0;
   else if(step >= 0.1) volDigits = 1;

   return NormalizeDouble(lots, volDigits);
}

double PriceByPoints(double price, int points, bool up)
{
   double p = points * _Point;
   return up ? (price + p) : (price - p);
}

bool IsHedgingAccount()
{
   long mode = AccountInfoInteger(ACCOUNT_MARGIN_MODE);
   return (mode == ACCOUNT_MARGIN_MODE_RETAIL_HEDGING);
}

// ✅ ตรวจว่าตอนนี้ส่งคำสั่งเทรดได้ไหม
bool IsTradeAllowedNow()
{
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) return false;
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED)) return false;

   long smode = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE);
   if(smode == SYMBOL_TRADE_MODE_DISABLED) return false;
   if(smode == SYMBOL_TRADE_MODE_CLOSEONLY) return false;

   // optional: บางโบรก freeze trade context ชั่วคราว
   if(IsStopped()) return false;

   return true;
}

bool IsFlatNow()
{
   return (CountPositionsByMagic() == 0);
}

void ResetSequenceStateIfFlat(const string reason)
{
   if(!IsFlatNow())
      return;

   // If no positions remain, ensure we don't keep stale lot/levels from previous cycle.
   if(IsTradeAllowedNow())
      CancelAllPendingsByMagic();

   gStarted = false;
   gCycles = 0;
   gLastTriggered = SIDE_NONE;
   gUpperPrice = 0.0;
   gLowerPrice = 0.0;
   gNextLot = 0.0;
   gPendingCloseAll = false;
   gPausedByMaxLot = false;
   gPausedBySideway = false;

   SaveState();

   if(InpDebugPrint)
      Print("🔄 ResetSequenceStateIfFlat: ", reason);
}

int PendingRepriceThresholdPts()
{
   if(InpPendingRepriceThresholdPoints > 0)
      return InpPendingRepriceThresholdPoints;
   int thr = GetCurrentStepPoints() / 5;
   if(thr < 10) thr = 10;
   return thr;
}

bool ShouldRepricePendingNow()
{
   if(!InpRepricePendingOnNewBar)
      return true;
   datetime bt = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(bt == 0) return true;
   if(bt == gLastPendingRepriceBarTime)
      return false;
   gLastPendingRepriceBarTime = bt;
   return true;
}

double DesiredOppositePendingPrice(const ZZ_SIDE lastSide)
{
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   int stopsLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minDist = stopsLevel * _Point;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   int stepPts = GetCurrentStepPoints();

   if(lastSide == SIDE_BUY)
   {
      // Keep SELL STOP below gUpperPrice by dynamic StepPoints
      double price = PriceByPoints(gUpperPrice, stepPts, false);
      if((bid - price) < minDist)
         price = bid - (minDist + 2*_Point);
      return NormalizeDouble(price, digits);
   }
   else if(lastSide == SIDE_SELL)
   {
      // Keep BUY STOP above gLowerPrice by dynamic StepPoints
      double price = PriceByPoints(gLowerPrice, stepPts, true);
      if((price - ask) < minDist)
         price = ask + (minDist + 2*_Point);
      return NormalizeDouble(price, digits);
   }
   return 0.0;
}

//====================================================================
// Anti-sideway (ATR) + Max lot guard
//====================================================================
bool EnsureAtrHandle()
{
   if(gAtrHandle != INVALID_HANDLE)
      return true;

   if(InpSidewayATRPeriod <= 0)
      return false;

   gAtrHandle = iATR(_Symbol, PERIOD_CURRENT, InpSidewayATRPeriod);
   if(gAtrHandle == INVALID_HANDLE)
   {
      if(InpDebugPrint)
         Print("Sideway: failed to create ATR handle. err=", GetLastError());
      return false;
   }
   return true;
}

double CurrentATRPoints()
{
   if(InpSidewayATRPeriod <= 0 || InpSidewayMinATRPoints <= 0)
      return 0.0;

   if(!EnsureAtrHandle())
      return 0.0;

   double atr[];
   ArraySetAsSeries(atr, true);
   // shift=1 to use last completed bar to reduce noise
   int copied = CopyBuffer(gAtrHandle, 0, 1, 1, atr);
   if(copied <= 0)
      return 0.0;

   if(atr[0] <= 0.0) return 0.0;
   return atr[0] / _Point;
}

bool IsSidewayNow()
{
   if(InpSidewayMinATRPoints <= 0 || InpSidewayATRPeriod <= 0)
      return false;

   datetime barTime = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(barTime != 0 && barTime == gLastAtrBarTime)
      return gPausedBySideway;

   if(barTime != 0)
      gLastAtrBarTime = barTime;

   double atrPts = CurrentATRPoints();
   bool sideway = (atrPts > 0.0 && atrPts < (double)InpSidewayMinATRPoints);
   gPausedBySideway = sideway;

   if(InpDebugPrint && barTime != 0)
      Print("Sideway ATR pts=", DoubleToString(atrPts, 1), " min=", InpSidewayMinATRPoints, " sideway=", (sideway?"true":"false"));

   return sideway;
}

double ApplyMaxLotLimit(double lots, bool &exceeded)
{
   exceeded = false;
   if(InpMaxLotLimit <= 0.0)
      return lots;
   if(lots <= InpMaxLotLimit)
      return lots;
   exceeded = true;
   return InpMaxLotLimit;
}

//====================================================================
// ABCD (Structure-break) via ZigZag pivots
//====================================================================
struct ZZPivot
{
   int      shift;
   datetime time;
   double   price;
   bool     isHigh;
   bool     isLow;
};

ENUM_TIMEFRAMES ABCD_TF()
{
   if(InpABCDTimeframe == PERIOD_CURRENT)
      return (ENUM_TIMEFRAMES)_Period;
   return InpABCDTimeframe;
}

bool EnsureZigZagHandle()
{
   if(gZigZagHandle != INVALID_HANDLE)
      return true;

   ENUM_TIMEFRAMES tf = ABCD_TF();
   gZigZagHandle = iCustom(_Symbol, tf, InpZigZagPath, InpZigZagDepth, InpZigZagDeviation, InpZigZagBackstep);
   if(gZigZagHandle == INVALID_HANDLE)
   {
      Print("❌ ABCD: failed to create ZigZag handle. path=", InpZigZagPath,
            " tf=", EnumToString(tf),
            " err=", GetLastError());
      return false;
   }
   return true;
}

bool DetectLast4Pivots(ZZPivot &A, ZZPivot &B, ZZPivot &C, ZZPivot &D)
{
   ENUM_TIMEFRAMES tf = ABCD_TF();
   int bars = Bars(_Symbol, tf);
   if(bars <= 0) return false;

   int lookback = InpABCDLookbackBars;
   if(lookback < 100) lookback = 100;
   if(lookback > bars) lookback = bars;

   if(!EnsureZigZagHandle()) return false;

   double zz[];
   ArraySetAsSeries(zz, true);
   int copied = CopyBuffer(gZigZagHandle, 0, 0, lookback, zz);
   if(copied <= 0)
   {
      if(InpDebugPrint)
         Print("ABCD: CopyBuffer ZigZag failed copied=", copied, " err=", GetLastError());
      return false;
   }

   ZZPivot piv[4];
   int found = 0;
   double tol = 2.0 * _Point;

   int startShift = InpABCDConfirmBars;
   if(startShift < 1) startShift = 1;

   for(int shift = startShift; shift < copied && found < 4; ++shift)
   {
      double p = zz[shift];
      if(p == 0.0) continue;

      ZZPivot pv;
      pv.shift = shift;
      pv.time  = iTime(_Symbol, tf, shift);
      pv.price = p;

      double hi = iHigh(_Symbol, tf, shift);
      double lo = iLow(_Symbol, tf, shift);
      pv.isHigh = (MathAbs(p - hi) <= tol);
      pv.isLow  = (MathAbs(p - lo) <= tol);
      if(!pv.isHigh && !pv.isLow)
      {
         double mid = (hi + lo) * 0.5;
         pv.isHigh = (p >= mid);
         pv.isLow  = !pv.isHigh;
      }

      piv[found] = pv; // D, C, B, A (most recent first)
      found++;
   }

   if(found < 4) return false;

   D = piv[0];
   C = piv[1];
   B = piv[2];
   A = piv[3];

   bool alt1 = (A.isHigh && B.isLow && C.isHigh && D.isLow);
   bool alt2 = (A.isLow  && B.isHigh && C.isLow  && D.isHigh);
   if(!alt1 && !alt2) return false;

   double abPts = MathAbs(A.price - B.price) / _Point;
   double bcPts = MathAbs(B.price - C.price) / _Point;
   double cdPts = MathAbs(C.price - D.price) / _Point;
   if(abPts < InpABCDMinLegPoints || bcPts < InpABCDMinLegPoints || cdPts < InpABCDMinLegPoints)
      return false;

   return true;
}

ABCD_SIGNAL ComputeAbcdSignal(const ZZPivot &A, const ZZPivot &B, const ZZPivot &C, const ZZPivot &D)
{
   // Structure-break style framing:
   // Bullish: A(high)->B(low)->C(lower high)->D(lower low) => prepare BUY bias.
   // Bearish: A(low)->B(high)->C(higher low)->D(higher high) => prepare SELL bias.
   bool bullish = (A.isHigh && B.isLow && C.isHigh && D.isLow && C.price < A.price && D.price < B.price);
   bool bearish = (A.isLow && B.isHigh && C.isLow && D.isHigh && C.price > A.price && D.price > B.price);
   if(bullish) return ABCD_BUY;
   if(bearish) return ABCD_SELL;
   return ABCD_NONE;
}

bool UpdateAbcdSignalIfNeeded()
{
   if(InpABCDStartMode == ABCD_START_ALWAYS_BUY && !InpABCDDynamicRefresh)
      return false;

   ENUM_TIMEFRAMES tf = ABCD_TF();
   datetime tfBarTime = iTime(_Symbol, tf, 0);
   if(tfBarTime == 0) return false;

   // Scan at most once per TF bar (keeps it cheap)
   if(gLastTfBarTime == tfBarTime)
      return false;
   gLastTfBarTime = tfBarTime;

   ZZPivot A,B,C,D;
   if(!DetectLast4Pivots(A,B,C,D))
      return false;

   ABCD_SIGNAL sig = ComputeAbcdSignal(A,B,C,D);
   if(sig == ABCD_NONE)
      return false;

   // Update only when last pivot (D) changes
   if(D.time != 0 && D.time != gAbcdPivotTime)
   {
      gAbcdPivotTime = D.time;
      gAbcdSignal = sig;
      if(InpDebugPrint)
      {
         int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
         Print("ABCD updated: ", (sig==ABCD_BUY?"BUY":"SELL"),
               " tf=", EnumToString(tf),
               " A=", DoubleToString(A.price, digits),
               " B=", DoubleToString(B.price, digits),
               " C=", DoubleToString(C.price, digits),
               " D=", DoubleToString(D.price, digits));
      }
      return true;
   }
   return false;
}

//-------------------- SAFE POSITION ITERATION ----------------------
bool SelectPosByIndexSafe(const int index, ulong &ticket_out)
{
   ticket_out = 0;
   if(index < 0 || index >= PositionsTotal()) return false;

   ulong ticket = (ulong)PositionGetTicket(index);
   if(ticket == 0) return false;

   if(!PositionSelectByTicket(ticket)) return false;

   ticket_out = ticket;
   return true;
}

int CountPositionsByMagic()
{
   int cnt = 0;
   for(int i=PositionsTotal()-1; i>=0; --i)
   {
      ulong t=0;
      if(!SelectPosByIndexSafe(i, t)) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      cnt++;
   }
   return cnt;
}

double FloatingProfitByMagic()
{
   double sum = 0.0;
   for(int i=PositionsTotal()-1; i>=0; --i)
   {
      ulong t=0;
      if(!SelectPosByIndexSafe(i, t)) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      sum += PositionGetDouble(POSITION_PROFIT);
   }
   return sum;
}

bool GetLastPosition(ZZ_SIDE &side, double &openPrice, double &vol)
{
   datetime bestTime = 0;
   bool found = false;

   for(int i=PositionsTotal()-1; i>=0; --i)
   {
      ulong t=0;
      if(!SelectPosByIndexSafe(i, t)) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

      datetime tm = (datetime)PositionGetInteger(POSITION_TIME);
      if(!found || tm > bestTime)
      {
         bestTime = tm;
         long type = (long)PositionGetInteger(POSITION_TYPE);
         side = (type == POSITION_TYPE_BUY) ? SIDE_BUY : SIDE_SELL;
         openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
         vol = PositionGetDouble(POSITION_VOLUME);
         found = true;
      }
   }
   return found;
}

void DumpMyPositions()
{
   Print("=== DUMP POSITIONS === sym=", _Symbol, " magic=", (long)InpMagic);
   for(int i=PositionsTotal()-1; i>=0; --i)
   {
      ulong t=0;
      if(!SelectPosByIndexSafe(i, t)) continue;

      string sym  = PositionGetString(POSITION_SYMBOL);
      long   mg   = (long)PositionGetInteger(POSITION_MAGIC);
      long   type = (long)PositionGetInteger(POSITION_TYPE);
      double vol  = PositionGetDouble(POSITION_VOLUME);
      double prf  = PositionGetDouble(POSITION_PROFIT);

      Print("POS ticket=", (long)t,
            " sym=", sym,
            " magic=", mg,
            " type=", (type==POSITION_TYPE_BUY?"BUY":"SELL"),
            " vol=", DoubleToString(vol,2),
            " profit=", DoubleToString(prf,2));
   }
   Print("======================");
}

bool CloseAllPositionsByMagic()
{
   bool ok = true;

   if(!IsTradeAllowedNow())
   {
      // ✅ ตลาดปิด -> รอปิดทีหลัง
      gPendingCloseAll = true;
      SaveState();
      Print("⏸ CloseAll delayed: market closed / trade not allowed now.");
      return false;
   }

   for(int pass=0; pass<10; pass++)
   {
      bool any = false;

      for(int i=PositionsTotal()-1; i>=0; --i)
      {
         ulong t=0;
         if(!SelectPosByIndexSafe(i, t)) continue;

         if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
         if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

         any = true;

         if(!trade.PositionClose(t))
         {
            ok = false;

            int err = GetLastError();
            long rc = (long)trade.ResultRetcode();
            string desc = trade.ResultRetcodeDescription();

            Print("❌ PositionClose failed ticket=", (long)t,
                  " retcode=", rc,
                  " desc=", desc,
                  " err=", err);

            // ✅ ถ้า market closed -> ตั้ง pending close แล้วออก
            if(rc == 10018 || StringFind(desc, "market closed") >= 0 || err == 4756)
            {
               gPendingCloseAll = true;
               SaveState();
               Print("⏸ CloseAll delayed (market closed). Will retry when market opens.");
               return false;
            }
         }
         else
         {
            Print("✅ Closed ticket=", (long)t);
         }
      }

      if(!any) break;
      Sleep(50);
   }

   // ✅ ถ้าปิดหมดแล้ว
   if(CountPositionsByMagic() == 0)
   {
      gPendingCloseAll = false;
      gPausedByMaxLot = false;
      SaveState();
   }

   return ok;
}

//-------------------- ORDERS (PENDING) -----------------------------
bool CancelAllPendingsByMagic()
{
   bool ok = true;

   if(!IsTradeAllowedNow())
   {
      // ตลาดปิด ไม่ต้องลบก็ได้ รอเปิดค่อยจัดการ
      return false;
   }

   for(int i=OrdersTotal()-1; i>=0; --i)
   {
      ulong ticket = (ulong)OrderGetTicket(i);
      if(ticket == 0) continue;

      if((ulong)OrderGetInteger(ORDER_MAGIC) != InpMagic) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;

      ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(type==ORDER_TYPE_BUY_STOP || type==ORDER_TYPE_SELL_STOP ||
         type==ORDER_TYPE_BUY_LIMIT|| type==ORDER_TYPE_SELL_LIMIT ||
         type==ORDER_TYPE_BUY_STOP_LIMIT || type==ORDER_TYPE_SELL_STOP_LIMIT)
      {
         if(!trade.OrderDelete(ticket))
            ok = false;
      }
   }
   return ok;
}

bool PendingExists(const ENUM_ORDER_TYPE wantType, ulong &ticket_out, double &price_out)
{
   ticket_out = 0;
   price_out  = 0.0;

   for(int i=OrdersTotal()-1; i>=0; --i)
   {
      ulong ticket = (ulong)OrderGetTicket(i);
      if(ticket == 0) continue;

      if((ulong)OrderGetInteger(ORDER_MAGIC) != InpMagic) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;

      ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(type != wantType) continue;

      ticket_out = ticket;
      price_out  = OrderGetDouble(ORDER_PRICE_OPEN);
      return true;
   }
   return false;
}

void DeleteDuplicatePendings(const ENUM_ORDER_TYPE wantType, const bool keepNewest=true)
{
   ulong keepTicket = 0;
   datetime keepTime = 0;

   for(int i=OrdersTotal()-1; i>=0; --i)
   {
      ulong tk = (ulong)OrderGetTicket(i);
      if(tk==0) continue;

      if((ulong)OrderGetInteger(ORDER_MAGIC) != InpMagic) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;

      ENUM_ORDER_TYPE tp = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(tp != wantType) continue;

      datetime t = (datetime)OrderGetInteger(ORDER_TIME_SETUP);

      if(keepTicket==0)
      {
         keepTicket = tk;
         keepTime   = t;
      }
      else
      {
         if(keepNewest)
         {
            if(t > keepTime) { keepTicket = tk; keepTime = t; }
         }
         else
         {
            if(t < keepTime) { keepTicket = tk; keepTime = t; }
         }
      }
   }

   if(!IsTradeAllowedNow()) return;

   for(int i=OrdersTotal()-1; i>=0; --i)
   {
      ulong tk = (ulong)OrderGetTicket(i);
      if(tk==0 || tk==keepTicket) continue;

      if((ulong)OrderGetInteger(ORDER_MAGIC) != InpMagic) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;

      ENUM_ORDER_TYPE tp = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(tp != wantType) continue;

      trade.OrderDelete(tk);
   }
}

//------------------------- SL/TP ------------------------------------
void ApplySLTPForOpenedPosition(ZZ_SIDE side, double openPrice)
{
   if(InpSL_Points<=0 && InpTP_Points<=0) return;
   if(!IsTradeAllowedNow()) return;

   for(int i=PositionsTotal()-1; i>=0; --i)
   {
      ulong t=0;
      if(!SelectPosByIndexSafe(i, t)) continue;

      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

      long type = (long)PositionGetInteger(POSITION_TYPE);
      double pOpen = PositionGetDouble(POSITION_PRICE_OPEN);

      if((side==SIDE_BUY && type==POSITION_TYPE_BUY) || (side==SIDE_SELL && type==POSITION_TYPE_SELL))
      {
         if(MathAbs(pOpen - openPrice) <= (2*_Point))
         {
            double sl=0,tp=0;
            if(side==SIDE_BUY)
            {
               if(InpSL_Points>0) sl = PriceByPoints(pOpen, InpSL_Points, false);
               if(InpTP_Points>0) tp = PriceByPoints(pOpen, InpTP_Points, true);
            }
            else
            {
               if(InpSL_Points>0) sl = PriceByPoints(pOpen, InpSL_Points, true);
               if(InpTP_Points>0) tp = PriceByPoints(pOpen, InpTP_Points, false);
            }
            trade.PositionModify(t, sl, tp);
            break;
         }
      }
   }
}

//====================================================================
// LOT PROGRESSION
//====================================================================
double GetNextLot_ADD(const double lastVol){ return NormalizeLot(lastVol + InpLotAdd); }
double GetNextLot_MUL(const double lastVol){ return NormalizeLot(lastVol * InpLotMultiplier); }

double GetNextLot(const double lastVol)
{
   double nxt = (InpLotMode == LOT_MUL) ? GetNextLot_MUL(lastVol) : GetNextLot_ADD(lastVol);
   bool exceeded=false;
   nxt = ApplyMaxLotLimit(nxt, exceeded);
   if(exceeded && InpPauseOnMaxLot)
      gPausedByMaxLot = true;
   return nxt;
}

double GetFirstOppLot()
{
   double lot;
   if(InpFirstOppLot > 0.0) lot = NormalizeLot(InpFirstOppLot);
   else if(InpLotMode == LOT_MUL) lot = NormalizeLot(InpStartLot * InpLotMultiplier);
   else lot = NormalizeLot(InpStartLot + InpLotAdd);

   bool exceeded=false;
   lot = ApplyMaxLotLimit(lot, exceeded);
   if(exceeded && InpPauseOnMaxLot)
      gPausedByMaxLot = true;
   return lot;
}

//====================================================================
// TRAILING STOP (ONE-SIDED)
//====================================================================
void CountSides(int &buyCount, int &sellCount)
{
   buyCount = 0; sellCount = 0;
   for(int i=PositionsTotal()-1; i>=0; --i)
   {
      ulong t=0;
      if(!SelectPosByIndexSafe(i, t)) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      long type = (long)PositionGetInteger(POSITION_TYPE);
      if(type == POSITION_TYPE_BUY) buyCount++;
      else if(type == POSITION_TYPE_SELL) sellCount++;
   }
}

void ManageTrailingStop()
{
   if(!InpUseTrailing || InpTrailingStartPoints <= 0 || InpTrailingDistancePoints <= 0) return;
   
   int buyCount=0, sellCount=0;
   CountSides(buyCount, sellCount);
   
   // Apply trailing only if it is one-sided
   if((buyCount > 0 && sellCount > 0) || (buyCount == 0 && sellCount == 0)) return;
   
   if(!IsTradeAllowedNow()) return;
   
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double point = _Point;
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   
   // Safety check against tight stops level
   long stopsLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   double minDist = (stopsLevel > spread ? stopsLevel : spread) * point;
   
   double safeDistancePts = InpTrailingDistancePoints;
   // Safety check 1: Distance must be strictly less than Start (otherwise SL falls in loss territory)
   if(safeDistancePts >= InpTrailingStartPoints)
      safeDistancePts = InpTrailingStartPoints - 10;
   
   double trailDist = safeDistancePts * point;
   
   // Safety check 2: against tight stops level
   if(trailDist < minDist + (2 * point))
      trailDist = minDist + (5 * point); // Force distance to be safe from Invalid Parameters
   
   for(int i=PositionsTotal()-1; i>=0; --i)
   {
      ulong t=0;
      if(!SelectPosByIndexSafe(i, t)) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      
      long type = (long)PositionGetInteger(POSITION_TYPE);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl = PositionGetDouble(POSITION_SL);
      
      if(type == POSITION_TYPE_BUY)
      {
         double profitPts = (bid - openPrice) / point;
         if(profitPts >= InpTrailingStartPoints)
         {
            double newSL = NormalizeDouble(bid - trailDist, digits);
            // Modify only if SL needs to jump up by at least 15 points (anti-spam)
            if(sl == 0.0 || newSL > sl + (15 * point))
            {
               bool ok = trade.PositionModify(t, newSL, PositionGetDouble(POSITION_TP));
               if(!ok && InpDebugPrint) Print("Trailing BUY #", t, " failed: ", trade.ResultRetcodeDescription());
            }
         }
      }
      else if(type == POSITION_TYPE_SELL)
      {
         double profitPts = (openPrice - ask) / point;
         if(profitPts >= InpTrailingStartPoints)
         {
            double newSL = NormalizeDouble(ask + trailDist, digits);
            // Modify only if SL needs to jump down by at least 15 points (anti-spam)
            if(sl == 0.0 || newSL < sl - (15 * point))
            {
               bool ok = trade.PositionModify(t, newSL, PositionGetDouble(POSITION_TP));
               if(!ok && InpDebugPrint) Print("Trailing SELL #", t, " failed: ", trade.ResultRetcodeDescription());
            }
         }
      }
   }
}

//------------------------- CORE LOGIC --------------------------------
bool PlaceOppositeStop(ZZ_SIDE lastSide, double lots)
{
   if(!IsTradeAllowedNow())
   {
      DPrint("Skip PlaceOppositeStop: market closed.");
      return false;
   }

   if(gPausedByMaxLot && InpPauseOnMaxLot)
   {
      DPrint("Skip PlaceOppositeStop: paused by max lot.");
      return false;
   }

   if(IsSidewayNow())
   {
      DPrint("Skip PlaceOppositeStop: sideways (ATR filter).");
      return false;
   }

   lots = NormalizeLot(lots);

   trade.SetExpertMagicNumber((long)InpMagic);
   trade.SetDeviationInPoints(InpSlippagePoints);

   if(InpOnePendingOnly)
      CancelAllPendingsByMagic();

   DeleteDuplicatePendings(ORDER_TYPE_BUY_STOP, true);
   DeleteDuplicatePendings(ORDER_TYPE_SELL_STOP, true);

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   int stopsLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minDist = stopsLevel * _Point;

   if(lastSide == SIDE_BUY)
   {
      ulong t=0; double p=0;
      if(PendingExists(ORDER_TYPE_SELL_STOP, t, p)) return true;

      double price = gLowerPrice;
      if(InpFollowPriceForPending)
      {
         price = DesiredOppositePendingPrice(SIDE_BUY);
         if(price > 0.0)
         {
            gLowerPrice = price;
            gUpperPrice = NormalizeDouble(PriceByPoints(gLowerPrice, GetCurrentStepPoints(), true), (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
         }
      }

      if((bid - price) < minDist)
         price = bid - (minDist + 2*_Point);

      price = NormalizeDouble(price, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
      bool ok = trade.SellStop(lots, price, _Symbol, 0.0, 0.0, ORDER_TIME_GTC, 0, InpComment);
      if(InpDebugPrint && !ok) Print("SellStop failed retcode=", trade.ResultRetcode(), " desc=", trade.ResultRetcodeDescription(), " err=", GetLastError());
      return ok;
   }
   else if(lastSide == SIDE_SELL)
   {
      ulong t=0; double p=0;
      if(PendingExists(ORDER_TYPE_BUY_STOP, t, p)) return true;

      double price = gUpperPrice;
      if(InpFollowPriceForPending)
      {
         price = DesiredOppositePendingPrice(SIDE_SELL);
         if(price > 0.0)
         {
            gUpperPrice = price;
            gLowerPrice = NormalizeDouble(PriceByPoints(gUpperPrice, GetCurrentStepPoints(), false), (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
         }
      }

      if((price - ask) < minDist)
         price = ask + (minDist + 2*_Point);

      price = NormalizeDouble(price, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
      bool ok = trade.BuyStop(lots, price, _Symbol, 0.0, 0.0, ORDER_TIME_GTC, 0, InpComment);
      if(InpDebugPrint && !ok) Print("BuyStop failed retcode=", trade.ResultRetcode(), " desc=", trade.ResultRetcodeDescription(), " err=", GetLastError());
      return ok;
   }
   return false;
}

bool StartSequence()
{
   if(gStarted) return true;

   // new run -> clear pause-by-max-lot
   gPausedByMaxLot = false;

   if(!IsHedgingAccount())
   {
      Print("This EA requires Hedging account mode.");
      return false;
   }

   if(!IsTradeAllowedNow())
   {
      Print("⏸ StartSequence delayed: market closed / trade not allowed now.");
      return false;
   }

   trade.SetExpertMagicNumber((long)InpMagic);
   trade.SetDeviationInPoints(InpSlippagePoints);

   // Refresh ABCD signal (safe: does not touch live positions)
   UpdateAbcdSignalIfNeeded();

   ZZ_SIDE startSide = SIDE_BUY;
   if(InpABCDStartMode != ABCD_START_ALWAYS_BUY)
   {
      if(gAbcdSignal == ABCD_BUY) startSide = SIDE_BUY;
      else if(gAbcdSignal == ABCD_SELL) startSide = SIDE_SELL;
      else if(InpABCDStartMode == ABCD_START_REQUIRE_ABCD)
      {
         Print("⏸ StartSequence blocked: ABCD signal not found yet.");
         return false;
      }
   }

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double lot1 = NormalizeLot(InpStartLot);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   if(startSide == SIDE_BUY)
   {
      gUpperPrice = NormalizeDouble(ask, digits);
      gLowerPrice = NormalizeDouble(PriceByPoints(gUpperPrice, GetCurrentStepPoints(), false), digits);
   }
   else
   {
      gLowerPrice = NormalizeDouble(bid, digits);
      gUpperPrice = NormalizeDouble(PriceByPoints(gLowerPrice, GetCurrentStepPoints(), true), digits);
   }

   bool ok = (startSide==SIDE_BUY)
             ? trade.Buy(lot1, _Symbol, 0.0, 0.0, 0.0, InpComment)
             : trade.Sell(lot1, _Symbol, 0.0, 0.0, 0.0, InpComment);
   if(!ok)
   {
      Print("Failed to open first ", (startSide==SIDE_BUY?"BUY":"SELL"), ". retcode=", trade.ResultRetcode(), " desc=", trade.ResultRetcodeDescription(), " err=", GetLastError());
      return false;
   }

   gLastTriggered = startSide;
   gCycles = 1;

   gNextLot = GetFirstOppLot();
   PlaceOppositeStop(gLastTriggered, gNextLot);

   gStarted = true;
   SaveState();
   return true;
}

void MaintainOppositePending()
{
   if(!IsTradeAllowedNow())
   {
      DPrint("Skip MaintainOppositePending: market closed.");
      return;
   }

   // Safety: if no positions, don't maintain/place pendings with stale state.
   if(IsFlatNow())
   {
      ResetSequenceStateIfFlat("MaintainOppositePending: flat");
      return;
   }

   // Anti-chop: if sideways, remove pendings and wait.
   if(IsSidewayNow())
   {
      if(InpDebugPrint)
         Print("⏸ Sideway filter active -> cancel pendings and pause new legs.");
      CancelAllPendingsByMagic();
      return;
   }

   // Max-lot guard: stop adding new legs (still allows close-all by profit/loss).
   if(gPausedByMaxLot && InpPauseOnMaxLot)
   {
      if(InpDebugPrint)
         Print("⏸ MaxLot guard active -> cancel pendings and pause new legs.");
      CancelAllPendingsByMagic();
      return;
   }

   if(InpTxnCooldownMs > 0)
   {
      ulong now = (ulong)GetTickCount();
      if(gLastDealMs > 0 && (now - gLastDealMs) < (ulong)InpTxnCooldownMs)
         return;
   }

   DeleteDuplicatePendings(ORDER_TYPE_BUY_STOP,  true);
   DeleteDuplicatePendings(ORDER_TYPE_SELL_STOP, true);

   ulong buyT=0, sellT=0;
   double buyP=0, sellP=0;
   bool hasBuyStop  = PendingExists(ORDER_TYPE_BUY_STOP,  buyT,  buyP);
   bool hasSellStop = PendingExists(ORDER_TYPE_SELL_STOP, sellT, sellP);

   if(gLastTriggered == SIDE_BUY)
   {
      if(hasBuyStop) trade.OrderDelete(buyT);
      hasSellStop = PendingExists(ORDER_TYPE_SELL_STOP, sellT, sellP);
      if(InpFollowPriceForPending && ShouldRepricePendingNow())
      {
         double want = DesiredOppositePendingPrice(SIDE_BUY);
         if(want > 0.0)
         {
            int thr = PendingRepriceThresholdPts();
            double diffPts = (hasSellStop ? (MathAbs(sellP - want) / _Point) : (double)(thr + 1));
            if(!hasSellStop || diffPts >= (double)thr)
            {
               if(hasSellStop) trade.OrderDelete(sellT);
               gLowerPrice = want;
               gUpperPrice = NormalizeDouble(PriceByPoints(gLowerPrice, GetCurrentStepPoints(), true), (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
               PlaceOppositeStop(SIDE_BUY, gNextLot);
               SaveState();
               return;
            }
         }
      }
      if(!hasSellStop) PlaceOppositeStop(SIDE_BUY, gNextLot);
   }
   else if(gLastTriggered == SIDE_SELL)
   {
      if(hasSellStop) trade.OrderDelete(sellT);
      hasBuyStop = PendingExists(ORDER_TYPE_BUY_STOP, buyT, buyP);
      if(InpFollowPriceForPending && ShouldRepricePendingNow())
      {
         double want = DesiredOppositePendingPrice(SIDE_SELL);
         if(want > 0.0)
         {
            int thr = PendingRepriceThresholdPts();
            double diffPts = (hasBuyStop ? (MathAbs(buyP - want) / _Point) : (double)(thr + 1));
            if(!hasBuyStop || diffPts >= (double)thr)
            {
               if(hasBuyStop) trade.OrderDelete(buyT);
               gUpperPrice = want;
               gLowerPrice = NormalizeDouble(PriceByPoints(gUpperPrice, GetCurrentStepPoints(), false), (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
               PlaceOppositeStop(SIDE_SELL, gNextLot);
               SaveState();
               return;
            }
         }
      }
      if(!hasBuyStop) PlaceOppositeStop(SIDE_SELL, gNextLot);
   }
}

bool RebuildFromExisting()
{
   int cnt = CountPositionsByMagic();
   if(cnt <= 0) return false;

   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   // anchor upper from oldest BUY if any
   datetime bestOldBuy  = 0;
   bool     foundBuy    = false;
   double   buyPrice    = 0;

   // anchor from oldest SELL if no BUY
   datetime bestOldSell = 0;
   bool     foundSell   = false;
   double   sellPrice   = 0;

   for(int i=PositionsTotal()-1; i>=0; --i)
   {
      ulong t=0;
      if(!SelectPosByIndexSafe(i, t)) continue;

      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

      long type = (long)PositionGetInteger(POSITION_TYPE);
      datetime tm = (datetime)PositionGetInteger(POSITION_TIME);
      double   op = PositionGetDouble(POSITION_PRICE_OPEN);

      if(type == POSITION_TYPE_BUY)
      {
         if(!foundBuy || tm < bestOldBuy)
         {
            bestOldBuy = tm;
            buyPrice   = op;
            foundBuy   = true;
         }
      }
      else if(type == POSITION_TYPE_SELL)
      {
         if(!foundSell || tm < bestOldSell)
         {
            bestOldSell = tm;
            sellPrice   = op;
            foundSell   = true;
         }
      }
   }

   if(foundBuy)
      gUpperPrice = NormalizeDouble(buyPrice, digits);
   else if(foundSell)
   {
      gUpperPrice = NormalizeDouble(PriceByPoints(sellPrice, GetCurrentStepPoints(), true), digits);
      if(InpDebugPrint)
         Print("RebuildFromExisting: no BUY found, anchoring Upper from oldest SELL ",
               DoubleToString(sellPrice, digits), " + Step -> ", DoubleToString(gUpperPrice, digits));
   }
   else
      gUpperPrice = NormalizeDouble(SymbolInfoDouble(_Symbol, SYMBOL_BID), digits);

   gLowerPrice = NormalizeDouble(PriceByPoints(gUpperPrice, GetCurrentStepPoints(), false), digits);

   ZZ_SIDE lastS; double lastP,lastV;
   if(GetLastPosition(lastS,lastP,lastV))
   {
      gLastTriggered = lastS;
      gNextLot = GetNextLot(lastV);
   }
   else
   {
      gLastTriggered = SIDE_BUY;
      gNextLot = GetFirstOppLot();
   }

   gCycles = cnt;
   gStarted = true;

   // ถ้าตลาดปิด ก็แค่เซฟ state ไว้ก่อน
   if(IsTradeAllowedNow())
      MaintainOppositePending();

   SaveState();
   return true;
}

void CheckProfitLossCloseAll()
{
   double fp = FloatingProfitByMagic();

   if(InpDebugPrint)
      Print("DBG fp=", DoubleToString(fp,2),
            " target=", DoubleToString(InpProfitTargetMoney,2),
            " closeOnProfit=", (InpCloseAllOnProfit?"true":"false"),
            " sym=", _Symbol, " magic=", (long)InpMagic);

   if(InpCloseAllOnProfit && fp >= InpProfitTargetMoney)
   {
      Print("🏁 Profit target hit. fp=", DoubleToString(fp,2), " >= ", DoubleToString(InpProfitTargetMoney,2));
      DumpMyPositions();

      // ✅ ถ้าตลาดปิด -> ตั้งธงรอปิด
      if(!IsTradeAllowedNow())
      {
         gPendingCloseAll = true;
         SaveState();
         Print("⏸ Profit hit but market closed. Will close when market opens.");
         return;
      }

      CancelAllPendingsByMagic();
      bool closeOk = CloseAllPositionsByMagic();

      int left = CountPositionsByMagic();
      if(left == 0)
      {
         gStarted=false;
         gPendingCloseAll=false;
         gPausedByMaxLot=false;
      }
      else
      {
         // If any close failed or not all positions closed yet, keep retrying on timer.
         gPendingCloseAll = true;
         if(!closeOk)
            Print("⚠️ Close-all not finished yet (will retry on timer). left=", left);
         else
            Print("⚠️ Close-all partial (will retry on timer). left=", left);
      }
      SaveState();
      return;
   }

   if(InpCloseAllOnLoss && fp <= InpLossLimitMoney)
   {
      Print("🛑 Loss limit hit. fp=", DoubleToString(fp,2), " <= ", DoubleToString(InpLossLimitMoney,2));
      DumpMyPositions();

      if(!IsTradeAllowedNow())
      {
         gPendingCloseAll = true;
         SaveState();
         Print("⏸ Loss hit but market closed. Will close when market opens.");
         return;
      }

      CancelAllPendingsByMagic();
      bool closeOk = CloseAllPositionsByMagic();

      int left = CountPositionsByMagic();
      if(left == 0)
      {
         gStarted=false;
         gPendingCloseAll=false;
         gPausedByMaxLot=false;
      }
      else
      {
         gPendingCloseAll = true;
         if(!closeOk)
            Print("⚠️ Close-all not finished yet (will retry on timer). left=", left);
         else
            Print("⚠️ Close-all partial (will retry on timer). left=", left);
      }
      SaveState();
      return;
   }
}

//------------------------- MARKET OPEN/CLOSE MONITOR ----------------
void HandleMarketOpenClose()
{
   bool allow = IsTradeAllowedNow();

   if(!allow)
   {
      if(!gMarketWasClosed)
      {
         gMarketWasClosed = true;
         Print("⏸ Market became CLOSED (trade not allowed). EA will wait.");
      }
      return;
   }

   // now allowed
   if(gMarketWasClosed)
   {
      gMarketWasClosed = false;
      Print("✅ Market became OPEN again. EA will resume pending/close tasks.");

      // If user manually closed everything while market was closed, reset state/lot.
      if(IsFlatNow())
      {
         ResetSequenceStateIfFlat("Market open: flat after close");
         return;
      }

      // ถ้ามีธงรอปิด
      if(gPendingCloseAll)
      {
         Print("🔁 Retry pending close-all now that market is open...");
         CancelAllPendingsByMagic();
         CloseAllPositionsByMagic();

         if(CountPositionsByMagic()==0)
         {
            gPendingCloseAll=false;
            gStarted=false; // ปิดหมดแล้ว
            gPausedByMaxLot=false;
            SaveState();
            Print("✅ Pending close-all completed.");
         }
         else
         {
            SaveState();
            Print("⚠️ Pending close-all not finished yet (will retry on timer).");
         }
      }
      else
      {
         // ถ้าไม่ได้ pending close ก็ rebuild pending ให้ครบ
         int cnt = CountPositionsByMagic();
         if(cnt > 0)
         {
            if(!gStarted)
               RebuildFromExisting();
            if(gStarted)
               MaintainOppositePending();
         }
      }
   }
}

//------------------------- EVENTS ----------------------------------
int OnInit()
{
   trade.SetExpertMagicNumber((long)InpMagic);
   trade.SetDeviationInPoints(InpSlippagePoints);

   // Prime ABCD signal early (best-effort)
   if(InpABCDStartMode != ABCD_START_ALWAYS_BUY || InpABCDDynamicRefresh)
      UpdateAbcdSignalIfNeeded();

   LoadState();

   // If flat on attach, reset lot/levels so next run starts from InpStartLot.
   ResetSequenceStateIfFlat("OnInit: flat");

   // ถ้ามี position อยู่แล้ว -> rebuild
   if(!gStarted || gUpperPrice<=0 || gLowerPrice<=0 || gLastTriggered==SIDE_NONE)
      RebuildFromExisting();

   if(InpTimerSeconds > 0)
      EventSetTimer(InpTimerSeconds);

   // auto start
   if(InpAutoStart)
   {
      if(!gStarted && CountPositionsByMagic()==0)
         StartSequence();
   }

   // Ensure pending exists/updated immediately after attach (especially after EA stop/restart)
   if(IsTradeAllowedNow() && !gPendingCloseAll && CountPositionsByMagic() > 0)
      MaintainOppositePending();

   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   SaveState();
   EventKillTimer();

   if(gZigZagHandle != INVALID_HANDLE)
   {
      IndicatorRelease(gZigZagHandle);
      gZigZagHandle = INVALID_HANDLE;
   }

   if(gAtrHandle != INVALID_HANDLE)
   {
      IndicatorRelease(gAtrHandle);
      gAtrHandle = INVALID_HANDLE;
   }
}

void OnTimer()
{
   // ✅ ให้ timer เป็นตัวคอยรีทรายตอนตลาดกลับมาเปิด
   HandleMarketOpenClose();

   // If flat, reset state/lot (covers manual close scenarios)
   ResetSequenceStateIfFlat("OnTimer: flat");

   // Refresh ABCD signal periodically (at most once per TF bar)
   if(InpABCDStartMode != ABCD_START_ALWAYS_BUY || InpABCDDynamicRefresh)
      UpdateAbcdSignalIfNeeded();

   if(!gStarted) return;

   if(gPendingCloseAll)
   {
      // ถ้ายัง pending close อยู่ ให้พยายามซ้ำเป็นระยะ
      if(IsTradeAllowedNow())
      {
         Print("🔁 Timer retry close-all ...");
         CancelAllPendingsByMagic();
         CloseAllPositionsByMagic();
         if(CountPositionsByMagic()==0)
         {
            gPendingCloseAll=false;
            gStarted=false;
            gPausedByMaxLot=false;
            SaveState();
            Print("✅ Timer close-all completed.");
         }
      }
      return;
   }

   // ถ้าตลาดเปิดอยู่ ก็รักษา pending ไว้ให้ครบ (บางที OnTick เงียบ)
   if(IsTradeAllowedNow())
   {
      MaintainOppositePending();
      ManageTrailingStop();
   }
}

void OnTick()
{
   HandleMarketOpenClose();

   // If flat, reset state/lot (covers manual close scenarios)
   ResetSequenceStateIfFlat("OnTick: flat");

   // Refresh ABCD signal on new TF bar (won't alter existing positions)
   if(InpABCDStartMode != ABCD_START_ALWAYS_BUY || InpABCDDynamicRefresh)
      UpdateAbcdSignalIfNeeded();

   if(InpAutoStart && !gStarted)
   {
      if(CountPositionsByMagic()==0)
         StartSequence();
   }

   if(!gStarted) return;

   if(gPendingCloseAll)
      return; // กำลังรอปิดทั้งหมดอยู่ อย่าเปิดเพิ่ม

   if(InpMaxCycles > 0 && gCycles >= InpMaxCycles)
   {
      if(IsTradeAllowedNow())
         CancelAllPendingsByMagic();
      CheckProfitLossCloseAll();
      return;
   }

   CheckProfitLossCloseAll();
   if(!gStarted) return;

   MaintainOppositePending();
   ManageTrailingStop();
}

void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest& request,
                        const MqlTradeResult& result)
{
   if(!gStarted) return;
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
   if(trans.deal == 0) return;

   if(trans.deal == gLastDealProcessed) return;
   gLastDealProcessed = trans.deal;

   gLastDealMs = (ulong)GetTickCount();

   if(!HistoryDealSelect(trans.deal)) return;

   ulong  dealMagic  = (ulong)HistoryDealGetInteger(trans.deal, DEAL_MAGIC);
   string dealSymbol = HistoryDealGetString(trans.deal, DEAL_SYMBOL);
   if(dealMagic != InpMagic) return;
   if(dealSymbol != _Symbol) return;

   long dealType = (long)HistoryDealGetInteger(trans.deal, DEAL_TYPE);
   if(dealType != DEAL_TYPE_BUY && dealType != DEAL_TYPE_SELL) return;

   ZZ_SIDE newSide = (dealType == DEAL_TYPE_BUY) ? SIDE_BUY : SIDE_SELL;
   double  price   = HistoryDealGetDouble(trans.deal, DEAL_PRICE);
   double  vol     = HistoryDealGetDouble(trans.deal, DEAL_VOLUME);

   gLastTriggered = newSide;
   gCycles++;

   ApplySLTPForOpenedPosition(newSide, price);

   gNextLot = GetNextLot(vol);

   if(InpMaxCycles > 0 && gCycles >= InpMaxCycles)
   {
      if(IsTradeAllowedNow())
         CancelAllPendingsByMagic();
      SaveState();
      return;
   }

   if(!IsTradeAllowedNow())
   {
      // ตลาดปิดก็เก็บ state ไว้ก่อน เดี๋ยว timer/open event ค่อย rebuild pending
      SaveState();
      return;
   }

   DeleteDuplicatePendings(ORDER_TYPE_BUY_STOP,  true);
   DeleteDuplicatePendings(ORDER_TYPE_SELL_STOP, true);

   PlaceOppositeStop(gLastTriggered, gNextLot);
   SaveState();
}
//+------------------------------------------------------------------+
