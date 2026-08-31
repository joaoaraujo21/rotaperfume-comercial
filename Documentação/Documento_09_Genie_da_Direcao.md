# Documento 09 — O Genie da Direção e a Tabela de Retorno

**Deploy:** #1 da noite App & Genie (noite 4)
**Tarefa:** `gold_retorno_ligacao` (tarefa 11 do pipeline)
**Artefatos:**
- `src/gold/11-retorno-ligacao.sql`
- `resources/direcao.geniespace.json`
- `resources/genie-direcao.genie_space.yml`
- `resources/comercial.geniespace.json`
- `resources/genie-comercial.genie_space.yml`

**Tabelas/views geradas:**
- `gold.clientes_em_risco` (view)
- `gold.ranking_marcas` (view)
- `gold.receita_mensal` (view)
- `gold.retorno_ligacao` (tabela — começa vazia)

---

## O que foi feito

Este deploy entrega duas coisas:

**1. O caminho de volta.** A `gold.retorno_ligacao` é a única tabela do projeto cujo dado não vem do pipeline — vem do time. É onde o vendedor registra o que aconteceu depois da ligação: vendeu, vai pensar, sem interesse, não atendeu.

**2. O Genie da direção.** Um segundo Genie Space, feito para uma audiência específica (a direção comercial). Tem menos fontes que o comercial (7 vs 13), instruções de negócio dedicadas e a regra central: **a métrica da direção é `lift_top200`, nunca AUC**.

---

## Por que um Genie separado

A pergunta que decide o desenho:

> *"O vendedor pergunta 'quanto o cliente X comprou no ano'. O diretor pergunta 'quanto vale a fila'. Se os dois moram no mesmo espaço, as instruções brigam: o que serve para um vira ruído para o outro."*

**Genie não é um por empresa. É um por audiência.**

| Space | Audiência | Foco |
|---|---|---|
| `Rota do Perfume · Comercial` | Vendedor (já existe da noite 3) | Fila, score, ferramentas |
| `Rota do Perfume · Direção` | Direção comercial (este deploy) | Valor da fila, ROI do modelo |

---

## A tabela `gold.retorno_ligacao`

```sql
CREATE TABLE IF NOT EXISTS lakehouse_rotaperfume.gold.retorno_ligacao (
    cliente_id     INT,
    vendedor       STRING,
    status         STRING,   -- vendeu | vai_pensar | sem_interesse | nao_atendeu
    comentario     STRING,
    registrado_em  TIMESTAMP,
    registrado_por STRING,
    _referencia    DATE
)
```

**`CREATE TABLE IF NOT EXISTS` é obrigatório.** É a única tabela do projeto cujo dado vem do time, não do pipeline. Um redeploy não pode apagar o que o vendedor respondeu.

### Estados da tabela

- **Início do deploy**: vazia (0 linhas). É o estado correto.
- **Após registros**: cresce. Cada ligação pode ter múltiplos registros (vendedor ligou, falou, ligou de novo, vendeu).
- **Após redeploy**: preservada. O `IF NOT EXISTS` impede recriação.

---

## As 3 views auxiliares

| View | O que responde | Para quem |
|---|---|---|
| `gold.clientes_em_risco` | "Quem está fora do ritmo?" | Direção (reunião) |
| `gold.ranking_marcas` | "Qual marca vende mais?" | Direção (reunião) |
| `gold.receita_mensal` | "Como anda a sazonalidade?" | Direção (reunião) |

### `clientes_em_risco`
```sql
WHERE s.faixa = 'Fria'
   OR f.atraso_relativo > 2.0
   OR f.atraso_relativo IS NULL
```
Faixa Fria (score mais baixo) OU atraso_relativo > 2 OU cliente sem ritmo definido.

### `ranking_marcas`
`RANK() OVER (ORDER BY SUM(receita) DESC)` — posição da marca no portfólio.

### `receita_mensal`
Receita por ano/mês. A regra de sazonalidade invertida (pico no mês ANTERIOR à data comemorativa) está documentada no COMMENT da view.

---

## O Genie da Direção

### 7 fontes (em ordem alfabética)

```
gold.clientes_em_risco
gold.fila_semanal
gold.modelo_metricas
gold.ranking_marcas
gold.receita_mensal
gold.retorno_ligacao
gold.score_propensao
```

### 10 instruções de negócio (em português)

1. Você é um assistente para a direção comercial
2. Score = probabilidade de comprar em 7 dias (0 a 1)
3. A fila é global, não por vendedor
4. Receita esperada = `SUM(score * ticket_medio)` é uma **estimativa**
5. Métrica da direção é `lift_top200`. NUNCA cite AUC
6. `retorno_ligacao` começa vazia. Se for zero, diga que ninguém registrou
7. Cliente pode ter mais de um retorno. Use `MAX(registrado_em)`
8. Sazonalidade invertida (pico no mês ANTERIOR à data comemorativa)
9. Nunca use o schema bronze
10. `fila_semanal` tem exatamente 200 linhas

### 5 perguntas com SQL validado

1. "Quem eu ligo essa semana?" → `fila_semanal`
2. "Quanto vale a fila desta semana?" → `SUM(score * ticket_medio)` com a palavra **estimativa**
3. "Quantas ligações já foram registradas?" → `COUNT(*) de retorno_ligacao`
4. "Quantas ligações viraram pedido?" → `WHERE status = 'vendeu'`
5. "O modelo é bom?" → `lift_top200` e `acertos_top200`. **Nunca AUC.**

