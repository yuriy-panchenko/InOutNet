#ifndef INCLUDE_LOG
#define INCLUDE_LOG

//+------------------------------------------------------------------+
//| Print() plus an appended line in a text file in the common       |
//| folder (Terminal\Common\Files), so a run can be shared later.    |
//+------------------------------------------------------------------+
string gLogFile = "";
bool gLogFailed = false;

void LogInit(string const file)
{
    gLogFile = file;
    if(file == "")
        return;
    ResetLastError();
    int const h = FileOpen(file, FILE_WRITE | FILE_READ | FILE_TXT | FILE_ANSI | FILE_COMMON);
    int const err = GetLastError();
    PrintFormat("Log file '%s': %s, error %d, common folder %s, data folder %s",
                file, h == INVALID_HANDLE ? "CANNOT OPEN" : "ok", err,
                TerminalInfoString(TERMINAL_COMMONDATA_PATH), TerminalInfoString(TERMINAL_DATA_PATH));
    if(h != INVALID_HANDLE)
        FileClose(h);
}

void Log(string const text)
{
    Print(text);
    if(gLogFile == "")
        return;
    ResetLastError();
    int const h = FileOpen(gLogFile, FILE_WRITE | FILE_READ | FILE_TXT | FILE_ANSI | FILE_COMMON);
    if(h == INVALID_HANDLE)
    {
        if(!gLogFailed)
            PrintFormat("Log: cannot open '%s', error %d", gLogFile, GetLastError());
        gLogFailed = true;
        return;
    }
    FileSeek(h, 0, SEEK_END);
    FileWriteString(h, TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS) + "  " + text + "\r\n");
    FileClose(h);
}

#endif //	INCLUDE_LOG
