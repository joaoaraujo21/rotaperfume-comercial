# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

---

## Databricks Setup (READ FIRST)

**Always invoke the `databricks:databricks-core` skill before any Databricks operations.**

It handles CLI authentication, profile selection, and the bundle deployment workflow. Without it, operations may be slower and less accurate.

Load it via: `/skill databricks:databricks-core`

---

## Project Overview

This repository hosts **two related Databricks projects** for the "rotaperfume" data engineering course:

1. **`rotaperfume/`** — A **Databricks Asset Bundle (DAB)** implementing a medallion architecture (bronze/silver/gold) and ML layer. A progressive series of six lessons extends the same bundle.
2. **`rotaperfume-direcao/`** — A **Databricks App** (AppKit, React + TypeScript + Express) that consumes the gold layer. The "director dashboard" for the call queue.

**Top-level layout:**
- `rotaperfume/` — Bundle (databricks.yml, resources/, src/, scripts/, tests/)
- `rotaperfume-direcao/` — AppKit app (client/, server/, shared/, databricks.yml, app.yaml)
- `dados/` — Source CSVs (ERP + CRM, ~14 MB, 10 files, 313,551 rows)
- `.llm/` — Course lesson prompts (source of truth for what each lesson should accomplish)
- `Documentação/` — Portuguese documentation per lesson (Documento_01_Catalogo.md through Documento_09_Genie_da_Direcao.md)

### Course Lesson Prompts
The pipeline project is a progressive course. Each lesson extends the bundle — read the matching prompt before deploying:
1. `prompt_01.md` — Catalog setup
2. `prompt_02.md` — Bronze layer (raw → bronze)
3. `prompt_03.md` — Silver layer (cleaning, deduplication)
4. `prompt_04.md` — Gold layer (dimensions, facts, marts)
5. `prompt_05.md` — ML features + model + queue

---

## Architecture

### Medallion Layers (in `rotaperfume/`)
```
lakehouse_rotaperfume (catalog)
├── bronze (schema)     — Raw files, byte-for-byte as arrived
│   └── raw (Volume)    — CSV landing zone (erp/, crm/ subfolders)
├── silver (schema)     — Cleaned, deduplicated, conformed
└── gold (schema)       — Business metrics, star schema, ML features, call queue
```

### Bundle Configuration (`rotaperfume/databricks.yml`)
- **Bundle name**: `rotaperfume`
- **Variables**: `catalog` (default: `lakehouse_rotaperfume`), `warehouse_id` (default: `5e190bf1956452bc`)
- **Targets**: `dev` (default, paused) and `prod`

### Pipeline Job (`rotaperfume/resources/pipeline.job.yml`)
- **Job**: `rotaperfume_pipeline`
- **Schedule**: Daily 6:00 AM, `America/Sao_Paulo`
- **Compute**: Serverless (no cluster config — Free Edition constraint)
- **Tasks**: `raw_conferencia` → `bronze` → `silver` (4 parallel) → `gold` (3 serial) → `testes` → `ml_features` → `ml_modelo` → `ml_fila`

### Companion App (`rotaperfume-direcao/`)
- **AppKit app**: `rotaperfume-direcao` — React/TypeScript frontend + Express server
- **Resources**: SQL Warehouse (`5e190bf1956452bc`) + Genie Space `01f1a40c17651d788e1d5fab9c7f09ec`
- **Deploy**: `databricks apps deploy` (see `rotaperfume-direcao/README.md`)

### Data (10 CSV files in `dados/`)
| ERP | CRM |
|-----|-----|
| produtos, pedidos, itens_pedido, pagamentos, estoque | clientes, vendedores, carteira, oportunidades, visitas |

### ML Layer (Lesson 5)
- `src/ml/11-features.py` — Feature engineering (churn prediction, value ranking)
- `src/ml/12-modelo.py` — Model training (classification + regression)
- `src/ml/13-fila.sql` — Inference queue table (`gold.fila_semanal`, top 200)
- **CRITICAL**: `src/ml/` is gitignored. `databricks.yml` has `sync.include: src/ml/**` to keep it deployed.

