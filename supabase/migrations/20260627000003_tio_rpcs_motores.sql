-- ============================================================
-- TIO - RPCs: Os 5 Motores
-- Migration: 20260627000003
-- Depende de: 000002 (financeiro RPCs)
-- ============================================================

-- ============================================================
-- UTILITÁRIO: Tipo de executor por serviço
-- ============================================================
CREATE OR REPLACE FUNCTION fn_tipo_executor(p_tipo_servico TEXT)
RETURNS TEXT
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN p_tipo_servico IN ('corrida_moto', 'corrida_carro', 'entrega') THEN 'motorista'
    WHEN p_tipo_servico IN ('barbearia','salao','massagem','eletricista','encanador','pintor','reparo')
         THEN 'prestador'
    WHEN p_tipo_servico IN ('pizza','hamburguer','restaurante','delivery') THEN 'estabelecimento'
    ELSE 'prestador'
  END;
$$;

-- ============================================================
-- rpc_calcular_tarifa
-- Busca tarifa configurada e retorna breakdown de valores
-- ============================================================
CREATE OR REPLACE FUNCTION rpc_calcular_tarifa(
  p_motor        TEXT,
  p_tipo_servico TEXT,
  p_distancia_km DECIMAL,
  p_cidade_id    UUID
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_t  cfg_tarifas%ROWTYPE;
  v_total DECIMAL;
BEGIN
  SELECT * INTO v_t
  FROM cfg_tarifas
  WHERE motor        = p_motor
    AND tipo_servico = p_tipo_servico
    AND (cidade_id   = p_cidade_id OR cidade_id IS NULL)
    AND ativa        = true
  ORDER BY cidade_id NULLS LAST
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Tarifa não configurada: motor=%, servico=%', p_motor, p_tipo_servico;
  END IF;

  v_total := GREATEST(
    COALESCE(v_t.taxa_minima, 0),
    COALESCE(v_t.valor_base, 0) + (p_distancia_km * COALESCE(v_t.valor_km, 0))
  );
  v_total := ROUND(v_total, 2);

  RETURN jsonb_build_object(
    'valor_total',           v_total,
    'valor_base',            v_t.valor_base,
    'valor_km',              v_t.valor_km,
    'distancia_km',          p_distancia_km,
    'taxa_percentual',       v_t.taxa_percentual,
    'percentual_matriz',     v_t.percentual_matriz,
    'percentual_franqueado', v_t.percentual_franqueado,
    'valor_executor',        ROUND(v_total * (1 - v_t.taxa_percentual / 100), 2)
  );
END;
$$;

-- ============================================================
-- rpc_criar_solicitacao
-- Ponto de entrada para todos os motores
-- ============================================================
CREATE OR REPLACE FUNCTION rpc_criar_solicitacao(
  p_usuario_id         UUID,
  p_tipo_usuario       TEXT,
  p_cidade_id          UUID,
  p_motor              TEXT,
  p_tipo_servico       TEXT,
  p_dados              JSONB,
  p_minutos_expiracao  INT DEFAULT 15
)
RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_id UUID;
BEGIN
  INSERT INTO solicitacoes (
    usuario_id, tipo_usuario, cidade_id,
    motor, tipo_servico, dados,
    status, expira_em
  )
  VALUES (
    p_usuario_id, p_tipo_usuario, p_cidade_id,
    p_motor, p_tipo_servico, p_dados,
    'aberta',
    NOW() + (p_minutos_expiracao || ' minutes')::INTERVAL
  )
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

-- ============================================================
-- rpc_buscar_executores_proximos
-- Lista motoristas/prestadores disponíveis na cidade,
-- ordenados por distância aproximada e rating.
-- Sem PostGIS usa distância Euclidiana em graus → km.
-- ============================================================
CREATE OR REPLACE FUNCTION rpc_buscar_executores_proximos(
  p_tipo_servico TEXT,
  p_cidade_id    UUID,
  p_latitude     DECIMAL DEFAULT NULL,
  p_longitude    DECIMAL DEFAULT NULL,
  p_raio_km      INT     DEFAULT 5,
  p_limite       INT     DEFAULT 10
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_tipo_exec TEXT;
BEGIN
  v_tipo_exec := fn_tipo_executor(p_tipo_servico);

  RETURN (
    SELECT COALESCE(jsonb_agg(r ORDER BY r.distancia_km ASC NULLS LAST, r.rating DESC NULLS LAST), '[]'::jsonb)
    FROM (
      SELECT
        u.id,
        u.telefone,
        u.pushname,
        u.nome,
        -- Extrai rating do perfil correspondente
        ( SELECT (p->>'rating')::DECIMAL
          FROM jsonb_array_elements(u.perfis) p
          WHERE p->>'type' = v_tipo_exec
          LIMIT 1
        ) AS rating,
        ( SELECT (p->>'total_avaliacoes')::INT
          FROM jsonb_array_elements(u.perfis) p
          WHERE p->>'type' = v_tipo_exec
          LIMIT 1
        ) AS total_avaliacoes,
        e.latitude,
        e.longitude,
        -- Distância aproximada em km (fórmula plana, suficiente para raios < 20km)
        CASE
          WHEN p_latitude IS NOT NULL AND p_longitude IS NOT NULL AND e.latitude IS NOT NULL
          THEN ROUND(
            SQRT(
              POWER((e.latitude  - p_latitude)  * 111.32, 2) +
              POWER((e.longitude - p_longitude) * 111.32 * COS(RADIANS(p_latitude)), 2)
            )::DECIMAL, 2
          )
          ELSE NULL
        END AS distancia_km
      FROM usuarios u
      LEFT JOIN enderecos e ON e.usuario_id = u.id AND e.principal = true
      WHERE u.cidade_id  = p_cidade_id
        AND u.ativo      = true
        AND u.bloqueado  = false
        AND EXISTS (
          SELECT 1 FROM jsonb_array_elements(u.perfis) p
          WHERE p->>'type'   = v_tipo_exec
            AND p->>'status' = 'ativo'
        )
    ) r
    WHERE r.distancia_km IS NULL OR r.distancia_km <= p_raio_km
    LIMIT p_limite
  );
END;
$$;

-- ============================================================
-- rpc_aceitar_solicitacao
-- Aceite atômico: protegido contra race condition
-- ============================================================
CREATE OR REPLACE FUNCTION rpc_aceitar_solicitacao(
  p_solicitacao_id UUID,
  p_executor_id    UUID
)
RETURNS BOOLEAN
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  UPDATE solicitacoes
  SET status                = 'aceita',
      aceita_por_usuario_id = p_executor_id,
      aceita_em             = NOW(),
      atualizado_em         = NOW()
  WHERE id     = p_solicitacao_id
    AND status = 'aberta';  -- garante que só um motorista aceita

  RETURN FOUND;
END;
$$;

-- ============================================================
-- MOTOR 2: CARONA COMPARTILHADA
-- ============================================================

-- Publica carona (fluxo inverso: motorista cria, cliente entra)
CREATE OR REPLACE FUNCTION rpc_publicar_carona(
  p_motorista_id UUID,
  p_cidade_id    UUID,
  p_dados        JSONB
  -- dados esperado:
  -- {origem, destino, data_saida, hora_saida, total_vagas,
  --  valor_total, km_total, paradas, tipo_veiculo}
)
RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_id       UUID;
  v_km_total DECIMAL;
  v_vagas    INT;
  v_total    DECIMAL;
BEGIN
  v_km_total := (p_dados->>'km_total')::DECIMAL;
  v_vagas    := (p_dados->>'total_vagas')::INT;
  v_total    := (p_dados->>'valor_total')::DECIMAL;

  INSERT INTO ofertas (
    usuario_id, tipo_usuario, cidade_id,
    motor, tipo_servico,
    dados, status,
    expira_em
  )
  VALUES (
    p_motorista_id, 'motorista', p_cidade_id,
    'carona', 'carona_compartilhada',
    p_dados || jsonb_build_object(
      'valor_por_vaga',   ROUND(v_total / NULLIF(v_vagas, 0), 2),
      'valor_por_km',     ROUND(v_total / NULLIF(v_km_total, 0), 2),
      'vagas_disponiveis', v_vagas,
      'passageiros',       '[]'::jsonb
    ),
    'ativa',
    -- Expira na data/hora da saída + 1h
    (p_dados->>'data_saida')::DATE + (p_dados->>'hora_saida')::TIME + INTERVAL '1 hour'
  )
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

-- Busca caronas disponíveis por origem/destino
CREATE OR REPLACE FUNCTION rpc_buscar_caronas(
  p_cidade_id UUID,
  p_origem    TEXT,
  p_destino   TEXT,
  p_data      DATE DEFAULT CURRENT_DATE
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  RETURN (
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'oferta_id',         o.id,
      'motorista_id',      o.usuario_id,
      'motorista_nome',    u.nome,
      'motorista_rating',  (
        SELECT (p->>'rating')::DECIMAL FROM jsonb_array_elements(u.perfis) p
        WHERE p->>'type' = 'motorista' LIMIT 1
      ),
      'dados',             o.dados,
      'vagas_disponiveis', (o.dados->>'vagas_disponiveis')::INT,
      'valor_por_km',      (o.dados->>'valor_por_km')::DECIMAL,
      'hora_saida',        o.dados->>'hora_saida'
    )), '[]'::jsonb)
    FROM ofertas o
    JOIN usuarios u ON u.id = o.usuario_id
    WHERE o.cidade_id  = p_cidade_id
      AND o.motor      = 'carona'
      AND o.status     = 'ativa'
      AND (o.dados->>'data_saida')::DATE = p_data
      AND (o.dados->>'vagas_disponiveis')::INT > 0
      -- Verifica se a origem está na rota (destino ou parada)
      AND (
        unaccent(lower(o.dados->>'origem'))   LIKE '%' || unaccent(lower(p_origem))  || '%' OR
        unaccent(lower(o.dados->>'destino'))  LIKE '%' || unaccent(lower(p_origem))  || '%'
      )
  );
