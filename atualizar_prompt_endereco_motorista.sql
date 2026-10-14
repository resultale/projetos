-- A apresentação passa a avisar que o cadastro de motorista também pede endereço (confirmado no mapa).
-- Rodar no SQL Editor do Supabase (projeto okctljhosqdtmtflamgi).

begin;

update prompts set conteudo = replace(conteudo,
'explicando que é rápido (cidade, nome e dados do veículo: tipo, marca e modelo, ano, cor e placa)',
'explicando que é rápido (cidade, nome, endereço de residência confirmado no mapa e dados do veículo: tipo, marca e modelo, ano, cor e placa)')
where chave = 'apresentacao_1_instrucoes';

-- Conferência: deve ser true
select (conteudo like '%endereço de residência confirmado no mapa%') as ok
from prompts where chave = 'apresentacao_1_instrucoes';

commit;
