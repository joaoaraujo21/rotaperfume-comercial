-- @param vendedor: string = Todos
-- KPI da semana: 4 números para o diretor.
--
-- Fontes:
--   gold.fila_semanal      -- 200 contatos, 35 vendedores
--   gold.modelo_metricas   -- lift_top200, acertos_top200, taxa_base (ÚLTIMA versão)
--   gold.retorno_ligacao   -- caminho de volta (vazio no começo)

WITH
  ultima_metrica AS (
    SELECT
      -- Contatos que o modelo acertou nos top 200
      acertos_top200,
      -- Lift sobre taxa base (quantas vezes melhor que sortear)
      lift_top200,
      -- Taxa base de compra em decimal (ex: 0.1012)
      taxa_base
    FROM   lakehouse_rotaperfume.gold.modelo_metricas
    QUALIFY ROW_NUMBER() OVER (ORDER BY versao DESC) = 1
  ),
  fila_filtrada AS (
    SELECT
      -- Identificador único do cliente
      cliente_id,
      -- Nome do vendedor responsável
      vendedor,
      -- Score de propensão (0 a 1)
      score,
      -- Ticket médio do cliente
      ticket_medio
    FROM   lakehouse_rotaperfume.gold.fila_semanal
    WHERE  CASE
             WHEN :vendedor = 'Todos' THEN TRUE
             ELSE vendedor = :vendedor
           END
  ),
  agregados AS (
    SELECT
      -- Contatos únicos da semana filtrada
      COUNT(DISTINCT ff.cliente_id)                                        AS contatos,
      -- Vendedores distintos na semana
      COUNT(DISTINCT ff.vendedor)                                          AS vendedores,
      -- Receita estimada: soma de score * ticket_medio
      ROUND(SUM(ff.score * ff.ticket_medio), 2)                            AS receita_esperada,
      -- Contatos já trabalhados (com registro em retorno_ligacao)
      COUNT(DISTINCT rl.cliente_id)                                        AS ja_trabalhados,
      -- Contatos que viraram pedido
      COUNT(DISTINCT CASE WHEN rl.status = 'vendeu' THEN rl.cliente_id END)
                                                                          AS viraram_pedido
    FROM        fila_filtrada     ff
    LEFT JOIN   lakehouse_rotaperfume.gold.retorno_ligacao rl
            ON  rl.cliente_id = ff.cliente_id
  )
SELECT
  ag.contatos,
  ag.vendedores,
  ag.receita_esperada,
  um.acertos_top200,
  ROUND(um.lift_top200, 2)                                            AS lift,
  ROUND(um.taxa_base * 100, 1)                                         AS taxa_base_pct,
  ROUND(um.acertos_top200 * 100.0 / GREATEST(ag.contatos, 1), 1)       AS conversao_prevista_pct,
  ag.ja_trabalhados,
  ag.viraram_pedido
FROM        agregados        ag
CROSS JOIN  ultima_metrica   um;
