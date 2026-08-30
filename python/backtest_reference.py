# Wyckoff CFD Portfolio Strategy - Python reference
# Christian Miccolis - Beriv Consulting

import os
import sys
import pandas as pd
import numpy as np
from zoneinfo import ZoneInfo

INDICES_7 = ["SP500","NASDAQ100","DOWJONES","DAX40","CAC40","NIKKEI225","EUROSTOXX50"]
CUTOFF = pd.Timestamp("2020-01-01")
MAX_HOLDING_H1_BARS = 15*24
SPREAD_POINTS = {"SP500":0.90, "NASDAQ100":0.70, "DOWJONES":0.80, "DAX40":0.80, "CAC40":1.04,
                 "NIKKEI225":15.0, "EUROSTOXX50":2.0}
REGIME_THRESHOLD = 0.50
WYCKOFF_EXCLUDED = {"NIKKEI225"}
ROME = ZoneInfo("Europe/Rome")

MODE = sys.argv[1] if len(sys.argv) > 1 else "nfpfomc"  # "none" | "nfpfomc" (recommended) | "extended" (worsens results, see README)

NFP_DATES = """
2012-01-06 2012-02-03 2012-03-09 2012-04-06 2012-05-04 2012-06-01 2012-07-06 2012-08-03 2012-09-07 2012-10-05 2012-11-02 2012-12-07
2013-01-04 2013-02-01 2013-03-08 2013-04-05 2013-05-03 2013-06-07 2013-07-05 2013-08-02 2013-09-06 2013-10-22 2013-11-08 2013-12-06
2014-01-10 2014-02-07 2014-03-07 2014-04-04 2014-05-02 2014-06-06 2014-07-03 2014-08-01 2014-09-05 2014-10-03 2014-11-07 2014-12-05
2015-01-09 2015-02-06 2015-03-06 2015-04-03 2015-05-08 2015-06-05 2015-07-02 2015-08-07 2015-09-04 2015-10-02 2015-11-06 2015-12-04
2016-01-08 2016-02-05 2016-03-04 2016-04-01 2016-05-06 2016-06-03 2016-07-08 2016-08-05 2016-09-02 2016-10-07 2016-11-04 2016-12-02
2017-01-06 2017-02-03 2017-03-10 2017-04-07 2017-05-05 2017-06-02 2017-07-07 2017-08-04 2017-09-01 2017-10-06 2017-11-03 2017-12-08
2018-01-05 2018-02-02 2018-03-09 2018-04-06 2018-05-04 2018-06-01 2018-07-06 2018-08-03 2018-09-07 2018-10-05 2018-11-02 2018-12-07
2019-01-04 2019-02-01 2019-03-08 2019-04-05 2019-05-03 2019-06-07 2019-07-05 2019-08-02 2019-09-06 2019-10-04 2019-11-01 2019-12-06
2020-01-10 2020-02-07 2020-03-06 2020-04-03 2020-05-08 2020-06-05 2020-07-02 2020-08-07 2020-09-04 2020-10-02 2020-11-06 2020-12-04
2021-01-08 2021-02-05 2021-03-05 2021-04-02 2021-05-07 2021-06-04 2021-07-02 2021-08-06 2021-09-03 2021-10-08 2021-11-05 2021-12-03
2022-01-07 2022-02-04 2022-03-04 2022-04-01 2022-05-06 2022-06-03 2022-07-08 2022-08-05 2022-09-02 2022-10-07 2022-11-04 2022-12-02
2023-01-06 2023-02-03 2023-03-10 2023-04-07 2023-05-05 2023-06-02 2023-07-07 2023-08-04 2023-09-01 2023-10-06 2023-11-03 2023-12-08
2024-01-05 2024-02-02 2024-03-08 2024-04-05 2024-05-03 2024-06-07 2024-07-05 2024-08-02 2024-09-06 2024-10-04 2024-11-01 2024-12-06
2025-01-10 2025-02-07 2025-03-07 2025-04-04 2025-05-02 2025-06-06 2025-07-03 2025-08-01 2025-09-05 2025-11-20 2025-12-16
2026-01-09 2026-02-11 2026-03-06 2026-04-03 2026-05-08 2026-06-05 2026-07-02 2026-08-07
""".split()

