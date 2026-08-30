# Wyckoff CFD Portfolio Strategy

*Christian Miccolis — Beriv Consulting*

MetaTrader 5 EA and Python reference implementation for a mean-reversion strategy (Bollinger Bands + Keltner Channels + Wyckoff Spring) on a portfolio of 7 CFD indices (SP500, NASDAQ100, DOWJONES, DAX40, CAC40, NIKKEI225, EUROSTOXX50), with a volatility regime filter, a macro news filter (NFP/FOMC), and optional volatility targeting.

> **Disclaimer**: This is not financial advice. This repository is provided for educational and research purposes only. CFD trading involves substantial risk and can result in the loss of your invested capital; it is not suitable for all investors. Backtested performance does not guarantee future results — markets change, and a strategy that worked in the past may not work going forward. You are solely responsible for any trading decisions and outcomes if you choose to use this code. Always test thoroughly on a demo account before considering real funds, and never risk money you cannot afford to lose.

## Performance

Validated both on the Python reference and on a native MetaTrader 5 backtest (Strategy Tester), with numbers reconciled between the two sources.

**Native MT5, full history 2012-2026** (fixed leverage, 1.34% risk per trade):

| | With news filter (NFP+FOMC) | No filter |
|---|---|---|
| Total return | **+156.7%** | +122.9% |
| Profit Factor | **1.40** | 1.30 |
| Sharpe | **1.12** | 0.92 |
| Max Drawdown (equity) | **-25.5%** | -29.4% |
| Win rate | 52.4% | 51.4% |

**Python reference, validation period 2020-2026:**

| | With news filter | No filter |
|---|---|---|
| CAGR | **16.1%/year** | 15.5%/year |
| Max Drawdown | **-15.6%** | -19.0% |

The news filter (NFP+FOMC) improves every metric compared to not having it, all else equal — it's enabled by default in the EA.

This repository documents method and results rigorously — dual Python/MT5 validation, real bugs found and fixed during development, a news calendar built from official sources. No guarantee of future profitability.

## What's inside

```
mql5/
  WyckoffPortfolioEA.mq5      MetaTrader 5 Expert Advisor (7-symbol portfolio)
python/
  backtest_reference.py       Independent Python reference (same signal logic)
```

### The EA (`mql5/WyckoffPortfolioEA.mq5`)

- Signal: price below the Bollinger Band (20, 2σ) OR below the Keltner Channel (EMA20 ± 2×ATR14) OR a Wyckoff-style "spring", always with price above the MA200 (long-only, uptrend-only)
- Regime filter: no new trades when volatility (252-day ATR%/price percentile of the reference symbol) is above the 50th historical percentile
- News filter: no new entries on NFP release days or FOMC meeting days (293 dates 2012-2026, from official BLS/Federal Reserve sources — validated: improves CAGR and reduces drawdown compared to not having it)
- Exit: stop at 1.5×ATR, target at 1.5R, or time-based close after 15 days of maximum holding
- Position sizing: fixed 1.34% equity risk per trade, with optional dynamic volatility targeting (0.4x-3x leverage calibrated on realized equity volatility)

**Before using it**: read the comments at the top of the file — they document real bugs found during development (order filling mode, Tester vs. live time offset, guards against anomalous data) and the recommendation to verify the time offset live before trading a real account.

### The Python reference (`python/backtest_reference.py`)

Independent backtest on the same signal logic, used to validate the EA (the two, by the end of the work, converge within a reasonable margin on total trades and return). Requires H1 historical data for the 7 indices in a `data/` folder (not included in this repository — see below).

```bash
pip install pandas numpy
python python/backtest_reference.py nfpfomc   # with news filter (recommended)
python python/backtest_reference.py none      # without filter, for comparison
```

## Required data (not included)

The historical data used for development is H1 2012-2026 for the 7 indices, originally sourced from Dukascopy. It is not included in this repository (size, data licensing). To reproduce the results you need one CSV per symbol in `python/data/{SYMBOL}_H1.csv` with columns `timestamp,open,high,low,close,volume` (UTC timestamps).

For the EA, the same data needs to be imported into MT5 as **custom symbols** (`CustomSymbolCreate` + `CustomRatesUpdate`) — most brokers' real symbols don't have sufficiently long history, and live spreads vary too much broker to broker for a clean comparison. With custom symbols, set `InpServerToRomeOffsetHours = 0` (the CSV timestamps are already in Rome time); with your broker's real symbols, recalibrate the offset live as explained in the EA's comments.

## Methodology

- **Spread**: fixed assumptions per symbol (SP500 0.90 points, NASDAQ100 0.70, DOWJONES 0.80, DAX40 0.80, CAC40 1.04 points — confirmed from a real account; NIKKEI225 15.0 and EUROSTOXX50 2.0 remain conservative estimates, never confirmed)
- **News filter**: an extended set was also tested (+CPI, +PCE, +GDP, +Jackson Hole, +Fed Chair semi-annual testimony) — it *worsens* the results (blocks too many days and removes edge from a mean-reversion strategy, which specifically captures the rebounds after the price excesses those events often generate). The default active filter uses only NFP+FOMC.
- **Validation**: results compared both on the Python reference and on a native MetaTrader 5 backtest (Strategy Tester, 1-minute OHLC model), with numbers reconciled between the two sources.

## Known limitations

- No slippage cost beyond the assumed fixed spread
- NIKKEI225 and EUROSTOXX50 spreads never confirmed on a real account
- Dynamic volatility targeting has not been tested in combination with the news filter
- Backtest, not live trading: no guarantee that future behavior will replicate historical behavior

## License

MIT — see [LICENSE](LICENSE). Code provided for research/educational purposes, no guarantee of profitability.
