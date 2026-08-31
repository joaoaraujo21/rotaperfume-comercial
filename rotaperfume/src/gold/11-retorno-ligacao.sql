-- gold.retorno_ligacao -- O caminho de volta.
--
-- Job: rotaperfume_pipeline -- tarefa gold_retorno_ligacao
--
-- Entregas:
--   1. gold.clientes_em_risco     -- view: clientes fora do ritmo
--   2. gold.ranking_marcas         -- view: ranking de marcas por receita
--   3. gold.receita_mensal        -- view: receita por ano/mes
--   4. gold.retorno_ligacao       -- tabela: o que aconteceu depois da ligacao
--
-- ORDEM:
--   1. Views primeiro -- o Genie da Direcao as referencia
--   2. Tabela por ultimo -- CREATE TABLE IF NOT EXISTS (nao OR REPLACE)
--   3. COMMENT em toda coluna e na tabela
--   4. 2 testes com raise_error
--
-- IMPORTANTE:
--   retorno_ligacao usa CREATE TABLE IF NOT EXISTS -- a UNICA tabela do
--   projeto cujo dado NAO vem do pipeline. O time registra aqui. Um redeploy
--   NAO pode apagar o que o vendedor respondeu.

-- ===========================================================
-- PARTE 1: 3 views auxiliares para o Genie da Direcao
-- ===========================================================

-- gold.clientes_em_risco
-- Clientes fora do ritmo de compra ou com score baixo.
-- Clientes_em_risco = score na faixa Fria OU atraso_relativo > 2.
CREATE OR REPLACE VIEW lakehouse_rotaperfume.gold.clientes_em_risco AS
SELECT
    c.cliente_id,
    c.razao_social,
    c.cidade,
    c.uf,
    s.score,
    s.faixa,
    f.atraso_relativo,
    f.valor_total,
    f.recencia_dias,
    f.intervalo_medio_dias
FROM lakehouse_rotaperfume.gold.score_propensao s
INNER JOIN lakehouse_rotaperfume.gold.dim_cliente c
        ON c.cliente_id = s.cliente_id
LEFT JOIN lakehouse_rotaperfume.gold.features_cliente f
        ON f.cliente_id = s.cliente_id
WHERE s.faixa = 'Fria'
   OR f.atraso_relativo > 2.0
   OR f.atraso_relativo IS NULL;

COMMENT ON VIEW lakehouse_rotaperfume.gold.clientes_em_risco IS
  'Clientes fora do ritmo de compra: score na faixa Fria ou atraso_relativo > 2. Usado pelo Genie da Direcao para perguntas sobre clientes em risco.';

-- gold.ranking_marcas
-- Ranking de marcas por receita total no periodo do dataset.
CREATE OR REPLACE VIEW lakehouse_rotaperfume.gold.ranking_marcas AS
SELECT
    marca,
    ROUND(SUM(receita), 2)             AS receita_total,
    ROUND(SUM(margem), 2)              AS margem_total,
    ROUND(100.0 * SUM(margem) / NULLIF(SUM(receita), 0), 1) AS margem_pct,
    COUNT(DISTINCT cliente_id)           AS clientes_unicos,
    COUNT(DISTINCT sku)                  AS skus_vendidos,
    SUM(quantidade)                     AS quantidade_total,
    RANK() OVER (ORDER BY SUM(receita) DESC) AS posicao
FROM lakehouse_rotaperfume.gold.fato_vendas
WHERE devolucao = false
GROUP BY marca;

COMMENT ON VIEW lakehouse_rotaperfume.gold.ranking_marcas IS
  'Ranking de marcas por receita total. Posicao = RANK() sobre receita. Usado pelo Genie da Direcao para perguntas sobre performance de marcas.';

-- gold.receita_mensal
-- Receita agregada por ano e mes -- para perguntas de sazonalidade.
-- Sazonalidade INVERTIDA: o pico de vendas e o mes ANTERIOR a data
-- comemorativa (ex: natal -> dezembro, mas compra em novembro).
CREATE OR REPLACE VIEW lakehouse_rotaperfume.gold.receita_mensal AS
SELECT
    ano,
    mes,
    ROUND(SUM(receita), 2)             AS receita,
    ROUND(SUM(margem), 2)              AS margem,
    ROUND(100.0 * SUM(margem) / NULLIF(SUM(receita), 0), 1) AS margem_pct,
    COUNT(DISTINCT cliente_id)           AS clientes_unicos,
    COUNT(DISTINCT data_pedido)          AS dias_com_venda
FROM lakehouse_rotaperfume.gold.fato_vendas
GROUP BY ano, mes;