FOMC_DATES = """
2012-01-25 2012-03-13 2012-04-25 2012-06-20 2012-08-01 2012-09-13 2012-10-24 2012-12-12
2013-01-30 2013-03-20 2013-05-01 2013-06-19 2013-07-31 2013-09-18 2013-10-30 2013-12-18
2014-01-29 2014-03-19 2014-04-30 2014-06-18 2014-07-30 2014-09-17 2014-10-29 2014-12-17
2015-01-28 2015-03-18 2015-04-29 2015-06-17 2015-07-29 2015-09-17 2015-10-28 2015-12-16
2016-01-27 2016-03-16 2016-04-27 2016-06-15 2016-07-27 2016-09-21 2016-11-02 2016-12-14
2017-02-01 2017-03-15 2017-05-03 2017-06-14 2017-07-26 2017-09-20 2017-11-01 2017-12-13
2018-01-31 2018-03-21 2018-05-02 2018-06-13 2018-08-01 2018-09-26 2018-11-08 2018-12-19
2019-01-30 2019-03-20 2019-05-01 2019-06-19 2019-07-31 2019-09-18 2019-10-30 2019-12-11
2020-01-29 2020-03-03 2020-03-15 2020-04-29 2020-06-10 2020-07-29 2020-09-16 2020-11-05 2020-12-16
2021-01-27 2021-03-17 2021-04-28 2021-06-16 2021-07-28 2021-09-22 2021-11-03 2021-12-15
2022-01-26 2022-03-16 2022-05-04 2022-06-15 2022-07-27 2022-09-21 2022-11-02 2022-12-14
2023-02-01 2023-03-22 2023-05-03 2023-06-14 2023-07-26 2023-09-20 2023-11-01 2023-12-13
2024-01-31 2024-03-20 2024-05-01 2024-06-12 2024-07-31 2024-09-18 2024-11-07 2024-12-18
2025-01-29 2025-03-19 2025-05-07 2025-06-18 2025-07-30 2025-09-17 2025-10-29 2025-12-10
2026-01-28 2026-03-18 2026-04-29 2026-06-17 2026-07-29
""".split()

# CPI: "year: mm-dd mm-dd ..."
CPI_RAW = """
2012: 01-19 02-17 03-16 04-13 05-15 06-14 07-17 08-15 09-14 10-16 11-15 12-14
2013: 01-16 02-21 03-15 04-16 05-16 06-18 07-16 08-15 09-17 10-30 11-20 12-17
2014: 01-16 02-20 03-18 04-15 05-15 06-17 07-22 08-19 09-17 10-22 11-20 12-17
2015: 01-16 02-26 03-24 04-17 05-22 06-18 07-17 08-19 09-16 10-15 11-17 12-15
2016: 01-20 02-19 03-16 04-14 05-17 06-16 07-15 08-16 09-16 10-18 11-17 12-15
2017: 01-18 02-15 03-15 04-14 05-12 06-14 07-14 08-11 09-14 10-13 11-15 12-13
2018: 01-12 02-14 03-13 04-11 05-10 06-12 07-12 08-10 09-13 10-11 11-14 12-12
2019: 01-11 02-13 03-12 04-10 05-10 06-12 07-11 08-13 09-12 10-10 11-13 12-11
2020: 01-14 02-13 03-11 04-10 05-12 06-10 07-14 08-12 09-11 10-13 11-12 12-10
2021: 01-13 02-10 03-10 04-13 05-12 06-10 07-13 08-11 09-14 10-13 11-10 12-10
2022: 01-12 02-10 03-10 04-12 05-11 06-10 07-13 08-10 09-13 10-13 11-10 12-13
2023: 01-12 02-14 03-14 04-12 05-10 06-13 07-12 08-10 09-13 10-12 11-14 12-12
2024: 01-11 02-13 03-12 04-10 05-15 06-12 07-11 08-14 09-11 10-10 11-13 12-11
2025: 01-15 02-12 03-12 04-10 05-13 06-11 07-15 08-12 09-11 10-24 12-18
2026: 01-13 02-13 03-11 04-10 05-12 06-10 07-14 08-12
"""

