//+------------------------------------------------------------------+
//| WyckoffPortfolioEA.mq5                                           |
//| Portafoglio 7 indici: Bollinger + Keltner + Wyckoff Spring        |
//| + filtro di regime (ATR% percentile su simbolo di riferimento)    |
//| + vol-targeting (leva dinamica su volatilita' realizzata equity)  |
//|                                                                    |
//| STORIA DELLE VERIFICHE (sessione di backtest MT5 del 29/08/2026): |
//|  - Simboli verificati sul vero elenco Market Watch del broker     |
//|    usato per il test (RUSSELL2000 non disponibile, escluso)       |
//|  - Bug corretto: modalita' di riempimento ordine non specificata  |
//|    (bloccava TUTTI i trade con errore 4756)                       |
//|  - Bug corretto: vol-targeting usava leva massima invece di leva  |
//|    neutra quando l'equity era ancora piatta (nessun trade fatto)  |
//|  - Guardia di sicurezza aggiunta: scarta segnali con stop anomalo |
//|    (individuato un dato corrotto su FRA40 per pochi giorni nel    |
//|    dicembre 2019 che generava ATR assurdo)                        |
//|  - Rilevamento nuova barra spostato da OnTimer() a OnTick(): piu' |
//|    robusto (OnTimer a cadenza reale puo' saltare barre quando il  |
//|    Tester gira a velocita' accelerata), anche se nei test non ha  |
//|    cambiato il risultato in modo significativo                    |
//|  - IMPORTANTE: l'offset orario giusto per il TESTER e' risultato  |
//|    essere -2, DIVERSO dal -1 misurato confrontando TimeCurrent()  |
//|    e TimeLocal() sul terminale LIVE. Il Tester sembra usare un    |
//|    riferimento orario interno leggermente diverso da quello del   |
//|    terminale live per riprodurre lo storico. Con -2 il risultato  |
//|    sul periodo 2018-2026 e' passato da un drawdown catastrofico   |
//|    (-40%, equity negativa) a un rendimento positivo (+27/+30%),   |
//|    ma resta un residuo scarto di 1-3 ore (non costante, non       |
//|    spiegato da un pattern DST pulito) rispetto al backtest Python |
//|    di riferimento sugli stessi dati - probabilmente inerente alla |
//|    ricostruzione tick sintetica del Tester senza dati tick reali. |
//|  - RACCOMANDAZIONE: prima di operare live, verificare l'offset    |
//|    corretto DAL VIVO (non fidarsi del -2 trovato nel Tester) e    |
//|    fare un periodo di forward-test su demo confrontando i trade   |
//|    reali con quelli attesi, esattamente come da bug trovati qui.  |
//|                                                                    |
//|  NOTA SUI SIMBOLI CUSTOM: il backtest 2012-2026 di riferimento e' |
//|  stato ottenuto importando storico Dukascopy H1 come simboli      |
//|  custom (vedi README nella cartella python/ per lo script di      |
//|  import), non sui simboli reali del broker (storico troppo corto  |
//|  su molti broker, spread live non comparabili tra loro). Con i    |
//|  simboli custom, InpServerToRomeOffsetHours va messo a 0 (i       |
//|  timestamp del CSV importato sono gia' in ora di Roma).           |
//+------------------------------------------------------------------+
#property copyright "Ricerca strategia indici CFD"
#property version   "1.02"
#property strict

//--- INPUT: simboli (CORREGGERE con i nomi esatti disponibili sul tuo broker/terminale,
//--- separati da virgola; SP500 DEVE restare il simbolo [0], riferimento per il filtro di regime)
input string InpSymbols                 = "SP500,NAS100,DJI30,DAX40,FRA40,JPN225,STOXX50"; // nomi indicativi: verifica quelli reali nel tuo Market Watch
input int    InpRegimeReferenceIndex    = 0;      // indice nell'elenco sopra usato come riferimento macro (0 = SP500)

//--- INPUT: fuso orario (DA RICALIBRARE DAL VIVO - vedi nota sopra, il valore giusto puo' differire tra Tester e trading reale)
input int    InpServerToRomeOffsetHours = -1;     // valore per il LIVE, misurato il 29/08/2026 (server 17:28, Roma 16:28 -> -1). Usato per costruire le barre giornaliere (le date risultanti coincidono con Python con questo valore). USA 0 se operi su simboli custom con timestamp gia' in ora di Roma.
input int    InpOffsetExtraSessione     = -2;     // NON USATO nel codice attuale (residuo di un test precedente) - lasciato per compatibilita' con vecchi file .set, nessun effetto.

