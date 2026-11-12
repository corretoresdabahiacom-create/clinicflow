import { useCallback, useEffect, useMemo, useState } from 'react';
import { api, ApiError } from './api';
import { Turnstile, TURNSTILE_SITE_KEY } from './Turnstile';

type PPatient = { organization_id: string; organization_name: string; patient_id: string; patient_name: string; relation: 'self' | 'dependent' };
type CatRow = { unit_id: string; unit_name: string; service_id: string; service_name: string; duration_minutes: number; professional_id: string; professional_name: string; specialty: string | null };
type Appt = {
  event_id: string; status: string; starts_at: string; ends_at: string; unit_id: string; unit_name: string; service_id: string | null;
  service_name: string | null; professional_id: string | null; professional_name: string | null; can_cancel: boolean;
};
type Slot = { starts_at: string; ends_at: string };

const input = 'w-full rounded-lg border border-slate-300 px-3 py-2 text-base focus:outline-none focus:ring-2 focus:ring-teal-600';
const btn = 'rounded-lg bg-teal-700 px-4 py-2 font-medium text-white hover:bg-teal-800 disabled:opacity-50';
const btn2 = 'rounded-lg border border-slate-300 px-3 py-2 text-sm hover:bg-slate-50 disabled:opacity-50';
const fmt = new Intl.DateTimeFormat('pt-BR', { dateStyle: 'full', timeStyle: 'short' });
const fmtTime = new Intl.DateTimeFormat('pt-BR', { timeStyle: 'short' });
const STATUS: Record<string, string> = { scheduled: 'Agendado', cancelled: 'Cancelado' };
const today = () => new Date(Date.now() - new Date().getTimezoneOffset() * 60000).toISOString().slice(0, 10);

function explain(e: unknown): string {
  if (e instanceof ApiError) {
    if (e.status === 409) return 'Esse horário não está mais disponível, ou o prazo para alterar já passou, ou o limite de agendamentos foi atingido. Escolha outro horário.';
    if (e.status === 403) return 'Não foi possível confirmar a verificação de segurança. Tente novamente.';
    if (e.status === 429) return 'Muitas tentativas. Aguarde um minuto.';
    if (e.status === 503) return 'O agendamento online está indisponível no momento. Fale com a clínica.';
    if (e.status === 404) return 'Não encontrado.';
    if (e.status === 422) return 'Dados inválidos. Revise e tente de novo.';
  }
  return 'Não foi possível concluir agora. Tente novamente.';
}

export default function Portal() {
  const [people, setPeople] = useState<PPatient[] | null>(null);
  const [sel, setSel] = useState(0);
  const [tab, setTab] = useState<'list' | 'book'>('list');
  const [error, setError] = useState<string | null>(null);
  const me = people?.[sel];

  useEffect(() => {
    api<{ items: PPatient[] }>('/portal/context').then((r) => setPeople(r.items)).catch((e) => setError(explain(e)));
  }, []);

  if (people === null) return <p className="p-6 text-slate-600">{error ?? 'Carregando…'}</p>;
  if (people.length === 0) return <p className="p-6 text-slate-700">Sua conta ainda não está vinculada a um cadastro de paciente. Peça à clínica para confirmar o vínculo presencialmente.</p>;

  return (
    <section aria-label="Portal do paciente" className="mx-auto max-w-2xl p-4 sm:p-6">
      {people.length > 1 && (
        <label className="mb-4 block text-sm font-medium">Quem será atendido
          <select className={input} value={sel} onChange={(e) => setSel(Number(e.target.value))}>
            {people.map((p, i) => <option key={p.patient_id} value={i}>{p.patient_name}{p.relation === 'dependent' ? ' (dependente)' : ''} — {p.organization_name}</option>)}
          </select>
        </label>
      )}
      <p className="mb-3 text-sm text-slate-600">{me!.patient_name} · {me!.organization_name}</p>
      <div role="tablist" className="mb-4 flex gap-2">
        <button role="tab" aria-selected={tab === 'list'} className={tab === 'list' ? btn : btn2} onClick={() => setTab('list')}>Meus agendamentos</button>
        <button role="tab" aria-selected={tab === 'book'} className={tab === 'book' ? btn : btn2} onClick={() => setTab('book')}>Agendar</button>
      </div>
      {error && <p role="alert" className="mb-4 rounded-lg bg-red-50 p-3 text-sm text-red-800">{error}</p>}
      {tab === 'list'
        ? <Appointments key={me!.patient_id} me={me!} setError={setError} goBook={() => setTab('book')} />
        : <Book key={me!.patient_id} me={me!} setError={setError} done={() => setTab('list')} />}
    </section>
  );
}

