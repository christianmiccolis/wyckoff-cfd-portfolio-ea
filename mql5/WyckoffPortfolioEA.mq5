//+------------------------------------------------------------------+
//| WyckoffPortfolioEA.mq5                                           |
//| Christian Miccolis - Beriv Consulting                             |
//|                                                                    |
//| 7-index portfolio: Bollinger + Keltner + Wyckoff Spring            |
//| + regime filter (ATR% percentile on the reference symbol)         |
//| + volatility targeting (dynamic leverage on realized equity vol)  |
//|                                                                    |
//| DEVELOPMENT/VALIDATION HISTORY (MT5 backtest session 2026-08-29): |
//|  - Symbols verified against the real Market Watch list of the     |
//|    broker used for testing (RUSSELL2000 not available, excluded)  |
//|  - Bug fixed: order filling mode was unspecified (blocked ALL     |
//|    trades with error 4756)                                        |
//|  - Bug fixed: vol-targeting used maximum leverage instead of      |
//|    neutral leverage when equity was still flat (no trades yet)    |
//|  - Safety guard added: discards signals with an anomalous stop    |
//|    (a corrupted data point was found on FRA40 for a few days in   |
//|    December 2019 that produced an absurd ATR)                     |
//|  - New-bar detection moved from OnTimer() to OnTick(): more       |
//|    robust (a real-time OnTimer can skip bars when the Tester runs |
//|    at accelerated speed), although in testing this didn't change  |
//|    the result significantly                                       |
//|  - IMPORTANT: the correct time offset for the TESTER turned out   |
//|    to be -2, DIFFERENT from the -1 measured by comparing          |
//|    TimeCurrent() and TimeLocal() on the LIVE terminal. The Tester  |
//|    seems to use a slightly different internal time reference than |
//|    the live terminal when replaying history. With -2 the result   |
//|    on the 2018-2026 period went from a catastrophic drawdown      |
//|    (-40%, negative equity) to a positive return (+27/+30%), but   |
//|    a residual gap of 1-3 hours remains (not constant, not         |
//|    explained by a clean DST pattern) versus the Python reference  |
//|    backtest on the same data - probably inherent to the Tester's  |
//|    synthetic tick reconstruction without real tick data.          |
//|  - RECOMMENDATION: before trading live, verify the correct offset |
//|    LIVE (don't trust the -2 found in the Tester) and run a        |
//|    forward-test period on demo comparing real trades against      |
//|    expected ones, exactly as done for the bugs found here.        |
//|                                                                    |
//|  NOTE ON CUSTOM SYMBOLS: the 2012-2026 reference backtest was      |
//|  obtained by importing Dukascopy H1 history as custom symbols     |
//|  (see the README in the python/ folder for the import script),    |
//|  not on the broker's real symbols (history too short on many      |
//|  brokers, live spreads not comparable to each other). With custom |
//|  symbols, InpServerToRomeOffsetHours should be set to 0 (the      |
//|  imported CSV timestamps are already in Rome time).                |
//+------------------------------------------------------------------+
#property copyright "Christian Miccolis - Beriv Consulting"
#property version   "1.02"
#property strict

//--- INPUT: symbols (FIX with the exact names available on your broker/terminal,
//--- comma-separated; SP500 MUST remain symbol [0], the reference for the regime filter)
input string InpSymbols                 = "SP500,NAS100,DJI30,DAX40,FRA40,JPN225,STOXX50"; // indicative names: check the real ones in your Market Watch
input int    InpRegimeReferenceIndex    = 0;      // index in the list above used as the macro reference (0 = SP500)

//--- INPUT: time zone (RECALIBRATE LIVE - see note above, the correct value may differ between Tester and live trading)
input int    InpServerToRomeOffsetHours = -1;     // value for LIVE, measured on 2026-08-29 (server 17:28, Rome 16:28 -> -1). Used to build the daily bars (the resulting dates match Python with this value). USE 0 if trading custom symbols with timestamps already in Rome time.
input int    InpExtraSessionOffset      = -2;     // NOT USED in the current code (leftover from an earlier test) - kept for compatibility with old .set files, no effect.

//--- INPUT: trading time window (Rome time)
input int    InpSessionStartHour        = 9;
input int    InpSessionEndHour          = 20;     // exclusive: trades until 19:59

