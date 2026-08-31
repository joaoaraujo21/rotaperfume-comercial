# Documento 4 — Gold: Dimensões, Fato, Martins e Testes

**Deploy nº 4** · 4 dimensões conformadas, 1 fato de vendas, 3 data marts
e 9 testes de qualidade. As 4 tarefas gold rodam em SERIE (dependência), os
9 testes são o guarda de transição.

## 1. O que é o Deploy #4

A gold não é "a camada limpa" — isso é a silver. A gold é a camada **modelada
para um consumidor específico**. Se você não sabe quem consome, não está
pronto para criar gold.

Este deploy cria:

| Camada | Artefato | Grão | Quem consome |
|--------|----------|------|--------------|
| Dimensões | `dim_cliente`, `dim_produto`, `dim_vendedor`, `dim_calendario` | Surrogate key + atributos | Todas as queries |
| Fato | `fato_vendas` | Item de pedido | Diretoria Comercial, Produto |
| Marts | `mart_vendas_por_vendedor` | Vendedor × mês | Diretoria Comercial |
| | `mart_produto_performance` | SKU × mês | Diretoria Produto |
| | `mart_financeiro_recebimento` | Mês de vencimento | Diretoria Financeiro |
| Testes | `testes` (9 queries) | — | Todo o pipeline |

## 2. Arquivos do Deploy

| Arquivo | Função |
|---------|--------|
| `src/gold/05-dimensoes.sql` | 4 dimensões conformadas |
| `src/gold/06-fato-vendas.sql` | Fato único de vendas |
| `src/gold/07-marts.sql` | 3 data marts |
| `src/gold/08-testes.sql` | 9 testes de qualidade |
| `resources/pipeline.job.yml` | 4 tarefas gold em série + testes |

## 3. Dimensões — `05-dimensoes.sql`

### 3.1 `dim_cliente` — LEFT JOIN intencional

```sql
CREATE OR REPLACE TABLE lakehouse_rotaperfume.gold.dim_cliente AS
SELECT
  c.cliente_id,
  c.cnpj,
  c.razao_social,
  c.estado,
  c.cidade,
  c.segmento,
  c.data_cadastro,
  c.ativo,
  -- metadado
  c.cliente_ids_duplicados,
  CASE WHEN p.cliente_id IS NULL THEN TRUE ELSE FALSE END AS sem_pedidos,
  current_timestamp() AS _processado_em
FROM lakehouse_rotaperfume.silver.clientes c
LEFT JOIN (
  SELECT DISTINCT cliente_id FROM lakehouse_rotaperfume.silver.pedidos
) p ON p.cliente_id = c.cliente_id;
-- 3.189 linhas: 3.000 clientes + 189 que nunca compraram
```

**LEFT JOIN intencional:** 189 clientes cadastrados nunca fizeram pedido.
Usar INNER JOIN os tiraria da dimensão — qualquer join com o fato os perderia.
Dimensão é dimensão: guarda o que existe, não só o que vendeu.

### 3.2 `dim_produto`

```sql
SELECT
  sku,
  descricao,
  categoria,
  marca,
  nota_olfativa,
  preco_base,
  custo_unitario,
  ativo,
  data_lancamento
FROM lakehouse_rotaperfume.silver.produtos
```

### 3.3 `dim_vendedor`

```sql
SELECT
  vendedor_id,
  nome,
  cpf,
  regiao,
  data_admissao,
  data_desligamento,
  ativo,
  meta_mensal,
  CASE WHEN data_desligamento IS NOT NULL AND ativo THEN TRUE
       ELSE FALSE END AS desligado_e_ativo,
  current_timestamp() AS _processado_em
FROM lakehouse_rotaperfume.silver.vendedores
```

### 3.4 `dim_calendario` — via `explode(sequence())`

```sql
CREATE OR REPLACE TABLE lakehouse_rotaperfume.gold.dim_calendario AS
SELECT
  data AS data_calendario,
  YEAR(data)    AS ano,
  MONTH(data)   AS mes,
  DAY(data)    AS dia,
  DAYOFWEEK(data)   AS dia_semana,
  WEEKDAY(data)     AS dia_util,
  QUARTER(data)     AS trimestre,
  CASE WHEN DAYOFWEEK(data) IN (1,7) THEN FALSE ELSE TRUE END AS dia_util_flag
FROM explode(sequence(
  DATE('2024-01-01'),
  DATE('2026-12-31')
)) AS t(data)
```

