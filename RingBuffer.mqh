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

    int Count()const
    {
        return MathMin(iPos + 1, maxLen);
    }

    //	back = 0 is the newest sample, 1 the one added a bar before it, and so on
    bool GetBack(int back, T& obj)const
    {
        if(back < 0 || back >= Count())
            return false;
        obj = arr[(iPos - back) % maxLen];
        return true;
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

//+------------------------------------------------------------------+
//| First in, first out queue of fixed capacity (oldest dropped when |
//| full).                                                           |
//+------------------------------------------------------------------+
template<typename T>
class Fifo
{
    int cap, head, count;
    T arr[];

public:
    Fifo(int capacity)
        : cap(MathMax(capacity, 1))
        , head(0)
        , count(0)
    {
        ArrayResize(arr, cap);
    }

    int Size()const
    {
        return count;
    }

    void Push(T const& obj)
    {
        if(count == cap)
        {
            head = (head + 1) % cap;
            --count;
        }
        arr[(head + count) % cap] = obj;
        ++count;
    }

    void Front(T& obj)const
    {
        obj = arr[head];
    }

    void Pop()
    {
        if(count == 0)
            return;
        head = (head + 1) % cap;
        --count;
    }
};

#endif //	INCLUDE_RINGBUFFER
//+------------------------------------------------------------------+
