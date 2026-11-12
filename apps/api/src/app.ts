import { Hono, type Context, type MiddlewareHandler } from 'hono';
import { cors } from 'hono/cors';
import { secureHeaders } from 'hono/secure-headers';
import { z, ZodError } from 'zod';
import { validateConfig } from './config';
import { hashCpf, isValidCpf, maskCpf, normalizeCpf } from './cpf';
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

const instantLike = () => z.string().datetime({ offset: true });
const unitCreate = z.object({ name, timezone: tz.optional() }).strict();
const unitPatch = z.object({ name: name.optional(), timezone: tz.optional(), status: z.enum(['active', 'inactive']).optional() })
  .strict().refine(nonEmpty, 'empty patch');
const orgPatch = z.object({
  name: name.optional(),
  legal_name: z.string().trim().max(300).nullable().optional(),
  cnpj: z.string().regex(/^\d{14}$/).nullable().optional(),
  timezone: tz.optional(),
}).strict().refine(nonEmpty, 'empty patch');
const isoDate = z.string().regex(/^\d{4}-\d{2}-\d{2}$/).refine((v) => {
  const d = new Date(`${v}T00:00:00Z`);
  return !Number.isNaN(d.getTime()) && d.toISOString().startsWith(v) && v >= '1900-01-01' && d.getTime() <= Date.now();
}, 'invalid or future date');
const cpfInput = z.string().transform(normalizeCpf).refine(isValidCpf, 'invalid cpf');
const phone = z.string().regex(/^\d{10,13}$/);
const patientCreate = z.object({
  full_name: name, social_name: name.optional(), birth_date: isoDate, cpf: cpfInput.optional(),
  phone: phone.optional(), email: z.string().trim().email().max(254).optional(),
  confirm_possible_duplicate: z.boolean().optional(),
}).strict();
const patientPatch = z.object({
  full_name: name.optional(), social_name: name.nullable().optional(), birth_date: isoDate.optional(), cpf: cpfInput.nullable().optional(),
  phone: phone.nullable().optional(), email: z.string().trim().email().max(254).nullable().optional(), status: z.enum(['active', 'inactive']).optional(),
}).strict().refine(nonEmpty, 'empty patch');
const patientQuery = z.object({
  q: z.string().trim().min(2).max(100).optional(), cpf: cpfInput.optional(), birth_date: isoDate.optional(),
  limit: z.coerce.number().int().min(1).max(100).default(30), offset: z.coerce.number().int().min(0).max(1000).default(0),
}).refine((q) => !!(q.q || q.cpf || q.birth_date), 'at least one filter (q, cpf, birth_date) is required');
const consentBody = z.object({
  purpose: z.enum(['care_data', 'communication', 'data_sharing', 'research']), granted: z.boolean(), source: z.enum(['in_person', 'portal', 'phone']),
}).strict();
const guardianBody = z.object({
  guardian_patient_id: uuid, relationship: z.enum(['parent', 'legal_guardian', 'curator', 'other']), valid_to: instantLike().optional(),
}).strict();
const linkBody = z.object({ user_id: uuid }).strict();
const purposeEnum = z.enum(['care', 'emergency']);
const pageLimit = z.coerce.number().int().min(1).max(100).default(50);
const recordCreate = z.object({
  kind: z.enum(['anamnesis', 'evolution', 'conduct']), title: z.string().trim().min(2).max(200),
  body: z.string().trim().min(1).max(20000), event_id: uuid.optional(),
}).strict();
const recordPatch = z.object({ title: z.string().trim().min(2).max(200), body: z.string().trim().min(1).max(20000) }).strict();
const addendumBody = z.object({ reason: z.string().trim().min(3).max(300), body: z.string().trim().min(1).max(10000) }).strict();
const emergencyBody = z.object({ justification: z.string().trim().min(20).max(1000) }).strict();
const reviewBody = z.object({ outcome: z.enum(['justified', 'not_justified']), note: z.string().trim().max(500).optional() }).strict();
const careAssignBody = z.object({ professional_id: uuid, valid_to: instantLike().optional(), reason: z.string().trim().min(5).max(300) }).strict();
const careRevokeBody = z.object({ reason: z.string().trim().min(3).max(300) }).strict();
const clinicalListQuery = z.object({ purpose: purposeEnum, limit: pageLimit, offset: z.coerce.number().int().min(0).max(1000).default(0) });
const clinicalGetQuery = z.object({ purpose: purposeEnum });
const careQuery = z.object({ patient_id: uuid.optional(), professional_id: uuid.optional(), limit: pageLimit, offset: z.coerce.number().int().min(0).max(1000).default(0) });
const grantsQuery = z.object({ pending: z.enum(['true', 'false']).default('true'), limit: pageLimit });
const accessLogQuery = z.object({ patient_id: uuid.optional(), before: z.coerce.number().int().positive().optional(), limit: pageLimit });
const council = z.enum(['CRM', 'COREN', 'CRF', 'CRP', 'CREFITO', 'CRN', 'OUTRO']);
const professionalCreate = z.object({
  full_name: name, member_id: uuid.optional(),
  council: council.optional(), council_number: z.string().regex(/^[0-9A-Za-z.-]{1,20}$/).optional(),
  council_uf: z.string().regex(/^[A-Z]{2}$/).optional(), specialty: z.string().trim().min(2).max(120).optional(),
}).strict().refine((v) => !!v.council === !!v.council_number && !!v.council === !!v.council_uf, 'council, number and uf go together');
const professionalPatch = z.object({
  full_name: name.optional(), council: council.optional(), council_number: z.string().regex(/^[0-9A-Za-z.-]{1,20}$/).optional(),
  council_uf: z.string().regex(/^[A-Z]{2}$/).optional(), specialty: z.string().trim().min(2).max(120).optional(),
  status: z.enum(['active', 'inactive']).optional(),
}).strict().refine(nonEmpty, 'empty patch');
const shortName = z.string().trim().min(1).max(120);
const roomCreate = z.object({ unit_id: uuid, name: shortName, capacity: z.number().int().min(1).max(1000).optional() }).strict();
const roomPatch = z.object({ name: shortName.optional(), capacity: z.number().int().min(1).max(1000).optional(), status: z.enum(['active', 'inactive']).optional() })
  .strict().refine(nonEmpty, 'empty patch');
