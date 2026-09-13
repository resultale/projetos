# Auditoria TIO — n8n + Supabase — 12/09/2026 (+ 13/09/2026)

## 🆕 13/09/2026 (9) — Vocabulário "entrega" (não "frete") + valor mínimo de entrega padrão iFood

**Vocabulário:** nenhum estabelecimento fala a palavra "frete" — sempre "entrega". Renomeado o vocabulário do prompt/descrições de parâmetro do `Processar_Entrega_Completa` (n8n) de "frete" pra "entrega" (mantendo notas internas explicando que é o mesmo conceito, só pra reforçar ao Agent que a palavra "frete" nunca vai aparecer na mensagem real).

**Nova regra — valor mínimo de entrega (estilo iFood):**
- `processar_entrega_completa`: valor da entrega nunca fica abaixo de **R$9,00** (piso aplicado tanto no cálculo por distância quanto no valor informado por estabelecimento — não se aplica a tarifas customizadas de estabelecimento com contrato próprio, tabela_km/taxa_fixa/categoria).
- `aceitar_solicitacao`: pra entregas abaixo de R$9,00 (casos legados/exceção) a comissão do Tio fica limitada a **R$1,00 fixo** em vez do percentual normal — motorista nunca recebe menos que R$8,00 na prática, já que o piso de R$9 garante isso. Acima de R$9, comissão volta ao percentual normal.
- **Exceção**: quando tem cupom de desconto do Tio aplicado (`cupom_codigo_aplicado`), a comissão volta a ser sempre percentual — o piso de R$1 não vale, já que aí é uma promoção deliberada do Tio, não um preço baixo "de mercado".
- Rótulo da comissão no texto pro motorista ajustado pra mostrar "Comissão Tio (mínima)" em vez de uma % que não bateria com o valor fixo de R$1.
- Testado via SQL: valor informado R$5 → vira R$9 automaticamente; solicitação com R$8 (sem cupom, bypassando o piso pra testar isoladamente) → comissão R$1, motorista recebe R$7 (confirma a fórmula valor-1 que na prática nunca passa de R$1 de desconto do piso R$9 → R$8 líquido).

**Pendência em aberto:** ainda not confirmed com o Edvaldo se a regra "tiopay só quando já pago" (item anterior) também deveria ser revertida pro modelo "tiopay é sempre o padrão, só muda se ele informar explicitamente como paga a entrega" — perguntei e ele mudou de assunto pra essa regra do valor mínimo. Precisa voltar nesse ponto antes de considerar fechado.

## 🆕 13/09/2026 (7) — Correção de regra de negócio: tiopay não é fixo, depende da cobrança do pedido

O Edvaldo corrigiu a lógica implementada no item anterior: **`tiopay` não é o padrão sempre** — é só quando o pedido **já foi pago** (`decisao_cobranca_pedido='ja_pago'`). Quando o motorista **precisa cobrar o pedido** (`decisao_cobranca_pedido='cobrar'`), ele cobra o pedido **e o frete juntos**, na mesma hora, do destinatário — a forma de pagamento do frete nesse caso é a mesma do pedido (`forma_pagamento_pedido`), nunca tiopay.

**Corrigido:**
- `processar_entrega_completa`: `forma_pagamento` do frete agora deriva de `decisao_cobranca_pedido` — `cobrar` → acompanha `forma_pagamento_pedido` (dinheiro/pix/cartão); `ja_pago` (ou ainda não respondido) → `tiopay`.
- `aceitar_solicitacao`: "Total a cobrar do cliente na entrega" agora **sempre soma pedido + frete** quando `decisao_cobranca_pedido='cobrar'` (antes só somava se o frete por acaso fosse `dinheiro`, o que nunca acontecia com a regra errada anterior).
- Texto da ferramenta no n8n atualizado pra refletir a regra certa e reforçar que o Agent nunca deve perguntar forma de pagamento do frete separadamente — é 100% automático.

**Testado via SQL direto antes de publicar:** `cobrar` + `forma_pagamento_pedido='pix'` → frete sai `pix` corretamente; `ja_pago` → frete sai `tiopay`; aceite do motorista com pedido R$45 + frete R$8 (cobrar) → "Total a cobrar do cliente na entrega: R$53,00" (correto, soma os dois).

