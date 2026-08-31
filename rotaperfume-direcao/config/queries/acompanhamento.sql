-- @param vendedor: string = Todos
-- Acompanhamento do trabalho: o que foi feito com a fila.
--
-- Retorna uma linha por vendedor (ou uma unica linha quando 'Todos'),
-- com a contagem por status.

WITH
  retorno_mais_recente AS (
    SELECT *
    FROM   lakehouse_rotaperfume.gold.retorno_ligacao
    QUALIFY ROW_NUMBER() OVER (PARTITION BY cliente_id ORDER BY registrado_em DESC) = 1
  ),
  fila_filtrada AS (
    SELECT cliente_id, vendedor
    FROM   lakehouse_rotaperfume.gold.fila_semanal
    WHERE  CASE
             WHEN :vendedor = 'Todos' THEN TRUE
             ELSE vendedor = :vendedor
           END
  )
SELECT
  ff.vendedor,
  COUNT(DISTINCT ff.cliente_id)                                             AS na_fila,
  COUNT(DISTINCT rmr.cliente_id)                                            AS trabalhados,
  COUNT(DISTINCT CASE WHEN rmr.status = 'vendeu'        THEN rmr.cliente_id END)
                                                                             AS viraram_pedido,
  COUNT(DISTINCT CASE WHEN rmr.status = 'vai_pensar'    THEN rmr.cliente_id END)
                                                                             AS vai_pensar,
  COUNT(DISTINCT CASE WHEN rmr.status = 'sem_interesse' THEN rmr.cliente_id END)
                                                                             AS sem_interesse,
  COUNT(DISTINCT CASE WHEN rmr.status = 'nao_atendeu'   THEN rmr.cliente_id END)
                                                                             AS nao_atendeu
FROM     fila_filtrada ff
LEFT JOIN retorno_mais_recente rmr
       ON rmr.cliente_id = ff.cliente_id
GROUP BY ff.vendedor
ORDER BY ff.vendedor;
