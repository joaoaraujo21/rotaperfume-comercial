# Documento 10 — O App da Direção: a fila dos 200 na tela

**Deploy:** #2 da noite App & Genie (noite 4)
**Artefatos:**
- `rotaperfume-direcao/` — scaffold do Databricks App
- `rotaperfume-direcao/config/queries/` — 4 arquivos SQL
- `rotaperfume-direcao/client/src/pages/` — 3 telas React
- `rotaperfume-direcao/shared/appkit-types/analytics.d.ts` — tipos gerados

**URL:** `https://rotaperfume-direcao-7474649855865169.aws.databricksapps.com`
**Service Principal:** `815f0c63-5ef3-4af1-8d54-86b928065a92`

---

## O que foi feito

Este deploy cria um **Databricks App** para a direção comercial. O app é um "usuário" do Unity Catalog — ele lê as tabelas gold como qualquer pessoa leria, mas tem compute próprio e URL pública.

A entrega tem 3 telas:

| Tela | Rota | O que mostra |
|---|---|---|
| A semana | `/` | 4 KPIs + tabela dos 200 contatos filtrável por vendedor |
| Perguntar | `/perguntar` | Genie "Rota do Perfume · Direção" embutido |
| Acompanhamento | `/acompanhamento` | Status do trabalho: na fila, trabalhados, viraram pedido |

---

## Arquitetura

```
rotaperfume-direcao/
├── app.py                    # Entry point Express
├── server/                   # API backend (Genie, quem-sou)
├── client/                   # Frontend React
│   └── src/
│       ├── App.tsx           # Menu + routing
│       └── pages/
│           ├── semana/SemanaPage.tsx       # KPIs + tabela
│           ├── genie/GeniePage.tsx          # Chat Genie
│           └── acompanhamento/AcompanhamentoPage.tsx
├── config/
│   └── queries/              # SQL fora do React
│       ├── kpis_semana.sql   # 4 KPIs
│       ├── fila.sql          # 200 contatos
│       ├── vendedores.sql     # Lista de vendedores
│       └── acompanhamento.sql
├── shared/
│   └── appkit-types/
│       └── analytics.d.ts    # Tipos gerados (auto-regenera)
└── databricks.yml            # Configuração do app
```

**Regra central: nenhum SQL dentro do React.** Toda leitura é um arquivo `.sql` em `config/queries/`, e o nome do arquivo é a chave que o `useAnalyticsQuery` usa.

---

## As 4 queries SQL

### `kpis_semana.sql` — 4 KPIs da semana

```sql
-- @param vendedor: string = Todos
WITH
  ultima_metrica AS (
    SELECT acertos_top200, lift_top200, taxa_base
    FROM   lakehouse_rotaperfume.gold.modelo_metricas
    QUALIFY ROW_NUMBER() OVER (ORDER BY versao DESC) = 1
  ),
  fila_filtrada AS (
    SELECT cliente_id, vendedor, score, ticket_medio
    FROM   lakehouse_rotaperfume.gold.fila_semanal
    WHERE  CASE WHEN :vendedor = 'Todos' THEN TRUE
                ELSE vendedor = :vendedor END
  ),
  agregados AS (
    SELECT
      COUNT(DISTINCT ff.cliente_id)         AS contatos,
      COUNT(DISTINCT ff.vendedor)            AS vendedores,
      ROUND(SUM(ff.score * ff.ticket_medio), 2) AS receita_esperada,
      COUNT(DISTINCT rl.cliente_id)          AS ja_trabalhados,
      COUNT(DISTINCT CASE WHEN rl.status = 'vendeu'
                          THEN rl.cliente_id END) AS viraram_pedido
    FROM        fila_filtrada ff
    LEFT JOIN   lakehouse_rotaperfume.gold.retorno_ligacao rl
            ON  rl.cliente_id = ff.cliente_id
  )
SELECT
  ag.contatos,
  ag.vendedores,
  ag.receita_esperada,
  um.acertos_top200,
  ROUND(um.lift_top200, 2)                         AS lift,
  ROUND(um.taxa_base * 100, 1)                    AS taxa_base_pct,
  ROUND(um.acertos_top200 * 100.0 / GREATEST(ag.contatos, 1), 1) AS conversao_prevista_pct,
  ag.ja_trabalhados,
  ag.viraram_pedido
FROM        agregados        ag
CROSS JOIN  ultima_metrica   um;
```

