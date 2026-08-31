-- gold -- 3 data marts sobre o mesmo fato_vendas.
--
-- Job: rotaperfume_pipeline -- tarefa gold_marts
-- Lado do prompt: 07-marts.sql
--
-- TODOS os marts sao CONFORMADOS: a soma de receita em qualquer um
-- deve ser igual a SUM(receita) FROM gold.fato_vendas = R$ 102.303.828,05.
-- Se divergir, alguma agregacao esta errada.
--
-- mart_vendas_por_vendedor: Diretoria Comercial. Grão: vendedor x mes.
-- mart_produto_performance:  Diretoria Produto.  Grão: SKU x mes + curva ABC.
-- mart_financeiro_recebimento: Diretoria Financeiro. Grão: mes de vencimento.

-- ===========================================================
-- PARTE A: gold.mart_vendas_por_vendedor
-- Diretoria: Comercial. Grão: vendedor × mês.
-- ===========================================================
CREATE OR REPLACE TABLE lakehouse_rotaperfume.gold.mart_vendas_por_vendedor AS
SELECT
  f.ano,
  f.mes,
  f.vendedor_id,
  v.nome                    AS vendedor_nome,
  v.regiao,
  v.ativo,
  v.meta_mensal,
  -- metricas de negocio
  ROUND(SUM(f.receita), 2) AS receita,
  ROUND(SUM(f.margem), 2)  AS margem,
  -- atingimento: meta_mensal é por MÊS, não por período acumulado.
  -- Meta mensal = R$ X por mês. Atingimento = receita do mes / meta_mensal.
  ROUND(100.0 * SUM(f.receita) / NULLIF(v.meta_mensal, 0), 1) AS atingimento_pct,
  COUNT(DISTINCT f.cliente_id)                                 AS clientes_atendidos,
  ROUND(SUM(f.receita) / NULLIF(COUNT(DISTINCT f.cliente_id), 0), 2)
                                                                  AS ticket_medio,
  -- auditoria
  current_timestamp()                                            AS _processado_em
FROM lakehouse_rotaperfume.gold.fato_vendas f
JOIN lakehouse_rotaperfume.silver.vendedores v
  ON v.vendedor_id = f.vendedor_id
GROUP BY f.ano, f.mes, f.vendedor_id, v.nome, v.regiao, v.ativo, v.meta_mensal;

COMMENT ON TABLE lakehouse_rotaperfume.gold.mart_vendas_por_vendedor IS
  'Gold - mart de vendas por vendedor. Diretoria Comercial. Grão: vendedor x mês. Receita, margem, atingimento%, ticket médio. Meta mensal = meta por mês (não acumulada). Conformado com fato_vendas.';

-- ===========================================================
-- PARTE B: gold.mart_produto_performance
-- Diretoria: Produto. Grão: SKU × mês.
-- Curva ABC por receita acumulada dentro de cada categoria/mes.
-- ===========================================================
CREATE OR REPLACE TABLE lakehouse_rotaperfume.gold.mart_produto_performance AS
WITH agregado AS (
  SELECT
    f.ano,
    f.mes,
    f.sku,
    pr.descricao,
    pr.categoria,
    pr.marca,
    f.preco_praticado,
    ROUND(SUM(f.receita), 2) AS receita,
    ROUND(SUM(f.margem), 2)  AS margem,
    ROUND(100.0 * SUM(f.margem) / NULLIF(SUM(f.receita), 0), 1) AS margem_pct,
    SUM(f.quantidade)         AS quantidade
  FROM lakehouse_rotaperfume.gold.fato_vendas f
  JOIN lakehouse_rotaperfume.silver.produtos pr
    ON pr.sku = f.sku
  GROUP BY f.ano, f.mes, f.sku, pr.descricao, pr.categoria, pr.marca, f.preco_praticado
),
com_abc AS (
  SELECT *,
    -- receita acumulada por categoria+mes, ordenada por receita desc
    SUM(receita) OVER (
      PARTITION BY ano, mes, categoria
      ORDER BY receita DESC
      ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS receita_acumulada,
    -- total da categoria no mes
    SUM(receita) OVER (
      PARTITION BY ano, mes, categoria
    ) AS total_categoria
  FROM agregado
)
SELECT
  ano,
  mes,
  sku,
  descricao,
  categoria,
  marca,
  preco_praticado,
  receita,
  margem,
  margem_pct,
  quantidade,
  -- curva ABC: A=80% superior, B=80-95%, C=5% inferior
  CASE
    WHEN receita_acumulada / NULLIF(total_categoria, 0) <= 0.80 THEN 'A'
    WHEN receita_acumulada / NULLIF(total_categoria, 0) <= 0.95 THEN 'B'
    ELSE 'C'
  END AS curva_abc,
  -- auditoria
  current_timestamp() AS _processado_em
FROM com_abc;

COMMENT ON TABLE lakehouse_rotaperfume.gold.mart_produto_performance IS
  'Gold - mart de performance de produtos. Diretoria Produto. Grão: SKU x mês. Receita, margem, quantidade, curva ABC por receita acumulada dentro de cada categoria+mês. Conformado com fato_vendas.';

-- ===========================================================
-- PARTE C: gold.mart_financeiro_recebimento
-- Diretoria: Financeiro. Grão: mes de vencimento.
-- Baseado em pagamentos, nao em pedidos.
-- ===========================================================
CREATE OR REPLACE TABLE lakehouse_rotaperfume.gold.mart_financeiro_recebimento AS
SELECT
  YEAR(pg.data_vencimento)                                    AS ano_vencimento,
  MONTH(pg.data_vencimento)                                   AS mes_vencimento,
  p.canal,
  pg.forma_pagamento,
  -- metricas
  ROUND(SUM(pg.valor), 2)                                  AS valor_a_receber,
  ROUND(SUM(pg.valor) FILTER (
    WHERE pg.data_pagamento IS NOT NULL), 2)                AS valor_recebido,
  ROUND(SUM(pg.valor) FILTER (
    WHERE pg.vencido), 2)                                   AS valor_vencido_nao_recebido,
  ROUND(AVG(pg.taxa_pct) FILTER (
    WHERE pg.data_pagamento IS NOT NULL), 3)                 AS taxa_media_paga,
  ROUND(AVG(DATEDIFF(pg.data_pagamento, pg.data_vencimento)) FILTER (
    WHERE pg.data_pagamento IS NOT NULL), 1)                 AS atraso_medio_dias,
  -- auditoria
  current_timestamp()                                          AS _processado_em
FROM lakehouse_rotaperfume.silver.pagamentos pg
JOIN lakehouse_rotaperfume.silver.pedidos p
  ON p.pedido_id = pg.pedido_id
WHERE NOT p.cancelado  -- mesma regra do fato: cancelado nao entra
GROUP BY YEAR(pg.data_vencimento), MONTH(pg.data_vencimento),
         p.canal, pg.forma_pagamento;

COMMENT ON TABLE lakehouse_rotaperfume.gold.mart_financeiro_recebimento IS
  'Gold - mart financeiro de recebimento. Diretoria Financeiro. Grão: mes de vencimento x canal x forma_pagamento. Valor a receber, recebido, vencido nao recebido, taxa media, atraso medio em dias.';
