# Documento 2 — Bronze: Ingestão que Preserva a Sujeira

**Deploy nº 2** · Dez tabelas Delta ingeridas dos CSVs, com `inferColumnTypes`
desligado, tudo como STRING. A sujeira fica — é o material do próximo deploy.

## 1. O que é o Deploy #2

A bronze lê os 10 CSVs do Volume (`bronze.raw/{sistema}/{tabela}.csv`) e grava
10 tabelas Delta em `lakehouse_rotaperfume.bronze.{tabela}`, modo `overwrite`.

**Princípio fundador:** nada de limpeza, nada de conversão de tipo. A bronze
preserva o dado exatamente como o ERP/CRM mandou. A limpeza é trabalho da
silver — e é lá que vai morar a regra de negócio.

## 2. Arquivo do Deploy

| Arquivo | Função |
|---------|--------|
| `src/bronze/ingestao.py` | Notebook Python que ingere os 10 CSVs |
| `src/bronze/validacao.py` | Valida contagem: bronze == raw |
| `resources/pipeline.job.yml` | Acrescenta tarefas `bronze_ingestao` e `bronze_validacao` |

## 3. O Notebook — `src/bronza/ingestao.py`

Estrutura:

```python
# Databricks notebook source

# Recebe catalog via widget
catalog = dbutils.widgets.get("catalog")

# Lista de 10 tabelas (uma linha por arquivo)
TABELAS = [
    ("erp", "produtos"), ("erp", "pedidos"), ("erp", "itens_pedido"),
    ("erp", "pagamentos"), ("erp", "estoque"),
    ("crm", "clientes"), ("crm", "vendedores"), ("crm", "carteira"),
    ("crm", "oportunidades"), ("crm", "visitas"),
]

def ingerir(sistema, tabela, catalog):
    """Lê 1 CSV, grava 1 tabela Delta. Tudo STRING, mais 2 colunas técnicas."""
    path = f"/Volumes/{catalog}/bronze/raw/{sistema}/{tabela}.csv"
    df = (spark.read
          .option("header", True)
          .option("inferColumnTypes", False)   # CRÍTICO
          .option("escape", '"')
          .csv(path))
    df = (df.withColumn("_ingerido_em", current_timestamp())
            .withColumn("_arquivo_origem", lit(f"{sistema}/{tabela}.csv"))
            .select("* EXCEPT (_rescued_data)"))   # descarta coluna fantasma
    df.write.mode("overwrite").saveAsTable(f"{catalog}.bronze.{tabela}")
    return df.count()

# Itera: a função é escrita UMA vez, chamada 10 vezes
resultados = [(t, ingerir(s, t, catalog)) for s, t in TABELAS]
```

## 4. Regras de Ingestão

| Regra | Por quê |
|-------|--------|
| `inferColumnTypes=False` | CNPJ perderia zero à esquerda; data viraria nula |
| Tudo STRING | Bronze é prova do que o ERP mandou; converter é trabalho da silver |
| `_ingerido_em` TIMESTAMP | "Quando entrou" — primeira pergunta de qualquer investigação |
| `_arquivo_origem` STRING | "De qual arquivo veio" — segunda pergunta |
| `EXCEPT (_rescued_data)` | Databricks cria essa coluna sozinho; precisa descartar |
| `escape='"'` | CSVs com aspas escapadas no conteúdo |
| `header=True` | CSVs têm header |
| NÃO usar `multiLine` | CSVs são CRLF sem aspas quebrando linha |

### 4.1 A armadilha do `inferColumnTypes`

Se o Spark adivinha tipo:

```sql
-- (a) tudo texto, que é como a bronze vai guardar
SELECT cliente_id, cnpj FROM read_files(
  '/Volumes/lakehouse_rotaperfume/bronze/raw/crm/clientes.csv',
  format => 'csv', header => true)
WHERE cnpj LIKE '0%' LIMIT 5;
-- cnpj = '01234567890123' ✓

-- (b) o mesmo arquivo com inferência de tipo ligada
SELECT cnpj FROM read_files(
  '/Volumes/lakehouse_rotaperfume/bronze/raw/crm/clientes.csv',
  format => 'csv', header => true, inferColumnTypes => true)
WHERE cnpj LIKE '0%' LIMIT 5;
-- cnpj = 1234567890123 ✗ (zero à esquerda perdido)
```

**309 clientes ficariam errados para sempre, sem erro.** É o tipo de bug que
vira piada em reunião três meses depois.

### 4.2 A coluna `_rescued_data`

O leitor de arquivo do Databricks cria uma coluna `_rescued_data` sozinho,
para capturar linhas malformadas em vez de falhar. Mesmo passando
`rescuedDataColumn => ''` **não** desliga — cria uma coluna de nome vazio e o
CREATE TABLE quebra.

**Solução:** `SELECT * EXCEPT (_rescued_data)` em todo `withColumn`.

## 5. Tabelas Produzidas

| Tabela | Linhas esperadas |
|--------|------------------|
| produtos | 292 |
| pedidos | 28.729 |
| itens_pedido | 197.724 |
| pagamentos | 27.772 |
| estoque | 8.400 |
| clientes | 3.040 |
| vendedores | 42 |
| carteira | 3.637 |
| oportunidades | 5.979 |
| visitas | 37.936 |
| **Total** | **313.551** |

