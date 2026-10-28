# InOutNet - handoff notes (2026-10-28)

Read this first in a new chat, then pull the repo (`git clone` works in Claude's sandbox for a public repo; `web_fetch` on github.com is blocked).

## Working agreement
- Collaborative, critique-focused: say what to change and why, not full rewrites.
- Small incremental patches as `.patch` files, applied with `git apply`, then pushed. New files need `git add`.
- One question at a time; go slowly ("chew it slowly").
- Claude can't compile MQL5; it checks patches with `git apply --check` and tests math in Python.

## What the EA does (MQL5, NDX M1, MetaTrader tester, real ticks)
- Two networks: entry (14 inputs -> ... -> 2 sigmoid outputs: buy, sell) and exit (placeholder, not designed).
- On every new bar: snapshot the entry state, open a virtual buy and a virtual sell, track peak/dip per tick for `Window` bars (read-before-add ring buffer -> 101 bars in practice).
- At maturity: b = buy peak - ask entry, s = sell entry bid - lowest ask; threshold `th = max(K * ATR * sqrt(Window), SpreadMult * spread)`; labels `LabelExcessShare` (excess over th, share between sides, both 0 = "stay out").
- Online SGD (`Network::Learn`, tanh hidden, sigmoid out, cross-entropy), one step per matured sample, `LearnRate` input.
- Live: trade the larger output if above `Cutoff` (0.6); fixed hold of `Window` bars (placeholder exit); optional SL/TP in ATR (default off). Warm-up: no trading until `WarmUp` samples trained.
- Files: `InOutNet.mq5`, `Types.mqh`, `Network.mqh`, `Features.mqh` (14 features, completed bars only), `RingBuffer.mqh`, `Log.mqh` (log file in common folder), `Export.mqh` (`ExportEvery` input writes matured samples to `InOutNet_samples.csv`). `Vector.mqh` is the user's own long-used class, outside the repo (no include guard, not to be changed).
- Patches 1-13 were produced and applied locally; 14 (exit state) and 15 (exit samples and training) came later. Check the repo for the latest.

## Results so far
1. Defaults (Window 100, K 1.0, LearnRate 0.01), Jan-Oct 2026: about -300 to -470 net, ~1,680 trades, 51.5% won. Earlier no-TP/K=0.6 runs were worse (one stopped out at balance 1,306).
2. Optimizer, Jan-May (288 passes): Window explained ~44% of profit variance, K and LearnRate almost nothing; Window 200 looked great (mean +2,642, 88% profitable). Re-run on Jun-Oct: Window 200 mean -1,117; correlation of profit between periods across all combinations 0.10. The Jan-May winners were period luck.
3. Run Window 200 / K 0.9 / LearnRate 0.05: +5,233 total, but +4,679 of it in Jan-May (the selection period) and +554 in Jun-Oct; max drawdown 29.6%.
4. Measurement bug found and fixed (patch 11): `loss`/`dir` computed at maturity were leaked (neighbouring samples' labels overlap the window), e.g. "97.8% direction accuracy". Honest metrics use the prediction stored at entry.
5. Honest network metrics (full period, ~98k directional samples): direction accuracy 50.4%; predicted activity is slightly *higher* when nothing happens; loss worse than a constant guess.
6. Offline test on the exported samples (58k, walk-forward with 200-bar gap): "will a move reach th" is predictable (AUC 0.68 logistic, 0.74 boosting), mostly from spread/ATR (f13) and ATR level vs its median - probably a label artifact (th anchored on current ATR) and non-directional. The online network gets AUC 0.464 on it, so its training procedure fails even there. Direction among clear samples: AUC 0.517 +- 0.017 (block bootstrap), accuracy 51.9%, no monotonic gain for confident predictions -> no usable directional signal in the 14 features.
7. Bars-based labels reproduce the tester's b exactly and s within 0.22 on average (18,401 samples), so offline research on M1 bars is faithful.

## Known issues / design notes
- Online SGD on consecutive, near-identical samples chases the recent regime and is overconfident; a replay buffer + lower learning rate is the likely fix (not done).
- Labels use peaks/dips, but the placeholder exit realises the profit at the end of the window (mismatch); TP at th (`MarketTarget = 10*K`) was tried once in a worse setting.
- Exit network labels/state are not designed.

## Exit side (patches 14-15)
- Idea: decide live, every bar, from the position's own state; the future is only used to make training labels.
- Exit state (19 inputs, `MakeExitState`): the 14 entry features (mirrored for a sell: f0-7 change sign, wicks swap; f13 spread redone as tanh(2*spread/ATR) because tanh(10x) saturated) + pnl in ATR*sqrt(Window), pnl in ATR*sqrt(age), age/Window, best pnl since open, drop from that best. pnl is mark-to-market (bid for a buy, ask for a sell), so it starts at about -spread.
- Exit samples (patch 15): every new bar `ExitPerBar` (4) random (virtual trade, side) pairs are drawn from the entry virtual trades (ages 1..Window); state and the net's own prediction are stored; `ExitHorizon` (20) bars later the label is 0.5*(1+tanh(dir*(mark_now - mark_then)/(ATR*sqrt(N)))), i.e. what holding added versus closing at that moment. One SGD step each, `ExitLearnRate` 0.0002. Low on purpose: in a synthetic test (random walk vs planted mean reversion) 0.003 and above made the loss clearly worse than a constant guess even on pure noise, while 0.0001-0.0005 stayed at the baseline and found the planted structure (corr about +0.08).
- Metrics use the prediction stored at creation: loss vs base (constant guess), corr(pred-0.5, label-0.5), hit rate where |label-0.5|>0.1. Samples overlap heavily, so the effective n is roughly bars/ExitHorizon, not the printed n: the noise of a correlation is about 1/sqrt(bars/20) (0.03 after 20k bars), so trust the cumulative numbers, not single windows.
- Trading is still the placeholder (fixed hold of Window bars). Next: use the net in `ShouldClose` (close when output <= 0.5 + margin) and compare with the fixed hold and an ATR trailing stop on the same entries.
- Window 250 run with `LogExitEvery=10` (45 trades) checked patch 14: state consistent (peak >= pnl, pnl sign matches the closed trade's net 45/45), position features rarely saturate.

## Pending
- Full M1 history export from MetaTrader failed: "Max bars in chart" was 100,000 (only 2026-07-17..10-28 exported), then the script ended with "Abnormal termination". Plan was: raise the setting + restart, rerun `ExportBars.mq5` (10-day chunks, logs each chunk), or use Ctrl+U -> Bars -> Export Bars. Goal: ~20 months of M1 bars for offline (Python) feature/label research.

## Options for next steps
A. Fix training (replay buffer, lower learning rate) - gives an activity predictor, which is not tradeable alone.
B. Get the full bars and do offline research on direction: longer context, daily levels, gaps, other horizons, other labels (e.g. final return after costs); count every idea tried and keep the last months untouched.
C. Rethink the problem or the instrument; a null on direction is a common outcome for M1 index data after spread.
