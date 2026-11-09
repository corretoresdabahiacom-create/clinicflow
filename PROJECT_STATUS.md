# PROJECT_STATUS

Data: 2026-11-09 · Fase atual: **0 — Diagnóstico e Planejamento** · Modo operacional: **A (sintético)**

## Diagnóstico do ambiente
| Item | Resultado |
|---|---|
| Diretório de trabalho | `/home/claude`, vazio (sem projeto, sem git). **GREENFIELD.** |
| Frontend / backend / migrations / RLS / auth / PWA existentes | Inexistentes. Nada a preservar ou corrigir. |
| Repositório GitHub `corretoresdabahiacom-create/clinicflow` | **Não inspecionado**: o acesso (add_repo, push) foi negado pelo sistema de permissões. Conteúdo e estado desconhecidos. |
| Supabase | Acesso de leitura OK. Existe 1 projeto: "Mercado" (INACTIVE, us-west-2), **sem relação com o ClinicFlow; não será usado nem alterado**. Nenhum projeto ClinicFlow criado. |
| Cloudflare | Não inspecionado (sem conector/credenciais disponíveis nesta sessão). |
| Vulnerabilidades | Não aplicável (sem código). Riscos de projeto em `docs/THREAT_MODEL.md`. |

## Pronto
Documentação de planejamento (lista em `README.md`). **Nada foi implementado, testado, criado em nuvem ou publicado.**

## Pendente
- Revisão e aprovação deste plano pelo responsável.
- Decisões da seção "Decisões que exigem aprovação" abaixo.
- Publicação no GitHub (ver bloqueios).

## Bloqueado
- Push ao GitHub: acesso ao repositório não concedido nesta sessão.
- Criação do projeto Supabase de homologação e conta Cloudflare: exigem sua autorização e verificação de custos (ver `docs/COSTS.md`).

## Decisões que exigem aprovação expressa
1. ADR-001 a ADR-008 (`docs/ADR/`), especialmente: API em Workers + JWT do usuário repassado ao Supabase (ADR-003), Workers Static Assets vs Pages (ADR-002), rate limiting em Postgres vs KV (ADR-006), antimalware (ADR-008).
2. Criar projeto Supabase "clinicflow-hml" (free) em qual organização e região (recomendação: região São Paulo, se disponível, por latência e LGPD).
3. Conta Cloudflare a utilizar e domínio de homologação.
4. Forma de conceder acesso ao GitHub para publicar.
5. Aprovar o modelo de dados (`docs/ERD.md`) antes de qualquer migration.

## Gate de Produção
Todos os 20 requisitos: **Não iniciado** (`docs/PRODUCTION_GATE.md`). Sistema permanece no Modo A.

## Recomendação
Aprovar/ajustar a Fase 0 e liberar a **Fase 1A (Fundação)**.