## 🆕 13/09/2026 (6) — Cenário "cobrar" completo, ponta a ponta (Galegos → Edvaldo)

**Bug corrigido antes do teste:** ao tornar `tiopay` o padrão do frete pra estabelecimento (item anterior), a seção "CONFIRMAÇÃO DO CLIENTE" do prompt só sabia tratar `pix` vs `dinheiro/cartão` — não tinha instrução pra `tiopay`, o que travaria a criação da solicitação. Corrigido: `tiopay` agora entra no mesmo grupo de dinheiro/cartão (cria a solicitação direto, sem gerar Pix).

**Achado sem correção (mais um caso de inconsistência do LLM):** na mensagem de teste, "dinheiro" foi mencionado só em relação ao valor do PEDIDO ("motorista vai precisar cobrar 45 reais em dinheiro do cliente") — mas o Agent também aplicou "dinheiro" no campo de pagamento do FRETE, que não tinha sido mencionado. Parece um "vazamento" do valor de um parâmetro pro outro parâmetro parecido. RPC teria dado `tiopay` corretamente se o parâmetro tivesse vindo vazio; segue como ponto de atenção pra observar em testes futuros.

**Teste completo (contas reais autorizadas: Galegos como estabelecimento, Edvaldo Leite como motorista, Edi Leite como destinatário/cliente final):** mensagem única "Tio, preciso de uma entrega... telefone do cliente é [Edi]... valor da entrega é 8 reais... motorista vai precisar cobrar 45 reais em dinheiro do cliente" → resumo correto com `📦 O motorista vai cobrar R$ 45,00 (dinheiro) do cliente na entrega`. Simulando o aceite do Edvaldo, a mensagem dele saiu:

> Valor da entrega: R$8,00 / Comissão Tio (20%): R$1,60 / Você recebe: R$6,40 (carteira TioPay) / 📦 Valor do produto a cobrar: R$45,00 (dinheiro) / 💰 Total a cobrar do cliente na entrega: R$45,00

Total ficou correto (só o produto — não somou o frete, porque o frete não é pago em dinheiro). Mensagem do cliente (Galegos) sem vazar comissão. Dados de teste removidos, estados de conversa dos três restaurados ao que eram antes.

## 🆕 13/09/2026 (5) — Testes com contas reais em Lençóis Paulista (Marcelo, Silvia, Diih) + bugs adicionais

**⚠️ Achado de processo:** o primeiro teste usou um número real e ativo (Marcelo, dono da barbearia "Confraria do Corte") — ele recebeu de verdade a mensagem de teste no WhatsApp e respondeu confuso. Número já estava cadastrado no banco mas em uso real, não era "de teste" só por estar lá. Estado de conversa dele restaurado exatamente como estava. Lição: mesmo pré-lançamento, checar se a conta tem uso ativo recente antes de disparar teste nela.

**Bug 1 - "FALTANDO" vazando pro parâmetro da ferramenta:** o bloco de contexto "Dados salvos" do prompt (`Agent_tio`, WF_ENTREGA) mostra `campo: FALTANDO` quando um dado ainda não foi coletado — só pra leitura do próprio Agent. Só que o modelo estava *copiando* literalmente essa palavra como valor real do parâmetro (`forma_pagamento: "FALTANDO"`) na chamada da ferramenta, corrompendo o dado (a RPC não trata como nulo). Um aviso textual sozinho não resolveu — o modelo continuou copiando. Resolvido substituindo o placeholder por texto que não pareceria um valor válido de parâmetro (`"(dado ainda nao informado)"`). Confirmado corrigido em reteste real.

**Bug 2 - parâmetros do n8n sem defaultValue viram "obrigatórios" pro LLM:** aproveitando a investigação do bug 1, os `$fromAI(...)` do node `Processar_Entrega_Completa` foram todos atualizados com descrição + `defaultValue` vazio, deixando-os genuinamente opcionais no schema que o n8n gera pro modelo (antes disso o modelo se sentia "obrigado" a preencher algo em todo parâmetro declarado).

