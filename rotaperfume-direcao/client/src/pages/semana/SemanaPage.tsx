/**
 * SemanaPage -- "A semana"
 *
 * Fila semanal de 200 contatos priorizados com seletor inline 2x2 de status.
 * - Click grava, UI atualiza IMEDIATAMENTE (otimista) e revalida em background.
 * - Filter de vendedor vem do Outlet (Layout) -- sobrevive a qualquer remount.
 * - reload via key remounting (não window.location.href).
 *
 * CRITICAL: Numbers come from the warehouse as STRINGS in the JSON, even
 * when the typegen type says `number`. Always use Number() before formatting.
 */

import { useOutletContext } from 'react-router';
import {
  Card,
  CardContent,
  CardHeader,
  CardTitle,
  Skeleton,
  Alert,
  AlertDescription,
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from '@databricks/appkit-ui/react';
import { useState, useCallback, useEffect, useRef } from 'react';
import { useAnalyticsQuery } from '@databricks/appkit-ui/react';
import { sql } from '@databricks/appkit-ui/js';

// ── Helpers ────────────────────────────────────────────────────────────────────

function asNum(v: unknown, fallback = 0): number {
  if (v === null || v === undefined || v === '') return fallback;
  const n = Number(v);
  return Number.isFinite(n) ? n : fallback;
}

function asRows<T>(v: unknown): T[] {
  if (Array.isArray(v)) return v as T[];
  return [];
}

function fmtBRL(v: unknown): string {
  return asNum(v).toLocaleString('pt-BR', { style: 'currency', currency: 'BRL' });
}

function fmtPct(v: unknown): string {
  return `${Math.round(asNum(v))}%`;
}

function fmtInt(v: unknown): string {
  return asNum(v).toLocaleString('pt-BR');
}

// ── Outlet context (vem do Layout em App.tsx) ──────────────────────────────────

interface OutletCtx {
  vendedor: string;
  setVendedor: (v: string) => void;
}

// ── Tipos ─────────────────────────────────────────────────────────────────────

interface KpiData {
  contatos: string | number;
  vendedores: string | number;
  receita_esperada: string | number;
  acertos_top200: string | number;
  lift: string | number;
  taxa_base_pct: string | number;
  conversao_prevista_pct: string | number;
  ja_trabalhados: string | number;
  viraram_pedido: string | number;
}

interface FilaRow {
  ordem: string | number;
  cliente_id: number;
  razao_social: string;
  localizacao: string;
  ticket_medio: string | number;
  vendedor: string;
  chance_pct: string | number;
  faixa: string;
  motivo: string;
  sugestao: string;
  status_retorno: string | null;
  comentario_retorno: string | null;
  quando_retorno: string | null;
}

interface VendedorOption {
  value: string;
  label: string;
}

type RetornoStatus = 'vendeu' | 'vai_pensar' | 'sem_interesse' | 'nao_atendeu';

// ── Config de status — estilo seletor 2x2 ──────────────────────────────────────

const STATUS_META: Record<RetornoStatus, {
  label: string;
  short: string;
  // inativo: fundo claro, texto discreto
  bg: string; text: string; border: string; ring: string;
  // ativo: fundo escuro, texto claro
  activeBg: string; activeText: string; activeBorder: string;
}> = {
  vendeu:        { label: '✅ Vendido',        short: 'Vendido',       bg: 'bg-green-50',  text: 'text-green-700',  border: 'border-green-200',  ring: 'ring-green-500',   activeBg: 'bg-green-600',  activeText: 'text-white', activeBorder: 'border-green-700' },
  vai_pensar:    { label: '🤔 Vai pensar',      short: 'Vai pensar',    bg: 'bg-yellow-50', text: 'text-yellow-700', border: 'border-yellow-200', ring: 'ring-yellow-500',  activeBg: 'bg-yellow-500', activeText: 'text-white', activeBorder: 'border-yellow-600' },
  sem_interesse: { label: '❌ Sem interesse',   short: 'Sem interesse', bg: 'bg-red-50',    text: 'text-red-700',    border: 'border-red-200',    ring: 'ring-red-500',     activeBg: 'bg-red-600',    activeText: 'text-white', activeBorder: 'border-red-700' },
  nao_atendeu:   { label: '📵 Não atende',      short: 'Não atende',    bg: 'bg-gray-100',  text: 'text-gray-600',   border: 'border-gray-200',   ring: 'ring-gray-500',    activeBg: 'bg-gray-700',   activeText: 'text-white', activeBorder: 'border-gray-800' },
};

// 2x2: linha de cima = vendeu, vai_pensar; linha de baixo = sem_interesse, nao_atendeu
const STATUS_GRID: RetornoStatus[] = ['vendeu', 'vai_pensar', 'sem_interesse', 'nao_atendeu'];

// ── Componentes ────────────────────────────────────────────────────────────────

function KpiCard({ label, value, sub, icon }: { label: string; value: string; sub?: string; icon: string }) {
  return (
    <Card className="shadow-sm">
      <CardContent className="pt-4">
        <div className="flex items-start justify-between">
          <div>
            <p className="text-xs text-muted-foreground font-medium uppercase tracking-wide">{label}</p>
            <p className="text-2xl font-bold text-foreground mt-0.5">{value}</p>
            {sub && <p className="text-xs text-muted-foreground/70 mt-0.5">{sub}</p>}
          </div>
          <span className="text-2xl" role="img" aria-hidden="true">{icon}</span>
        </div>
      </CardContent>
    </Card>
  );
}

function ErrorState({ message }: { message: string }) {
  return (
    <Alert variant="destructive">
      <AlertDescription>{message}</AlertDescription>
    </Alert>
  );
}

// ── Seletor 2x2 inline (dentro da célula da tabela) ───────────────────────────

interface StatusSelectorProps {
  clienteId: number;
  vendedorVal: string;
  currentStatus: RetornoStatus | null;
  saving: boolean;
  onStatusChange: (clienteId: number, vendedorVal: string, status: RetornoStatus) => void;
}

function StatusSelector({ clienteId, vendedorVal, currentStatus, saving, onStatusChange }: StatusSelectorProps) {
  const handleClick = (s: RetornoStatus) => {
    if (saving) return;
    onStatusChange(clienteId, vendedorVal, s);
  };

  return (
    <div className="grid grid-cols-2 gap-1.5 p-1.5 w-full max-w-[220px]">
      {STATUS_GRID.map(s => {
        const meta = STATUS_META[s];
        const isActive = currentStatus === s;
        return (
          <button
            key={s}
            type="button"
            disabled={saving}
            onClick={() => handleClick(s)}
            aria-pressed={isActive}
            title={meta.label}
            className={`
              w-full px-2 py-1.5 rounded-md border text-xs font-medium text-center
              transition-colors duration-100 cursor-pointer select-none
              disabled:opacity-40 disabled:cursor-not-allowed
              focus:outline-none focus-visible:ring-2 focus-visible:${meta.ring} focus-visible:ring-offset-1
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

// ── Main Page ────────────────────────────────────────────────────────────────

export function SemanaPage() {
  // Filtro vem do Layout (App.tsx) — sobrevive a remounts.
  const { vendedor, setVendedor } = useOutletContext<OutletCtx>();

  // Reload key: muda a cada gravação → força re-fetch dos contadores.
  const [reloadKey, setReloadKey] = useState(0);

  // Saving por cliente
  const [savingFor, setSavingFor] = useState<Set<number>>(new Set());

  // Erro de POST
  const [postError, setPostError] = useState<string | null>(null);

  // Status local otimista: o click reflete IMEDIATAMENTE na UI, antes mesmo
  // do POST resolver e do reloadKey re-fetch do banco.
  const [localStatus, setLocalStatus] = useState<Record<number, RetornoStatus>>({});

  // Refs para evitar race: se clicar duas vezes rápido, a 2ª sobrescreve a 1ª.
  const inflightRef = useRef<Set<number>>(new Set());

  // ── Queries ─────────────────────────────────────────────────────────────────

  const kpis = useAnalyticsQuery('kpis_semana', { vendedor: sql.string(vendedor) });
  const kpiData = asRows<KpiData>(kpis.data)[0] ?? null;

  const fila = useAnalyticsQuery('fila', { vendedor: sql.string(vendedor) });
  const filaData = asRows<FilaRow>(fila.data);

  const vendedores = useAnalyticsQuery('vendedores', {});
  const vendedoresData = asRows<VendedorOption>(vendedores.data);

  // Limpa otimismo quando os dados do banco chegam (evita flicker).
  useEffect(() => {
    setLocalStatus(prev => {
      const next: Record<number, RetornoStatus> = {};
      for (const idStr of Object.keys(prev)) {
        const id = Number(idStr);
        const row = filaData.find(r => r.cliente_id === id);
        if (!row || !row.status_retorno) {
          // servidor ainda não gravou — mantém otimismo
          next[id] = prev[id];
        }
        // se já chegou com status, deixa o banco ditar (descarta otimismo)
      }
      // early-return se nada mudou
      const a = Object.keys(prev).length;
      const b = Object.keys(next).length;
      if (a === b) {
        let same = true;
        for (const k of Object.keys(prev)) if (prev[Number(k)] !== next[Number(k)]) { same = false; break; }
        if (same) return prev;
      }
      return next;
    });
  }, [filaData]);

  // ── POST handler — atualização otimista + remount ────────────────────────────

  const handleStatusChange = useCallback(async (clienteId: number, vendedorVal: string, status: RetornoStatus) => {
    setPostError(null);

    // Otimista: UI muda AGORA.
    setLocalStatus(prev => ({ ...prev, [clienteId]: status }));
    setSavingFor(prev => new Set([...prev, clienteId]));

    // Se já tem uma chamada em voo para o mesmo cliente, ignora.
    if (inflightRef.current.has(clienteId)) return;
    inflightRef.current.add(clienteId);

    try {
      const res = await fetch('/api/retorno', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          cliente_id: clienteId,
          vendedor: vendedorVal,
          status,
          comentario: '',
          referencia: new Date().toISOString().slice(0, 10),
        }),
      });
      if (!res.ok) {
        const fallback: { detail?: string } = { detail: `HTTP ${res.status}` };
        const parsed = (await res.json().catch(() => fallback)) as { detail?: string | object };
        const detail = parsed.detail;
        const detailStr = typeof detail === 'string' ? detail : detail ? JSON.stringify(detail) : `HTTP ${res.status}`;
        throw new Error(detailStr);
      }
      // Re-fetch dos contadores (KPIs) e da própria fila (pega o status_retorno do banco).
      setReloadKey(k => k + 1);
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : 'Erro ao registrar retorno.';
      setPostError(message);
      // Reverte otimismo.
      setLocalStatus(prev => {
        const next = { ...prev };
        delete next[clienteId];
        return next;
      });
    } finally {
      inflightRef.current.delete(clienteId);
      setSavingFor(prev => {
        const next = new Set(prev);
        next.delete(clienteId);
        return next;
      });
    }
  }, []);

  const taxaBase = asNum(kpiData?.taxa_base_pct);
  const conv = asNum(kpiData?.conversao_prevista_pct);

  // ── Contadores instantâneos (otimista + banco) ────────────────────────────────
  // "Já trabalhados" do banco é GLOBAL (toda a semana, todos os vendedores).
  // Otimismo: para cada cliente com localStatus, somamos 1 SE esse cliente
  // AINDA não tinha status no banco. Quando o POST resolve e a query refaz,
  // o otimismo se apaga e o número volta a ser o do banco (já com a gravação).
  const jaTrabalhadosBase = asNum(kpiData?.ja_trabalhados);
  const novosClientesTrabalhados = Object.keys(localStatus).filter(idStr => {
    const id = Number(idStr);
    const row = filaData.find(r => {
      const cid = typeof r.cliente_id === 'number' ? Number(r.cliente_id) : Number(r.cliente_id) || 0;
      return cid === id;
    });
    return !row || !row.status_retorno;
  }).length;
  const jaTrabalhadosOptimistic = jaTrabalhadosBase + novosClientesTrabalhados;
  const viraramPedidoOptimistic = asNum(kpiData?.viraram_pedido);

  // ── Render ──────────────────────────────────────────────────────────────────

  return (
    <div className="space-y-6 w-full max-w-7xl mx-auto">
      {/* Header */}
      <div>
        <h2 className="text-2xl font-bold text-foreground">A semana</h2>
        <p className="text-sm text-muted-foreground mt-0.5">
          Fila semanal de {kpiData ? fmtInt(kpiData.contatos) : '—'} contatos priorizados
        </p>
      </div>

      {/* KPI cards — `ja_trabalhados` usa contagem otimista pra refletir IMEDIATAMENTE
          cada clique de status, sem esperar o round-trip. Os outros cards refletem o
          banco e atualizam no próximo refetch (mudança de filtro, F5, etc.). */}
      {kpis.loading ? (
        <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4">
          {[1, 2, 3, 4].map(i => <Skeleton key={i} className="h-24 w-full" />)}
        </div>
      ) : kpis.error ? (
        <ErrorState message={kpis.error} />
      ) : kpiData ? (
        <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4">
          <KpiCard label="Contatos" value={fmtInt(kpiData.contatos)} sub={`${kpiData.vendedores} vendedores`} icon="👥" />
          <KpiCard label="Receita esperada" value={fmtBRL(kpiData.receita_esperada)} sub="Estimativa baseada no score" icon="💰" />
          <KpiCard label="Conversão prevista" value={fmtPct(conv)} sub={`Base: ${fmtPct(taxaBase)} às cegas`} icon="📈" />
          <KpiCard
            label="Já trabalhados"
            value={fmtInt(jaTrabalhadosOptimistic)}
            sub={viraramPedidoOptimistic > 0 ? `${viraramPedidoOptimistic} virou pedido` : 'Ninguém ligou ainda'}
            icon="📞"
          />
        </div>
      ) : (
        <p className="text-muted-foreground">Sem dados.</p>
      )}

      {/* Erro de POST */}
      {postError && (
        <Alert variant="destructive">
          <AlertDescription>{postError}</AlertDescription>
        </Alert>
      )}

      {/* Filtro por vendedor */}
      <div className="flex items-center gap-3">
        <label className="text-sm font-medium text-foreground" htmlFor="vendedor-filter">
          Filtrar por vendedor:
        </label>
        <Select value={vendedor} onValueChange={setVendedor}>
          <SelectTrigger id="vendedor-filter" className="w-72">
            <SelectValue placeholder="Todos" />
          </SelectTrigger>
          <SelectContent>
            {vendedoresData.map(opt => (
              <SelectItem key={opt.value} value={opt.value}>
                {opt.label}
              </SelectItem>
            ))}
          </SelectContent>
        </Select>
      </div>

      {/* Tabela — key força remount, mas filtro sobrevive porque vive no Layout */}
      <Card className="shadow-sm">
        <CardHeader>
          <CardTitle className="text-base font-semibold">Fila de contatos</CardTitle>
        </CardHeader>
        <CardContent className="p-0">
          {fila.loading ? (
            <div className="p-4 space-y-2">
              {[1, 2, 3, 4, 5, 6, 7, 8].map(i => <Skeleton key={i} className="h-10 w-full" />)}
            </div>
          ) : fila.error ? (
            <div className="p-4"><ErrorState message={fila.error} /></div>
          ) : filaData.length === 0 ? (
            <div className="p-8 text-center">
              <p className="text-muted-foreground">
                {vendedor !== 'Todos' ? `Nenhum contato para ${vendedor}.` : 'Fila vazia.'}
              </p>
              {vendedor !== 'Todos' && (
                <p className="text-xs text-muted-foreground/70 mt-2">
                  A fila é global. Escolha &ldquo;Todos&rdquo; para ver todos.
                </p>
              )}
            </div>
          ) : (
            // key muda → React destrói e recria → useAnalyticsQuery re-executa
            <div key={`fila-${reloadKey}-${vendedor}`} className="overflow-x-auto">
              <Table className="w-full text-sm">
                <TableHeader>
                  <TableRow className="bg-muted/40">
                    <TableHead className="w-10 font-semibold text-xs">#</TableHead>
                    <TableHead className="min-w-[200px] font-semibold text-xs">Cliente</TableHead>
                    <TableHead className="w-28 font-semibold text-xs">Vendedor</TableHead>
                    <TableHead className="w-20 font-semibold text-xs">Score</TableHead>
                    <TableHead className="min-w-[160px] font-semibold text-xs">Motivo</TableHead>
                    <TableHead className="min-w-[140px] font-semibold text-xs">Sugestão</TableHead>
                    <TableHead className="min-w-[220px] font-semibold text-xs">Status da ligação</TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {filaData.map((row, i) => {
                    const chance = asNum(row.chance_pct);
                    const clienteId = typeof row.cliente_id === 'number'
                      ? Number(row.cliente_id)
                      : Number(row.cliente_id) || i;
                    const saving = savingFor.has(clienteId);
                    // Status efetivo: otimismo local > banco
                    const bankStatus = row.status_retorno as RetornoStatus | null;
                    const effectiveStatus = localStatus[clienteId] ?? bankStatus;

                    const scoreColor = chance >= 80 ? 'bg-red-50 text-red-700 border-red-200'
                      : chance >= 60 ? 'bg-orange-50 text-orange-700 border-orange-200'
                      : chance >= 40 ? 'bg-yellow-50 text-yellow-700 border-yellow-200'
                      : 'bg-slate-50 text-slate-500 border-slate-200';

                    return (
                      <TableRow
                        key={clienteId}
                        className={effectiveStatus ? 'bg-green-50/30' : 'hover:bg-muted/20'}
                      >
                        <TableCell className="font-mono text-xs text-muted-foreground">
                          {row.ordem}
                        </TableCell>
                        <TableCell>
                          <div className="font-medium text-foreground leading-tight">{row.razao_social}</div>
                          <div className="text-xs text-muted-foreground mt-0.5">{row.localizacao}</div>
                        </TableCell>
                        <TableCell className="text-muted-foreground">{row.vendedor}</TableCell>
                        <TableCell>
                          <span className={`inline-flex items-center justify-center min-w-[40px] px-2 py-0.5 rounded border text-xs font-semibold ${scoreColor}`}>
                            {fmtPct(chance)}
                          </span>
                        </TableCell>
                        <TableCell className="text-xs text-muted-foreground leading-relaxed max-w-[160px]">
                          <span className="line-clamp-2">{row.motivo}</span>
                        </TableCell>
                        <TableCell className="text-xs text-muted-foreground leading-relaxed max-w-[140px]">
                          <span className="line-clamp-2">{row.sugestao}</span>
                        </TableCell>
                        {/* Status: seletor 2x2 inline */}
                        <TableCell className="p-1 align-middle">
                          <StatusSelector
                            clienteId={clienteId}
                            vendedorVal={String(row.vendedor)}
                            currentStatus={effectiveStatus}
                            saving={saving}
                            onStatusChange={(id, v, s) => { void handleStatusChange(id, v, s); }}
                          />
                        </TableCell>
                      </TableRow>
                    );
                  })}
                </TableBody>
              </Table>
            </div>
          )}
        </CardContent>
      </Card>
    </div>
  );
}