END;
$$;

-- Calcula valor proporcional do trecho solicitado pelo passageiro
CREATE OR REPLACE FUNCTION rpc_calcular_trecho_carona(
  p_oferta_id UUID,
  p_km_trecho DECIMAL
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_valor_km  DECIMAL;
  v_valor     DECIMAL;
BEGIN
  SELECT (dados->>'valor_por_km')::DECIMAL INTO v_valor_km
  FROM ofertas WHERE id = p_oferta_id;

  IF NOT FOUND OR v_valor_km IS NULL THEN
    RAISE EXCEPTION 'Oferta de carona não encontrada: %', p_oferta_id;
  END IF;

  v_valor := ROUND(p_km_trecho * v_valor_km, 2);

  RETURN jsonb_build_object(
    'km_trecho',   p_km_trecho,
    'valor_por_km', v_valor_km,
    'valor_trecho', v_valor
  );
END;
$$;

-- Passageiro entra na carona (decrementa vagas)
CREATE OR REPLACE FUNCTION rpc_entrar_carona(
  p_oferta_id    UUID,
  p_passageiro_id UUID,
  p_origem       TEXT,
  p_destino      TEXT,
  p_km_trecho    DECIMAL,
  p_valor_pago   DECIMAL
)
RETURNS BOOLEAN
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_vagas INT;
BEGIN
  SELECT (dados->>'vagas_disponiveis')::INT INTO v_vagas
  FROM ofertas WHERE id = p_oferta_id AND status = 'ativa'
  FOR UPDATE;

  IF NOT FOUND OR v_vagas <= 0 THEN
    RETURN false;
  END IF;

  UPDATE ofertas
  SET dados = dados
    || jsonb_build_object('vagas_disponiveis', v_vagas - 1)
    || jsonb_build_object('passageiros',
         COALESCE(dados->'passageiros', '[]'::jsonb)
         || jsonb_build_array(jsonb_build_object(
              'usuario_id', p_passageiro_id,
              'origem',     p_origem,
              'destino',    p_destino,
              'km',         p_km_trecho,
              'valor',      p_valor_pago,
              'status',     'confirmado'
            ))
       ),
      atualizado_em = NOW()
  WHERE id = p_oferta_id;

  RETURN true;
END;
$$;

-- ============================================================
-- MOTOR 3 + 4: SERVIÇOS E REPAROS
-- (Oferta/Agendamento e Indicação/Orçamento)
-- ============================================================

-- Busca prestadores ativos por tipo de serviço e cidade
CREATE OR REPLACE FUNCTION rpc_buscar_prestadores(
  p_tipo_servico TEXT,
  p_cidade_id    UUID,
  p_limite       INT DEFAULT 5
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  RETURN (
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id',               u.id,
      'telefone',         u.telefone,
      'nome',             u.nome,
      'rating',           (
        SELECT (p->>'rating')::DECIMAL FROM jsonb_array_elements(u.perfis) p
        WHERE p->>'type' = 'prestador' LIMIT 1
      ),
      'total_avaliacoes', (
        SELECT (p->>'total_avaliacoes')::INT FROM jsonb_array_elements(u.perfis) p
        WHERE p->>'type' = 'prestador' LIMIT 1
      ),
      -- Dados extras do prestador ficam no campo dados da oferta dele
      -- ou num JSONB dedicado dentro de perfis
      'especialidades', (
        SELECT p->'especialidades' FROM jsonb_array_elements(u.perfis) p
        WHERE p->>'type' = 'prestador' LIMIT 1
      )
    ) ORDER BY (
        SELECT (p->>'rating')::DECIMAL FROM jsonb_array_elements(u.perfis) p
        WHERE p->>'type' = 'prestador' LIMIT 1
      ) DESC NULLS LAST
    ), '[]'::jsonb)
    FROM usuarios u
    WHERE u.cidade_id = p_cidade_id
      AND u.ativo     = true
      AND u.bloqueado = false
      AND EXISTS (
        SELECT 1 FROM jsonb_array_elements(u.perfis) p
        WHERE p->>'type'   = 'prestador'
          AND p->>'status' = 'ativo'
          AND (
            p->'especialidades' @> jsonb_build_array(p_tipo_servico)
            OR p_tipo_servico = ANY(ARRAY['eletricista','encanador','pintor','reparo'])
          )
      )
    LIMIT p_limite
  );