### Resposta esperada para "Quanto vale a fila?"

```sql
SELECT ROUND(SUM(score * ticket_medio), 2) AS receita_esperada_estimativa
FROM lakehouse_rotaperfume.gold.fila_semanal;
-- 582799.50 (estimativa baseada no score, não receita realizada)
```

---

## O Genie Comercial — versão como código

A noite 3 criou o Genie Comercial via interface. Este deploy **versiona** ele como código:

- `resources/comercial.geniespace.json` — snapshot da configuração
- `resources/genie-comercial.genie_space.yml` — recurso bundle com `space_id` fixo

O `space_id: 01f1a355995a13d3baf8c4a27b0085e0` é o que já existe no workspace. O bundle detecta que o recurso existe e **não recria** — apenas rastreia.

> **Nunca renomeie a chave `genie_comercial`.** Trocar a chave faz o bundle tentar apagar e recriar, com URL nova.

---

## Os 2 testes que interrompem o job

| Teste | Condição | O que quebra |
|---|---|---|
| 1 | Nenhuma coluna de `retorno_ligacao` sem COMMENT | Faltou documentação |
| 2 | Exatamente 7 colunas na tabela | Estrutura divergente |

> **Nota:** `retorno_ligacao` é vazia no início. O teste não exige linhas — exige metadado. A auditoria de metadado da noite 2 continua valendo.

---

## O job — 15 tarefas

A tarefa `gold_retorno_ligacao` (11) entra **após `gold_marts`** e **antes de `testes`**, em paralelo com `testes` (ambos dependem de `gold_marts`).

```
gold_dimensoes → gold_fato_vendas → gold_marts → ┬─ gold_retorno_ligacao  (paralelo)
                                                 └─ testes                 (paralelo)
                                                       ↓
                                                   ml_features
                                                       ↓
                                                   ml_modelo
                                                       ↓
                                                   ml_fila
```

`gold_retorno_ligacao` não depende de `testes` porque ela não consome nada que os testes validam — só cria uma tabela vazia e 3 views.

---

## Como verificar

### Tabela e views

```sql
-- Tabela existe e está vazia (estado correto no início)
SELECT COUNT(*) FROM lakehouse_rotaperfume.gold.retorno_ligacao;
-- Esperado: 0

-- 4 objetos novos criados
SELECT table_name, table_type FROM lakehouse_rotaperfume.information_schema.tables
WHERE table_schema = 'gold'
  AND table_name IN ('retorno_ligacao', 'clientes_em_risco',
                     'ranking_marcas', 'receita_mensal');

-- Nenhuma coluna sem COMMENT
SELECT COUNT(*) FROM lakehouse_rotaperfume.information_schema.columns
WHERE table_schema = 'gold' AND table_name = 'retorno_ligacao'
  AND (comment IS NULL OR comment = '');
-- Esperado: 0
```

### Genie spaces

```bash
databricks genie list-spaces --profile joaogui21@hotmail.com
-- Esperado: 2 spaces (Comercial + Direção)
```

### As 3 perguntas

| Pergunta | O que tem que aparecer |
|---|---|
| *"Quanto vale a fila desta semana?"* | **R$ 582.799,50** e a palavra *estimativa* |
| *"Quantas ligações já foram registradas?"* | **zero** — e a frase de que ninguém registrou |
| *"O modelo é bom?"* | **4,25×** ou **86 de 200**. **Não pode citar AUC** |

> **Use o botão *Show generated code* em toda resposta.** É o hábito que separa quem usa Genie de quem confia em Genie.

---

## Armadilhas resolvidas

| Armadilha | Problema | Solução |
|---|---|---|
| Ordenação no JSON do Genie | Deploy falha com "must be sorted by identifier" | `data_sources.tables` ordenadas alfabeticamente; listas ordenadas por `id` |
| IDs não determinísticos | Redesployes recriam perguntas e sujam o diff do Git | MD5 do conteúdo (32 hex minúsculos) |
| `CREATE OR REPLACE` na `retorno_ligacao` | Apagaria o que o time registrou | `CREATE TABLE IF NOT EXISTS` |
| Schema bronze no Genie | Permite queries em dado cru, não conforme | Instrução: "nunca use o schema bronze" |
| Genie cita AUC | Métrica de quem treina, não de quem decide | Instrução: "NUNCA cite AUC para responder pergunta de negócio" |
| Genie inventa retorno quando vazio | Resposta falsa | Instrução: "se for zero, diga que ninguém registrou ainda" |
| Chave do `genie_comercial` renomeada | Bundle recria o recurso com URL nova | space_id fixo no YAML, comentário avisando |

---

## Próximos deploys

| Deploy | O que vem |
|---|---|
| App | App Streamlit consumindo a fila + retorno |
| Genie tuning | Mais perguntas, mais instruções baseadas no uso |
| Métricas de ML | Atualizar `modelo_metricas` com a taxa real de conversão dos registros |

---

## Relacionamento com outros documentos

- [Documento_04_Gold.md](Documento_04_Gold.md) — o `fato_vendas` que alimenta `receita_mensal`
- [Documento_07_Modelo.md](Documento_07_Modelo.md) — o `modelo_metricas` e `score_propensao` que alimentam o Genie
- [Documento_08_Fila_e_Agente.md](Documento_08_Fila_e_Agente.md) — a `fila_semanal` que é o assunto principal
