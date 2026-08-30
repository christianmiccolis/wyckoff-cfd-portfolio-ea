# Wyckoff CFD Portfolio Strategy

*Christian Miccolis — Beriv Consulting*

EA per MetaTrader 5 e riferimento Python per una strategia mean-reversion (Bollinger Bands + Keltner Channels + Wyckoff Spring) su un paniere di 7 indici CFD (SP500, NASDAQ100, DOWJONES, DAX40, CAC40, NIKKEI225, EUROSTOXX50), con filtro di regime, filtro news macro (NFP/FOMC) e vol-targeting opzionale.

## Performance

Validata sia sul riferimento Python sia su backtest nativo MetaTrader 5 (Strategy Tester), con numeri riconciliati tra le due fonti.

**MT5 nativo, storico completo 2012-2026** (leva fissa, rischio 1,34%/trade):

| | Con filtro news (NFP+FOMC) | Senza filtro |
|---|---|---|
| Rendimento totale | **+156,7%** | +122,9% |
| Profit Factor | **1,40** | 1,30 |
| Sharpe | **1,12** | 0,92 |
| Max Drawdown (equità) | **-25,5%** | -29,4% |
| Win rate | 52,4% | 51,4% |

**Riferimento Python, periodo di validazione 2020-2026:**

| | Con filtro news | Senza filtro |
|---|---|---|
| CAGR | **16,1%/anno** | 15,5%/anno |
| Max Drawdown | **-15,6%** | -19,0% |

Il filtro news (NFP+FOMC) migliora ogni metrica rispetto a non averlo, a parità di tutto il resto — è attivo di default nell'EA.

Questo repository documenta metodo e risultati con rigore — doppia validazione Python/MT5, bug reali trovati e corretti durante lo sviluppo, calendario news da fonti ufficiali. Nessuna garanzia di profittabilità futura.

## Cosa c'è dentro

```
mql5/
  WyckoffPortfolioEA.mq5      Expert Advisor per MetaTrader 5 (portafoglio 7 simboli)
python/
  backtest_reference.py       Riferimento Python indipendente (stessa logica di segnale)
```

### L'EA (`mql5/WyckoffPortfolioEA.mq5`)

- Segnale: prezzo sotto la banda di Bollinger (20, 2σ) O sotto il canale di Keltner (EMA20 ± 2×ATR14) O uno "spring" in stile Wyckoff, sempre con prezzo sopra la MA200 (solo long, solo in uptrend)
- Filtro di regime: nessun nuovo trade quando la volatilità (percentile ATR%/prezzo a 252 giorni del simbolo di riferimento) è sopra la soglia storica del 50°
- Filtro news: nessun nuovo ingresso nei giorni di rilascio NFP o riunione FOMC (293 date 2012-2026, fonti ufficiali BLS/Federal Reserve — validato: migliora CAGR e riduce il drawdown rispetto a non avere il filtro)
- Uscita: stop a 1,5×ATR, target 1,5R, oppure chiusura a tempo dopo 15 giorni di holding massimo
- Position sizing: rischio fisso 1,34% dell'equity per trade, con vol-targeting dinamico opzionale (leva 0,4x-3x calibrata sulla volatilità realizzata dell'equity)

**Prima di usarlo**: leggi i commenti in testa al file — documentano bug reali trovati durante lo sviluppo (modalità di riempimento ordini, offset orario Tester vs live, guardie contro dati anomali) e la raccomandazione di verificare l'offset orario dal vivo prima di operare su un conto reale.

### Il riferimento Python (`python/backtest_reference.py`)

Backtest indipendente sulla stessa logica di segnale, usato per validare l'EA (i due, alla fine del lavoro, convergono entro un margine ragionevole su trade totali e rendimento). Richiede dati storici H1 per i 7 indici in una cartella `data/` (non inclusi in questo repository — vedi sotto).

```bash
pip install pandas numpy
python python/backtest_reference.py nfpfomc   # con filtro news (consigliato)
python python/backtest_reference.py none      # senza filtro, per confronto
```

## Dati necessari (non inclusi)

Lo storico usato per lo sviluppo è H1 2012-2026 per i 7 indici, originariamente da Dukascopy. Non è incluso in questo repository (dimensione, licenza dei dati). Per riprodurre i risultati serve un CSV per simbolo in `python/data/{SIMBOLO}_H1.csv` con colonne `timestamp,open,high,low,close,volume` (timestamp UTC).

Per l'EA, gli stessi dati vanno importati in MT5 come **simboli custom** (`CustomSymbolCreate` + `CustomRatesUpdate`) — i simboli reali della maggior parte dei broker non hanno storico sufficientemente lungo, e gli spread live variano troppo da broker a broker per un confronto pulito. Con simboli custom, imposta `InpServerToRomeOffsetHours = 0` (i timestamp del CSV sono già in ora di Roma); con simboli reali del tuo broker, ricalibra l'offset dal vivo come spiegato nei commenti dell'EA.

## Metodologia

- **Spread**: assunzioni fisse per simbolo (SP500 0,90 punti, NASDAQ100 0,70, DOWJONES 0,80, DAX40 0,80, CAC40 1,04 punti — confermati da un conto reale; NIKKEI225 15,0 e EUROSTOXX50 2,0 restano stime prudenti mai confermate)
- **Filtro news**: testato anche un set esteso (+CPI, +PCE, +GDP, +Jackson Hole, +testimonianza semestrale Fed) — *peggiora* i risultati (blocca troppi giorni e toglie edge a una strategia mean-reversion, che cattura proprio i rimbalzi dopo gli eccessi di prezzo che quegli eventi spesso generano). Il filtro attivo di default usa solo NFP+FOMC.
- **Validazione**: risultati confrontati sia sul riferimento Python sia su backtest nativo MetaTrader 5 (Strategy Tester, modello OHLC a 1 minuto), con numeri riconciliati tra le due fonti.

## Limitazioni note

- Nessun costo di slippage oltre allo spread fisso assunto
- Spread di NIKKEI225 ed EUROSTOXX50 mai confermati su un conto reale
- Il vol-targeting dinamico non è stato testato in combinazione con il filtro news
- Backtest, non trading live: nessuna garanzia che il comportamento futuro replichi quello storico

## Licenza

MIT — vedi [LICENSE](LICENSE). Codice fornito a scopo di ricerca/didattico, nessuna garanzia di profittabilità.
