# Documentação do Projeto — Rota Perfume

> **Monorepo:** toda a documentação vive aqui, em `rotaperfume-comercial/Documentação/`.
> Qualquer alteração, inclusão ou correção deve ser feita **neste diretório**.

## Índice

| # | Documento | Deploy | Tema |
|---|----------|--------|------|
| 1 | [Documento_01_Catalogo.md](Documento_01_Catalogo.md) | #1 | Catálogo como código + conferência de chegada |
| 2 | [Documento_02_Bronze.md](Documento_02_Bronze.md) | #2 | Bronze — ingestão que preserva a sujeira |
| 3 | [Documento_03_Silver.md](Documento_03_Silver.md) | #3 | Silver — limpeza tipada e contrato |
| 4 | [Documento_04_Gold.md](Documento_04_Gold.md) | #4 | Gold — dimensões, fato, marts e testes |
| 5 | [Documento_05_Dashboard.md](Documento_05_Dashboard.md) | #5 | Dashboard como código — versionado e rollbackável |
| 6 | [Documento_06_Features.md](Documento_06_Features.md) | ML #1 | Features de cliente para ML (RFM, Ritmo, CRM, Mix) |
| 7 | [Documento_07_Modelo.md](Documento_07_Modelo.md) | ML #2 | Treino do modelo + MLflow (AUC, lift_top200) |
| 8 | [Documento_08_Fila_e_Agente.md](Documento_08_Fila_e_Agente.md) | ML #3 | Fila semanal + 4 ferramentas SQL do agente |
| 9 | [Documento_09_Genie_da_Direcao.md](Documento_09_Genie_da_Direcao.md) | App #1 | Genie da Direção + caminho de volta (retorno_ligacao) |
| 10 | [Documento_10_App_Direcao.md](Documento_10_App_Direcao.md) | App #2 | App da Direção: a fila dos 200 na tela |
| 11 | [Documento_11_Retorno.md](Documento_11_Retorno.md) | App #3 | O Retorno: POST /api/retorno + seletor 2×2 + KPI instantâneo |

## Visão Geral do Projeto

**Projeto:** Rota Perfume — engenharia de dados com arquitetura medallion (bronze/silver/gold) em Databricks.

**Stack:**
- Databricks Asset Bundles (DAB) — infraestrutura como código
- Unity Catalog — catálogo, schemas, volumes
- SQL Warehouse (serverless) — tarefas SQL no pipeline
- Python notebooks — ingestão e conferência de chegada
- AI/BI Dashboards — dashboards declarativos versionados

**Volume de dados:**
- 10 arquivos fonte (ERP + CRM), ~14,7 MB, 313.551 linhas
- Bronze → Silver → Gold em pipeline diário agendado às 6h (São Paulo)

**Números canônicos validados:**
- Receita total: R$ 102.232.376,45
- Margem total: R$ 39.586.969,39
- Clientes únicos: 2.810
- Ticket médio: R$ 36.381,27
