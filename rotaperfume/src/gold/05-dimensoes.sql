-- gold -- 4 dimensoes conformadas: dim_cliente, dim_produto, dim_vendedor, dim_calendario.
--
-- Job: rotaperfume_pipeline -- tarefa gold_dimensoes
-- Lado do prompt: 05-dimensoes.sql
--
-- REGRAS COMUNS:
--  - 4 dimensoes, cada uma com seu grão.
--  - dim_cliente: 1 linha por cliente (189 sem pedido, 2811 com pedido).
--    LEFT JOIN pedidos: clientes que nunca compraram permanecem na dimensao
--    com receita_acumulada=0, dias_desde_ultima_compra=NULL.
--  - dim_calendario: 1 linha por DIA entre min(data_pedido) e max(data_pedido).
--    explode(sequence(...)) gera 730 linhas (2024-09-01 a 2026-08-31).
--  - mes_pico_setor: abril, junho, outubro = TRUE (perfumaria oriental).
--    Nao e regra de negocio do cliente -- e contexto do SETOR.
--
-- ANSI mode: tudo DATE, sem cast malicioso.

-- ===========================================================
-- PARTE A: gold.dim_cliente
-- ===========================================================
CREATE OR REPLACE TABLE lakehouse_rotaperfume.gold.dim_cliente AS
SELECT
  c.cliente_id,
  c.cnpj,
  c.razao_social,
  c.segmento,
  c.cidade,
  c.uf,
  c.ativo,
  c.data_cadastro,
  MIN(p.data_pedido)                                    AS primeiro_pedido,
  MAX(p.data_pedido)                                    AS ultimo_pedido,
  COUNT(DISTINCT p.pedido_id)                            AS total_pedidos,
  -- receita_acumulada: soma de TODOS os pedidos nao cancelados do cliente
  -- 189 clientes (sem pedido) ficam com NULL aqui -- sinaliza "nunca comprou".
  ROUND(SUM(i.quantidade * i.preco_praticado), 2)       AS receita_acumulada,
  -- dias_desde_ultima_compra: NULL para quem nunca comprou. IS NOT NULL distingue.
  DATEDIFF(CURRENT_DATE, MAX(p.data_pedido))             AS dias_desde_ultima_compra,
  -- auditoria
  current_timestamp()                                     AS _processado_em
FROM lakehouse_rotaperfume.silver.clientes c
LEFT JOIN lakehouse_rotaperfume.silver.pedidos p
  ON p.cliente_id = c.cliente_id
LEFT JOIN lakehouse_rotaperfume.silver.itens_pedido i
  ON i.pedido_id = p.pedido_id
  AND NOT p.cancelado
GROUP BY c.cliente_id, c.cnpj, c.razao_social, c.segmento, c.cidade, c.uf,
         c.ativo, c.data_cadastro;

ALTER TABLE lakehouse_rotaperfume.gold.dim_cliente
  ADD CONSTRAINT dimcliente_id_not_null CHECK (cliente_id IS NOT NULL);

COMMENT ON TABLE lakehouse_rotaperfume.gold.dim_cliente IS
  'Gold - dimensao de clientes. 1 linha por cliente (3.000 totais; 189 sem pedido). receita_acumulada: soma de todos os itens de pedidos nao cancelados. dias_desde_ultima_compra: NULL quando nunca comprou. Granularidade: cliente.';


-- ===========================================================
-- PARTE B: gold.dim_produto
-- ===========================================================
CREATE OR REPLACE TABLE lakehouse_rotaperfume.gold.dim_produto AS
SELECT
  sku,
  descricao,
  categoria,
  marca,
  nota_olfativa,
  custo_unitario,
  preco_tabela,
  data_lancamento,
  ativo,
  -- descontinuado: NAO esta mais ativo (NAO precisa join -- eh o proprio campo)
  NOT ativo                                              AS descontinuado,
  -- auditoria
  current_timestamp()                                     AS _processado_em
FROM lakehouse_rotaperfume.silver.produtos;

ALTER TABLE lakehouse_rotaperfume.gold.dim_produto
  ADD CONSTRAINT dimproduto_sku_not_null CHECK (sku IS NOT NULL);

COMMENT ON TABLE lakehouse_rotaperfume.gold.dim_produto IS
  'Gold - dimensao de produtos. 1 linha por SKU (292 totais; 290 com item em pedido). descontinuado = NOT ativo. Granularidade: SKU.';


-- ===========================================================
-- PARTE C: gold.dim_vendedor
-- ===========================================================
CREATE OR REPLACE TABLE lakehouse_rotaperfume.gold.dim_vendedor AS
SELECT
  vendedor_id,
  nome,
  regiao,
  uf,
  data_admissao,
  data_desligamento,
  ativo,
  meta_mensal,
  -- auditoria
  current_timestamp()                                     AS _processado_em
FROM lakehouse_rotaperfume.silver.vendedores;

ALTER TABLE lakehouse_rotaperfume.gold.dim_vendedor
  ADD CONSTRAINT dimvendedor_id_not_null CHECK (vendedor_id IS NOT NULL);

COMMENT ON TABLE lakehouse_rotaperfume.gold.dim_vendedor IS
  'Gold - dimensao de vendedores. 1 linha por vendedor (42 totais; 6 desligados). meta_mensal em DECIMAL(18,2). Granularidade: vendedor.';


-- ===========================================================
-- PARTE D: gold.dim_calendario
-- ===========================================================
CREATE OR REPLACE TABLE lakehouse_rotaperfume.gold.dim_calendario AS
WITH dias AS (
  -- 730 dias (2024-09-01 ate 2026-08-31 = 24 meses, 730 dias)
  SELECT explode(sequence(
    CAST('2024-09-01' AS DATE),
    CAST('2026-08-31' AS DATE)
  )) AS data
)
SELECT
  CAST(data AS DATE)                                      AS data,
  year(data)                                              AS ano,
  month(data)                                             AS mes,
  date_format(data, 'MMMM')                               AS nome_mes,
  quarter(data)                                            AS trimestre,
  date_format(data, 'EEEE')                               AS dia_semana,
  -- abril, junho e outubro = TRUE (pico do setor de perfumaria oriental)
  CASE WHEN month(data) IN (4, 6, 10) THEN TRUE
       ELSE FALSE END                                     AS mes_pico_setor,
  -- auditoria
  current_timestamp()                                      AS _processado_em
FROM dias;

ALTER TABLE lakehouse_rotaperfume.gold.dim_calendario
  ADD CONSTRAINT dimcalendario_data_not_null CHECK (data IS NOT NULL);

COMMENT ON TABLE lakehouse_rotaperfume.gold.dim_calendario IS
  'Gold - dimensao calendario. 1 linha por DIA (730 linhas, 24 meses). mes_pico_setor: abril, junho, outubro = TRUE (contexto do SETOR, nao regra do cliente). Granularidade: dia.';