const equipCreate = z.object({ unit_id: uuid, name: shortName }).strict();
const equipPatch = z.object({ name: shortName.optional(), status: z.enum(['active', 'inactive']).optional() }).strict().refine(nonEmpty, 'empty patch');
const mins = (max: number) => z.number().int().min(0).max(max);
const serviceCreate = z.object({
  name, kind: z.enum(['consultation', 'exam', 'procedure']), duration_minutes: z.number().int().min(5).max(720),
  buffer_before_minutes: mins(120).optional(), buffer_after_minutes: mins(120).optional(), online_booking: z.boolean().optional(),
}).strict();
const servicePatch = z.object({
  name: name.optional(), duration_minutes: z.number().int().min(5).max(720).optional(),
  buffer_before_minutes: mins(120).optional(), buffer_after_minutes: mins(120).optional(), online_booking: z.boolean().optional(), status: z.enum(['active', 'inactive']).optional(),
}).strict().refine(nonEmpty, 'empty patch');
const instant = z.string().datetime({ offset: true });
const resourceRef = z.object({ type: z.enum(['professional', 'room', 'equipment']), id: uuid }).strict();
const bookBody = z.object({
  unit_id: uuid, kind: z.enum(['appointment', 'block', 'maintenance']).default('appointment'),
  service_id: uuid.optional(), starts_at: instant, ends_at: instant.optional(),
  resources: z.array(resourceRef).min(1).max(20), title: z.string().trim().min(2).max(200).optional(), patient_id: uuid.optional(),
}).strict().refine((b) => !b.patient_id || b.kind === 'appointment', 'patient_id only for appointments');
const cancelBody = z.object({ reason: z.string().trim().min(3).max(300) }).strict();
const rescheduleBody = z.object({ starts_at: instant, ends_at: instant.optional() }).strict();
const eventsQuery = z.object({ unit_id: uuid.optional(), from: instant, to: instant, limit: z.coerce.number().int().min(1).max(500).default(200) })
  .refine((q) => Date.parse(q.to) > Date.parse(q.from) && Date.parse(q.to) - Date.parse(q.from) <= 62 * 86400_000, 'range must be positive and at most 62 days');
