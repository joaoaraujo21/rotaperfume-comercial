# Documento 11 — O Retorno: o ciclo se fecha

**Deploy:** #3 da noite App & Genie (noite 4) — o último.
**Feature:** `prompt_03_retorno.md` (`.llm/.app_e_genie/`)
**URL:** `https://rotaperfume-direcao-7474649855865169.aws.databricksapps.com`
**Service Principal:** `815f0c63-5ef3-4af1-8d54-86b928065a92`

---

## O que foi feito

O app agora **escreve** na `gold`, completando o ciclo. O modelo disse quem comprar; o vendedor diz se acertou. Esse dado volta para a `gold` e vira:

1. O KPI **"Já trabalhados"** sobe na hora.
2. O **Genie** sabe responder sobre o que foi registrado.
3. A próxima **semana de treino** do modelo tem dados reais.

A entrega tem 5 partes:

| # | O que | Onde |
|---|---|---|
| 1 | Rota `POST /api/retorno` com validação Zod | `server/server.ts` |
| 2 | Seletor 2×2 inline na tabela (sem popup) | `SemanaPage.tsx` |
| 3 | Reload por key remounting (sem full reload) | `SemanaPage.tsx` |
| 4 | KPI "Já trabalhados" com atualização instantânea | `SemanaPage.tsx` |
| 5 | Fix Genie (alias correto) | `server/server.ts` |

---

## 1 · A rota `POST /api/retorno`

Registrada em `server/server.ts`, dentro de `onPluginsReady`, via `appkit.server.extend()`:

```typescript
// server/server.ts
import { z } from 'zod';
import { createApp, analytics, genie, server, sql } from '@databricks/appkit';

const RetornoSchema = z.object({
  cliente_id:  z.coerce.number().int().positive(),
  vendedor:   z.string().min(1).max(100),
  status:     z.enum(['vendeu', 'vai_pensar', 'sem_interesse', 'nao_atendeu']),
  comentario: z.string().max(500).optional().default(''),
  referencia: z.string().regex(/^\d{4}-\d{2}-\d{2}$/, 'Formato: aaaa-mm-dd'),
});

createApp({
  cache: { enabled: false },  // dado muda a cada clique
  plugins: [
    analytics(),
    genie({ spaces: { 'genie-space': process.env.DATABRICKS_GENIE_SPACE_ID! } }),
    server(),
  ],
  onPluginsReady(appkit) {
    appkit.server.extend((app) => {
      app.post('/api/retorno', express.json(), async (req, res) => {
        const parsed = RetornoSchema.safeParse(req.body);
        if (!parsed.success)
          return res.status(400).json({ error: 'VALIDATION_ERROR', detail: parsed.error.flatten() });

        const data = parsed.data;
        const registrado_por = String(req.headers['x-forwarded-email'] ?? 'dev@rotaperfume.local');

        await appkit.analytics.query(INSERT_RETORNO, {
          cliente_id:     sql.int(data.cliente_id),
          vendedor:       sql.string(data.vendedor),
          status:         sql.string(data.status),
          comentario:     sql.string(data.comentario ?? ''),
          registrado_por: sql.string(registrado_por),
          referencia:     sql.string(data.referencia),
        });
        return res.status(201).json({ ok: true });
      });
    });
  },
});
```

### O SQL INSERT

```sql
INSERT INTO lakehouse_rotaperfume.gold.retorno_ligacao
  (cliente_id, vendedor, status, comentario, registrado_em, registrado_por, _referencia)
VALUES
  (:cliente_id, :vendedor, :status, :comentario, CURRENT_TIMESTAMP(), :registrado_por, :referencia)
```

### Por que o enum é o contrato

O botão manda um dos 4 valores; o Zod valida e recusa qualquer outro. A tabela nunca vai ter `"vendeu"`, `"Vendeu"`, `"vendido"` ou `"Talvez"` — porque esses valores não passam no `safeParse()`.

```bash
# Exemplo: curl com status inválido
curl -X POST https://rotaperfume-direcao.../api/retorno \
  -H "Content-Type: application/json" \
  -d '{"cliente_id":2137,"vendedor":"Bruno","status":"talvez","referencia":"2026-08-31"}'
# → HTTP 400, { error: "VALIDATION_ERROR", detail: { ... } }
# nada chega ao warehouse
```

---

## 2 · O seletor 2×2 inline

**Problema anterior:** um dialog overlay abria como tela separada. O usuário queria que o status ficasse **dentro da própria linha**.

