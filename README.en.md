# Payment Reconciliation with SQL

[Português](README.md) · **English**

A SQL and Python pipeline that reconciles what a platform's internal system recorded against what two payment providers settled. It finds the discrepancies, sizes their impact in Brazilian reais (BRL), assigns who needs to act and measures its own accuracy against an answer key.

**Result:** 125 discrepancies across 8 categories, BRL 21,294.81 in impact, two incidents identified and **100% precision and recall**, including on a brand-new dataset, without changing a single query.

---

## The problem

A fictional online platform takes deposits and pays out withdrawals through two providers, also fictional: **PagaJá** and **LiquidaPay**. October 2026 has closed, and finance needs to know whether the internal records match what the providers settled.

The three sources don't speak the same language:

| Source | Format |
| --- | --- |
| Internal records | 6,000 transactions; timestamps in Brasília time |
| PagaJá statement | 3,021 rows; `;` separator, comma decimals with dot thousands, `dd/mm/yyyy` dates, ids without the hyphen and in lowercase |
| LiquidaPay statement | 2,407 rows; in English, timestamps in **UTC**, ids with stray spaces and mixed case |
| Contract | Fee (percentage + fixed) and settlement deadline per provider, method and type |

The deliverable is a **discrepancy report**: what doesn't match, why, how much it is worth and who needs to act, the provider or the internal team.

## Why the data is synthetic

Transaction data, provider statements and contracted fees are confidential and protected by Brazil's data protection law (LGPD). There is no public payment reconciliation dataset, and using real data would be neither possible nor appropriate.

So the data comes from a Python generator (`src/gerar_dados.py`) that reproduces problems that show up in real payment operations: different layouts per provider, time zones, a wrong fee charged over a window of days, duplicated entries, refunds that never reach the internal system. The scenarios come from my experience in the field; no company data was used.

The generator also plants **traps**, cases that look like errors but aren't, and writes an **answer key**. That makes it possible to measure the pipeline's accuracy, which real data would not allow.

## Architecture

```
CSV  →  raw  →  staging  →  matching  →  validations  →  report  →  scoring
```

| Step | File | What it does |
| --- | --- | --- |
| 0. Load | `sql/00_ddl_raw.sql`, `src/carregar_dados.py` | Creates the `raw_*` tables with every column as text and loads the CSVs with no transformation |
| 1. Profiling | `sql/01_perfil.sql` | Exploration before reconciling: volumes, periods, distributions, formats, dirty ids, time zone effects |
| 2. Staging | `sql/02_staging.sql` | `stg_*` views: proper types, standardized ids, time zone converted to Brasília, both statements in one (`UNION ALL`) |
| 3. Matching | `sql/03_casamento.sql` | Removes duplicates, defines what should be in the statement and matches the sources (`FULL OUTER JOIN`) |
| 4. Validations | `sql/04_validacoes.sql` | Amount, status, refunds, fee vs. contract and deadline; merges everything into a single findings list |
| 5. Report | `sql/05_relatorio.sql` | `divergencias` table, summary, owner and risk per category, daily series with running totals and incidents |
| 6. Scoring | `sql/06_conferencia.sql` | Compares against the answer key: precision and recall per category |
| Orchestration | `src/pipeline.py` | Runs everything in order and exports the report to `saida/` |

The raw layer keeps the files exactly as they arrived. All cleaning lives in staging, written in SQL and version-controlled, so every finding can be traced back to the provider's original row.

## Key findings

**125 discrepancies across 8 categories:**

| Category | Findings | Impact (BRL) | Who acts | Risk |
| --- | --- | --- | --- | --- |
| Duplicate entry | 10 | 4,693.24 | Provider | Financial |
| Missing from internal records | 8 | 4,704.20 | Investigate | Customer |
| Late settlement | 11 | 4,178.43 | Provider | Cash flow |
| Status mismatch | 10 | 3,467.21 | Internal | Customer |
| Missing from statement | 12 | 2,545.06 | Provider | Financial |
| Unrecorded refund | 7 | 1,308.32 | Internal | Financial |
| Amount mismatch | 9 | 289.29 | Provider | Financial |
| Wrong fee | 58 | 109.06 | Provider | Financial |
| **Total** | **125** | **21,294.81** | | |

**Counting findings is misleading.** LiquidaPay has 82 findings (BRL 4,148.64) and PagaJá 43 (BRL 17,146.17): twice the occurrences, a quarter of the impact. Prioritizing by count would send the team after the wrong provider.

**Two incidents, not isolated cases:**

1. **Wrong fee at LiquidaPay (cards):** 58 transactions between Oct 15 and 18, all charged above the contract. The amount is small (BRL 109.06), but the pattern points to a misconfigured fee at the provider. The incident barely shows in the **amount** series; in the **count** series, the running total jumps from 19 to 77 in four days.
2. **Duplicates at PagaJá:** 10 repeated entries, all settled on Oct 22. It is the largest impact of any category (BRL 4,693.24), and a single settlement date suggests a batch processed twice.

The remaining categories are spread across the month and both providers: one-off failures, handled case by case.