END;
$$;

-- Cria agendamento (Motor 3) ou orçamento (Motor 4)
-- A distinção está no campo motor passado
CREATE OR REPLACE FUNCTION rpc_criar_agendamento(
  p_cliente_id   UUID,
  p_prestador_id UUID,
  p_cidade_id    UUID,
  p_motor        TEXT,   -- 'oferta_agendamento' ou 'indicacao_orcamento'
  p_tipo_servico TEXT,
  p_dados        JSONB   -- {descricao, data_preferida, periodo, endereco_id, etc}
)
RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_id UUID;
BEGIN
  -- Cria solicitação vinculando cliente e prestador
  INSERT INTO solicitacoes (
    usuario_id, tipo_usuario, cidade_id,
    motor, tipo_servico, dados,
    status, expira_em
  )
  VALUES (
    p_cliente_id, 'cliente', p_cidade_id,
    p_motor, p_tipo_servico,
    p_dados || jsonb_build_object(
      'prestador_id', p_prestador_id,
      'fase', 'aguardando_confirmacao_prestador'
    ),
    'aberta',
    NOW() + INTERVAL '24 hours'
  )
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

-- Prestador confirma agendamento e propõe horário
CREATE OR REPLACE FUNCTION rpc_confirmar_agendamento(
  p_solicitacao_id UUID,
  p_prestador_id   UUID,
  p_dados_resposta JSONB  -- {horario_confirmado, observacao, valor_estimado}
)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  UPDATE solicitacoes
  SET status        = 'aceita',
      aceita_por_usuario_id = p_prestador_id,
      aceita_em     = NOW(),
      dados         = dados || p_dados_resposta
                            || jsonb_build_object('fase', 'confirmado'),
      atualizado_em = NOW()
  WHERE id     = p_solicitacao_id
    AND status = 'aberta';