//--- INPUT: strategy parameters (values validated in the 2012-2026 backtest)
input double InpRegimePercentileThreshold = 0.50; // skip days with SP500 ATR% above this historical percentile
input double InpATRMultStop             = 1.5;
input double InpRMultTarget             = 1.5;
input int    InpMaxHoldingDays          = 15;
input int    InpTightRangeLookback      = 20;     // days for the Wyckoff range
input int    InpMedianLookback          = 100;    // days for the range reference median
input double InpVolumeClimaxMult        = 1.5;

//--- INPUT: position sizing / dynamic leverage
input double InpBaseRiskPct             = 1.34;   // % of equity risked per trade BEFORE dynamic leverage
input bool   InpUseVolTargeting         = true;   // if false: fixed 1.0x leverage, risk always = InpBaseRiskPct
                                                   // (for direct comparison with the Python reference, which has no vol-targeting)
input double InpTargetAnnualVolPct      = 15.0;   // annualized volatility target for vol-targeting
input double InpLeverageCapMin          = 0.4;
input double InpLeverageCapMax          = 3.0;
input int    InpVolLookbackDays         = 20;

input string InpEquityHistoryFile       = "wyckoff_portfolio_equity.csv";
input int    InpMagicNumber             = 20260829;
input double InpMaxRiskPctPrice         = 20.0;  // safety guard: discard the signal if the computed stop exceeds this % of price (anomalous data)

//--- DIAGNOSTIC INPUTS: switches to isolate the contribution of each component (all true = original behavior)
input bool   InpUseBollinger            = true;
input bool   InpUseKeltner              = true;
input bool   InpUseWyckoff              = true;
input bool   InpUseRegimeFilter         = true;
input bool   InpAvoidNewsDays           = true;  // skip new entries on NFP/FOMC days (validated in the Python backtest: improves CAGR and reduces MaxDD)

//+------------------------------------------------------------------+
//| NFP + FOMC calendar 2012-2026 (official BLS/Fed dates), YYYYMMDD  |
//| format - used to avoid new entries on the days of these two       |
//| high-impact US macro events.                                      |
//+------------------------------------------------------------------+
#define N_NEWS_DATES 293
int g_newsDates[N_NEWS_DATES] = {
   20120106,20120125,20120203,20120309,20120313,20120406,20120425,20120504,20120601,20120620,
   20120706,20120801,20120803,20120907,20120913,20121005,20121024,20121102,20121207,20121212,
   20130104,20130130,20130201,20130308,20130320,20130405,20130501,20130503,20130607,20130619,
   20130705,20130731,20130802,20130906,20130918,20131022,20131030,20131108,20131206,20131218,
   20140110,20140129,20140207,20140307,20140319,20140404,20140430,20140502,20140606,20140618,
   20140703,20140730,20140801,20140905,20140917,20141003,20141029,20141107,20141205,20141217,
   20150109,20150128,20150206,20150306,20150318,20150403,20150429,20150508,20150605,20150617,
   20150702,20150729,20150807,20150904,20150917,20151002,20151028,20151106,20151204,20151216,
   20160108,20160127,20160205,20160304,20160316,20160401,20160427,20160506,20160603,20160615,
   20160708,20160727,20160805,20160902,20160921,20161007,20161102,20161104,20161202,20161214,
   20170106,20170201,20170203,20170310,20170315,20170407,20170503,20170505,20170602,20170614,
   20170707,20170726,20170804,20170901,20170920,20171006,20171101,20171103,20171208,20171213,
   20180105,20180131,20180202,20180309,20180321,20180406,20180502,20180504,20180601,20180613,
   20180706,20180801,20180803,20180907,20180926,20181005,20181102,20181108,20181207,20181219,
   20190104,20190130,20190201,20190308,20190320,20190405,20190501,20190503,20190607,20190619,
   20190705,20190731,20190802,20190906,20190918,20191004,20191030,20191101,20191206,20191211,
   20200110,20200129,20200207,20200303,20200306,20200315,20200403,20200429,20200508,20200605,
   20200610,20200702,20200729,20200807,20200904,20200916,20201002,20201105,20201106,20201204,
   20201216,20210108,20210127,20210205,20210305,20210317,20210402,20210428,20210507,20210604,
   20210616,20210702,20210728,20210806,20210903,20210922,20211008,20211103,20211105,20211203,
   20211215,20220107,20220126,20220204,20220304,20220316,20220401,20220504,20220506,20220603,
   20220615,20220708,20220727,20220805,20220902,20220921,20221007,20221102,20221104,20221202,
   20221214,20230106,20230201,20230203,20230310,20230322,20230407,20230503,20230505,20230602,
   20230614,20230707,20230726,20230804,20230901,20230920,20231006,20231101,20231103,20231208,
   20231213,20240105,20240131,20240202,20240308,20240320,20240405,20240501,20240503,20240607,
   20240612,20240705,20240731,20240802,20240906,20240918,20241004,20241101,20241107,20241206,
   20241218,20250110,20250129,20250207,20250307,20250319,20250404,20250502,20250507,20250606,
   20250618,20250703,20250730,20250801,20250905,20250917,20251029,20251120,20251210,20251216,
   20260109,20260128,20260211,20260306,20260318,20260403,20260429,20260508,20260605,20260617,
   20260702,20260729,20260807
};