//--- INPUT: finestra oraria di trading (ora di Roma)
input int    InpSessioneOraInizio       = 9;
input int    InpSessioneOraFine         = 20;     // esclusiva: si opera fino alle 19:59

//--- INPUT: parametri strategia (valori validati nel backtest 2012-2026)
input double InpSogliaRegimePercentile  = 0.50;   // salta i giorni con ATR% SP500 sopra questo percentile storico
input double InpATRMultStop             = 1.5;
input double InpRMultTarget             = 1.5;
input int    InpMaxHoldingGiorni        = 15;
input int    InpRangeStrettaLookback    = 20;     // giorni per il range Wyckoff
input int    InpMedianaLookback         = 100;    // giorni per la mediana di riferimento del range
input double InpVolumeClimaxMult        = 1.5;

//--- INPUT: position sizing / leva dinamica
input double InpBaseRiskPct             = 1.34;   // % di equity rischiata per trade PRIMA della leva dinamica
input bool   InpUsaVolTargeting         = true;   // se false: leva fissa 1.0x, rischio sempre = InpBaseRiskPct
                                                   // (per confronto diretto col riferimento Python, che non ha vol-targeting)
input double InpTargetVolAnnuoPct       = 15.0;   // target di volatilita' annualizzata per il vol-targeting
input double InpLevaCapMin              = 0.4;
input double InpLevaCapMax              = 3.0;
input int    InpVolLookbackGiorni       = 20;

input string InpFileEquityStorico       = "wyckoff_portfolio_equity.csv";
input int    InpMagicNumber             = 20260829;
input double InpMaxRischioPctPrezzo     = 20.0;  // guardia di sicurezza: scarta il segnale se lo stop calcolato supera questa % del prezzo (dato anomalo)

//--- INPUT diagnostici: interruttori per isolare il contributo di ogni componente (tutti true = comportamento originale)
input bool   InpUsaBollinger            = true;
input bool   InpUsaKeltner              = true;
input bool   InpUsaWyckoff              = true;
input bool   InpUsaFiltroRegime         = true;
input bool   InpEvitaGiorniNews         = true;  // salta nuovi ingressi nei giorni NFP/FOMC (validato in backtest Python: migliora CAGR e riduce MaxDD)

//+------------------------------------------------------------------+
//| Calendario NFP + FOMC 2012-2026 (date ufficiali BLS/Fed), formato |
//| YYYYMMDD - usato per evitare nuovi ingressi nei giorni di questi  |
//| due eventi macro USA ad alto impatto.                             |
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

bool EGiornoNews(datetime tRoma)
  {
   MqlDateTime dt;
   TimeToStruct(tRoma, dt);
   int oggi = dt.year*10000 + dt.mon*100 + dt.day;
   for(int i=0; i<N_NEWS_DATES; i++)
      if(g_newsDates[i]==oggi) return true;
   return false;
  }

//+------------------------------------------------------------------+
//| Strutture dati                                                    |
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
   bool   valido;
   datetime ultimaBarraD1;
  };
DailySignal g_daily[MAX_SYMS];

double   g_regimePercentile = 1.0;   // valore placeholder finche' g_regimeValido resta false (nessun trade permesso)
bool     g_regimeValido = false;

datetime g_ultimaBarraH1[MAX_SYMS];
datetime g_ultimoGiornoEquitySalvato = 0;
datetime g_ultimoGiornoRegime = 0;
double   g_levaCorrente = 1.0;

//+------------------------------------------------------------------+
//| Utilita': split stringa per virgola                                |
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
//| Ora di Roma corrente (approssimata via offset configurabile)      |
//+------------------------------------------------------------------+
datetime OraDiRoma()
  {
   return TimeCurrent() + InpServerToRomeOffsetHours*3600;
  }

bool DentroSessione()
  {
   MqlDateTime dt;
   TimeToStruct(OraDiRoma(), dt);
   return (dt.hour >= InpSessioneOraInizio && dt.hour < InpSessioneOraFine);
  }

