# Documento 06 — Features de Cliente para Machine Learning

**Deploy:** #1 da noite ML
**Tarefa:** `ml_features` (tarefa 12 do pipeline)
**Artefato:** `src/ml/11-features.py`
**Tabelas geradas:** `gold.features_treino`, `gold.features_cliente`

---

## O que foi feito

O módulo `11-features.py` gera **20 features por cliente** usando uma única função `montar_features(referencia, with_label)` que é chamada duas vezes com datas de corte diferentes:

| Tabela | Referência | Label |
|---|---|---|
| `gold.features_treino` | 2026-08-01 | `comprou_em_7d` (1 se comprou entre 01/08 e 07/08) |
| `gold.features_cliente` | 2026-08-31 | nenhum (é o que será pontuado) |

Essa arquitetura de **uma função, dois usos** garante que treino e score nunca divirjam — o que o Feature Store resolve com infraestrutura, aqui está resolvido com um `def`.

### As 20 features em 4 grupos

**RFM (6 features)**
- `recencia_dias` — dias desde o último pedido (vs. referência)
- `frequencia_pedidos` — número de pedidos distintos
- `valor_total` — soma de receita (devoluções entram negativas)
- `ticket_medio` — `valor_total / frequencia`
- `margem_total` — soma de margem
- `margem_percentual` — `margem_total / valor_total`

**Ritmo (4 features)**
- `intervalo_medio_dias` — média dos intervalos entre pedidos consecutivos
- `desvio_intervalo_dias` — desvio padrão desses intervalos
- `atraso_relativo` — `recencia / intervalo_medio` (teto em 10×, NULL se 1 pedido só)
- `pedidos_ultimos_90d` — pedidos distintos nos 90 dias antes do corte

**CRM (5 features)**
- `oportunidades_abertas` — oportunidades nem ganha nem perdida
- `oportunidades_ganhas` — oportunidades fechadas como ganha
- `taxa_ganho` — `ganhas / total`
- `visitas_90d` — visitas nos 90 dias antes do corte
- `conversao_visita` — visitas que geraram pedido

**Mix (5 features)**
- `skus_distintos` — variedade de produtos
- `categorias_distintas` — variedade de categorias
- `marcas_distintas` — variedade de marcas
- `concentracao_marca_top` — fatia de receita da marca favorita
- `comprou_lancamento` — comprou SKU lançado nos 120 dias antes do corte

### Princípios de design

**Nenhum vazamento.** Todas as fontes são filtradas por `< referencia` na primeira linha da leitura. Se qualquer coluna souber do futuro (data > referência), o AUC do modelo vem 0,98 e ninguém percebe — até o modelo quebrar em produção.

**Cliente sem atividade recebe 0, não NULL.** Oportunidades, visitas e mix usam `COALESCE(..., 0)`. Apenas as features de ritmo (intervalo e desvio) podem ser NULL — quando há menos de 2 pedidos, não há intervalo para medir.

**Decimal não entra no modelo.** Todas as colunas numéricas são `cast("double")` antes da gravação. Soma de receita vem do Delta como `DECIMAL(18,2)`, que não é JSON-serializable e quebra o registro do modelo.

---

## Arquitetura de dados

```
gold.fato_vendas         (data_pedido < referencia)
    └── joins com silver.pedidos + silver.itens_pedido para pedido_id
    └── joins com gold.dim_produto (data_lancamento) para lancamentos

silver.oportunidades     (data_abertura < referencia)
silver.visitas          (data_visita < referencia)

Output: 1 linha por cliente_id
        20 features + _referencia + _processado_em
        Se with_label=True: + comprou_em_7d
```

---

## Armadilhas resolvidas

| Armadilha | Problema | Solução |
|---|---|---|
| `F.least()` ignora NULL | Clientes de 1 pedido ficavam com `atraso_relativo=10` (teto) | `when(intervalo_medio_dias IS NOT NULL ...)` antes do `least()` |
| Célula `%md` não define função | Markdown no início da célula impede a definição de `montar_features()` | `# COMMAND ----------` antes de todo código |
| Decimal não serializável | `DECIMAL(18,2)` quebra `mlflow.sklearn.log_model()` | `.cast("double")` em todas as 21 colunas numéricas |
| `current_date()` no código | Data de corte vira "hoje real" em vez de 2026-08-31 | Parâmetro `referencia` em todas as leituras |

---

## Como verificar

```sql
-- As duas tabelas nascem do mesmo corte, declarado como coluna
SELECT '_treino' AS tabela, COUNT(*) AS clientes, MIN(_referencia) AS corte
FROM lakehouse_rotaperfume.gold.features_treino
UNION ALL
SELECT '_cliente', COUNT(*), MIN(_referencia)
FROM lakehouse_rotaperfume.gold.features_cliente;
-- Esperado: 2.815 / 2026-08-01 e 2.816 / 2026-08-31
```

```sql
-- Taxa base (o número que o prompt 2 usa como régua)
SELECT COUNT(*) AS clientes,
       SUM(comprou_em_7d) AS compraram,
       ROUND(100 * AVG(comprou_em_7d), 2) AS taxa_base_pct
FROM lakehouse_rotaperfume.gold.features_treino;
-- Esperado: 2.815 clientes, taxa base ~10,12%
```

```sql
-- A feature que ordena a fila
SELECT c.razao_social,
       f.recencia_dias,
       ROUND(f.intervalo_medio_dias, 1) AS intervalo,
       ROUND(f.atraso_relativo, 1) AS atraso
FROM lakehouse_rotaperfume.gold.features_cliente f
JOIN lakehouse_rotaperfume.gold.dim_cliente c USING (cliente_id)
ORDER BY f.atraso_relativo DESC NULLS LAST LIMIT 10;
```

```sql
-- Prova de que não há vazamento: recência negativa = dado do futuro na feature
SELECT MIN(recencia_dias) AS menor_recencia
FROM lakehouse_rotaperfume.gold.features_treino;
-- Esperado: >= 0 (se negativo, alguma fonte escapou do filtro < referencia)
```

---

## Estrutura das tabelas

**`gold.features_treino`** — 23 colunas
- `cliente_id` (INT), `_referencia` (DATE), 20 features numéricas (DOUBLE), `comprou_em_7d` (DOUBLE), `_processado_em` (TIMESTAMP)

**`gold.features_cliente`** — 22 colunas
- `cliente_id` (INT), `_referencia` (DATE), 20 features numéricas (DOUBLE), `_processado_em` (TIMESTAMP)

Ambas têm `COMMENT` em português documentando o propósito, gerado pelo notebook após `saveAsTable`.

---

## O que vem depois

| Próximo passo | O que muda |
|---|---|
| `ml_modelo` (tarefa 13) | Lê `features_treino` para treinar; `features_cliente` para pontuar |
| `ml_fila` (tarefa 14) | Lê `features_cliente` para escrever o motivo em português |

---

## Relacionamento com outros documentos

- [Documento_04_Gold.md](Documento_04_Gold.md) — as tabelas `gold.fato_vendas` e `gold.dim_produto` que alimentam as features
- [Documento_07_Modelo.md](Documento_07_Modelo.md) — o modelo que consome estas features
- [Documento_08_Fila_e_Agente.md](Documento_08_Fila_e_Agente.md) — o motivo em português gerado a partir destas features