**Bug 3 - Agent assumindo "dinheiro" no pagamento do frete sem o remetente ter dito isso** — corrigido em duas camadas: (a) prompt agora deixa claro que o padrão do frete de estabelecimento é sempre `tiopay` (acerto direto com o Tio) e o Agent nunca deve perguntar isso; (b) a RPC `processar_entrega_completa` passou a aplicar esse default sozinha (antes só clientes com `entrega_conta_pos_paga=true` tinham auto-tiopay; agora vale pra todo estabelecimento). Durante essa correção introduzi um bug novo (esqueci de incluir 'dinheiro' na lista de valores válidos do CASE, fazendo ele cair sempre em 'tiopay') — pego e corrigido no mesmo teste, confirmado via SQL direto.

**Achado sem correção aplicada (fica registrado para acompanhar):** em um teste real com o Diih, a ferramenta retornou `forma_pagamento:"dinheiro"` mesmo a chamada do Agent (visível no log de execução) não incluindo esse parâmetro. Testes isolados da RPC confirmam que ela funciona certo (default `tiopay` quando nulo) — o comportamento pontual parece uma inconsistência do próprio modelo LLM entre chamadas semelhantes, não um bug determinístico do sistema. Vale reobservar em testes futuros.

**Endereço da Silvia cadastrado:** `enderecos` — Rua Francisco Marins, 156, Lençóis Paulista (ela não tinha endereço salvo, o que estava gerando `campos_faltantes: origem` em todo teste).

Todos os `conversation_state` das contas reais usadas (Marcelo, Silvia, Diih) foram restaurados ao estado anterior aos testes.

## 🆕 13/09/2026 (4) — 2ª rodada do guardrail de roteamento + correção do pagamento do frete

**Guardrail incompleto:** o guardrail do item (3) abaixo só pegava a palavra "entrega/entregar" explícita. Testando a frase real do Edvaldo ("Manda uma moto pra [endereço], é uma pizza grande, telefone do cliente é X, o frete é 15 reais no pix...") — que não usa a palavra "entrega" nenhuma vez — o guardrail não disparou e caiu de novo no LLM, que classificou como DELIVERY por causa da "pizza". Ampliado pra também disparar com "frete" e "telefone do cliente/destinatário" (vocabulário exclusivo de entrega de estabelecimento). Retestado com a frase exata — roteou certo pro WF_ENTREGA.

**Correção de regra de negócio — pagamento do frete:** o prompt tratava pix/cartão do frete como se fossem "pro motorista igual dinheiro". Corrigido pra regra certa: **só dinheiro vai fisicamente pro motorista na hora**; pix/cartão/tiopay do frete são sempre acerto direto entre o estabelecimento e o Tio — o motorista nunca recebe nada em mãos por causa disso, só é creditado depois na carteira TioPay (igual comissão normal). O motorista só recebe algo fisicamente em duas situações: (a) frete pago em dinheiro, ou (b) `decisao_cobranca_pedido='cobrar'` (ele coleta o pedido inteiro do destinatário). Testado ponta a ponta com "frete no pix + já pago" — resumo saiu limpo, sem menção a motorista recebendo pix, e a mensagem do motorista (já validada antes) mostra corretamente só "já cai na carteira TioPay".

## 🆕 13/09/2026 (3) — Bug real de roteamento achado por teste FIEL (via n8n, não via RPC direta)

**Contexto importante:** todos os testes anteriores desse dia validaram as RPCs chamando-as diretamente por SQL — prova que o banco está certo, mas não prova que o classificador (LLM) do Maestro vai extrair/rotear certo a partir de uma mensagem real em linguagem natural. A pedido do Edvaldo, testamos de verdade: disparamos uma mensagem sintética pro webhook real (`n8n.chamaotio.com/webhook/tio_v2`, via `pg_net`, simulando um payload do Evolution API) com um número de teste marcado como `estabelecimento`, e inspecionamos a execução real do n8n.

**Bug encontrado:** mensagem "Preciso de uma entrega pra [endereço], é uma pizza grande, ..." foi classificada pelo LLM classificador (`Basic LLM Chain`, `tio_v3`) como `[tipo:DELIVERY]` em vez de `ENTREGA` — a palavra "pizza" bastou pra desviar o roteamento, mesmo a frase começando com "preciso de uma entrega" e o próprio prompt já tendo uma regra escrita dizendo que isso deveria virar ENTREGA. Resultado: a mensagem nunca chegava no `Agent_tio`/`Processar_Entrega_Completa` — ia pro fluxo de cardápio por engano.

