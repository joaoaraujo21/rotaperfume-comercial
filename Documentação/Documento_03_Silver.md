# Documento 3 — Silver: Limpeza Tipada e Contrato

**Deploy nº 3** · Dez tabelas silver, limpas, tipadas e com CHECK constraints
declaradas. É a entrega mais importante: ela é a única camada que pode
mudar o faturamento se for mal feita.

## 1. O que é o Deploy #3

A silver pega a bronze (suja, tudo texto) e entrega 10 tabelas Delta com:

- **Tipos corretos** — `cnpj` STRING 14 dígitos, `data_*` DATE, `valor_*` DECIMAL.
- **Normalização** — `trim`, `regexp_replace`, `lpad`, `try_to_date`, `initcap`.
- **Deduplicação** — clientes via `row_number()` por CNPJ.
- **Regras de negócio** — `devolucao` boolean, `cancelado` boolean, `valor_liquido`,
  `vigente`, `orfao_vendedor_desligado`.
- **Contrato** — CHECK constraints via `ALTER TABLE ... ADD CONSTRAINT`.
- **Comentários** — em cada tabela e coluna que exigiu decisão de limpeza.

**Quatro tarefas `sql_task` em PARALELO** — nenhuma depende da outra.

## 2. Arquivos do Deploy

| Arquivo | Função |
|---------|--------|
| `src/silver/01-clientes.sql` | Dedup CNPJ, normalização |
| `src/silver/02-pedidos.sql` | Tipagem, valor_liquido, ano/mes |
| `src/silver/03-itens-e-produtos.sql` | Devolucao flag, join com produtos |
| `src/silver/04-crm-e-financeiro.sql` | Vendedores, carteira, pagamentos, estoque |
| `resources/pipeline.job.yml` | Acrescenta 4 tarefas silver em paralelo |

## 3. O Loop Central — `01-clientes.sql`

### 3.1 Normalização de CNPJ

```sql
-- Bronze: 3 formatos diferentes na mesma coluna
-- Silver: 14 dígitos, sem pontuação, sem espaço
SELECT
  trim(cnpj)                                          AS cnpj_trim,
  regexp_replace(trim(cnpj), '[^0-9]', '')             AS cnpj_so_digitos,
  lpad(regexp_replace(trim(cnpj), '[^0-9]', ''), 14, '0') AS cnpj_14
FROM lakehouse_rotaperfume.bronze.clientes;
```

**Nunca converter CNPJ para número.** A conversão perderia o zero à esquerda
de 309 clientes, sem erro.

### 3.2 Deduplicação — `row_number()`

São 40 CNPJs com dois `cliente_id`. `DISTINCT` não resolve porque o `cliente_id`
é diferente em cada cadastro:

```sql
-- a dedup certa: pegar o cadastro mais antigo
WITH ranked AS (
  SELECT *,
    row_number() OVER (PARTITION BY cnpj ORDER BY data_cadastro, cliente_id) AS ordem
  FROM (
    SELECT
      lpad(regexp_replace(trim(cnpj), '[^0-9]', ''), 14, '0') AS cnpj,
      cliente_id, razao_social, data_cadastro,
      CASE WHEN upper(ativo) = 'S' THEN TRUE ELSE FALSE END AS ativo
    FROM lakehouse_rotaperfume.bronze.clientes
  )
)
SELECT *
FROM ranked
WHERE ordem = 1;   -- 3.000 clientes únicos
```

**Rastreabilidade:** `cliente_ids_duplicados` (array) guarda os IDs antigos,
porque os pedidos velhos continuam apontando para eles. Decisão: não cortar
a referência, marcar e expor.

### 3.3 Datas — `try_to_date` sempre

ANSI mode está ligado: `to_date()` e `date_trunc()` sobre data malformada
**aborta a query** com `CAST_INVALID_INPUT`, não retorna NULL.

```sql
-- ERRO: aborta em '15/10/2025'
SELECT date_trunc('month', to_date(data_pedido)) FROM bronze.pedidos;
-- [CAST_INVALID_INPUT] The value '15/10/2025' ... cannot be cast to "DATE"

-- CORRETO: coalesce dos dois formatos
SELECT coalesce(try_to_date(data_pedido),
                try_to_date(data_pedido, 'dd/MM/yyyy')) AS data_pedido
FROM bronze.pedidos;
```

Esse detalhe derruba pipeline em produção: a query passou meses funcionando
e morre no dia em que o ERP mandou uma data no outro formato.