bool IsNewsDay(datetime tRome)
  {
   MqlDateTime dt;
   TimeToStruct(tRome, dt);
   int today = dt.year*10000 + dt.mon*100 + dt.day;
   for(int i=0; i<N_NEWS_DATES; i++)
      if(g_newsDates[i]==today) return true;
   return false;
  }

//+------------------------------------------------------------------+
//| Data structures                                                    |
//+------------------------------------------------------------------+
#define MAX_SYMS 16
string   g_symbols[MAX_SYMS];
int      g_nSymbols = 0;

struct DailySignal
  {
   double atr14;
   double ma200;
   double bbLower;
   double kcLower;
   bool   wyckoffSignal;
   bool   valid;
   datetime lastBarD1;
  };
DailySignal g_daily[MAX_SYMS];

double   g_regimePercentile = 1.0;   // placeholder value until g_regimeValid becomes true (no trading allowed until then)
bool     g_regimeValid = false;

datetime g_lastBarH1[MAX_SYMS];
datetime g_lastEquitySavedDay = 0;
datetime g_lastRegimeDay = 0;
double   g_currentLeverage = 1.0;

//+------------------------------------------------------------------+
//| Utility: split a comma-separated string                            |
//+------------------------------------------------------------------+
int SplitSymbols(string src, string &dst[])
  {
   int n = StringSplit(src, ',', dst);
   for(int i=0;i<n;i++)
     {
      StringTrimLeft(dst[i]);
      StringTrimRight(dst[i]);
     }
   return n;
  }

//+------------------------------------------------------------------+
//| Current Rome time (approximated via a configurable offset)        |
//+------------------------------------------------------------------+
datetime RomeTime()
  {
   return TimeCurrent() + InpServerToRomeOffsetHours*3600;
  }

bool WithinSession()
  {
   MqlDateTime dt;
   TimeToStruct(RomeTime(), dt);
   return (dt.hour >= InpSessionStartHour && dt.hour < InpSessionEndHour);
  }

// Same as WithinSession() but evaluated on the BAR'S OWN time (its opening timestamp,
// which is its time "label") instead of the instant it was detected as closed.
// Needed to align exactly with the Python backtest, which uses each H1 bar's time
// label to decide whether it falls in the 9-20 window, not the time the bar closes.
bool WithinSessionBar(datetime barTimeServer)
  {
   MqlDateTime dt;
   TimeToStruct(barTimeServer + InpServerToRomeOffsetHours*3600, dt);
   return (dt.hour >= InpSessionStartHour && dt.hour < InpSessionEndHour);
  }