**Solução:** `StatusSelector` — componente com 4 botões organizados em grid 2×2, renderizado diretamente na célula da tabela:

```
┌──────────────┬──────────────┐
│  ✅ Vendido  │  🤔 Vai pensar │
├──────────────┼──────────────┤
│ ❌ Sem int.  │  📵 Não atend. │
└──────────────┴──────────────┘
```

### Config de estilos (em `SemanaPage.tsx`)

```typescript
const STATUS_META: Record<RetornoStatus, {
  label: string; short: string;
  bg: string; text: string; border: string; ring: string;      // inativo
  activeBg: string; activeText: string; activeBorder: string;     // ativo
}> = {
  vendeu:        { label: '✅ Vendido',    short: 'Vendido',     bg: 'bg-green-50',  text: 'text-green-700',  border: 'border-green-200',  activeBg: 'bg-green-600',  activeText: 'text-white', activeBorder: 'border-green-700' },
  vai_pensar:    { label: '🤔 Vai pensar',  short: 'Vai pensar', bg: 'bg-yellow-50', text: 'text-yellow-700', border: 'border-yellow-200', activeBg: 'bg-yellow-500', activeText: 'text-white', activeBorder: 'border-yellow-600' },
  sem_interesse: { label: '❌ Sem interés.', short: 'Sem interés.', bg: 'bg-red-50',    text: 'text-red-700',    border: 'border-red-200',    activeBg: 'bg-red-600',    activeText: 'text-white', activeBorder: 'border-red-700' },
  nao_atendeu:   { label: '📵 Não atende',  short: 'Não atend.',  bg: 'bg-gray-100',  text: 'text-gray-600',   border: 'border-gray-200',   activeBg: 'bg-gray-700',   activeText: 'text-white', activeBorder: 'border-gray-800' },
};

const STATUS_GRID: RetornoStatus[] = ['vendeu', 'vai_pensar', 'sem_interesse', 'nao_atendeu'];
```

### O componente

```tsx
function StatusSelector({ clienteId, currentStatus, saving, onStatusChange }) {
  return (
    <div className="grid grid-cols-2 gap-1.5 p-1.5 w-full max-w-[220px]">
      {STATUS_GRID.map(s => {
        const meta = STATUS_META[s];
        const isActive = currentStatus === s;
        return (
          <button
            key={s} type="button"
            disabled={saving}
            onClick={() => handleClick(s)}
            aria-pressed={isActive}
            className={`
              w-full px-2 py-1.5 rounded-md border text-xs font-medium text-center
              transition-colors duration-100 cursor-pointer select-none
              disabled:opacity-40 disabled:cursor-not-allowed
              focus:outline-none focus-visible:ring-2
              ${isActive
                ? `${meta.activeBg} ${meta.activeText} ${meta.activeBorder} shadow-sm font-semibold`
                : `${meta.bg} ${meta.text} ${meta.border} hover:brightness-95`
              }
            `}
          >
            {meta.short}
          </button>
        );
      })}
    </div>
  );
}
```

### Status efetivo: otimismo > banco

```typescript
// Status efetivo = local (otimista) primeiro, depois banco
const bankStatus = row.status_retorno as RetornoStatus | null;
const effectiveStatus = localStatus[clienteId] ?? bankStatus;
```

---

## 3 · O reload: key remounting (sem full reload)

**Problema:** `useAnalyticsQuery` não tem `refetch()`. O cache do AppKit guarda o resultado. Depois de gravar, a tela mostrava o número de antes.

**Solução:** `cache: { enabled: false }` no `createApp` + key que muda no componente React.

```typescript
// Estado no componente pai
const [reloadKey, setReloadKey] = useState(0);

// Depois do POST resolver com sucesso:
setReloadKey(k => k + 1);

// A tabela é envelopada com a key:
<div key={`fila-${reloadKey}-${vendedor}`} className="overflow-x-auto">
  <Table>...</Table>
</div>
```

**O que acontece:** React destrói e recria o `<div>` → o `useAnalyticsQuery('fila', ...)` é chamado de novo → o SQL roda → os dados refletem a gravação.

**Por que não parâmetro falso:** a alternativa de mandar um `:recarga >= 0` no SQL funciona, mas quebra quando o usuário tem uma versão antiga do JS em cache — o navegador manda a query sem o parâmetro e o warehouse responde `UNBOUND_SQL_PARAMETER`. Com key remounting isso nunca acontece.

