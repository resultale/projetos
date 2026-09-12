# Auditoria TIO — n8n + Supabase — 12/09/2026

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