END;
$$;

-- ============================================================
-- MOTOR 5: DELIVERY INTELIGENTE
-- ============================================================

-- Busca estabelecimentos abertos por tipo de cuisine/serviço
CREATE OR REPLACE FUNCTION rpc_buscar_estabelecimentos(
  p_tipo      TEXT,    -- 'pizzaria', 'hamburguer', 'restaurante', etc.
  p_cidade_id UUID,
  p_limite    INT DEFAULT 5
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  RETURN (
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id',               u.id,
      'nome',             u.nome,
      'telefone',         u.telefone,
      'rating',           (
        SELECT (p->>'rating')::DECIMAL FROM jsonb_array_elements(u.perfis) p
        WHERE p->>'type' = 'estabelecimento' LIMIT 1
      ),
      'total_avaliacoes', (
        SELECT (p->>'total_avaliacoes')::INT FROM jsonb_array_elements(u.perfis) p
        WHERE p->>'type' = 'estabelecimento' LIMIT 1
      ),
      'tempo_entrega_min', (
        SELECT p->>'tempo_entrega_min' FROM jsonb_array_elements(u.perfis) p
        WHERE p->>'type' = 'estabelecimento' LIMIT 1
      ),
      'taxa_entrega', (
        SELECT (p->>'taxa_entrega')::DECIMAL FROM jsonb_array_elements(u.perfis) p
        WHERE p->>'type' = 'estabelecimento' LIMIT 1
      )
    ) ORDER BY (
        SELECT (p->>'rating')::DECIMAL FROM jsonb_array_elements(u.perfis) p
        WHERE p->>'type' = 'estabelecimento' LIMIT 1
      ) DESC NULLS LAST
    ), '[]'::jsonb)
    FROM usuarios u
    WHERE u.cidade_id = p_cidade_id
      AND u.ativo     = true
      AND u.bloqueado = false
      AND EXISTS (
        SELECT 1 FROM jsonb_array_elements(u.perfis) p
        WHERE p->>'type'   = 'estabelecimento'
          AND p->>'status' = 'ativo'
          AND (p->>'tipo_cuisine' = p_tipo OR p_tipo IS NULL)
      )
    LIMIT p_limite
  );