function Appointments({ me, setError, goBook }: { me: PPatient; setError: (s: string | null) => void; goBook: () => void }) {
  const [items, setItems] = useState<Appt[] | null>(null);
  const [moving, setMoving] = useState<Appt | null>(null);
  const [busy, setBusy] = useState('');
  const base = `/portal/orgs/${me.organization_id}`;
  const load = useCallback(() => {
    api<{ items: Appt[] }>(`${base}/patients/${me.patient_id}/appointments`).then((r) => { setItems(r.items); setError(null); }).catch((e) => setError(explain(e)));
  }, [base, me.patient_id, setError]);
  useEffect(load, [load]);

  const cancel = async (a: Appt) => {
    if (!window.confirm('Cancelar este agendamento?')) return;
    setBusy(a.event_id);
    try { await api(`${base}/appointments/${a.event_id}/cancel`, { method: 'POST', body: {} }); load(); }
    catch (e) { setError(explain(e)); } finally { setBusy(''); }
  };

  if (items === null) return <p className="text-slate-600">Carregando…</p>;
  return (
    <>
      {items.length === 0 && <p className="mb-3 text-slate-600">Você não tem agendamentos. <button className="underline" onClick={goBook}>Agendar agora</button></p>}
      <ul className="divide-y rounded-lg border">
        {items.map((a) => (
          <li key={a.event_id} className="flex flex-col gap-2 p-3">
            <div className="flex flex-wrap items-baseline justify-between gap-2">
              <span className="font-medium first-letter:uppercase">{fmt.format(new Date(a.starts_at))}</span>
              <span className={`text-sm ${a.status === 'scheduled' ? 'text-teal-800' : 'text-slate-500'}`}>{STATUS[a.status] ?? a.status}</span>
            </div>
            <div className="text-sm text-slate-600">{a.service_name ?? 'Atendimento'} · {a.professional_name ?? 'Profissional'} · {a.unit_name}</div>
            {a.status === 'scheduled' && (a.can_cancel
              ? <div className="flex gap-2"><button className={btn2} disabled={busy === a.event_id} onClick={() => setMoving(moving?.event_id === a.event_id ? null : a)}>Remarcar</button>
                  <button className={btn2} disabled={busy === a.event_id} onClick={() => cancel(a)}>Cancelar</button></div>
              : <p className="text-xs text-slate-500">O prazo para alterar online passou. Fale com a clínica.</p>)}
            {moving?.event_id === a.event_id && a.unit_id && a.service_id && a.professional_id && (
              <SlotPicker org={me.organization_id} unitId={a.unit_id} serviceId={a.service_id} professionalId={a.professional_id} label="Confirmar nova data"
                onPick={async (startsAt, ts) => {
                  await api(`${base}/appointments/${a.event_id}/reschedule`, { method: 'POST', body: { starts_at: startsAt }, turnstileToken: ts });
                  setMoving(null); load();
                }} setError={setError} />
            )}
          </li>
        ))}
      </ul>
    </>
  );
}

