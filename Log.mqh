#ifndef INCLUDE_LOG
#define INCLUDE_LOG

//+------------------------------------------------------------------+
//| Print() plus an appended line in a text file in the common       |
//| folder (Terminal\Common\Files), so a run can be shared later.    |
//+------------------------------------------------------------------+
string gLogFile = "";

void LogInit(string const file)
{
    gLogFile = file;
}

void Log(string const text)
{
    Print(text);
    if(gLogFile == "")
        return;
    int const h = FileOpen(gLogFile, FILE_WRITE | FILE_READ | FILE_TXT | FILE_ANSI | FILE_COMMON | FILE_SHARE_READ);
    if(h == INVALID_HANDLE)
        return;
    FileSeek(h, 0, SEEK_END);
    FileWriteString(h, TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS) + "  " + text + "\r\n");
    FileClose(h);
}

#endif //	INCLUDE_LOG