**Correção:** adicionado guardrail determinístico (regex, sem LLM) em `tio_v3` — nodes `Detectar_Entrega_Estabelecimento_Deterministico` + `Eh_Entrega_Estabelecimento_Deterministico` + `Forcar_Tipo_Entrega_Estabelecimento_Deterministico` — que força `tipo:ENTREGA` sempre que a conta é `estabelecimento` E a mensagem menciona "entrega/entregar" explicitamente, sem depender do classificador acertar. Segue o mesmo padrão já usado pra corrida (`Detectar_Pedido_Transporte_Deterministico`).

**Reteste (mesma mensagem, mesmo cenário) confirmou o Agent real, não a RPC simulada, funcionando ponta a ponta:** roteou certo pro WF_ENTREGA, o `Agent_tio` extraiu sozinho TODOS os campos numa única chamada (origem via endereço salvo, destino, veículo, frete, `decisao_cobranca_pedido='cobrar'`, `valor_pedido=60`, `forma_pagamento_pedido='pix'`), RPC retornou `pronto_para_resumo:true`, e o resumo final saiu com a linha "📦 O motorista vai cobrar R$ 60,00 (pix) do cliente na entrega" certinha.

**Lição para próximos testes:** testar a RPC direto por SQL só valida o banco. Testar de verdade (disparar webhook real + inspecionar execução do n8n) é o que revela erros de classificação/roteamento do LLM, que é onde o comportamento do sistema é menos previsível.

## 🆕 13/09/2026 (2) — Entrega de ESTABELECIMENTO (WF_ENTREGA): defaults + cobrança na entrega

Motor **separado** do cardápio/delivery: é o `WF_ENTREGA`, usado tanto por cliente comum (entrega pessoa-a-pessoa, sem nada a cobrar do destinatário) quanto por conta **estabelecimento** (loja pedindo pra Tio entregar um pedido já vendido por ela a um cliente dela). Toda a lógica nova abaixo é **exclusiva de estabelecimento** (`v_eh_estabelecimento`/`eh_estabelecimento`) — entregas de cliente comum continuam exatamente como eram (origem+destino+veículo+forma de pagamento+tarifa por distância, sem nenhuma pergunta nova).

**Padronização pra reduzir fricção do estabelecimento** (`processar_entrega_completa`):
- **Veículo**: se o estabelecimento não especificar, assume `moto_entrega` automaticamente (não pergunta).
- **Valor do frete**: nunca mais oferece "calcular pela distância" pro estabelecimento — ele já vendeu o frete pro cliente dele, então tem que informar o valor direto (a não ser que já tenha tarifa própria pré-cadastrada, que já é usada automaticamente).
- **Nova decisão obrigatória — `decisao_cobranca_pedido`** (`'cobrar'` ou `'ja_pago'`): todo pedido de entrega de estabelecimento agora exige essa resposta explícita (nunca fica implícito/pulado). Se `'cobrar'`: exige também `valor_pedido` (valor do produto) e `forma_pagamento_pedido`. Se `'ja_pago'`: segue sem mais perguntas.
- Tudo testado ponta a ponta via SQL com conta de teste temporariamente marcada como estabelecimento (revertido depois).

**Mensagem do motorista/entregador ao aceitar** (`aceitar_solicitacao`) — quando é entrega de estabelecimento com `decisao_cobranca_pedido='cobrar'`, agora mostra separado:
- 💰 quanto ele **ganha** pela entrega (like já era, comissão descontada);
- 📦 quanto é o **produto** a cobrar do destinatário (`valor_pedido` + forma de pagamento combinada);
- 💰 o **total a cobrar do destinatário na entrega** (produto + valor da entrega, só soma o frete se a entrega em si também for paga em dinheiro na hora; se o frete já foi pago separado via Pix/cartão/TioPay, o total é só o produto).

