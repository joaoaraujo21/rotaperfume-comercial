-- silver -- CRM e Financeiro: vendedores, carteira, oportunidades, visitas, pagamentos, estoque.
--
-- Job: rotaperfume_pipeline -- tarefa silver_04_crm_financeiro
-- Lado do prompt: 04-crm-e-financeiro.sql
--
-- REGRAS POR TABELA:
--  vendedores:
--    - data_admissao: try_to_date ISO (todas as 42 datas sao ISO, 0 vazias).
--    - data_desligamento: try_to_date ISO (36 vazias = ativo; 6 desligados).
--    - ativo: data_desligamento IS NULL.
--  carteira:
--    - vigente: data_inicio <= hoje E (data_fim IS NULL OR data_fim >= hoje)
--      + join com silver.vendedores para excluir se vendedor esta desligado.
--    - orfao_vendedor_desligado: o vendedor da carteira esta desligado E a
--      carteira teoricamente segue vigente (data_fim vazia e dentro do periodo).
--      NAO conserta -- EXPÕE o problema para o gestor.
--  oportunidades:
--    - etapa em portugues: 'Fechado ganho'->'ganha', 'Fechado perdido'->'perdida'.
--      Confirmed: 'Fechado ganho','Negociação','Proposta enviada','Qualificação',
--      'Prospecção','Fechado perdido' (0 em 'Ganha'/'Perdida' no bronze).
--    - data_abertura: DATE. data_fechamento: NULL quando nao fechada (3719/5979).
--  visitas:
--    - data_visita: DATE. duracao_min: INT.
--  pagamentos:
--    - valor, valor_liquido, taxa_pct: DECIMAL.
--    - data_vencimento: DATE. data_pagamento: NULL quando nao pago (1865/27772).
--    - vencido: data_vencimento < hoje E data_pagamento IS NULL.
--  estoque:
--    - saldo: DECIMAL. ruptura: saldo = 0.
--
-- ANSI mode: try_to_date() em toda conversao de data.
-- Todas as datas nas tabelas bronze sao ISO (verificado: 0 datas BR nos 6 CSVs).

-- ===========================================================
-- PARTE A: silver.vendedores
-- ===========================================================
CREATE OR REPLACE TABLE lakehouse_rotaperfume.silver.vendedores AS
SELECT
  CAST(vendedor_id       AS STRING)                                   AS vendedor_id,
  nome,
  regiao,
  uf,
  -- 36 ativos (data_desligamento vazia), 6 desligados
  try_to_date(data_admissao, 'yyyy-MM-dd')                           AS data_admissao,
  -- NULL = ativo (36). Nao usar COALESCE: os 6 desligados tem data.
  try_to_date(data_desligamento, 'yyyy-MM-dd')                       AS data_desligamento,
  -- ativo: NULL em data_desligamento = vendedor ativo
  (try_to_date(data_desligamento, 'yyyy-MM-dd') IS NULL)            AS ativo,
  CAST(TRY_CAST(meta_mensal AS DECIMAL(18,2)) AS DECIMAL(18,2))     AS meta_mensal,
  -- auditoria
  current_timestamp()                                                  AS _processado_em,
  COUNT(*) OVER ()                                                    AS _linhas_origem
FROM lakehouse_rotaperfume.bronze.vendedores;

ALTER TABLE lakehouse_rotaperfume.silver.vendedores
  ADD CONSTRAINT vendedores_admissao_not_null
  CHECK (data_admissao IS NOT NULL);

COMMENT ON TABLE lakehouse_rotaperfume.silver.vendedores IS
  'Silver CRM - vendedores. 6 vendedores desligados (data_desligamento nao-nula), 36 ativos. ativo BOOLEAN. data_admissao e data_desligamento em DATE. meta_mensal em DECIMAL(18,2). Nao ha CNPJ nem nome social nesta tabela (sao pessoas fisicas).';