730 dias (3 anos completos) garante que todas as combinações de data que
aparecem no fato encontram correspondência na dimensão.

## 4. O Fato — `06-fato-vendas.sql`

### 4.1 Granularidade: item de pedido

Cada linha da tabela é **um item de pedido**, não um pedido. Isso é essencial
para que o `SUM(receita) * SUM(quantidade)` seja matematicamente correto.

```sql
CREATE OR REPLACE TABLE lakehouse_rotaperfume.gold.fato_vendas AS
SELECT
  p.data_pedido,
  p.ano,
  p.mes,
  p.canal,
  p.cliente_id,
  c.razao_social,
  c.segmento,
  c.cidade,
  p.vendedor_id,
  i.sku,
  pr.categoria,
  pr.marca,
  pr.nota_olfativa,
  -- métricas
  i.quantidade,                                        -- negativa se devolução
  i.preco_praticado,
  i.valor_bruto                                       AS receita,   -- fecha com silver
  ROUND(i.quantidade_abs * pr.custo_unitario, 2)      AS custo,
  ROUND(i.valor_bruto - i.quantidade_abs * pr.custo_unitario, 2) AS margem,
  i.devolucao,
  -- auditoria
  current_timestamp()                                  AS _processado_em
FROM lakehouse_rotaperfume.silver.itens_pedido i
JOIN lakehouse_rotaperfume.silver.pedidos  p ON p.pedido_id = i.pedido_id
JOIN lakehouse_rotaperfume.silver.clientes c ON c.cliente_id = p.cliente_id
JOIN lakehouse_rotaperfume.silver.produtos pr ON pr.sku = i.sku
WHERE NOT p.cancelado;
-- exclui cancelado; devolução fica DENTRO com valor negativo
```

### 4.2 Regras de cálculo

```sql
-- receita = quantidade * preco_praticado (usa valor_bruto da silver, não o produto)
-- custo   = quantidade_abs * custo_unitario_do_produto
-- margem  = receita - custo
```

**Por que `valor_bruto` da silver, não `quantidade * preco_praticado`?** O
`valor_bruto` foi arredondado no nível do item na silver. Se multiplicar
`quantidade * preco_praticado` aqui, a soma diverge por arredondamento. Usar
o `valor_bruto` garante que `SUM(receita) FROM gold.fato_vendas == SUM(valor_liquido)
FROM silver.pedidos`.

### 4.3 Devolução dentro do fato

A devolução fica **DENTRO** do fato, com quantidade e receita negativas. Se
ficasse fora, a gold somaria R$ 103,6 mi em vez de R$ 102,3 mi — R$ 1,26
milhão de diferença. Quem quiser o bruto pede:

```sql
SUM(receita) FILTER (WHERE NOT devolucao)
```

### 4.4 Diferença gold vs silver (conhecida)

Devido à deduplicação de clientes na silver (40 CNPJs duplicados, 36 pedidos
perderam `cliente_id` no LEFT JOIN), a soma do fato é ~R$ 71.451,60 menor
que a soma da silver. Decisão: manter o JOIN com silver.clientes (modelagem
correta de dimensão) e documentar a diferença. Teste 1 aceita tolerância de
R$ 100.000.

## 5. Data Martins — `07-marts.sql`

Todos os marts são **conformados**: a soma de receita em qualquer mart é
igual a `SUM(receita) FROM gold.fato_vendas = R$ 102.232.376,45`.

### 5.1 `mart_vendas_por_vendedor` — Diretoria Comercial

Grão: vendedor × mês. Contém meta mensal, atingimento %, ticket médio.