PCE_RAW = """
2012: 01-30 03-01 03-30 04-30 06-01 06-29 07-31 08-30 09-28 10-29 11-30 12-21
2013: 01-31 03-01 03-29 04-29 05-31 06-27 08-02 08-30 09-27 11-08 12-06 12-23
2014: 01-31 03-03 03-28 05-01 05-30 06-26 08-01 08-29 09-29 10-31 11-26 12-23
2015: 02-02 03-02 03-30 04-30 06-01 06-25 08-03 08-28 09-28 10-30 11-25 12-23
2016: 02-01 02-26 03-28 04-29 05-31 06-29 08-02 08-29 09-30 10-31 11-30 12-22
2017: 01-30 03-01 03-31 05-01 05-30 06-30 08-01 08-31 09-29 10-30 11-30 12-22
2018: 01-29 03-01 03-29 04-30 05-31 06-29 07-31 08-30 09-28 10-29 11-29 12-21
2019: 02-19 04-29 05-31 06-28 07-30 08-30 09-27 10-31 11-27 12-20
2020: 01-31 02-28 03-27 04-30 05-29 06-26 07-31 08-28 10-01 10-30 11-25 12-23
2021: 01-29 02-26 03-26 04-30 05-28 06-25 07-30 08-27 10-01 10-29 11-24 12-23
2022: 01-28 02-25 03-31 04-29 05-27 06-30 07-29 08-26 09-30 10-28 12-01 12-23
2023: 01-27 02-24 03-31 04-28 05-26 06-30 07-28 08-31 09-29 10-27 11-30 12-22
2024: 01-26 02-29 03-29 04-26 05-31 06-28 07-26 08-30 09-27 10-31 11-27 12-20
2025: 01-31 02-28 03-28 04-30 05-30 06-27 07-31 08-29 09-26 12-05 12-23
2026: 01-22 02-20 03-13 04-09 04-30 05-28 06-25 07-30 08-26
"""

GDP_DATES = """
2012-01-27 2012-04-27 2012-07-27 2012-10-26
2013-01-30 2013-04-26 2013-07-31 2013-11-07
2014-01-30 2014-04-30 2014-07-30 2014-10-30
2015-01-30 2015-04-29 2015-07-30 2015-10-29
2016-01-29 2016-04-28 2016-07-29 2016-10-28
2017-01-27 2017-04-28 2017-07-28 2017-10-27
2018-01-26 2018-04-27 2018-07-27 2018-10-25
2019-02-28 2019-04-26 2019-07-26 2019-10-30
2020-01-30 2020-04-29 2020-07-30 2020-10-29
2021-01-28 2021-04-29 2021-07-29 2021-10-28
2022-01-27 2022-04-28 2022-07-28 2022-10-27
2023-01-26 2023-04-27 2023-07-27 2023-10-26
2024-01-25 2024-04-25 2024-07-25 2024-10-30
2025-01-30 2025-04-30 2025-07-30 2025-12-23
2026-02-20 2026-04-30 2026-07-30
""".split()

# Jackson Hole: date ranges (we block the entire period)
JACKSON_HOLE_RANGES = [
    ("2012-08-30","2012-09-01"), ("2013-08-21","2013-08-24"), ("2014-08-21","2014-08-23"),
    ("2015-08-27","2015-08-29"), ("2016-08-25","2016-08-27"), ("2017-08-24","2017-08-26"),
    ("2018-08-23","2018-08-25"), ("2019-08-22","2019-08-24"), ("2020-08-27","2020-08-28"),
    ("2021-08-27","2021-08-27"), ("2022-08-25","2022-08-27"), ("2023-08-24","2023-08-26"),
    ("2024-08-22","2024-08-24"), ("2025-08-21","2025-08-23"), ("2026-08-27","2026-08-29"),
]

FED_TESTIMONY_DATES = """
2012-02-29 2012-03-01 2012-07-17 2012-07-18
2013-02-26 2013-02-27 2013-07-17 2013-07-18
2014-02-11 2014-02-27 2014-07-15 2014-07-16
2015-02-24 2015-02-25 2015-07-15 2015-07-16
2016-02-10 2016-02-11 2016-06-21 2016-06-22
2017-02-14 2017-02-15 2017-07-12 2017-07-13
2018-02-27 2018-03-01 2018-07-17 2018-07-18
2019-02-26 2019-02-27 2019-07-10 2019-07-11
2020-02-11 2020-02-12 2020-06-16 2020-06-17
2021-02-23 2021-02-24 2021-07-14 2021-07-15
2022-03-02 2022-03-03 2022-06-22 2022-06-23
2023-03-07 2023-03-08 2023-06-21 2023-06-22
2024-03-06 2024-03-07 2024-07-09 2024-07-10
2025-02-11 2025-02-12 2025-06-24 2025-06-25
2026-07-14 2026-07-15
""".split()


def parse_yearblock(raw):
    dates = []
    year = None
    for line in raw.strip().split("\n"):
        line = line.strip()
        if not line:
            continue
        if ":" in line:
            year_part, rest = line.split(":", 1)
            year = year_part.strip()
            parts = rest.split()
        else:
            parts = line.split()
        for p in parts:
            dates.append(f"{year}-{p}")
    return dates


