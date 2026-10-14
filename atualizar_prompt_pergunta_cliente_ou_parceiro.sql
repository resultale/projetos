-- Corrige a apresentação: a IA passa a perguntar "cliente ou parceiro (motorista, estabelecimento ou profissional)"
-- e não assume mais "motorista" quando a pessoa diz só "trabalhar" / "ser parceiro".
-- Rodar no SQL Editor do Supabase (projeto okctljhosqdtmtflamgi).

begin;

update prompts set conteudo = replace(replace(replace(conteudo,
'2) Descobrir se ela quer usar o Tio como CLIENTE ou trabalhar como MOTORISTA/ENTREGADOR parceiro.',
'2) Descobrir se ela quer usar o Tio como CLIENTE ou ser PARCEIRO do Tio. Parceiro tem 3 tipos: MOTORISTA/ENTREGADOR, ESTABELECIMENTO (lanchonete, restaurante, loja, brechó...) ou PROFISSIONAL (barbeiro, manicure, eletricista...). Nunca assuma o tipo.'),
'Termine perguntando, em linha própria, se a pessoa quer se cadastrar para usar o Tio como cliente ou para trabalhar com a gente como motorista/entregador parceiro.',
'Termine perguntando, em linha própria, se a pessoa quer usar o Tio como cliente ou ser parceiro do Tio, deixando claro que parceiro pode ser motorista/entregador, dono de estabelecimento ou profissional (barbeiro, manicure, eletricista...).'),
'Quem fala de "motoboy", "motorista" ou "entregador" pode tanto querer contratar quanto trabalhar.',
'Quem fala de "motoboy", "motorista" ou "entregador" pode tanto querer contratar quanto trabalhar. Quem diz só "trabalhar", "ser parceiro", "me cadastrar" ou "parceria" ainda NÃO disse o tipo: NÃO apresente o pacote de motorista; pergunte, em linha própria, se é para trabalhar como motorista/entregador, cadastrar um estabelecimento ou oferecer seus serviços como profissional.')
where chave = 'apresentacao_1_instrucoes';

-- Conferência: os três devem ser true
select (conteudo like '%Nunca assuma o tipo%')                       as a_missao,
       (conteudo like '%dono de estabelecimento ou profissional%')   as b_pergunta_inicial,
       (conteudo like '%NÃO apresente o pacote de motorista%')       as c_caso_ambiguo
from prompts where chave = 'apresentacao_1_instrucoes';

commit;
