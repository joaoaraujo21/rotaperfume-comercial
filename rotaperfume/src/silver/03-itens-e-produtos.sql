-- silver.produtos + silver.itens_pedido -- Tipagem, devolucao, join com produtos.
--
-- Job: rotaperfume_pipeline -- tarefa silver_03_itens_produtos
-- Lado do prompt: 03-itens-e-produtos.sql
--
-- PARTE A: produtos
--  - ativo: 'S'/'N' -> BOOLEAN.
--  - data_lancamento: try_to_date (245 produtos tem campo vazio -> NULL).
--  - precos: DECIMAL(18,2).
--
-- PARTE B: itens_pedido
--  - quantidade: INT.
--  - quantidade negativa = DEVOLUCAO, nao erro. Flag devolucao BOOLEAN,
--    e quantidade_abs = ABS(quantidade). NAO descartar linhas.
--  - preco_praticado, desconto_pct, valor_bruto: DECIMAL.
--  - join com produtos: sku_descontinuado = NOT produto.ativo.
--  - Constraint: quantidade_abs > 0 (apos ABS isso e sempre true, mas
--    garante que nunca vem zero).
--
-- ANSI mode: try_to_date() em toda conversao de data.

-- ===========================================================
-- PARTE A: silver.produtos
-- ===========================================================
CREATE OR REPLACE TABLE lakehouse_rotaperfume.silver.produtos AS
SELECT
  CAST(sku          AS STRING)                            AS sku,
  descricao,
  categoria,
  marca,
  nota_olfativa,
  CAST(TRY_CAST(preco_tabela   AS DECIMAL(18,2)) AS DECIMAL(18,2)) AS preco_tabela,
  CAST(TRY_CAST(custo_unitario AS DECIMAL(18,2)) AS DECIMAL(18,2)) AS custo_unitario,
  unidade,
  (ativo = 'S')                                          AS ativo,
  -- data_lancamento: 245 produtos tem campo vazio (string ""). try_to_date
  -- devolve NULL em string vazia -- o que esta correto: esses 245 NAO tem
  -- data de lancamento. Nao abortar a query.
  try_to_date(data_lancamento, 'yyyy-MM-dd')             AS data_lancamento,
  current_timestamp()                                    AS _processado_em,
  COUNT(*) OVER ()                                       AS _linhas_origem
FROM lakehouse_rotaperfume.bronze.produtos;

ALTER TABLE lakehouse_rotaperfume.silver.produtos
  ADD CONSTRAINT produtos_sku_not_null CHECK (sku IS NOT NULL);

COMMENT ON TABLE lakehouse_rotaperfume.silver.produtos IS
  'Silver ERP - produtos. ativo em BOOLEAN, precos em DECIMAL(18,2). data_lancamento: 245 produtos sem data -> NULL (nao e erro, e ausencia).';


-- ===========================================================
-- PARTE B: silver.itens_pedido
-- ===========================================================
CREATE OR REPLACE TABLE lakehouse_rotaperfume.silver.itens_pedido AS
SELECT
  CAST(i.item_id           AS STRING)                            AS item_id,
  CAST(i.pedido_id         AS STRING)                            AS pedido_id,
  CAST(i.sku               AS STRING)                            AS sku,
  CAST(TRY_CAST(i.quantidade AS INT) AS INT)                      AS quantidade,
  -- flag devolucao: quantidade < 0
  (CAST(TRY_CAST(i.quantidade AS INT) AS INT) < 0)              AS devolucao,
  -- valor absoluto -- mantem todas as linhas (NAO descarta devolucao)
  ABS(CAST(TRY_CAST(i.quantidade AS INT) AS INT))                 AS quantidade_abs,
  CAST(TRY_CAST(i.preco_praticado AS DECIMAL(18,2)) AS DECIMAL(18,2)) AS preco_praticado,
  CAST(TRY_CAST(i.desconto_pct    AS DECIMAL(5,2))  AS DECIMAL(5,2))  AS desconto_pct,
  CAST(TRY_CAST(i.valor_bruto     AS DECIMAL(18,2)) AS DECIMAL(18,2)) AS valor_bruto,
  -- sku_descontinuado: produto nao esta mais ativo
  COALESCE(NOT p.ativo, FALSE)                                  AS sku_descontinuado,
  -- auditoria
  current_timestamp()                                            AS _processado_em,
  COUNT(*) OVER ()                                               AS _linhas_origem
FROM lakehouse_rotaperfume.bronze.itens_pedido i
LEFT JOIN lakehouse_rotaperfume.silver.produtos p
  ON i.sku = p.sku;

-- Constraint: quantidade_abs > 0. Como eh ABS(), o valor nunca eh 0
-- (a menos que a fonte tenha 0, que e um bug). Esta constraint pega isso.
ALTER TABLE lakehouse_rotaperfume.silver.itens_pedido
  ADD CONSTRAINT itens_qtd_abs_positiva CHECK (quantidade_abs > 0);

COMMENT ON TABLE lakehouse_rotaperfume.silver.itens_pedido IS
  'Silver ERP - itens de pedido. Quantidade negativa = DEVOLUCAO (flag devolucao BOOLEAN, quantidade_abs INT). Linhas de devolucao NAO sao descartadas -- negocio legitimo (2.327 registros). Join com silver.produtos para flag sku_descontinuado. Decisao: devolver e sinalizar > descartar (mantem rastreabilidade).';