-- ===========================================================
-- PARTE B: silver.carteira
-- ===========================================================
CREATE OR REPLACE TABLE lakehouse_rotaperfume.silver.carteira AS
SELECT
  CAST(carteira_id              AS STRING)                                       AS carteira_id,
  CAST(cliente_id               AS STRING)                                       AS cliente_id,
  CAST(c.vendedor_id            AS STRING)                                       AS vendedor_id,
  -- datas em DATE
  try_to_date(data_inicio, 'yyyy-MM-dd')                            AS data_inicio,
  try_to_date(data_fim,    'yyyy-MM-dd')                            AS data_fim,
  -- vigente: inicio <= hoje E (fim IS NULL OR fim >= hoje) E vendedor ativo
  -- Left join com vendedores para detectar desligamento.
  -- 3000 carteiras tem data_fim vazia (vigente por definicao de periodo).
  (  try_to_date(data_inicio, 'yyyy-MM-dd') <= CURRENT_DATE
  AND (try_to_date(data_fim, 'yyyy-MM-dd') IS NULL
       OR try_to_date(data_fim, 'yyyy-MM-dd') >= CURRENT_DATE)
  AND COALESCE(v.ativo, TRUE)                                        -- left join: se nulo, ativo=true
  )                                                                  AS vigente,
  -- orfao: vendedor desligado E carteira seria vigente (sem considerar desligamento).
  -- Isso EXPÕE o problema ao gestor, nao o conserta.
  (  COALESCE(v.ativo, TRUE) = FALSE
  AND (  try_to_date(data_inicio, 'yyyy-MM-dd') <= CURRENT_DATE
     AND (try_to_date(data_fim, 'yyyy-MM-dd') IS NULL
          OR try_to_date(data_fim, 'yyyy-MM-dd') >= CURRENT_DATE))
  )                                                                  AS orfao_vendedor_desligado,
  -- auditoria
  current_timestamp()                                                  AS _processado_em,
  COUNT(*) OVER ()                                                    AS _linhas_origem
FROM lakehouse_rotaperfume.bronze.carteira c
LEFT JOIN lakehouse_rotaperfume.silver.vendedores v
  ON c.vendedor_id = v.vendedor_id;

ALTER TABLE lakehouse_rotaperfume.silver.carteira
  ADD CONSTRAINT carteira_cliente_not_null CHECK (cliente_id IS NOT NULL);

COMMENT ON TABLE lakehouse_rotaperfume.silver.carteira IS
  'Silver CRM - carteira de clientes por vendedor. vigente = periodo valido (inicio <= hoje <= fim) E vendedor ativo. orfao_vendedor_desligado = vendedor ja desligado mas a carteira continua vigente no sistema (441 registros). Decisao: EXPOR, nao corrigir automaticamente. data_inicio e data_fim em DATE.';


-- ===========================================================
-- PARTE C: silver.oportunidades
-- ===========================================================
CREATE OR REPLACE TABLE lakehouse_rotaperfume.silver.oportunidades AS
SELECT
  CAST(oportunidade_id      AS STRING)                                       AS oportunidade_id,
  CAST(cliente_id           AS STRING)                                       AS cliente_id,
  CAST(vendedor_id          AS STRING)                                       AS vendedor_id,
  origem,
  -- etapa: normalizar 'Fechado ganho'/'Fechado perdido' para 'ganha'/'perdida'
  -- (NUNCA 'Ganha' ou 'Perdida' -- confirmado: 0 registros no bronze.)
  CASE etapa
    WHEN 'Fechado ganho'   THEN 'ganha'
    WHEN 'Fechado perdido' THEN 'perdida'
    ELSE etapa
  END                                                                      AS etapa,
  try_to_date(data_abertura, 'yyyy-MM-dd')                                 AS data_abertura,
  CAST(TRY_CAST(probabilidade_pct AS DECIMAL(5,2)) AS DECIMAL(5,2))       AS probabilidade_pct,
  CAST(TRY_CAST(valor_estimado    AS DECIMAL(18,2)) AS DECIMAL(18,2))     AS valor_estimado,
  -- data_fechamento: NULL quando nao fechada (3719/5979 nao fechadas)
  try_to_date(data_fechamento, 'yyyy-MM-dd')                               AS data_fechamento,
  CAST(TRY_CAST(ciclo_dias AS INT) AS INT)                                  AS ciclo_dias,
  motivo_perda,
  -- auditoria
  current_timestamp()                                                        AS _processado_em,
  COUNT(*) OVER ()                                                          AS _linhas_origem
FROM lakehouse_rotaperfume.bronze.oportunidades;

ALTER TABLE lakehouse_rotaperfume.silver.oportunidades
  ADD CONSTRAINT oportunidades_id_not_null CHECK (oportunidade_id IS NOT NULL);

COMMENT ON TABLE lakehouse_rotaperfume.silver.oportunidades IS
  'Silver CRM - oportunidades. etapa: ''Fechado ganho''->''ganha'', ''Fechado perdido''->''perdida''. data_fechamento: NULL quando nao fechada (3.719 de 5.979). valor_estimado e probabilidade_pct em DECIMAL. ciclo_dias em INT.';


-- ===========================================================
-- PARTE D: silver.visitas
-- ===========================================================
CREATE OR REPLACE TABLE lakehouse_rotaperfume.silver.visitas AS
SELECT
  CAST(visita_id    AS STRING)                                       AS visita_id,
  CAST(cliente_id   AS STRING)                                       AS cliente_id,
  CAST(vendedor_id  AS STRING)                                       AS vendedor_id,
  -- datas em DATE (todas ISO, verificado: 0 BR)
  try_to_date(data_visita, 'yyyy-MM-dd')                             AS data_visita,
  resultado,
  -- duracao em minutos: INT (string -> INT)
  CAST(TRY_CAST(duracao_min AS INT) AS INT)                          AS duracao_min,
  -- auditoria
  current_timestamp()                                                  AS _processado_em,
  COUNT(*) OVER ()                                                    AS _linhas_origem