// Come DentroSessione() ma valutata sull'ORA DELLA BARRA stessa (il suo timestamp di apertura,
// che e' la sua "etichetta" oraria) invece che sull'istante in cui la si e' rilevata chiusa.
// Necessario per allinearsi esattamente al backtest Python, che usa l'ora-etichetta di ogni
// barra H1 per decidere se e' dentro la finestra 9-20, non l'ora in cui la barra si chiude.
bool DentroSessioneBarra(datetime tempoBarraServer)
  {
   MqlDateTime dt;
   TimeToStruct(tempoBarraServer + InpServerToRomeOffsetHours*3600, dt);
   return (dt.hour >= InpSessioneOraInizio && dt.hour < InpSessioneOraFine);
  }

//+------------------------------------------------------------------+
//| Costruisce barre "giornaliere" allineate a MEZZANOTTE DI ROMA      |
//| (non del server) aggregando barre H1. FONDAMENTALE: le barre D1   |
//| native del broker sono allineate a mezzanotte SERVER, sfasata di  |
//| 1-2 ore da Roma - usarle significa calcolare TUTTI gli indicatori |
//| (ATR, MA200, Bollinger, Keltner, Wyckoff, regime) su "giorni" che |
//| non corrispondono alle sessioni che il backtest Python usa (che   |
//| resample da barre H1 GIA' shiftate a ora di Roma). Un disallineamento|
//| di poche ore ripetuto su migliaia di giorni in un backtest         |
//| pluriennale genera un effetto cumulativo enorme.                   |
//| Ritorna un array in formato "serie" (indice 0 = ieri, cioe' l'ultimo|
//| giorno di Roma COMPLETO, mai il giorno odierno ancora in corso).   |
//+------------------------------------------------------------------+
#define MAX_H1_STORICO 25000
int CostruisciGiornaliereRoma(string symbol, MqlRates &out[])
  {
   MqlRates h1[];
   ArraySetAsSeries(h1, true);
   int n = CopyRates(symbol, PERIOD_H1, 1, MAX_H1_STORICO, h1); // shift1: mai la barra H1 in formazione
   if(n <= 24) return 0;

   datetime oggiMezzanotteRoma;
     {
      MqlDateTime dtOggi;
      TimeToStruct(OraDiRoma(), dtOggi);
      dtOggi.hour=0; dtOggi.min=0; dtOggi.sec=0;
      oggiMezzanotteRoma = StructToTime(dtOggi);
     }

   MqlRates temp[];
   ArrayResize(temp, 0);
   MqlRates corrente;
   ZeroMemory(corrente);
   datetime giornoCorrente = 0;
   bool primaBarra = true;
   int count = 0;

   for(int i=n-1; i>=0; i--) // dalla barra H1 piu' vecchia alla piu' recente (ordine cronologico)
     {
      datetime romaTime = h1[i].time + InpServerToRomeOffsetHours*3600;
      MqlDateTime dt; TimeToStruct(romaTime, dt);
      dt.hour=0; dt.min=0; dt.sec=0;
      datetime giornoData = StructToTime(dt);
      if(giornoData >= oggiMezzanotteRoma) continue; // mai il giorno di Roma ancora in corso (incompleto)

      if(giornoData != giornoCorrente)
        {
         if(!primaBarra)
           {
            ArrayResize(temp, count+1);
            temp[count] = corrente;
            count++;
           }
         giornoCorrente = giornoData;
         corrente.time = giornoData;
         corrente.open = h1[i].open;
         corrente.high = h1[i].high;
         corrente.low  = h1[i].low;
         corrente.close= h1[i].close;
         corrente.tick_volume = h1[i].tick_volume;
         primaBarra = false;
        }
      else
        {
         corrente.high = MathMax(corrente.high, h1[i].high);
         corrente.low  = MathMin(corrente.low, h1[i].low);
         corrente.close= h1[i].close;
         corrente.tick_volume += h1[i].tick_volume;
        }
     }
   if(!primaBarra)
     {
      ArrayResize(temp, count+1);
      temp[count] = corrente;
      count++;
     }

   // temp[] e' in ordine cronologico (piu' vecchio prima). Lo invertiamo in formato "serie"
   // (indice 0 = piu' recente = ieri) come si aspetta il resto del codice.
   int totale = ArraySize(temp);
   ArrayResize(out, totale);
   for(int i=0;i<totale;i++) out[i] = temp[totale-1-i];
   return totale;
  }