function Book({ me, setError, done }: { me: PPatient; setError: (s: string | null) => void; done: () => void }) {
  const [cat, setCat] = useState<CatRow[] | null>(null);
  const [unit, setUnit] = useState(''); const [svc, setSvc] = useState(''); const [prof, setProf] = useState('');
  useEffect(() => {
    api<{ items: CatRow[] }>(`/portal/orgs/${me.organization_id}/catalog`).then((r) => setCat(r.items)).catch((e) => setError(explain(e)));
  }, [me.organization_id, setError]);
  const units = useMemo(() => [...new Map((cat ?? []).map((r) => [r.unit_id, r.unit_name])).entries()], [cat]);
  const svcs = useMemo(() => [...new Map((cat ?? []).filter((r) => r.unit_id === unit).map((r) => [r.service_id, `${r.service_name} (${r.duration_minutes} min)`])).entries()], [cat, unit]);
  const profs = useMemo(() => (cat ?? []).filter((r) => r.unit_id === unit && r.service_id === svc), [cat, unit, svc]);

  if (cat === null) return <p className="text-slate-600">Carregando…</p>;
  if (cat.length === 0) return <p className="text-slate-700">Nenhum serviço está liberado para agendamento online. Fale com a clínica.</p>;
  return (
    <div className="flex flex-col gap-3">
      <label className="text-sm font-medium">Unidade
        <select className={input} value={unit} onChange={(e) => { setUnit(e.target.value); setSvc(''); setProf(''); }}>
          <option value="">Selecione…</option>{units.map(([id, n]) => <option key={id} value={id}>{n}</option>)}
        </select></label>
      <label className="text-sm font-medium">Serviço
        <select className={input} value={svc} disabled={!unit} onChange={(e) => { setSvc(e.target.value); setProf(''); }}>
          <option value="">Selecione…</option>{svcs.map(([id, n]) => <option key={id} value={id}>{n}</option>)}
        </select></label>
      <label className="text-sm font-medium">Profissional
        <select className={input} value={prof} disabled={!svc} onChange={(e) => setProf(e.target.value)}>
          <option value="">Selecione…</option>{profs.map((p) => <option key={p.professional_id} value={p.professional_id}>{p.professional_name}{p.specialty ? ` — ${p.specialty}` : ''}</option>)}
        </select></label>
      {unit && svc && prof && (
        <SlotPicker org={me.organization_id} unitId={unit} serviceId={svc} professionalId={prof} label="Confirmar agendamento"
          onPick={async (startsAt, ts) => {
            await api(`/portal/orgs/${me.organization_id}/patients/${me.patient_id}/appointments`, {
              method: 'POST', body: { unit_id: unit, service_id: svc, professional_id: prof, starts_at: startsAt }, turnstileToken: ts });
            done();
          }} setError={setError} />
      )}
    </div>
  );
}

function SlotPicker(p: {
  org: string; unitId: string; serviceId: string; professionalId: string; label: string;
  onPick: (startsAt: string, turnstile: string) => Promise<void>; setError: (s: string | null) => void;
}) {
  const [date, setDate] = useState(''); const [slots, setSlots] = useState<Slot[] | null>(null);
  const [pick, setPick] = useState(''); const [token, setToken] = useState(''); const [rk, setRk] = useState(0); const [busy, setBusy] = useState(false);
  const setTok = useCallback((t: string) => setToken(t), []);
  useEffect(() => {
    setSlots(null); setPick('');
    if (!date) return;
    api<{ items: Slot[] }>(`/portal/orgs/${p.org}/slots?unit_id=${p.unitId}&service_id=${p.serviceId}&professional_id=${p.professionalId}&from=${date}&to=${date}`)
      .then((r) => { setSlots(r.items); p.setError(null); }).catch((e) => { p.setError(explain(e)); setSlots([]); });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [date, p.org, p.unitId, p.serviceId, p.professionalId]);

  const confirm = async () => {
    setBusy(true);
    try { await p.onPick(pick, token); }
    catch (e) { p.setError(explain(e)); setRk((n) => n + 1); }
    finally { setBusy(false); }
  };
  return (
    <div className="flex flex-col gap-2 rounded-lg bg-slate-50 p-3">
      <label className="text-sm font-medium">Data
        <input className={input} type="date" min={today()} value={date} onChange={(e) => setDate(e.target.value)} /></label>
      {date && slots !== null && slots.length === 0 && <p className="text-sm text-slate-600">Sem horários livres nesta data.</p>}
      <div className="flex flex-wrap gap-2" role="radiogroup" aria-label="Horários disponíveis">
        {(slots ?? []).map((s) => (
          <button key={s.starts_at} role="radio" aria-checked={pick === s.starts_at} className={pick === s.starts_at ? btn : btn2} onClick={() => setPick(s.starts_at)}>
            {fmtTime.format(new Date(s.starts_at))}
          </button>
        ))}
      </div>
      <Turnstile onToken={setTok} resetKey={rk} />
      {pick && <button className={btn} disabled={busy || (!!TURNSTILE_SITE_KEY && !token)} onClick={confirm}>{busy ? 'Enviando…' : p.label}</button>}
    </div>
  );
}
