# Documento 5 — Dashboard como Código: Versionado e Rollbackável

**Deploy nº 5** · Dashboard comercial em JSON versionado no repositório.
Sobe junto com o bundle, versionado, com `git diff` e `git revert`.

## 1. O que é o Deploy #5

Este deploy cria o **AI/BI Dashboard** comercial como recurso do bundle:

| Arquivo | Função |
|---------|--------|
| `resources/dashboard-comercial.lvdash.json` | Dashboard em JSON |
| `resources/dashboard.dashboard.yml` | Declaração como recurso bundle |

O JSON define: 1 dataset compartilhado, 3 filtros (Ano/Segmento/Cidade),
4 KPI counters, 1 line chart (24 meses), 2 bar charts, 1 tabela (top 20).

**Tudo num arquivo versionado.** Mude o título de um widget, `git diff` mostra.
Apague o dashboard ao vivo, `bundle deploy` traz de volta idêntico.

## 2. O JSON — `dashboard-comercial.lvdash.json`

### 2.1 Dataset compartilhado

```json
{
  "datasets": [
    {
      "name": "dataset_fato",
      "displayName": "Fato Vendas",
      "query": "SELECT data_pedido, ano, mes, canal, cliente_id, razao_social, segmento, cidade, marca, categoria, receita, margem, devolucao FROM gold.fato_vendas"
    }
  ]
}
```

**Por que um único dataset:** widgets que compartilham dataset filtram
juntos. Clicar num segmento filtra a tela inteira. Datasets separados quebram
o cross-filtering.

**Por que `query` (string única), não `queryLines` (array):** o bundle
serializa `queryLines` sem quebras de linha — vira uma linha gigante onde
`devolucaoFROM` gruda e o SQL quebra. Uma string única evita isso.

### 2.2 Filtros

Os filtros ficam **no mesmo canvas**, não numa página de global filters.
Usam o mesmo `dataset_fato` com `associative_filter_predicate_group` para
o cross-filtering:

```json
{
  "name": "filter_ano",
  "queries": [
    {
      "name": "dashboards/01f1a2ec125b132897fb59555ae2e22b/datasets/dataset_fato_ano",
      "query": {
        "datasetName": "dataset_fato",
        "fields": [
          { "name": "ano", "expression": "`ano`" },
          { "name": "ano_associative_filter_predicate_group",
            "expression": "COUNT_IF(`associative_filter_predicate_group`)" }
        ],
        "disaggregated": false
      }
    }
  ],
  "spec": {
    "version": 2,
    "frame": { "showTitle": true, "title": "Ano" },
    "widgetType": "filter-single-select",
    "encodings": {
      "fields": [
        { "fieldName": "ano",
          "queryName": "dashboards/01f1a2ec125b132897fb59555ae2e22b/datasets/dataset_fato_ano" }
      ]
    }
  }
}
```

**Armadilhas dos filtros:**

1. **Falta `frame.title`** → filtro aparece sem nome visível.
2. **Falta `associative_filter_predicate_group`** → cross-filter não funciona.
3. **`queryName` errado** → o filtro não vincula ao dataset principal.

### 2.3 Counters (KPI)

```json
{
  "name": "counter_receita",
  "queries": [{
    "name": "main_query",
    "query": {
      "datasetName": "dataset_fato",
      "fields": [{ "name": "total_receita", "expression": "SUM(`receita`)" }],
      "disaggregated": false
    }
  }],
  "spec": {
    "version": 2,
    "frame": { "showTitle": true, "title": "Receita Total" },
    "widgetType": "counter",
    "encodings": { "value": { "fieldName": "total_receita" } }
  }
}
```

**Versão correta:**
- counter = 2
- table = 1
- bar = 3
- line = 3
- filter = 2

**Versão errada = widget quebrado.** Counter não aceita cor própria — a
cor vem de `theme.fontColor`.

### 2.4 Line chart

```json
{
  "name": "line_receita_mensal",
  "spec": {
    "version": 3,
    "frame": { "showTitle": true, "title": "Receita Mensal (R$ 24 meses)" },
    "widgetType": "line",
    "encodings": {
      "x": { "fieldName": "mes_label", "scale": { "type": "temporal" } },
      "y": {
        "primary": {
          "fields": [{ "fieldName": "receita_mes" }],
          "scale": { "type": "quantitative" },
          "format": { "type": "number-plain", "abbreviation": "compact", ... }
        }
      }
    }
  }
}
```

