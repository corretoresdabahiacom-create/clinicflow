# Relatório da Fase 1E — Portal do paciente e PWA (seção 29)

## 1. Objetivo
Portal para o **paciente logado** (ver, agendar, cancelar e remarcar os próprios agendamentos), PWA instalável sem dado sensível no cache, e proteção anti-abuso (Turnstile) — **somente dados sintéticos**. Decisões do usuário: agendamento só para paciente logado (sem agendamento anônimo); portal = meus agendamentos + cancelar/remarcar (sem cadastro nem prontuário); Turnstile "agora".

## 2. Implementado
- **Banco (migration 012)**: `portal_settings` (antecedência mínima 2 h, prazo de cancelar/remarcar 24 h, horizonte 60 dias, máx. 5 agendamentos ativos, máx. 2 remarcações; todos configuráveis), `services.online_booking` (padrão: **não liberado**), `professional_availability` (janelas semanais na hora local da unidade) e RPCs `rpc_portal_context/catalog/slots/appointments/book/cancel/reschedule` + `rpc_set_availability`, `rpc_set_portal_settings` (equipe).
- **Segurança**: o paciente **não lê nenhuma tabela** (agenda, alocações, auditoria, prontuário continuam fechados por RLS); só RPCs `security definer` que checam `patient_self_access` (titular ou responsável ativo) dentro da função. Sem vínculo, vínculo revogado ou outra organização → 404 (não revela existência). O paciente escolhe serviço/profissional/horário; **sala e equipamento são escolhidos pelo servidor**. Horário validado no servidor (serviço liberado, disponibilidade, antecedência, horizonte, alinhamento de 5 min). Remarcação atômica (libera o horário antigo e reserva o novo na mesma transação; se falha, nada muda). Agendar e remarcar são **naturalmente idempotentes** (repetir devolve o mesmo agendamento); trava por paciente (advisory lock) para o limite de ativos. Auditoria `portal.book/cancel/reschedule` com o usuário real.
- **API**: `/api/portal/*` (sem `X-Organization-Id`), `PUT /api/org/professionals/:id/availability`, `PUT /api/org/portal-settings`, `online_booking` em serviços. Escritas (agendar/remarcar): limite 10/min por usuário + **Turnstile verificado no servidor**. Sem `TURNSTILE_SECRET` o agendamento **fica fechado (503) em hml/prod** (fail-closed); só `APP_ENV=ci` (Supabase local) dispensa.
- **Web**: portal (lista, agendar por unidade→serviço→profissional→data→horário, remarcar, cancelar), alternância equipe/portal, widget Turnstile (só com `VITE_TURNSTILE_SITE_KEY`).
- **PWA**: manifest + ícones, service worker que guarda **apenas o casco estático**; nunca API, outra origem ou requisição autenticada; limpeza de cache ao sair; push **genérico** (payload ignorado); `public/_headers` com CSP e `no-store` na API (valem no deploy).

## 3. Não implementado / lacunas
- **Turnstile real não foi exercitado**: exige conta Cloudflare e chaves, que você havia adiado para o deploy. O código e os testes usam verificação injetável/fake; a chamada real à Cloudflare (`siteverify`) não foi testada. Até haver chaves, o agendamento online em hml/prod responde 503 (cancelar funciona).
- **Push**: só o tratador genérico no service worker. Não há inscrição, chaves VAPID nem envio; nenhuma notificação é enviada hoje.
- Horários exibidos no fuso do aparelho (não da unidade).
- Sem tela da equipe para disponibilidade/parâmetros (só API); sem fila de espera, e-mail/SMS de lembrete, nem cadastro de paciente pelo próprio.
- E2E do portal escrito, mas **só roda no CI** (o sandbox não tem o stack Supabase local); resultado abaixo.
- Teste de interface feito à mão com API simulada (captura de tela); não é teste automatizado.

## 4. Migrations
`20261112000012_portal`. **hml**: tem até a 010; **011 (1D) e 012 não aplicadas** (a aplicação da 011 havia ficado sem resposta; aguardo sua decisão). Correção incluída: a 012 não reabre `service_role` nas tabelas clínicas.

## 5. Testes (locais)
SQL: portal 61 verificações; as 6 suítes anteriores seguem verdes (43/14/21/10/31/17). Concorrência C10: 10 pacientes no mesmo horário → 1 vence, 9 conflitos; remarcações simultâneas ao mesmo horário → 1 vence e o perdedor mantém o original. API: 80 testes (15 novos). PWA: 7 testes executando o service worker em sandbox. Mutação: removi checagem de vínculo, antecedência mínima, cabeçalho de autorização no SW e payload genérico do push — todas detectadas (uma lacuna de teste da antecedência foi encontrada e corrigida).

## 6. Riscos
Sem Turnstile real, a defesa de abuso se resume ao limite por usuário (e login obrigatório). Rate limit depende de `SUPABASE_SERVICE_ROLE_KEY` configurada no Worker. Dados em texto simples (sintéticos). Production Gate 20/20 "Não iniciado". Custos: nenhum. Deploy: nenhum.

## 7. Recomendação
Decidir: aplicar 011 e 012 no hml; quando criar a conta Cloudflare (gratuita), configurar Turnstile; só então considerar a próxima fase.
