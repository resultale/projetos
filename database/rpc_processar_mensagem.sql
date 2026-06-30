-- ========================================================================
-- RPC: PROCESSAR MENSAGEM - Função Principal de Roteamento
-- ========================================================================
-- Descrição: Processa mensagens recebidas do WhatsApp/Maestro
-- Retorna: JSONB com workflow_id, estado da conversa e dados do usuário
-- ========================================================================

-- 1. 🧼 FAXINA COMPLETA: Remove as assinaturas antigas para evitar duplicidade
-- ========================================================================
DROP FUNCTION IF EXISTS public.rpc_processar_mensagem(text, text, text, text, text, text);
DROP FUNCTION IF EXISTS public.rpc_processar_mensagem(text, text, text, text, text, text, text, text);

-- ========================================================================
-- 2. 🚀 CRIAÇÃO DEFINITIVA: Bloco de abertura e fechamento corrigidos com $$
-- ========================================================================
CREATE OR REPLACE FUNCTION public.rpc_processar_mensagem(
    p_telefone text,
    p_mensagem text,
    p_msg_id text,
    p_context_msg_id text,
    p_codigo_oferta text,
    p_push_name text,
    p_latitude text DEFAULT NULL::text,
    p_longitude text DEFAULT NULL::text
)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $$
DECLARE
  v_usuario_id UUID;
  v_usuario_nome TEXT;
  v_status_conta TEXT;
  v_cidade_id UUID;
  v_cidade_nome TEXT;
  v_usuario_sexo TEXT;
  v_servicos_ativos TEXT[];
  v_etapa_atual TEXT;
  v_fluxo_atual TEXT;
  v_historico JSONB;
  v_workflow_id TEXT;
  v_contexto JSONB;
  v_ultima_msg TIMESTAMP WITH TIME ZONE;
  v_sessao_existe BOOLEAN := FALSE;
  v_suporte_ativo BOOLEAN;
  v_operador_id UUID;
  v_operador_nome TEXT;
  v_timestamp_suporte_inicio TIMESTAMP WITH TIME ZONE;
  v_motivo_suporte TEXT;
  v_motor TEXT;