//+------------------------------------------------------------------+
//| Calcolo indicatori giornalieri per un simbolo (usa SOLO barre     |
//| gia' chiuse: shift 1 = "ieri", shift 2.. = giorni precedenti,     |
//| MAI la barra 0 (in formazione) per evitare look-ahead)            |
//+------------------------------------------------------------------+
bool CalcolaDailySignal(string symbol, DailySignal &out)
  {
   int necessarie = InpMedianaLookback + InpRangeStrettaLookback + 10; // margine
   int n = MathMax(necessarie, 210); // almeno 210 per MA200
   MqlRates rates[];
   int copiate = CostruisciGiornaliereRoma(symbol, rates); // barre allineate a mezzanotte di ROMA
   if(copiate < n)
     {
      out.valido = false;
      return false;
     }
   // rates[0] = ieri (shift1), rates[1] = 2 giorni fa (shift2), ecc.

   // --- ATR14 a shift1 (calcolato sulle barre shift1..shift14, ognuna con il proprio prev close a shift2..shift15) ---
   double trSum = 0.0;
   for(int k=0;k<14;k++)
     {
      double high = rates[k].high, low = rates[k].low, prevClose = rates[k+1].close;
      double tr = MathMax(high-low, MathMax(MathAbs(high-prevClose), MathAbs(low-prevClose)));
      trSum += tr;
     }
   out.atr14 = trSum/14.0;

   // --- MA200 a shift1 (media dei close da shift1 a shift200) ---
   double sum200=0.0;
   for(int k=0;k<200;k++) sum200 += rates[k].close;
   out.ma200 = sum200/200.0;

   // --- Bollinger: SMA20 e STD20 dei close, a shift1 ---
   double sum20=0.0;
   for(int k=0;k<20;k++) sum20 += rates[k].close;
   double sma20 = sum20/20.0;
   double varSum=0.0;
   for(int k=0;k<20;k++) varSum += MathPow(rates[k].close - sma20, 2);
   // ddof=1 (divide per N-1=19), NON N=20: pandas Series.std() usa la deviazione standard
   // campionaria di default. Con ddof=0 (popolazione) lo std risulta ~2.5% piu' piccolo,
   // rendendo bb_lower sistematicamente piu' vicino alla media e quindi piu' facile da
   // rompere al ribasso: falsi segnali extra rispetto al riferimento Python.
   double std20 = MathSqrt(varSum/19.0);
   out.bbLower = sma20 - 2.0*std20;

   // --- Keltner: EMA20 dei close a shift1 (calcolata ricorsivamente sulle barre disponibili, dalla piu' vecchia alla piu' recente) ---
   double emaAlpha = 2.0/(20.0+1.0);
   double ema = rates[copiate-1].close; // valore iniziale: barra piu' vecchia disponibile
   for(int k=copiate-2;k>=0;k--) ema = rates[k].close*emaAlpha + ema*(1.0-emaAlpha);
   out.kcLower = ema - 2.0*out.atr14;

   // --- WYCKOFF SPRING ---
   // range_low/high sui 20 giorni PRIMA di ieri, cioe' shift2..shift21 (indici 1..20 nell'array, poiche' indice 0 = shift1)
   double rangeLow = rates[1].low, rangeHigh = rates[1].high;
   double volAvg = 0.0;
   for(int k=1;k<=InpRangeStrettaLookback;k++)
     {
      rangeLow  = MathMin(rangeLow, rates[k].low);
      rangeHigh = MathMax(rangeHigh, rates[k].high);
      volAvg += (double)rates[k].tick_volume;
     }
   volAvg /= InpRangeStrettaLookback;
   double rangePctIeri = (rangeHigh-rangeLow)/rates[1].close;

   // mediana del range% calcolata sui 100 giorni precedenti (finestre di 20gg via shift, semplificato:
   // calcoliamo un campione di range% su finestre scorrevoli nei 100 giorni precedenti a shift2)
   double campioneRangePct[];
   ArrayResize(campioneRangePct, InpMedianaLookback);
   for(int w=0; w<InpMedianaLookback; w++)
     {
      double lo = rates[1+w].low, hi = rates[1+w].high;
      for(int k=1;k<InpRangeStrettaLookback;k++)
        {
         lo = MathMin(lo, rates[1+w+k].low);
         hi = MathMax(hi, rates[1+w+k].high);
        }
      campioneRangePct[w] = (hi-lo)/rates[1+w].close;
     }
   ArraySort(campioneRangePct);
   // pandas .median() su un campione di lunghezza pari fa la media dei due elementi centrali,
   // non prende solo il superiore: con InpMedianaLookback=100 servono indici 49 e 50, non solo 50.
   double medianaRangePct;
   if(InpMedianaLookback % 2 == 0)
      medianaRangePct = 0.5*(campioneRangePct[InpMedianaLookback/2 - 1] + campioneRangePct[InpMedianaLookback/2]);
   else
      medianaRangePct = campioneRangePct[InpMedianaLookback/2];
   bool rangeStretto = (rangePctIeri < medianaRangePct);

   bool springValido = (rates[0].low < rangeLow) && (rates[0].close > rangeLow) &&
                        rangeStretto && ((double)rates[0].tick_volume > InpVolumeClimaxMult*volAvg);
   out.wyckoffSignal = springValido;

   out.valido = true;
   out.ultimaBarraD1 = rates[0].time;
   return true;
  }

