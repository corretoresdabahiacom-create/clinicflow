# INTEGRATIONS (todas **não funcionais**; nenhuma declarada pronta)

| Integração | Fase | Abordagem | Exige aprovação/custo |
|---|---|---|---|
| Supabase (Auth/DB/Storage) | 1A | Cliente com JWT do usuário | Projeto hml (free) |
| IA (provedor) | 3B | `AIProviderAdapter`, allowlist, minimização, DPA | Sim |
| WhatsApp Cloud API oficial (Meta) ou provedor autorizado | 3C | Adaptador, webhook assinado, templates, consentimento | Sim |
| E-mail/SMS | 2+ | Adaptador | Sim |
| Pagamentos/PIX/cartão | 4E | Somente após aprovação; hoje lançamentos manuais | Sim |
| TISS/TUSS | 2D/4E | Registros manuais primeiro; padrões vigentes a verificar | — |
| Assinatura eletrônica / receita eletrônica | 2B/4E | Não simular; validar requisitos legais | Provável |
| Laboratórios, telemedicina | 4E | Pesquisa futura | A definir |
| Antimalware de uploads | 1E/2A | ADR-008 | Possível |
Proibido: WhatsApp Web automatizado ou soluções não oficiais.