CPI_DATES = parse_yearblock(CPI_RAW)
PCE_DATES = parse_yearblock(PCE_RAW)

NEWS_DATES_NFP_FOMC = set(pd.Timestamp(d).date() for d in (NFP_DATES + FOMC_DATES))

extra_dates = list(CPI_DATES) + list(PCE_DATES) + list(GDP_DATES) + list(FED_TESTIMONY_DATES)
extra_set = set(pd.Timestamp(d).date() for d in extra_dates)
for start, end in JACKSON_HOLE_RANGES:
    for d in pd.date_range(start, end):
        extra_set.add(d.date())

NEWS_DATES_EXTENDED = NEWS_DATES_NFP_FOMC | extra_set

if MODE == "none":
    NEWS_DATES = set()
elif MODE == "nfpfomc":
    NEWS_DATES = NEWS_DATES_NFP_FOMC
else:
    NEWS_DATES = NEWS_DATES_EXTENDED

print(f"Mode: {MODE} | news days blocked in period: {len(NEWS_DATES)}")


def compute_atr(df, period=14):
    high, low, close = df["high"], df["low"], df["close"]
    prev_close = close.shift(1)
    tr = pd.concat([high-low,(high-prev_close).abs(),(low-prev_close).abs()],axis=1).max(axis=1)
    return tr.rolling(period).mean()

DATA_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "data")  # python/data/, see README

def load_duka_h1(sym):
    df = pd.read_csv(f"{DATA_DIR}/{sym}_H1.csv", parse_dates=["timestamp"])
    df["timestamp"] = df["timestamp"].dt.tz_convert(ROME).dt.tz_localize(None)
    df = df.set_index("timestamp").sort_index()
    return df[["open","high","low","close","volume"]]

h1_data = {}
daily_filters = {}

sp500_h1 = load_duka_h1("SP500")
sp500_daily = sp500_h1.resample("1D").agg({"open":"first","high":"max","low":"min","close":"last"}).dropna()
sp500_daily["atr14"] = compute_atr(sp500_daily, 14)
sp500_daily["atr_pct_price"] = sp500_daily["atr14"]/sp500_daily["close"]
sp500_daily["atr_percentile"] = sp500_daily["atr_pct_price"].rolling(252).rank(pct=True)
regime_sp500 = sp500_daily[["atr_percentile"]].shift(1)

for sym in INDICES_7:
    h1 = load_duka_h1(sym)
    h1_data[sym] = h1
    daily = h1.resample("1D").agg({"open":"first","high":"max","low":"min","close":"last","volume":"sum"}).dropna()
    daily["atr14"] = compute_atr(daily, 14)
    daily["ma200"] = daily["close"].rolling(200).mean()
    bb_mid = daily["close"].rolling(20).mean(); bb_std = daily["close"].rolling(20).std()
    daily["bb_lower"] = bb_mid-2*bb_std
    daily["kc_mid"] = daily["close"].ewm(span=20, adjust=False).mean()
    daily["kc_lower"] = daily["kc_mid"]-2*daily["atr14"]

    range_low_20 = daily["low"].rolling(20).min()
    range_high_20 = daily["high"].rolling(20).max()
    range_pct = (range_high_20-range_low_20)/daily["close"]
    tight_range = range_pct < range_pct.rolling(100, min_periods=30).median()
    vol_avg20 = daily["volume"].rolling(20).mean()
    spring_raw = (daily["low"] < range_low_20.shift(1)) & (daily["close"] > range_low_20.shift(1)) & \
                 tight_range.shift(1) & (daily["volume"] > 1.5*vol_avg20.shift(1))
    daily["wyckoff_raw"] = spring_raw if sym not in WYCKOFF_EXCLUDED else False

    filters = daily[["atr14","ma200","bb_lower","kc_lower","wyckoff_raw"]].shift(1)
    filters = filters.join(regime_sp500, how="left").ffill()
    daily_filters[sym] = filters

def simulate_fixed(h1, entry_idx, entry, sl, tp):
    for j in range(entry_idx+1, min(entry_idx+1+MAX_HOLDING_H1_BARS, len(h1))):
        row = h1.iloc[j]
        if row["low"]<=sl: return "sl_hit", sl, j-entry_idx
        if row["high"]>=tp: return "tp_hit", tp, j-entry_idx
    j_max = min(entry_idx+MAX_HOLDING_H1_BARS, len(h1)-1)
    return "time_exit", h1.iloc[j_max]["close"], j_max-entry_idx