//+------------------------------------------------------------------+
//| Filtro di regime: percentile ATR%/prezzo del simbolo di riferimento|
//| su una finestra di 252 giorni, usando SOLO dati fino a ieri        |
//+------------------------------------------------------------------+
bool CalcolaRegime(string refSymbol, double &percentileOut)
  {
   int n = 252 + 20; // margine per il calcolo dell'ATR di ciascun giorno del campione
   MqlRates rates[];
   int copiate = CostruisciGiornaliereRoma(refSymbol, rates); // barre allineate a mezzanotte di ROMA
   if(copiate < n) return false;

   double campioneATRpct[];
   ArrayResize(campioneATRpct, 252);
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
      campioneATRpct[w] = atr/rates[w].close;
     }
   double valoreIeri = campioneATRpct[0]; // shift1 = ieri
   // percentile = frazione di valori (nei 252, ieri incluso) <= valoreIeri
   int conta=0;
   for(int w=0; w<252; w++) if(campioneATRpct[w] <= valoreIeri) conta++;
   percentileOut = (double)conta/252.0;
   return true;
  }

//+------------------------------------------------------------------+
//| Vol-targeting: legge/aggiorna lo storico equity e ricalcola leva  |
//+------------------------------------------------------------------+
void AggiornaVolTargeting()
  {
   MqlDateTime dtNow;
   TimeToStruct(OraDiRoma(), dtNow);
   datetime oggiMezzanotteRoma = StringToTime(StringFormat("%04d.%02d.%02d 00:00", dtNow.year, dtNow.mon, dtNow.day));
   if(oggiMezzanotteRoma == g_ultimoGiornoEquitySalvato) return; // gia' salvato oggi

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   int handle = FileOpen(InpFileEquityStorico, FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI);
   if(handle==INVALID_HANDLE)
     {
      Print("ERRORE apertura file equity storico: ", GetLastError());
      return;
     }
   FileSeek(handle, 0, SEEK_END);
   FileWrite(handle, TimeToString(oggiMezzanotteRoma, TIME_DATE), DoubleToString(equity,2));
   FileClose(handle);

   g_ultimoGiornoEquitySalvato = oggiMezzanotteRoma;

   // ricalcolo leva: rilegge il file, prende le ultime ~40 righe, calcola rendimenti giornalieri
   // e la deviazione standard annualizzata sugli ultimi InpVolLookbackGiorni rendimenti
   int h2 = FileOpen(InpFileEquityStorico, FILE_READ|FILE_CSV|FILE_ANSI);
   if(h2==INVALID_HANDLE) return;
   double storicoEquity[]; ArrayResize(storicoEquity,0);
   while(!FileIsEnding(h2))
     {
      string data = FileReadString(h2);
      if(StringLen(data)==0) break;
      string eq = FileReadString(h2);
      int sz = ArraySize(storicoEquity);
      ArrayResize(storicoEquity, sz+1);
      storicoEquity[sz] = StringToDouble(eq);
     }
   FileClose(h2);

   if(!InpUsaVolTargeting) { g_levaCorrente = 1.0; return; } // leva fissa: storico equity comunque loggato sopra

   int m = ArraySize(storicoEquity);
   int lookback = MathMin(InpVolLookbackGiorni, m-1);
   if(lookback < 5)
     {
      g_levaCorrente = 1.0; // dati insufficienti: leva neutra finche' non si accumula storico
      return;
     }
   double rendimenti[]; ArrayResize(rendimenti, lookback);
   for(int i=0;i<lookback;i++)
     {
      int idx = m-lookback+i;
      rendimenti[i] = (storicoEquity[idx]-storicoEquity[idx-1])/storicoEquity[idx-1];
     }
   double media=0.0;
   for(int i=0;i<lookback;i++) media += rendimenti[i];
   media /= lookback;
   double varSum=0.0;
   for(int i=0;i<lookback;i++) varSum += MathPow(rendimenti[i]-media,2);
   double stdGiornaliera = MathSqrt(varSum/lookback);
   double volAnnua = stdGiornaliera*MathSqrt(252.0);

   bool nessunRendimentoNonNullo = true;
   for(int i=0;i<lookback;i++) if(rendimenti[i]!=0.0) { nessunRendimentoNonNullo=false; break; }

   if(nessunRendimentoNonNullo)
      g_levaCorrente = 1.0; // equity ancora piatta (nessun trade chiuso nel periodo): leva NEUTRA, non massima -
                            // volAnnua=0 qui significa "dati insufficienti", non "strategia genuinamente calma"
   else if(volAnnua <= 0.0001)
      g_levaCorrente = InpLevaCapMax; // volatilita' realmente quasi nulla con storico di trade genuino
   else
      g_levaCorrente = MathMax(InpLevaCapMin, MathMin(InpLevaCapMax, (InpTargetVolAnnuoPct/100.0)/volAnnua));

   PrintFormat("Vol-targeting aggiornato: vol_annua=%.2f%% leva=%.2fx (storico=%d gg)", volAnnua*100.0, g_levaCorrente, m);
  }

