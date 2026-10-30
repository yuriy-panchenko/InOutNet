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
- Patch 17: `ExitMode` input: EXIT_FIXED (default, unchanged behaviour), EXIT_NET (close when output <= 0.5 + `ExitMargin`), EXIT_TRAIL (close when the drop from the best pnl >= `TrailK` * ATR*sqrt(Window)). Every mode still closes at Window bars at the latest. The run header `=== exit` line shows the mode. EXIT_NET: the net's output is nearly constant 0.5, so it behaves like a random exit. Run with ExitMargin 0 (stopped on Jan 15): 1551 trades in 10 days, median hold 1 min, balance 8113 vs 10071 for the fixed hold on the same date. Run with ExitMargin -0.02 (full period): 5997 trades up to Jun 9 (39 per day vs 6 for the fixed hold), median hold 2 min, win rate 35%, balance 10000 -> 1228 by Jun 9 (fixed hold: 14402 at that date); no trades after that (account too small to open another, my guess; nothing in the log says so). The real output spread is wider than a synthetic test suggested, so -0.02 still closed most positions at the first or second check. Note when changing inputs: the order is ExitMode, ExitMargin, TrailK.
- Result of the exit rules on the same entries (Window=150 K=0.5 Cutoff=0.5, Jan 1 - Oct 27 2026): EXIT_FIXED 1845 trades, final balance 16684, win rate 50%, avg win +84 / avg loss -78, profit factor 1.10, max drawdown 20%. EXIT_TRAIL (TrailK 0.5) 3463 trades, final 10478, win rate 38%, avg win +74 / avg loss -45, profit factor 1.02, max drawdown 28%, median hold 71 min with only 17% reaching the cap, and Jun-Oct net negative. The trailing stop did what the theory says: with no edge in the price it only reshapes the results (smaller wins, smaller losses) and, because the EA re-enters whenever it is flat, it nearly doubles the number of trades and the spread paid. Even the fixed hold's per-trade mean (+3.8) has t = 1.4 in-sample, and March alone is 38% of its profit.
- Conclusion for the exit side: the learned exit is null at horizons 5, 20 and 60, the trailing stop is worse than the fixed hold, and EXIT_NET is far worse (margin 0 and -0.02). The default stays EXIT_FIXED. Exit work is finished unless new information (not price shapes) turns up.
- Result (NDX M1, Jan 1 - Oct 27 2026, about 291k bars, 1.17M exit samples per run): cumulative corr(pred, label) +0.005 at ExitHorizon 5, +0.006 at 20, +0.002 at 60 (noise about 0.004 / 0.008 / 0.014); hit rate 50.2-50.3%; the net ends as a constant (meanPred = meanLabel = 0.500) and no month stands out. So the 19-feature state, price-derived and position-centred, does not predict the mark-to-market change at any of the three horizons. Entry said the same (dir AUC 0.517). With no structure after entry no exit rule can create expectancy, only reshape it.
- The exit runs did not change trading (identical trades and balance in all runs with the same entry parameters); their balances are in-sample and say nothing about the exit.
- The log file is appended to, not overwritten: delete it between runs or several runs end up in one file.
- Not tried yet: tick volume (exported by ExportBars but unused by the features), other instruments, longer timeframes.
- Window 250 run with `LogExitEvery=10` (45 trades) checked patch 14: state consistent (peak >= pnl, pnl sign matches the closed trade's net 45/45), position features rarely saturate.

## Out-of-sample and offline checks (patch 19: `ExportSeries`)
- `ExportSeries` writes one row per bar (time, bid, ask, atr, previous bar's max bid / min ask, 14 entry features, entry outputs, live flag) to InOutNet_series.csv. About 45 MB raw for 10 months, about 100 MB for 22 months (too big to upload: zip it or use a shorter period). Offline, the rebuilt exit state matches the EA's logged state (22k states, within the log's rounding) and an offline fixed-hold simulator matches the EA (1853 vs 1845 trades, per-trade correlation 0.9999, 1 price point = 1 money unit; the tester also charges about 0.5-0.8 per trade that is not in the prices).
- Offline exit research (train Jan-Jun, test Jul-Oct, 150-bar embargo, 1.75M samples): gradient boosting, an EA-shaped MLP (38-38-10) and a large MLP (128-128-64) all give held-out correlations between -0.008 and +0.026 (noise 0.01-0.017) at 5, 20, 60 bars and to the cap. As exit rules on the 741 test entries they lose 0.5-5 points per position against holding to the cap (not significant). It is not a learner or topology problem.
- Where the 2026 fixed-hold profit came from: the index rose 16.6% but the system is 50/50 buys and sells, and random timing with that mix would lose 1.1 per trade. Entry-selected trades earn nothing extra in the first ~40 bars; a slim extra builds by bar 150 (+2.3 points per trade, SE about 2).
- Out-of-sample run, same parameters (Window 150, K 0.5, Cutoff 0.5, EXIT_FIXED), Jan 2025 - Oct 29 2026, entry net learning online from scratch: 4136 trades, balance 10000 -> 5314 (low 1700 on 2026-07-02). 2025 alone: 2245 trades, -3055, mean -1.04 per trade (t -0.49). 2026 inside the same run (net already trained on 2025): 1891 trades, -1630 (June alone -5112), while the fresh 2026-only run made +6684 with the same parameters. Same data, same settings, opposite sign, so the 2026 profit looks like selection luck (parameters x net path) and not an edge.
- Conclusion: no demonstrated edge in the entry, so there is nothing for an exit to improve. The exit side stays closed unless the entry gets a real edge (new information, not a better learner).

## Pending
- Full M1 history export from MetaTrader failed: "Max bars in chart" was 100,000 (only 2026-07-17..10-28 exported), then the script ended with "Abnormal termination". Plan was: raise the setting + restart, rerun `ExportBars.mq5` (10-day chunks, logs each chunk), or use Ctrl+U -> Bars -> Export Bars. Goal: ~20 months of M1 bars for offline (Python) feature/label research.

## Options for next steps
A. Fix training (replay buffer, lower learning rate) - gives an activity predictor, which is not tradeable alone.
B. Get the full bars and do offline research on direction: longer context, daily levels, gaps, other horizons, other labels (e.g. final return after costs); count every idea tried and keep the last months untouched.
C. Rethink the problem or the instrument; a null on direction is a common outcome for M1 index data after spread.
