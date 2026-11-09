import { Hono, type Context, type MiddlewareHandler } from 'hono';
import { cors } from 'hono/cors';
import { secureHeaders } from 'hono/secure-headers';
import { z, ZodError } from 'zod';
import { validateConfig } from './config';
import { HttpError } from './errors';
import { runIdempotent, sha256, validateIdempotencyKey } from './idempotency';
import type { Bindings, Deps, OrgContext, Variables } from './types';

type Env = { Bindings: Bindings; Variables: Variables };
type Ctx = Context<Env>;

const uuid = z.string().uuid();
const tz = z.string().refine((v) => {
  try { new Intl.DateTimeFormat('en', { timeZone: v }); return true; } catch { return false; }
}, 'invalid timezone');
const name = z.string().trim().min(2).max(200);
const nonEmpty = (o: object) => Object.keys(o).length > 0;

const unitCreate = z.object({ name, timezone: tz.optional() }).strict();
const unitPatch = z.object({ name: name.optional(), timezone: tz.optional(), status: z.enum(['active', 'inactive']).optional() })
  .strict().refine(nonEmpty, 'empty patch');
const orgPatch = z.object({
  name: name.optional(),
  legal_name: z.string().trim().max(300).nullable().optional(),
  cnpj: z.string().regex(/^\d{14}$/).nullable().optional(),
  timezone: tz.optional(),
}).strict().refine(nonEmpty, 'empty patch');
const auditQuery = z.object({
  limit: z.coerce.number().int().min(1).max(100).default(50),
  before: z.coerce.number().int().positive().optional(),
});

export function can(ctx: OrgContext, perm: string, unitId?: string): boolean {
  if (ctx.permissions.includes(perm)) return true;
  return !!unitId && ctx.unit_scopes.some((s) => s.unit_id === unitId && s.permissions.includes(perm));
}
const canAnyUnit = (ctx: OrgContext, perm: string) =>
  ctx.permissions.includes(perm) || ctx.unit_scopes.some((s) => s.permissions.includes(perm));

function log(level: 'info' | 'warn' | 'error', event: string, fields: Record<string, unknown>) {
  // Nunca registrar PII, tokens ou conteúdo clínico.
  console.log(JSON.stringify({ level, event, ...fields }));
}

async function readJson(c: Ctx): Promise<unknown> {
  try { return JSON.parse(await c.req.text()); } catch { throw new HttpError(400, 'Invalid JSON body'); }
}

async function audit(c: Ctx, p: { action: string; resourceType: string; resourceId: string; result: 'success' | 'denied' | 'error'; unitId?: string | null }) {
  const org = c.get('org');
  if (!org) return;
  try {
    await c.get('repo').writeAudit({
      organizationId: org.organization_id, unitId: p.unitId ?? null, action: p.action,
      resourceType: p.resourceType, resourceId: p.resourceId, result: p.result,
      ip: c.req.header('cf-connecting-ip') ?? null,
      userAgent: (c.req.header('user-agent') ?? '').slice(0, 300) || null,
      correlationId: c.get('requestId'),
    });
  } catch (e) {
    log('error', 'audit_write_failed', { requestId: c.get('requestId'), action: p.action, message: (e as Error).message });
  }
}

