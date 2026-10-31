# Project Brief: Customer 360 Data Cleaning

## Background
A company stores its customer data across five separate exports (CRM, product catalog, orders, support tickets and website clickstream). The data is messy: duplicated customer profiles, inconsistent formats, placeholder values, invalid numbers and broken links between tables. It cannot be used for reporting or analysis in its current state.

## Objective
Clean **all records** (no sampling) in all five tables and deliver analysis-ready Excel files, together with a report that proves what was fixed.

## Source Data (`raw_data/`, read-only)
| Table | File | Rows | Columns |
|---|---|---:|---:|
| Customers | `crm_50000_customers_dirty_v3.csv` | 50,000 | 14 |
| Products | `product_catalog_dirty_30pct.csv` | 500 | 4 |
| Orders | `orders_300k_dirty.csv` | 300,000 | 8 |
| Support tickets | `support_tickets_30000_dirty.csv` | 30,000 | 8 |
| Clickstream | `clickstream_500k_events.csv` | 500,000 | 8 |

Source: Kaggle "Customer 360" by vinaykandimalla (CC0, synthetic data).

> **Note:** On GitHub the raw CSVs are stored as `raw_data/raw_data.zip`, because GitHub rejects files over 100 MB (`clickstream_500k_events.csv` is 121.8 MB). Extract the zip inside `raw_data/` before running the notebooks.

## Scope of Work
| # | Task | Table | Tools |
|---|---|---|---|
| 1 | Profile every table and log all data-quality issues | All | pandas |
| 2 | Clean names, email, phone, dates and locations; merge duplicate profiles into one golden record | Customers | pandas |
| 3 | Clean product names, categories and prices using Power Query and formulas | Products | Excel, Power Query |
| 4 | Fix amounts, quantities, dates, payment methods and status; detect outliers; flag orphan records | Orders | pandas, NumPy |
| 5 | Fix timestamps, URLs and event types; remove duplicate events; process the full file in chunks | Clickstream | pandas |
| 6 | Clean tickets in SQL and check relationships across all tables | Tickets | SQL |
| 7 | Validate the results and report before vs after | All | pandas, matplotlib |

## Rules
- Raw files are never modified.
- Measure first, then clean.
- Never guess a value. Uncertain records are flagged, not invented.
- Every fix must be traceable to the issue log.
- Full data only, no sampling.

## Deliverables (`03_clean_data_and_report/`)
- `data_cleaning_report.xlsx`: one report with a guide to every file, summary, before vs after validity, every issue and how it was handled, integrity checks, data dictionary and charts
- `clean_data/`: one clean `.xlsx` per table; records that need review and value mappings are sheets inside the same workbook
- `clean_data/csv/`: the same clean data as UTF-8 CSV
- `clean_data/database/`: the clean data as a PostgreSQL database dump

Detailed working logs (issue log, fix log per milestone, charts) stay in each milestone folder under `02_process/<milestone>/output/`.

## Schedule
| Milestone | Work | Folder in `02_process/` |
|---|---|---|
| M1 | Data profiling and issue log | `01_profiling-pandas` |
| M2 | Customers cleaning | `02_cleaning_customers-pandas` |
| M3 | Products cleaning | `03_cleaning_products-excel_powerquery` |
| M4 | Orders cleaning | `04_cleaning_orders-pandas_numpy` |
| M5 | Clickstream cleaning | `05_cleaning_clickstream-pandas` |
| M6 | Tickets cleaning, integrity checks and clean database | `06_cleaning_tickets-sql` |
| M7 | Validation and final report | `07_validation_report-pandas_matplotlib` |