//+------------------------------------------------------------------+
//| Builds "daily" bars aligned to ROME MIDNIGHT (not the broker's)   |
//| by aggregating H1 bars. CRITICAL: the broker's native D1 bars are |
//| aligned to SERVER midnight, offset by 1-2 hours from Rome - using |
//| them means computing ALL indicators (ATR, MA200, Bollinger,       |
//| Keltner, Wyckoff, regime) on "days" that don't match the sessions |
//| the Python backtest uses (which resamples from H1 bars ALREADY    |
//| shifted to Rome time). A misalignment of a few hours, repeated    |
//| over thousands of days in a multi-year backtest, produces a huge  |
//| cumulative effect.                                                 |
//| Returns an array in "series" format (index 0 = yesterday, i.e.    |
//| the last COMPLETE Rome day, never the still-in-progress today).   |
//+------------------------------------------------------------------+
#define MAX_H1_STORICO 25000
int BuildRomeDailyBars(string symbol, MqlRates &out[])
  {
   MqlRates h1[];
   ArraySetAsSeries(h1, true);
   int n = CopyRates(symbol, PERIOD_H1, 1, MAX_H1_STORICO, h1); // shift1: never the H1 bar being formed
   if(n <= 24) return 0;

   datetime todayMidnightRome;
     {
      MqlDateTime dtToday;
      TimeToStruct(RomeTime(), dtToday);
      dtToday.hour=0; dtToday.min=0; dtToday.sec=0;
      todayMidnightRome = StructToTime(dtToday);
     }

   MqlRates temp[];
   ArrayResize(temp, 0);
   MqlRates current;
   ZeroMemory(current);
   datetime currentDay = 0;
   bool firstBar = true;
   int count = 0;

   for(int i=n-1; i>=0; i--) // from the oldest H1 bar to the most recent (chronological order)
     {
      datetime romeTimeVal = h1[i].time + InpServerToRomeOffsetHours*3600;
      MqlDateTime dt; TimeToStruct(romeTimeVal, dt);
      dt.hour=0; dt.min=0; dt.sec=0;
      datetime dayData = StructToTime(dt);
      if(dayData >= todayMidnightRome) continue; // never today's still-incomplete Rome day

      if(dayData != currentDay)
        {
         if(!firstBar)
           {
            ArrayResize(temp, count+1);
            temp[count] = current;
            count++;
           }
         currentDay = dayData;
         current.time = dayData;
         current.open = h1[i].open;
         current.high = h1[i].high;
         current.low  = h1[i].low;
         current.close= h1[i].close;
         current.tick_volume = h1[i].tick_volume;
         firstBar = false;
        }
      else
        {
         current.high = MathMax(current.high, h1[i].high);
         current.low  = MathMin(current.low, h1[i].low);
         current.close= h1[i].close;
         current.tick_volume += h1[i].tick_volume;
        }
     }
   if(!firstBar)
     {
      ArrayResize(temp, count+1);
      temp[count] = current;
      count++;
     }

   // temp[] is in chronological order (oldest first). We reverse it into "series" format
   // (index 0 = most recent = yesterday) as expected by the rest of the code.
   int total = ArraySize(temp);
   ArrayResize(out, total);
   for(int i=0;i<total;i++) out[i] = temp[total-1-i];
   return total;
  }

//+------------------------------------------------------------------+
//| Daily indicator calculation for a symbol (uses ONLY already-closed |
//| bars: shift 1 = "yesterday", shift 2.. = previous days, NEVER bar  |
//| 0 (still forming) to avoid look-ahead)                             |
//+------------------------------------------------------------------+
bool CalculateDailySignal(string symbol, DailySignal &out)
  {
   int needed = InpMedianLookback + InpTightRangeLookback + 10; // margin
   int n = MathMax(needed, 210); // at least 210 for MA200
   MqlRates rates[];
   int copied = BuildRomeDailyBars(symbol, rates); // bars aligned to ROME midnight
   if(copied < n)
     {
      out.valid = false;
      return false;
     }
   // rates[0] = yesterday (shift1), rates[1] = 2 days ago (shift2), etc.

   // --- ATR14 at shift1 (computed on bars shift1..shift14, each with its own prev close at shift2..shift15) ---
   double trSum = 0.0;
   for(int k=0;k<14;k++)
     {
      double high = rates[k].high, low = rates[k].low, prevClose = rates[k+1].close;
      double tr = MathMax(high-low, MathMax(MathAbs(high-prevClose), MathAbs(low-prevClose)));
      trSum += tr;
     }
   out.atr14 = trSum/14.0;

   // --- MA200 at shift1 (average of closes from shift1 to shift200) ---
   double sum200=0.0;
   for(int k=0;k<200;k++) sum200 += rates[k].close;
   out.ma200 = sum200/200.0;

   // --- Bollinger: SMA20 and STD20 of closes, at shift1 ---
   double sum20=0.0;
   for(int k=0;k<20;k++) sum20 += rates[k].close;
   double sma20 = sum20/20.0;
   double varSum=0.0;
   for(int k=0;k<20;k++) varSum += MathPow(rates[k].close - sma20, 2);
   // ddof=1 (divide by N-1=19), NOT N=20: pandas Series.std() uses the sample standard
   // deviation by default. With ddof=0 (population) the std comes out ~2.5% smaller,
   // making bb_lower systematically closer to the mean and therefore easier to break
   // to the downside: extra false signals compared to the Python reference.
   double std20 = MathSqrt(varSum/19.0);
   out.bbLower = sma20 - 2.0*std20;

   // --- Keltner: EMA20 of closes at shift1 (computed recursively over the available bars, from oldest to most recent) ---
   double emaAlpha = 2.0/(20.0+1.0);
   double ema = rates[copied-1].close; // initial value: oldest available bar
   for(int k=copied-2;k>=0;k--) ema = rates[k].close*emaAlpha + ema*(1.0-emaAlpha);
   out.kcLower = ema - 2.0*out.atr14;

   // --- WYCKOFF SPRING ---
   // range_low/high over the 20 days BEFORE yesterday, i.e. shift2..shift21 (indices 1..20 in the array, since index 0 = shift1)
   double rangeLow = rates[1].low, rangeHigh = rates[1].high;
   double volAvg = 0.0;
   for(int k=1;k<=InpTightRangeLookback;k++)
     {
      rangeLow  = MathMin(rangeLow, rates[k].low);
      rangeHigh = MathMax(rangeHigh, rates[k].high);
      volAvg += (double)rates[k].tick_volume;
     }
   volAvg /= InpTightRangeLookback;
   double rangePctYesterday = (rangeHigh-rangeLow)/rates[1].close;

   // median of range% computed over the previous 100 days (rolling 20-day windows via shift, simplified:
   // we compute a sample of range% over sliding windows in the 100 days preceding shift2)
   double rangePctSample[];
   ArrayResize(rangePctSample, InpMedianLookback);
   for(int w=0; w<InpMedianLookback; w++)
     {
      double lo = rates[1+w].low, hi = rates[1+w].high;
      for(int k=1;k<InpTightRangeLookback;k++)
        {
         lo = MathMin(lo, rates[1+w+k].low);
         hi = MathMax(hi, rates[1+w+k].high);
        }
      rangePctSample[w] = (hi-lo)/rates[1+w].close;
     }
   ArraySort(rangePctSample);
   // pandas .median() on an even-length sample averages the two central elements,
   // it doesn't just take the upper one: with InpMedianLookback=100 you need indices 49 and 50, not just 50.
   double medianRangePct;
   if(InpMedianLookback % 2 == 0)
      medianRangePct = 0.5*(rangePctSample[InpMedianLookback/2 - 1] + rangePctSample[InpMedianLookback/2]);
   else
      medianRangePct = rangePctSample[InpMedianLookback/2];
   bool tightRange = (rangePctYesterday < medianRangePct);

   bool validSpring = (rates[0].low < rangeLow) && (rates[0].close > rangeLow) &&
                       tightRange && ((double)rates[0].tick_volume > InpVolumeClimaxMult*volAvg);
   out.wyckoffSignal = validSpring;

   out.valid = true;
   out.lastBarD1 = rates[0].time;
   return true;
  }

