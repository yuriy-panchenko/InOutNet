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
#include "Features.mqh"
#include "RingBuffer.mqh"
#include "Log.mqh"
#include <Trade/Trade.mqh>

input int Window = 100;
input double MarketTarget = .0;	//	Take profit, in ATR (0 = off)
input double StopLoss = .0;	//	Stop loss, in ATR (0 = off)
input double Cutoff = 0.6;	//	Min network output to open a trade
input double Lots = 0.1;	//	Trade volume
input long Magic = 20261027;	//	Magic number
input double K = 1.0;		//	Good enough, in ATR * sqrt(Window)
input double SpreadMult = 2.0;	//	Good enough floor, in spreads
input int AtrPeriod = 14;	//	ATR period
input double LearnRate = 0.01;	//	Learning rate
input int Seed = 1;	//	Random seed for initial weights
input int WarmUp = 2000;	//	Train this many samples before trading
input int LogEvery = 500;	//	Print training stats every N samples (0 = off)
input string LogFile = "InOutNet_log.txt";	//	Also append log lines to this file in the common folder (empty = off)

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
CTrade gTrade;
double gLossSum = 0, gSumB = 0, gSumS = 0, gPrevB = 0.5, gPrevS = 0.5;
int gFlat = 0, gDirN = 0, gDirHit = 0, gDirNAll = 0, gDirHitAll = 0;
int gAtr = INVALID_HANDLE;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
    LogInit(LogFile);
    Log(StringFormat("=== run %s  Window=%d K=%.3f SpreadMult=%.2f Cutoff=%.3f LearnRate=%.4f Seed=%d WarmUp=%d SL=%.2f TP=%.2f",
                     Symbol(), Window, K, SpreadMult, Cutoff, LearnRate, Seed, WarmUp, StopLoss, MarketTarget));
    MathSrand(Seed);
    gTrade.SetExpertMagicNumber(Magic);
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
        Exit::State exStt;
        if(!CollectState(enStt) || !CollectState(exStt))
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
            double oB, oS;
            LabelExcessShare(sam.buy.peak - sam.buy.entry, sam.sell.entry - sam.sell.dip, Threshold(sam), oB, oS);
            Vector const pred = gIn.Think(ToInput(sam.state));
            gLossSum += gIn.Learn(oB, oS);
            gSumB += oB;
            gSumS += oS;
            if(oB + oS == 0)
                ++gFlat;
            if(MathAbs(oB - oS) > 0.5)   // clearly directional label: did the net pick the right side?
            {
                bool const hit = (pred.Get(0) > pred.Get(1)) == (oB > oS);
                ++gDirN;
                ++gDirNAll;
                if(hit)
                {
                    ++gDirHit;
                    ++gDirHitAll;
                }
            }
            if(LogEvery > 0 && gIn.Trained() % LogEvery == 0)
            {
                //	base: best constant guess for this window; prev: previous window's mean as the guess
                double const base = 0.5 * (CrossEntropy(gSumB, LogEvery, gSumB / LogEvery) + CrossEntropy(gSumS, LogEvery, gSumS / LogEvery));
                double const prev = 0.5 * (CrossEntropy(gSumB, LogEvery, gPrevB) + CrossEntropy(gSumS, LogEvery, gPrevS));
                Log(StringFormat("trained %d  loss %.4f  base %.4f  prev %.4f  flat %.0f%%  buy %.0f%%  sell %.0f%%  dir %.0f%% (n=%d)  dirAll %.1f%% (n=%d)",
                                 gIn.Trained(), gLossSum / LogEvery, base, prev,
                                 100.0 * gFlat / LogEvery, 100.0 * gSumB / LogEvery, 100.0 * gSumS / LogEvery,
                                 gDirN > 0 ? 100.0 * gDirHit / gDirN : 0.0, gDirN,
                                 gDirNAll > 0 ? 100.0 * gDirHitAll / gDirNAll : 0.0, gDirNAll));
                gPrevB = gSumB / LogEvery;
                gPrevS = gSumS / LogEvery;
                gLossSum = gSumB = gSumS = 0;
                gFlat = gDirN = gDirHit = 0;
            }
        }
        //	add new virtual trades buy and sell
        entrySams.Add(Entry::Sample(enStt, current_bar_time, atr, lastTick));
        g_last_bar_time = current_bar_time;

        if(gIn.Trained() < WarmUp)
            return;

        //	trading
        if(SelectOurPosition())
        {
            if(ShouldClose(gOut.Think(ToInput(exStt))))
                CloseTrade();
        }
        else
        {
            Vector const out = gIn.Think(ToInput(enStt));
            int const iShould = ShouldTrade(out);
            if(iShould && MakeTrade(iShould > 0))
                Log(StringFormat("open %s  out buy %.3f sell %.3f", iShould > 0 ? "BUY" : "SELL", out.Get(0), out.Get(1)));
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
    if(trans.type != TRADE_TRANSACTION_DEAL_ADD || !HistoryDealSelect(trans.deal))
        return;
    if(HistoryDealGetInteger(trans.deal, DEAL_MAGIC) != Magic || HistoryDealGetInteger(trans.deal, DEAL_ENTRY) != DEAL_ENTRY_OUT)
        return;
    double const net = HistoryDealGetDouble(trans.deal, DEAL_PROFIT) + HistoryDealGetDouble(trans.deal, DEAL_SWAP)
                       + HistoryDealGetDouble(trans.deal, DEAL_COMMISSION);
    Log(StringFormat("close  net %.2f  balance %.2f", net, AccountInfoDouble(ACCOUNT_BALANCE)));
}
//+------------------------------------------------------------------+
bool CollectState(Entry::State &state)
{
    double atr;
    return ReadAtr(atr) && MakeEntryState(state, atr, lastTick.ask - lastTick.bid);
}
//	exit side: placeholders until the exit network is designed
bool CollectState(Exit::State &state)
{
    state._ = 0;
    return true;
}
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
Vector ToInput(Exit::State const &state)
{
    return Vector(EXIT_INPUT_SIZE, 0.0);
}
//+------------------------------------------------------------------+
//| Trading                                                          |
//+------------------------------------------------------------------+
bool SelectOurPosition()
{
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        if(PositionGetTicket(i) == 0)
            continue;
        if(PositionGetString(POSITION_SYMBOL) == Symbol() && PositionGetInteger(POSITION_MAGIC) == Magic)
            return true;
    }
    return false;
}
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
int ShouldTrade(Vector const &out)   // +1 buy, -1 sell, 0 stay out
{
    double const b = out.Get(0), s = out.Get(1);
    if(b > s && b > Cutoff)
        return 1;
    if(s > b && s > Cutoff)
        return -1;
    return 0;
}
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool ShouldClose(Vector const&)   // placeholder: close after the training horizon
{
    datetime const opened = (datetime)PositionGetInteger(POSITION_TIME);
    return iBarShift(Symbol(), Period(), opened) >= Window;
}
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool MakeTrade(bool isBuy)
{
    double atr;
    if(!ReadAtr(atr))
        return false;
    int const digits = (int)SymbolInfoInteger(Symbol(), SYMBOL_DIGITS);
    double const price = isBuy ? lastTick.ask : lastTick.bid;
    double const dir = isBuy ? 1.0 : -1.0;
    double const sl = StopLoss > 0 ? NormalizeDouble(price - dir * StopLoss * atr, digits) : 0;
    double const tp = MarketTarget > 0 ? NormalizeDouble(price + dir * MarketTarget * atr, digits) : 0;
    bool const ok = isBuy ? gTrade.Buy(Lots, Symbol(), 0, sl, tp) : gTrade.Sell(Lots, Symbol(), 0, sl, tp);
    if(!ok)
        PrintFormat("MakeTrade(%s) failed, retcode %d", isBuy ? "buy" : "sell", gTrade.ResultRetcode());
    return ok;
}
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void CloseTrade()
{
    if(!SelectOurPosition())
        return;
    if(!gTrade.PositionClose((ulong)PositionGetInteger(POSITION_TICKET)))
        PrintFormat("CloseTrade failed, retcode %d", gTrade.ResultRetcode());
}
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool ReadAtr(double &atr)
{
    double buf[1];
    if(CopyBuffer(gAtr, 0, 1, 1, buf) != 1 || buf[0] <= 0)
        return false;
    atr = buf[0];
    return true;
}
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
double CrossEntropy(double sum, int n, double p)   // mean loss of guessing constant p for n targets that add up to sum
{
    p = MathMin(MathMax(p, 1e-6), 1.0 - 1e-6);
    return -(sum * MathLog(p) + (n - sum) * MathLog(1.0 - p)) / n;
}
double Threshold(Entry::Sample const &s)
{
    return MathMax(K * s.atr * MathSqrt(Window), SpreadMult * s.spread);
}
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void LabelExcessShare(double b, double s, double th, double &ob, double &os)
{
    double eb = MathMax(b - th, 0), es = MathMax(s - th, 0);
    double sum = eb + es;
    ob = sum > 0 ? eb / sum : 0;
    os = sum > 0 ? es / sum : 0;
}
//+------------------------------------------------------------------+
