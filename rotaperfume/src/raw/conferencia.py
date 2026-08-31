# Databricks notebook source
# ----------------------------------------------------------------------
# Tarefa: CONFERENCIA DE CHEGADA (Arrival Verification)
# Job: rotaperfume_pipeline -- tarefa 1 de N
#
# Evolucao do job (Deploys 2-6):
#   [2-3] bronze_ingestao_erp/crm  -- DLT ingestando CSVs em tabelas bronze
#   [4-5] silver_limpeza_erp/crm   -- deduplicacao e limpeza
#   [6-7] gold_agregados + dim     -- metricas e dimensoes
#   [8]   qualidade_dados            -- testes de qualidade
#   [9-10] gold_dashboards + enrich -- metricas e enriquecimento
# ----------------------------------------------------------------------

from pyspark.sql import SparkSession
from pyspark.sql.types import StructType, StructField, StringType, LongType, TimestampType
from datetime import datetime, timezone
import os


# ----------------------------------------------------------------------
# 1. Parametro catalog via dbutils.widgets
# ----------------------------------------------------------------------
# Declara o widget com default "" (string vazia). Quando a tarefa do job
# passa catalog via base_parameters, esse valor e injetado em runtime.
dbutils.widgets.text("catalog", "", "Catalogo Unity Catalog")
catalog = dbutils.widgets.get("catalog")

if not catalog or not catalog.strip():
    raise ValueError(
        "Parametro 'catalog' e obrigatorio. "
        "Passe catalog=lakehouse_rotaperfume na tarefa do job."
    )

catalog = catalog.strip()
print(f"Usando catalog: {catalog}")

spark = SparkSession.builder.getOrCreate()


# ----------------------------------------------------------------------
# 2. Arquivos esperados
# ----------------------------------------------------------------------
BASE_PATH = f"/Volumes/{catalog}/bronze/raw"

ARQUIVOS_ESPERADOS = {
    "erp": [
        "produtos.csv",
        "pedidos.csv",
        "itens_pedido.csv",
        "pagamentos.csv",
        "estoque.csv",
    ],
    "crm": [
        "clientes.csv",
        "vendedores.csv",
        "carteira.csv",
        "oportunidades.csv",
        "visitas.csv",
    ],
}

TODOS_ARQUIVOS = [
    (sistema, arquivo)
    for sistema, arquivos in ARQUIVOS_ESPERADOS.items()
    for arquivo in arquivos
]


# ----------------------------------------------------------------------
# 3. Verifica existencia, tamanho e linhas de cada arquivo
# ----------------------------------------------------------------------
resultados = []
erros = []

for sistema, arquivo in TODOS_ARQUIVOS:
    caminho = f"{BASE_PATH}/{sistema}/{arquivo}"

    if not os.path.exists(caminho):
        erros.append(f"[FALTA] {sistema}/{arquivo} -- arquivo nao encontrado")
        continue

    tamanho_bytes = os.path.getsize(caminho)
    if tamanho_bytes == 0:
        erros.append(f"[VAZIO] {sistema}/{arquivo} -- 0 bytes")
        continue

    with open(caminho, "r", encoding="utf-8", errors="replace") as f:
        linhas = sum(1 for _ in f) - 1  # -1: cabecalho CSV

    resultados.append({
        "sistema": sistema,
        "arquivo": arquivo,
        "bytes": tamanho_bytes,
        "linhas": linhas,
        "conferido_em": datetime.now(timezone.utc),
    })


# ----------------------------------------------------------------------
# 4. Se algum arquivo falta ou esta vazio: levanta excecao
# ----------------------------------------------------------------------
if erros:
    print("=" * 60)
    print("CONFERENCIA DE CHEGADA -- FALHOU")
    print("=" * 60)
    for e in erros:
        print(f"  {e}")
    raise Exception(
        f"Conferencia falhou: {len(erros)} problema(s) encontrado(s). "
        "Verifique se todos os arquivos foram carregados no Volume."
    )


# ----------------------------------------------------------------------
# 5. Grava bronze._raw_arquivos
# ----------------------------------------------------------------------
schema = StructType([
    StructField("sistema", StringType(), False),
    StructField("arquivo", StringType(), False),
    StructField("bytes", LongType(), False),
    StructField("linhas", LongType(), False),
    StructField("conferido_em", TimestampType(), False),
])
df = spark.createDataFrame(resultados, schema=schema)
TABLENAME = f"{catalog}.bronze._raw_arquivos"

spark.sql(f"DROP TABLE IF EXISTS {TABLENAME}")
df.write.mode("overwrite").format("delta").saveAsTable(TABLENAME)

# COMMENTs na tabela e colunas (documentacao viva no metastore)
spark.sql(
    f"COMMENT ON TABLE {TABLENAME} IS "
    "'Controle de chegada: arquivos crus que pousaram no Volume bronze.raw.'"
)
spark.sql(f"COMMENT ON COLUMN {TABLENAME}.sistema IS 'Sistema de origem: erp ou crm'")
spark.sql(f"COMMENT ON COLUMN {TABLENAME}.arquivo IS 'Nome do arquivo no Volume'")
spark.sql(f"COMMENT ON COLUMN {TABLENAME}.bytes IS 'Tamanho em bytes'")
spark.sql(
    f"COMMENT ON COLUMN {TABLENAME}.linhas IS "
    "'Linhas de dado (exclui linha de cabecalho do CSV)'"
)
spark.sql(f"COMMENT ON COLUMN {TABLENAME}.conferido_em IS 'Timestamp UTC da conferencia'")


# ----------------------------------------------------------------------
# 6. Tabela legivel ao final
# ----------------------------------------------------------------------
print("=" * 60)
print("CONFERENCIA DE CHEGADA -- SUCESSO")
print("=" * 60)
print(f"Catalogo: {catalog}")
print(f"Volume:   /Volumes/{catalog}/bronze/raw")
print(f"Arquivos conferidos: {len(resultados)}")
print("")
print(f"{'Sistema':<8} {'Arquivo':<20} {'Bytes':>12} {'Linhas':>10}")
print("-" * 55)

total_bytes = 0
total_linhas = 0
for r in sorted(resultados, key=lambda x: x["sistema"]):
    print(f"{r['sistema']:<8} {r['arquivo']:<20} {r['bytes']:>12,} {r['linhas']:>10,}")
    total_bytes += r["bytes"]
    total_linhas += r["linhas"]

print("-" * 55)
print(f"{'TOTAL':<28} {total_bytes:>12,} {total_linhas:>10,}")
print("")
print(f"-> Tabela de controle: {TABLENAME}")
