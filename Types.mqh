//+------------------------------------------------------------------+
//|                                                      ProjectName |
//|                                      Copyright 2020, CompanyName |
//|                                       http://www.companyname.net |
//+------------------------------------------------------------------+
#ifndef INCLUDE_TYPES
#define INCLUDE_TYPES

#define ENTRY_FEATURES 14   // keep in sync with Features.mqh
#define EXIT_FEATURES (ENTRY_FEATURES + 5)   // mirrored market features + 5 position ones; keep in sync with Features.mqh

namespace Entry
{
struct State
{
    double f[ENTRY_FEATURES];
};

struct Side
{
    double entry, peak, dip;
    datetime dtPeak, dtDip;

    Side() {}
    Side(double in, double out, datetime dt)
        : entry(in)
        , peak(out)
        , dip(out)
        , dtPeak(dt)
        , dtDip(dt)
    {}

    void Update(double val, datetime dt)
    {
        if(val > peak)
        {
            peak = val;
            dtPeak = dt;
        }
        if(val < dip)
        {
            dip = val;
            dtDip = dt;
        }
    }
};

struct Sample
{
    State state;
    datetime time;
    double atr, spread;
    double predBuy, predSell;   // what the network said at entry, before the outcome was known
    Side buy, sell;

    Sample() {}
    Sample(State const& s, datetime dt, double ATR, MqlTick const& tick, double pB, double pS)
        : state(s)
        , time(dt)
        , atr(ATR)
        , spread(tick.ask - tick.bid)
        , predBuy(pB)
        , predSell(pS)
        , buy(tick.ask, tick.bid, dt)
        , sell(tick.bid, tick.ask, dt)
    {}
    void Update(MqlTick const& t)
    {
        buy.Update(t.bid, t.time);
        sell.Update(t.ask, t.time);
    }
};
}

namespace Exit
{
struct State
{
    double f[EXIT_FEATURES];
};

struct Sample
{
    State state;
    int bar;           // bar counter when the sample was drawn
    bool isBuy;
    double mark, atr;  // closing price of its side then (bid for a buy, ask for a sell), and ATR
    double pred;       // what the exit network said then, before the outcome was known

    Sample() {}
    Sample(State const& s, int b, bool buy, double m, double ATR, double p)
        : state(s)
        , bar(b)
        , isBuy(buy)
        , mark(m)
        , atr(ATR)
        , pred(p)
    {}
};
}

//+------------------------------------------------------------------+
#endif //	INCLUDE_TYPES
