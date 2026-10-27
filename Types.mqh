//+------------------------------------------------------------------+
//|                                                      ProjectName |
//|                                      Copyright 2020, CompanyName |
//|                                       http://www.companyname.net |
//+------------------------------------------------------------------+
#ifndef INCLUDE_TYPES
#define INCLUDE_TYPES

namespace Entry
{
struct State
{
    double _;
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
    Side buy, sell;

    Sample() {}
    Sample(State const& s, datetime dt, double ATR, MqlTick const& tick)
        : state(s)
        , time(dt)
        , atr(ATR)
        , spread(tick.ask - tick.bid)
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
    double _;
};

struct Sample
{
    State state;
    void Update(MqlTick const&) {}	//	stub until exit design
};
}

//+------------------------------------------------------------------+
#endif //	INCLUDE_TYPES