**O filtro sobrevive:** o `vendedor` é estado do `Layout` (App.tsx), passado por `Outlet context`. A tabela remontando não perde o filtro.

---

## 4 · KPI "Já trabalhados" — atualização instantânea

O KPI não está na mesma key que a tabela. Para dar feedback **imediatamente**, sem esperar o round-trip do banco:

```typescript
// Contadores instantâneos (otimista + banco)
const jaTrabalhadosBase = asNum(kpiData?.ja_trabalhados);
const novosClientesTrabalhados = Object.keys(localStatus).filter(idStr => {
  const id = Number(idStr);
  const row = filaData.find(r => Number(r.cliente_id) === id);
  // só conta se AINDA não tinha status no banco
  return !row || !row.status_retorno;
}).length;

const jaTrabalhadosOptimistic = jaTrabalhadosBase + novosClientesTrabalhados;
```

**Fluxo completo:**

1. Usuário clica "Vendido" → `localStatus[id] = 'vendeu'` → `effectiveStatus` muda → linha fica verde, botão fica destacado → `novosClientesTrabalhados` sobe → **número do KPI sobe na hora**
2. POST resolve → `setReloadKey()` → tabela remonta → query re-executa → banco devolve `status_retorno = 'vendeu'` → useEffect limpa otimismo → `novosClientesTrabalhados` volta a 0 → **KPI volta ao valor real do banco**

---

## 5 · Fix Genie (alias correto)

**Sintoma:** qualquer pergunta na aba "Perguntar" retornava `HTTP 404`.

**Causa:** `GeniePage.tsx` chama `<GenieChat alias="genie-space" />`, mas `server.ts` inicializava `genie()` sem configuração — o plugin registrava o space com alias `"default"` (fallback via `DATABRICKS_GENIE_SPACE_ID`).

**Fix em `server/server.ts`:**

```typescript
// ANTES (bug): alias "genie-space" não existia
plugins: [analytics(), genie(), server()]

// DEPOIS (fix): alias registrado com o mesmo nome que o componente usa
plugins: [
  analytics(),
  genie({
    spaces: { 'genie-space': process.env.DATABRICKS_GENIE_SPACE_ID! },
  }),
  server(),
]
```

`DATABRICKS_GENIE_SPACE_ID` vem de `app.yaml` (mapeado do recurso `genie-space`) e está preenchido em runtime pelo Databricks.

---

## Arquitetura completa

```
rotaperfume-direcao/
├── server/
│   └── server.ts              # createApp + rotas POST /api/retorno
├── client/src/
│   ├── App.tsx                # Layout com Outlet context (vendedor filter)
│   └── pages/
│       ├── semana/SemanaPage.tsx         # Seletor 2×2 + KPIs instantâneos
│       ├── acompanhamento/AcompanhamentoPage.tsx  # Gráfico + tabela por vendedor
│       └── genie/GeniePage.tsx          # GenieChat (alias="genie-space")
└── config/queries/
    ├── kpis_semana.sql        # LEFT JOIN retorno_ligacao para contadores
    ├── fila.sql              # LEFT JOIN retorno_ligacao para status por linha
    ├── acompanhamento.sql     # GROUP BY vendedor com COUNT por status
    └── vendedores.sql         # Lista para filtro

lakehouse_rotaperfume.gold/
├── fila_semanal              # Entrada: 200 contatos priorizados
└── retorno_ligacao           # Saída: o que o vendedor respondeu
                              # INSERT via POST /api/retorno
```

### Fluxo de dados

```
fila_semanal  →  app (leitura via useAnalyticsQuery)
                    │
                    ├── SemanaPage: StatusSelector 2×2
                    │              POST /api/retorno
                    │              │
                    │              └── retorno_ligacao ← INSERT
                    │                       │
                    │                       ├── kpis_semana.sql (LEFT JOIN) → KPI atualiza
                    │                       ├── fila.sql (LEFT JOIN)        → linha muda
                    │                       ├── acompanhamento.sql            → gráfico atualiza
                    │                       └── Genie Space (automático)    → Genie sabe responder
```

---

## Permissão de escrita (escopada)

O service principal do app **não** tem `MODIFY` no schema inteiro. A permissão é em uma tabela só:

```sql
-- Conceder no Databricks SQL Editor (com usuário admin)
GRANT MODIFY ON TABLE lakehouse_rotaperfume.gold.retorno_ligacao
TO `815f0c63-5ef3-4af1-8d54-86b928065a92`;
```