END;
$$;

-- Busca itens do cardápio com texto livre (nome ou ingredientes)
CREATE OR REPLACE FUNCTION rpc_buscar_itens_cardapio(
  p_estabelecimento_id UUID,
  p_busca              TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  RETURN (
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id',          ci.id,
      'nome',        ci.nome,
      'descricao',   ci.descricao,
      'ingredientes', ci.ingredientes,
      'preco',       ci.preco,
      'preco_promo', ci.preco_promocional,
      'categoria',   cc.nome
    ) ORDER BY ci.nome ASC), '[]'::jsonb)
    FROM cardapio_itens ci
    LEFT JOIN cardapio_categorias cc ON cc.id = ci.categoria_id
    WHERE ci.estabelecimento_id = p_estabelecimento_id
      AND ci.ativo              = true
      AND ci.disponivel         = true
      AND (
        p_busca IS NULL
        OR unaccent(lower(ci.nome))         LIKE '%' || unaccent(lower(p_busca)) || '%'
        OR unaccent(lower(ci.ingredientes)) LIKE '%' || unaccent(lower(p_busca)) || '%'
      )
  );
END;
$$;

-- Cria pedido de delivery completo
CREATE OR REPLACE FUNCTION rpc_criar_pedido_delivery(
  p_cliente_id         UUID,
  p_estabelecimento_id UUID,
  p_cidade_id          UUID,
  p_itens              JSONB,   -- [{id, nome, preco, qtd}]
  p_endereco_id        UUID,
  p_forma_pagamento    TEXT,    -- 'pix', 'dinheiro', 'cartao_maquina'
  p_troco_para         DECIMAL DEFAULT NULL,  -- valor da nota (dinheiro)
  p_retirada           BOOLEAN DEFAULT false  -- true = cliente vai buscar
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_sol_id       UUID;
  v_total_itens  DECIMAL;
  v_taxa_entrega DECIMAL := 0;
  v_total_final  DECIMAL;
  v_troco        DECIMAL := 0;
  v_end          enderecos%ROWTYPE;
BEGIN
  -- Calcula total dos itens
  SELECT ROUND(SUM((item->>'preco')::DECIMAL * (item->>'qtd')::INT), 2)
  INTO v_total_itens
  FROM jsonb_array_elements(p_itens) AS item;

  -- Busca taxa de entrega do estabelecimento
  IF NOT p_retirada THEN
    SELECT (p->>'taxa_entrega')::DECIMAL INTO v_taxa_entrega
    FROM usuarios u, jsonb_array_elements(u.perfis) p
    WHERE u.id = p_estabelecimento_id AND p->>'type' = 'estabelecimento'
    LIMIT 1;

    v_taxa_entrega := COALESCE(v_taxa_entrega, 0);
  END IF;

  v_total_final := v_total_itens + v_taxa_entrega;

  -- Busca endereço de entrega
  IF NOT p_retirada THEN
    SELECT * INTO v_end FROM enderecos WHERE id = p_endereco_id AND usuario_id = p_cliente_id;
  END IF;

  -- Calcula troco se pagamento em dinheiro
  IF p_forma_pagamento = 'dinheiro' AND p_troco_para IS NOT NULL THEN
    v_troco := GREATEST(0, ROUND(p_troco_para - v_total_final, 2));
  END IF;

  -- Cria solicitação de delivery
  INSERT INTO solicitacoes (
    usuario_id, tipo_usuario, cidade_id,
    motor, tipo_servico, dados,
    status, expira_em
  )
  VALUES (
    p_cliente_id, 'cliente', p_cidade_id,
    'delivery', 'delivery',
    jsonb_build_object(
      'estabelecimento_id',  p_estabelecimento_id,
      'itens',               p_itens,
      'total_itens',         v_total_itens,
      'taxa_entrega',        v_taxa_entrega,
      'total_final',         v_total_final,
      'forma_pagamento',     p_forma_pagamento,
      'troco_para',          p_troco_para,
      'troco_valor',         v_troco,
      'retirada',            p_retirada,
      'endereco_entrega_id', p_endereco_id,
      'endereco_entrega',    CASE WHEN v_end.id IS NOT NULL
                             THEN jsonb_build_object(
                               'endereco', v_end.endereco,
                               'numero',   v_end.numero,
                               'tipo',     v_end.tipo
                             )
                             ELSE NULL END,
      'fase', 'aguardando_estabelecimento'
    ),
    'aberta',
    NOW() + INTERVAL '30 minutes'
  )
  RETURNING id INTO v_sol_id;

  RETURN jsonb_build_object(
    'solicitacao_id',  v_sol_id,
    'total_itens',     v_total_itens,
    'taxa_entrega',    v_taxa_entrega,
    'total_final',     v_total_final,
    'troco',           v_troco
  );
END;
$$;

-- Estabelecimento aceita ou recusa o pedido de delivery
CREATE OR REPLACE FUNCTION rpc_aceitar_pedido_delivery(
  p_solicitacao_id     UUID,
  p_estabelecimento_id UUID,
  p_aceitar            BOOLEAN,
  p_tempo_preparo_min  INT DEFAULT 15
)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF p_aceitar THEN
    UPDATE solicitacoes
    SET status                = 'aceita',
        aceita_por_usuario_id = p_estabelecimento_id,
        aceita_em             = NOW(),
        dados = dados || jsonb_build_object(
          'fase',             'em_preparo',
          'tempo_preparo_min', p_tempo_preparo_min,
          'previsao_saida',   NOW() + (p_tempo_preparo_min || ' minutes')::INTERVAL
        ),
        atualizado_em = NOW()
    WHERE id = p_solicitacao_id AND status = 'aberta';
  ELSE
    UPDATE solicitacoes
    SET status        = 'cancelada',
        cancelada_em  = NOW(),
        motivo_cancelamento = 'Estabelecimento recusou o pedido',
        atualizado_em = NOW()
    WHERE id = p_solicitacao_id;
  END IF;
END;
$$;

-- Marca pedido como saiu para entrega (estabelecimento despachou)
CREATE OR REPLACE FUNCTION rpc_despachar_pedido(
  p_solicitacao_id UUID,
  p_entregador_id  UUID
)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  UPDATE solicitacoes
  SET dados = dados || jsonb_build_object(
        'fase',        'em_rota',
        'entregador_id', p_entregador_id,
        'saiu_em',     NOW()
      ),
      atualizado_em = NOW()
  WHERE id = p_solicitacao_id;
END;
$$;
