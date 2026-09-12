# Auditoria TIO — n8n + Supabase — 12/09/2026

Registro de tudo que foi feito na auditoria de hoje, pra retomar a conversa sobre o item pendente (revoke de RPCs) assim que possível.

## ⚠️ PENDÊNCIA CRÍTICA — precisa de confirmação sua

Revoguei o acesso de `anon`/`authenticated` (API pública/logada do Supabase) a ~115 funções de negócio (`aceitar_solicitacao`, `criar_solicitacao`, `processar_pagamento_asaas`, `solicitar_saque_motorista`, etc.), mantendo só as funções `app_*` e `dashboard_*` acessíveis.

**O problema:** eu mapeei a lista de funções "seguras" (que devem continuar acessíveis) analisando o código do app do motorista no repo `resultale/tio-motorista`. Você me avisou depois que **esse app não é o real usado em produção** — foi feito por outra pessoa e não emplacou. O dashboard (pasta `dashboard/` do mesmo repo) você confirmou que **é** o real.

**Risco:** se o app do motorista de verdade (que eu não vi) chama alguma função de negócio que não seja `app_*`/`dashboard_*`, o revoke pode ter quebrado alguma ação real de motorista (aceitar corrida, sacar, etc. — dependendo de como o app real chama o banco).

**Decisão combinada:** deixar como está por enquanto (não reverti nada), você confirma o repositório do app real quando puder e a gente reprocessa a lista seguindo o mesmo método (grep de `.rpc(...)` no código real) antes de decidir manter ou reverter.

**Se precisar reverter rápido antes disso**, o comando é: reconceder `EXECUTE` de volta a `PUBLIC` nas funções de negócio (a lista completa de funções tocadas está no final deste arquivo).

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

As `dashboard_*` e as 3 `obter_*_operador_logado` estão confirmadas certas (dashboard é o real). As `app_*` e as 4 soltas (`atualizar_localizacao`, `definir_senha_saque`, `gerar_otp_cadastro`, `verificar_otp_cadastro_v2`) vieram do app errado — **precisam ser reconferidas contra o app real**.

## Projeto Supabase
`okctljhosqdtmtflamgi` (tioOficial) — **não** `dfgbrksuovievxxchcix` (tioMob, antigo/inativo).
