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
#include "Export.mqh"
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
input int LogExitEvery = 0;	//	Log the exit state every N bars of an open position (0 = off)
input int ExportEvery = 0;	//	Export every Nth matured sample to InOutNet_samples.csv (0 = off)
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
int gFlat = 0, gDirN = 0, gDirHit = 0, gDirNAll = 0, gDirHitAll = 0, gSat = 0, gNFAll = 0, gFAll = 0;
double gActNFAll = 0, gActFAll = 0;
int gAtr = INVALID_HANDLE;
ulong gPosTicket = 0;	//	our open position, as seen by TrackPosition
double gPosPeak = 0;	//	best mark-to-market pnl of it since open, in price units

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
    LogInit(LogFile);
    if(ExportEvery > 0)
        ExportOpen("InOutNet_samples.csv");
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
    ExportClose();
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
    TrackPosition();

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
            double oB, oS;
            double const bMax = sam.buy.peak - sam.buy.entry, sMax = sam.sell.entry - sam.sell.dip, th = Threshold(sam);
            LabelExcessShare(bMax, sMax, th, oB, oS);
            if(ExportEvery > 0 && gIn.Trained() % ExportEvery == 0)
                ExportRow(sam, bMax, sMax, th, oB, oS);
            //	metrics use the prediction made at entry (weights then knew nothing about this outcome);
            //	the Think below is only to set the activations for Learn
            gIn.Think(ToInput(sam.state));
            gIn.Learn(oB, oS);
            gLossSum += PairLoss(sam.predBuy, sam.predSell, oB, oS);
            gSumB += oB;
            gSumS += oS;
            //	honest activity check: does the net say 'something will happen' more when it really does?
            double const act = sam.predBuy + sam.predSell;
            if(oB + oS == 0)
            {
                ++gFlat;
                ++gFAll;
                gActFAll += act;
            }
            else
            {
                ++gNFAll;
                gActNFAll += act;
            }
            if(MathMax(sam.predBuy, sam.predSell) > 0.9)
                ++gSat;
            if(MathAbs(oB - oS) > 0.5)   // clearly directional label: did the net pick the right side?
            {
                bool const hit = (sam.predBuy > sam.predSell) == (oB > oS);
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
                Log(StringFormat("trained %d  loss %.4f  base %.4f  prev %.4f  flat %.0f%%  buy %.0f%%  sell %.0f%%  dir %.0f%% (n=%d)  dirAll %.1f%% (n=%d)  sure %.0f%%  actAll flat %.2f / move %.2f",
                                 gIn.Trained(), gLossSum / LogEvery, base, prev,
                                 100.0 * gFlat / LogEvery, 100.0 * gSumB / LogEvery, 100.0 * gSumS / LogEvery,
                                 gDirN > 0 ? 100.0 * gDirHit / gDirN : 0.0, gDirN,
                                 gDirNAll > 0 ? 100.0 * gDirHitAll / gDirNAll : 0.0, gDirNAll,
                                 100.0 * gSat / LogEvery,
                                 gFAll > 0 ? gActFAll / gFAll : 0.0, gNFAll > 0 ? gActNFAll / gNFAll : 0.0));
                gPrevB = gSumB / LogEvery;
                gPrevS = gSumS / LogEvery;
                gLossSum = gSumB = gSumS = 0;
                gFlat = gDirN = gDirHit = gSat = 0;
            }
        }
        //	the network's call for this bar, made once with the weights it has now
        Vector const out = gIn.Think(ToInput(enStt));
        //	add new virtual trades buy and sell
        entrySams.Add(Entry::Sample(enStt, current_bar_time, atr, lastTick, out.Get(0), out.Get(1)));
        g_last_bar_time = current_bar_time;

        if(gIn.Trained() < WarmUp)
            return;

        //	trading
        if(SelectOurPosition())
        {
            Exit::State exStt;
            CollectState(exStt, enStt, atr);   // zeroed on failure: a bad state never blocks the exit
            if(ShouldClose(gOut.Think(ToInput(exStt))))
                CloseTrade();
        }
        else
        {
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
//	exit side: the position's point of view; call only while our position is selected
void CollectState(Exit::State &state, Entry::State const &market, double atr)
{
    datetime const opened = (datetime)PositionGetInteger(POSITION_TIME);
    int const age = iBarShift(Symbol(), Period(), opened);
    bool const isBuy = PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY;
    if(!MakeExitState(state, market, isBuy, PositionPnl(), gPosPeak, age, atr, Window))
    {
        for(int i = 0; i < EXIT_FEATURES; i++)
            state.f[i] = 0.0;
        return;
    }
    if(LogExitEvery > 0 && age % LogExitEvery == 0)
    {
        string line = StringFormat("exit state age %d:", age);
        for(int i = 0; i < EXIT_FEATURES; i++)
            line += StringFormat(" %.2f", state.f[i]);
        Log(line);
    }
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
//| Mark-to-market pnl of the selected position, in price units.     |
//| POSITION_PRICE_CURRENT is the price we would close at (bid for a |
//| buy, ask for a sell), so the exit cost is already in it.         |
//+------------------------------------------------------------------+
double PositionPnl()
{
    double const dir = PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY ? 1.0 : -1.0;
    return dir * (PositionGetDouble(POSITION_PRICE_CURRENT) - PositionGetDouble(POSITION_PRICE_OPEN));
}
//+------------------------------------------------------------------+
//| Every tick: keep the best pnl of our position since it opened.   |
//+------------------------------------------------------------------+
void TrackPosition()
{
    if(!SelectOurPosition())
    {
        gPosTicket = 0;
        return;
    }
    ulong const ticket = (ulong)PositionGetInteger(POSITION_TICKET);
    double const pnl = PositionPnl();
    gPosPeak = ticket == gPosTicket ? MathMax(gPosPeak, pnl) : pnl;
    gPosTicket = ticket;
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
double PairLoss(double pB, double pS, double tB, double tS)   // mean cross-entropy of the two outputs
{
    return 0.5 * (CrossEntropy(tB, 1, pB) + CrossEntropy(tS, 1, pS));
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
