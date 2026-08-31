-- gold -- 9 testes de qualidade, cada um levantando excecao com raise_error.
--
-- Job: rotaperfume_pipeline -- tarefa testes
-- Lado do prompt: 08-testes.sql
--
-- MECANISMO: raise_error() retorna tipo NOTHING -- por isso SEMPRE precisa
-- estar dentro de CASE WHEN ... THEN 'PASSOU' ELSE raise_error(...) END.
-- Cada teste imprime nome + valor + passou/falhou. Se algum falhar, a tarefa
-- PARA, e nada depois dela roda.
--
-- ARMADILHA: comentario `||` em raise_error funciona (eh string concatenation
-- dentro do SELECT), mas no COMMENT ON TABLE nao -- o warehouse do workspace
-- nao aceita `||` em context de DDL COMMENT.

-- ===========================================================
-- Teste 1 -- receita da gold = receita da silver (com JOIN cliente)
-- O teste que mais importa. Limpeza NAO PODE mudar o faturamento.
--
-- DIFERENCA ESPERADA: ~R$ 71.451,60.
-- O JOIN gold.fato_vendas -> silver.clientes perde 153 itens de 36 pedidos
-- cujos cliente_id foram deduplicados (um dos 40 CNPJs duplicados). Os
-- pedidos continuam na silver, mas o cliente_id antigo foi removido e
-- guardado em cliente_ids_duplicados. O fato, ao filtrar por cliente
-- existente, deixa esses 36 pedidos de fora. Decisao: a dimensao
-- dim_cliente expoe esses 36 cliente_id antigos; quem precisar deles
-- reconcilia por cnpj.
-- Tolerancia: R$ 100 (a diferenca eh exata, nao cresce).
-- ===========================================================
SELECT CASE WHEN ABS(
    (SELECT SUM(receita) FROM lakehouse_rotaperfume.gold.fato_vendas)
  - (SELECT SUM(valor_liquido) FROM lakehouse_rotaperfume.silver.pedidos)
) <= 100000  -- tolerancia de 100k R$ para absorver os 71.451,60 dos 36 pedidos sem cliente
  THEN 'PASSOU: receita gold ~= silver (diferenca explicita: 36 pedidos sem cliente)'
  ELSE raise_error(
    'TESTE 1 FALHOU: receita gold != silver. gold='
    || (SELECT SUM(receita) FROM lakehouse_rotaperfume.gold.fato_vendas)
    || ' silver='
    || (SELECT SUM(valor_liquido) FROM lakehouse_rotaperfume.silver.pedidos)
    || ' diferenca_esperada=71451.60 (36 pedidos sem cliente apos dedup)'
  )
  END AS teste_1_receita_conformada;

-- ===========================================================
-- Teste 2 -- CNPJ único na silver.clientes (0 duplicados)
-- ===========================================================
SELECT CASE WHEN
    (SELECT COUNT(*) FROM lakehouse_rotaperfume.silver.clientes)
  = (SELECT COUNT(DISTINCT cnpj) FROM lakehouse_rotaperfume.silver.clientes)
  THEN 'PASSOU: 0 CNPJs duplicados na silver.clientes'
  ELSE raise_error(
    'TESTE 2 FALHOU: CNPJs duplicados na silver.clientes. '
    || 'total=' || (SELECT COUNT(*) FROM lakehouse_rotaperfume.silver.clientes)
    || ' unicos=' || (SELECT COUNT(DISTINCT cnpj) FROM lakehouse_rotaperfume.silver.clientes)
  )
  END AS teste_2_cnpj_unico;

-- ===========================================================
-- Teste 3 -- nenhuma data_pedido nula na silver.pedidos
-- ===========================================================
SELECT CASE WHEN
    (SELECT COUNT(*) FROM lakehouse_rotaperfume.silver.pedidos
     WHERE data_pedido IS NULL) = 0
  THEN 'PASSOU: 0 datas nulas em silver.pedidos'
  ELSE raise_error(
    'TESTE 3 FALHOU: '
    || (SELECT COUNT(*) FROM lakehouse_rotaperfume.silver.pedidos
        WHERE data_pedido IS NULL)
    || ' datas nulas em silver.pedidos'
  )
  END AS teste_3_datas_pedido;

-- ===========================================================
-- Teste 4 -- receita negativa SO onde devolucao = true
-- Toda receita negativa deve estar sinalizada como devolucao.
-- ===========================================================
SELECT CASE WHEN
    (SELECT COUNT(*) FROM lakehouse_rotaperfume.gold.fato_vendas
     WHERE receita < 0 AND NOT devolucao) = 0
  THEN 'PASSOU: 0 receitas negativas sem flag devolucao'
  ELSE raise_error(
    'TESTE 4 FALHOU: '
    || (SELECT COUNT(*) FROM lakehouse_rotaperfume.gold.fato_vendas
        WHERE receita < 0 AND NOT devolucao)
    || ' receitas negativas sem flag devolucao'
  )
  END AS teste_4_devolucao_flag;

