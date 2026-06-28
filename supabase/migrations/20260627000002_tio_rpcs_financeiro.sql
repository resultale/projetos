-- ============================================================
-- TIO - RPCs: Financeiro (TioPay, Comissões, Saques)
-- Migration: 20260627000002
-- Depende de: 000001 (onboarding RPCs)
-- ============================================================

-- ============================================================
-- rpc_creditar_tiopay
-- Adiciona saldo ao TioPay e registra movimentação
-- Retorna novo saldo
-- ============================================================
CREATE OR REPLACE FUNCTION rpc_creditar_tiopay(
  p_usuario_id    UUID,
  p_valor         DECIMAL,
  p_tipo          TEXT,    -- 'cashback','troco','bonus','recebimento','reembolso'
  p_referencia_id UUID    DEFAULT NULL,
  p_descricao     TEXT    DEFAULT NULL
)
RETURNS DECIMAL
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_anterior DECIMAL;
  v_posterior DECIMAL;
BEGIN
  IF p_valor <= 0 THEN
    RAISE EXCEPTION 'Valor de crédito deve ser positivo: %', p_valor;
  END IF;

  SELECT saldo INTO v_anterior FROM tiopay WHERE usuario_id = p_usuario_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'TioPay não encontrado para usuário %', p_usuario_id;
  END IF;

  v_posterior := v_anterior + p_valor;

  UPDATE tiopay
  SET saldo = v_posterior, atualizado_em = NOW()
  WHERE usuario_id = p_usuario_id;

  INSERT INTO movimentacao_tiopay (
    usuario_id, tipo, valor,
    saldo_anterior, saldo_posterior,
    referencia_id, referencia_tipo, descricao
  )
  VALUES (
    p_usuario_id, p_tipo, p_valor,
    v_anterior, v_posterior,
    p_referencia_id, 'solicitacao', p_descricao
  );

  RETURN v_posterior;
END;
$$;

-- ============================================================
-- rpc_debitar_tiopay
-- Subtrai saldo do TioPay (valida saldo disponível)
-- Retorna novo saldo
-- ============================================================
CREATE OR REPLACE FUNCTION rpc_debitar_tiopay(
  p_usuario_id    UUID,
  p_valor         DECIMAL,
  p_tipo          TEXT,    -- 'saque','pagamento'
  p_referencia_id UUID    DEFAULT NULL,
  p_descricao     TEXT    DEFAULT NULL
)
RETURNS DECIMAL
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_anterior  DECIMAL;
  v_posterior DECIMAL;
BEGIN
  IF p_valor <= 0 THEN
    RAISE EXCEPTION 'Valor de débito deve ser positivo: %', p_valor;
  END IF;

  SELECT saldo INTO v_anterior FROM tiopay WHERE usuario_id = p_usuario_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'TioPay não encontrado para usuário %', p_usuario_id;
  END IF;

  IF v_anterior < p_valor THEN
    RAISE EXCEPTION 'Saldo insuficiente. Disponível: R$ %, solicitado: R$ %',
      v_anterior, p_valor;
  END IF;

  v_posterior := v_anterior - p_valor;

  UPDATE tiopay
  SET saldo = v_posterior, atualizado_em = NOW()
  WHERE usuario_id = p_usuario_id;

  INSERT INTO movimentacao_tiopay (
    usuario_id, tipo, valor,
    saldo_anterior, saldo_posterior,
    referencia_id, descricao
  )
  VALUES (
    p_usuario_id, p_tipo, p_valor,
    v_anterior, v_posterior,
    p_referencia_id, p_descricao
  );

  RETURN v_posterior;
END;
$$;

