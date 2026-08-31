# Documento 08 — A Fila Semanal e o Agente

**Deploy:** #3 da noite ML
**Tarefa:** `ml_fila` (tarefa 14 do pipeline)
**Artefato:** `src/ml/13-fila.sql`
**Tabelas geradas:** `gold.fila_semanal`
**Views (ferramentas do agente):** `gold.priorizar_carteira`, `gold.contexto_cliente`, `gold.sugerir_produtos`, `gold.checar_disponibilidade`

---

## O que foi feito

O módulo `13-fila.sql` faz o último metro do projeto: transforma score em decisão. Gera a **fila semanal de 200 clientes priorizados**, com nome, motivo em português e sugestão de produto — e registra 4 views que funcionam como ferramentas do agente.

### A fila semanal

A `gold.fila_semanal` é a entrega principal. São 200 linhas — não 172, não 300. A quantidade é fixada por um teste que quebra o job se não fechar.

**Características:**
- **Fila global, não por vendedor.** A capacidade é por pessoa, mas a ordenação é global: os 200 clientes com maior score recebem ligação, independente de quem é o vendedor.
- **Carteira elegível.** Apenas clientes com `vigente = true` e `orfao_vendedor_desligado = false`. Clientes órfãos de vendedor desligado não recebem ligação — o que cobra o preço da sujeira que foi limpa na noite silver.
- **Distribuição por vendedor.** Não há cota igual. A carteira do João pode estar quente e a do Pedro fria. Forçar 5 por vendedor obriga o João a deixar cliente quente na mesa para o Pedro ligar para cliente frio.

```sql
-- Quem ligou para quantos
SELECT vendedor, COUNT(*) AS ligacoes, ROUND(AVG(score), 3) AS score_medio
FROM lakehouse_rotaperfume.gold.fila_semanal
GROUP BY vendedor ORDER BY ligacoes DESC;
-- Esperado: ~35 vendedores, de 1 a 12 ligações cada
```

### O motivo em português

Cada linha tem uma coluna `motivo` — uma frase que explica **por que** aquele cliente está na fila. É o que permite ao vendedor confiar quando o modelo acerta, e entender quando erra.

A regra de negócio é um `CASE WHEN` ordenado do mais raro para o mais comum:

| Condição | Motivo gerado |
|---|---|
| `atraso_relativo > 3` | "Compra a cada N dias e está há M dias sem pedido. Risco de perder para o concorrente." |
| `atraso_relativo > 1.5` | "Está N× mais atrasado que o ritmo dele." |
| `comprou_lancamento = 1` | "Comprou lançamento recente. Alta chance de repetir." |
| `valor_total` no percentil 90 | "Cliente grande, R$ X no ano. Manter contato." |
| ELSE | "Dentro do ritmo. Contato de manutenção." |

> O ELSE é obrigatório — motivo `NULL` quebra o teste 2.

### A sugestão de produto

A coluna `sugestao` indica o **SKU da marca preferida do cliente que ele não comprou nos últimos 90 dias**, com saldo do estoque.

```
SKU123 | Saldo: 45
SKU456 | Saldo: 0 (RUPTURA)
```

Lógica:
1. Identifica a marca com maior receita para o cliente (marca preferida)
2. Lista os SKUs dessa marca comprados nos últimos 90 dias
3. Remove esses SKUs da sugestão
4. Ordena os SKUs restantes por receita e pega o top 1
5. Cruza com o snapshot mais recente de `silver.estoque`

---

## As 4 ferramentas (views)

O agente não inventa — ele consulta. As 4 views são o contrato entre o agente e o catálogo.

| View | O que responde | Como usar |
|---|---|---|
| `gold.priorizar_carteira` | "Quem eu ligo hoje?" | `WHERE vendedor = 'Ana Souza' AND ordem <= 5` |
| `gold.contexto_cliente` | "Por que esse cliente está aqui?" | `WHERE cliente_id = '123'` |
| `gold.sugerir_produtos` | "O que esse cliente costuma comprar?" | `WHERE cliente_id = '123' ORDER BY receita_total DESC` |
| `gold.checar_disponibilidade` | "Tem no estoque?" | `WHERE sku = 'SKU123'` |