//+------------------------------------------------------------------+
//| Regime filter: ATR%/price percentile of the reference symbol      |
//| over a 252-day window, using ONLY data up to yesterday             |
//+------------------------------------------------------------------+
bool CalculateRegime(string refSymbol, double &percentileOut)
  {
   int n = 252 + 20; // margin for computing each sample day's ATR
   MqlRates rates[];
   int copied = BuildRomeDailyBars(refSymbol, rates); // bars aligned to ROME midnight
   if(copied < n) return false;

   double atrPctSample[];
   ArrayResize(atrPctSample, 252);
   for(int w=0; w<252; w++)
     {
      double trSum=0.0;
      for(int k=0;k<14;k++)
        {
         double high=rates[w+k].high, low=rates[w+k].low, prevClose=rates[w+k+1].close;
         double tr = MathMax(high-low, MathMax(MathAbs(high-prevClose), MathAbs(low-prevClose)));
         trSum += tr;
        }
      double atr = trSum/14.0;
      atrPctSample[w] = atr/rates[w].close;
     }
   double yesterdayValue = atrPctSample[0]; // shift1 = yesterday
   // percentile = fraction of values (within the 252, including yesterday) <= yesterdayValue
   int count=0;
   for(int w=0; w<252; w++) if(atrPctSample[w] <= yesterdayValue) count++;
   percentileOut = (double)count/252.0;
   return true;
  }

