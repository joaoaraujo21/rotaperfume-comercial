-- Lista de vendedores da fila para alimentar o filtro.
-- Inclui a opcao 'Todos' no topo, com a contagem total entre parenteses.

SELECT 'Todos' AS value, 'Todos os vendedores' AS label
UNION ALL
SELECT
  vendedor AS value,
  CONCAT(vendedor, ' (',
         COUNT(*), ')') AS label
FROM   lakehouse_rotaperfume.gold.fila_semanal
GROUP BY vendedor
ORDER BY CASE WHEN value = 'Todos' THEN 0 ELSE 1 END, value;