### Resources Deployed (`rotaperfume/resources/`)
- `catalogo.yml` — Catalog/schemas/volumes
- `pipeline.job.yml` — The 13+ task pipeline job
- `dashboard.dashboard.yml` + `dashboard-comercial.lvdash.json` — AI/BI dashboard
- `genie_comercial.geniespace.json` — Genie Space for sales team
- `direcao.geniespace.json` — Genie Space for directors (the one used by `rotaperfume-direcao`)

---

## Common Commands

### Pipeline (rotaperfume)
```bash
cd rotaperfume

# Bundle operations (always pass --profile)
databricks bundle validate --target dev --profile joaogui21@hotmail.com
databricks bundle deploy   --target dev --profile joaogui21@hotmail.com
databricks bundle run     rotaperfume_pipeline --target dev --profile joaogui21@hotmail.com

# Run a single task in isolation (~35s vs ~3m30 for full job)
bash scripts/rodar-tarefa.sh joaogui21@hotmail.com <task_key>
# e.g. bash scripts/rodar-tarefa.sh joaogui21@hotmail.com ml_features
```

### App (rotaperfume-direcao)
```bash
cd rotaperfume-direcao

npm install                    # one-time
npm run dev                    # local dev (Vite + tsx watch)
npm run build                  # production build (client + server)
npm run typecheck              # tsc on both projects
npm run lint                   # eslint
npm run format                 # prettier --check
npm run test                   # vitest

# Deploy
databricks apps deploy                              # dev/default
databricks apps deploy -t prod                      # production
databricks apps start rotaperfume-direcao           # restart after inactivity
```

### Local Python tests (requires uv + Databricks Connect)
```bash
cd rotaperfume
uv sync --dev
uv run pytest -v           # Uses Databricks Connect (auto-enables serverless fallback)
uv run pytest -v tests/    # Run specific test file
uv run ruff check .
uv run ruff format .

# Databricks Connect version: databricks-connect>=15.4,<15.5 (see pyproject.toml)
```

---

## Development Workflow

### First-Time Pipeline Deploy (CRITICAL ORDER)

```bash
cd rotaperfume

# 1. Create catalog (Free Edition workaround — API rejects CREATE CATALOG)
bash scripts/criar-catalogo.sh joaogui21@hotmail.com

# 2. Validate + deploy schemas, volumes, job
databricks bundle deploy --target dev --profile joaogui21@hotmail.com

# 3. Upload CSVs to Volume (Volume must exist first)
bash scripts/subir-raw.sh joaogui21@hotmail.com

# 4. Run pipeline
databricks bundle run rotaperfume_pipeline --target dev --profile joaogui21@hotmail.com
```

### Subsequent Iterations

```bash
cd rotaperfume
databricks bundle deploy --target dev --profile joaogui21@hotmail.com
databricks bundle run rotaperfume_pipeline --target dev --profile joaogui21@hotmail.com
```

### Verification Queries

```sql
-- Check schemas exist
SHOW SCHEMAS IN lakehouse_rotaperfume;

-- Check raw files in Volume
LIST '/Volumes/lakehouse_rotaperfume/bronze/raw/erp';
LIST '/Volumes/lakehouse_rotaperfume/bronze/raw/crm';

-- Audit table (populated by raw_conferencia)
SELECT sistema, arquivo, bytes, linhas, conferido_em
FROM lakehouse_rotaperfume.bronze._raw_arquivos
ORDER BY linhas DESC;

-- Summary stats
SELECT COUNT(*) AS arquivos, SUM(linhas) AS linhas,
       ROUND(SUM(bytes)/1024/1024, 1) AS mb
FROM lakehouse_rotaperfume.bronze._raw_arquivos;
-- Expected: 10 files, 313,551 rows, ~14.7 MB

-- Call queue (top 200 from ML scoring)
SELECT vendedor, ordem, cliente, score, faixa, motivo, sugestao
FROM lakehouse_rotaperfume.gold.fila_semanal
ORDER BY score DESC;
```

