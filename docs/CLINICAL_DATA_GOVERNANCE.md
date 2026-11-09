# CLINICAL_DATA_GOVERNANCE

- Prontuário: rascunho → finalizado; finalizado é imutável; correções por adendo preservando original, autoria, sequência e data/hora.
- Registro de visualização, exportação, impressão e alteração em `data_access_logs`.
- Acesso por vínculo profissional + finalidade.
- Retenção: **prazos legais de guarda de prontuário e documentos não estão definidos neste documento** e devem ser confirmados com assessoria jurídica/CFM antes do Gate. Nenhum registro sujeito à guarda é excluído fisicamente antes do prazo.
- Legal hold: tabela `legal_holds` bloqueia descarte/anonimização.
- Direitos do titular: fluxo de análise com decisão registrada; eliminação/anonimização só do que não estiver sob guarda.
- Descarte de documentos clínicos: dupla aprovação, registro da justificativa.
- Marketing: consentimento separado da base do tratamento.
- Assinatura/validade jurídica: o sistema **não afirma** validade automática; sem assinatura digital simulada.
- Produção com dados reais só após Gate aprovado.
