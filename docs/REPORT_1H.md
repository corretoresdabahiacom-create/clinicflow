# Relatório da Fase 1H — Endurecimento (seção 29)

## 1. Objetivo
Reduzir os riscos herdados das fases 1A–1C antes de qualquer dado clínico (1D): provar a integração real Worker↔Supabase, impedir perda de controle da organização, tornar a auditoria transacional e fechar lacunas de idempotência e de chave do CPF.

## 2. Implementado
- **Último proprietário**: triggers em `user_role_assignments` e `organization_members` impedem revogar, expirar, trocar de papel/escopo, suspender ou apagar o último proprietário efetivo (CF409 → HTTP 409). Serializado por `pg_advisory_xact_lock` por organização (duas revogações simultâneas não passam juntas). Vale também para service_role.
- **Auditoria transacional**: `app.audit_row()` grava em `audit_logs` na mesma transação da mutação, em 14 tabelas (organização, unidades, profissionais, vínculo profissional×unidade, salas, equipamentos, serviços, requisitos, pacientes, consentimentos, responsáveis, atribuições de papel, membros). Registra **somente nomes de colunas alteradas**, nunca valores; ator vem de `auth.uid()`; correlação, IP e user-agent chegam por cabeçalhos `x-correlation-id`, `x-client-ip`, `x-client-ua` repassados pelo Worker. Falha na auditoria aborta a mutação. O Worker passou a auditar só `denied` e `patient.read`.
- **Idempotência**: `locked_at`; chave presa em `processing` há mais de 2 min é reaberta (condicional e atômica); recém-criada não. `rpc_purge_idempotency` (somente service_role) apaga chaves vencidas em lote.
- **Chave do CPF**: `patients.cpf_key_version` (gravada a partir de `CPF_HMAC_KEY_VERSION`, padrão 1). Prepara a rotação; não a implementa.
- **E2E no CI**: job `e2e` sobe o Supabase local (CLI) e executa o Worker real via HTTP (6 cenários). `supabase/config.toml` adicionado; `APP_ENV=ci` aceito somente com SUPABASE_URL de loopback.
- Esclarecimento: o CI **já** rodava no GitHub desde a 1A (jobs verify e database); a pendência "CI nunca rodou" listada antes estava errada.

## 3. Não implementado
- Rotação de chave do CPF (exige busca com duas chaves e re-hash gradual quando o CPF for reapresentado: o sistema não guarda o CPF em claro). Só a coluna de versão existe.
- Agendamento da purga (nenhum cron ativo): chamar `rpc_purge_idempotency` por Worker agendado no deploy ou pg_cron.
- Armazenamento definitivo de `CPF_HMAC_KEY` (segredo do Worker, na fase de deploy).
- Auditoria transacional de **leitura** (`patient.read` continua no Worker, fora da transação) e de logins.
- Limitador de taxa segue inativo sem a chave de service_role. Nenhuma UI. Fluxos de organização/vínculo assistencial aguardam decisão do usuário.

## 4. Migrations
`20261111000009_hardening` (aplicada em hml e idêntica ao repositório).

## 5. RLS / permissões
Sem políticas novas. Funções novas sem EXECUTE para anon/authenticated (funções de trigger não precisam); `rpc_purge_idempotency` só service_role. Advisors de segurança: nenhum achado novo (permanecem os 9 avisos das RPCs intencionais e `rate_limits` sem política por desenho).

## 6. Testes
Ver `docs/TEST_PLAN.md` (Fase 1H): SQL 31 asserções, concorrência C8, API 51, E2E 6 (CI), smoke hml. Os testes novos foram validados por mutação (falham sem o recurso).

## 7. Riscos e lacunas honestas
- O E2E passou na primeira execução no CI; não fiz mutação nele (a mutação foi feita nas suítes SQL/concorrência).
- A chave de HMAC continua sem rotação operacional.
- User-agent é gravado percent-encoded (limitação de cabeçalho HTTP).
- A auditoria de `INSERT` por trigger usa `auth.uid()`; operações de service_role ficam com ator nulo.
- Vulnerabilidades: nenhuma nova conhecida. Custos: nenhum (CI gratuito; Supabase local no runner). Limites do plano gratuito: não confirmados.
- Deploy: nenhum (Cloudflare não iniciado). Production Gate: 20/20 "Não iniciado".

## 8. Recomendação
Aguardar decisões do usuário sobre provisionamento de organização e vínculo assistencial (pré-requisitos da 1D); em seguida, 1D.
