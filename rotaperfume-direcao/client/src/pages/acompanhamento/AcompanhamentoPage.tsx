/**
 * AcompanhamentoPage -- "Acompanhamento"
 *
 * Shows per-vendedor (or global) work status:
 * - 4 KPI cards
 * - Bar chart of trabalhados vs viraram_pedido per vendedor (global only)
 * - Status breakdown boxes
 */

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
  Empty,
  EmptyDescription,
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from '@databricks/appkit-ui/react';
import { useState } from 'react';
import { useAnalyticsQuery } from '@databricks/appkit-ui/react';
import { sql } from '@databricks/appkit-ui/js';
import {
  BarChart,
  Bar,
  XAxis,
  YAxis,
  CartesianGrid,
  Tooltip,
  Legend,
  ResponsiveContainer,
} from 'recharts';

// ── Helpers ────────────────────────────────────────────────────────────────────

function asNum(v: unknown, fallback = 0): number {
  if (v === null || v === undefined || v === '') return fallback;
  const n = Number(v);
  return Number.isFinite(n) ? n : fallback;
}

function fmtInt(v: unknown): string {
  return asNum(v).toLocaleString('pt-BR');
}

function asRows<T>(v: unknown): T[] {
  if (Array.isArray(v)) return v as T[];
  return [];
}

// ── Tipos ─────────────────────────────────────────────────────────────────────

interface AcompRow {
  vendedor: string;
  na_fila: string | number;
  trabalhados: string | number;
  viraram_pedido: string | number;
  vai_pensar: string | number;
  sem_interesse: string | number;
  nao_atendeu: string | number;
}

interface VendedorOption {
  value: string;
  label: string;
}

// ── Componentes ────────────────────────────────────────────────────────────────

function KpiCard({ label, value, sub, icon }: { label: string; value: string; sub?: string; icon: string }) {
  return (
    <Card className="shadow-sm">
      <CardContent className="pt-4">
        <div className="flex items-start justify-between">
          <div>
            <p className="text-xs text-muted-foreground font-medium">{label}</p>
            <p className="text-2xl font-bold text-foreground mt-0.5">{value}</p>
            {sub && <p className="text-xs text-muted-foreground/70 mt-0.5">{sub}</p>}
          </div>
          <span className="text-2xl" role="img" aria-hidden="true">{icon}</span>
        </div>
      </CardContent>
    </Card>
  );
}

function StatusBox({ value, label, color }: { value: number; label: string; color: string }) {
  return (
    <div className={`text-center p-3 rounded-lg ${color}`}>
      <p className="text-2xl font-bold">{fmtInt(value)}</p>
      <p className="text-xs mt-1 opacity-80">{label}</p>
    </div>
  );
}

function ErrorState({ message }: { message: string }) {
  return (
    <Alert variant="destructive">
      <AlertDescription>Erro: {message}</AlertDescription>
    </Alert>
  );
}

// ── Main Page ────────────────────────────────────────────────────────────────

