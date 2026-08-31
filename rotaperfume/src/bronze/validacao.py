# Databricks notebook source
# ----------------------------------------------------------------------
# Tarefa: BRONZE VALIDACAO (Bronze vs Raw)
# Job: rotaperfume_pipeline -- tarefa 3 de N (Deploy #2)
#
# Valida que cada tabela bronze tem o MESMO numero de linhas que o CSV
# correspondente no Volume. Isso garante que a ingestao nao perdeu dados.
#
# Para cada tabela bronze:
#   1. Conta linhas da tabela Delta
#   2. Compara com a contagem registrada em _raw_arquivos
#   3. Reporta OK ou DIVERGENCIA
#
# A contagem-alvo e o total de 313.551 linhas (10 tabelas, ver prompt_02.md).
# ----------------------------------------------------------------------

from pyspark.sql import SparkSession


# ----------------------------------------------------------------------
# 1. Parametro catalog via dbutils.widgets
# ----------------------------------------------------------------------
dbutils.widgets.text("catalog", "", "Catalogo Unity Catalog")
catalog = dbutils.widgets.get("catalog").strip()
if not catalog:
    raise ValueError("Parametro 'catalog' e obrigatorio.")
print(f"Usando catalog: {catalog}")

spark = SparkSession.builder.getOrCreate()


# ----------------------------------------------------------------------
# 2. Tabelas a validar
# ----------------------------------------------------------------------
TABELAS = [
    # (bronze_table, csv_file, sistema)
    ("produtos",      "produtos.csv",      "erp"),
    ("pedidos",       "pedidos.csv",       "erp"),
    ("itens_pedido",  "itens_pedido.csv",  "erp"),
    ("pagamentos",    "pagamentos.csv",     "erp"),
    ("estoque",       "estoque.csv",        "erp"),
    ("clientes",      "clientes.csv",       "crm"),
    ("vendedores",    "vendedores.csv",     "crm"),
    ("carteira",      "carteira.csv",       "crm"),
    ("oportunidades", "oportunidades.csv",  "crm"),
    ("visitas",       "visitas.csv",        "crm"),
]


# ----------------------------------------------------------------------
# 3. Consulta de referencia: _raw_arquivos
# ----------------------------------------------------------------------
raw_counts = {}
rows = spark.sql(
    f"SELECT arquivo, linhas FROM {catalog}.bronze._raw_arquivos"
).collect()
for row in rows:
    raw_counts[row["arquivo"]] = row["linhas"]


# ----------------------------------------------------------------------
# 4. Valida cada tabela bronze
# ----------------------------------------------------------------------
resultados = []
divergencias = []

for table, csv_file, sistema in TABELAS:
    bronze_table = f"{catalog}.bronze.{table}"

    # Conta linhas na tabela bronze
    bronze_count = spark.sql(f"SELECT COUNT(*) AS cnt FROM {bronze_table}").first()["cnt"]

    # Linha do _raw_arquivos (subtrai 1 porque CSV tem cabecalho)
    raw_count = raw_counts.get(csv_file, 0)

    match = (bronze_count == raw_count)
    diff = bronze_count - raw_count

    status = "OK" if match else "DIVERGENCIA"
    emoji = "✅" if match else "❌"

    resultados.append({
        "tabela": table,
        "sistema": sistema,
        "csv": csv_file,
        "bronze_linhas": bronze_count,
        "raw_linhas": raw_count,
        "diferenca": diff,
        "status": status,
    })

    if not match:
        divergencias.append(f"{emoji} {table}: bronze={bronze_count}, raw={raw_count} (diff={diff:+d})")

    print(f"{emoji} {sistema}/{table}: bronze={bronze_count:,} | raw={raw_count:,} | diff={diff:+d}")


# ----------------------------------------------------------------------
# 5. Resumo
# ----------------------------------------------------------------------
print("")
print("=" * 60)
print("BRONZE VALIDACAO -- RESUMO")
print("=" * 60)

total_bronze = sum(r["bronze_linhas"] for r in resultados)
total_raw    = sum(r["raw_linhas"] for r in resultados)
total_diff   = sum(r["diferenca"] for r in resultados)
num_ok       = sum(1 for r in resultados if r["status"] == "OK")
num_div      = len(resultados) - num_ok

print(f"Total bronze: {total_bronze:,} linhas")
print(f"Total raw:    {total_raw:,} linhas")
print(f"Diferenca:    {total_diff:+d} linhas")
print(f"Status:       {num_ok}/{len(resultados)} OK")
print("")

if divergencias:
    print("DIVERGENCIAS ENCONTRADAS:")
    for d in divergencias:
        print(f"  {d}")
    raise Exception(
        f"Validacao falhou: {num_div} tabela(s) com divergencia. "
        "Verifique a ingestao bronze."
    )
else:
    print("SUCESSO: Todos os dados conferem. Bronze == Raw.")