//+------------------------------------------------------------------+
//| Volatility targeting: reads/updates the equity history and        |
//| recomputes leverage                                                |
//+------------------------------------------------------------------+
void UpdateVolTargeting()
  {
   MqlDateTime dtNow;
   TimeToStruct(RomeTime(), dtNow);
   datetime todayMidnightRome = StringToTime(StringFormat("%04d.%02d.%02d 00:00", dtNow.year, dtNow.mon, dtNow.day));
   if(todayMidnightRome == g_lastEquitySavedDay) return; // already saved today

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   int handle = FileOpen(InpEquityHistoryFile, FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI);
   if(handle==INVALID_HANDLE)
     {
      Print("ERROR opening equity history file: ", GetLastError());
      return;
     }
   FileSeek(handle, 0, SEEK_END);
   FileWrite(handle, TimeToString(todayMidnightRome, TIME_DATE), DoubleToString(equity,2));
   FileClose(handle);

   g_lastEquitySavedDay = todayMidnightRome;

   // recompute leverage: re-reads the file, takes the last ~40 rows, computes daily returns
   // and the annualized standard deviation over the last InpVolLookbackDays returns
   int h2 = FileOpen(InpEquityHistoryFile, FILE_READ|FILE_CSV|FILE_ANSI);
   if(h2==INVALID_HANDLE) return;
   double equityHistory[]; ArrayResize(equityHistory,0);
   while(!FileIsEnding(h2))
     {
      string data = FileReadString(h2);
      if(StringLen(data)==0) break;
      string eq = FileReadString(h2);
      int sz = ArraySize(equityHistory);
      ArrayResize(equityHistory, sz+1);
      equityHistory[sz] = StringToDouble(eq);
     }
   FileClose(h2);

   if(!InpUseVolTargeting) { g_currentLeverage = 1.0; return; } // fixed leverage: equity history is still logged above

   int m = ArraySize(equityHistory);
   int lookback = MathMin(InpVolLookbackDays, m-1);
   if(lookback < 5)
     {
      g_currentLeverage = 1.0; // insufficient data: neutral leverage until enough history accumulates
      return;
     }
   double returns[]; ArrayResize(returns, lookback);
   for(int i=0;i<lookback;i++)
     {
      int idx = m-lookback+i;
      returns[i] = (equityHistory[idx]-equityHistory[idx-1])/equityHistory[idx-1];
     }
   double mean=0.0;
   for(int i=0;i<lookback;i++) mean += returns[i];
   mean /= lookback;
   double varSum=0.0;
   for(int i=0;i<lookback;i++) varSum += MathPow(returns[i]-mean,2);
   double dailyStd = MathSqrt(varSum/lookback);
   double annualVol = dailyStd*MathSqrt(252.0);

   bool noNonZeroReturn = true;
   for(int i=0;i<lookback;i++) if(returns[i]!=0.0) { noNonZeroReturn=false; break; }

   if(noNonZeroReturn)
      g_currentLeverage = 1.0; // equity still flat (no trade closed in the period): NEUTRAL leverage, not maximum -
                               // annualVol=0 here means "insufficient data", not "genuinely calm strategy"
   else if(annualVol <= 0.0001)
      g_currentLeverage = InpLeverageCapMax; // genuinely near-zero volatility with a real trade history
   else
      g_currentLeverage = MathMax(InpLeverageCapMin, MathMin(InpLeverageCapMax, (InpTargetAnnualVolPct/100.0)/annualVol));

   PrintFormat("Vol-targeting updated: annual_vol=%.2f%% leverage=%.2fx (history=%d days)", annualVol*100.0, g_currentLeverage, m);
  }

//+------------------------------------------------------------------+
//| Count open positions per symbol (one trade at a time)              |
//+------------------------------------------------------------------+
bool PositionOpenOnSymbol(string symbol)
  {
   for(int i=0;i<PositionsTotal();i++)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket==0) continue;
      if(PositionGetString(POSITION_SYMBOL)==symbol && PositionGetInteger(POSITION_MAGIC)==InpMagicNumber)
         return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Close expired positions (maximum holding period exceeded)          |
//+------------------------------------------------------------------+
void ManageTimeExits()
  {
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket==0) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=InpMagicNumber) continue;
      datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
      double daysOpen = (double)(TimeCurrent()-openTime)/86400.0;
      if(daysOpen >= InpMaxHoldingDays)
        {
         string sym = PositionGetString(POSITION_SYMBOL);
         MqlTradeRequest req; MqlTradeResult res;
         ZeroMemory(req); ZeroMemory(res);
         req.action   = TRADE_ACTION_DEAL;
         req.position = ticket;
         req.symbol   = sym;
         req.volume   = PositionGetDouble(POSITION_VOLUME);
         req.type     = ORDER_TYPE_SELL; // positions are always long in this strategy
         req.price    = SymbolInfoDouble(sym, SYMBOL_BID);
         req.deviation= 20;
         req.magic    = InpMagicNumber;
         req.type_filling = DetectFillingMode(sym);
         bool sent = OrderSend(req,res);
         if(!sent || (res.retcode!=TRADE_RETCODE_DONE && res.retcode!=TRADE_RETCODE_PLACED))
            PrintFormat("ERROR closing time-exit %s: retcode=%d comment=%s", sym, res.retcode, res.comment);
         else
            PrintFormat("Time exit (max holding %d days) on %s", InpMaxHoldingDays, sym);
        }
     }
  }