### Traps that didn't become false alarms

| Trap | Size | How it was handled |
| --- | --- | --- |
| End-of-month transactions that only settle in November | 95 | Excluded from what is expected: the statement ends on Oct 31. Without this rule they would show up as "missing" |
| BRL 0.01 fee differences from rounding | 776 | BRL 0.01 tolerance, as the contract allows |
| Entries that change date when converted from UTC to Brasília | 517 | Time zone converted in staging, before any date comparison |
| Refunds sharing the original entry's id | 175 | Entry type is part of the duplicate definition |
| Ids with stray spaces or the wrong case | 272 | `TRIM` + `UPPER` in staging |
| Amounts with dot thousands and comma decimals | 150 | Remove the dot before swapping the comma |

## Validation

The generator writes an answer key with every planted discrepancy. Step 6 compares the pipeline's output against it, row by row, on **transaction + category**: finding the right transaction with the wrong diagnosis doesn't count as a hit.

| Dataset | Findings | Precision | Recall |
| --- | --- | --- | --- |
| Original (seed 42) | 125 | 100% | 100% |
| New, generated with `--seed 7`, **without changing any query** | 123 | 100% | 100% |

The BRL impact of all 125 findings also matches the answer key.

Seed 7 shows that the rules follow business logic rather than quirks of the original data: the errors land on different transactions, days and amounts. The limit of the test: both datasets come from the same generator, with the same error types. A new type of error would need a new validation (see "Next steps").

## SQL techniques

| Technique | Where | Why |
| --- | --- | --- |
| Chained CTEs | Steps 3 to 6 | Each step of the logic gets its own name, no nested subqueries |
| `ROW_NUMBER()` | `03_casamento.sql` | Keep the first occurrence of each entry and isolate the repeats |
| `COUNT(*) OVER (PARTITION BY ...)` | `03_casamento.sql` | Keep how many times an entry appeared, even after deduplicating |
| `LAG()` with a `WINDOW` clause | `04_validacoes.sql` | Look at each transaction's previous entry and check the refund sequence |
| `SUM() OVER (PARTITION BY ... ORDER BY ...)` | `05_relatorio.sql` | Running impact and count over the month, per provider |
| `FULL OUTER JOIN` | Steps 3 and 6 | Find what exists on one side only (internal vs. statement; pipeline vs. answer key) |
| `generate_series` + `CROSS JOIN` | `05_relatorio.sql` | A series with every day of the month, including days with no findings |
| `GROUPING SETS` and `ROLLUP` | Steps 1 and 6 | Several aggregations in one query; subtotals and totals |
| `COUNT(*) FILTER (WHERE ...)` | Throughout | Conditional counts in a single pass |
| `AT TIME ZONE` and `TO_DATE` with a mask | `02_staging.sql` | Explicit time zone and date conversion, independent of server settings |
| `INSERT ... SELECT` with a composite key | `05_relatorio.sql` | The report as a snapshot of the close, one row per transaction and category |

## How to run

**Requirements:** Python 3.11 or later and PostgreSQL 14 or later.

1. Clone the repository and install the dependencies (ideally in a virtual environment):
   ```bash
   python -m venv .venv
   pip install -r requirements.txt
   ```
2. Create the database in PostgreSQL:
   ```sql
   CREATE DATABASE conciliacao;
   ```
3. Create a `.env` file in the project root (it is not committed):
   ```
   PG_USER=postgres
   PG_PASSWORD=your_password
   PG_HOST=localhost
   PG_PORT=5432
   PG_DB=conciliacao
   ```
4. Run the pipeline:
   ```bash
   python src/pipeline.py
   ```

Expected output at the end: `125 achados | precisão 100.0% | recall 100.0%`. The report is written to `saida/`: `divergencias.csv`, `resumo.csv` and `relatorio_conciliacao.xlsx`.

**To test on another dataset:**
```bash
python src/gerar_dados.py --seed 7
python src/pipeline.py
python src/gerar_dados.py          # back to the original dataset (seed 42)
```

## Repository structure

```
├── dados/             input CSVs (generated by src/gerar_dados.py)
├── gabarito/          planted discrepancies, used only in step 6
├── sql/               00_ddl_raw.sql to 06_conferencia.sql
├── src/
│   ├── gerar_dados.py     synthetic data generator
│   ├── carregar_dados.py  loads the CSVs into the raw tables
│   └── pipeline.py        runs everything and exports the report
├── saida/             report produced by the pipeline
├── DESAFIO.md         full project brief (in Portuguese)
└── requirements.txt
```

Code, table names and comments are in Portuguese, matching the business context of the project.

## Next steps

- **A new error type in the generator** (chargeback or partial settlement), to test the pipeline against a problem it doesn't know yet and build the matching validation.
- **Natural-language questions:** an agent that answers questions in Portuguese about the reconciliation database, with read-only SQL and answers checked against known queries.
- **JSON webhooks:** each transaction's status history, extracted with SQL.

---

Built by **Pedro Freixo** · [GitHub](https://github.com/freixopedro23)
