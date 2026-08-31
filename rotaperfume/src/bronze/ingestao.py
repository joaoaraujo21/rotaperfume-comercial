# Databricks notebook source
# ----------------------------------------------------------------------
# Tarefa: BRONZE INGESTAO (Raw -> Bronze)
# Job: rotaperfume_pipeline -- tarefa 2 de N
#
# Le os 10 CSVs do Volume bronze.raw e grava tabelas Delta em bronze.
#
# REGRAS DA BRONZE (nenhuma limpeza, nenhuma conversao de tipo):
#   - Tudo lido como STRING -- nenhum inferSchema.
#   - CSVs com header e CRLF. Sem multiLine.
#   - Apenas 2 colunas de auditoria: _ingerido_em (timestamp) e
#     _arquivo_origem (nome do arquivo de origem).
#   - Funcao UNICA de ingestao -- itera sobre a lista das 10 tabelas.
#     Naum repete bloco por tabela.
#
# Contagens esperadas (seed 42):
#   produtos 292 | pedidos 28.729 | itens_pedido 197.724 | pagamentos 27.772
#   estoque 8.400 | clientes 3.040 | vendedores 42 | carteira 3.637
#   oportunidades 5.979 | visitas 37.936   TOTAL: 313.551
# ----------------------------------------------------------------------

from pyspark.sql import SparkSession
from pyspark.sql.functions import current_timestamp, lit


# ----------------------------------------------------------------------
# 1. Parametro catalog via dbutils.widgets
# ----------------------------------------------------------------------
dbutils.widgets.text("catalog", "", "Catalogo Unity Catalog")
catalog = dbutils.widgets.get("catalog").strip()
if not catalog:
    raise ValueError(
        "Parametro 'catalog' e obrigatorio. "
        "Passe catalog=lakehouse_rotaperfume na tarefa do job."
    )
print(f"Usando catalog: {catalog}")

spark = SparkSession.builder.getOrCreate()


# ----------------------------------------------------------------------
# 2. Lista das 10 tabelas
#    Tupla: (sistema, subpath_no_volume, table_name, file_name)
# ----------------------------------------------------------------------
TABELAS = [
    # ERP
    ("erp", "erp", "produtos",      "produtos.csv"),
    ("erp", "erp", "pedidos",       "pedidos.csv"),
    ("erp", "erp", "itens_pedido",  "itens_pedido.csv"),
    ("erp", "erp", "pagamentos",    "pagamentos.csv"),
    ("erp", "erp", "estoque",       "estoque.csv"),
    # CRM
    ("crm", "crm", "clientes",      "clientes.csv"),
    ("crm", "crm", "vendedores",    "vendedores.csv"),
    ("crm", "crm", "carteira",      "carteira.csv"),
    ("crm", "crm", "oportunidades", "oportunidades.csv"),
    ("crm", "crm", "visitas",       "visitas.csv"),
]


# ----------------------------------------------------------------------
# 3. Funcao UNICA de ingestao
#    Le 1 CSV do Volume e grava 1 tabela Delta em {catalog}.bronze.{table}.
#    Retorna o numero de linhas ingeridas.
# ----------------------------------------------------------------------
def ingest_csv(sistema: str, subpath: str, table_name: str, file_name: str) -> int:
    """Ingere um CSV do Volume como tabela Delta no schema bronze.

    Regras:
      - Tudo string: inferSchema=False (default, mas documentado).
      - Sem multiLine: CSVs tem header mas nenhum campo com newline dentro.
      - 2 colunas de auditoria: _ingerido_em e _arquivo_origem.
    """
    volume_path = f"/Volumes/{catalog}/bronze/raw/{subpath}/{file_name}"
    print(f"--> {sistema}/{table_name}: lendo {volume_path}")

    # Leitura: TUDO como string, sem inferencia de tipo
    df = (
        spark.read
        .format("csv")
        .option("header", "true")
        .option("inferSchema", "false")    # REGRIA DA BRONZE: tudo string
        .option("multiLine", "false")      # sem newline dentro de campos
        .option("escape", '"')
        .option("quote", '"')
        .load(volume_path)
    )

    # Auditoria: apenas 2 colunas (nomes exatos do prompt)
    df_audit = (
        df
        .withColumn("_ingerido_em",   current_timestamp())
        .withColumn("_arquivo_origem", lit(file_name))
    )

    full_table = f"{catalog}.bronze.{table_name}"

    # Grava como Delta (overwrite = idempotente)
    (
        df_audit.write
        .format("delta")
        .mode("overwrite")
        .option("overwriteSchema", "true")
        .saveAsTable(full_table)
    )

    # COMMENT documentando a origem e a regra de string
    spark.sql(
        f"COMMENT ON TABLE {full_table} IS "
        f"'Bronze {sistema.upper()}: {table_name} (origem: {file_name}). "
        f"Tudo como STRING -- nenhuma limpeza, conversao ou filtro. Sujeira preservada.'"
    )

    num_linhas = df_audit.count()
    print(f"    {num_linhas:,} linhas | {len(df_audit.columns)} colunas")
    return num_linhas


# ----------------------------------------------------------------------
# 4. Itera sobre a lista -- funcao chamada 10 vezes, nao 10 blocos
# ----------------------------------------------------------------------
resultados = []

for sistema, subpath, table_name, file_name in TABELAS:
    n = ingest_csv(sistema, subpath, table_name, file_name)
    resultados.append((sistema, table_name, n))


# ----------------------------------------------------------------------
# 5. Resumo e validacao de contagem contra _raw_arquivos
# ----------------------------------------------------------------------
print("")
print("=" * 60)
print("BRONZE INGESTAO -- RESUMO")
print("=" * 60)
print(f"{'Sistema':<8} {'Tabela':<18} {'Linhas':>12}")
print("-" * 45)

total = 0
erros_contagem = []

for sistema, table_name, n in resultados:
    print(f"{sistema:<8} {table_name:<18} {n:>12,}")
    total += n

print("-" * 45)
print(f"{'TOTAL':<26} {total:>12,}")
print("")

# Validacao contra bronze._raw_arquivos (registro do prompt 1)
print("Validando contagem contra bronze._raw_arquivos...")

raw_rows = {
    row["arquivo"]: row["linhas"]
    for row in spark.sql(
        f"SELECT arquivo, linhas FROM {catalog}.bronze._raw_arquivos"
    ).collect()
}

for sistema, table_name, n in resultados:
    csv_name = table_name + ".csv"
    raw_n = raw_rows.get(csv_name, -1)
    if n != raw_n:
        erros_contagem.append(
            f"  {sistema}/{table_name}: bronze={n:,}, raw={raw_n:,} (diff={n - raw_n:+d})"
        )
        print(f"  {sistema}/{table_name}: DIVERGENCIA -- bronze={n:,}, raw={raw_n:,}")
    else:
        print(f"  {sistema}/{table_name}: OK ({n:,} linhas)")

if erros_contagem:
    print("")
    print("DIVERGENCIAS ENCONTRADAS:")
    for e in erros_contagem:
        print(e)
    raise Exception(
        f"Ingestao falhou: {len(erros_contagem)} tabela(s) com contagem diferente "
        "do arquivo de origem. Verifique a leitura do CSV."
    )

print("")
print(f"SUCESSO: 10 tabelas bronze ingeridas ({total:,} linhas total).")
print("Todas as colunas sao STRING de propsito -- sujeira preservada.")