const portalSlotsQuery = z.object({
  unit_id: uuid, service_id: uuid, professional_id: uuid,
  from: z.string().regex(/^\d{4}-\d{2}-\d{2}$/), to: z.string().regex(/^\d{4}-\d{2}-\d{2}$/),
});
const portalBookBody = z.object({ unit_id: uuid, service_id: uuid, professional_id: uuid, starts_at: instant }).strict();
const portalCancelBody = z.object({ reason: z.string().trim().min(3).max(300).optional() }).strict();
const portalRescheduleBody = z.object({ starts_at: instant }).strict();
const availabilityBody = z.object({
  unit_id: uuid,
  windows: z.array(z.object({
    weekday: z.number().int().min(0).max(6),
    start: z.string().regex(/^([01]\d|2[0-3]):[0-5]\d$/), end: z.string().regex(/^([01]\d|2[0-3]):[0-5]\d$/),
  }).strict().refine((w) => w.end > w.start, 'end must be after start')).max(50),
}).strict();
const portalSettingsBody = z.object({
  min_lead_hours: z.number().int().min(0).max(168), cancel_min_hours: z.number().int().min(0).max(168),
  horizon_days: z.number().int().min(1).max(365), max_active_per_patient: z.number().int().min(1).max(50),
  max_reschedules: z.number().int().min(0).max(10),
}).strict();
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
  // Respostas da API (inclusive prontuário) nunca são guardadas por cache de navegador/proxy.
  app.use('/api/*', async (c, next) => { await next(); c.header('Cache-Control', 'no-store'); });
  app.use('/api/*', cors({
    origin: (origin, c) => (c.env.ALLOWED_ORIGIN && origin === c.env.ALLOWED_ORIGIN ? origin : ''),
    allowHeaders: ['Authorization', 'Content-Type', 'X-Organization-Id', 'Idempotency-Key', 'X-Request-Id', 'X-Turnstile-Token'],
    allowMethods: ['GET', 'POST', 'PATCH', 'PUT', 'OPTIONS'],
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
    c.set('repo', deps.makeRepo(c.env, m[1], {
      correlationId: c.get('requestId'),
      ip: c.req.header('cf-connecting-ip') ?? null,
      userAgent: (c.req.header('user-agent') ?? '').slice(0, 300) || null,
    }));
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

  // perm pode ser uma lista: basta uma (o banco ainda aplica RLS/vínculo)
  const guard = (permIn: string | string[], opts: { unitParam?: string; anyUnit?: boolean } = {}): MiddlewareHandler<Env> =>
    async (c, next) => {
      const ctx = c.get('org')!;
      let unitId: string | undefined;
      if (opts.unitParam) {
        unitId = c.req.param(opts.unitParam);
        if (!uuid.safeParse(unitId).success) throw new HttpError(400, 'Invalid id');
      }
      const perms = Array.isArray(permIn) ? permIn : [permIn];
      const allowed = perms.some((perm) => (opts.anyUnit ? canAnyUnit(ctx, perm) : can(ctx, perm, unitId)));
      if (!allowed) {
        await audit(c, { action: `denied:${perms.join('|')}`, resourceType: 'permission', resourceId: perms.join('|'), result: 'denied', unitId });
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
    return c.json(row);
  });

  org.get('/units', guard('unit.read', { anyUnit: true }), async (c) =>
    c.json({ items: await c.get('repo').listUnits(c.get('org')!.organization_id) }));

  org.post('/units', guard('unit.write'), async (c) => {
    const input = unitCreate.parse(await readJson(c));
    const orgId = c.get('org')!.organization_id;
    const exec = async () => {
      const unit = await c.get('repo').createUnit(orgId, input);
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
    return c.json(row);
  });

  org.get('/audit-logs', guard('audit.read'), async (c) => {
    const q = auditQuery.parse(c.req.query());
    const items = await c.get('repo').listAudit(c.get('org')!.organization_id, q.limit, q.before);
    return c.json({ items });
  });

  // ---- idempotência obrigatória nas operações de agenda ----
  const idempotent = async (c: Ctx, scope: string, input: unknown, exec: () => Promise<{ status: number; body: unknown }>) => {
    const key = c.req.header('idempotency-key');
    if (!key) throw new HttpError(400, 'Idempotency-Key header required');
    validateIdempotencyKey(key);
    const r = await runIdempotent(c.get('repo'),
      { orgId: c.get('org')!.organization_id, userId: c.get('userId'), scope, key, hash: await sha256(JSON.stringify(input)) }, exec);
    c.header('Idempotent-Replayed', String(r.replayed));
    return c.json(r.body, r.status as 200 | 201);
  };
  const unitWrite = (c: Ctx, perm: string, unitId: string) => {
    if (!can(c.get('org')!, perm, unitId)) throw new HttpError(403, 'Forbidden');
  };
  const idParam = (c: Ctx) => { const id = c.req.param('id') ?? ''; if (!uuid.safeParse(id).success) throw new HttpError(400, 'Invalid id'); return id; };
  const orgId = (c: Ctx) => c.get('org')!.organization_id;

  // ---- profissionais ----
  org.get('/professionals', guard('professional.read', { anyUnit: true }), async (c) =>
    c.json({ items: await c.get('repo').listCatalog('professionals', orgId(c)) }));
  org.post('/professionals', guard('professional.write'), async (c) => {
    const row = await c.get('repo').createCatalog('professionals', orgId(c), professionalCreate.parse(await readJson(c)));
    return c.json(row, 201);
  });
  org.patch('/professionals/:id', guard('professional.write'), async (c) => {
    const id = idParam(c);
    const row = await c.get('repo').updateCatalog('professionals', orgId(c), id, professionalPatch.parse(await readJson(c)));
    if (!row) throw new HttpError(404, 'Not found');
    return c.json(row);
  });
  org.post('/professionals/:id/units', guard('professional.write', { anyUnit: true }), async (c) => {
    const id = idParam(c);
    const { unit_id } = z.object({ unit_id: uuid }).strict().parse(await readJson(c));
    unitWrite(c, 'professional.write', unit_id);
    await c.get('repo').linkProfessionalUnit(orgId(c), id, unit_id);
    return c.json({ professional_id: id, unit_id }, 201);
  });

  // ---- salas e equipamentos (escopo por unidade) ----
  for (const [path, table, create, patch] of [['rooms', 'rooms', roomCreate, roomPatch], ['equipment', 'equipment', equipCreate, equipPatch]] as const) {
    org.get(`/${path}`, guard('resource.read', { anyUnit: true }), async (c) => {
      const unit = c.req.query('unit_id');
      if (unit && !uuid.safeParse(unit).success) throw new HttpError(400, 'Invalid unit_id');
      return c.json({ items: await c.get('repo').listCatalog(table, orgId(c), unit) });
    });
    org.post(`/${path}`, guard('resource.write', { anyUnit: true }), async (c) => {
      const input = create.parse(await readJson(c)) as { unit_id: string };
      unitWrite(c, 'resource.write', input.unit_id);
      const row = await c.get('repo').createCatalog(table, orgId(c), input);
      return c.json(row, 201);
    });
    org.patch(`/${path}/:id`, guard('resource.write', { anyUnit: true }), async (c) => {
      const id = idParam(c);
      const row = await c.get('repo').updateCatalog(table, orgId(c), id, patch.parse(await readJson(c)));
      if (!row) throw new HttpError(404, 'Not found');
      return c.json(row);
    });
  }

  // ---- serviços ----
  org.get('/services', guard('service.read', { anyUnit: true }), async (c) =>
    c.json({ items: await c.get('repo').listCatalog('services', orgId(c)) }));
  org.post('/services', guard('service.write'), async (c) => {
    const row = await c.get('repo').createCatalog('services', orgId(c), serviceCreate.parse(await readJson(c)));
    return c.json(row, 201);
  });
  org.patch('/services/:id', guard('service.write'), async (c) => {
    const id = idParam(c);
    const row = await c.get('repo').updateCatalog('services', orgId(c), id, servicePatch.parse(await readJson(c)));
    if (!row) throw new HttpError(404, 'Not found');
    return c.json(row);
  });
  org.post('/services/:id/requirements', guard('service.write'), async (c) => {
    const id = idParam(c);
    const { resource_type } = z.object({ resource_type: z.enum(['professional', 'room', 'equipment']) }).strict().parse(await readJson(c));
    await c.get('repo').addServiceRequirement(orgId(c), id, resource_type);
    return c.json({ service_id: id, resource_type }, 201);
  });

  // ---- pacientes (cadastro administrativo; CPF só como HMAC + máscara) ----
  // Defesa em profundidade: o hash do CPF nunca sai da API, mesmo que o repositório o devolva.
  const pub = (row: Record<string, unknown>) => { const { cpf_hash: _h, ...rest } = row; return rest; };
  const cpfKey = (c: Ctx) => {
    const k = c.env.CPF_HMAC_KEY;
    if (!k || k.length < 32) throw new HttpError(503, 'CPF protection key not configured');
    return k;
  };
  const cpfVersion = (c: Ctx) => {
    const v = Number(c.env.CPF_HMAC_KEY_VERSION ?? '1');
    if (!Number.isInteger(v) || v < 1 || v > 32767) throw new HttpError(503, 'CPF protection key version invalid');
    return v;
  };
  org.get('/patients', guard(['patient.read', 'clinical.read'], { anyUnit: true }), async (c) => {
    const q = patientQuery.parse(c.req.query());
    const cpfHash = q.cpf ? await hashCpf(cpfKey(c), orgId(c), q.cpf) : undefined;
    return c.json({ items: (await c.get('repo').listPatients(orgId(c), { q: q.q, cpfHash, birthDate: q.birth_date, limit: q.limit, offset: q.offset })).map(pub) });
  });
  org.post('/patients', guard('patient.write', { anyUnit: true }), async (c) => {
    const { cpf, confirm_possible_duplicate, ...rest } = patientCreate.parse(await readJson(c));
    const repo = c.get('repo');
    if (!confirm_possible_duplicate) {
      const dups = await repo.listPatients(orgId(c), { q: rest.full_name, birthDate: rest.birth_date, limit: 5, offset: 0 });
      if (dups.some((d) => String(d.full_name).toLowerCase() === rest.full_name.toLowerCase())) {
        throw new HttpError(409, 'Possible duplicate patient', 'same name and birth date exists; resend with confirm_possible_duplicate=true');
      }
    }
    const input: Record<string, unknown> = { ...rest };
    if (cpf) { input.cpf_hash = await hashCpf(cpfKey(c), orgId(c), cpf); input.cpf_masked = maskCpf(cpf); input.cpf_key_version = cpfVersion(c); }
    const row = await repo.createCatalog('patients', orgId(c), input);
    return c.json(pub(row), 201);
  });
  org.get('/patients/:id', guard(['patient.read', 'clinical.read'], { anyUnit: true }), async (c) => {
    const id = idParam(c);
    const row = await c.get('repo').getPatient(orgId(c), id);
    if (!row) throw new HttpError(404, 'Not found');
    await audit(c, { action: 'patient.read', resourceType: 'patient', resourceId: id, result: 'success' });
    return c.json(pub(row));
  });
  org.patch('/patients/:id', guard('patient.write', { anyUnit: true }), async (c) => {
    const id = idParam(c);
    const { cpf, ...rest } = patientPatch.parse(await readJson(c));
    const patch: Record<string, unknown> = { ...rest };
    if (cpf === null) { patch.cpf_hash = null; patch.cpf_masked = null; }
    else if (cpf) { patch.cpf_hash = await hashCpf(cpfKey(c), orgId(c), cpf); patch.cpf_masked = maskCpf(cpf); patch.cpf_key_version = cpfVersion(c); }
    const row = await c.get('repo').updateCatalog('patients', orgId(c), id, patch);
    if (!row) throw new HttpError(404, 'Not found');
    return c.json(pub(row));
  });
  org.get('/patients/:id/consents', guard('patient.read', { anyUnit: true }), async (c) =>
    c.json({ items: await c.get('repo').listConsents(orgId(c), idParam(c)) }));
  org.post('/patients/:id/consents', guard('patient.write', { anyUnit: true }), async (c) => {
    const id = idParam(c);
    const row = await c.get('repo').addConsent(orgId(c), id, consentBody.parse(await readJson(c)));
    return c.json(row, 201);
  });
  org.get('/patients/:id/guardians', guard('patient.read', { anyUnit: true }), async (c) =>
    c.json({ items: await c.get('repo').listGuardianships(orgId(c), idParam(c)) }));
  org.post('/patients/:id/guardians', guard('patient.write', { anyUnit: true }), async (c) => {
    const id = idParam(c);
    const b = guardianBody.parse(await readJson(c));
    const row = await c.get('repo').addGuardianship(orgId(c), { guardianId: b.guardian_patient_id, dependentId: id, relationship: b.relationship, validTo: b.valid_to ?? null });
    return c.json(row, 201);
  });
  org.post('/guardianships/:id/revoke', guard('patient.write', { anyUnit: true }), async (c) => {
    const id = idParam(c);
    if (!(await c.get('repo').revokeGuardianship(orgId(c), id))) throw new HttpError(404, 'Not found');
    return c.json({ id, revoked: true });
  });
  org.post('/patients/:id/account-link', guard('patient.write', { anyUnit: true }), async (c) => {
    const id = idParam(c);
    const b = linkBody.parse(await readJson(c));
    return idempotent(c, `patients.link:${id}`, b, async () => ({
      status: 201, body: { id: await c.get('repo').linkPatientAccount(orgId(c), id, b.user_id), patient_id: id } as unknown,
    }));
  });
  org.post('/account-links/:id/revoke', guard('patient.write', { anyUnit: true }), async (c) => {
    const id = idParam(c);
    await c.get('repo').revokePatientLink(orgId(c), id);
    return c.json({ id, revoked: true });
  });

  // ---- 1D: vínculo assistencial ----
  org.get('/care-relationships', guard('care.read', { anyUnit: true }), async (c) => {
    const q = careQuery.parse(c.req.query());
    return c.json({ items: await c.get('repo').listCareRelationships(orgId(c), { patientId: q.patient_id, professionalId: q.professional_id, limit: q.limit, offset: q.offset }) });
  });
  org.post('/patients/:id/care-relationships', guard('care.assign', { anyUnit: true }), async (c) => {
    const id = idParam(c);
    const b = careAssignBody.parse(await readJson(c));
    return idempotent(c, `care.assign:${id}`, b, async () => ({
      status: 201, body: { id: await c.get('repo').assignCare(orgId(c), id, b.professional_id, b.valid_to ?? null, b.reason), patient_id: id } as unknown,
    }));
  });
  org.post('/care-relationships/:id/revoke', guard('care.assign', { anyUnit: true }), async (c) => {
    const id = idParam(c);
    const b = careRevokeBody.parse(await readJson(c));
    await c.get('repo').revokeCare(orgId(c), id, b.reason);
    return c.json({ id, revoked: true });
  });

  // ---- 1D: prontuário (o banco valida vínculo/finalidade e registra o acesso; o Worker nunca loga conteúdo) ----
  org.get('/patients/:id/clinical-records', guard('clinical.read', { anyUnit: true }), async (c) => {
    const id = idParam(c); const q = clinicalListQuery.parse(c.req.query());
    return c.json({ items: await c.get('repo').listClinicalRecords(orgId(c), id, q.purpose, q.limit, q.offset) });
  });
  org.post('/patients/:id/clinical-records', guard('clinical.write', { anyUnit: true }), async (c) => {
    const id = idParam(c); const b = recordCreate.parse(await readJson(c));
    return idempotent(c, `clinical.create:${id}`, b, async () => ({
      status: 201, body: { id: await c.get('repo').createClinicalRecord(orgId(c), id, { kind: b.kind, title: b.title, body: b.body, eventId: b.event_id ?? null }), patient_id: id } as unknown,
    }));
  });
  org.get('/clinical-records/:id', guard('clinical.read', { anyUnit: true }), async (c) => {
    const id = idParam(c); const q = clinicalGetQuery.parse(c.req.query());
    return c.json(await c.get('repo').getClinicalRecord(orgId(c), id, q.purpose));
  });
  org.patch('/clinical-records/:id', guard('clinical.write', { anyUnit: true }), async (c) => {
    const id = idParam(c); const b = recordPatch.parse(await readJson(c));
    await c.get('repo').updateClinicalDraft(orgId(c), id, b.title, b.body);
    return c.json({ id, updated: true });
  });
  org.post('/clinical-records/:id/finalize', guard('clinical.write', { anyUnit: true }), async (c) => {
    const id = idParam(c);
    return idempotent(c, `clinical.finalize:${id}`, {}, async () => ({
      status: 200, body: { id, status: 'finalized', content_hash: await c.get('repo').finalizeClinicalRecord(orgId(c), id) } as unknown,
    }));
  });
  org.post('/clinical-records/:id/addenda', guard('clinical.write', { anyUnit: true }), async (c) => {
    const id = idParam(c); const b = addendumBody.parse(await readJson(c));
    return idempotent(c, `clinical.addendum:${id}`, b, async () => ({
      status: 201, body: { record_id: id, seq: await c.get('repo').addClinicalAddendum(orgId(c), id, b.reason, b.body) } as unknown,
    }));
  });
  org.post('/clinical-records/:id/verify', guard('clinical.audit', { anyUnit: true }), async (c) => {
    const id = idParam(c);
    return c.json({ id, intact: await c.get('repo').verifyClinicalRecord(orgId(c), id) });
  });

  // ---- 1D: acesso de emergência e log de acesso ----
  org.post('/patients/:id/emergency-access', guard('clinical.emergency', { anyUnit: true }), async (c) => {
    const id = idParam(c); const b = emergencyBody.parse(await readJson(c));
    return idempotent(c, `clinical.emergency:${id}`, b, async () => ({
      status: 201, body: { id: await c.get('repo').emergencyAccess(orgId(c), id, b.justification), patient_id: id, valid_for_minutes: 120 } as unknown,
    }));
  });
  org.get('/emergency-access', guard('clinical.audit', { anyUnit: true }), async (c) => {
    const q = grantsQuery.parse(c.req.query());
    return c.json({ items: await c.get('repo').listEmergencyGrants(orgId(c), { pendingOnly: q.pending === 'true', limit: q.limit }) });
  });
  org.post('/emergency-access/:id/review', guard('clinical.audit', { anyUnit: true }), async (c) => {
    const id = idParam(c); const b = reviewBody.parse(await readJson(c));
    await c.get('repo').reviewEmergencyAccess(orgId(c), id, b.outcome, b.note ?? null);
    return c.json({ id, reviewed: true, outcome: b.outcome });
  });
  org.get('/clinical-access-logs', guard('clinical.audit', { anyUnit: true }), async (c) => {
    const q = accessLogQuery.parse(c.req.query());
    return c.json({ items: await c.get('repo').listAccessLogs(orgId(c), { patientId: q.patient_id, before: q.before, limit: q.limit }) });
  });

  // ---- agenda ----
  org.get('/events', guard('agenda.read', { anyUnit: true }), async (c) => {
    const q = eventsQuery.parse(c.req.query());
    return c.json({ items: await c.get('repo').listEvents(orgId(c), { unitId: q.unit_id, from: q.from, to: q.to, limit: q.limit }) });
  });
  org.post('/events', guard('agenda.write', { anyUnit: true }), async (c) => {
    const b = bookBody.parse(await readJson(c));
    unitWrite(c, 'agenda.write', b.unit_id);
    return idempotent(c, 'events.book', b, async () => {
      const input = {
        unitId: b.unit_id, kind: b.kind, serviceId: b.service_id ?? null, startsAt: b.starts_at, endsAt: b.ends_at ?? null,
        resources: b.resources, title: b.title ?? null,
      };
      const ev = b.patient_id
        ? await c.get('repo').bookEventForPatient(orgId(c), b.patient_id, input)
        : await c.get('repo').bookEvent(orgId(c), input);
      return { status: 201, body: ev as unknown };
    });
  });
  org.post('/events/:id/cancel', guard('agenda.write', { anyUnit: true }), async (c) => {
    const id = idParam(c); const b = cancelBody.parse(await readJson(c));
    return idempotent(c, `events.cancel:${id}`, b, async () => {
      await c.get('repo').cancelEvent(orgId(c), id, b.reason);
      return { status: 200, body: { id, status: 'cancelled' } };
    });
  });
  org.post('/events/:id/check-in', guard('checkin.write', { anyUnit: true }), async (c) => {
    const id = idParam(c);
    return idempotent(c, `events.checkin:${id}`, {}, async () => ({
      status: 201, body: { id: await c.get('repo').checkIn(orgId(c), id), event_id: id } as unknown,
    }));
  });
  org.post('/events/:id/reschedule', guard('agenda.write', { anyUnit: true }), async (c) => {
    const id = idParam(c); const b = rescheduleBody.parse(await readJson(c));
    return idempotent(c, `events.reschedule:${id}`, b, async () => {
      const ev = await c.get('repo').rescheduleEvent(orgId(c), id, b.starts_at, b.ends_at ?? null);
      return { status: 201, body: ev as unknown };
    });
  });

  // ---- staff: disponibilidade e parâmetros do portal ----
  org.put('/professionals/:id/availability', guard('agenda.write', { anyUnit: true }), async (c) => {
    const id = idParam(c); const b = availabilityBody.parse(await readJson(c));
    const n = await c.get('repo').setAvailability(orgId(c), b.unit_id, id, b.windows);
    return c.json({ windows: n });
  });
  org.put('/portal-settings', guard('org.manage'), async (c) => {
    const b = portalSettingsBody.parse(await readJson(c));
    await c.get('repo').setPortalSettings(orgId(c), {
      minLeadHours: b.min_lead_hours, cancelMinHours: b.cancel_min_hours, horizonDays: b.horizon_days,
      maxActive: b.max_active_per_patient, maxReschedules: b.max_reschedules });
    return c.json({ ok: true });
  });

  app.route('/api/org', org);

  // ---- portal do paciente (usuário logado; o vínculo paciente↔conta é verificado no banco, nunca aqui) ----
  // Sem X-Organization-Id: o paciente não é membro da equipe. Nenhuma rota devolve dado clínico.
  const portal = new Hono<Env>();
  const pOrg = (c: Ctx) => { const v = c.req.param('org') ?? ''; if (!uuid.safeParse(v).success) throw new HttpError(400, 'Invalid id'); return v; };
  const pId = (c: Ctx, k: string) => { const v = c.req.param(k) ?? ''; if (!uuid.safeParse(v).success) throw new HttpError(400, 'Invalid id'); return v; };
  // Escritas: limite mais rígido por usuário e Turnstile (T10). Sem segredo configurado, o agendamento fica FECHADO
  // (fail-closed), exceto em APP_ENV=ci, que só roda contra Supabase local.
  const writeGate: MiddlewareHandler<Env> = async (c, next) => {
    const limiter = deps.makeRateLimiter?.(c.env);
    if (limiter) {
      let ok: boolean;
      try { ok = await limiter.hit(`portal:${c.get('userId')}`, 60, 10); }
      catch (e) { log('error', 'rate_limiter_failed', { requestId: c.get('requestId'), message: (e as Error).message }); throw new HttpError(503, 'Service unavailable'); }
      if (!ok) { c.header('Retry-After', '60'); throw new HttpError(429, 'Too many requests'); }
    }
    if (c.env.APP_ENV !== 'ci' || c.env.TURNSTILE_SECRET) {
      if (!c.env.TURNSTILE_SECRET || !deps.verifyTurnstile) {
        log('error', 'turnstile_not_configured', { requestId: c.get('requestId') });
        throw new HttpError(503, 'Online booking is temporarily unavailable');
      }
      const token = c.req.header('x-turnstile-token') ?? '';
      if (!token || token.length > 2048) throw new HttpError(403, 'Verification required');
      const pass = await deps.verifyTurnstile(c.env, token, c.req.header('cf-connecting-ip') ?? null);
      if (!pass) throw new HttpError(403, 'Verification failed');
    }
    await next();
  };

  portal.get('/context', async (c) => c.json({ items: await c.get('repo').portalContext() }));
  portal.get('/orgs/:org/catalog', async (c) => c.json({ items: await c.get('repo').portalCatalog(pOrg(c)) }));
  portal.get('/orgs/:org/slots', async (c) => {
    const q = portalSlotsQuery.parse(c.req.query());
    const items = await c.get('repo').portalSlots(pOrg(c), { unitId: q.unit_id, serviceId: q.service_id, professionalId: q.professional_id, from: q.from, to: q.to });
    return c.json({ items });
  });
  portal.get('/orgs/:org/patients/:patient/appointments', async (c) =>
    c.json({ items: await c.get('repo').portalAppointments(pOrg(c), pId(c, 'patient')) }));
  portal.post('/orgs/:org/patients/:patient/appointments', writeGate, async (c) => {
    const b = portalBookBody.parse(await readJson(c));
    const id = await c.get('repo').portalBook(pOrg(c), pId(c, 'patient'), {
      unitId: b.unit_id, serviceId: b.service_id, professionalId: b.professional_id, startsAt: b.starts_at });
    return c.json({ event_id: id }, 201);
  });
  portal.post('/orgs/:org/appointments/:id/cancel', async (c) => {
    const b = portalCancelBody.parse(await readJson(c));
    await c.get('repo').portalCancel(pOrg(c), pId(c, 'id'), b.reason ?? null);
    return c.json({ ok: true });
  });
  portal.post('/orgs/:org/appointments/:id/reschedule', writeGate, async (c) => {
    const b = portalRescheduleBody.parse(await readJson(c));
    const id = await c.get('repo').portalReschedule(pOrg(c), pId(c, 'id'), b.starts_at);
    return c.json({ event_id: id }, 201);
  });
  app.route('/api/portal', portal);

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