export function createApp(deps: Deps) {
  const app = new Hono<Env>();

  app.use('*', async (c, next) => {
    const id = c.req.header('x-request-id');
    c.set('requestId', id && /^[A-Za-z0-9-]{8,64}$/.test(id) ? id : crypto.randomUUID());
    c.header('X-Request-Id', c.get('requestId'));
    await next();
  });
  app.use('*', secureHeaders());
  app.use('/api/*', cors({
    origin: (origin, c) => (c.env.ALLOWED_ORIGIN && origin === c.env.ALLOWED_ORIGIN ? origin : ''),
    allowHeaders: ['Authorization', 'Content-Type', 'X-Organization-Id', 'Idempotency-Key', 'X-Request-Id'],
    allowMethods: ['GET', 'POST', 'PATCH', 'OPTIONS'],
  }));

  app.use('/api/*', async (c, next) => {
    const problem = validateConfig(c.env);
    if (problem) {
      log('error', 'misconfigured', { requestId: c.get('requestId'), problem });
      throw new HttpError(500, 'Server misconfigured');
    }
    await next();
  });

  app.get('/api/health', (c) => c.json({ status: 'ok', env: c.env.APP_ENV }));

  // ---- autenticação ----
  const auth: MiddlewareHandler<Env> = async (c, next) => {
    const m = /^Bearer (.+)$/.exec(c.req.header('authorization') ?? '');
    if (!m || !m[1]) throw new HttpError(401, 'Unauthorized');
    const user = await deps.verifyToken(c.env, m[1]);
    if (!user) throw new HttpError(401, 'Unauthorized');
    c.set('jwt', m[1]);
    c.set('userId', user.userId);
    c.set('repo', deps.makeRepo(c.env, m[1]));
    await next();
  };
  app.use('/api/*', auth);

  // ---- rate limit (ativo apenas se o limitador estiver configurado) ----
  app.use('/api/*', async (c, next) => {
    const limiter = deps.makeRateLimiter?.(c.env);
    if (limiter) {
      let allowed: boolean;
      try { allowed = await limiter.hit(`u:${c.get('userId')}`, 60, 120); }
      catch (e) {
        log('error', 'rate_limiter_failed', { requestId: c.get('requestId'), message: (e as Error).message });
        throw new HttpError(503, 'Service unavailable');
      }
      if (!allowed) { c.header('Retry-After', '60'); throw new HttpError(429, 'Too many requests'); }
    }
    await next();
  });

  app.get('/api/me', async (c) => {
    const contexts = await c.get('repo').getContexts();
    return c.json({ user_id: c.get('userId'), organizations: contexts });
  });

  // ---- escopo de organização (derivado dos vínculos reais, nunca confiado do cliente) ----
  const org = new Hono<Env>();
  org.use('*', async (c, next) => {
    const orgId = c.req.header('x-organization-id');
    if (!orgId || !uuid.safeParse(orgId).success) throw new HttpError(400, 'X-Organization-Id header required');
    const ctx = (await c.get('repo').getContexts()).find((x) => x.organization_id === orgId);
    if (!ctx) throw new HttpError(403, 'Forbidden');
    if (ctx.organization_status !== 'active') throw new HttpError(403, 'Organization is not active');
    c.set('org', ctx);
    await next();
  });

  const guard = (perm: string, opts: { unitParam?: string; anyUnit?: boolean } = {}): MiddlewareHandler<Env> =>
    async (c, next) => {
      const ctx = c.get('org')!;
      let unitId: string | undefined;
      if (opts.unitParam) {
        unitId = c.req.param(opts.unitParam);
        if (!uuid.safeParse(unitId).success) throw new HttpError(400, 'Invalid id');
      }
      const allowed = opts.anyUnit ? canAnyUnit(ctx, perm) : can(ctx, perm, unitId);
      if (!allowed) {
        await audit(c, { action: `denied:${perm}`, resourceType: 'permission', resourceId: perm, result: 'denied', unitId });
        throw new HttpError(403, 'Forbidden');
      }
      await next();
    };

  org.get('/', guard('org.read'), async (c) => {
    const row = await c.get('repo').getOrganization(c.get('org')!.organization_id);
    if (!row) throw new HttpError(404, 'Not found');
    return c.json(row);
  });

  org.patch('/', guard('org.manage'), async (c) => {
    const patch = orgPatch.parse(await readJson(c));
    const orgId = c.get('org')!.organization_id;
    const row = await c.get('repo').updateOrganization(orgId, patch);
    if (!row) throw new HttpError(404, 'Not found');
    await audit(c, { action: 'organization.update', resourceType: 'organization', resourceId: orgId, result: 'success' });
    return c.json(row);
  });

  org.get('/units', guard('unit.read', { anyUnit: true }), async (c) =>
    c.json({ items: await c.get('repo').listUnits(c.get('org')!.organization_id) }));

  org.post('/units', guard('unit.write'), async (c) => {
    const input = unitCreate.parse(await readJson(c));
    const orgId = c.get('org')!.organization_id;
    const exec = async () => {
      const unit = await c.get('repo').createUnit(orgId, input);
      await audit(c, { action: 'unit.create', resourceType: 'unit', resourceId: unit.id, result: 'success', unitId: unit.id });
      return { status: 201, body: unit as unknown };
    };
    const key = c.req.header('idempotency-key');
    if (!key) { const r = await exec(); return c.json(r.body, 201); }
    validateIdempotencyKey(key);
    const r = await runIdempotent(c.get('repo'),
      { orgId, userId: c.get('userId'), scope: 'units.create', key, hash: await sha256(JSON.stringify(input)) }, exec);
    c.header('Idempotent-Replayed', String(r.replayed));
    return c.json(r.body, r.status as 200 | 201);
  });

  org.patch('/units/:id', guard('unit.write', { unitParam: 'id' }), async (c) => {
    const id = c.req.param('id');
    const patch = unitPatch.parse(await readJson(c));
    const row = await c.get('repo').updateUnit(c.get('org')!.organization_id, id, patch);
    if (!row) throw new HttpError(404, 'Not found');
    await audit(c, { action: 'unit.update', resourceType: 'unit', resourceId: id, result: 'success', unitId: id });
    return c.json(row);
  });

  org.get('/audit-logs', guard('audit.read'), async (c) => {
    const q = auditQuery.parse(c.req.query());
    const items = await c.get('repo').listAudit(c.get('org')!.organization_id, q.limit, q.before);
    return c.json({ items });
  });

  app.route('/api/org', org);

  app.notFound((c) => problem(c, 404, 'Not found'));
  app.onError((err, c) => {
    if (err instanceof HttpError) return problem(c, err.status, err.title, err.detail);
    if (err instanceof ZodError) {
      return problem(c, 422, 'Validation failed', err.issues.map((i) => `${i.path.join('.') || '(body)'}: ${i.message}`).join('; '));
    }
    log('error', 'unhandled', { requestId: c.get('requestId'), message: err.message });
    return problem(c, 500, 'Internal error');
  });

  return app;
}

function problem(c: Context, status: number, title: string, detail?: string) {
  return c.json(
    { type: 'about:blank', title, status, ...(detail ? { detail } : {}), instance: c.get('requestId' as never) },
    status as 400,
    { 'Content-Type': 'application/problem+json' },
  );
}
