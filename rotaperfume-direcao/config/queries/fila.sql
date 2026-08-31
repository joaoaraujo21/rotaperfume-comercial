-- @param vendedor: string = Todos
-- 200 contatos priorizados, com LEFT JOIN do retorno mais recente.
--
-- Quando o filtro = 'Todos', a lista inteira e exibida (200).
-- Quando filtrado por vendedor, mostra so os clientes daquele vendedor.

WITH
  retorno_mais_recente AS (
    SELECT *
    FROM   lakehouse_rotaperfume.gold.retorno_ligacao
    QUALIFY ROW_NUMBER() OVER (PARTITION BY cliente_id ORDER BY registrado_em DESC) = 1
  ),
  fila_filtrada AS (
    SELECT *
    FROM   lakehouse_rotaperfume.gold.fila_semanal
    WHERE  CASE
             WHEN :vendedor = 'Todos' THEN TRUE
             ELSE vendedor = :vendedor
           END
  )
SELECT
  ff.cliente_id,
  ff.ordem,
  ff.razao_social,
  CONCAT(ff.cidade, '/', ff.uf)              AS localizacao,
  ff.ticket_medio,
  ff.vendedor,
  ROUND(ff.score * 100, 0)                   AS chance_pct,
  ff.faixa,
  ff.motivo,
  ff.sugestao,
  rmr.status                                  AS status_retorno,
  rmr.comentario                              AS comentario_retorno,
  rmr.registrado_em                           AS quando_retorno
FROM     fila_filtrada ff
LEFT JOIN retorno_mais_recente rmr
       ON rmr.cliente_id = ff.cliente_id
ORDER BY ff.vendedor, ff.ordem;