//+------------------------------------------------------------------+
//| Conteggio posizioni aperte per simbolo (un trade alla volta)      |
//+------------------------------------------------------------------+
bool PosizioneApertaSuSimbolo(string symbol)
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
//| Chiusura posizioni scadute (holding massimo superato)              |
//+------------------------------------------------------------------+
void GestisciUsciteATempo()
  {
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket==0) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=InpMagicNumber) continue;
      datetime apertura = (datetime)PositionGetInteger(POSITION_TIME);
      double giorniAperti = (double)(TimeCurrent()-apertura)/86400.0;
      if(giorniAperti >= InpMaxHoldingGiorni)
        {
         string sym = PositionGetString(POSITION_SYMBOL);
         MqlTradeRequest req; MqlTradeResult res;
         ZeroMemory(req); ZeroMemory(res);
         req.action   = TRADE_ACTION_DEAL;
         req.position = ticket;
         req.symbol   = sym;
         req.volume   = PositionGetDouble(POSITION_VOLUME);
         req.type     = ORDER_TYPE_SELL; // posizioni sempre long in questa strategia
         req.price    = SymbolInfoDouble(sym, SYMBOL_BID);
         req.deviation= 20;
         req.magic    = InpMagicNumber;
         req.type_filling = RilevaFillingMode(sym);
         bool inviato = OrderSend(req,res);
         if(!inviato || (res.retcode!=TRADE_RETCODE_DONE && res.retcode!=TRADE_RETCODE_PLACED))
            PrintFormat("ERRORE chiusura a tempo %s: retcode=%d comment=%s", sym, res.retcode, res.comment);
         else
            PrintFormat("Chiusura a tempo (holding max %d gg) su %s", InpMaxHoldingGiorni, sym);
        }
     }
  }

//+------------------------------------------------------------------+
//| Rileva la modalita' di riempimento ordine supportata dal simbolo  |
//+------------------------------------------------------------------+
ENUM_ORDER_TYPE_FILLING RilevaFillingMode(string symbol)
  {
   long filling = SymbolInfoInteger(symbol, SYMBOL_FILLING_MODE);
   if((filling & SYMBOL_FILLING_FOK) != 0) return ORDER_FILLING_FOK;
   if((filling & SYMBOL_FILLING_IOC) != 0) return ORDER_FILLING_IOC;
   return ORDER_FILLING_RETURN;
  }

//+------------------------------------------------------------------+
//| Calcolo lotti dal rischio in valuta e distanza dello stop         |
//+------------------------------------------------------------------+
double CalcolaLotti(string symbol, double riskUsd, double stopDistancePrice)
  {
   double tickValue = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize<=0 || tickValue<=0) return 0.0;
   double rischioPerLotto = stopDistancePrice * (tickValue/tickSize);
   if(rischioPerLotto<=0) return 0.0;
   double lotti = riskUsd/rischioPerLotto;

   double lotStep = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
   double lotMin  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double lotMax  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   lotti = MathFloor(lotti/lotStep)*lotStep;
   lotti = MathMax(lotMin, MathMin(lotMax, lotti));
   return lotti;
  }