---

## Environment & Authentication

### Profiles (`.databrickscfg`)
- `joaogui21@hotmail.com` — **Active workspace.** Host: `https://dbc-320fbd50-0c3f.cloud.databricks.com`. Use this for all operations.

### Free Edition Constraints
- Everything runs **serverless** — no `new_cluster` config in any task
- API cannot create catalog (requires MANAGED LOCATION) — use `scripts/criar-catalogo.sh` via SQL instead
- **CRITICAL**: `src/ml/` is gitignored — bundle deploys via `sync.include: src/ml/**` in databricks.yml
  - If ML tasks fail with "Unable to access the notebook", verify the sync pattern is present

### Node Version (for `rotaperfume-direcao`)
The appkit bundler uses `styleText` from `node:util`, which requires Node 20.12+; this project uses Node 24.

---

## Key Patterns

### Widget Parameters
Every notebook task must declare the widget **before** calling `get()`:
```python
dbutils.widgets.text("catalog", "", "Catalogo Unity Catalog")
catalog = dbutils.widgets.get("catalog")
```

### Volume File Access (Python Notebooks)
Spark serverless cannot access local files — **never use `os.path.exists()`** on Volume paths. For server-side checks, use `dbutils.fs.ls()` instead.

### Datetime in Spark DataFrames
Always use explicit schema + Python `datetime` — Spark cannot infer timestamps from dict values:
```python
from datetime import datetime, timezone
df = spark.createDataFrame(rows, schema=StructType([...]))
```

### Destination Always Needs `dbfs:` Scheme
Even for UC Volumes, `databricks fs cp` requires `dbfs:` prefix:
```bash
# CORRECT
databricks fs cp file.csv dbfs:/Volumes/.../raw/file.csv
# WRONG — will fail
databricks fs cp file.csv /Volumes/.../raw/file.csv
```

---

## Test Framework (rotaperfume)

Tests use **Databricks Connect** (not local Spark) with auto-fallback to serverless compute. See `rotaperfume/tests/conftest.py`.

### Fixtures
- `spark` — Returns `DatabricksSession` (serverless-backed)
- `load_fixture(filename)` — Loads JSON or CSV from `fixtures/` directory

### Configuration
- `databricks-connect>=15.4,<15.5` (pinned in `pyproject.toml`)
- `DATABRICKS_SERVERLESS_COMPUTE_ID=auto` is set automatically if no cluster configured
- `pytest_configure` validates session eagerly (15+)

### Adding Tests
- Place files in `rotaperfume/tests/`
- Place test data in `rotaperfume/fixtures/`
- JSON/CSV loaders are auto-detected by file extension

### App Tests (rotaperfume-direcao)
- Vitest, see `vitest.config.ts`. `npm run test` runs the suite.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `Metastore storage root URL does not exist` on deploy | Bundle tried to create catalog via API | Run `scripts/criar-catalogo.sh` first |
| Schemas named `dev_user_bronze` | `mode: development` in dev target | Use `presets: { trigger_pause_status: PAUSED }` instead |
| `profile not found` | Profile not in `.databrickscfg` | `databricks auth login --profile <name>` |
| `databricks fs cp` path error | Missing `dbfs:` prefix | Use `dbfs:/Volumes/...` (see Key Patterns above) |
| `CANNOT_DETERMINE_TYPE` | Spark Column in dict/struct context | Use explicit `StructType` + Python `datetime` |
| `dbutils.widgets` returns empty | Widget not declared first | Call `dbutils.widgets.text()` before `get()` |
| `Unable to access the notebook` for ml task | `src/ml/` is gitignored | Bundle has `sync.include: src/ml/**` in databricks.yml |
| `os.path.exists` returns False on Volume | Serverless can't read local files | Use `dbutils.fs.ls()` for server-side checks |
| AppKit build fails with `styleText` not exported | Node < 20.12 | Use Node 24 (see `rotaperfume-direcao/CLAUDE.md`) |
