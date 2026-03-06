//+------------------------------------------------------------------+
//|                                                Dynamic_Grid_Hedge|
//|                                        Based on Dev.CNXs Logic   |
//|                                         Fixed version by Gemini  |
//+------------------------------------------------------------------+
#property copyright "Your Name"
#property link      ""
#property version   "1.02" // อัปเดตเวอร์ชันแก้เรื่อง Lot

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>

CTrade         trade;
CPositionInfo  posInfo;
CSymbolInfo    symInfo;

//--- Inputs
input double   InpStartLot       = 0.02;       // First Buy/Sell Lot
input double   InpLotMultiplier  = 1.5;        // Lot Multiplier (Martingale)
input int      InpATRPeriod      = 14;         // ATR Period for Sideway/Distance
input int      InpEMAPeriod      = 50;         // EMA Period for Trend
input double   InpTargetProfit   = 10.0;       // Profit Target to Close All ($)
input ulong    InpMagicNumber    = 20260210;   // Magic Number

//--- Handles
int atrHandle;
int emaHandle;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
   symInfo.Name(_Symbol);
   trade.SetExpertMagicNumber(InpMagicNumber);
   
   atrHandle = iATR(_Symbol, PERIOD_CURRENT, InpATRPeriod);
   emaHandle = iMA(_Symbol, PERIOD_CURRENT, InpEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   
   if(atrHandle == INVALID_HANDLE || emaHandle == INVALID_HANDLE)
     {
      Print("Error creating indicators");
      return(INIT_FAILED);
     }
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
   if(!symInfo.RefreshRates()) return;

   // 1. ตรวจสอบกำไรรวม เพื่อทำการ "รวบไม้" (Group Close)
   if(GetTotalProfit() >= InpTargetProfit)
     {
      CloseAllPositionsAndOrders();
      Print("รวบไม้ทำกำไรเรียบร้อยแล้ว!");
      return;
     }

   // 2. ดึงค่า Indicator (ATR & EMA)
   double atr[], ema[];
   CopyBuffer(atrHandle, 0, 0, 1, atr);
   CopyBuffer(emaHandle, 0, 0, 1, ema);
   if(ArraySize(atr) == 0 || ArraySize(ema) == 0) return;

   double currentATR = atr[0];
   double currentEMA = ema[0];
   double ask = symInfo.Ask();
   double bid = symInfo.Bid();

   int totalPositions = PositionsTotal();
   int totalOrders = OrdersTotal();

   // 3. Logic เริ่มต้น: ถ้าไม่มีออเดอร์ ให้เปิดตามเทรนด์ (EMA)
   if(totalPositions == 0 && totalOrders == 0)
     {
      if(ask > currentEMA) // ราคาอยู่บน EMA -> เปิด Buy
        {
         trade.Buy(InpStartLot, _Symbol, ask, 0, 0, "Initial Buy");
        }
      else if(bid < currentEMA) // ราคาอยู่ใต้ EMA -> เปิด Sell
        {
         trade.Sell(InpStartLot, _Symbol, bid, 0, 0, "Initial Sell");
        }
     }
     
   // 4. Logic Grid/Hedge: ถ้าระบบเปิดออเดอร์แล้ว ให้วาง Pending ฝั่งตรงข้าม
   if(totalPositions > 0 && totalOrders == 0)
     {
      // หาระยะ Grid จาก ATR
      double gridDistance = currentATR; 
      
      // หาตำแหน่งล่าสุดที่เปิดจริงๆ โดยอ้างอิงจาก Ticket สูงสุด
      ulong lastTicket = 0;
      long type = -1;
      double lastLot = 0;
      double openPrice = 0;
      
      for(int i = 0; i < totalPositions; i++)
        {
         ulong t = PositionGetTicket(i);
         if(t > lastTicket) 
           {
            lastTicket = t;
            type = PositionGetInteger(POSITION_TYPE);
            lastLot = PositionGetDouble(POSITION_VOLUME);
            openPrice = PositionGetDouble(POSITION_PRICE_OPEN); // <-- ล็อกราคาเปิดไว้
           }
        }
      
      if(lastTicket > 0)
        {
         double nextLot = lastLot * InpLotMultiplier; // คูณ Lot แบบ Martingale
         
         // --- เริ่มต้นส่วนการปัดเศษ Lot (Normalize Volume) ---
         double volStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
         double volMin  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
         double volMax  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
         
         // ปัดเศษให้เข้ากับ Step ของโบรคเกอร์ (ป้องกัน Error Invalid Volume)
         if(volStep > 0)
           {
            nextLot = MathRound(nextLot / volStep) * volStep;
           }
         
         // จำกัด Lot ไม่ให้ต่ำกว่าหรือสูงกว่าที่โบรคเกอร์อนุญาต
         if(nextLot < volMin) nextLot = volMin;
         if(nextLot > volMax) nextLot = volMax;
         // --- สิ้นสุดส่วนการปัดเศษ Lot ---
         
         if(type == POSITION_TYPE_BUY)
           {
            // คำนวณจุดวาง SELL STOP จาก "ราคาเปิดของไม้ Buy ล่าสุด"
            double priceLevel = openPrice - gridDistance;
            
            // เช็กว่าราคายังไม่ไหลทะลุจุดที่จะวาง
            if(bid > priceLevel)
              {
               trade.SellStop(nextLot, priceLevel, _Symbol, 0, 0, ORDER_TIME_GTC, 0, "Pending Hedge Sell");
              }
            else // ถ้าราคากระชากลงแรงจนทะลุจุดวางไปแล้ว ให้ยิง Market สวนทันที
              {
               trade.Sell(nextLot, _Symbol, bid, 0, 0, "Market Hedge Sell (Fast Drop)");
              }
           }
         else if(type == POSITION_TYPE_SELL)
           {
            // คำนวณจุดวาง BUY STOP จาก "ราคาเปิดของไม้ Sell ล่าสุด"
            double priceLevel = openPrice + gridDistance;
            
            if(ask < priceLevel)
              {
               trade.BuyStop(nextLot, priceLevel, _Symbol, 0, 0, ORDER_TIME_GTC, 0, "Pending Hedge Buy");
              }
            else
              {
               trade.Buy(nextLot, _Symbol, ask, 0, 0, "Market Hedge Buy (Fast Spike)");
              }
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| ฟังก์ชันหาค่ากำไรสุทธิรวม (Equity Profit)                               |
//+------------------------------------------------------------------+
double GetTotalProfit()
  {
   double totalProfit = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket))
        {
         if(PositionGetInteger(POSITION_MAGIC) == InpMagicNumber && PositionGetString(POSITION_SYMBOL) == _Symbol)
           {
            totalProfit += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
           }
        }
     }
   return totalProfit;
  }

//+------------------------------------------------------------------+
//| ฟังก์ชันเคลียร์ออเดอร์ทั้งหมด (Positions & Pending Orders)              |
//+------------------------------------------------------------------+
void CloseAllPositionsAndOrders()
  {
   // ปิด Positions (ออเดอร์ที่เปิดอยู่)
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket))
        {
         if(PositionGetInteger(POSITION_MAGIC) == InpMagicNumber && PositionGetString(POSITION_SYMBOL) == _Symbol)
           {
            trade.PositionClose(ticket);
           }
        }
     }
   // ลบ Pending Orders
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong ticket = OrderGetTicket(i);
      if(OrderSelect(ticket))
        {
         if(OrderGetInteger(ORDER_MAGIC) == InpMagicNumber && OrderGetString(ORDER_SYMBOL) == _Symbol)
           {
            trade.OrderDelete(ticket);
           }
        }
     }
  }