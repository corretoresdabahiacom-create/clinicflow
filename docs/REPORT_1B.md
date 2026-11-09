# Relatório da Fase 1B — Profissionais, recursos e núcleo de agenda (seção 29)

Data: 2026-11-09 · Modo A (somente dados sintéticos)

## 1. Objetivo
Cadastros (profissionais, salas, equipamentos, serviços) e núcleo de agenda com bloqueio de conflito no banco; testes de concorrência.

## 2. Implementado
- 9 tabelas novas (justificativa em `docs/DATABASE.md`), RLS ENABLE+FORCE, grants mínimos; escrita de agenda somente por RPC.
- `EXCLUDE USING gist` impede dupla reserva de profissional/sala/equipamento; período inclui folgas do serviço; reserva tudo-ou-nada.
- Agendar, cancelar (libera recursos) e remarcar (atômico; conflito preserva o original). Bloqueios e manutenções usam o mesmo núcleo.
- Auditoria e histórico de status gravados na mesma transação (melhora o ponto "auditoria best-effort" da 1A para as operações de agenda).
- 8 permissões novas, papéis de sistema atualizados com backfill; provisionamento usa definição única.
- API: profissionais, salas, equipamentos, serviços, requisitos, eventos (listar/agendar/cancelar/remarcar); Idempotency-Key obrigatória nas operações de agenda; erros do banco traduzidos sem vazar detalhes (409/404/422/403).

## 3. Não implementado
Interface (UI) de cadastros e agenda; pacientes (1C; `patient_id` sem FK); recorrência, lista de espera, feriados/férias, regras de antecedência, alternativas de horário no 409, agenda "própria" do médico, capacidade >1 de sala, fuso/DST por unidade em regras de disponibilidade, DELETE/desvínculo de profissional-unidade, desativar recurso não cancela agendamentos futuros.

## 4. Migrations
004 tabelas · 005 permissões/RLS/RPCs · 006 revoke anon (corrigido após advisor). Aplicadas no hml; rollback em `docs/MIGRATION.md`.

## 5. Testes (reais)
| Suite | Ambiente | Resultado |
|---|---|---|
| scheduling_rules.sql | Postgres 16 local | TESTS_OK 21 |
| concurrency.sh (30 conexões; 4 execuções) | Postgres 16 local | CONCURRENCY_OK; controle negativo (sem EXCLUDE) falha: 30 reservas / 1326 sobreposições |
| smoke 1B | hml Supabase | TESTS_OK 9 |
| rls_isolation / repo_contract (regressão) | local e hml (1A) | 43 / 14 OK no local após as migrations 1B |
| API vitest | local | 35 passando (13 novos) |
| typecheck, build, secrets, audit | local | OK; 0 vulnerabilidades |

## 6. Segurança
Advisor Supabase: achado de EXECUTE anônimo nas novas RPCs corrigido (migration 6). Restam avisos esperados (RPCs SECURITY DEFINER executáveis por usuários autenticados, com autorização interna) e INFO de `rate_limits` sem policy (intencional). Cancelar/remarcar evento de outra organização responde "não encontrado" (sem confirmar existência).

## 7. Lacunas honestas
- Concorrência foi provada em Postgres 16 local; o hml (Supabase) recebeu só o smoke, não a carga concorrente. O Supabase real ainda não foi exercitado via HTTP/PostgREST (sandbox sem acesso), então `SupabaseRepo` (1A+1B) segue sem teste ponta a ponta.
- A suíte `scheduling_rules.sql` completa não foi executada no hml, apenas no local.
- O job `database` do CI (Postgres + suítes) foi escrito mas nunca rodou no GitHub.
- Folgas usam o mesmo conflito do recurso (uma consulta com folga bloqueia o vizinho).
- Fixtures de teste no hml ficaram em rollback (nenhum dado persistido).

## 8. Custos / Gate
R$ 0 (Supabase free). Sem Cloudflare. Gate de Produção: 20/20 "Não iniciado".

## 9. Recomendação
Aprovar a 1B. Antes de 1C (Pacientes), idealmente validar ponta a ponta em máquina com rede (Worker local → hml). **Aguardando autorização expressa para a Fase 1C.**
