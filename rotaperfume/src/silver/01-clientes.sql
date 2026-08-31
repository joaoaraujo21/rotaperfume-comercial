-- silver.clientes -- Deduplicacao por CNPJ, normalizacao, tipagem.
--
-- Job: rotaperfume_pipeline -- tarefa silver_01_clientes
-- Lado do prompt: 01-clientes.sql
--
-- REGRAS:
--  - CNPJ: trim, depois regexp_replace tirando nao-digito, depois lpad 14.
--    NUNCA converter CNPJ para numero (perde zero a esquerda).
--  - razao_social: initcap + colapsa espacos duplos.
--  - data_cadastro: coalesce de try_to_date (ISO e dd/MM/yyyy).
--  - ativo: 'S'/'N' -> BOOLEAN.
--  - Deduplicacao: row_number() por cnpj_limpo, mantem o mais ANTIGO.
--    Guarda cliente_ids_duplicados (array) para que pedidos antigos
--    que apontam para o id descartado continuem rastreaveis.
--
-- ANSI mode esta LIGADO no workspace: try_to_date() em vez de to_date().
-- Data malformada ABORTA a query se usar to_date() direto.
--
-- Constraint: cnpj com exatamente 14 digitos; data_cadastro nao nula.

CREATE OR REPLACE TABLE lakehouse_rotaperfume.silver.clientes AS
WITH normalizado AS (
  SELECT
    CAST(cliente_id AS STRING)  AS cliente_id,
    cnpj,
    razao_social,
    segmento,
    cidade,
    uf,
    bairro,
    data_cadastro,
    ativo,
    -- CNPJ limpo -> 14 digitos com zeros a esquerda
    lpad(regexp_replace(trim(cnpj), '[^0-9]', ''), 14, '0')            AS cnpj_limpo,
    -- razao social -> initcap + colapsa espacos duplos
    regexp_replace(initcap(trim(razao_social)), '  +', ' ')              AS razao_social_limpa,
    -- data -> tenta ISO, depois BR
    coalesce(
      try_to_date(data_cadastro, 'yyyy-MM-dd'),
      try_to_date(data_cadastro, 'dd/MM/yyyy')
    )                                                                   AS data_cadastro_dt,
    -- ativo -> boolean
    (ativo = 'S')                                                       AS ativo_bool
  FROM lakehouse_rotaperfume.bronze.clientes
),
com_ordem AS (
  SELECT
    cliente_id,
    cnpj_limpo,
    razao_social_limpa,
    segmento,
    cidade,
    uf,
    bairro,
    data_cadastro_dt,
    ativo_bool,
    -- row_number por cnpj_limpo, ordem: mais antigo primeiro
    row_number() OVER (
      PARTITION BY cnpj_limpo
      ORDER BY data_cadastro_dt ASC, cliente_id ASC
    )                                                                   AS ordem,
    -- todos os ids do mesmo cnpj (para guardar no array)
    collect_list(cliente_id) OVER (PARTITION BY cnpj_limpo)              AS todos_ids
  FROM normalizado
)
SELECT
  cliente_id,
  cnpj_limpo                                       AS cnpj,
  razao_social_limpa                                AS razao_social,
  segmento,
  cidade,
  uf,
  bairro,
  data_cadastro_dt                                 AS data_cadastro,
  ativo_bool                                       AS ativo,
  -- ids descartados (exclui o que ficou como cliente_id principal)
  array_except(todos_ids, array(cliente_id))       AS cliente_ids_duplicados,
  -- auditoria
  current_timestamp()                              AS _processado_em,
  COUNT(*) OVER ()                                 AS _linhas_origem
FROM com_ordem
WHERE ordem = 1;

-- ===========================================================
-- CONTRATO (regra da tabela, nao do script)
-- ===========================================================
ALTER TABLE lakehouse_rotaperfume.silver.clientes
  ADD CONSTRAINT clientes_cnpj_14      CHECK (length(cnpj) = 14);

ALTER TABLE lakehouse_rotaperfume.silver.clientes
  ADD CONSTRAINT clientes_data_not_null CHECK (data_cadastro IS NOT NULL);

COMMENT ON TABLE lakehouse_rotaperfume.silver.clientes IS
  'Silver CRM - clientes. Deduplicado por CNPJ (40 duplicados removidos -> 3.000 finais). CNPJ normalizado para 14 digitos, razao_social em initcap, data_cadastro em DATE, ativo em BOOLEAN. cliente_ids_duplicados guarda os ids descartados para rastreabilidade (pedidos antigos continuam apontando para eles).';