## 4. Decisões de Negócio

### 4.1 Devolução — manter com flag

2.327 itens em `itens_pedido` têm quantidade negativa. Três caminhos:

| Caminho | Efeito | Por que não |
|---------|--------|-------------|
| Descartar a devolução | Faturamento INFLA em R$ 1,26 mi | Diretor comemora número errado |
| Manter sem flag | Toda soma fica poluída | Análise fica impossível |
| **Manter com flag `devolucao=TRUE`** | **Bruto e líquido preservados** | **Resposta certa** |

A silver cria:
- `devolucao BOOLEAN` (TRUE se quantidade < 0)
- `quantidade_abs INT` (módulo, para joins com produtos)
- Mantém a quantidade negativa original (para que `SUM(valor_bruto)` feche com a bronze)

### 4.2 Cancelado — flag + valor zero

957 pedidos cancelados têm `valor_total` zerado mas sem flag. A silver cria:
- `cancelado BOOLEAN` a partir de `status = 'Cancelado'`
- `valor_liquido DECIMAL(18,2)` = 0 quando cancelado, senão `valor_total`

### 4.3 Valor negativo de pedido

135 pedidos têm `valor_liquido` negativo. Não é sujeira: contêm item
devolvido, e o saldo do pedido virou negativo. Negócio legítimo.

**Por isso a constraint é `NOT cancelado OR valor_liquido = 0`**, e não
`valor_liquido >= 0`. A primeira protege; a segunda quebraria a tabela.

### 4.4 Vendedor desligado com carteira

Existem carteiras vigentes cujo vendedor foi desligado. A silver **não
conserta** o dado — cria a coluna `orfao_vendedor_desligado` que expõe
o problema para o gestor de vendas.

### 4.5 Etapas de oportunidade

Confusion trap: a origem tem `'Fechado ganho'` e `'Fechado perdido'`, não
`'Ganha'` e `'Perdida'`. Sem `SELECT DISTINCT etapa` antes, a CASE volta 0.

## 5. Contrato — `ALTER TABLE ... ADD CONSTRAINT`

A regra vira parte da tabela, não do script que rodou naquele dia:

```sql
ALTER TABLE lakehouse_rotaperfume.silver.clientes
  ADD CONSTRAINT clientes_cnpj_14
  CHECK (length(cnpj) = 14);

ALTER TABLE lakehouse_rotaperfume.silver.pedidos
  ADD CONSTRAINT pedido_cancelado_zerado
  CHECK (NOT cancelado OR valor_liquido = 0);

ALTER TABLE lakehouse_rotaperfume.silver.itens_pedido
  ADD CONSTRAINT itens_quantidade_abs_positiva
  CHECK (quantidade_abs > 0);
```

**Por que isso importa:** quem recusou a escrita foi a tabela. Daqui a dois
anos, quando o script que fez isso já tiver sido reescrito três vezes, a
regra continua lá.

## 6. Colunas de Auditoria

Toda tabela silver tem:

| Coluna | Tipo | Função |
|--------|------|--------|
| `_processado_em` | TIMESTAMP | Quando a silver regravou esta linha |
| `_linhas_origem` | INT | Quantas linhas da bronze geraram esta (após dedup) |

Plus comentários `COMMENT ON TABLE` e `COMMENT ON COLUMN` documentando
decisões de limpeza. **`||` não funciona em `COMMENT ON TABLE` DDL** no
warehouse do workspace — escrever strings em uma linha só.

## 7. O Job — 4 Tarefas em Paralelo

```yaml
- task_key: silver_01_clientes
  depends_on: { task_key: bronze_ingestao }
  sql_task:
    warehouse_id: ${var.warehouse_id}
    file: { path: ../src/silver/01-clientes.sql }

- task_key: silver_02_pedidos
  depends_on: { task_key: bronze_ingestao }
  sql_task: ...

- task_key: silver_03_itens_produtos
  depends_on: { task_key: bronze_ingestao }
  sql_task: ...

- task_key: silver_04_crm_financeiro
  depends_on: { task_key: bronze_ingestao }
  sql_task: ...
```

**As 4 silver rodam em PARALELO** — nenhuma depende da outra. SQL legível
com `lakehouse_rotaperfume.silver.x` em vez de `IDENTIFIER(:catalog || '.silver.x')`,
porque `sql_task` não substitui identificador por parâmetro.

## 8. Como Verificar

### 8.1 Deduplicação funcionou — mesmo número por dois caminhos