**`x` precisa de `scale.type: "temporal"`** para o eixo entender que é data.

### 2.5 Bar charts — `disaggregated: true` + `encodings: {}`

Os bar charts no workspace usam **a forma simples**:

```json
{
  "name": "bar_top_marcas",
  "queries": [{
    "name": "main_query",
    "query": {
      "datasetName": "dataset_fato",
      "disaggregated": true
    }
  }],
  "spec": {
    "version": 3,
    "frame": { "showTitle": true, "title": "Top Marcas por Receita" },
    "widgetType": "bar",
    "encodings": {}
  }
}
```

**Por que `encodings: {}` e `disaggregated: true`:** o Databricks infere
as agregações e eixos do dataset automaticamente. Quando você tenta
especificar `x`/`y` com `disaggregated: false` + encodings explícitos, o
widget sai em branco.

### 2.6 Table (v1) — `disaggregated: true`

```json
{
  "name": "table_top_clientes",
  "spec": {
    "version": 1,
    "invisibleColumns": [],
    "allowHTMLByDefault": false,
    "itemsPerPage": 20,
    "paginationSize": "default",
    "condensed": true,
    "withRowNumber": false,
    "widgetType": "table",
    "encodings": {
      "columns": [
        { "fieldName": "razao_social", "title": "Cliente",
          "type": "string", "displayAs": "string", "visible": true, "order": 100000 },
        ...
      ]
    }
  }
}
```

**Atenção:** table é **versão 1**, não 2. Versão 2 quebra table.

## 3. A Declaração — `dashboard.dashboard.yml`

```yaml
resources:
  dashboards:
    dashboard_comercial:
      display_name: "Dashboard Comercial - Rota Perfume"
      file_path: ../resources/dashboard-comercial.lvdash.json
      warehouse_id: ${var.warehouse_id}
      dataset_catalog: ${var.catalog}
      dataset_schema: gold
```

`include: resources/*.yml` no `databricks.yml` carrega automaticamente.

**Campos:**

| Campo | Valor | Função |
|-------|-------|--------|
| `display_name` | nome humano | Aparece no workspace |
| `file_path` | path relativo | Onde o JSON vive |
| `warehouse_id` | `${var.warehouse_id}` | Serverless SQL warehouse |
| `dataset_catalog` | `${var.catalog}` | Resolve o `gold` das queries |
| `dataset_schema` | `gold` | Schema default das queries |

**Importante:** as queries do JSON usam nome de tabela **PURO**
(`FROM fato_vendas`), nunca `FROM gold.fato_vendas`. O catálogo e o schema
vêm de `dataset_catalog` e `dataset_schema` — se você prefixar, eles são
ignorados.

## 4. Como Verificar

### 4.1 Validação do bundle

```bash
databricks bundle validate --target dev --profile joaogui21@hotmail.com
# Validation OK!
```

### 4.2 Deploy

```bash
databricks bundle deploy --target dev --profile joaogui21@hotmail.com
# Created dashboards.dashboard_comercial
```

### 4.3 Resumo do bundle

```bash
databricks bundle summary --target dev --profile joaogui21@hotmail.com
```

A saída traz a URL do dashboard publicado.

### 4.4 Números canônicos dos cards

```sql
SELECT
  ROUND(SUM(receita), 2)                              AS receita_total,
  ROUND(SUM(margem), 2)                                AS margem_total,
  COUNT(DISTINCT cliente_id)                          AS pedidos,
  ROUND(SUM(receita) / COUNT(DISTINCT cliente_id), 2) AS ticket_medio
FROM lakehouse_rotaperfume.gold.fato_vendas;
-- receita_total = R$ 102.303.828,05
```

### 4.5 Margem por categoria

```sql
SELECT categoria,
       ROUND(SUM(receita)/1e6, 1)                 AS receita_mi,
       ROUND(100 * SUM(margem) / SUM(receita), 1) AS margem_pct
FROM lakehouse_rotaperfume.gold.fato_vendas
GROUP BY categoria ORDER BY margem_pct;
-- Kit Presente 33.0 na ponta esquerda
```

## 5. As 5 Demonstrações de Versão

### 5.1 Mudar e ver o diff

```bash
# Mude o título de um widget no JSON
git diff -- resources/dashboard-comercial.lvdash.json
databricks bundle deploy --target dev --profile joaogui21@hotmail.com
# Recarregue o dashboard: o título mudou
```