**Nota de implementação:** a query original tinha `SELECT` com colunas agregadas (`COUNT(DISTINCT`) junto com colunas de `CROSS JOIN` sem GROUP BY — o `DESCRIBE QUERY` do Databricks (usado pelo typegen) rejeita isso como `MISSING_GROUP_BY`. A solução foi extrair os agregados em uma CTE `agregados` e fazer o `CROSS JOIN` apenas no SELECT externo.

### `fila.sql` — 200 contatos

```sql
-- @param vendedor: string = Todos
WITH retorno_mais_recente AS (
  SELECT * FROM lakehouse_rotaperfume.gold.retorno_ligacao
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY cliente_id ORDER BY registrado_em DESC
  ) = 1
)
SELECT
  fs.ordem,
  fs.razao_social,
  CONCAT(fs.cidade, '/', fs.uf)             AS localizacao,
  fs.ticket_medio,
  fs.vendedor,
  ROUND(fs.score * 100, 0)                  AS chance_pct,
  fs.faixa,
  fs.motivo,
  fs.sugestao,
  rmr.status                                 AS status_retorno,
  rmr.comentario                             AS comentario_retorno,
  rmr.registrado_em                          AS quando_retorno
FROM        lakehouse_rotaperfume.gold.fila_semanal fs
LEFT JOIN   retorno_mais_recente rmr
        ON  rmr.cliente_id = fs.cliente_id
WHERE CASE WHEN :vendedor = 'Todos' THEN TRUE
            ELSE fs.vendedor = :vendedor END
ORDER BY fs.score DESC;
```

### `vendedores.sql` — Lista para o filtro

```sql
SELECT 'Todos' AS value, 'Todos os vendedores' AS label
UNION ALL
SELECT vendedor AS value,
       CONCAT(vendedor, ' (', COUNT(*), ')') AS label
FROM   lakehouse_rotaperfume.gold.fila_semanal
GROUP BY vendedor
ORDER BY label;
```

### `acompanhamento.sql` — Status por vendedor

```sql
-- @param vendedor: string = Todos
SELECT
  fs.vendedor,
  COUNT(DISTINCT fs.cliente_id)                                   AS na_fila,
  COUNT(DISTINCT CASE WHEN rl.cliente_id IS NOT NULL
                      THEN fs.cliente_id END)                     AS trabalhados,
  COUNT(DISTINCT CASE WHEN rl.status = 'vendeu'
                      THEN fs.cliente_id END)                     AS viraram_pedido,
  COUNT(DISTINCT CASE WHEN rl.status = 'vai_pensar'
                      THEN fs.cliente_id END)                      AS vai_pensar,
  COUNT(DISTINCT CASE WHEN rl.status = 'sem_interesse'
                      THEN fs.cliente_id END)                      AS sem_interesse,
  COUNT(DISTINCT CASE WHEN rl.status = 'nao_atendeu'
                      THEN fs.cliente_id END)                      AS nao_atendeu
FROM        lakehouse_rotaperfume.gold.fila_semanal fs
LEFT JOIN   lakehouse_rotaperfume.gold.retorno_ligacao rl
        ON  rl.cliente_id = fs.cliente_id
WHERE CASE WHEN :vendedor = 'Todos' THEN TRUE
            ELSE fs.vendedor = :vendedor END
GROUP BY fs.vendedor;
```

---

## As 3 telas

### "A semana" (`/`) — SemanaPage.tsx

4 cartões KPIs no topo:
- **Contatos** — `COUNT(DISTINCT cliente_id)` + número de vendedores
- **Receita esperada** — `SUM(score * ticket_medio)` em R$ (formatado com `toLocaleString`)
- **Conversão prevista** — `acertos_top200 / contatos` em % vs taxa base às cegas
- **Já trabalhados** — quantos têm registro em `retorno_ligacao` + quantos "viraram pedido"

