# Documento 07 — Treino do Modelo e MLflow

**Deploy:** #2 da noite ML
**Tarefa:** `ml_modelo` (tarefa 13 do pipeline)
**Artefato:** `src/ml/12-modelo.py`
**Tabelas geradas:** `gold.score_propensao`, `gold.modelo_metricas`, `gold.calibragem_holdout`
**Modelo registrado:** `lakehouse_rotaperfume.gold.propensao_compra` (alias `@prod`)

---

## O que foi feito

O módulo `12-modelo.py` implementa o ciclo completo de ML:

1. **Baseline** — 3 regras simples vs. moeda (holdout 25%)
2. **Treino** — `HistGradientBoostingClassifier` + 5-fold CV out-of-fold
3. **Métricas** — AUC (holdout) + lift_top200 (OOF)
4. **Importância** — permutation importance no holdout (top 10)
5. **MLflow** — experimento + registro no UC + alias `@prod`
6. **Testes** — 3 asserts que interrompem a tarefa
7. **Score** — todos os 2.816 clientes em `gold.score_propensao`
8. **Tabelas de auditoria** — `gold.modelo_metricas` + `gold.calibragem_holdout`

### O baseline — a régua que a sala não espera

Antes de qualquer modelo, o código avalia 3 regras simples no holdout (25%, estratificado):

| Estratégia | AUC |
|---|---|
| "ligue para quem comprou recentemente" (`-recencia_dias`) | 0,3522 |
| moeda (aleatório) | 0,5000 |
| "ligue para quem compra mais" (`valor_total`) | 0,6410 |
| "ligue para quem está atrasado" (`atraso_relativo`) | 0,7842 |

**`atraso_relativo` sozinho supera valor_total e recência.** Essa feature inventada no documento anterior já é melhor que as duas regras que a intuição comercial sugere. O modelo vai superar isso — mas a régua é definida aqui.

### O algoritmo

```python
HistGradientBoostingClassifier(
    random_state=42,
    max_iter=200,
    learning_rate=0.1,
    max_depth=6,
)
```

**Não é XGBoost.** XGBoost treina e registra, mas falha ao carregar de volta no serverless por conflito com `sklearn 1.6.1` (`__sklearn_tags__`). `HistGradientBoostingClassifier` trata `NaN` nativamente — não requer imputação, e as features de ritmo são `NULL` de propósito para clientes com um pedido só.

### As duas métricas

**AUC (holdout)** — área sob a curva ROC no holdout de 25%. Métrica de quem treina.

**Lift top 200 (OOF)** — a métrica que o diretor entende:
- Pontua todos os 2.816 clientes por validação cruzada out-of-fold (5 folds, shuffle, seed=42)
- Ordena por score e pega os 200 primeiros
- Divide a taxa de compra desses 200 pela taxa base (aleatória)

```sql
SELECT ROUND(100 * taxa_base, 1) AS aleatorio,
       acertos_top200 AS na_fila,
       ROUND(lift_top200, 2) AS lift,
       ROUND(auc, 4) AS auc
FROM lakehouse_rotaperfume.gold.modelo_metricas
ORDER BY _treinado_em DESC LIMIT 1;
-- Esperado: ~10% aleatório, ~86 acertos (4,25× lift), AUC ~0,88
```

### Os 3 testes que interrompem o job

| Teste | Condição | Por quê |
|---|---|---|
| 1 | `auc >= melhor_baseline + 0.05` | Modelo precisa superar a melhor regra simples por 5 pontos |
| 2 | `auc < 0.99` | Bom demais é vazamento, não competência |
| 3 | `lift_top200 >= 2.5` | Abaixo disso a fila não justifica o projeto |

> **Vazamento parece sucesso.** É o único erro de ML que chega com print no grupo. A defesa não é atenção — é estrutural: função com data por parâmetro, coluna `_referencia` gravada, e o teste 2.

---

## Arquitetura de MLflow