all_trades = []
skipped_for_news = 0
for sym in INDICES_7:
    h1 = h1_data[sym]
    filters_on_h1 = daily_filters[sym].reindex(h1.index, method="ffill")
    hour = pd.Series(h1.index, index=h1.index).dt.hour
    within_window = (hour>=9)&(hour<20)
    in_position_until = None
    for i in range(24*30, len(h1)-1):
        if in_position_until is not None and h1.index[i] < in_position_until: continue
        if not within_window.iloc[i]: continue
        atr=filters_on_h1["atr14"].iloc[i]; ma200=filters_on_h1["ma200"].iloc[i]
        bbl=filters_on_h1["bb_lower"].iloc[i]; kcl=filters_on_h1["kc_lower"].iloc[i]
        wyckoff=filters_on_h1["wyckoff_raw"].iloc[i]; regime=filters_on_h1["atr_percentile"].iloc[i]
        if pd.isna(atr) or pd.isna(ma200) or pd.isna(regime): continue
        if regime>=REGIME_THRESHOLD: continue
        price = h1.iloc[i]["close"]
        signal = False
        if not pd.isna(bbl) and price>ma200 and price<bbl: signal=True
        if not pd.isna(kcl) and price>ma200 and price<kcl: signal=True
        if not pd.isna(wyckoff) and bool(wyckoff) and price>ma200: signal=True
        if not signal: continue
        if h1.index[i].date() in NEWS_DATES:
            skipped_for_news += 1
            continue
        entry=price; sl=entry-1.5*atr; risk=entry-sl
        if risk<=0: continue
        tp=entry+1.5*risk
        outcome, exit_price, bars = simulate_fixed(h1, i, entry, sl, tp)
        r_result = 1.5 if outcome=="tp_hit" else (-1.0 if outcome=="sl_hit" else (exit_price-entry)/risk)
        spread_cost_r = SPREAD_POINTS[sym]/risk
        net_r = np.clip(r_result,-10,10) - spread_cost_r
        entry_time=h1.index[i]; exit_time=h1.index[min(i+bars, len(h1)-1)]
        all_trades.append({"symbol":sym,"entry":entry_time,"exit":exit_time,"net_r":net_r})
        in_position_until = exit_time

df = pd.DataFrame(all_trades).sort_values("entry").reset_index(drop=True)
print(f"Total trades: {len(df)} | Signals skipped for news: {skipped_for_news}")
development = df[df["entry"]<CUTOFF]; validation = df[df["entry"]>=CUTOFF]
print(f"Development (<2020): n={len(development)} net={development['net_r'].mean():+.3f}R winrate={100*(development['net_r']>0).mean():.1f}%")
print(f"Validation (>=2020): n={len(validation)} net={validation['net_r'].mean():+.3f}R winrate={100*(validation['net_r']>0).mean():.1f}%\n")

equity = 10000.0
curve = [(df["entry"].iloc[0], equity)]
for _, row in df.iterrows():
    equity += row["net_r"]*(equity*0.0134)
    curve.append((row["entry"], equity))
equity_curve = pd.Series([c[1] for c in curve], index=[c[0] for c in curve])
daily_curve = equity_curve.resample("1D").last().ffill()

dd = (daily_curve-daily_curve.cummax())/daily_curve.cummax()*100
print(f"Worst drawdown: {dd.min():.1f}% on {dd.idxmin().date()}")
print(f"Final equity: {daily_curve.iloc[-1]:.0f}  (starting {daily_curve.iloc[0]:.0f})")
print(f"Overall win rate: {100*(df['net_r']>0).mean():.1f}%  Average R: {df['net_r'].mean():+.3f}")

val_curve = daily_curve[daily_curve.index>=CUTOFF]
if len(val_curve) > 1:
    return_val = 100*(val_curve.iloc[-1]/val_curve.iloc[0]-1)
    years_val = (val_curve.index[-1]-val_curve.index[0]).days/365.25
    cagr_val = 100*((val_curve.iloc[-1]/val_curve.iloc[0])**(1/years_val)-1)
    dd_val = (val_curve-val_curve.cummax())/val_curve.cummax()*100
    print(f"\nValidation 2020-2026: return={return_val:+.1f}% CAGR={cagr_val:.1f}%/year MaxDD={dd_val.min():.1f}%")
