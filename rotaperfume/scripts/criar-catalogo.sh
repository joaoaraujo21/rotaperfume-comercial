#!/usr/bin/env bash
# =============================================================================
# Cria o catalogo lakehouse_rotaperfume no Unity Catalog via SQL.
#
# POR QUE NAO ESTA NO BUNDLE (resources/*.yml):
#
#   No Databricks Free Edition, o Default Storage esta habilitado. Quando a API
#   REST do Unity Catalog tenta criar um catalogo, ela exige um storage_root
#   (MANAGED LOCATION). O Free Edition nao permite configurar isso, e a API
#   retorna:
#
#     Error: Metastore storage root URL does not exist.
#            Default Storage is enabled in your account. (400 INVALID_STATE)
#
#   O comando SQL `CREATE CATALOG IF NOT EXISTS` funciona porque o SQL Engine
#   delega a criacao ao metastore, que usa a configuracao de Default Storage
#   ja existente. O bundle (que usa a API REST) nao tem essa flexibilidade.
#
#   Por isso: catalogo = script SQL (aqui); schemas + volumes = bundle.
# =============================================================================

set -euo pipefail

PROFILE="${1:-}"

if [[ -z "$PROFILE" ]]; then
    echo "ERRO: passe o profile como primeiro argumento." >&2
    echo "Uso: $0 <profile>" >&2
    echo "Exemplo: $0 projeto-dados-ia" >&2
    exit 1
fi

CATALOG_NAME="lakehouse_rotaperfume"

echo "==> Criando catalogo '$CATALOG_NAME' via SQL no profile '$PROFILE'..."

databricks experimental aitools tools query \
    --profile "$PROFILE" \
    "CREATE CATALOG IF NOT EXISTS ${CATALOG_NAME}"

echo "==> Catalogo '$CATALOG_NAME' criado (ou ja existia)."
echo ""
echo "Verifique com:"
echo "  databricks catalogs get ${CATALOG_NAME} --profile $PROFILE"
echo "  SHOW CATALOGS LIKE 'lakehouse_rotaperfume';"