-- ============================================================
-- rpc_distribuir_comissoes
-- Calcula e distribui valores após pagamento confirmado:
--   - Executor recebe (valor - taxa) em TioPay
--   - Matriz recebe 70% da taxa
--   - Franqueado recebe 30% da taxa
-- ============================================================
CREATE OR REPLACE FUNCTION rpc_distribuir_comissoes(
  p_solicitacao_id  UUID,
  p_valor_total     DECIMAL,
  p_executor_id     UUID,
  p_cliente_id      UUID,
  p_forma_pagamento TEXT,
  p_taxa_percentual DECIMAL DEFAULT 20.00
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_taxa         DECIMAL;
  v_val_executor DECIMAL;
  v_franq_id     UUID;
  v_pct_franq    DECIMAL := 30.00;
  v_val_franq    DECIMAL;
  v_cidade_id    UUID;
BEGIN
  v_taxa         := ROUND(p_valor_total * (p_taxa_percentual / 100), 2);
  v_val_executor := ROUND(p_valor_total - v_taxa, 2);

  -- Executor recebe via TioPay
  PERFORM rpc_creditar_tiopay(
    p_executor_id,
    v_val_executor,
    'recebimento',
    p_solicitacao_id,
    'Recebimento serviço'
  );

  -- Busca franqueado da cidade do executor
  SELECT u.franchise_id, u.cidade_id
  INTO v_franq_id, v_cidade_id
  FROM usuarios u
  WHERE u.id = p_executor_id;

  -- Repasse ao franqueado (30% da taxa) se existe
  IF v_franq_id IS NOT NULL THEN
    v_val_franq := ROUND(v_taxa * (v_pct_franq / 100), 2);
    PERFORM rpc_creditar_tiopay(
      v_franq_id,
      v_val_franq,
      'recebimento',
      p_solicitacao_id,
      'Comissão franqueado (' || v_pct_franq || '% da taxa)'
    );
  END IF;

  RETURN jsonb_build_object(
    'valor_total',     p_valor_total,
    'taxa',            v_taxa,
    'valor_executor',  v_val_executor,
    'valor_franqueado', COALESCE(v_val_franq, 0),
    'valor_matriz',    ROUND(v_taxa * 0.70, 2)
  );
END;
$$;

-- ============================================================
-- rpc_confirmar_pagamento_pix
-- Chamado pelo webhook do Asaas quando PIX é pago.
-- Atualiza a solicitação e dispara distribuição.
-- ============================================================
CREATE OR REPLACE FUNCTION rpc_confirmar_pagamento_pix(
  p_pix_id_asaas   TEXT,
  p_solicitacao_id UUID,
  p_valor          DECIMAL
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_sol solicitacoes%ROWTYPE;
  v_tar DECIMAL;
BEGIN
  SELECT * INTO v_sol FROM solicitacoes WHERE id = p_solicitacao_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Solicitação não encontrada: %', p_solicitacao_id;
  END IF;

  -- Idempotência: ignora se já foi processado
  IF v_sol.dados->>'pix_confirmado' = 'true' THEN
    RETURN jsonb_build_object('status', 'ja_processado');
  END IF;

  -- Marca PIX como confirmado no dados da solicitação
  UPDATE solicitacoes
  SET dados = dados || jsonb_build_object(
        'pix_confirmado', true,
        'pix_id_asaas', p_pix_id_asaas,
        'valor_pago', p_valor
      ),
      atualizado_em = NOW()
  WHERE id = p_solicitacao_id;

  -- Para motores de pagamento antecipado (corrida/entrega),
  -- a finalização do serviço acontece depois pela N8N.
  -- Aqui apenas sinalizamos pagamento confirmado.

  RETURN jsonb_build_object(
    'status',          'confirmado',
    'solicitacao_id',  p_solicitacao_id,
    'motor',           v_sol.motor,
    'tipo_servico',    v_sol.tipo_servico,
    'usuario_id',      v_sol.usuario_id,
    'valor',           p_valor
  );
END;
$$;

-- ============================================================
-- rpc_finalizar_servico
-- Finaliza a solicitação e distribui valores.
-- Chamado pela N8N quando serviço é concluído.
-- ============================================================
CREATE OR REPLACE FUNCTION rpc_finalizar_servico(
  p_solicitacao_id  UUID,
  p_valor_pago      DECIMAL,
  p_forma_pagamento TEXT   -- 'pix','dinheiro','cartao_maquina','tiopay'
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_sol        solicitacoes%ROWTYPE;
  v_taxa       DECIMAL;
  v_cb_pct     DECIMAL;
  v_reimb_pct  DECIMAL;
BEGIN
  SELECT * INTO v_sol FROM solicitacoes WHERE id = p_solicitacao_id;

  IF NOT FOUND OR v_sol.status = 'finalizada' THEN
    RETURN jsonb_build_object('status', 'ja_finalizado');
  END IF;

  IF v_sol.status NOT IN ('aberta', 'aceita', 'em_andamento') THEN
    RAISE EXCEPTION 'Status inválido para finalização: %', v_sol.status;
  END IF;

  -- Busca taxa percentual da tarifa configurada
  SELECT taxa_percentual INTO v_taxa
  FROM cfg_tarifas
  WHERE motor = v_sol.motor
    AND tipo_servico = v_sol.tipo_servico
    AND (cidade_id = v_sol.cidade_id OR cidade_id IS NULL)
    AND ativa = true
  ORDER BY cidade_id NULLS LAST
  LIMIT 1;

  v_taxa := COALESCE(v_taxa, 20.00);

  -- Marca como finalizada
  UPDATE solicitacoes
  SET status        = 'finalizada',
      finalizada_em = NOW(),
      atualizado_em = NOW()
  WHERE id = p_solicitacao_id;

  -- Distribui comissões para o executor
  PERFORM rpc_distribuir_comissoes(
    p_solicitacao_id  := p_solicitacao_id,
    p_valor_total     := p_valor_pago,
    p_executor_id     := v_sol.aceita_por_usuario_id,
    p_cliente_id      := v_sol.usuario_id,
    p_forma_pagamento := p_forma_pagamento,
    p_taxa_percentual := v_taxa
  );

  -- Reembolso extra ao entregador em pagamentos físicos
  IF p_forma_pagamento IN ('dinheiro', 'cartao_maquina')
     AND v_sol.tipo_servico IN ('entrega', 'corrida_moto', 'corrida_carro')
  THEN
    SELECT percentual_reembolso INTO v_reimb_pct
    FROM cfg_reembolso_devolucao
    WHERE tipo_pagamento = p_forma_pagamento
      AND (cidade_id = v_sol.cidade_id OR cidade_id IS NULL)
      AND ativa = true
    ORDER BY cidade_id NULLS LAST
    LIMIT 1;

    IF v_reimb_pct IS NOT NULL AND v_reimb_pct > 0 THEN
      PERFORM rpc_creditar_tiopay(
        v_sol.aceita_por_usuario_id,
        ROUND(p_valor_pago * (v_reimb_pct / 100), 2),
        'reembolso',
        p_solicitacao_id,
        'Reembolso devolução ' || p_forma_pagamento || ' (' || v_reimb_pct || '%)'
      );
    END IF;
  END IF;

  -- Cashback para cliente em pagamento PIX
  IF p_forma_pagamento = 'pix' THEN
    SELECT percentual_cashback INTO v_cb_pct
    FROM cfg_cashback
    WHERE tipo_usuario   = 'cliente'
      AND forma_pagamento = 'pix'
      AND (cidade_id = v_sol.cidade_id OR cidade_id IS NULL)
      AND ativa = true
    ORDER BY cidade_id NULLS LAST
    LIMIT 1;

    IF v_cb_pct IS NOT NULL AND v_cb_pct > 0 THEN
      PERFORM rpc_creditar_tiopay(
        v_sol.usuario_id,
        ROUND(p_valor_pago * (v_cb_pct / 100), 2),
        'cashback',
        p_solicitacao_id,
        'Cashback PIX ' || v_cb_pct || '%'
      );
    END IF;
  END IF;

  UPDATE cfg_cidades
  SET total_transacoes = total_transacoes + 1
  WHERE id = v_sol.cidade_id;

  RETURN jsonb_build_object(
    'status',         'finalizado',
    'solicitacao_id', p_solicitacao_id
  );
END;
$$;

-- ============================================================
-- rpc_processar_troco_digital
-- Quando cliente paga em dinheiro/cartão e dá valor maior,
-- o troco entra no TioPay dele em vez de dinheiro físico
-- ============================================================
CREATE OR REPLACE FUNCTION rpc_processar_troco_digital(
  p_usuario_id    UUID,
  p_valor_pago    DECIMAL,
  p_valor_total   DECIMAL,
  p_referencia_id UUID DEFAULT NULL
)
RETURNS DECIMAL
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_troco DECIMAL;
BEGIN
  v_troco := ROUND(p_valor_pago - p_valor_total, 2);

  IF v_troco <= 0 THEN
    RETURN 0;
  END IF;

  PERFORM rpc_creditar_tiopay(
    p_usuario_id,
    v_troco,
    'troco',
    p_referencia_id,
    'Troco digital (pago R$' || p_valor_pago || ', total R$' || p_valor_total || ')'
  );

  RETURN v_troco;
END;
$$;

-- ============================================================
-- rpc_solicitar_saque
-- Saque sob demanda (usuário iniciou): valida senha, saldo e
-- chave PIX antes de enfileirar o saque
-- ============================================================
CREATE OR REPLACE FUNCTION rpc_solicitar_saque(
  p_usuario_id UUID,
  p_valor      DECIMAL,
  p_senha      TEXT
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_tp   tiopay%ROWTYPE;
  v_sid  UUID;
BEGIN
  -- Valida senha
  IF NOT rpc_validar_senha(p_usuario_id, p_senha) THEN
    RETURN jsonb_build_object('sucesso', false, 'erro', 'Senha incorreta');
  END IF;

  SELECT * INTO v_tp FROM tiopay WHERE usuario_id = p_usuario_id FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('sucesso', false, 'erro', 'TioPay não encontrado');
  END IF;

  IF v_tp.saldo < p_valor THEN
    RETURN jsonb_build_object(
      'sucesso', false,
      'erro', 'Saldo insuficiente. Disponível: R$ ' || v_tp.saldo
    );
  END IF;

  IF p_valor < v_tp.saque_minimo THEN
    RETURN jsonb_build_object(
      'sucesso', false,
      'erro', 'Valor mínimo para saque: R$ ' || v_tp.saque_minimo
    );
  END IF;

  IF v_tp.chave_pix IS NULL THEN
    RETURN jsonb_build_object('sucesso', false, 'erro', 'Chave PIX não cadastrada');
  END IF;

  -- Anti-spam: bloqueia 2h entre saques sob demanda
  IF v_tp.ultimo_saque IS NOT NULL AND
     v_tp.ultimo_saque > NOW() - INTERVAL '2 hours' THEN
    RETURN jsonb_build_object(
      'sucesso', false,
      'erro', 'Aguarde 2h entre saques. Último: ' || v_tp.ultimo_saque
    );
  END IF;

  -- Debita o saldo e registra saque pendente
  PERFORM rpc_debitar_tiopay(
    p_usuario_id, p_valor, 'saque', NULL,
    'Saque sob demanda'
  );

  INSERT INTO saques_tiopay (
    usuario_id, valor, chave_pix, tipo_chave_pix, tipo, status
  )
  VALUES (
    p_usuario_id, p_valor, v_tp.chave_pix, v_tp.tipo_chave_pix,
    'sob_demanda', 'pendente'
  )
  RETURNING id INTO v_sid;

  UPDATE tiopay SET ultimo_saque = NOW() WHERE usuario_id = p_usuario_id;

  -- A Edge Function / cron job pega status='pendente' e chama Asaas
  RETURN jsonb_build_object(
    'sucesso',   true,
    'saque_id',  v_sid,
    'valor',     p_valor,
    'chave_pix', v_tp.chave_pix
  );
END;
$$;

-- ============================================================
-- rpc_verificar_elegibilidade_promocao
-- Valida se cliente pode usar a promoção e retorna valor com
-- e sem desconto para o estabelecimento tomar decisão
-- ============================================================
CREATE OR REPLACE FUNCTION rpc_verificar_elegibilidade_promocao(
  p_cliente_id  UUID,
  p_promocao_id UUID,
  p_valor       DECIMAL
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_promo       promocoes%ROWTYPE;
  v_elig        elegibilidade_promocao%ROWTYPE;
  v_desconto    DECIMAL := 0;
  v_valor_final DECIMAL;
BEGIN
  SELECT * INTO v_promo FROM promocoes WHERE id = p_promocao_id;

  IF NOT FOUND OR NOT v_promo.ativa THEN
    RETURN jsonb_build_object('elegivel', false, 'motivo', 'Promoção inativa ou inexistente');
  END IF;

  IF v_promo.valida_ate IS NOT NULL AND v_promo.valida_ate < NOW() THEN
    RETURN jsonb_build_object('elegivel', false, 'motivo', 'Promoção expirada');
  END IF;

  IF v_promo.limite_uso_total IS NOT NULL AND
     v_promo.total_usado >= v_promo.limite_uso_total THEN
    RETURN jsonb_build_object('elegivel', false, 'motivo', 'Limite total atingido');
  END IF;

  IF p_valor < v_promo.minimo_compra THEN
    RETURN jsonb_build_object(
      'elegivel', false,
      'motivo', 'Valor mínimo: R$ ' || v_promo.minimo_compra
    );
  END IF;

  SELECT * INTO v_elig
  FROM elegibilidade_promocao
  WHERE promocao_id = p_promocao_id AND cliente_id = p_cliente_id;

  IF FOUND THEN
    IF NOT v_elig.elegivel THEN
      RETURN jsonb_build_object('elegivel', false, 'motivo', v_elig.motivo_bloqueio);
    END IF;

    IF v_elig.bloqueado_ate IS NOT NULL AND v_elig.bloqueado_ate > NOW() THEN
      RETURN jsonb_build_object(
        'elegivel', false,
        'motivo', 'Bloqueado até ' || v_elig.bloqueado_ate
      );
    END IF;

    IF v_promo.limite_uso_por_cliente IS NOT NULL AND
       v_elig.total_compras >= v_promo.limite_uso_por_cliente THEN
      RETURN jsonb_build_object('elegivel', false, 'motivo', 'Limite de uso por cliente atingido');
    END IF;
  END IF;

  -- Calcula desconto
  IF v_promo.desconto_percentual IS NOT NULL THEN
    v_desconto := ROUND(p_valor * (v_promo.desconto_percentual / 100), 2);
    IF v_promo.maximo_desconto IS NOT NULL THEN
      v_desconto := LEAST(v_desconto, v_promo.maximo_desconto);
    END IF;
  ELSIF v_promo.desconto_valor IS NOT NULL THEN
    v_desconto := LEAST(v_promo.desconto_valor, p_valor);
  END IF;

  v_valor_final := ROUND(p_valor - v_desconto, 2);

  RETURN jsonb_build_object(
    'elegivel',          true,
    'valor_original',    p_valor,
    'desconto',          v_desconto,
    'valor_final',       v_valor_final,
    'desconto_pct',      v_promo.desconto_percentual,
    'nome_promocao',     v_promo.nome
  );
END;
$$;

-- ============================================================
-- rpc_registrar_uso_promocao
-- Atualiza contador de uso após transação paga
-- ============================================================
CREATE OR REPLACE FUNCTION rpc_registrar_uso_promocao(
  p_promocao_id UUID,
  p_cliente_id  UUID,
  p_valor       DECIMAL
)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  UPDATE promocoes
  SET total_usado = total_usado + 1
  WHERE id = p_promocao_id;

  INSERT INTO elegibilidade_promocao (
    promocao_id, cliente_id,
    data_primeiro_acesso, data_ultimo_acesso,
    total_compras, total_gasto
  )
  VALUES (
    p_promocao_id, p_cliente_id,
    NOW(), NOW(), 1, p_valor
  )
  ON CONFLICT (promocao_id, cliente_id) DO UPDATE
    SET data_ultimo_acesso = NOW(),
        total_compras      = elegibilidade_promocao.total_compras + 1,
        total_gasto        = elegibilidade_promocao.total_gasto + p_valor,
        atualizado_em      = NOW();
END;
$$;

-- ============================================================
-- rpc_avaliar_usuario
-- Registra avaliação e atualiza média no campo perfis do avaliado
-- ============================================================
CREATE OR REPLACE FUNCTION rpc_avaliar_usuario(
  p_avaliador_id   UUID,
  p_avaliado_id    UUID,
  p_solicitacao_id UUID,
  p_nota           INT,
  p_comentario     TEXT DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_total_aval   INT;
  v_media_nova   DECIMAL;
  v_perfil_tipo  TEXT;
BEGIN
  IF p_nota < 1 OR p_nota > 5 THEN
    RAISE EXCEPTION 'Nota inválida: %. Deve ser entre 1 e 5.', p_nota;
  END IF;

  INSERT INTO avaliacoes (
    avaliador_id, avaliado_id, solicitacao_id, nota, comentario
  )
  VALUES (p_avaliador_id, p_avaliado_id, p_solicitacao_id, p_nota, p_comentario);

  -- Recalcula média e atualiza no JSONB de perfis
  SELECT
    COUNT(*),
    ROUND(AVG(nota)::DECIMAL, 1)
  INTO v_total_aval, v_media_nova
  FROM avaliacoes
  WHERE avaliado_id = p_avaliado_id;

  -- Atualiza o perfil_atual do usuário com nova média
  UPDATE usuarios
  SET perfis = (
    SELECT jsonb_agg(
      CASE
        WHEN p->>'type' = perfil_atual
        THEN p || jsonb_build_object(
          'rating', v_media_nova,
          'total_avaliacoes', v_total_aval
        )
        ELSE p
      END
    )
    FROM jsonb_array_elements(perfis) AS p
  )
  WHERE id = p_avaliado_id;
END;
$$;
