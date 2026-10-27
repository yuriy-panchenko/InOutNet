#ifndef INCLUDE_NETWORK
#define INCLUDE_NETWORK
#include <YxSoft/Vector.mqh>
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
class Network
{
public:
    void Init(int const &arr[]);
    Vector Think(Vector const& inp);
};
#endif //	INCLUDE_NETWORK