```
Experimento: /Users/joaogui21@hotmail.com/mlflow/propensao-compra
Registro:    databricks-uc (Unity Catalog)
Modelo:       lakehouse_rotaperfume.gold.propensao_compra
Alias:        @prod (aponta para a versão mais recente)
```

O modelo é um **objeto do catálogo**, não um arquivo. Mesmo catálogo das tabelas, mesmo GRANT, mesma linhagem. Se alguém sair da empresa, o modelo continua no catálogo.

---

## Armadilhas resolvidas

| Armadilha | Problema | Solução |
|---|---|---|
| Pasta pai não existe | `set_experiment` falha com `BAD_REQUEST: For input string: None` | `WorkspaceClient().workspace.mkdirs()` antes |
| XGBoost + sklearn 1.6.1 | `AttributeError: __sklearn_tags__` | `HistGradientBoostingClassifier` |
| `pyfunc.spark_udf` no serverless | `InvalidVersion: '18.x-aarch64-photon-scala2'` | `mlflow.sklearn.load_model()` + pandas |
| `predict` devolve classe | score vira só 0 e 1 | `predict_proba()[:, 1]` |
| Decimal não serializável | feature `DECIMAL` quebra registro | `.cast("double")` no prompt de features |

---

## Tabelas geradas

### `gold.score_propensao`
Cada cliente com score e faixa. Alimenta a `fila_semanal` e o dashboard.

| Coluna | Tipo | Descrição |
|---|---|---|
| `cliente_id` | STRING | Identificador do cliente |
| `score` | DOUBLE | Probabilidade de comprar em 7 dias (0 a 1) |
| `faixa` | STRING | NTILE(4): Fria, Morna, Quente, Muito quente |
| `_referencia` | DATE | Data de corte das features (2026-08-31) |
| `_versao_modelo` | INT | Versão do modelo que gerou o score |
| `_processado_em` | TIMESTAMP | Timestamp de execução |

### `gold.modelo_metricas`
Uma linha por treino. Permite comparar versões ao longo do tempo.

| Coluna | Descrição |
|---|---|
| `versao` | Número da versão do modelo |
| `auc` | AUC no holdout |
| `lift_top200` | Lift dos 200 primeiros (vs. aleatório) |
| `acertos_top200` | Quantos dos 200 compraram |
| `taxa_base` | Taxa de compra aleatória |
| `auc_recencia`, `auc_valor`, `auc_atraso` | AUC de cada baseline |
| `feature_1` | Feature mais importante (permutation importance) |
| `_treinado_em` | Timestamp do treino |

### `gold.calibragem_holdout`
Prova de que o score ordena, sem falar em AUC.

```sql
SELECT faixa, clientes, compraram,
       ROUND(100 * taxa_de_compra, 1) AS pct_que_comprou
FROM lakehouse_rotaperfume.gold.calibragem_holdout
ORDER BY score_medio;
-- Esperado: taxa sobe de Fria para Muito quente
```

---

## Como verificar

```sql
-- A resposta para o diretor (sem falar em ML)
SELECT ROUND(100 * taxa_base, 1) AS aleatorio,
       acertos_top200 AS na_fila,
       ROUND(lift_top200, 2) AS lift
FROM lakehouse_rotaperfume.gold.modelo_metricas
ORDER BY _treinado_em DESC LIMIT 1;
```

```sql
-- Top 10 features por permutation importance
SELECT feature, importancia
FROM lakehouse_rotaperfume.gold.modelo_metricas m
CROSS JOIN UNNEST(ARRAY['atraso_relativo']) -- ver no notebook
-- As features impressas estão no output da tarefa ml_modelo
```

```bash
# O modelo é um objeto do catálogo
databricks model-versions get-by-alias \
  lakehouse_rotaperfume.gold.propensao_compra prod \
  --profile joaogui21@hotmail.com
```

---

## Relacionamento com outros documentos

- [Documento_06_Features.md](Documento_06_Features.md) — as 20 features consumidas pelo modelo
- [Documento_08_Fila_e_Agente.md](Documento_08_Fila_e_Agente.md) — a fila que usa `score_propensao` e o Genie Space que consulta as tabelas de métricas
