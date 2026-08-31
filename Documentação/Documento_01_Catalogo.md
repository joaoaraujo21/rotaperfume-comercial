# Documento 1 — Catálogo como Código e Conferência de Chegada

**Deploy nº 1** · `bundle deploy` cria o catálogo, schemas e volume. O job
`rotaperfume_pipeline` sobe com a primeira tarefa de conferência de chegada.

## 1. O que é o Deploy #1

Este deploy estabelece três coisas no workspace:

1. **O catálogo inteiro é código** — `lakehouse_rotaperfume` + 3 schemas (bronze/silver/gold) + 1 volume (`bronze.raw`) declarados em `resources/catalogo.yml`. O `bundle deploy` provisiona tudo.
2. **A conferência de chegada** — tarefa `raw_conferencia` que verifica que os 10 CSVs esperados estão no Volume antes de qualquer coisa rodar.
3. **O job `rotaperfume_pipeline`** — agendado diariamente às 6h, com a tarefa de conferência como primeiro nó. Os próximos 4 deploys adicionam tarefas.

## 2. Arquivos do Deploy

| Arquivo | Função |
|---------|--------|
| `databricks.yml` | Bundle definition, targets, variáveis |
| `resources/catalogo.yml` | 3 schemas + 1 volume declarados como recurso do bundle |
| `resources/pipeline.job.yml` | Job `rotaperfume_pipeline` com a tarefa `raw_conferencia` |
| `src/raw/conferencia.py` | Notebook Python que confere chegada |
| `scripts/criar-catalogo.sh` | Workaround Free Edition: cria catálogo por SQL |
| `scripts/subir-raw.sh` | Sobe os CSVs para o Volume |

## 3. O Bundle — `databricks.yml`

```yaml
bundle:
  name: rotaperfume
include:
  - resources/*.yml
variables:
  catalog:
    description: The Unity Catalog catalog to use
  warehouse_id:
    default: 5e190bf1956452bc
```

**Targets:**

| Target | Modo | Workspace | Por quê |
|--------|------|-----------|---------|
| `dev` (default) | `presets.trigger_pause_status: PAUSED` | host do workspace | Pause de agendamento sem prefixar nomes |
| `prod` | `production` | `/Workspace/Users/.../.bundle/...` | Modo produção com permissões explícitas |

### Armadilha crítica — `mode: development`

**NUNCA** use `mode: development` no target dev. Esse modo prefixa TODOS os
nomes de recursos com `[dev seu_usuario]` — inclusive os schemas do Unity
Catalog, que virariam `dev_fulano_bronze` em vez de `bronze`. Isso quebra
todo o SQL do pipeline (`SELECT bronze.clientes` não encontra nada).

**Solução adotada:** `presets: { trigger_pause_status: PAUSED }` no target
dev. Isso pausa o agendamento do job sem mexer no nome dos recursos.

## 4. O Catálogo — `resources/catalogo.yml`

Três schemas (bronze/silver/gold) + 1 volume (`bronze.raw` MANAGED).

```
lakehouse_rotaperfume (catalog)
├── bronze (schema)
│   └── raw (Volume, MANAGED)  ← CSVs do ERP/CRM
├── silver (schema)
└── gold (schema)
```

**Por que Volume e não DBFS:** Volume é objeto do Unity Catalog. Tem dono,
tem permissão, aparece na linhagem. DBFS é uma pasta sem sobrenome.

**Por que MANAGED:** o ciclo de vida do arquivo é gerenciado pelo Unity Catalog
(permissão e auditoria herdam do schema).

## 5. Workaround Free Edition — `scripts/criar-catalogo.sh`

No Databricks Free Edition, o **Default Storage está ligado**, e a API do
Unity Catalog recusa criar catálogo por API:

```
Error: Metastore storage root URL does not exist.
       Default Storage is enabled in your account. (400 INVALID_STATE)
```

A API exige um MANAGED LOCATION que a conta gratuita não fornece. O workaround
é criar o catálogo por SQL, que não passa pela mesma checagem:

```bash
databricks experimental aitools tools query \
  "CREATE CATALOG IF NOT EXISTS lakehouse_rotaperfume" \
  --profile joaogui21@hotmail.com
```

**Sequência obrigatória:**

```bash
# 1. Catálogo PRIMEIRO (workaround)
bash scripts/criar-catalogo.sh joaogui21@hotmail.com

# 2. Bundle (cria schemas e volume por API)
databricks bundle deploy --target dev --profile joaogui21@hotmail.com

# 3. CSVs (volume tem que existir antes)
bash scripts/subir-raw.sh joaogui21@hotmail.com

# 4. Job (conferência de chegada)
databricks bundle run rotaperfume_pipeline --target dev --profile joaogui21@hotmail.com
```

A ordem importa: catálogo → schemas/volume → arquivos → job.

## 6. A Conferência de Chegada — `src/raw/conferencia.py`

Serverless notebook que faz a **conferência de chegada** do raw:

