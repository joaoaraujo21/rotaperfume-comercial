# Rota Perfume — Comercial

**Engenharia de dados medallion + App comercial Databricks para a fila dos 200.**

Monorepo com dois projetos relacionados:

| Pasta | O que é | Stack |
|---|---|---|
| `rotaperfume/` | Bundle DAB com pipeline medallion (bronze/silver/gold), ML, scripts, recursos | Databricks Asset Bundles, Python, SQL |
| `rotaperfume-direcao/` | App Databricks AppKit com 3 abas (A semana, Perguntar, Acompanhamento) | React, TypeScript, Express, AppKit SDK |
| `Documentação/` | Documentação consolidada dos 11 deploys do projeto | Markdown |

**Live:** [rotaperfume-direcao-7474649855865169.aws.databricksapps.com](https://rotaperfume-direcao-7474649855865169.aws.databricksapps.com)

---

## O que é o projeto

A "Rota do Perfume" é um curso de engenharia de dados com Databricks. A ideia é construir:

1. Um **pipeline de dados** que ingere ERP + CRM, limpa, tipifica e entrega a `gold` dimensões, fato, marts e uma fila de 200 clientes priorizados por modelo de ML.
2. Um **app comercial** que mostra essa fila para a direção comercial e permite registrar o resultado da ligação, fechando o ciclo.

O número que vira a linha de fechamento é a `gold.retorno_ligacao` — quando o vendedor diz "vendeu", o dado volta e o KPI sobe.

---

## Estrutura

```
rotaperfume-comercial/
├── README.md                 ← este arquivo
├── CLAUDE.md                 ← instruções para IA
├── Documentação/             ← docs consolidados (01–11)
│   ├── README.md
│   ├── Documento_01_Catalogo.md
│   ├── Documento_02_Bronze.md
│   ├── ...
│   └── Documento_11_Retorno.md
├── rotaperfume/              ← bundle Databricks (medallion + ML)
│   ├── databricks.yml
│   ├── resources/
│   ├── scripts/
│   ├── src/                  ← notebooks Python + SQL das camadas
│   └── tests/
└── rotaperfume-direcao/      ← app comercial AppKit
    ├── databricks.yml
    ├── app.yaml
    ├── client/               ← React
    ├── server/               ← Express
    ├── config/queries/       ← SQL fora do React
    └── shared/
```

---

## Quick start

### Pipeline (rotaperfume)

```bash
cd rotaperfume

# 1. Criar catálogo (Free Edition: SQL direto)
bash scripts/criar-catalogo.sh <perfil>

# 2. Deploy dos recursos
databricks bundle deploy --target dev --profile <perfil>

# 3. Subir CSVs
bash scripts/subir-raw.sh <perfil>

# 4. Rodar pipeline
databricks bundle run rotaperfume_pipeline --target dev --profile <perfil>
```

### App (rotaperfume-direcao)

```bash
cd rotaperfume-direcao

npm install                    # uma vez

# Local dev
npm run dev

# Build produção
npm run build

# Deploy
databricks apps deploy --profile <perfil>
```

---

## Stack completa

- **Databricks Asset Bundles (DAB)** — infraestrutura como código
- **Unity Catalog** — catálogo, schemas, volumes
- **SQL Warehouse (serverless)** — tarefas SQL do pipeline
- **Python notebooks** — ingestão, features, treino de modelo
- **MLflow** — tracking do modelo
- **Databricks Apps + AppKit SDK** — frontend React + backend Express
- **Recharts** — gráficos do Acompanhamento
- **shadcn/ui + Tailwind** — UI

---

## Documentação

Toda a documentação está em `Documentação/`:

| # | Documento | Tema |
|---|---|---|
| 1 | [Documento_01_Catalogo.md](Documentação/Documento_01_Catalogo.md) | Catálogo como código + conferência |
| 2 | [Documento_02_Bronze.md](Documentação/Documento_02_Bronze.md) | Bronze — ingestão que preserva a sujeira |
| 3 | [Documento_03_Silver.md](Documentação/Documento_03_Silver.md) | Silver — limpeza tipada e contrato |
| 4 | [Documento_04_Gold.md](Documentação/Documento_04_Gold.md) | Gold — dimensões, fato, marts e testes |
| 5 | [Documento_05_Dashboard.md](Documentação/Documento_05_Dashboard.md) | Dashboard como código |
| 6 | [Documento_06_Features.md](Documentação/Documento_06_Features.md) | Features de cliente para ML (RFM, Ritmo, CRM, Mix) |
| 7 | [Documento_07_Modelo.md](Documentação/Documento_07_Modelo.md) | Treino do modelo + MLflow (AUC, lift_top200) |
| 8 | [Documento_08_Fila_e_Agente.md](Documentação/Documento_08_Fila_e_Agente.md) | Fila semanal + agente SQL |
| 9 | [Documento_09_Genie_da_Direcao.md](Documentação/Documento_09_Genie_da_Direcao.md) | Genie da Direção |
| 10 | [Documento_10_App_Direcao.md](Documentação/Documento_10_App_Direcao.md) | App da Direção: a fila dos 200 na tela |
| 11 | [Documento_11_Retorno.md](Documentação/Documento_11_Retorno.md) | O Retorno: ciclo se fecha |

---

## Números canônicos

| Métrica | Valor |
|---|---|
| Receita total | R$ 102.232.376,45 |
| Margem total | R$ 39.586.969,39 |
| Clientes únicos | 2.810 |
| Ticket médio | R$ 36.381,27 |
| Top 200 — acertos do modelo | 86 (43% vs base 10,1%) |
| Lift_top200 | 4,25 |

---

## Autenticação

```bash
# Configurar perfil do Databricks CLI
databricks auth login --host https://<workspace>.cloud.databricks.com
```

Lembre de nunca commitar:
- `.env` com credenciais
- `~/.databrickscfg`
- Tokens no código

---

## Licença

Projeto didático. Sem licença de uso comercial.
