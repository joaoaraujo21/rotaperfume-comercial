#!/usr/bin/env bash
# =============================================================================
# Roda UMA tarefa do pipeline em isolamento.
#
# Uso:
#   bash scripts/rodar-tarefa.sh <profile> <task_key>
#
# Exemplo:
#   bash scripts/rodar-tarefa.sh joaogui21@hotmail.com ml_features
#
# Vantagem: ~35s vs ~3m30 do job inteiro (13 tarefas serverless).
# =============================================================================

set -euo pipefail

PROFILE="${1:-}"
TASK="${2:-}"

if [[ -z "$PROFILE" ]]; then
    echo "ERRO: passe o profile como primeiro argumento." >&2
    echo "Uso: $0 <profile> <task_key>" >&2
    echo "Exemplo: $0 joaogui21@hotmail.com ml_features" >&2
    exit 1
fi

if [[ -z "$TASK" ]]; then
    echo "ERRO: passe a task_key como segundo argumento." >&2
    echo "Uso: $0 <profile> <task_key>" >&2
    echo "Exemplo: $0 joaogui21@hotmail.com ml_features" >&2
    exit 1
fi

echo "==> Rodando tarefa '${TASK}' no profile '${PROFILE}'..."
echo "    (~35s vs ~3m30 do job completo)"
echo ""

databricks bundle run rotaperfume_pipeline \
    --target dev \
    --profile "$PROFILE" \
    --only "$TASK"

echo ""
echo "==> Tarefa '${TASK}' concluida."
