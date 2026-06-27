-- ============================================================
-- TIO - RPCs: Onboarding e Sessão
-- Migration: 20260627000001
-- Depende de: 20260627000000 (schema)
-- ============================================================

CREATE EXTENSION IF NOT EXISTS unaccent;

-- ============================================================
-- rpc_verificar_cidade
-- Retorna dados da cidade pelo nome (ignora acentos e maiúsculas)
-- ============================================================
CREATE OR REPLACE FUNCTION rpc_verificar_cidade(p_nome TEXT)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_row cfg_cidades%ROWTYPE;
BEGIN
  SELECT * INTO v_row
  FROM cfg_cidades
  WHERE unaccent(lower(nome)) = unaccent(lower(trim(p_nome)))
  LIMIT 1;

  IF NOT FOUND THEN
    SELECT * INTO v_row
    FROM cfg_cidades
    WHERE unaccent(lower(nome)) LIKE unaccent(lower(trim(p_nome))) || '%'
    ORDER BY length(nome) ASC
    LIMIT 1;
  END IF;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('encontrada', false, 'ativa', false);
  END IF;

  RETURN jsonb_build_object(
    'encontrada',      true,
    'id',              v_row.id,
    'nome',            v_row.nome,
    'estado',          v_row.estado,
    'ativa',           v_row.ativa,
    'motores_ativos',  v_row.motores_ativos,
    'servicos_ativos', v_row.servicos_ativos,
    'raio_busca_km',   v_row.raio_busca_km
  );
END;
$$;

-- ============================================================
-- rpc_obter_usuario
-- Retorna usuário completo por telefone: perfis, endereços,
-- saldos e sessão ativa atual
-- ============================================================
CREATE OR REPLACE FUNCTION rpc_obter_usuario(p_telefone TEXT)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_u  usuarios%ROWTYPE;
  v_tp DECIMAL;
  v_sd DECIMAL;
BEGIN
  SELECT * INTO v_u FROM usuarios WHERE telefone = p_telefone;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('encontrado', false);
  END IF;

  SELECT COALESCE(saldo, 0)        INTO v_tp FROM tiopay        WHERE usuario_id = v_u.id;
  SELECT COALESCE(saldo_devedor, 0) INTO v_sd FROM saldo_usuario WHERE usuario_id = v_u.id;

  RETURN jsonb_build_object(
    'encontrado',      true,
    'id',              v_u.id,
    'telefone',        v_u.telefone,
    'pushname',        v_u.pushname,
    'nome',            v_u.nome,
    'sexo',            v_u.sexo,
    'perfis',          v_u.perfis,
    'perfil_atual',    v_u.perfil_atual,
    'cidade',          v_u.cidade,
    'cidade_id',       v_u.cidade_id,
    'ativo',           v_u.ativo,
    'bloqueado',       v_u.bloqueado,
    'motivo_bloqueio', v_u.motivo_bloqueio,
    'tiopay_saldo',    v_tp,
    'saldo_devedor',   v_sd,
    'enderecos', (
      SELECT COALESCE(jsonb_agg(
        jsonb_build_object(
          'id',          e.id,
          'tipo',        e.tipo,
          'endereco',    e.endereco,
          'numero',      e.numero,
          'complemento', e.complemento,
          'cidade',      e.cidade,
          'latitude',    e.latitude,
          'longitude',   e.longitude,
          'principal',   e.principal
        ) ORDER BY e.principal DESC, e.criado_em ASC
      ), '[]'::jsonb)
      FROM enderecos e
      WHERE e.usuario_id = v_u.id AND e.ativo = true
    ),
    'sessao', (
      SELECT jsonb_build_object(
        'id',             s.id,
        'motor_atual',    s.motor_atual,
        'contexto_atual', s.contexto_atual
      )
      FROM sessoes s
      WHERE s.usuario_id = v_u.id AND s.status = 'ativa'
      ORDER BY s.ultima_atividade DESC
      LIMIT 1
    )
  );