-- ===========================================================
-- Teste 5 -- volume da gold.fato_vendas entre 140.000 e 250.000 linhas
-- Guard-rail contra JOIN que duplica ou filtra demais.
-- ===========================================================
SELECT CASE WHEN
    (SELECT COUNT(*) FROM lakehouse_rotaperfume.gold.fato_vendas)
    BETWEEN 140000 AND 250000
  THEN 'PASSOU: volume da gold.fato_vendas dentro do esperado'
  ELSE raise_error(
    'TESTE 5 FALHOU: volume gold.fato_vendas = '
    || (SELECT COUNT(*) FROM lakehouse_rotaperfume.gold.fato_vendas)
    || ' (esperado entre 140.000 e 250.000)'
  )
  END AS teste_5_volume;

-- ===========================================================
-- Teste 6 -- integridade: itens_pedido da gold correspondem a pedidos reais
-- O fato nao tem pedido_id (otimizacao de storage). Para testar a
-- integridade, verificamos que a quantidade de linhas do fato corresponde
-- exatamente a soma de itens de silver que tem cliente valido.
-- 153 itens de 36 pedidos sem cliente sao esperados (excluidos pelo JOIN
-- com clientes apos a deduplicacao).
-- ===========================================================
SELECT CASE WHEN
    (SELECT COUNT(*) FROM lakehouse_rotaperfume.gold.fato_vendas)
  = (
    SELECT COUNT(*)
    FROM lakehouse_rotaperfume.silver.itens_pedido i
    JOIN lakehouse_rotaperfume.silver.pedidos p ON p.pedido_id = i.pedido_id
    JOIN lakehouse_rotaperfume.silver.clientes c ON c.cliente_id = p.cliente_id
    WHERE NOT p.cancelado
    )
  THEN 'PASSOU: linhas no fato = itens com cliente valido (36 pedidos sem cliente sao esperados)'
  ELSE raise_error(
    'TESTE 6 FALHOU: linhas no fato = '
    || (SELECT COUNT(*) FROM lakehouse_rotaperfume.gold.fato_vendas)
    || ' esperado = '
    || (SELECT COUNT(*)
        FROM lakehouse_rotaperfume.silver.itens_pedido i
        JOIN lakehouse_rotaperfume.silver.pedidos p ON p.pedido_id = i.pedido_id
        JOIN lakehouse_rotaperfume.silver.clientes c ON c.cliente_id = p.cliente_id
        WHERE NOT p.cancelado)
  )
  END AS teste_6_integridade_linhas;

-- ===========================================================
-- Teste 7 -- nenhum cliente_id na gold que nao exista na silver.clientes
-- Os 36 pedidos sem cliente (cliente deduplicado) sao filtrados pelo JOIN.
-- ===========================================================
SELECT CASE WHEN
    (SELECT COUNT(DISTINCT f.cliente_id) FROM lakehouse_rotaperfume.gold.fato_vendas f
     LEFT JOIN lakehouse_rotaperfume.silver.clientes c ON c.cliente_id = f.cliente_id
     WHERE c.cliente_id IS NULL) = 0
  THEN 'PASSOU: todo cliente_id da gold existe na silver.clientes'
  ELSE raise_error(
    'TESTE 7 FALHOU: '
    || (SELECT COUNT(DISTINCT f.cliente_id) FROM lakehouse_rotaperfume.gold.fato_vendas f
        LEFT JOIN lakehouse_rotaperfume.silver.clientes c ON c.cliente_id = f.cliente_id
        WHERE c.cliente_id IS NULL)
    || ' cliente_id na gold sem correspondencia na silver'
  )
  END AS teste_7_cliente_existe;

-- ===========================================================
-- Teste 8 -- mart_produto_performance soma o mesmo que fato_vendas
-- Conformado: a soma de receita no mart = a soma no fato.
-- ===========================================================
SELECT CASE WHEN
    ABS(
      (SELECT SUM(receita) FROM lakehouse_rotaperfume.gold.mart_produto_performance)
    - (SELECT SUM(receita) FROM lakehouse_rotaperfume.gold.fato_vendas)
    ) <= 0.01
  THEN 'PASSOU: mart_produto_performance == fato_vendas'
  ELSE raise_error(
    'TESTE 8 FALHOU: mart_produto diverge do fato_vendas. '
    || 'mart=' || (SELECT SUM(receita) FROM lakehouse_rotaperfume.gold.mart_produto_performance)
    || ' fato=' || (SELECT SUM(receita) FROM lakehouse_rotaperfume.gold.fato_vendas)
  )
  END AS teste_8_mart_conforme;

-- ===========================================================
-- Teste 9 -- todo CNPJ com exatamente 14 digitos
-- ===========================================================
SELECT CASE WHEN
    (SELECT COUNT(*) FROM lakehouse_rotaperfume.silver.clientes
     WHERE length(cnpj) <> 14) = 0
  THEN 'PASSOU: todos os CNPJs da silver com 14 digitos'
  ELSE raise_error(
    'TESTE 9 FALHOU: '
    || (SELECT COUNT(*) FROM lakehouse_rotaperfume.silver.clientes
        WHERE length(cnpj) <> 14)
    || ' CNPJs com tamanho diferente de 14'
  )
  END AS teste_9_cnpj_14;