Pra isso, o node `Criar_Solicitacao_Entrega` (n8n) passou a gravar `decisao_cobranca_pedido` dentro de `solicitacoes.dados_coletados` (antes só `valor_pedido`/`forma_pagamento_pedido` eram salvos — a decisão em si não estava sendo persistida, então o motorista nunca teria essa info). Testado via SQL com solicitação de entrega fictícia (`decisao_cobranca_pedido='cobrar'`, `valor_pedido=45`, frete `R$12` em dinheiro) → mensagem do motorista saiu: "📦 Valor do produto a cobrar: R$45.00 (dinheiro) / 💰 Total a cobrar do cliente na entrega: R$57.00". Dados de teste removidos depois.

## 🆕 13/09/2026 — Mini página de cardápio (delivery) + correções financeiras

### Feature nova: cardápio vira página, não texto corrido

Criado app público `resultale/delivery` (Next.js, deploy no EasyPanel em `delivery.chamaotio.com`) pra substituir o "Agent narra o cardápio em texto" por uma mini página estilo iFood, aberta dentro do próprio WhatsApp:

- **Banco**: tabela `cardapio_sessoes` (token único, expira em 60min, uso único) + RPCs `gerar_link_cardapio`/`gerar_link_busca_cardapio` (internas, só n8n), `cardapio_publico`/`salvar_carrinho_cardapio`/`escolher_item_busca` (públicas, `anon`).
- **Dois modos de página**:
  - **`modo: loja`** — cliente já escolheu a loja (ex: "quero pedir do Galegos Burguer") → mostra o cardápio completo daquela loja, monta carrinho, confirma.
  - **`modo: busca`** — cliente só disse o que quer comer (ex: "quero um x-bacon"), sem citar loja → mostra esse prato em **várias lojas diferentes** com preço de cada uma; toca pra ver descrição, "Pedir esse" já seleciona a loja e adiciona o item ao carrinho automaticamente.
- **n8n (`WF_DELIVERY`)**: novos nodes `Enviar_Link_Cardapio`, `Enviar_Link_Busca_Cardapio` e `Enviar_Botao_Cardapio` (mensagem interativa do Evolution API, botão "Faça seu pedido aqui" — link nunca aparece cru pro cliente). Prompt do `Agent_tio_delivery` reescrito: comida mencionada sem loja → busca cross-loja; loja nomeada direto → cardápio único.
- **Ao confirmar o carrinho na página**: `salvar_carrinho_cardapio` dispara via `pg_net` um webhook simulando uma mensagem do cliente pro Maestro (`tio_v2`) — o Agent já continua sozinho a conversa (pergunta endereço/pagamento) sem o cliente precisar digitar nada.
- **Identidade visual**: logo do Tio + cores da marca (azul `#0F1660` / dourado `#F6B90D`) aplicadas na página.

### Bugs achados e corrigidos durante os testes (todos confirmados end-to-end)
1. **Mensagens com link não chegavam no WhatsApp** — Evolution API tentava gerar preview do link e travava o envio (confirmado testando até com `google.com`). Corrigido com `linkPreview: false` no `sendText`. Isso valia pra **qualquer** link, não só o nosso — corrigido no node genérico `Enviar_WhatsApp` do `WF_DELIVERY`.
2. **Token do cardápio "expirado" mesmo válido** — ao encurtar o token de 65 pra 12 caracteres, sobrou uma validação antiga (`length(p_token) < 20`) em `_resolver_sessao_cardapio` que rejeitava todo token novo. Corrigido pra `< 10`.
3. **Falta de grant explícito pro PUBLIC** — `gerar_link_busca_cardapio` ficou acidentalmente executável por `anon` porque só tinha sido revogado de `anon`/`authenticated`, não do `PUBLIC` (Postgres dá `GRANT EXECUTE TO PUBLIC` por padrão em toda função nova — **isso é sistêmico, vale lembrar em qualquer função nova criada daqui pra frente**). Corrigido com `REVOKE ALL ... FROM PUBLIC`.
4. **`Criar_Pedido_Delivery` retornando erro "function does not exist"** (bug pré-existente, não relacionado ao cardápio) — o node passava `distancia_km`/`tempo_minutos` como `float8`, mas a função espera `numeric`. Corrigido o cast na query do node.