Tabela com as colunas: ordem, cliente (razão social + localização), vendedor, chance (badge colorido), motivo, sugestão, status.

Filtro `Select` com vendedores + opção "Todos".

**CRÍTICO — números como string:** o warehouse devolve número como string no JSON, mesmo quando o tipo TypeScript diz `number`. Toda formatação passa por `Number()` primeiro:

```tsx
function asNum(v: unknown, fallback = 0): number {
  if (v === null || v === undefined || v === '') return fallback;
  const n = Number(v);
  return Number.isFinite(n) ? n : fallback;
}
```

### "Perguntar" (`/perguntar`) — GeniePage.tsx

```tsx
<GenieChat alias="genie-space" />
```

O `alias` corresponde ao nome do recurso definido em `databricks.yml`:

```yaml
resources:
  - name: genie-space
    genie_space:
      name: "Rota do Perfume · Direção"
      space_id: "01f1a40c17651d788e1d5fab9c7f09ec"
```

Rota `/api/quem-sou` no backend Express devolve o e-mail do usuário logado via header `x-forwarded-email`.

### "Acompanhamento" (`/acompanhamento`) — AcompanhamentoPage.tsx

Na view global ("Todos"), agrega todos os vendedores com `reduce<number>` para evitar erros de tipagem nas operações aritméticas:

```tsx
const na_fila_t = acompData.reduce<number>((s, r) => s + asNum(r.na_fila), 0);
const trab_t   = acompData.reduce<number>((s, r) => s + asNum(r.trabalhados), 0);
```

Na view por vendedor, usa os valores diretos da linha.

---

## O typegen e os tipos

O comando `npm run typegen` (executado pelo Databricks em cada deploy) roda `DESCRIBE QUERY` no warehouse para cada arquivo `.sql`. O resultado se torna `analytics.d.ts`:

```typescript
// Auto-generated — resultado após todos os fixes:
interface QueryRegistry {
  kpis_semana: { result: unknown; /* CTE + CROSS JOIN: typegen não resolve */ };
  fila: {
    result: Array<{
      ordem: number;
      razao_social: string;
      // ...
    }>;
  };
  acompanhamento: {
    result: Array<{
      vendedor: string;
      na_fila: number;
      // ...
    }>;
  };
  vendedores: {
    result: Array<{ value: string; label: string; }>;
  };
}
```

`kpis_semana` tem `result: unknown` porque o typegen não consegue resolver o tipo de uma query com CTEs e `CROSS JOIN`. O workaround é o helper `asRows<T>()` — mas o lint bloqueia `as unknown as T[]` (double type assertion), então se usa:

```tsx
function asRows<T>(v: unknown): T[] {
  if (Array.isArray(v)) return v as T[];
  return [];
}

const kpiData = asRows<KpiData>(kpis.data)[0] ?? null;
```

---

## Node.js — requisito de versão

O AppKit usa `tsdown` → `rolldown`, e `rolldown` importa `styleText` de `node:util`. Esse símbolo foi adicionado em **Node 20.12**.

- **Node 20.11.1** → falha: `SyntaxError: The requested module 'node:util' does not provide an export named 'styleText'`
- **Node 24.10.0** → funciona. Instalado em `C:\Users\Windows 10\node-v24.10.0-win-x64\`

Antes de qualquer comando `npm`, `npx` ou `databricks apps`, é preciso garantir que Node 24 está no PATH:

```powershell
$env:PATH = "C:\Users\Windows 10\node-v24.10.0-win-x64;$env:PATH"
```

O PATH do usuário no Windows já foi atualizado para apontar para o Node 24.

---

## Permissões do service principal

O app tem identity própria. Após o primeiro deploy, o `service_principal_client_id` fica disponível em `databricks apps get`. Sem GRANT, o app sobe e mostra tela vazia — sem erro visível.

```bash
# Obter o ID
databricks apps get rotaperfume-direcao -o json --profile joaogui21@hotmail.com
# Campo: service_principal_client_id = 815f0c63-5ef3-4af1-8d54-86b928065a92

# Conceder acesso
databricks grants update catalog lakehouse_rotaperfume \
  --json '{"changes":[{"principal":"815f0c63-5ef3-4af1-8d54-86b928065a92","add":["USE_CATALOG"]}]}'