```sql
SELECT
  f.ano, f.mes, f.vendedor_id,
  v.nome AS vendedor_nome, v.regiao, v.ativo, v.meta_mensal,
  ROUND(SUM(f.receita), 2) AS receita,
  ROUND(SUM(f.margem), 2)  AS margem,
  ROUND(100.0 * SUM(f.receita) / NULLIF(v.meta_mensal, 0), 1) AS atingimento_pct,
  COUNT(DISTINCT f.cliente_id)                         AS clientes_atendidos,
  ROUND(SUM(f.receita) / NULLIF(COUNT(DISTINCT f.cliente_id), 0), 2)
                                                          AS ticket_medio
FROM gold.fato_vendas f
JOIN silver.vendedores v ON v.vendedor_id = f.vendedor_id
GROUP BY 1,2,3,4,5,6,7
```

### 5.2 `mart_produto_performance` — Diretoria Produto

Grão: SKU × mês. Contém curva ABC por receita acumulada dentro de cada
categoria+mês.

```sql
-- A: 80% superior da receita acumulada
-- B: 80-95%
-- C: 5% inferior
CASE
  WHEN receita_acumulada / total_categoria <= 0.80 THEN 'A'
  WHEN receita_acumulada / total_categoria <= 0.95 THEN 'B'
  ELSE 'C'
END AS curva_abc
```

### 5.3 `mart_financeiro_recebimento` — Diretoria Financeiro

Grão: mês de vencimento × canal × forma_pagamento. Baseado em pagamentos,
não em pedidos.

```sql
FROM silver.pagamentos pg
JOIN silver.pedidos p ON p.pedido_id = pg.pedido_id
WHERE NOT p.cancelado
```

**Nota:** este mart usa `silver.pagamentos` + `silver.pedidos` diretamente,
não `gold.fato_vendas`, porque `fato_vendas` não tem `pedido_id` (otimização
de storage). Se precisasse receita do pedido, teria que usar o mart ou a silver.

## 6. Testes — `08-testes.sql`

9 testes com `raise_error()`. Mecanismo: `raise_error()` retorna tipo
`NOTHING` — SEMPRE dentro de `CASE WHEN ... THEN 'PASSOU' ELSE raise_error(...) END`.
Se algum teste falhar, a tarefa **para** e nada depois dela roda.

### Os 9 Testes

| # | Teste | O que verifica |
|---|-------|---------------|
| 1 | Receita gold ≈ silver | `ABS(SUM(gold) - SUM(silver)) <= 100000` (tolerância: 36 pedidos sem cliente) |
| 2 | CNPJ único na silver | `COUNT(*) == COUNT(DISTINCT cnpj)` em silver.clientes |
| 3 | Sem datas nulas | `COUNT(*) WHERE data_pedido IS NULL = 0` em silver.pedidos |
| 4 | Devolução marcada | `COUNT(*) WHERE receita < 0 AND NOT devolucao = 0` |
| 5 | Volume do fato | `COUNT(*) BETWEEN 140000 AND 250000` (guard-rail) |
| 6 | Integridade linhas | `COUNT(fato) == COUNT(itens com cliente válido)` |
| 7 | Cliente existe | Todo `cliente_id` da gold existe na silver.clientes |
| 8 | Mart conforme | `SUM(mart_produto) == SUM(fato_vendas)` |
| 9 | CNPJ 14 dígitos | `COUNT(*) WHERE length(cnpj) <> 14 = 0` |

### Padrão de teste

```sql
SELECT CASE WHEN
  (SELECT COUNT(*) FROM lakehouse_rotaperfume.gold.fato_vendas)
  BETWEEN 140000 AND 250000
  THEN 'PASSOU: volume da gold.fato_vendas dentro do esperado'
  ELSE raise_error(
    'TESTE 5 FALHOU: volume = '
    || (SELECT COUNT(*) FROM lakehouse_rotaperfume.gold.fato_vendas)
    || ' (esperado entre 140.000 e 250.000)'
  )
END AS teste_5_volume;
```

**Nota:** `||` funciona em `raise_error()` dentro de SELECT. NÃO funciona em
`COMMENT ON TABLE` (erro `PARSE_SYNTAX_ERROR`).

## 7. O Job — 4 Tarefas em Série + Testes

