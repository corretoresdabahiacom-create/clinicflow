import { useCallback, useEffect, useState, type FormEvent } from 'react';
import type { Session } from '@supabase/supabase-js';
import { api, supabase, type OrgContext, type Unit } from './api';

const input = 'w-full rounded-lg border border-slate-300 px-3 py-2 text-base focus:outline-none focus:ring-2 focus:ring-teal-600';
const btn = 'rounded-lg bg-teal-700 px-4 py-2 font-medium text-white hover:bg-teal-800 disabled:opacity-50';

function Login() {
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const submit = async (e: FormEvent) => {
    e.preventDefault();
    setBusy(true); setError(null);
    const { error } = await supabase.auth.signInWithPassword({ email, password });
    if (error) setError('E-mail ou senha inválidos.');
    setBusy(false);
  };
  return (
    <main className="mx-auto flex min-h-screen max-w-sm flex-col justify-center gap-4 p-6">
      <h1 className="text-2xl font-semibold text-slate-900">ClinicFlow</h1>
      <p className="text-sm text-slate-600">Ambiente de homologação. Somente dados sintéticos.</p>
      <form onSubmit={submit} className="flex flex-col gap-3">
        <label className="text-sm font-medium">E-mail
          <input className={input} type="email" autoComplete="username" required value={email} onChange={(e) => setEmail(e.target.value)} />
        </label>
        <label className="text-sm font-medium">Senha
          <input className={input} type="password" autoComplete="current-password" required value={password} onChange={(e) => setPassword(e.target.value)} />
        </label>
        {error && <p role="alert" className="text-sm text-red-700">{error}</p>}
        <button className={btn} disabled={busy}>{busy ? 'Entrando…' : 'Entrar'}</button>
      </form>
      <button disabled title="Em breve" className="text-sm text-slate-400">Criar conta (indisponível)</button>
    </main>
  );
}

function Workspace({ session }: { session: Session }) {
  const [orgs, setOrgs] = useState<OrgContext[] | null>(null);
  const [orgId, setOrgId] = useState<string>('');
  const [units, setUnits] = useState<Unit[]>([]);
  const [name, setName] = useState('');
  const [error, setError] = useState<string | null>(null);
  const org = orgs?.find((o) => o.organization_id === orgId);
  const canWrite = !!org?.permissions.includes('unit.write');

  useEffect(() => {
    api<{ organizations: OrgContext[] }>('/me')
      .then((r) => { setOrgs(r.organizations); setOrgId(r.organizations[0]?.organization_id ?? ''); })
      .catch((e: Error) => setError(e.message));
  }, []);

  const loadUnits = useCallback(async () => {
    if (!orgId) return;
    try { setUnits((await api<{ items: Unit[] }>('/org/units', { org: orgId })).items); setError(null); }
    catch (e) { setError((e as Error).message); setUnits([]); }
  }, [orgId]);
  useEffect(() => { void loadUnits(); }, [loadUnits]);

  const create = async (e: FormEvent) => {
    e.preventDefault();
    try {
      await api('/org/units', { method: 'POST', org: orgId, body: { name }, idempotencyKey: crypto.randomUUID() });
      setName(''); await loadUnits();
    } catch (err) { setError((err as Error).message); }
  };

  return (
    <main className="mx-auto max-w-3xl p-4 sm:p-6">
      <header className="mb-6 flex flex-wrap items-center justify-between gap-2">
        <h1 className="text-xl font-semibold">ClinicFlow</h1>
        <div className="flex items-center gap-3 text-sm">
          <span className="text-slate-600">{session.user.email}</span>
          <button className="underline" onClick={() => supabase.auth.signOut()}>Sair</button>
        </div>
      </header>
      {error && <p role="alert" className="mb-4 rounded-lg bg-red-50 p-3 text-sm text-red-800">{error}</p>}
      {orgs && orgs.length === 0 && <p className="text-slate-700">Você ainda não pertence a nenhuma organização. Peça a um administrador para vinculá-lo.</p>}
      {orgs && orgs.length > 0 && (
        <>
          <label className="mb-4 block text-sm font-medium">Organização
            <select className={input} value={orgId} onChange={(e) => setOrgId(e.target.value)}>
              {orgs.map((o) => <option key={o.organization_id} value={o.organization_id}>{o.organization_name}</option>)}
            </select>
          </label>
          <h2 className="mb-2 text-lg font-medium">Unidades</h2>
          <ul className="mb-4 divide-y rounded-lg border">
            {units.length === 0 && <li className="p-3 text-sm text-slate-500">Nenhuma unidade visível.</li>}
            {units.map((u) => <li key={u.id} className="flex justify-between p-3"><span>{u.name}</span><span className="text-sm text-slate-500">{u.status}</span></li>)}
          </ul>
          {canWrite
            ? <form onSubmit={create} className="flex gap-2"><input className={input} placeholder="Nome da nova unidade" required minLength={2} value={name} onChange={(e) => setName(e.target.value)} /><button className={btn}>Criar</button></form>
            : <p className="text-sm text-slate-500">Seu perfil não permite criar unidades.</p>}
        </>
      )}
    </main>
  );
}

export default function App() {
  const [session, setSession] = useState<Session | null | undefined>(undefined);
  useEffect(() => {
    supabase.auth.getSession().then(({ data }) => setSession(data.session));
    const { data } = supabase.auth.onAuthStateChange((_e, s) => setSession(s));
    return () => data.subscription.unsubscribe();
  }, []);
  if (session === undefined) return <p className="p-6 text-slate-600">Carregando…</p>;
  return session ? <Workspace session={session} /> : <Login />;
}