**Em TABLE, não em SCHEMA.** Com `MODIFY` no schema, o app poderia alterar `fato_vendas` e qualquer outra tabela. Com a permissão escopada, ele só escreve onde precisa.

---

## Como verificar

### 1 · O momento da noite: clique e mostre a linha

No app, primeiro cliente da fila — *Farmácia Serena*, Goiânia, score **0,974**.
Clique em **Vendido**.

Agora, no SQL Editor:

```sql
SELECT cliente_id, vendedor, status, comentario, registrado_por, registrado_em
FROM   lakehouse_rotaperfume.gold.retorno_ligacao;
```

A linha está lá, com **o seu e-mail** em `registrado_por`.

> *"Segunda a query quebrou por causa de data em dois formatos. Hoje um clique
> virou uma linha na gold. É o mesmo lugar — o dado deu a volta inteira."*

### 2 · O contrato recusa o inválido

```bash
curl -X POST <URL-do-app>/api/retorno \
  -H "Content-Type: application/json" \
  -d '{"cliente_id":2137,"vendedor":"Bruno","status":"talvez","referencia":"2026-08-31"}'
```

Devolve **400** com a lista dos 4 valores aceitos. Nada chega ao warehouse.

### 3 · O KPI sobe na hora

Depois do clique, o cartão *Já trabalhados* vai de **0** para **1** instantaneamente. A linha fica verde na tabela.

### 4 · O Genie responde sobre o que acabou de acontecer

Na aba *Perguntar*, pergunte:

> *"Quantas ligações já foram registradas e quantas viraram pedido?"*

Ele responde **1 e 1** (ou o número real de registros). **Nenhuma linha de código do Genie mudou** — mudou o dado debaixo dele.

### 5 · Limpe antes de encerrar

```sql
DELETE FROM lakehouse_rotaperfume.gold.retorno_ligacao;
```

---

## Se der errado

| Sintoma | Causa | Correção |
|---|---|---|
| `PERMISSION_DENIED` ao gravar | falta `MODIFY` na tabela | `GRANT MODIFY ON TABLE lakehouse_rotaperfume.gold.retorno_ligacao TO '<sp>'` — em TABLE, não em SCHEMA |
| Grava, mas a tela não muda | `cache: { enabled: false }` desligado | `cache: { enabled: false }` no `createApp` |
| KPI "Já trabalhados" não sobe | key não muda ou `localStatus` não é computado | `setReloadKey(k => k + 1)` após POST ok + contagem otimista em `jaTrabalhadosOptimistic` |
| HTTP 404 na aba "Perguntar" | alias do Genie não registrado | `genie({ spaces: { 'genie-space': process.env.DATABRICKS_GENIE_SPACE_ID! } })` |
| `UNBOUND_SQL_PARAMETER: recarga` | parâmetro falso no SQL | Não use parâmetro falso. Se já usou: `Ctrl+Shift+R` no navegador |
| `registrado_por` sempre `dev@rotaperfume.local` | rodando em `npm run dev` sem OAuth | No app publicado, vem o e-mail real via `x-forwarded-email` |

---

## Relacionamento com outros documentos

- [Documento_10_App_Direcao.md](Documento_10_App_Direcao.md) — o scaffold do app; a tabela `gold.retorno_ligacao` já existia com 0 linhas
- [Documento_09_Genie_da_Direcao.md](Documento_09_Genie_da_Direcao.md) — o Genie Space "Rota do Perfume · Direção"; agora responde sobre os retornos registrados
- [Documento_07_Modelo.md](Documento_07_Modelo.md) — a `gold.modelo_metricas` com `lift_top200`; o retorno registrado vira dado de treino na próxima semana
- [Documento_08_Fila_e_Agente.md](Documento_08_Fila_e_Agente.md) — a `gold.fila_semanal`; o retorno fecha o ciclo da fila

---

## Comandos de deploy

```bash
cd rotaperfume-direcao

# Validar
databricks apps validate --profile joaogui21@hotmail.com

# Deploy
databricks apps deploy --profile joaogui21@hotmail.com

# Verificar status
databricks apps get rotaperfume-direcao -o json --profile joaogui21@hotmail.com \
  | python -c "import json,sys; d=json.load(sys.stdin); print(d['url'], d['app_status'], d['compute_status'])"

# Ver logs
databricks apps logs rotaperfume-direcao --profile joaogui21@hotmail.com
```