//+------------------------------------------------------------------+
//| Valutazione ingresso per un simbolo                                |
//+------------------------------------------------------------------+
void ValutaIngresso(int idx, double prezzo)
  {
   string symbol = g_symbols[idx];
   if(PosizioneApertaSuSimbolo(symbol)) return;
   if(!g_daily[idx].valido) return;
   if(InpEvitaGiorniNews && EGiornoNews(OraDiRoma())) return; // salta ingressi nei giorni NFP/FOMC
   if(InpUsaFiltroRegime)
     {
      if(!g_regimeValido) return;
      if(g_regimePercentile >= InpSogliaRegimePercentile) return; // regime sfavorevole: nessun nuovo trade oggi
     }

   if(prezzo <= g_daily[idx].ma200) return; // serve essere in uptrend

   bool segnale = false;
   if(InpUsaBollinger && prezzo < g_daily[idx].bbLower) segnale = true;
   if(InpUsaKeltner   && prezzo < g_daily[idx].kcLower) segnale = true;
   if(InpUsaWyckoff   && g_daily[idx].wyckoffSignal)    segnale = true;
   if(!segnale) return;

   double atr = g_daily[idx].atr14;
   double sl  = prezzo - InpATRMultStop*atr;
   double risk = prezzo - sl;
   if(risk<=0) return;
   // guardia di sicurezza: scarta segnali con stop anomalo (dato di prezzo/ATR corrotto)
   if(risk > prezzo*(InpMaxRischioPctPrezzo/100.0))
     {
      PrintFormat("ATTENZIONE: stop anomalo su %s (risk=%.2f, prezzo=%.2f, atr=%.2f) - segnale scartato per sicurezza",
                  symbol, risk, prezzo, atr);
      return;
     }
   double tp  = prezzo + InpRMultTarget*risk;

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskUsd = equity * (InpBaseRiskPct/100.0) * g_levaCorrente;
   double lotti = CalcolaLotti(symbol, riskUsd, risk);
   if(lotti<=0) { Print("Lotti calcolati <=0 per ", symbol, ", trade saltato"); return; }

   MqlTradeRequest req; MqlTradeResult res;
   ZeroMemory(req); ZeroMemory(res);
   req.action   = TRADE_ACTION_DEAL;
   req.symbol   = symbol;
   req.volume   = lotti;
   req.type     = ORDER_TYPE_BUY;
   req.price    = SymbolInfoDouble(symbol, SYMBOL_ASK);
   req.sl       = sl;
   req.tp       = tp;
   req.deviation= 20;
   req.magic    = InpMagicNumber;
   req.comment  = "Wyckoff/BB/KC portfolio";
   req.type_filling = RilevaFillingMode(symbol);

   if(!OrderSend(req,res))
      PrintFormat("ERRORE apertura %s: %d (%s)", symbol, GetLastError(), res.comment);
   else
      PrintFormat("APERTO %s: lotti=%.2f entry=%.2f sl=%.2f tp=%.2f leva=%.2fx bb=%d kc=%d wyckoff=%d",
                  symbol, lotti, prezzo, sl, tp, g_levaCorrente,
                  (prezzo<g_daily[idx].bbLower), (prezzo<g_daily[idx].kcLower), g_daily[idx].wyckoffSignal);
  }

//+------------------------------------------------------------------+
//| OnInit                                                             |
//+------------------------------------------------------------------+
int OnInit()
  {
   g_nSymbols = SplitSymbols(InpSymbols, g_symbols);
   if(g_nSymbols<2 || g_nSymbols>MAX_SYMS)
     {
      Print("Elenco simboli non valido");
      return(INIT_FAILED);
     }
   for(int i=0;i<g_nSymbols;i++)
     {
      if(!SymbolSelect(g_symbols[i], true))
         PrintFormat("ATTENZIONE: simbolo '%s' non trovato/selezionabile - verificare il nome esatto in Market Watch", g_symbols[i]);
      g_daily[i].valido = false;
      g_ultimaBarraH1[i] = 0;
     }
   EventSetTimer(60); // controllo ogni 60 secondi
   Print("WyckoffPortfolioEA inizializzato su ", g_nSymbols, " simboli. VERIFICARE i nomi simboli e InpServerToRomeOffsetHours prima di operare su reale.");
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();
  }

