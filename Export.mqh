#ifndef INCLUDE_EXPORT
#define INCLUDE_EXPORT
#include "Types.mqh"

//+------------------------------------------------------------------+
//| Dumps matured entry samples to a CSV in the common folder so the |
//| features and labels can be studied offline (Python).             |
//| Columns: time, f0..f13, b, s, th, atr, spread, labelBuy,         |
//| labelSell, predBuy, predSell, minutes from entry to each         |
//| side's peak and dip (buyPeak, buyDip, sellPeak, sellDip).        |
//+------------------------------------------------------------------+
int gExpHandle = INVALID_HANDLE;
int gExpRows = 0;

void ExportOpen(string const file)
{
    if(file == "")
        return;
    gExpHandle = FileOpen(file, FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_COMMON);
    if(gExpHandle == INVALID_HANDLE)
    {
        PrintFormat("Export: cannot open '%s', error %d", file, GetLastError());
        return;
    }
    string head = "time";
    for(int i = 0; i < ENTRY_FEATURES; i++)
        head += ",f" + IntegerToString(i);
    head += ",b,s,th,atr,spread,labelBuy,labelSell,predBuy,predSell,buyPeak,buyDip,sellPeak,sellDip";
    FileWriteString(gExpHandle, head + "\r\n");
}

void ExportRow(Entry::Sample const &s, double b, double sl, double th, double oB, double oS)
{
    if(gExpHandle == INVALID_HANDLE)
        return;
    string row = TimeToString(s.time, TIME_DATE | TIME_MINUTES);
    for(int i = 0; i < ENTRY_FEATURES; i++)
        row += "," + DoubleToString(s.state.f[i], 5);
    row += "," + DoubleToString(b, 2) + "," + DoubleToString(sl, 2) + "," + DoubleToString(th, 2)
         + "," + DoubleToString(s.atr, 3) + "," + DoubleToString(s.spread, 3)
         + "," + DoubleToString(oB, 4) + "," + DoubleToString(oS, 4)
         + "," + DoubleToString(s.predBuy, 4) + "," + DoubleToString(s.predSell, 4)
         + "," + IntegerToString((int)((s.buy.dtPeak - s.time) / 60)) + "," + IntegerToString((int)((s.buy.dtDip - s.time) / 60))
         + "," + IntegerToString((int)((s.sell.dtPeak - s.time) / 60)) + "," + IntegerToString((int)((s.sell.dtDip - s.time) / 60));
    FileWriteString(gExpHandle, row + "\r\n");
    if(++gExpRows % 1000 == 0)
        FileFlush(gExpHandle);
}

void ExportClose()
{
    if(gExpHandle == INVALID_HANDLE)
        return;
    FileClose(gExpHandle);
    gExpHandle = INVALID_HANDLE;
}

//+------------------------------------------------------------------+
//| One row per bar, for offline exit research: enough to rebuild    |
//| virtual trades of any age, their exit states and any label.      |
//| Columns: time, bid and ask at the bar's first tick, atr, the     |
//| highest bid and lowest ask over the ticks of the PREVIOUS bar    |
//| (the peak and dip of a virtual trade need every tick), the 14    |
//| entry features, the entry network's two outputs, and live = 1    |
//| once the entry network is past its warm-up.                      |
//+------------------------------------------------------------------+
int gSerHandle = INVALID_HANDLE;
int gSerRows = 0;

void SeriesOpen(string const file)
{
    if(file == "")
        return;
    gSerHandle = FileOpen(file, FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_COMMON);
    if(gSerHandle == INVALID_HANDLE)
    {
        PrintFormat("Series: cannot open '%s', error %d", file, GetLastError());
        return;
    }
    string head = "time,bid,ask,atr,prevMaxBid,prevMinAsk";
    for(int i = 0; i < ENTRY_FEATURES; i++)
        head += ",f" + IntegerToString(i);
    head += ",outBuy,outSell,live";
    FileWriteString(gSerHandle, head + "\r\n");
}

void SeriesRow(datetime time, MqlTick const &tick, double atr, double prevMaxBid, double prevMinAsk,
               Entry::State const &st, double outBuy, double outSell, bool live)
{
    if(gSerHandle == INVALID_HANDLE)
        return;
    string row = TimeToString(time, TIME_DATE | TIME_MINUTES)
               + "," + DoubleToString(tick.bid, _Digits) + "," + DoubleToString(tick.ask, _Digits)
               + "," + DoubleToString(atr, 3)
               + "," + DoubleToString(prevMaxBid, _Digits) + "," + DoubleToString(prevMinAsk, _Digits);
    for(int i = 0; i < ENTRY_FEATURES; i++)
        row += "," + DoubleToString(st.f[i], 3);
    row += "," + DoubleToString(outBuy, 4) + "," + DoubleToString(outSell, 4) + "," + (live ? "1" : "0");
    FileWriteString(gSerHandle, row + "\r\n");
    if(++gSerRows % 1000 == 0)
        FileFlush(gSerHandle);
}

void SeriesClose()
{
    if(gSerHandle == INVALID_HANDLE)
        return;
    FileClose(gSerHandle);
    gSerHandle = INVALID_HANDLE;
}

#endif //	INCLUDE_EXPORT