export function AcompanhamentoPage() {
  const [vendedor, setVendedor] = useState<string>('Todos');
  const isGlobal = vendedor === 'Todos';

  const acomp = useAnalyticsQuery('acompanhamento', {
    vendedor: sql.string(vendedor),
  });
  const acompData = asRows<AcompRow>(acomp.data);

  const vendedores = useAnalyticsQuery('vendedores', {});
  const vendedoresData = asRows<VendedorOption>(vendedores.data);

  const hasAnyWork = acompData.some(r => asNum(r.trabalhados) > 0);

  return (
    <div className="space-y-6 w-full max-w-7xl mx-auto">
      {/* Header */}
      <div>
        <h2 className="text-2xl font-bold text-foreground">Acompanhamento</h2>
        <p className="text-sm text-muted-foreground mt-0.5">
          Status do trabalho da semana {isGlobal ? '— todos os vendedores' : `de ${vendedor}`}
        </p>
      </div>

      {/* Filter */}
      <div className="flex items-center gap-3">
        <label className="text-sm font-medium text-foreground" htmlFor="acomp-vendedor">
          Selecione o vendedor:
        </label>
        <Select value={vendedor} onValueChange={setVendedor}>
          <SelectTrigger id="acomp-vendedor" className="w-72">
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

      {/* KPIs + chart */}
      {acomp.loading ? (
        <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4">
          {[1,2,3,4].map(i => <Skeleton key={i} className="h-24 w-full" />)}
        </div>
      ) : acomp.error ? (
        <ErrorState message={acomp.error} />
      ) : acompData.length === 0 ? (
        <Empty>
          <EmptyDescription>Nenhum dado de acompanhamento.</EmptyDescription>
        </Empty>
      ) : (() => {
          const na_fila_t = acompData.reduce<number>((s, r) => s + asNum(r.na_fila), 0);
          const trab_t   = acompData.reduce<number>((s, r) => s + asNum(r.trabalhados), 0);
          const pedido_t = acompData.reduce<number>((s, r) => s + asNum(r.viraram_pedido), 0);
          const pensar_t = acompData.reduce<number>((s, r) => s + asNum(r.vai_pensar), 0);
          const semInt_t = acompData.reduce<number>((s, r) => s + asNum(r.sem_interesse), 0);
          const naoAt_t = acompData.reduce<number>((s, r) => s + asNum(r.nao_atendeu), 0);
          const pendentes = na_fila_t - trab_t;
          const taxaConv = trab_t > 0 ? (pedido_t / trab_t * 100).toFixed(1) : '0';

          const chartData = acompData.map(r => ({
            vendedor: String(r.vendedor).split(' ')[0], // first name only for readability
            Trabalhados: asNum(r.trabalhados),
            'Viraram pedido': asNum(r.viraram_pedido),
          }));

          if (isGlobal) {
            return (
              <>
                <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4">
                  <KpiCard label="Total na fila" value={fmtInt(na_fila_t)} sub={`${acompData.length} vendedores`} icon="👥" />
                  <KpiCard label="Trabalhados" value={fmtInt(trab_t)} sub={`${na_fila_t > 0 ? (trab_t / na_fila_t * 100).toFixed(1) : 0}% da fila`} icon="📞" />
                  <KpiCard label="Viraram pedido" value={fmtInt(pedido_t)} sub={`${taxaConv}% de conversão`} icon="✅" />
                  <KpiCard label="Pendentes" value={fmtInt(pendentes)} sub="Ainda não contatados" icon="⏳" />
                </div>

                {/* Bar chart */}
                {hasAnyWork ? (
                  <Card className="shadow-sm">
                    <CardHeader>
                      <CardTitle className="text-base">Trabalho por vendedor</CardTitle>
                    </CardHeader>
                    <CardContent>
                      <ResponsiveContainer width="100%" height={250}>
                        <BarChart data={chartData} margin={{ top: 5, right: 20, left: 0, bottom: 5 }}>
                          <CartesianGrid strokeDasharray="3 3" />
                          <XAxis dataKey="vendedor" tick={{ fontSize: 11 }} interval={0} />
                          <YAxis tick={{ fontSize: 11 }} allowDecimals={false} />
                          <Tooltip />
                          <Legend />
                          <Bar dataKey="Trabalhados" fill="#3b82f6" />
                          <Bar dataKey="Viraram pedido" fill="#22c55e" />
                        </BarChart>
                      </ResponsiveContainer>
                    </CardContent>
                  </Card>
                ) : (
                  <Empty>
                    <EmptyDescription>
                      Os números aparecem assim que o time marcar o retorno na aba "A semana".
                      Zero não é erro — é o estado inicial.
                    </EmptyDescription>
                  </Empty>
                )}

                {/* Status breakdown */}
                <Card className="shadow-sm">
                  <CardHeader>
                    <CardTitle className="text-base">Resultado das ligações</CardTitle>
                  </CardHeader>
                  <CardContent>
                    <div className="grid grid-cols-2 md:grid-cols-4 gap-4">
                      <StatusBox value={pedido_t} label="✅ Viraram pedido" color="bg-green-50" />
                      <StatusBox value={pensar_t} label="🤔 Vai pensar" color="bg-yellow-50" />
                      <StatusBox value={semInt_t} label="❌ Sem interesse" color="bg-red-50" />
                      <StatusBox value={naoAt_t} label="📵 Não atendeu" color="bg-gray-100" />
                    </div>
                  </CardContent>
                </Card>

                {/* Detail table */}
                <Card className="shadow-sm">
                  <CardHeader>
                    <CardTitle className="text-base">Por vendedor</CardTitle>
                  </CardHeader>
                  <CardContent className="p-0">
                    <div className="overflow-x-auto">
                      <Table className="w-full text-sm">
                        <TableHeader>
                          <TableRow>
                            <TableHead>Vendedor</TableHead>
                            <TableHead className="text-right">Na fila</TableHead>
                            <TableHead className="text-right">Trabalhados</TableHead>
                            <TableHead className="text-right">Viraram pedido</TableHead>
                            <TableHead className="text-right">Vai pensar</TableHead>
                            <TableHead className="text-right">Sem interesse</TableHead>
                            <TableHead className="text-right">Não atendeu</TableHead>
                          </TableRow>
                        </TableHeader>
                        <TableBody>
                          {acompData.map((row) => (
                            <TableRow key={row.vendedor}>
                              <TableCell className="font-medium">{row.vendedor}</TableCell>
                              <TableCell className="text-right">{fmtInt(row.na_fila)}</TableCell>
                              <TableCell className="text-right">{fmtInt(row.trabalhados)}</TableCell>
                              <TableCell className="text-right">{fmtInt(row.viraram_pedido)}</TableCell>
                              <TableCell className="text-right">{fmtInt(row.vai_pensar)}</TableCell>
                              <TableCell className="text-right">{fmtInt(row.sem_interesse)}</TableCell>
                              <TableCell className="text-right">{fmtInt(row.nao_atendeu)}</TableCell>
                            </TableRow>
                          ))}
                        </TableBody>
                      </Table>
                    </div>
                  </CardContent>
                </Card>
              </>
            );
          } else {
            // Single-vendedor view
            const row = acompData[0];
            if (!row) return null;
            const naFila = asNum(row.na_fila);
            const trab   = asNum(row.trabalhados);
            const pedido = asNum(row.viraram_pedido);
            const pendentesV = naFila - trab;
            const taxaConvV  = trab > 0 ? (pedido / trab * 100).toFixed(1) : '0';

            return (
              <div className="space-y-6">
                <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4">
                  <KpiCard label="Contatos na fila" value={fmtInt(naFila)} icon="👥" />
                  <KpiCard label="Trabalhados" value={fmtInt(trab)} sub={naFila > 0 ? `${(trab / naFila * 100).toFixed(1)}% da fila` : undefined} icon="📞" />
                  <KpiCard label="Viraram pedido" value={fmtInt(pedido)} sub={`${taxaConvV}% de conversão`} icon="✅" />
                  <KpiCard label="Pendentes" value={fmtInt(pendentesV)} sub="Ainda não contatados" icon="⏳" />
                </div>

                <Card className="shadow-sm">
                  <CardHeader>
                    <CardTitle className="text-base">Status das ligações de {row.vendedor}</CardTitle>
                  </CardHeader>
                  <CardContent>
                    <div className="grid grid-cols-2 md:grid-cols-4 gap-4">
                      <StatusBox value={asNum(row.viraram_pedido)} label="✅ Viraram pedido" color="bg-green-50" />
                      <StatusBox value={asNum(row.vai_pensar)}     label="🤔 Vai pensar"     color="bg-yellow-50" />
                      <StatusBox value={asNum(row.sem_interesse)} label="❌ Sem interesse" color="bg-red-50" />
                      <StatusBox value={asNum(row.nao_atendeu)}  label="📵 Não atendeu"  color="bg-gray-100" />
                    </div>
                  </CardContent>
                </Card>
              </div>
            );
          }
        })()
      }
    </div>
  );
}