### 5.2 Rollback

```bash
git checkout -- resources/dashboard-comercial.lvdash.json
databricks bundle deploy --target dev --profile joaogui21@hotmail.com
# e voltou
```

### 5.3 Apagar e recriar

```bash
# Delete o dashboard pela interface, ao vivo
# Depois:
databricks bundle deploy --target dev --profile joaogui21@hotmail.com
# Ele volta idêntico, com os mesmos widgets e cores
```

### 5.4 Cross-filter funciona

```bash
# Clique numa marca no gráfico de barras
# A tela inteira filtra, KPIs incluídos
# Se um widget não acompanhar, ele tem dataset próprio — é o erro
```

### 5.5 JSON puro no Git

```bash
# O dashboard mora no repositório — é código versionado
ls resources/dashboard-comercial.lvdash.json
```

## 6. Armadilhas Já Medidas

| Sintoma | Causa | Correção |
|---------|-------|----------|
| Widget diz "no selected fields to visualize" | `name` do field ≠ `fieldName` do encoding | Os dois têm que ser idênticos |
| Widget diz "unsupported widget definition" | Versão errada | counter/table=1,2; bar/line=3; filter=2 |
| Dashboard sobe mas dados não aparecem | Query prefixou catálogo/schema | `FROM fato_vendas`, sem prefixo |
| Clicar num gráfico não filtra os outros | Cada widget tem dataset próprio | Junte no mesmo dataset |
| Chave duplicada no `bundle validate` | Dois recursos com mesma chave | Cada recurso precisa de chave única |
| Widgets em branco | Bar/table com `disaggregated: false` + encodings explícitos | Use `disaggregated: true` + `encodings: {}` |
| Filtros sem nome | Falta `frame.title` | Adicione `frame: { showTitle: true, title: "..." }` |
| Cross-filter não funciona | Falta `associative_filter_predicate_group` | Adicione o field COUNT_IF |

## 7. Decisões e Princípios

| Decisão | Motivo |
|---------|--------|
| JSON, não YAML | AI/BI Dashboard exige `.lvdash.json` (LakeView) |
| `query` em vez de `queryLines` | Bundle serializa array sem `\n` — vira linha única e quebra |
| Dataset compartilhado | Cross-filtering entre widgets exige dataset único |
| `dataset_catalog` + `dataset_schema` | Bundle injeta catálogo/schema; queries usam nome puro |
| Filtros com `associative_filter_predicate_group` | Habilita cross-filter via `COUNT_IF` |
| `disaggregated: true` + `encodings: {}` em bar/table | Padrão do workspace; encodings explícitos quebram |
| `frame.title` em todos os widgets | Sem isso, label não aparece |
| Widget version 2 (counter/table), 3 (bar/line), 1 (table) | Versão errada = widget quebrado |
| `layoutVersion: "GRID_V1"` em toda página | Necessário para grid de 12 colunas |
| Deploy junto com o bundle | Uma fonte de verdade; `git diff` mostra tudo |

## 8. Layout Final

```
┌────────────────────────────────────────────────────────────┐
│  Filtro: Ano    │  Filtro: Segmento  │  Filtro: Cidade    │
├──────────┬──────────┬──────────┬──────────────────────────┤
│  Receita │  Margem  │ Clientes │  Ticket Médio           │
├──────────┴──────────┴──────────┴──────────────────────────┤
│              Receita Mensal (24 meses)                    │
├────────────────────────────┬───────────────────────────────┤
│  Top Marcas por Receita    │  Margem % por Categoria      │
├────────────────────────────┴───────────────────────────────┤
│              Top 20 Clientes (segmento, cidade)            │
└────────────────────────────────────────────────────────────┘
```

## 9. Próximos Passos

Este é o último deploy do projeto. O bundle agora tem 5 recursos versionados:

| Recurso | Tipo | Função |
|---------|------|--------|
| `rotaperfume_pipeline` | job | Pipeline completo (12 tarefas) |
| `dashboard_comercial` | dashboard | AI/BI Dashboard comercial |
| `schema_bronze` | schema | Camada de ingestão |
| `schema_silver` | schema | Camada de limpeza |
| `schema_gold` | schema | Camada modelada |
| `volume_bronze_raw` | volume | CSVs do ERP/CRM |

Qualquer alteração — schema, tabela, widget, agendamento — vive em arquivo
no repositório. `git diff` antes de qualquer merge, `git revert` se algo
quebrar.