```yaml
- task_key: gold_dimensoes
  depends_on: [silver_01_clientes, silver_02_pedidos,
               silver_03_itens_produtos, silver_04_crm_financeiro]
  sql_task:
    warehouse_id: ${var.warehouse_id}
    file: { path: ../src/gold/05-dimensoes.sql }

- task_key: gold_fato_vendas
  depends_on: { task_key: gold_dimensoes }
  sql_task:
    file: { path: ../src/gold/06-fato-vendas.sql }

- task_key: gold_marts
  depends_on: { task_key: gold_fato_vendas }
  sql_task:
    file: { path: ../src/gold/07-marts.sql }

- task_key: testes
  depends_on: { task_key: gold_marts }
  sql_task:
    file: { path: ../src/gold/08-testes.sql }
```

**Ordem:** `gold_dimensoes → gold_fato_vendas → gold_marts → testes`

- Fato depende de dimensões (JOIN precisa das dimensões prontas)
- Marts dependem do fato (agregação sobre o fato)
- Testes dependem dos marts (verificam a conformidade)

**Testes é o guarda de transição:** se falhar, o DAG para e os dashboards
ficam com o dado de ontem.

## 8. Como Verificar

### 8.1 Números canônicos do fato

```sql
SELECT
  ROUND(SUM(receita), 2)                        AS receita_total,
  ROUND(SUM(margem), 2)                         AS margem_total,
  COUNT(DISTINCT cliente_id)                     AS clientes,
  ROUND(SUM(receita) / COUNT(DISTINCT cliente_id), 2) AS ticket_medio,
  COUNT(*)                                       AS linhas
FROM lakehouse_rotaperfume.gold.fato_vendas;
```

| Métrica | Valor |
|---------|-------|
| Receita total | R$ 102.232.376,45 |
| Margem total | R$ 39.586.969,39 |
| Clientes únicos | 2.810 |
| Ticket médio | R$ 36.381,27 |
| Linhas | 190.927 |

### 8.2 Margem por categoria

```sql
SELECT
  categoria,
  ROUND(SUM(receita)/1e6, 1)       AS receita_mi,
  ROUND(100 * SUM(margem)/SUM(receita), 1) AS margem_pct
FROM lakehouse_rotaperfume.gold.fato_vendas
GROUP BY categoria ORDER BY margem_pct;
```

| Categoria | Margem % | Nota |
|-----------|----------|------|
| Kit Presente | 31.3% | Mais vendido, menor margem |
| Bakhoor | 45.3% | |
| Incenso | 46.9% | |
| Óleo Concentrado | 48.7% | Melhor margem |

### 8.3 Marts conformados

```sql
SELECT
  (SELECT SUM(receita) FROM gold.mart_vendas_por_vendedor)    AS mart_vendedor,
  (SELECT SUM(receita) FROM gold.mart_produto_performance)   AS mart_produto,
  (SELECT SUM(receita) FROM gold.fato_vendas)                AS fato;
-- Os três valores devem ser IGUAIS (com tolerância de R$ 0.01)
```

### 8.4 Todos os 9 testes passando

```sql
-- Cada SELECT retorna 'PASSOU: ...' ou raise_error(...)
-- Se o job completou sem erro, todos passaram
```

## 9. Decisões e Princípios

| Decisão | Motivo |
|---------|--------|
| Granularidade item de pedido | Necessário para soma correta; `pedido_id` omitido por storage |
| `valor_bruto` como receita | Garante que `SUM(gold) == SUM(silver)`, sem diferença de arredondamento |
| Devolução dentro do fato | Faturamento fecha; quem precisa do bruto filtra `NOT devolucao` |
| Mart financeiro usa silver.pagamentos | `fato_vendas` não tem `pedido_id` para fazer join com pagamentos |
| Tolerância R$ 100k no teste 1 | 36 pedidos perderam cliente após dedup; R$ 71.451,60 de diferença |
| 4 tarefas gold em série | Fato depende de dimensões; marts dependem do fato; testes dependem de marts |
| Testes como guarda de transição | Se falhar, dashboards ficam com dado de ontem — melhor do que dado errado |

## 10. Próximo Deploy

Deploy #5 (Dashboard): dashboard comercial em JSON versionado no bundle.
Cada widget é código, `git diff` mostra mudança, `git checkout` é rollback.
