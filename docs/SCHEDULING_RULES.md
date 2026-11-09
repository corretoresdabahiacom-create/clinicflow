# SCHEDULING_RULES

- Núcleo único: consultas, exames, bloqueios e manutenções passam por `scheduling_events` + `resource_allocations`.
- Recursos: profissional, sala, equipamento (capacidade, unidade, duração, preparo e limpeza). Serviço pode exigir vários recursos; reserva é tudo-ou-nada em uma transação.
- Concorrência: `tstzrange` `[início, fim)`, `EXCLUDE USING gist (organization_id =, resource_type =, resource_id =, period &&) WHERE status='active'`; conflito retorna 409 com alternativas; cancelamento muda status e libera o recurso.
- Idempotência obrigatória em agendar/remarcar/cancelar. Remarcação: criar nova alocação e só então cancelar a original, na mesma transação, preservando histórico.
- Regras: antecedência mínima/máxima, tolerância, encaixe, lista de espera, recorrência com exceções, feriados, férias, bloqueios, políticas de cancelamento/remarcação.
- Fuso: armazenar UTC, interpretar pelo fuso da unidade; testes em mudança de horário e fusos distintos.
- Disponibilidade pública calculada no servidor a partir de dados reais; nunca inventada.
