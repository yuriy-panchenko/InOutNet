#ifndef INCLUDE_FEATURES
#define INCLUDE_FEATURES
#include "Types.mqh"
#include "Network.mqh"

//+------------------------------------------------------------------+
//| Entry features. All dimensionless and squashed to about -1..1.   |
//| Uses only COMPLETED bars (shift >= 1), so there is no look-ahead.|
//|  0..5  close change over 1,2,4,8,16,32 bars, in ATR*sqrt(n)      |
//|  6     position of last close in the 20-bar range                |
//|  7     last bar body, in ATR                                     |
//|  8,9   last bar upper / lower wick, in ATR                       |
//|  10    log(avg range 5 bars / avg range 50 bars)                 |
//|  11,12 sin / cos of time of day (of the bar being formed)        |
//|  13    spread in ATR                                             |
//+------------------------------------------------------------------+
#define FEATURE_BARS 50

bool MakeEntryState(Entry::State &s, double atr, double spread)
{
    if(atr <= 0)
        return false;

    MqlRates r[];
    ArraySetAsSeries(r, true);   // r[0] is the last completed bar (shift 1)
    if(CopyRates(Symbol(), Period(), 1, FEATURE_BARS, r) != FEATURE_BARS)
        return false;

    int k = 0;
    int const lags[] = {1, 2, 4, 8, 16, 32};
    for(int i = 0; i < ArraySize(lags); i++)
        s.f[k++] = MathTanh((r[0].close - r[lags[i]].close) / (atr * MathSqrt(lags[i])));

    double hh = r[0].high, ll = r[0].low;
    for(int i = 1; i < 20; i++)
    {
        hh = MathMax(hh, r[i].high);
        ll = MathMin(ll, r[i].low);
    }
    s.f[k++] = hh > ll ? 2.0 * (r[0].close - ll) / (hh - ll) - 1.0 : 0.0;

    s.f[k++] = MathTanh((r[0].close - r[0].open) / atr);
    s.f[k++] = MathTanh((r[0].high - MathMax(r[0].open, r[0].close)) / atr);
    s.f[k++] = MathTanh((MathMin(r[0].open, r[0].close) - r[0].low) / atr);

    double sum5 = 0, sum50 = 0;
    for(int i = 0; i < FEATURE_BARS; i++)
    {
        double const rg = r[i].high - r[i].low;
        sum50 += rg;
        if(i < 5)
            sum5 += rg;
    }
    s.f[k++] = sum50 > 0 && sum5 > 0 ? MathTanh(MathLog((sum5 / 5.0) / (sum50 / FEATURE_BARS))) : 0.0;

    MqlDateTime dt;
    TimeToStruct(r[0].time + PeriodSeconds(), dt);
    double const day = 2.0 * M_PI * (dt.hour * 60 + dt.min) / 1440.0;
    s.f[k++] = MathSin(day);
    s.f[k++] = MathCos(day);

    s.f[k++] = MathTanh(10.0 * spread / atr);

    for(int i = 0; i < ENTRY_FEATURES; i++)
        if(!MathIsValidNumber(s.f[i]))
            return false;
    return k == ENTRY_FEATURES;
}

Vector ToInput(Entry::State const &s)
{
    Vector v(ENTRY_FEATURES, 0.0);
    for(int i = 0; i < ENTRY_FEATURES; i++)
        v.Set(i, s.f[i]);
    return v;
}

#endif //	INCLUDE_FEATURES
