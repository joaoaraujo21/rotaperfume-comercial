#!/usr/bin/env bash
# =============================================================================
# Sobe os 10 CSVs de dados/erp e dados/crm para o Volume bronze.raw.
#
# ARMADILHA COMUM: o comando `databricks fs cp` EXIGE o esquema `dbfs:` no
# destino, mesmo quando o destino e um Volume do Unity Catalog:
#   CERTO:   dbfs:/Volumes/lakehouse_rotaperfume/bronze/raw/erp
#   ERRADO:  /Volumes/lakehouse_rotaperfume/bronze/raw/erp
#
# Se dados/ nao existir (clonou o repo agora), gere antes com:
#   python3 material/gerar_dataset.py --saida ./dados --seed 42
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

# dados/ esta na raiz do repo (dois niveis acima de onde este script vive: scripts/ -> rotaperfume/ -> repo/).
# O script pode ser chamado de qualquer lugar, entao resolvemos o caminho
# relativo ao proprio script para encontrar dados/.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
DADOS_DIR="${REPO_ROOT}/dados"

if [[ ! -d "$DADOS_DIR/erp" ]] || [[ ! -d "$DADOS_DIR/crm" ]]; then
    echo "ERRO: $DADOS_DIR/erp ou $DADOS_DIR/crm nao existem." >&2
    echo "Gere com: python3 material/gerar_dataset.py --saida ./dados --seed 42" >&2
    exit 1
fi

echo "==> Upload dados/erp/*  -> dbfs:/Volumes/${CATALOG_NAME}/bronze/raw/erp"
databricks fs cp \
    --recursive \
    --overwrite \
    "${DADOS_DIR}/erp/" \
    "dbfs:/Volumes/${CATALOG_NAME}/bronze/raw/erp" \
    --profile "$PROFILE"

echo ""
echo "==> Upload dados/crm/*  -> dbfs:/Volumes/${CATALOG_NAME}/bronze/raw/crm"
databricks fs cp \
    --recursive \
    --overwrite \
    "${DADOS_DIR}/crm/" \
    "dbfs:/Volumes/${CATALOG_NAME}/bronze/raw/crm" \
    --profile "$PROFILE"

echo ""
echo "==> Upload concluido."
echo ""
echo "Verifique com:"
echo "  databricks fs ls dbfs:/Volumes/${CATALOG_NAME}/bronze/raw/erp --profile $PROFILE"
echo "  databricks fs ls dbfs:/Volumes/${CATALOG_NAME}/bronze/raw/crm --profile $PROFILE"