databricks grants update schema lakehouse_rotaperfume.gold \
  --json '{"changes":[{"principal":"815f0c63-5ef3-4af1-8d54-86b928065a92","add":["USE_SCHEMA","SELECT"]}]}'
```

`CAN_USE` no warehouse **não** dá acesso ao dado — é compute, não dado.

---

## Como verificar

### App no ar

```bash
databricks apps get rotaperfume-direcao -o json --profile joaogui21@hotmail.com \
  | python -c "import json,sys; d=json.load(sys.stdin); print(d['url'], d['app_status'], d['compute_status'])"
# https://rotaperfume-direcao-7474649855865169.aws.databricksapps.com RUNNING ACTIVE
```

### Os 4 números

```sql
-- Contatos e receita
SELECT COUNT(DISTINCT cliente_id)                            AS contatos,   -- 200
       COUNT(DISTINCT vendedor)                              AS vendedores, -- 35
       ROUND(SUM(score * ticket_medio), 2)                  AS receita    -- 582799.50
FROM   lakehouse_rotaperfume.gold.fila_semanal;

-- Modelo
SELECT acertos_top200, ROUND(lift_top200, 2) AS lift, ROUND(taxa_base * 100, 1) AS base
FROM   lakehouse_rotaperfume.gold.modelo_metricas
QUALIFY ROW_NUMBER() OVER (ORDER BY versao DESC) = 1;
-- Esperado: acertos_top200=86, lift=4.25, base=10.1
-- Conversão prevista: 86/200 = 43% vs 10.1% às cegas
```

### Validação local

```bash
# Requer Node 24 no PATH
databricks apps validate --profile joaogui21@hotmail.com
# Esperado: 5 checks passados em ~120s
```

---

## Armadilhas resolvidas

| Armadilha | Sintoma | Solução |
|---|---|---|
| `MISSING_GROUP_BY` no typegen | `kpis_semana` rejeitada pelo `DESCRIBE QUERY` | Extrair agregados em CTE `agregados`, CROSS JOIN só no SELECT externo |
| `styleText` missing (Node 20) | `SyntaxError: does not provide export named 'styleText'` | Upgrade para Node 24.10.0 |
| `as unknown as` bloqueado pelo lint | AST-grep `no-double-type-assertion` | Helper `asRows<T>()` sem cast duplo |
| `result: {}` para queries complexas | TypeScript não acha propriedades | `asRows<T>()` + interface local com tipagem correta |
| App mostra tela vazia, sem erro | Service principal sem GRANT no catálogo | `GRANT USE_CATALOG` + `GRANT USE_SCHEMA` + `GRANT SELECT` |
| Deploy target `dev` | App criado sem URL | `-t default` (não `dev`) |
| `bundle deploy` em vez de `apps deploy` | App criado mas sem compute | `databricks apps deploy` |
| Números sem formatação (`582799.498...`) | `toLocaleString` não formatou | `Number(v)` antes de formatar |
| Soma dá `712` em vez de `19` | Concatenação de strings | `Number()` antes de somar |
| GenieChat não carrega | Alias errado no componente | `alias="genie-space"` (matching `databricks.yml`) |

---

## Relacionamento com outros documentos

- [Documento_08_Fila_e_Agente.md](Documento_08_Fila_e_Agente.md) — a `gold.fila_semanal` lida pelo app; o agente LangGraph que alimenta a fila
- [Documento_09_Genie_da_Direcao.md](Documento_09_Genie_da_Direcao.md) — o Genie Space "Rota do Perfume · Direção" (`space_id: 01f1a40c17651d788e1d5fab9c7f09ec`) embutido na aba "Perguntar"

---

## Próximos deploys

| O que vem | Descrição |
|---|---|
| Retorno das ligações | A tabela `gold.retorno_ligacao` está vazia. O prompt 3 introduz a escrita de volta: o vendedor registra o que aconteceu e o KPI "Já trabalhados" deixa de ser zero |
| Genie tuning | Mais instruções de negócio baseadas no uso real |
| Métricas de ML atualizadas | `gold.modelo_metricas` com a taxa real de conversão dos registros |