### Correções financeiras/copy pedidas pelo Edvaldo
- **Mensagem de corrida pro cliente** (`aceitar_solicitacao`) simplificada: antes mostrava "Valor da corrida: R$X / Você paga: R$Y (arredondado)" (parecia expor a base de cálculo do motorista). Agora mostra só o valor final e, se houver diferença de arredondamento, "Você ganhou R$Z de crédito automático na sua carteira TioPay!". Mensagem do motorista (com comissão) não mudou.
- **Delivery "produto+entrega" ou "só entrega" não é mais perguntado ao cliente** — virou config fixa por loja (`lojas.cobra_produto_e_entrega`, boolean, default `true` = cobra tudo junto). `montar_resumo_delivery` e `criar_pedido_delivery` agora leem isso da loja e ignoram esse parâmetro se vier do Agent. Prompt do `Agent_tio_delivery` não pergunta mais isso.

---


## ✅ WF_CORRIDA — testes de usabilidade + guardrail de endereço impreciso

Rodei cenários reais direto na RPC `processar_corrida_completa` (usando telefones de teste, sem disparar WhatsApp): rua numa msg + número em outra (OK, o prompt do extrator já junta), tudo junto numa msg (OK), tudo picado em vários turnos (OK, fechou com valor e troco calculados certos), dúvida no meio da coleta (OK, `cotar_preco_corrida` não mexe no estado salvo).

**Achado corrigido:** quando o endereço geocodificava com baixa confiança (`origem_confianca_baixa`/`destino_confianca_baixa`), o sistema já sinalizava a flag mas liberava `pronto_para_resumo=true` mesmo assim — dependia só do Agent (LLM) decidir perguntar antes de seguir, mesma categoria de risco do bug do PIX. Implementado guardrail determinístico:
- RPC `processar_corrida_completa` ganhou parâmetro `p_confirmar_endereco_impreciso` + persiste `origem_confianca_confirmada`/`destino_confianca_confirmada` no `conversation_state.contexto` — `pronto_para_resumo` agora fica bloqueado (`campos_faltantes` ganha `origem_confirmar`/`destino_confirmar`) até confirmação explícita.
- Node `Chamar_Processar_Corrida_Deterministico` (n8n) passa esse novo parâmetro automaticamente sempre que o cliente manda uma confirmação curta ("sim"/"ok"/"pode").
- Prompt do `Agent_tio` atualizado com a pergunta específica pros dois novos campos.
- Testado ponta a ponta via SQL: bloqueia sem confirmação, libera e recalcula certo depois do "sim".
- A regra de cidade (destino usa a mesma cidade detectada na origem, cliente não precisa repetir) já existia no código antes de hoje — confirmado lendo a função, sem necessidade de mudança.


Registro de tudo que foi feito na auditoria de hoje, pra retomar a conversa sobre o item pendente (revoke de RPCs) assim que possível.

## ✅ Revoke de RPCs — FECHADO, confirmado contra o app real

O app real é `github.com/resultale/tio-motorista-flutter` (Flutter/Dart) — não o `tio-motorista` (React Native) usado antes. Repo real clonado e conferido diretamente: `lib/core/services/supabase_service.dart` tem inclusive uma lista explícita `_rpcsComSessao` no próprio código, que é a fonte da verdade de quais RPCs usam `p_sessao_token`.

Cruzando **todas** as chamadas `.rpc(...)` reais do app (31 funções distintas) contra os grants atuais no banco: **100% cobertas** (`anon` e `authenticated` com `EXECUTE` liberado em todas). Restaurei 6 funções que tinham sido cortadas por engano no revoke original (baseado no repo errado), além das 2 já restauradas antes:

`app_detalhe_solicitacao`, `app_excluir_endereco`, `app_listar_enderecos`, `app_ofertas_pendentes_sistema`, `app_revogar_sessao`, `app_salvar_endereco` (+ `app_enviar_mensagem_suporte`, `app_historico_suporte`, restauradas antes).

Nenhuma das ~115 funções de negócio internas (`aceitar_solicitacao`, `criar_solicitacao`, `processar_pagamento_asaas`, etc.) é chamada pelo app real — seguem corretamente bloqueadas pra `anon`/`authenticated`, só acessíveis via n8n (conexão Postgres direta) e `service_role`.

**Item fechado, sem mais pendência.**

---

<details>
<summary>Histórico da investigação (repo errado usado inicialmente)</summary>

## ⚠️ Atualização sobre o revoke de RPCs — parcialmente reconferido

