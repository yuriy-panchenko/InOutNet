//+------------------------------------------------------------------+
//|                                                      ProjectName |
//|                                      Copyright 2020, CompanyName |
//|                                       http://www.companyname.net |
//+------------------------------------------------------------------+
#ifndef INCLUDE_RINGBUFFER
#define INCLUDE_RINGBUFFER

template<typename T>
class RingBuffer
{
    int maxLen, iPos;
    T arr[];

public:
    RingBuffer(int max_len)
        : maxLen(max_len + 1)
        , iPos(-1)
    {
        ArrayResize(arr, max_len + 1);
    }

    bool HasReady()const
    {
        return iPos >= maxLen - 1;
    }

    void Add(T const& obj)
    {
        ++iPos;
        int const index = iPos % maxLen;
        arr[index] = obj;
    }

    void GetReady(T& obj)const
    {
        obj = arr[(iPos + 1) % maxLen];
    }

    void Update(MqlTick const& tick)
    {
        int const to = MathMin(iPos + 1, maxLen);

        for(int i = 0; i < to; i++)
            arr[i].Update(tick);
    }
};

#endif //	INCLUDE_RINGBUFFER
//+------------------------------------------------------------------+
