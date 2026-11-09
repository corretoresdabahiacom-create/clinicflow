import { HttpError } from './errors';
import type { Repo } from './repo';

const KEY_RE = /^[A-Za-z0-9_-]{8,128}$/;

export function validateIdempotencyKey(key: string): void {
  if (!KEY_RE.test(key)) throw new HttpError(400, 'Invalid Idempotency-Key', 'Use 8-128 chars: A-Z a-z 0-9 _ -');
}

export async function sha256(text: string): Promise<string> {
  const buf = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text));
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

export type Exec = () => Promise<{ status: number; body: unknown }>;

export async function runIdempotent(
  repo: Repo,
  p: { orgId: string; userId: string; scope: string; key: string; hash: string },
  exec: Exec,
): Promise<{ status: number; body: unknown; replayed: boolean }> {
  const begin = await repo.idemBegin(p);

  const finish = async (id: string) => {
    try {
      const r = await exec();
      await repo.idemComplete(id, r.status, r.body);
      return { ...r, replayed: false };
    } catch (e) {
      await repo.idemFail(id).catch(() => undefined);
      throw e;
    }
  };

  if (begin.created) return finish(begin.id);
  const rec = begin.record;
  if (!rec) throw new HttpError(409, 'Idempotency key in use');
  if (rec.requestHash !== p.hash) {
    throw new HttpError(422, 'Idempotency key reused with a different payload');
  }
  if (rec.status === 'completed') {
    return { status: rec.responseStatus ?? 200, body: rec.responseBody, replayed: true };
  }
  if (rec.status === 'processing') throw new HttpError(409, 'Request with this key is still processing');
  if (!(await repo.idemRestart(rec.id))) throw new HttpError(409, 'Request with this key is still processing');
  return finish(rec.id);
}