1. Lê o parâmetro `catalog` via `dbutils.widgets`.
2. Lista os 10 arquivos esperados em `/Volumes/{catalog}/bronze/raw/{sistema}/`.
3. Para cada um: mede bytes e conta linhas.
4. Grava `bronze._raw_arquivos` com `(sistema, arquivo, bytes, linhas, conferido_em)`.
5. Se faltar arquivo ou algum vier vazio: levanta exceção e interrompe.
6. Imprime tabela legível no final.

**Por que essa tarefa é importante:** o erro mais caro de pipeline não é o
que quebra — é o arquivo que não chegou e ninguém viu. Ele não dá erro: dá
número menor, e o dashboard mostra metade da receita com cara de número certo.

**Validação de arquivos:**

| Sistema | Tabelas |
|---------|---------|
| ERP | produtos, pedidos, itens_pedido, pagamentos, estoque |
| CRM | clientes, vendedores, carteira, oportunidades, visitas |

## 7. O Job — `resources/pipeline.job.yml`

```yaml
resources:
  jobs:
    rotaperfume_pipeline:
      name: rotaperfume_pipeline
      schedule:
        quartz_cron_expression: "0 0 6 * * ?"
        timezone_id: America/Sao_Paulo
      tasks:
        - task_key: raw_conferencia
          notebook_task:
            notebook_path: ../src/raw/conferencia.py
            base_parameters:
              catalog: ${var.catalog}
```

Serverless (sem `new_cluster`, sem `job_cluster_key`). O Databricks
provisiona compute automaticamente no Free Edition.

**Cabeçalho do YAML** contém o roadmap dos 6 deploys com a sequência de
tarefas — referência para quem evoluir o bundle depois.

## 8. Como Verificar

### 8.1 O catálogo inteiro existe, e nasceu de trinta linhas de YAML

```sql
SHOW SCHEMAS IN lakehouse_rotaperfume;
-- bronze, silver, gold

DESCRIBE VOLUME lakehouse_rotaperfume.bronze.raw;

SELECT schema_name, comment
FROM lakehouse_rotaperfume.information_schema.schemata
WHERE schema_name IN ('bronze', 'silver', 'gold');
```

### 8.2 Os 10 arquivos chegaram ao Volume

```sql
LIST '/Volumes/lakehouse_rotaperfume/bronze/raw/erp';
LIST '/Volumes/lakehouse_rotaperfume/bronze/raw/crm';
```

### 8.3 A conferência de chegada registrou o que chegou

```sql
SELECT sistema, arquivo, bytes, linhas, conferido_em
FROM lakehouse_rotaperfume.bronze._raw_arquivos
ORDER BY linhas DESC;

SELECT COUNT(*)                        AS arquivos,
       SUM(linhas)                     AS linhas_de_dado,
       ROUND(SUM(bytes)/1024/1024, 1)  AS mb
FROM lakehouse_rotaperfume.bronze._raw_arquivos;
```

| Esperado | Valor |
|---|---|
| Arquivos conferidos | 10 |
| Linhas de dado | 313.551 |
| Tamanho total | 14,7 MB |
| Maior arquivo | itens_pedido.csv · 197.724 |

### 8.4 A prova de que é código, não clique

```sql
DROP SCHEMA lakehouse_rotaperfume.gold;
SHOW SCHEMAS IN lakehouse_rotaperfume;
-- gold sumiu
```

```bash
databricks bundle deploy --target dev --profile joaogui21@hotmail.com
```

```sql
SHOW SCHEMAS IN lakehouse_rotaperfume;
-- gold voltou idêntico, em segundos
```

### 8.5 A prova de que a conferência serve para alguma coisa

```bash
# Quebrar de propósito: apagar um arquivo
databricks fs rm dbfs:/Volumes/lakehouse_rotaperfume/bronze/raw/erp/pagamentos.csv \
  --profile joaogui21@hotmail.com

databricks bundle run rotaperfume_pipeline --target dev --profile joaogui21@hotmail.com
# a tarefa raw_conferencia FALHA e o job para: falta pagamentos.csv

# Restaurar
bash scripts/subir-raw.sh joaogui21@hotmail.com
```

## 9. Decisões e Princípios

| Decisão | Motivo |
|---------|--------|
| Catálogo via SQL, não bundle | API Free Edition recusa `CREATE CATALOG` por Default Storage |
| `presets.trigger_pause_status: PAUSED` no dev | Pausa agendamento sem prefixar nomes |
| Volume MANAGED, não EXTERNAL | Auditoria e permissão herdam do schema |
| Tabela `_raw_arquivos` na bronze | Rastro de auditoria de quem chegou e quando |
| Tarefa de conferência ANTES de tudo | Arquivo que não chega dá "número menor", não erro |
| Serverless everywhere | Free Edition não permite cluster manual |

## 10. Próximo Deploy

Deploy #2 (Bronze): lê os 10 CSVs do Volume e grava 10 tabelas Delta,
preservando a sujeira — nada de CAST, nada de inferSchema.
