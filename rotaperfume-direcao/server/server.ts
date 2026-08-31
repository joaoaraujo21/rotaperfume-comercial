/**
 * server.ts — entrypoint do backend.
 *
 * Rotas customizadas registradas em onPluginsReady via appkit.server.extend().
 * Leitura continua sendo arquivo .sql + useAnalyticsQuery no front.
 * Escrita é uma rota POST por tabela, validada com Zod.
 *
 * Cache de leitura desligado: cada clique muda o estado de uma linha
 * (de "sem retorno" para "vendeu"), e o AppKit cacheia o resultado da
 * query por TTL. Sem cache, o reload via `key` no React sempre lê de novo.
 */

import express from 'express';
import { z } from 'zod';
import { createApp, analytics, genie, server, sql } from '@databricks/appkit';

// ── Schema do POST /api/retorno ────────────────────────────────────────────────

const RetornoSchema = z.object({
  cliente_id: z.coerce.number().int().positive(),
  vendedor:   z.string().min(1).max(100),
  status:     z.enum(['vendeu', 'vai_pensar', 'sem_interesse', 'nao_atendeu']),
  comentario: z.string().max(500).optional().default(''),
  referencia: z.string().regex(/^\d{4}-\d{2}-\d{2}$/, 'Formato: aaaa-mm-dd'),
});

type RetornoInput = z.infer<typeof RetornoSchema>;

// ── SQL parametrizado ──────────────────────────────────────────────────────────

const INSERT_RETORNO = `
  INSERT INTO lakehouse_rotaperfume.gold.retorno_ligacao
    (cliente_id, vendedor, status, comentario, registrado_em, registrado_por, _referencia)
  VALUES
    (:cliente_id, :vendedor, :status, :comentario, CURRENT_TIMESTAMP(), :registrado_por, :referencia)
`;

// ── App ────────────────────────────────────────────────────────────────────────

createApp({
  // Desligar o cache de leitura: o dado muda cada vez que alguém clica.
  cache: { enabled: false },
  plugins: [
    analytics(),
    // O alias "genie-space" corresponde a GenieChat alias="genie-space" no frontend.
    // O space_id vem da variável de ambiente DATABRICKS_GENIE_SPACE_ID
    // (definida em app.yaml via valor do recurso genie-space).
    genie({
      spaces: { 'genie-space': process.env.DATABRICKS_GENIE_SPACE_ID! },
    }),
    server(),
  ],
  onPluginsReady(appkit) {
    appkit.server.extend((app) => {
      // GET /api/quem-sou — quem está logado (a aba Perguntar já usa)
      app.get('/api/quem-sou', (req, res) => {
        const email = req.headers['x-forwarded-email']
          ?? req.headers['x-forwarded-user']
          ?? 'dev@rotaperfume.local';
        res.json({ email: String(email) });
      });

      // POST /api/retorno — grava um retorno de ligação
      app.post('/api/retorno', express.json(), async (req, res) => {
        console.log('[retorno] === POST RECEIVED ===');
        console.log('[retorno] headers:', JSON.stringify({
          'content-type': req.headers['content-type'],
          'x-forwarded-email': req.headers['x-forwarded-email'],
          'x-forwarded-user': req.headers['x-forwarded-user'],
          'authorization': req.headers['authorization'] ? 'PRESENT' : 'MISSING',
        }));
        console.log('[retorno] body:', JSON.stringify(req.body));
        const parsed = RetornoSchema.safeParse(req.body);
        if (!parsed.success) {
          console.log('[retorno] VALIDATION FAILED:', JSON.stringify(parsed.error.flatten()));
          return res.status(400).json({
            error: 'VALIDATION_ERROR',
            detail: parsed.error.flatten(),
          });
        }

        const data: RetornoInput = parsed.data;
        const registrado_por = String(
          req.headers['x-forwarded-email']
            ?? req.headers['x-forwarded-user']
            ?? 'dev@rotaperfume.local'
        );
        console.log('[retorno] parsed:', JSON.stringify(data), 'registrado_por:', registrado_por);

        try {
          await appkit.analytics.query(INSERT_RETORNO, {
            cliente_id:     sql.int(data.cliente_id),
            vendedor:       sql.string(data.vendedor),
            status:         sql.string(data.status),
            comentario:     sql.string(data.comentario ?? ''),
            registrado_por: sql.string(registrado_por),
            referencia:     sql.string(data.referencia),
          });
          console.log('[retorno] INSERT OK cliente_id=' + data.cliente_id + ' status=' + data.status);
          return res.status(201).json({ ok: true });
        } catch (err: any) {
          console.error('[retorno] INSERT failed:', err);
          return res.status(500).json({
            error: 'INSERT_FAILED',
            detail: String(err?.message ?? err),
          });
        }
      });
    });
  },
}).catch(console.error);
