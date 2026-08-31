-- silver.pedidos -- Tipagem, colunas derivadas, valor_liquido.
--
-- Job: rotaperfume_pipeline -- tarefa silver_02_pedidos
-- Lado do prompt: 02-pedidos.sql
--
-- REGRAS:
--  - data_pedido: coalesce de try_to_date (ISO + dd/MM/yyyy).
--    ANSI mode = LIGADO: to_date() ABORTA em data malformada.
--    3.443 datas estao em dd/MM/yyyy, 25.286 em ISO.
--  - valor_total: CAST para DECIMAL(18,2).
--  - cancelado: status = 'Cancelado' (BOOLEAN).
--  - valor_liquido: 0 se cancelado, valor_total caso contrario.
--    ATENCAO: 135 pedidos tem valor NEGATIVO (devolucao dentro do pedido).
--    Nao sao sujeira. Constraint NAO pode ser valor_liquido >= 0.
--    Constraint correta: NOT cancelado OR valor_liquido = 0.
--  - ano, mes: extraidos da data.
--
-- ANSI mode: try_to_date() SEMPRE, nao to_date().

CREATE OR REPLACE TABLE lakehouse_rotaperfume.silver.pedidos AS
SELECT
  CAST(pedido_id   AS STRING)                           AS pedido_id,
  CAST(cliente_id  AS STRING)                           AS cliente_id,
  CAST(vendedor_id AS STRING)                           AS vendedor_id,
  -- data: coalesce de ISO + BR
  coalesce(
    try_to_date(data_pedido, 'yyyy-MM-dd'),
    try_to_date(data_pedido, 'dd/MM/yyyy')
  )                                                     AS data_pedido,
  -- valor total em decimal
  CAST(TRY_CAST(valor_total AS DECIMAL(18,2)) AS DECIMAL(18,2)) AS valor_total,
  -- cancelado (boolean)
  (status = 'Cancelado')                              AS cancelado,
  -- valor liquido: zero se cancelado, valor_total caso contrario
  -- (135 pedidos tem valor negativo por devolucao dentro do pedido -- negocio legitimo)
  CASE
    WHEN status = 'Cancelado'
      THEN CAST(0.00 AS DECIMAL(18,2))
    ELSE CAST(TRY_CAST(valor_total AS DECIMAL(18,2)) AS DECIMAL(18,2))
  END                                                  AS valor_liquido,
  canal,
  status,
  -- extras: extrair de uma copia do date alias, para nao conflitar com a
  -- coluna string raw (que tem o mesmo nome). use coalesce como na data_pedido.
  year(coalesce(
    try_to_date(data_pedido, 'yyyy-MM-dd'),
    try_to_date(data_pedido, 'dd/MM/yyyy')
  ))                                                  AS ano,
  month(coalesce(
    try_to_date(data_pedido, 'yyyy-MM-dd'),
    try_to_date(data_pedido, 'dd/MM/yyyy')
  ))                                                  AS mes,
  -- auditoria
  current_timestamp()                                  AS _processado_em,
  COUNT(*) OVER ()                                     AS _linhas_origem
FROM lakehouse_rotaperfume.bronze.pedidos;

-- ===========================================================
-- CONTRATO (regra da tabela, nao do script)
-- ===========================================================
-- data_pedido nao pode ser nula
ALTER TABLE lakehouse_rotaperfume.silver.pedidos
  ADD CONSTRAINT pedidos_data_not_null CHECK (data_pedido IS NOT NULL);

-- Pedido cancelado deve ter valor_liquido = 0.
-- NAO usar >= 0 -- 135 pedidos tem valor negativo por devolucao legitima.
-- A regra: se cancelado, o valor_liquido TEM que ser zero.
ALTER TABLE lakehouse_rotaperfume.silver.pedidos
  ADD CONSTRAINT pedido_cancelado_zerado
  CHECK (NOT cancelado OR valor_liquido = CAST(0.00 AS DECIMAL(18,2)));

COMMENT ON TABLE lakehouse_rotaperfume.silver.pedidos IS
  'Silver ERP - pedidos. Datas tipadas com coalesce (ISO + BR), valor_total e valor_liquido em DECIMAL(18,2), cancelado BOOLEAN. valor_liquido = 0 quando cancelado, valor_total caso contrario. Constraint: pedido cancelado -> valor_liquido = 0. NOTA: 135 pedidos com valor_liquido negativo sao devolucoes legitimas, nao sujeira.';
