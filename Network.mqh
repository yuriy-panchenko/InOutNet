#ifndef INCLUDE_NETWORK
#define INCLUDE_NETWORK
#include <YxSoft/Vector.mqh>
//+------------------------------------------------------------------+
//| Fully connected net: tanh hidden layers, sigmoid outputs.        |
//| Loss is cross-entropy, so targets may be soft values in 0..1.    |
//| Learn() trains on the activations of the most recent Think().    |
//+------------------------------------------------------------------+
class Network
{
    int    nLayers, nTrained;
    int    size[], aOff[], wOff[];   // layer sizes, offsets into act/bias/delta and into w
    double act[], delta[], bias[], w[];
    double rate;

public:
    Network()
        : nLayers(0)
        , nTrained(0)
        , rate(0.01)
    {}

    int Trained()const
    {
        return nTrained;
    }

    void Init(int const &topology[], double learnRate = 0.01)
    {
        rate = learnRate;
        nTrained = 0;
        nLayers = ArraySize(topology);
        ArrayResize(size, nLayers);
        ArrayResize(aOff, nLayers);
        ArrayResize(wOff, nLayers);
        int nAct = 0, nW = 0;
        wOff[0] = 0;
        for(int l = 0; l < nLayers; l++)
        {
            size[l] = topology[l];
            aOff[l] = nAct;
            nAct += size[l];
            if(l > 0)
            {
                wOff[l] = nW;
                nW += size[l] * size[l - 1];
            }
        }
        ArrayResize(act, nAct);
        ArrayResize(delta, nAct);
        ArrayResize(bias, nAct);
        ArrayInitialize(act, 0);
        ArrayInitialize(delta, 0);
        ArrayInitialize(bias, 0);
        ArrayResize(w, nW);
        for(int l = 1; l < nLayers; l++)
        {
            double const limit = MathSqrt(6.0 / (size[l] + size[l - 1]));   // Xavier
            int const n = size[l] * size[l - 1];
            for(int i = 0; i < n; i++)
                w[wOff[l] + i] = (2.0 * MathRand() / 32767.0 - 1.0) * limit;
        }
    }

    Vector Think(Vector const& inp)
    {
        int const last = nLayers - 1;
        if(inp.Size() != size[0])
        {
            PrintFormat("Network::Think: input size %d, expected %d", inp.Size(), size[0]);
            return Vector(size[last], 0.0);
        }
        
        for(int i = 0; i < size[0]; i++)
            act[i] = inp.Get(i);

        for(int l = 1; l < nLayers; l++)
        {
            int const nIn = size[l - 1], pOff = aOff[l - 1];
            for(int j = 0; j < size[l]; j++)
            {
                double sum = bias[aOff[l] + j];
                int const row = wOff[l] + j * nIn;
                for(int i = 0; i < nIn; i++)
                    sum += w[row + i] * act[pOff + i];
                act[aOff[l] + j] = (l == last) ? 1.0 / (1.0 + MathExp(-sum)) : MathTanh(sum);
            }
        }
        Vector out(size[last], 0.0);
        for(int j = 0; j < size[last]; j++)
            out.Set(j, act[aOff[last] + j]);
        return out;
    }

    //	one SGD step towards target; returns mean cross-entropy before the step
    double Learn(Vector const& target)
    {
        int const last = nLayers - 1;
        if(target.Size() != size[last])
        {
            PrintFormat("Network::Learn: target size %d, expected %d", target.Size(), size[last]);
            return 0;
        }
        double loss = 0;
        for(int j = 0; j < size[last]; j++)
        {
            double const a = act[aOff[last] + j];
            double const o = MathMin(MathMax(a, 1e-12), 1.0 - 1e-12);
            double const t = target.Get(j);
            delta[aOff[last] + j] = a - t;   // sigmoid + cross-entropy
            loss -= t * MathLog(o) + (1.0 - t) * MathLog(1.0 - o);
        }

        for(int l = last; l >= 1; l--)
        {
            int const nIn = size[l - 1], pOff = aOff[l - 1];
            if(l > 1)   // deltas of the layer below, using weights before the update
            {
                for(int i = 0; i < nIn; i++)
                {
                    double sum = 0;
                    for(int j = 0; j < size[l]; j++)
                        sum += w[wOff[l] + j * nIn + i] * delta[aOff[l] + j];
                    double const a = act[pOff + i];
                    delta[pOff + i] = sum * (1.0 - a * a);   // tanh'
                }
            }
            for(int j = 0; j < size[l]; j++)
            {
                double const d = rate * delta[aOff[l] + j];
                int const row = wOff[l] + j * nIn;
                for(int i = 0; i < nIn; i++)
                    w[row + i] -= d * act[pOff + i];
                bias[aOff[l] + j] -= d;
            }
        }
        ++nTrained;
        return loss / size[last];
    }

    double Learn(double t0, double t1)
    {
        Vector t(2, 0.0);
        t.Set(0, t0);
        t.Set(1, t1);
        return Learn(t);
    }
};
#endif //	INCLUDE_NETWORK