END;
$$;

-- ============================================================
-- rpc_criar_usuario
-- Cria usuário + endereço principal + sessão + tiopay + saldo
-- p_senha deve chegar como hash bcrypt gerado pela aplicação
-- ============================================================
CREATE OR REPLACE FUNCTION rpc_criar_usuario(
  p_telefone      TEXT,
  p_pushname      TEXT,
  p_nome          TEXT,
  p_sexo          TEXT,
  p_cidade_id     UUID,
  p_cidade_nome   TEXT,
  p_senha         TEXT,
  p_tipo_endereco TEXT,
  p_endereco      TEXT,
  p_numero        TEXT,
  p_complemento   TEXT    DEFAULT NULL,
  p_bairro        TEXT    DEFAULT NULL,
  p_latitude      DECIMAL DEFAULT NULL,
  p_longitude     DECIMAL DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_uid UUID;
  v_sid UUID;
BEGIN
  INSERT INTO usuarios (
    telefone, pushname, nome, sexo,
    cidade_id, cidade, senha,
    perfis, perfil_atual
  )
  VALUES (
    p_telefone, p_pushname, p_nome, p_sexo,
    p_cidade_id, p_cidade_nome, p_senha,
    '[{"type":"cliente","status":"ativo","rating":5.0,"total_avaliacoes":0}]'::jsonb,
    'cliente'
  )
  RETURNING id INTO v_uid;

  INSERT INTO enderecos (
    usuario_id, tipo, endereco, numero, complemento,
    bairro, cidade, cidade_id, latitude, longitude, principal
  )
  VALUES (
    v_uid, p_tipo_endereco, p_endereco, p_numero, p_complemento,
    p_bairro, p_cidade_nome, p_cidade_id, p_latitude, p_longitude, true
  );

  INSERT INTO sessoes (usuario_id, status)
  VALUES (v_uid, 'ativa')
  RETURNING id INTO v_sid;

  INSERT INTO tiopay (usuario_id, tipo_usuario, saldo)
  VALUES (v_uid, 'cliente', 0);

  INSERT INTO saldo_usuario (usuario_id, saldo_disponivel, saldo_devedor)
  VALUES (v_uid, 0, 0);

  UPDATE cfg_cidades
  SET total_usuarios = total_usuarios + 1
  WHERE id = p_cidade_id;

  RETURN jsonb_build_object(
    'sucesso',    true,
    'usuario_id', v_uid,
    'sessao_id',  v_sid
  );
EXCEPTION WHEN OTHERS THEN
  RAISE EXCEPTION 'rpc_criar_usuario: %', SQLERRM;
END;
$$;

-- ============================================================
-- rpc_adicionar_endereco
-- ============================================================
CREATE OR REPLACE FUNCTION rpc_adicionar_endereco(
  p_usuario_id  UUID,
  p_tipo        TEXT,
  p_endereco    TEXT,
  p_numero      TEXT,
  p_complemento TEXT    DEFAULT NULL,
  p_bairro      TEXT    DEFAULT NULL,
  p_cidade      TEXT    DEFAULT NULL,
  p_cidade_id   UUID    DEFAULT NULL,
  p_latitude    DECIMAL DEFAULT NULL,
  p_longitude   DECIMAL DEFAULT NULL,
  p_principal   BOOLEAN DEFAULT false
)
RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_id UUID;
BEGIN
  IF p_principal THEN
    UPDATE enderecos SET principal = false WHERE usuario_id = p_usuario_id;
  END IF;

  INSERT INTO enderecos (
    usuario_id, tipo, endereco, numero, complemento,
    bairro, cidade, cidade_id, latitude, longitude, principal
  )
  VALUES (
    p_usuario_id, p_tipo, p_endereco, p_numero, p_complemento,
    p_bairro, p_cidade, p_cidade_id, p_latitude, p_longitude, p_principal
  )
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

-- ============================================================
-- rpc_registrar_interesse
-- Salva lead de cidade não atendida (upsert por telefone)
-- ============================================================
CREATE OR REPLACE FUNCTION rpc_registrar_interesse(
  p_telefone  TEXT,
  p_pushname  TEXT,
  p_cidade    TEXT,
  p_cidade_id UUID
)
RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_id UUID;
BEGIN
  INSERT INTO usuarios_interesse (telefone, pushname, cidade, cidade_id)
  VALUES (p_telefone, p_pushname, p_cidade, p_cidade_id)
  ON CONFLICT (telefone) DO UPDATE
    SET pushname  = EXCLUDED.pushname,
        cidade    = EXCLUDED.cidade,
        cidade_id = EXCLUDED.cidade_id
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

-- ============================================================
-- rpc_obter_ou_criar_sessao
-- Reutiliza sessão ativa existente ou cria nova
-- ============================================================
CREATE OR REPLACE FUNCTION rpc_obter_ou_criar_sessao(p_usuario_id UUID)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_s sessoes%ROWTYPE;
BEGIN
  SELECT * INTO v_s
  FROM sessoes
  WHERE usuario_id = p_usuario_id AND status = 'ativa'
  ORDER BY ultima_atividade DESC
  LIMIT 1;

  IF NOT FOUND THEN
    INSERT INTO sessoes (usuario_id, status) VALUES (p_usuario_id, 'ativa')
    RETURNING * INTO v_s;
  ELSE
    UPDATE sessoes SET ultima_atividade = NOW() WHERE id = v_s.id;
  END IF;

  RETURN jsonb_build_object(
    'id',             v_s.id,
    'motor_atual',    v_s.motor_atual,
    'contexto_atual', v_s.contexto_atual
  );
END;
$$;

-- ============================================================
-- rpc_atualizar_sessao
-- N8N chama isso a cada passo do fluxo para persistir contexto
-- ============================================================
CREATE OR REPLACE FUNCTION rpc_atualizar_sessao(
  p_sessao_id UUID,
  p_motor     TEXT,
  p_contexto  JSONB
)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  UPDATE sessoes
  SET motor_atual    = p_motor,
      contexto_atual = p_contexto,
      ultima_atividade = NOW()
  WHERE id = p_sessao_id;
END;
$$;

-- ============================================================
-- rpc_limpar_sessao
-- Chamado quando usuário conclui ou cancela um fluxo
-- ============================================================
CREATE OR REPLACE FUNCTION rpc_limpar_sessao(p_sessao_id UUID)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  UPDATE sessoes
  SET motor_atual    = NULL,
      contexto_atual = '{}'::jsonb,
      ultima_atividade = NOW()
  WHERE id = p_sessao_id;
END;
$$;

-- ============================================================
-- rpc_atualizar_pushname
-- Mantém nome do WhatsApp sincronizado a cada mensagem recebida
-- ============================================================
CREATE OR REPLACE FUNCTION rpc_atualizar_pushname(p_telefone TEXT, p_pushname TEXT)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  UPDATE usuarios
  SET pushname = p_pushname
  WHERE telefone = p_telefone
    AND (pushname IS NULL OR pushname IS DISTINCT FROM p_pushname);
END;
$$;

-- ============================================================
-- rpc_validar_senha
-- Compara input com hash bcrypt armazenado via pgcrypto crypt()
-- Compatível com $2a/$2b gerados por bcryptjs/bcrypt no Node
-- ============================================================
CREATE OR REPLACE FUNCTION rpc_validar_senha(p_usuario_id UUID, p_senha TEXT)
RETURNS BOOLEAN
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_hash TEXT;
BEGIN
  SELECT senha INTO v_hash FROM usuarios WHERE id = p_usuario_id AND ativo = true;
  IF NOT FOUND THEN RETURN false; END IF;
  RETURN crypt(p_senha, v_hash) = v_hash;
END;
$$;