> SQL UDFs `RETURNS TABLE` não são suportadas no SQL Warehouse Free Edition. As 4 views mantêm o mesmo contrato de consulta.

---

## Os 3 testes

| Teste | Condição | O que quebra |
|---|---|---|
| 1 | `COUNT(*) = 200` | Fila com número diferente de 200 |
| 2 | `COUNT(*) WHERE motivo IS NULL = 0` | Motivo sem ELSE no CASE WHEN |
| 3 | `COUNT(*) WHERE score < 0 OR score > 1 = 0` | Score fora do intervalo válido |

---

## A ordem das operações (crítica)

```
1º  INNER JOIN com carteira Elegevel
    (descarta não vigente + vendedores desligados)
2º  ORDER BY score DESC LIMIT 200
3º  ROW_NUMBER() OVER (PARTITION BY vendedor ORDER BY score DESC)
```

Se o filtro de carteira vier **depois** do LIMIT, os ~6 vendedores desligados levam seus clientes junto, e a fila sai com ~172 linhas em vez de 200. O teste 1 quebra o job. A sujeira que foi limpa na silver cobra o preço dela aqui.

---

## Genie Space

O Genie Space foi atualizado com:
- `gold.fila_semanal` — para perguntas sobre a fila
- `gold.score_propensao` — para perguntas sobre o score
- Instrução: *"Use sempre as tabelas e funções deste espaço. Nunca invente número, nome de cliente ou quantidade de estoque."*

O Genie consulta o catálogo, não inventa. Se a instrução não entrar, ele alucina.

---

## Dashboard — página "Fila da semana"

Uma nova página foi adicionada ao dashboard declarativo:
- **Filtro por vendedor** — cada vendedor vê só a sua fila
- **Tabela:** ordem, cliente, cidade, score, faixa, motivo, sugestão

É onde o vendedor consulta a lista — sem isso, os 200 ficam numa tabela que ele nunca abre.

---

## Tabela gold.fila_semanal

| Coluna | Tipo | Descrição |
|---|---|---|
| `vendedor` | STRING | Nome do vendedor responsável |
| `ordem` | INT | Posição na fila do vendedor (1 = prioridade máxima) |
| `cliente_id` | STRING | Identificador do cliente |
| `razao_social` | STRING | Nome fantasia / razão social |
| `cidade` | STRING | Cidade do cliente |
| `uf` | STRING | UF do cliente |
| `score` | DOUBLE | Probabilidade de compra (0 a 1) |
| `faixa` | STRING | Fria, Morna, Quente, Muito quente |
| `ticket_medio` | DOUBLE | Ticket médio do cliente |
| `motivo` | STRING | Frase em português explicando a priorização |
| `sugestao` | STRING | SKU sugerido + saldo do estoque |
| `_versao_modelo` | INT | Versão do modelo que gerou o score |

---

## Como verificar

```sql
-- A resposta para o vendedor
SELECT vendedor, ordem, razao_social,
       ROUND(score, 2) AS score, motivo
FROM lakehouse_rotaperfume.gold.fila_semanal
WHERE vendedor = 'Ana Souza'
ORDER BY ordem;
```

```sql
-- A ferramenta chamada como o agente chamaria
SELECT * FROM lakehouse_rotaperfume.gold.priorizar_carteira
WHERE vendedor = 'Ana Souza' AND ordem <= 5;
```

```sql
-- Contagem: exatamente 200, distribuídos por ~35 vendedores
SELECT COUNT(DISTINCT vendedor) AS vendedores,
       COUNT(*) AS ligacoes
FROM lakehouse_rotaperfume.gold.fila_semanal;
```

---

## Relacionamento com outros documentos

- [Documento_06_Features.md](Documento_06_Features.md) — as features que geram o `atraso_relativo` e `valor_total` usados no motivo
- [Documento_07_Modelo.md](Documento_07_Modelo.md) — o `score_propensao` que alimenta a fila
- [Documento_05_Dashboard.md](Documento_05_Dashboard.md) — o dashboard que recebeu a página "Fila da semana"