Revoguei o acesso de `anon`/`authenticated` (API pública/logada do Supabase) a ~115 funções de negócio (`aceitar_solicitacao`, `criar_solicitacao`, `processar_pagamento_asaas`, `solicitar_saque_motorista`, etc.), mantendo só as funções `app_*` e `dashboard_*` acessíveis.

**O que aconteceu:** eu mapeei a lista de funções "seguras" analisando o código do app do motorista no repo `resultale/tio-motorista`. Você avisou depois que **esse app não é o real usado em produção** (dashboard, na mesma pasta `dashboard/`, é o real).

**O que eu fiz pra reconferir sem depender do repo errado:** achei no histórico de migrations do Supabase uma migration de 30/08 chamada `infra_sessao_app_motorista` + `retrofit_sessao_funcoes_app_motorista` (1/2/3) — evidência de que existe uma trava de sessão (`p_sessao_token`) retrofitada especificamente nas funções realmente usadas pelo app em produção. Usei isso (direto no banco, não no repo) pra achar a lista definitiva: **22 funções `app_*`/`atualizar_localizacao` têm esse parâmetro `p_sessao_token`** — essas são confirmadas como reais.

Comparando com o que eu tinha preservado: **2 funções reais foram cortadas por engano** (`app_enviar_mensagem_suporte`, `app_historico_suporte` — têm `p_sessao_token` mas não apareciam no código do repo errado). **Já restaurei o acesso das 2** (`GRANT EXECUTE ... TO anon, authenticated`), confirmado no banco.

As outras funções que cortei e que só apareciam no repo errado (`app_aprovar_veiculo`, `app_excluir_endereco`, `app_listar_enderecos`, `app_salvar_endereco`, `app_ofertas_pendentes_sistema`, `app_revogar_sessao`, `app_status_tarifa_chuva`, `app_detalhe_solicitacao`, `verificar_otp_cadastro` sem `_v2`) **não têm** `p_sessao_token` — ou são de uso do dashboard (ex: `app_aprovar_veiculo` recebe `p_operador_telefone`, não telefone do motorista) ou são versões antigas pré-retrofit. Ficam cortadas, condizente com o nome da própria migration antiga (`travar_funcoes_nao_usadas_pelo_app`).

**Ainda assim, vale conferir com calma quando você abrir no PC** — essa checagem via `p_sessao_token` é uma evidência forte mas indireta; o ideal é confirmar contra o código do app real de verdade assim que tiver o repositório certo.

</details>

---

## O que foi corrigido hoje (n8n)

1. **`WF_TIMEOUT_PIX_ESTORNO`** — credencial Postgres quebrada (`Postgres account`, apontava pra localhost) corrigida para `Postgres_tio_v2`. Esse workflow falhava todo dia às 04:00 há vários dias; PIX em timeout não estava sendo estornado automaticamente.
2. **`WF_CORRIDA_COPY` → `WF_CORRIDA`** e **`WF_CORRIDA` (antigo) → `WF_CORRIDA_BACKUP`** — confirmado via `cfg_workflows` que o "COPY" é o que está de fato em produção.
3. **`WF_DELIVERY` duplicado** (`q12U0PQb4sDJ9y8w`) — desativado/arquivado (você mesmo desativou depois de eu avisar).
4. **Crons de "zumbis" duplicados** — `WF_EXPIRACAO_SOLICITACOES_ZUMBIS` (5min, sem notificação ao cliente) desativado. Mantido só `WF_EXPIRAR_SOLICITACOES_ZUMBIS` (15min, notifica o cliente).

## O que foi corrigido hoje (Supabase)

