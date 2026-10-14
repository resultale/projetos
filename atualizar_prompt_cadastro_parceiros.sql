-- Atualiza a instrução principal da IA (apresentacao_1_instrucoes) para abrir o cadastro
-- de NEGÓCIO e PROFISSIONAL pelo WhatsApp. Rodar no SQL Editor do Supabase (projeto okctljhosqdtmtflamgi).
-- Já aplicado antes: apresentacao_5_parceiros (base de conhecimento) e todo o fluxo no banco.

begin;

-- 1) Troca "NÃO abra cadastro" por abertura de cadastro de negócio/profissional
update prompts set conteudo = replace(conteudo,
'Diga que o cadastro desses parceiros é feito pela equipe do Tio, que entrará em contato. NÃO abra cadastro (não use a marcação [abrir_cadastro]). Registre o interesse escrevendo no fim da mensagem a marcação [duvida:quero ser parceiro, e o tipo de negócio ou serviço da pessoa].',
'Conte que o cadastro é rápido e feito aqui mesmo pelo WhatsApp (negócio: cidade, seu nome, nome do negócio, ramo e endereço; profissional: cidade, seu nome, serviços que faz e onde atende) e que a equipe do Tio aprova em seguida e entra em contato para montar cardápio/produtos ou serviços. Não prometa taxas, comissão ou valores. Depois pergunte, em linha própria, se quer começar.')
where chave = 'apresentacao_1_instrucoes';

-- 2) Novas marcações e primeira pergunta de cada perfil
update prompts set conteudo = replace(conteudo,
'a marcação [abrir_cadastro:cliente] ou [abrir_cadastro:motorista]. A primeira pergunta é sempre a cidade: cliente → "Em qual cidade você está?"; motorista → "Em qual cidade você quer trabalhar?".',
'a marcação [abrir_cadastro:cliente], [abrir_cadastro:motorista], [abrir_cadastro:estabelecimento] (lanchonete, restaurante, brechó, loja, qualquer negócio) ou [abrir_cadastro:profissional] (barbeiro, manicure, eletricista etc.). A primeira pergunta é sempre a cidade: cliente → "Em qual cidade você está?"; motorista → "Em qual cidade você quer trabalhar?"; negócio → "Em qual cidade fica o seu negócio?"; profissional → "Em qual cidade você atende?".')
where chave = 'apresentacao_1_instrucoes';

-- Conferência: a deve ser true e b deve ser false
select chave,
       (conteudo like '%abrir_cadastro:profissional%') as a_tem_novas_marcacoes,
       (conteudo like '%NÃO abra cadastro%')           as b_ainda_proibe
from prompts where chave = 'apresentacao_1_instrucoes';

commit;

-- Para desfazer (volta ao comportamento anterior):
-- update prompts set conteudo = replace(replace(conteudo,
--   'Conte que o cadastro é rápido e feito aqui mesmo pelo WhatsApp (negócio: cidade, seu nome, nome do negócio, ramo e endereço; profissional: cidade, seu nome, serviços que faz e onde atende) e que a equipe do Tio aprova em seguida e entra em contato para montar cardápio/produtos ou serviços. Não prometa taxas, comissão ou valores. Depois pergunte, em linha própria, se quer começar.',
--   'Diga que o cadastro desses parceiros é feito pela equipe do Tio, que entrará em contato. NÃO abra cadastro (não use a marcação [abrir_cadastro]). Registre o interesse escrevendo no fim da mensagem a marcação [duvida:quero ser parceiro, e o tipo de negócio ou serviço da pessoa].'),
--   'a marcação [abrir_cadastro:cliente], [abrir_cadastro:motorista], [abrir_cadastro:estabelecimento] (lanchonete, restaurante, brechó, loja, qualquer negócio) ou [abrir_cadastro:profissional] (barbeiro, manicure, eletricista etc.). A primeira pergunta é sempre a cidade: cliente → "Em qual cidade você está?"; motorista → "Em qual cidade você quer trabalhar?"; negócio → "Em qual cidade fica o seu negócio?"; profissional → "Em qual cidade você atende?".',
--   'a marcação [abrir_cadastro:cliente] ou [abrir_cadastro:motorista]. A primeira pergunta é sempre a cidade: cliente → "Em qual cidade você está?"; motorista → "Em qual cidade você quer trabalhar?".')
-- where chave = 'apresentacao_1_instrucoes';