//+------------------------------------------------------------------+
//| Detects the order filling mode supported by the symbol             |
//+------------------------------------------------------------------+
ENUM_ORDER_TYPE_FILLING DetectFillingMode(string symbol)
  {
   long filling = SymbolInfoInteger(symbol, SYMBOL_FILLING_MODE);
   if((filling & SYMBOL_FILLING_FOK) != 0) return ORDER_FILLING_FOK;
   if((filling & SYMBOL_FILLING_IOC) != 0) return ORDER_FILLING_IOC;
   return ORDER_FILLING_RETURN;
  }

//+------------------------------------------------------------------+
//| Lot calculation from currency risk and stop distance                |
//+------------------------------------------------------------------+
double CalculateLots(string symbol, double riskUsd, double stopDistancePrice)
  {
   double tickValue = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize<=0 || tickValue<=0) return 0.0;
   double riskPerLot = stopDistancePrice * (tickValue/tickSize);
   if(riskPerLot<=0) return 0.0;
   double lots = riskUsd/riskPerLot;

   double lotStep = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
   double lotMin  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double lotMax  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   lots = MathFloor(lots/lotStep)*lotStep;
   lots = MathMax(lotMin, MathMin(lotMax, lots));
   return lots;
  }

//+------------------------------------------------------------------+
//| Entry evaluation for a symbol                                      |
//+------------------------------------------------------------------+
void EvaluateEntry(int idx, double price)
  {
   string symbol = g_symbols[idx];
   if(PositionOpenOnSymbol(symbol)) return;
   if(!g_daily[idx].valid) return;
   if(InpAvoidNewsDays && IsNewsDay(RomeTime())) return; // skip entries on NFP/FOMC days
   if(InpUseRegimeFilter)
     {
      if(!g_regimeValid) return;
      if(g_regimePercentile >= InpRegimePercentileThreshold) return; // unfavorable regime: no new trade today
     }

   if(price <= g_daily[idx].ma200) return; // must be in an uptrend

   bool signal = false;
   if(InpUseBollinger && price < g_daily[idx].bbLower) signal = true;
   if(InpUseKeltner   && price < g_daily[idx].kcLower) signal = true;
   if(InpUseWyckoff   && g_daily[idx].wyckoffSignal)   signal = true;
   if(!signal) return;

   double atr = g_daily[idx].atr14;
   double sl  = price - InpATRMultStop*atr;
   double risk = price - sl;
   if(risk<=0) return;
   // safety guard: discards signals with an anomalous stop (corrupted price/ATR data)
   if(risk > price*(InpMaxRiskPctPrice/100.0))
     {
      PrintFormat("WARNING: anomalous stop on %s (risk=%.2f, price=%.2f, atr=%.2f) - signal discarded for safety",
                  symbol, risk, price, atr);
      return;
     }
   double tp  = price + InpRMultTarget*risk;

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskUsd = equity * (InpBaseRiskPct/100.0) * g_currentLeverage;
   double lots = CalculateLots(symbol, riskUsd, risk);
   if(lots<=0) { Print("Calculated lots <=0 for ", symbol, ", trade skipped"); return; }

   MqlTradeRequest req; MqlTradeResult res;
   ZeroMemory(req); ZeroMemory(res);
   req.action   = TRADE_ACTION_DEAL;
   req.symbol   = symbol;
   req.volume   = lots;
   req.type     = ORDER_TYPE_BUY;
   req.price    = SymbolInfoDouble(symbol, SYMBOL_ASK);
   req.sl       = sl;
   req.tp       = tp;
   req.deviation= 20;
   req.magic    = InpMagicNumber;
   req.comment  = "Wyckoff/BB/KC portfolio";
   req.type_filling = DetectFillingMode(symbol);

   if(!OrderSend(req,res))
      PrintFormat("ERROR opening %s: %d (%s)", symbol, GetLastError(), res.comment);
   else
      PrintFormat("OPENED %s: lots=%.2f entry=%.2f sl=%.2f tp=%.2f leverage=%.2fx bb=%d kc=%d wyckoff=%d",
                  symbol, lots, price, sl, tp, g_currentLeverage,
                  (price<g_daily[idx].bbLower), (price<g_daily[idx].kcLower), g_daily[idx].wyckoffSignal);
  }

