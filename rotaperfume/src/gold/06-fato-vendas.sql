-- =================================================================
-- gold.fato_vendas
--
-- CONTRATO (escrito antes do SQL -- eh assim que ele deve ser lido):
--
-- GRANULARIDADE: uma linha por ITEM DE PEDIDO (nao por pedido).
--
-- FILTRO: exclui pedidos cancelados. NAO exclui devolucao -- a devolucao
-- fica DENTRO do fato com quantidade e receita NEGATIVAS.
--
-- DIMENSOES: data_pedido, ano, mes, canal, cliente_id, razao_social,
--            segmento, cidade, vendedor_id, sku, categoria, marca,
--            nota_olfativa
--
-- METRICAS:
--   quantidade       - quantidade do item (pode ser negativa = devolucao)
--   preco_praticado  - preco unitario por item
--   receita          - quantidade * preco_praticado
--   custo            - quantidade * custo_unitario
--   margem           - receita - custo
--   devolucao        - TRUE se o item eh devolucao
--
-- REGRAS DE CALCULO (nao mude sem falar com o CFO):
--   receita = quantidade * preco_praticado
--   custo   = quantidade * custo_unitario_do_produto
--   margem  = receita - custo
--
-- POR QUE A DEVOLUCAO FICA DENTRO: se ficasse fora, a gold somaria
-- R$ 103,6 mi e a silver R$ 102,3 mi (R$ 1,26 milhao de diferenca).
-- Quem quiser o bruto pede:
--   SUM(receita) FILTER (WHERE NOT devolucao)
-- =================================================================

CREATE OR REPLACE TABLE lakehouse_rotaperfume.gold.fato_vendas AS
SELECT
  p.data_pedido,
  p.ano,
  p.mes,
  p.canal,
  p.cliente_id,
  c.razao_social,
  c.segmento,
  c.cidade,
  p.vendedor_id,
  i.sku,
  pr.categoria,
  pr.marca,
  pr.nota_olfativa,
  -- METRICAS
  -- quantidade: usa i.quantidade (NAO quantidade_abs) para que a devolucao
  -- entre negativa. Se usasse ABS, o fato somaria R$ 103,6 mi em vez de 102,3.
  i.quantidade,
  i.preco_praticado,
  -- receita: usa i.valor_bruto (ja calculado na bronze, arredonda no nivel
  -- do item) -- isso garante que SUM(receita) fecha com silver.valor_liquido.
  -- O produto quantity * preco_praticado daria diferenca por arredondamento.
  i.valor_bruto                                                     AS receita,
  ROUND(i.quantidade_abs * pr.custo_unitario, 2)                  AS custo,
  ROUND(i.valor_bruto - i.quantidade_abs * pr.custo_unitario, 2) AS margem,
  i.devolucao,
  -- auditoria
  current_timestamp()                                                AS _processado_em
FROM lakehouse_rotaperfume.silver.itens_pedido i
JOIN lakehouse_rotaperfume.silver.pedidos  p  ON p.pedido_id  = i.pedido_id
JOIN lakehouse_rotaperfume.silver.clientes c  ON c.cliente_id  = p.cliente_id
JOIN lakehouse_rotaperfume.silver.produtos pr ON pr.sku         = i.sku
WHERE NOT p.cancelado;  -- exclui so cancelado; devolucao fica

ALTER TABLE lakehouse_rotaperfume.gold.fato_vendas
  ADD CONSTRAINT fatovendas_receita_not_null CHECK (receita IS NOT NULL);

ALTER TABLE lakehouse_rotaperfume.gold.fato_vendas
  ADD CONSTRAINT fatovendas_quantidade_not_null CHECK (quantidade IS NOT NULL);

COMMENT ON TABLE lakehouse_rotaperfume.gold.fato_vendas IS
  'Gold - fato de vendas. Uma linha por item de pedido. Pedidos cancelados excluidos. Devolucao INCLUIDA com valor negativo (quantidade e receita negativas, flag devolucao=TRUE). margem = receita - custo (sem frete, sem desconto comercial). Granularidade: item de pedido.';

COMMENT ON COLUMN lakehouse_rotaperfume.gold.fato_vendas.receita IS
  'Receita do item: quantidade * preco_praticado. Negativa quando devolucao=TRUE. Bruto: SUM(receita) FILTER (WHERE NOT devolucao).';

COMMENT ON COLUMN lakehouse_rotaperfume.gold.fato_vendas.margem IS
  'Receita menos custo do produto. NAO considera frete, NAO considera desconto comercial. Negativa quando devolucao=TRUE.';

COMMENT ON COLUMN lakehouse_rotaperfume.gold.fato_vendas.custo IS
  'Custo do item: quantidade * custo_unitario do produto na data da venda. Custo unitario nao muda no tempo.';

COMMENT ON COLUMN lakehouse_rotaperfume.gold.fato_vendas.quantidade IS
  'Quantidade do item. Positiva = venda, negativa = devolucao. A devolucao mantem sinal original para que a soma do fato feche na receita da silver.';

COMMENT ON COLUMN lakehouse_rotaperfume.gold.fato_vendas.devolucao IS
  'TRUE se o item eh devolucao (quantidade < 0). NAO eh sujeira, eh negocio legitimo: 2.327 itens na silver.';