FROM lakehouse_rotaperfume.bronze.visitas;

ALTER TABLE lakehouse_rotaperfume.silver.visitas
  ADD CONSTRAINT visitas_data_not_null CHECK (data_visita IS NOT NULL);

COMMENT ON TABLE lakehouse_rotaperfume.silver.visitas IS
  'Silver CRM - visitas comerciais. data_visita em DATE, duracao_min em INT. 37.936 visitas registradas. Todas as datas em formato ISO.';


-- ===========================================================
-- PARTE E: silver.pagamentos
-- ===========================================================
CREATE OR REPLACE TABLE lakehouse_rotaperfume.silver.pagamentos AS
SELECT
  CAST(pagamento_id        AS STRING)                                        AS pagamento_id,
  CAST(pedido_id           AS STRING)                                        AS pedido_id,
  forma_pagamento,
  CAST(TRY_CAST(parcelas       AS INT)   AS INT)                            AS parcelas,
  CAST(TRY_CAST(valor          AS DECIMAL(18,2)) AS DECIMAL(18,2))           AS valor,
  CAST(TRY_CAST(taxa_pct       AS DECIMAL(5,2))  AS DECIMAL(5,2))           AS taxa_pct,
  CAST(TRY_CAST(valor_liquido   AS DECIMAL(18,2)) AS DECIMAL(18,2))         AS valor_liquido,
  -- datas em DATE
  try_to_date(data_vencimento, 'yyyy-MM-dd')                                AS data_vencimento,
  -- data_pagamento: NULL quando nao pago (1.865 de 27.772)
  try_to_date(data_pagamento, 'yyyy-MM-dd')                                  AS data_pagamento,
  status_pagamento,
  -- vencido: vencimento no passado E ainda nao pago
  (  try_to_date(data_vencimento, 'yyyy-MM-dd') < CURRENT_DATE
  AND try_to_date(data_pagamento, 'yyyy-MM-dd') IS NULL)                   AS vencido,
  -- auditoria
  current_timestamp()                                                         AS _processado_em,
  COUNT(*) OVER ()                                                           AS _linhas_origem
FROM lakehouse_rotaperfume.bronze.pagamentos;

ALTER TABLE lakehouse_rotaperfume.silver.pagamentos
  ADD CONSTRAINT pagamentos_id_not_null CHECK (pagamento_id IS NOT NULL);

COMMENT ON TABLE lakehouse_rotaperfume.silver.pagamentos IS
  'Silver Financeiro - pagamentos. valor e valor_liquido em DECIMAL(18,2). data_pagamento: NULL quando nao quitado (1.865 de 27.772). vencido = vencimento < hoje E data_pagamento IS NULL. taxa_pct em DECIMAL(5,2). Parcelas em INT.';


-- ===========================================================
-- PARTE F: silver.estoque
-- ===========================================================
CREATE OR REPLACE TABLE lakehouse_rotaperfume.silver.estoque AS
SELECT
  -- data_snapshot: quando o snapshot foi tirado
  try_to_date(data_snapshot, 'yyyy-MM-dd')                                  AS data_snapshot,
  CAST(sku AS STRING)                                                       AS sku,
  -- saldo: DECIMAL (pode ser fracionado)
  CAST(TRY_CAST(saldo AS DECIMAL(18,4)) AS DECIMAL(18,4))                  AS saldo,
  -- ruptura: saldo = 0 (boolean)
  (CAST(TRY_CAST(saldo AS DECIMAL(18,4)) AS DECIMAL(18,4)) = 0.0)         AS ruptura,
  -- auditoria
  current_timestamp()                                                        AS _processado_em,
  COUNT(*) OVER ()                                                          AS _linhas_origem
FROM lakehouse_rotaperfume.bronze.estoque;

ALTER TABLE lakehouse_rotaperfume.silver.estoque
  ADD CONSTRAINT estoque_sku_not_null    CHECK (sku IS NOT NULL);

ALTER TABLE lakehouse_rotaperfume.silver.estoque
  ADD CONSTRAINT estoque_snapshot_not_null CHECK (data_snapshot IS NOT NULL);

COMMENT ON TABLE lakehouse_rotaperfume.silver.estoque IS
  'Silver ERP - estoque. ruptura BOOLEAN = saldo = 0. saldo em DECIMAL(18,4) para permitir quantidades fracionadas (litros, kg). data_snapshot indica a data do snapshot (nao ha coluna id/timestamp).';