### Segurança
- RLS habilitado em 7 tabelas financeiras sem nenhuma proteção (`transacoes_financeiras`, `contatos_pix`, `custos_operacionais`, `metricas_financeiras_diarias`, `categorias_custo`, `tipos_calculo_tarifa`, `obras`).
- 4 views `SECURITY DEFINER` (`saldo_consolidado`, `motoristas_disponiveis`, `vw_suporte_ativo`, `vw_veiculos_pendentes_aprovacao`) convertidas para `SECURITY INVOKER` — elas tinham grant total pro `anon` e bypassavam RLS, expondo financeiro de todos os usuários e fotos de CNH/CRLV/selfie de motoristas pra qualquer um sem login.
- RLS + policies adicionadas em `financeiro` (estava sem nenhuma policy) pra sustentar a mudança acima.
- `search_path` fixado (`SET search_path = 'public'`) em ~117 funções de negócio (proteção contra schema hijacking).
- Todas as policies RLS permissivas duplicadas consolidadas em uma única policy por comando (~30 tabelas, incluindo `solicitacoes` e `conversation_state`) — sem mudar as regras de acesso, só reduzindo quantas vezes o Postgres avalia policy por query.
- **[pendente acima]** Revoke de `EXECUTE` de `anon`/`authenticated` em ~115 RPCs de negócio, mantendo só `app_*`/`dashboard_*`/helpers de RLS.

### Performance
- Índices criados (via `CONCURRENTLY`, sem travar produção) nas 3 FKs sem cobertura em `solicitacoes` (`loja_id`, `servico_id`, `solicitacao_entrega_id`).
- 26 índices mortos removidos (nunca usados, fora de `solicitacoes`), incluindo em `usuarios`, `veiculos`, `transacoes_financeiras`, `mensagens`, `operadores`, etc. Índices de chave primária/UNIQUE preservados.

### Ainda não mexido (menor prioridade / fora do escopo SQL)
- 3 extensions no schema `public` (`pg_net`, `http`, `unaccent`) — mover exige recriar e reapontar todas as referências, mais arriscado.
- "Leaked password protection" desligado no Auth — é toggle no painel do Supabase, não dá pra mudar por SQL.

---

## Lista completa das ~57 funções mantidas acessíveis (não foram tocadas)

`app_aceitar_oferta`, `app_atualizar_nome`, `app_avancar_etapa`, `app_cadastrar_chave_pix`, `app_cadastrar_veiculo`, `app_config_publica`, `app_consultar_ganhos`, `app_corridas_ativas`, `app_definir_disponibilidade`, `app_definir_tipos_servico`, `app_historico_movimentacoes`, `app_home_motorista`, `app_listar_veiculos`, `app_oferta_pendente`, `app_recusar_oferta`, `app_registrar_dispositivo_push`, `app_resumo_financeiro`, `app_solicitar_saque`, `app_status_acesso`, `app_tem_senha_saque`, `app_trocar_veiculo_ativo`, `atualizar_localizacao`, `calcular_dre_periodo`, `calcular_metricas_dia`, `dashboard_alternar_servico_cidade`, `dashboard_aprovar_veiculo`, `dashboard_atualizar_cidade`, `dashboard_atualizar_cupom`, `dashboard_atualizar_franquia`, `dashboard_atualizar_status_etapa_plano`, `dashboard_atualizar_tarifa`, `dashboard_buscar_usuarios`, `dashboard_comentar_etapa_plano`, `dashboard_conciliacao_comissoes`, `dashboard_config_sistema_get`, `dashboard_config_sistema_set`, `dashboard_criar_cidade`, `dashboard_criar_cupom`, `dashboard_criar_franquia`, `dashboard_criar_operador`, `dashboard_definir_forma_cobranca`, `dashboard_definir_tarifa_minimo_km_excedente`, `dashboard_executar_saque`, `dashboard_extrato_usuario`, `dashboard_lancamentos_financeiros`, `dashboard_resumo_financeiro`, `dashboard_upsert_tarifa`, `dashboard_upsert_taxa_fixa_por_corrida`, `dashboard_validar_entrega_retida`, `dashboard_visao_geral_hoje`, `dashboard_voltar_tarifa_simples`, `definir_senha_saque`, `gerar_otp_cadastro`, `obter_cidade_id_operador_logado`, `obter_cidades_cobertas_operador_logado`, `obter_franquia_id_operador_logado`, `obter_nivel_operador_logado`, `verificar_otp_cadastro_v2`.

**Atualizado:** essa lista foi 100% confirmada contra o app real (`tio-motorista-flutter`) — ver seção no topo do documento. Todas as 31 funções que o app chama estão liberadas para `anon`/`authenticated`.

## Projeto Supabase
`okctljhosqdtmtflamgi` (tioOficial) — **não** `dfgbrksuovievxxchcix` (tioMob, antigo/inativo).