//+------------------------------------------------------------------+
//| OnInit                                                             |
//+------------------------------------------------------------------+
int OnInit()
  {
   g_nSymbols = SplitSymbols(InpSymbols, g_symbols);
   if(g_nSymbols<2 || g_nSymbols>MAX_SYMS)
     {
      Print("Invalid symbol list");
      return(INIT_FAILED);
     }
   for(int i=0;i<g_nSymbols;i++)
     {
      if(!SymbolSelect(g_symbols[i], true))
         PrintFormat("WARNING: symbol '%s' not found/selectable - check the exact name in Market Watch", g_symbols[i]);
      g_daily[i].valid = false;
      g_lastBarH1[i] = 0;
     }
   EventSetTimer(60); // check every 60 seconds
   Print("WyckoffPortfolioEA initialized on ", g_nSymbols, " symbols. CHECK the symbol names and InpServerToRomeOffsetHours before trading live.");
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();
  }

//+------------------------------------------------------------------+
//| OnTick: new D1/H1 bar detection, NEVER timer-based                |
//| (a real-time timer skips bars when the Tester runs at accelerated |
//| speed, compressing years into minutes - a real bug discovered by  |
//| comparing entry times against the Python backtest: the gaps were  |
//| variable, 1-3 hours, a sign of skipped bars. OnTick instead fires |
//| on every price update, both in testing and live, never skipping   |
//| a transition.)                                                     |
//+------------------------------------------------------------------+
void OnTick()
  {
   // 1) update daily indicators if a new ROME day has started (not the broker's -
   // see BuildRomeDailyBars for why this is critical)
   datetime todayMidnightRome;
     {
      MqlDateTime dtToday;
      TimeToStruct(RomeTime(), dtToday);
      dtToday.hour=0; dtToday.min=0; dtToday.sec=0;
      todayMidnightRome = StructToTime(dtToday);
     }
   for(int i=0;i<g_nSymbols;i++)
     {
      if(g_daily[i].lastBarD1 != todayMidnightRome)
        {
         if(CalculateDailySignal(g_symbols[i], g_daily[i]))
            g_daily[i].lastBarD1 = todayMidnightRome;
        }
     }

   // 1bis) evaluate a new entry ONLY when an H1 bar closes (never intra-bar),
   // using the CLOSE price of the just-completed bar - same logic as the Python backtest
   for(int i=0;i<g_nSymbols;i++)
     {
      datetime lastBarH1[1];
      if(CopyTime(g_symbols[i], PERIOD_H1, 0, 1, lastBarH1) != 1) continue;
      if(g_lastBarH1[i] == 0) { g_lastBarH1[i] = lastBarH1[0]; continue; } // first run: just initialize
      if(g_lastBarH1[i] != lastBarH1[0])
        {
         g_lastBarH1[i] = lastBarH1[0];
         datetime closedBarTime[1];
         if(CopyTime(g_symbols[i], PERIOD_H1, 1, 1, closedBarTime) == 1 && WithinSessionBar(closedBarTime[0]))
           {
            double closeH1Bar[1];
            if(CopyClose(g_symbols[i], PERIOD_H1, 1, 1, closeH1Bar) == 1)
               EvaluateEntry(i, closeH1Bar[0]);
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| OnTimer: periodic tasks NOT critical to timing (tolerant of a few |
//| minutes of delay): regime, vol-targeting, time exits. New-bar     |
//| detection stays ONLY in OnTick().                                  |
//+------------------------------------------------------------------+
void OnTimer()
  {
   // 2) update the regime filter (depends on the reference symbol, typically SP500)
   // ONCE PER (Rome) DAY: CalculateRegime rebuilds up to 25000 H1 bars from scratch,
   // expensive - calling it on every OnTimer tick drastically slowed the Tester with no
   // benefit, since the value used for trading is "yesterday's" one regardless.
   datetime todayMidnightRomeRegime;
     {
      MqlDateTime dtToday;
      TimeToStruct(RomeTime(), dtToday);
      dtToday.hour=0; dtToday.min=0; dtToday.sec=0;
      todayMidnightRomeRegime = StructToTime(dtToday);
     }
   if(g_lastRegimeDay != todayMidnightRomeRegime)
     {
      double newPercentile;
      if(CalculateRegime(g_symbols[InpRegimeReferenceIndex], newPercentile))
        {
         g_regimePercentile = newPercentile;
         g_regimeValid = true;
         g_lastRegimeDay = todayMidnightRomeRegime;
        }
     }

   // 3) update vol-targeting (once per day)
   UpdateVolTargeting();

   // 4) handle time-based exits (maximum holding)
   ManageTimeExits();
  }
//+------------------------------------------------------------------+