```sql
SELECT COUNT(*) AS total, COUNT(DISTINCT cnpj) AS unicos
FROM lakehouse_rotaperfume.silver.clientes;
-- 3.000 e 3.000. Os dois têm que ser IGUAIS.

SELECT cliente_id, cnpj, razao_social, cliente_ids_duplicados
FROM lakehouse_rotaperfume.silver.clientes
WHERE cliente_ids_duplicados IS NOT NULL
  AND size(cliente_ids_duplicados) > 0
LIMIT 5;
-- 40 linhas com o id antigo guardado
```

### 8.2 A limpeza fez o que prometeu, em número

| Métrica | Valor |
|---------|-------|
| Clientes únicos | 3.000 |
| CNPJ ainda sujo | 0 |
| Itens de devolução | 2.327 |
| Pedidos cancelados | 957 |
| Itens com SKU descontinuado | 76 |
| Carteiras de vendedor desligado | 441 |

### 8.3 O teste que importa mais: a limpeza NÃO mudou o faturamento

```sql
SELECT
  (SELECT ROUND(SUM(try_cast(valor_total AS DECIMAL(18,2))), 2)
     FROM lakehouse_rotaperfume.bronze.pedidos
     WHERE status <> 'Cancelado')              AS bronze_como_veio,
  (SELECT ROUND(SUM(valor_liquido), 2)
     FROM lakehouse_rotaperfume.silver.pedidos) AS silver_limpa;
-- R$ 102.303.828,05 nas duas colunas — o MESMO número
```

> *"Eu joguei fora 40 cadastros duplicados, converti 3.443 datas e marquei
> 2.327 devoluções. O faturamento não mudou um centavo. É esse o teste de
> uma boa limpeza."*

### 8.4 O contrato existe, e é da tabela

```sql
SHOW TBLPROPERTIES lakehouse_rotaperfume.silver.clientes;
-- procure as linhas delta.constraints.*  →  o CHECK está gravado na tabela
```

### 8.5 A prova de que o contrato tem dente

```sql
-- Tente violar: regrave um cancelado com valor diferente de zero
INSERT INTO lakehouse_rotaperfume.silver.pedidos
SELECT * REPLACE (CAST(999.00 AS DECIMAL(18,2)) AS valor_liquido)
FROM lakehouse_rotaperfume.silver.pedidos
WHERE cancelado LIMIT 1;
-- [DELTA_VIOLATE_CONSTRAINT] CHECK constraint pedido_cancelado_zerado
-- (NOT cancelado OR valor_liquido = 0) violated by row with values ...

-- Mesma escrita respeitando a regra: essa passa
INSERT INTO lakehouse_rotaperfume.silver.pedidos
SELECT * REPLACE (CAST(0.00 AS DECIMAL(18,2)) AS valor_liquido,
                  TIMESTAMP'1999-01-01 00:00:00' AS _processado_em)
FROM lakehouse_rotaperfume.silver.pedidos
WHERE cancelado LIMIT 1;
-- 1 linha inserida

DELETE FROM lakehouse_rotaperfume.silver.pedidos
WHERE _processado_em = TIMESTAMP'1999-01-01 00:00:00';
-- desfaz o teste
```

Mostrar os dois ensina o que constraint é: uma porta que deixa passar o
dado certo e fecha para o errado, sem depender de ninguém lembrar da regra.

## 9. Decisões e Princípios

| Decisão | Motivo |
|---------|--------|
| 4 SQL `sql_task` em paralelo | Nenhuma depende da outra; o DAG desenha melhor |
| `try_to_date` sempre | ANSI mode aborta com `CAST_INVALID_INPUT` |
| Dedup com `row_number()` + rastrear IDs antigos | Preserva rastreabilidade dos pedidos velhos |
| Devolução com flag (não descartar) | Faturamento inflaria R$ 1,26 mi |
| Constraint `NOT cancelado OR valor_liquido = 0` | 135 pedidos com devolução ficam negativos legitimamente |
| `cnpj` STRING, não número | 309 clientes perdem zero à esquerda |
| `_processado_em` + `_linhas_origem` | Auditoria de quando a silver regravou a linha |
| COMMENT em colunas que exigem decisão | "Por que" sobrevive ao "o quê" |

## 10. Próximo Deploy

Deploy #4 (Gold): 4 dimensões, 1 fato, 3 marts por diretoria, 9 testes de
qualidade. A camada modelada para consumidor específico.
