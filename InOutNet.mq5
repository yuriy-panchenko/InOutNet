//+------------------------------------------------------------------+
//|                                                     InOutNet.mq5 |
//|                                  Copyright 2025, MetaQuotes Ltd. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025, MetaQuotes Ltd."
#property link      "https://www.mql5.com"
#property version   "1.00"

#include "Types.mqh"
#include "Network.mqh"
#include "RingBuffer.mqh"

input int Window = 100;
input double MarketTarget = .0;	//	Market Target
input double StopLoss = .0;	//	Stop Loss
input double K = 1.0;		//	Good enough, in ATR * sqrt(Window)
input double SpreadMult = 2.0;	//	Good enough floor, in spreads
input int AtrPeriod = 14;	//	ATR period
input double LearnRate = 0.01;	//	Learning rate
input int Seed = 1;	//	Random seed for initial weights

//+------------------------------------------------------------------+
const int ENTRY_INPUT_SIZE = sizeof(Entry::State) / sizeof(double);
const int EXIT_INPUT_SIZE = sizeof(Exit::State) / sizeof(double);
const int TOPOLOGY_ENTRY[] = {ENTRY_INPUT_SIZE, ENTRY_INPUT_SIZE * 2, ENTRY_INPUT_SIZE * 2, 10, 2};
const int TOPOLOGY_EXIT[] = {EXIT_INPUT_SIZE, EXIT_INPUT_SIZE * 2, EXIT_INPUT_SIZE * 2, 10, 1};

datetime g_last_bar_time;
Network gIn, gOut;
RingBuffer<Entry::Sample> entrySams(Window);
RingBuffer<Exit::Sample> exitSams(Window);
MqlTick lastTick;
int gAtr = INVALID_HANDLE;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
    MathSrand(Seed);
    gIn.Init(TOPOLOGY_ENTRY, LearnRate);
    gOut.Init(TOPOLOGY_EXIT, LearnRate);
//---
    gAtr = iATR(Symbol(), Period(), AtrPeriod);
    if(gAtr == INVALID_HANDLE)
        return INIT_FAILED;
    g_last_bar_time = iTime(Symbol(), Period(), 0);
    if(!SymbolInfoTick(Symbol(), lastTick))
        return INIT_FAILED;
    return(INIT_SUCCEEDED);
}
//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    if(gAtr != INVALID_HANDLE)
        IndicatorRelease(gAtr);
}
//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
    datetime const current_bar_time = iTime(Symbol(), Period(), 0);
    if(current_bar_time == 0)
        return;
    if(!SymbolInfoTick(Symbol(), lastTick))
        return;
    bool const isNewBar = current_bar_time != g_last_bar_time;

    //	update all virtual trades with current bis/ask
    entrySams.Update(lastTick);

    if(isNewBar)
    {
        Entry::State enStt;
        if(!CollectState(enStt))
            return;
        double atr;
        if(!ReadAtr(atr))
            return;
        //	collect finished v. trades
        if(entrySams.HasReady())
        {
            Entry::Sample sam;
            entrySams.GetReady(sam);
            //	teach network(s) on ready samples and clean used trades
            double const bMax = sam.buy.peak - sam.buy.entry, sMax = sam.sell.entry - sam.sell.dip;
            double const th = Threshold(sam);
            double oB, oS;
            LabelExcessShare(bMax, sMax, th, oB, oS);
            gIn.Think(ToInput(sam.state));
            gIn.Learn(oB, oS);
        }
        //	add new virtual trades buy and sell
        entrySams.Add(Entry::Sample(enStt, current_bar_time, atr, lastTick));
        g_last_bar_time = current_bar_time;

        //	trading
        if(PositionSelect(Symbol()))
        {
            Exit::State state;

            if(!CollectState(state))
                return;

            Vector out = gOut.Think(ToInput(state));

            if(ShouldClose(out))
                CloseTrade();
        }
        else
        {
            Vector out = gIn.Think(ToInput(enStt));
            int const iShould = ShouldTrade(out);
            if(iShould)
                MakeTrade(iShould > 0);
        }
    }
}
//+------------------------------------------------------------------+
//| TradeTransaction function                                        |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest& request,
                        const MqlTradeResult& result)
{
//---

}
//+------------------------------------------------------------------+
bool CollectState(Entry::State &state);	// 0 is just created
bool CollectState(Exit::State &state);
Vector ToInput(Entry::State const &state);
Vector ToInput(Exit::State const &state);
bool ShouldClose(Vector const&);
void CloseTrade();
int ShouldTrade(Vector const&);
bool MakeTrade(bool isBuy);
bool ReadAtr(double &atr)
{
    double buf[1];
    if(CopyBuffer(gAtr, 0, 1, 1, buf) != 1 || buf[0] <= 0)
        return false;
    atr = buf[0];
    return true;
}
double Threshold(Entry::Sample const &s)
{
    return MathMax(K * s.atr * MathSqrt(Window), SpreadMult * s.spread);
}
void LabelExcessShare(double b, double s, double th, double &ob, double &os)
{
    double eb = MathMax(b - th, 0), es = MathMax(s - th, 0);
    double sum = eb + es;
    ob = sum > 0 ? eb / sum : 0;
    os = sum > 0 ? es / sum : 0;
}
//+------------------------------------------------------------------+