## 6. Validação — `src/bronze/validacao.py`

Tarefa que **compara linhas da bronze com `bronze._raw_arquivos`**:

```sql
WITH contagem AS (
  SELECT 'produtos'     AS tabela, COUNT(*) AS linhas FROM bronze.produtos
  UNION ALL SELECT 'pedidos',      COUNT(*) FROM bronze.pedidos
  UNION ALL SELECT 'itens_pedido', COUNT(*) FROM bronze.itens_pedido
  -- ... (10 tabelas)
)
SELECT c.tabela, c.linhas AS na_tabela, r.linhas AS no_arquivo,
       c.linhas = r.linhas AS bate
FROM contagem c
JOIN bronze._raw_arquivos r ON r.arquivo = c.tabela || '.csv'
ORDER BY c.linhas DESC;
```

**A coluna `bate` tem que ser `true` nas 10 linhas.** Se uma linha der
`false`, o CSV foi lido errado (quase sempre `multiLine` ligado ou separador
trocado), e é melhor descobrir agora.

## 7. O Job — `pipeline.job.yml`

Adiciona duas tarefas:

```yaml
- task_key: bronze_ingestao
  depends_on: { task_key: raw_conferencia }
  notebook_task:
    notebook_path: ../src/bronze/ingestao.py

- task_key: bronze_validacao
  depends_on: { task_key: bronze_ingestao }
  notebook_task:
    notebook_path: ../src/bronze/validacao.py
```

**Ordem:** `raw_conferencia → bronze_ingestao → bronze_validacao`. Se a
conferência falhar, a bronze não roda. Se a ingestão rodar e a validação
mostrar divergência, o job para.

## 8. Como Verificar

### 8.1 As 10 tabelas existem, contagem bate com a origem

```sql
SHOW TABLES IN lakehouse_rotaperfume.bronze;
-- 10 + _raw_arquivos
```

Comparar a query de validação do item 6.

### 8.2 Tudo entrou como texto — de propósito

```sql
DESCRIBE TABLE lakehouse_rotaperfume.bronze.pedidos;
-- todas as colunas de negócio em STRING; só _ingerido_em é TIMESTAMP
```

### 8.3 O metadado técnico responde "de onde veio" e "quando entrou"

```sql
SELECT _arquivo_origem, MIN(_ingerido_em) AS ingerido_em, COUNT(*) AS linhas
FROM lakehouse_rotaperfume.bronze.itens_pedido
GROUP BY _arquivo_origem;
```

### 8.4 A sujeira foi PRESERVADA

```sql
SELECT
  COUNT(*)                                                       AS clientes,
  COUNT(*) FILTER (WHERE cnpj LIKE '%.%')                        AS cnpj_pontuado,
  COUNT(*) FILTER (WHERE cnpj <> trim(cnpj))                     AS cnpj_com_espaco,
  COUNT(*) FILTER (WHERE regexp_replace(trim(cnpj),'[^0-9]','') LIKE '0%')
                                                                 AS cnpj_zero_a_esquerda,
  COUNT(*) FILTER (WHERE data_cadastro LIKE '%/%')               AS data_formato_br
FROM lakehouse_rotaperfume.bronze.clientes;
```

| Métrica | Valor |
|---------|-------|
| Clientes na bronze | 3.040 |
| CNPJ pontuado | 1.111 |
| CNPJ com espaço | 223 |
| CNPJ com zero à esquerda | 309 |
| Data em dd/MM/yyyy | 12% da tabela |

**Essa é a deixa para o prompt 3** — toda essa sujeira é material de limpeza.

### 8.5 A bronze não conserta nada

```sql
-- "me dá os cinco maiores pedidos" — direto da bronze
SELECT pedido_id, valor_total
FROM lakehouse_rotaperfume.bronze.pedidos
ORDER BY valor_total DESC LIMIT 5;
-- o "maior" é o que COMEÇA com 9: valor_total é texto, texto ordena
-- alfabeticamente: '987.50' vem antes de '10240.00'

-- e a mesma pergunta com a conversão que a silver vai fazer
SELECT pedido_id, CAST(valor_total AS DECIMAL(18,2)) AS valor
FROM lakehouse_rotaperfume.bronze.pedidos
ORDER BY valor DESC LIMIT 5;
```

As duas listas são diferentes, e nenhuma das duas deu erro. Isso não é
limitação da bronze, é o contrato dela: ela responde "o que o ERP mandou".
Quem responde "quanto a gente vendeu" é a próxima camada.

## 9. Decisões e Princípios

| Decisão | Motivo |
|---------|--------|
| `inferColumnTypes=False` | CNPJ e data perdem precisão silenciosamente |
| Tudo STRING | Bronze é a prova da origem; converter é trabalho da silver |
| `_ingerido_em` + `_arquivo_origem` | Linhagem básica para qualquer investigação |
| `EXCEPT (_rescued_data)` | Databricks cria essa coluna; precisamos descartá-la |
| Função de ingestão única + lista | 11ª tabela no futuro = 1 linha a mais |
| Validação posterior | Detecta cedo divergência de contagem |
| Nada de CAST | Quem precisar de tipos vai na silver |

## 10. Próximo Deploy

Deploy #3 (Silver): limpar, tipar, deduplicar, e declarar CHECK constraints
como contrato da tabela.