COMMENT ON VIEW lakehouse_rotaperfume.gold.receita_mensal IS
  'Receita por ano e mes. Sazonalidade INVERTIDA: o pico de vendas da perfumaria ocorre no mes ANTERIOR a data comemorativa. Usado pelo Genie da Direcao para perguntas de sazonalidade.';

-- ===========================================================
-- PARTE 2: gold.retorno_ligacao
-- A tabela do caminho de volta -- dado vem do TIME, nao do pipeline.
-- CREATE TABLE IF NOT EXISTS preserva os dados em redeploy.
-- ===========================================================

CREATE TABLE IF NOT EXISTS lakehouse_rotaperfume.gold.retorno_ligacao (
    cliente_id     INT          COMMENT 'Identificador do cliente.',
    vendedor       STRING       COMMENT 'Nome do vendedor responsavel pela ligacao.',
    status         STRING       COMMENT 'vendeu | vai_pensar | sem_interesse | nao_atendeu.',
    comentario     STRING       COMMENT 'Texto livre do vendedor sobre o resultado da ligacao.',
    registrado_em  TIMESTAMP    COMMENT 'Data e hora em que o registro foi feito.',
    registrado_por STRING       COMMENT 'E-mail de quem estava logado ao registrar.',
    _referencia    DATE         COMMENT 'Semana da fila que gerou esta ligacao.'
)
COMMENT 'Caminho de volta: registro do resultado de cada ligacao. Dado vem do TIME, nao do pipeline. CREATE IF NOT EXISTS preserva os registros em redeploy.';

-- ===========================================================
-- PARTE 3: COMMENT em cada coluna (saveAsTable nao grava COMMENT)
-- ===========================================================
COMMENT ON TABLE lakehouse_rotaperfume.gold.retorno_ligacao IS
  'Caminho de volta: registro do resultado de cada ligacao da fila_semanal. Dado vem do TIME, nao do pipeline. CREATE IF NOT EXISTS preserva os registros em redeploy. Para o estado mais recente de um cliente, use MAX(registrado_em).';

COMMENT ON COLUMN lakehouse_rotaperfume.gold.retorno_ligacao.cliente_id    IS 'Identificador do cliente. JOIN com gold.score_propensao e gold.dim_cliente.';
COMMENT ON COLUMN lakehouse_rotaperfume.gold.retorno_ligacao.vendedor      IS 'Nome do vendedor responsavel pela ligacao. JOIN com gold.fila_semanal.';
COMMENT ON COLUMN lakehouse_rotaperfume.gold.retorno_ligacao.status        IS 'Resultado da ligacao: vendeu | vai_pensar | sem_interesse | nao_atendeu.';
COMMENT ON COLUMN lakehouse_rotaperfume.gold.retorno_ligacao.comentario    IS 'Texto livre do vendedor. Campo opcional para contexto adicional.';
COMMENT ON COLUMN lakehouse_rotaperfume.gold.retorno_ligacao.registrado_em  IS 'Timestamp UTC em que o registro foi feito. Use MAX para pegar o mais recente por cliente.';
COMMENT ON COLUMN lakehouse_rotaperfume.gold.retorno_ligacao.registrado_por IS 'E-mail de quem registrou. Usado para auditoria.';
COMMENT ON COLUMN lakehouse_rotaperfume.gold.retorno_ligacao._referencia   IS 'Data de referencia da fila que gerou esta ligacao (semana da fila_semanal).';

-- ===========================================================
-- PARTE 4: 2 testes com raise_error
-- ===========================================================

-- Teste 1: nenhuma coluna da tabela retorno_ligacao sem COMMENT
SELECT CASE WHEN (
    SELECT COUNT(*)
    FROM lakehouse_rotaperfume.information_schema.columns
    WHERE table_schema = 'gold'
      AND table_name   = 'retorno_ligacao'
      AND (comment IS NULL OR comment = '')
) = 0
THEN 'PASSOU: todas as colunas tem COMMENT'
ELSE raise_error(
    'TESTE 1 FALHOU: colunas sem COMMENT em retorno_ligacao. '
    || 'A auditoria de metadado quebra o job se faltar COMMENT.'
)
END AS teste_1_comentarios;

-- Teste 2: a tabela tem exatamente 7 colunas (verifica estrutura)
SELECT CASE WHEN (
    SELECT COUNT(*)
    FROM lakehouse_rotaperfume.information_schema.columns
    WHERE table_schema = 'gold'
      AND table_name   = 'retorno_ligacao'
) = 7
THEN 'PASSOU: estrutura da tabela com 7 colunas'
ELSE raise_error(
    'TESTE 2 FALHOU: retorno_ligacao deveria ter 7 colunas, tem '
    || (SELECT COUNT(*)::STRING
        FROM lakehouse_rotaperfume.information_schema.columns
        WHERE table_schema = 'gold' AND table_name = 'retorno_ligacao')
)
END AS teste_2_estrutura;