BEGIN

  -- 1. Localiza o utilizador
  SELECT id, nome, status_conta, cidade_id, cidade, sexo
  INTO v_usuario_id, v_usuario_nome, v_status_conta, v_cidade_id, v_cidade_nome, v_usuario_sexo
  FROM usuarios WHERE telefone = p_telefone;

  IF v_usuario_id IS NULL THEN
    INSERT INTO usuarios (telefone, perfis, saldo_tiopay)
    VALUES (p_telefone, ARRAY['cliente'], 0.00)
    RETURNING id, status_conta INTO v_usuario_id, v_status_conta;
  END IF;

  -- 🛡️ SISTEMA DE AUTO-CURA (SELF-HEALING)
  IF v_usuario_id IS NOT NULL AND v_cidade_id IS NULL AND v_cidade_nome IS NOT NULL THEN
    SELECT id INTO v_cidade_id FROM cidades WHERE lower(cidade) = lower(v_cidade_nome) LIMIT 1;
    UPDATE usuarios SET cidade_id = v_cidade_id WHERE id = v_usuario_id;
  END IF;

  -- 2. Localiza a Sessão
  SELECT
    etapa_atual, fluxo_atual, historico_contexto, contexto, ultima_mensagem_at,
    suporte_ativo, operador_id, timestamp_suporte_inicio, motivo_suporte
  INTO
    v_etapa_atual, v_fluxo_atual, v_historico, v_contexto, v_ultima_msg,
    v_suporte_ativo, v_operador_id, v_timestamp_suporte_inicio, v_motivo_suporte
  FROM conversation_state WHERE telefone = p_telefone;

  v_sessao_existe := FOUND;

  -- ==========================================
  -- 🕒 TIMEOUT DE SESSÃO CONVERSACIONAL (1 HORA)
  -- ==========================================
  IF v_sessao_existe AND COALESCE(v_suporte_ativo, false) = false AND (NOW() - v_ultima_msg > INTERVAL '1 hour') THEN
    v_fluxo_atual := 'menu_principal';
    v_etapa_atual := 'menu_principal';
    v_contexto := '{}'::jsonb;
  END IF;

  -- 📍 ATUALIZAÇÃO DO CONTEXTO EM MEMÓRIA
  IF v_sessao_existe THEN
    v_contexto := COALESCE(v_contexto, '{}'::jsonb);
    IF p_codigo_oferta IS NOT NULL THEN
      v_contexto := v_contexto || jsonb_build_object('codigo_oferta', p_codigo_oferta);
    END IF;
    IF p_latitude IS NOT NULL THEN
      v_contexto := v_contexto || jsonb_build_object('latitude', p_latitude);
    END IF;
    IF p_longitude IS NOT NULL THEN
      v_contexto := v_contexto || jsonb_build_object('longitude', p_longitude);
    END IF;
  END IF;

  -- ==========================================
  -- 🚨 PROTEÇÃO 1: SUPORTE HUMANO ATIVO
  -- ==========================================
  IF v_suporte_ativo = true THEN
    IF LOWER(TRIM(p_mensagem)) = '!retomar' THEN
      UPDATE conversation_state
      SET
        suporte_ativo = false,
        operador_id = NULL,
        timestamp_suporte_fim = NOW(),
        fluxo_atual = 'menu_principal',
        etapa_atual = 'menu_principal',
        ultima_mensagem_at = NOW()
      WHERE telefone = p_telefone;

      UPDATE suporte_logs
      SET
        timestamp_fim = NOW(),
        duracao_minutos = EXTRACT(MINUTE FROM NOW() - timestamp_inicio)::INTEGER,
        resolvido = true
      WHERE usuario_telefone = p_telefone AND timestamp_fim IS NULL;

      RETURN jsonb_build_object(
        'tipo', 'SUPORTE_FINALIZADO',
        'mensagem', 'Suporte finalizado. Bot retomando...',
        'fluxo_atual', 'menu_principal'
      );
    END IF;

    IF (NOW() - v_timestamp_suporte_inicio > INTERVAL '1 hour') THEN
      UPDATE conversation_state
      SET
        suporte_ativo = false,
        operador_id = NULL,
        timestamp_suporte_fim = NOW(),
        fluxo_atual = 'menu_principal',
        etapa_atual = 'menu_principal',
        ultima_mensagem_at = NOW()
      WHERE telefone = p_telefone;

      UPDATE suporte_logs
      SET
        timestamp_fim = NOW(),
        duracao_minutos = EXTRACT(MINUTE FROM NOW() - timestamp_inicio)::INTEGER
      WHERE usuario_telefone = p_telefone AND timestamp_fim IS NULL;

      RETURN jsonb_build_object(
        'tipo', 'SUPORTE_TIMEOUT',
        'mensagem', 'Suporte encerrado por timeout (1h). Voltando ao menu...'
      );
    END IF;

    INSERT INTO suporte_mensagens (suporte_log_id, quem_enviou, cliente_telefone, conteudo_msg)
    SELECT sl.id, 'cliente', p_telefone, p_mensagem
    FROM suporte_logs sl
    WHERE sl.usuario_telefone = p_telefone AND sl.timestamp_fim IS NULL
    LIMIT 1;

    RETURN jsonb_build_object(
      'tipo', 'BLOQUEADO_SUPORTE',
      'operador_id', v_operador_id,
      'operador_nome', (SELECT nome FROM operadores WHERE id = v_operador_id),
      'motivo', v_motivo_suporte,
      'tempo_aguardando_minutos', EXTRACT(MINUTE FROM NOW() - v_timestamp_suporte_inicio)::INTEGER,
      'mensagem', 'Operador humano em atendimento. Sua mensagem foi registrada.'
    );
  END IF;

  -- ==========================================
  -- 🚨 PROTEÇÃO 2: ANTI-LOOP
  -- ==========================================
  IF v_sessao_existe AND (NOW() - v_ultima_msg < INTERVAL '1.8 second') THEN
    RETURN jsonb_build_object(
      'tipo', 'BLOQUEADO',
      'motivo', 'Loop detectado',
      'workflow_id', NULL,
      'em_coleta_ativa', false
    );
  END IF;

  -- ==========================================
  -- 3. TRAVA DE SEGURANÇA MÁXIMA E SALVAMENTO DE CONTEXTO
  -- ==========================================
  IF v_usuario_nome IS NULL OR v_cidade_id IS NULL THEN
    v_fluxo_atual := 'cadastro';

    IF v_etapa_atual NOT LIKE 'coletando_%' OR v_etapa_atual IS NULL THEN
      v_etapa_atual := 'coletando_cidade';
    END IF;

    IF NOT v_sessao_existe THEN
      v_contexto := jsonb_build_object('codigo_oferta', p_codigo_oferta);
      IF p_latitude IS NOT NULL THEN
        v_contexto := v_contexto || jsonb_build_object('latitude', p_latitude);
      END IF;
      IF p_longitude IS NOT NULL THEN
        v_contexto := v_contexto || jsonb_build_object('longitude', p_longitude);
      END IF;

      INSERT INTO conversation_state (telefone, usuario_id, fluxo_atual, etapa_atual, contexto, historico_contexto)
      VALUES (p_telefone, v_usuario_id, v_fluxo_atual, v_etapa_atual, v_contexto, '[]'::jsonb);
    ELSE
      UPDATE conversation_state
      SET
        fluxo_atual = v_fluxo_atual,
        etapa_atual = v_etapa_atual,
        contexto = v_contexto,
        ultima_mensagem_at = NOW()
      WHERE telefone = p_telefone;
    END IF;

  ELSE
    IF v_fluxo_atual = 'cadastro' THEN
      v_fluxo_atual := 'menu_principal';
      v_etapa_atual := 'menu_principal';
      UPDATE conversation_state
      SET
        fluxo_atual = 'menu_principal',
        etapa_atual = 'menu_principal',
        contexto = v_contexto,
        ultima_mensagem_at = NOW()
      WHERE telefone = p_telefone;
    ELSE
      UPDATE conversation_state
      SET
        fluxo_atual = v_fluxo_atual,
        etapa_atual = v_etapa_atual,
        contexto = v_contexto,
        ultima_mensagem_at = NOW()
      WHERE telefone = p_telefone;
    END IF;
  END IF;

  IF v_fluxo_atual = 'cadastro' AND v_contexto IS NOT NULL THEN
    IF v_cidade_id IS NULL AND (v_contexto->>'cidade_id') IS NOT NULL THEN
      v_cidade_id := (v_contexto->>'cidade_id')::uuid;
    END IF;
  END IF;

  -- ========================================================================
  -- 🔥 4. EXTRAÇÃO SEGURA DAS CHAVES DO NOVO JSONB PARA TEXT[]
  -- ========================================================================
  IF v_cidade_id IS NOT NULL THEN
    SELECT c.cidade,
           ARRAY(
             SELECT key
             FROM jsonb_each(COALESCE(cfg.servicos_ativos, '{}'::jsonb))
             WHERE (value->>'ativa')::boolean = true
           )
    INTO v_cidade_nome, v_servicos_ativos
    FROM cidades c
    JOIN cfg_cidades cfg ON cfg.cidade_id = c.id
    WHERE c.id = v_cidade_id;
  END IF;

  -- ==========================================
  -- ROTEAMENTO 1: CADASTRO
  -- ==========================================
  IF v_etapa_atual LIKE 'coletando_%' AND v_fluxo_atual = 'cadastro' THEN
    SELECT workflow_id INTO v_workflow_id FROM cfg_workflows WHERE codigo = 'cadastro';
    v_workflow_id := COALESCE(v_workflow_id, 'NbBb1NLuDRON6HhZ');

    RETURN jsonb_build_object(
      'tipo', 'EXECUTAR',
      'workflow_id', v_workflow_id,
      'sessao_id', v_usuario_id,
      'estado_atual', v_etapa_atual,
      'em_coleta_ativa', true,
      'fluxo_atual', 'cadastro',
      'campos_faltantes', jsonb_build_array('dados_cadastro'),
      'conteudo_msg', p_mensagem,
      'msg_id', p_msg_id,
      'context_msg_id', p_context_msg_id,
      'codigo_oferta', p_codigo_oferta,
      'latitude', p_latitude,
      'longitude', p_longitude,
      'telefone', p_telefone,
      'cidade_id', v_cidade_id,
      'cidade_nome', v_cidade_nome,
      'sexo', v_usuario_sexo,
      'historico_contexto', COALESCE(v_historico, '[]'::jsonb),
      'veiculos_disponiveis', (
        SELECT jsonb_agg(jsonb_build_object(
          'chave', t.veiculo_chave_tecnica,
          'nome', t.veiculo_nome_exibicao,
          'icone', t.veiculo_icone,
          'valor_base', t.valor_base,
          'valor_por_km', t.valor_por_km,
          'valor_minimo', t.valor_minimo,
          'ativa', t.ativa
        ))
        FROM tarifas t
        WHERE t.cidade_id = v_cidade_id AND t.ativa = true AND t.veiculo_ativo = true
      ),
      'usuario', jsonb_build_object(
        'id', v_usuario_id,
        'nome', COALESCE(v_usuario_nome, p_push_name),
        'status', v_status_conta,
        'telefone', p_telefone
      )
    );
  END IF;

  -- ==========================================
  -- ROTEAMENTO 2: SUB-FLUXOS ATIVOS (TRAVA)
  -- ==========================================
  IF v_fluxo_atual IS NOT NULL
     AND v_fluxo_atual != 'menu_principal'
     AND v_fluxo_atual != 'cadastro'
     AND v_fluxo_atual != '' THEN

    SELECT motor INTO v_motor FROM servicos WHERE codigo = v_fluxo_atual LIMIT 1;

    IF v_motor IS NOT NULL THEN
      SELECT workflow_id INTO v_workflow_id FROM cfg_workflows WHERE lower(codigo) = lower(v_motor) LIMIT 1;
    END IF;

    IF v_workflow_id IS NOT NULL THEN
      RETURN jsonb_build_object(
        'tipo', 'EXECUTAR',
        'workflow_id', v_workflow_id,
        'sessao_id', v_usuario_id,
        'estado_atual', v_etapa_atual,
        'em_coleta_ativa', true,
        'fluxo_atual', v_fluxo_atual,
        'campos_faltantes', '[]'::jsonb,
        'conteudo_msg', p_mensagem,
        'msg_id', p_msg_id,
        'context_msg_id', p_context_msg_id,
        'codigo_oferta', p_codigo_oferta,
        'latitude', p_latitude,
        'longitude', p_longitude,
        'telefone', p_telefone,
        'cidade_id', v_cidade_id,
        'cidade_nome', v_cidade_nome,
        'sexo', v_usuario_sexo,
        'historico_contexto', COALESCE(v_historico, '[]'::jsonb),
        'veiculos_disponiveis', (
          SELECT jsonb_agg(jsonb_build_object(
            'chave', t.veiculo_chave_tecnica,
            'nome', t.veiculo_nome_exibicao,
            'icone', t.veiculo_icone,
            'base_km', t.valor_base,
            'min', t.valor_minimo,
            'ativa', t.ativa
          ))
          FROM tarifas t
          WHERE t.cidade_id = v_cidade_id AND t.ativa = true AND t.veiculo_ativo = true
        ),
        'usuario', jsonb_build_object(
          'id', v_usuario_id,
          'nome', v_usuario_nome,
          'telefone', p_telefone,
          'cidade_id', v_cidade_id,
          'cidade_nome', v_cidade_nome,
          'sexo', v_usuario_sexo,
          'servicos_ativos', COALESCE(to_jsonb(v_servicos_ativos), '[]'::jsonb)
        )
      );
    END IF;
  END IF;

  -- ==========================================
  -- ROTEAMENTO 3: MAESTRO (FALLBACK)
  -- ==========================================
  RETURN jsonb_build_object(
    'tipo', 'CHAMAR_MAESTRO',
    'workflow_id', NULL,
    'sessao_id', v_usuario_id,
    'estado_atual', v_etapa_atual,
    'em_coleta_ativa', false,
    'fluxo_atual', v_fluxo_atual,
    'campos_faltantes', '[]'::jsonb,
    'conteudo_msg', p_mensagem,
    'msg_id', p_msg_id,
    'context_msg_id', p_context_msg_id,
    'codigo_oferta', p_codigo_oferta,
    'latitude', p_latitude,
    'longitude', p_longitude,
    'telefone', p_telefone,
    'cidade_id', v_cidade_id,
    'cidade_nome', v_cidade_nome,
    'sexo', v_usuario_sexo,
    'historico_contexto', COALESCE(v_historico, '[]'::jsonb),
    'veiculos_disponiveis', (
      SELECT jsonb_agg(jsonb_build_object(
        'chave', t.veiculo_chave_tecnica,
        'nome', t.veiculo_nome_exibicao,
        'icone', t.veiculo_icone,
        'base_km', t.valor_base,
        'min', t.valor_minimo,
        'ativa', t.ativa
      ))
      FROM tarifas t
      WHERE t.cidade_id = v_cidade_id AND t.ativa = true AND t.veiculo_ativo = true
    ),
    'usuario', jsonb_build_object(
      'id', v_usuario_id,
      'nome', v_usuario_nome,
      'telefone', p_telefone,
      'cidade_id', v_cidade_id,
      'cidade_nome', v_cidade_nome,
      'sexo', v_usuario_sexo,
      'servicos_ativos', COALESCE(to_jsonb(v_servicos_ativos), '[]'::jsonb)
    )
  );

END;
$$;

-- ========================================================================
-- GRANT PERMISSIONS
-- ========================================================================
GRANT EXECUTE ON FUNCTION public.rpc_processar_mensagem(
    text, text, text, text, text, text, text, text
) TO public;

-- ========================================================================
-- DOCUMENTAÇÃO
-- ========================================================================
COMMENT ON FUNCTION public.rpc_processar_mensagem(
    text, text, text, text, text, text, text, text
) IS 'RPC para processar mensagens do WhatsApp/Maestro. Retorna workflow_id, estado da conversa e contexto do usuário.';