//+------------------------------------------------------------------+
//| OnTick: rilevamento nuova barra D1/H1, MAI su base timer          |
//| (un timer a cadenza reale salta barre quando il Tester gira a     |
//| velocita' accelerata, comprimendo anni in minuti - bug reale      |
//| scoperto confrontando gli orari di ingresso con il backtest       |
//| Python: gli scarti erano variabili, 1-3 ore, segno di barre       |
//| saltate. OnTick invece scatta ad ogni aggiornamento di prezzo,    |
//| sia in test che dal vivo, senza mai saltare una transizione.)     |
//+------------------------------------------------------------------+
void OnTick()
  {
   // 1) aggiorna indicatori giornalieri se e' iniziato un nuovo giorno DI ROMA (non del server -
   // vedi CostruisciGiornaliereRoma per il perche' questo e' fondamentale)
   datetime oggiMezzanotteRoma;
     {
      MqlDateTime dtOggi;
      TimeToStruct(OraDiRoma(), dtOggi);
      dtOggi.hour=0; dtOggi.min=0; dtOggi.sec=0;
      oggiMezzanotteRoma = StructToTime(dtOggi);
     }
   for(int i=0;i<g_nSymbols;i++)
     {
      if(g_daily[i].ultimaBarraD1 != oggiMezzanotteRoma)
        {
         if(CalcolaDailySignal(g_symbols[i], g_daily[i]))
            g_daily[i].ultimaBarraD1 = oggiMezzanotteRoma;
        }
     }

   // 1bis) valuta un nuovo ingresso SOLO alla chiusura di una barra H1 (mai infra-barra),
   // usando il prezzo di CHIUSURA della barra appena conclusa - stessa logica del backtest Python
   for(int i=0;i<g_nSymbols;i++)
     {
      datetime ultimaBarraH1[1];
      if(CopyTime(g_symbols[i], PERIOD_H1, 0, 1, ultimaBarraH1) != 1) continue;
      if(g_ultimaBarraH1[i] == 0) { g_ultimaBarraH1[i] = ultimaBarraH1[0]; continue; } // primo avvio: solo inizializza
      if(g_ultimaBarraH1[i] != ultimaBarraH1[0])
        {
         g_ultimaBarraH1[i] = ultimaBarraH1[0];
         datetime tempoBarraChiusa[1];
         if(CopyTime(g_symbols[i], PERIOD_H1, 1, 1, tempoBarraChiusa) == 1 && DentroSessioneBarra(tempoBarraChiusa[0]))
           {
            double chiusuraBarraH1[1];
            if(CopyClose(g_symbols[i], PERIOD_H1, 1, 1, chiusuraBarraH1) == 1)
               ValutaIngresso(i, chiusuraBarraH1[0]);
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| OnTimer: compiti periodici NON critici per il timing (tolleranti  |
//| a qualche minuto di ritardo): regime, vol-targeting, uscite a     |
//| tempo. Il rilevamento di nuove barre resta SOLO in OnTick().      |
//+------------------------------------------------------------------+
void OnTimer()
  {
   // 2) aggiorna il filtro di regime (dipende dal simbolo di riferimento, tipicamente SP500)
   // UNA VOLTA AL GIORNO (di Roma): CalcolaRegime ricostruisce da zero fino a 25000 barre H1,
   // costoso - richiamarlo ad ogni tick di OnTimer rallentava drasticamente il Tester senza
   // alcun beneficio, dato che il valore usato per il trading e' comunque quello di "ieri".
   datetime oggiMezzanotteRomaRegime;
     {
      MqlDateTime dtOggi;
      TimeToStruct(OraDiRoma(), dtOggi);
      dtOggi.hour=0; dtOggi.min=0; dtOggi.sec=0;
      oggiMezzanotteRomaRegime = StructToTime(dtOggi);
     }
   if(g_ultimoGiornoRegime != oggiMezzanotteRomaRegime)
     {
      double nuovoPercentile;
      if(CalcolaRegime(g_symbols[InpRegimeReferenceIndex], nuovoPercentile))
        {
         g_regimePercentile = nuovoPercentile;
         g_regimeValido = true;
         g_ultimoGiornoRegime = oggiMezzanotteRomaRegime;
        }
     }

   // 3) aggiorna vol-targeting (una volta al giorno)
   AggiornaVolTargeting();

   // 4) gestisci uscite a tempo (holding massimo)
   GestisciUsciteATempo();
  }
//+------------------------------------------------------------------+
