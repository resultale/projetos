-- ============================================================
-- TIO - Schema SQL Completo para Supabase
-- Versão: 3.0 | Data: 2026-06-27
-- ============================================================

-- Extensions
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ============================================================
-- FUNÇÃO AUXILIAR: atualiza coluna atualizado_em automaticamente
-- ============================================================

CREATE OR REPLACE FUNCTION fn_atualizar_timestamp()
RETURNS TRIGGER AS $$
BEGIN
  NEW.atualizado_em = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- 1. CONFIGURAÇÕES DE CIDADES
-- ============================================================

CREATE TABLE cfg_cidades (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  nome          VARCHAR(100) UNIQUE NOT NULL,
  estado        CHAR(2) NOT NULL,

  ativa         BOOLEAN DEFAULT false,
  data_ativacao TIMESTAMP WITH TIME ZONE,

  -- Ex: ["aceite_direto", "carona", "oferta_agendamento", "indicacao_orcamento", "delivery"]
  motores_ativos  JSONB DEFAULT '[]'::jsonb,
  -- Ex: ["corrida_moto", "corrida_carro", "entrega", "barbearia", "pizza"]
  servicos_ativos JSONB DEFAULT '[]'::jsonb,

  valor_minimo_cobranca DECIMAL(10,2) DEFAULT 50.00,
  dias_apos_atingir     INT DEFAULT 7,
  dias_vencimento       INT DEFAULT 7,

  raio_busca_km INT DEFAULT 2,

  -- Preenchido depois via ALTER (gerenciador é um usuario)
  gerenciador_id    UUID,
  telefone_suporte  VARCHAR(20),

  total_usuarios    INT DEFAULT 0,
  total_transacoes  INT DEFAULT 0,

  criado_em    TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  atualizado_em TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX idx_cfg_cidades_ativa ON cfg_cidades(ativa);
CREATE INDEX idx_cfg_cidades_nome  ON cfg_cidades(nome);

CREATE TRIGGER trg_cfg_cidades_atualizado
  BEFORE UPDATE ON cfg_cidades
  FOR EACH ROW EXECUTE FUNCTION fn_atualizar_timestamp();

-- ============================================================
-- 2. USUÁRIOS
-- Clientes, motoristas, prestadores, estabelecimentos
-- e franqueados compartilham esta tabela via campo `perfis`
-- ============================================================

CREATE TABLE usuarios (
  id       UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  telefone VARCHAR(20) UNIQUE NOT NULL,
  pushname VARCHAR(255),
  nome     VARCHAR(255),
  sexo     VARCHAR(30),         -- 'Masculino', 'Feminino', 'Prefiro não informar'

  -- Ex: [{"type": "cliente", "status": "ativo", "rating": 4.9, "total_avaliacoes": 156}]
  perfis        JSONB DEFAULT '[]'::jsonb,
  perfil_atual  VARCHAR(30) DEFAULT 'cliente',

  -- UUID de outro usuario com perfil 'franqueado' (gerencia a cidade)
  franchise_id UUID,

  cidade    VARCHAR(100),
  cidade_id UUID NOT NULL REFERENCES cfg_cidades(id),

  senha VARCHAR(255) NOT NULL,  -- hash bcrypt

  ativo    BOOLEAN DEFAULT true,
  bloqueado BOOLEAN DEFAULT false,
  motivo_bloqueio VARCHAR(255),
  bloqueado_em    TIMESTAMP WITH TIME ZONE,

  criado_em    TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  atualizado_em TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE UNIQUE INDEX idx_usuarios_telefone_cidade ON usuarios(telefone, cidade_id);
CREATE INDEX idx_usuarios_cidade_id   ON usuarios(cidade_id);
CREATE INDEX idx_usuarios_perfil_atual ON usuarios(perfil_atual);
CREATE INDEX idx_usuarios_ativo        ON usuarios(ativo) WHERE ativo = true;

CREATE TRIGGER trg_usuarios_atualizado
  BEFORE UPDATE ON usuarios
  FOR EACH ROW EXECUTE FUNCTION fn_atualizar_timestamp();

-- FK circular resolvida após criação de ambas as tabelas
ALTER TABLE cfg_cidades
  ADD CONSTRAINT fk_cfg_cidades_gerenciador
  FOREIGN KEY (gerenciador_id) REFERENCES usuarios(id);

ALTER TABLE usuarios
  ADD CONSTRAINT fk_usuarios_franchise
  FOREIGN KEY (franchise_id) REFERENCES usuarios(id);

-- ============================================================
-- 3. ENDEREÇOS
-- Múltiplos endereços por usuário com apelido livre
-- ============================================================

CREATE TABLE enderecos (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  usuario_id  UUID NOT NULL REFERENCES usuarios(id) ON DELETE CASCADE,

  tipo        VARCHAR(50),         -- 'Casa', 'Trabalho', 'Academia', 'Outro'
  endereco    VARCHAR(255),
  numero      VARCHAR(20),
  complemento VARCHAR(100),
  bairro      VARCHAR(100),

  cidade    VARCHAR(100),
  cidade_id UUID NOT NULL REFERENCES cfg_cidades(id),
  cep       VARCHAR(10),

  latitude  DECIMAL(9,6),
  longitude DECIMAL(9,6),

  -- Endereço padrão usado quando cliente diz "aqui em casa"
  principal BOOLEAN DEFAULT false,
  ativo     BOOLEAN DEFAULT true,

  criado_em    TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  atualizado_em TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX idx_enderecos_usuario_cidade ON enderecos(usuario_id, cidade_id);
CREATE INDEX idx_enderecos_usuario_id     ON enderecos(usuario_id);
CREATE INDEX idx_enderecos_principal      ON enderecos(usuario_id, principal)
  WHERE principal = true;

CREATE TRIGGER trg_enderecos_atualizado
  BEFORE UPDATE ON enderecos
  FOR EACH ROW EXECUTE FUNCTION fn_atualizar_timestamp();

-- ============================================================
-- 4. SESSÕES E MENSAGENS
-- Contexto da conversa WhatsApp por usuário
-- ============================================================

CREATE TABLE sessoes (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  usuario_id UUID NOT NULL REFERENCES usuarios(id) ON DELETE CASCADE,

  status        VARCHAR(20) DEFAULT 'ativa',   -- 'ativa', 'inativa'
  motor_atual   VARCHAR(50),                    -- motor em execução
  contexto_atual JSONB DEFAULT '{}'::jsonb,    -- estado da conversa em andamento

  ultima_atividade TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  criado_em        TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX idx_sessoes_usuario_id        ON sessoes(usuario_id);
CREATE INDEX idx_sessoes_status            ON sessoes(status);
CREATE INDEX idx_sessoes_ultima_atividade  ON sessoes(ultima_atividade);

CREATE TABLE mensagens (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  usuario_id     UUID NOT NULL REFERENCES usuarios(id) ON DELETE CASCADE,
  sessao_id      UUID NOT NULL REFERENCES sessoes(id) ON DELETE CASCADE,
  solicitacao_id UUID,               -- referência opcional à solicitação vinculada

  conteudo TEXT,
  tipo     VARCHAR(20),              -- 'enviada' (usuário→TIO), 'recebida' (TIO→usuário)

  criado_em  TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  deletado_em TIMESTAMP WITH TIME ZONE  -- soft delete para rotina de limpeza
);

CREATE INDEX idx_mensagens_usuario_id  ON mensagens(usuario_id);
CREATE INDEX idx_mensagens_sessao_id   ON mensagens(sessao_id);
CREATE INDEX idx_mensagens_criado_em   ON mensagens(criado_em);

-- ============================================================
-- 5. SOLICITAÇÕES
-- Pedidos criados pelos clientes (ponto de entrada dos motores)
-- ============================================================

CREATE TABLE solicitacoes (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  usuario_id   UUID NOT NULL REFERENCES usuarios(id),
  tipo_usuario VARCHAR(30),    -- 'cliente', 'motorista', 'prestador'

  cidade_id UUID NOT NULL REFERENCES cfg_cidades(id),

  -- Motor responsável pelo fluxo
  motor        VARCHAR(50) NOT NULL,   -- 'aceite_direto', 'carona', 'oferta_agendamento',
                                       -- 'indicacao_orcamento', 'delivery'
  tipo_servico VARCHAR(50) NOT NULL,   -- 'corrida_moto', 'corrida_carro', 'entrega',
                                       -- 'barbearia', 'pizza', 'eletricista', etc.

  -- Dados dinâmicos do serviço (origem, destino, distância, valor, etc.)
  dados JSONB NOT NULL DEFAULT '{}'::jsonb,

  status VARCHAR(30) DEFAULT 'aberta',
  -- 'aberta' | 'aceita' | 'em_andamento' | 'finalizada' | 'cancelada' | 'expirada'

  aceita_por_usuario_id UUID REFERENCES usuarios(id),
  aceita_em             TIMESTAMP WITH TIME ZONE,

  finalizada_em         TIMESTAMP WITH TIME ZONE,
  cancelada_em          TIMESTAMP WITH TIME ZONE,
  motivo_cancelamento   VARCHAR(255),

  criada_em    TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  expira_em    TIMESTAMP WITH TIME ZONE,
  atualizado_em TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX idx_solicitacoes_usuario_motor  ON solicitacoes(usuario_id, motor);
CREATE INDEX idx_solicitacoes_status         ON solicitacoes(status);
CREATE INDEX idx_solicitacoes_expira_em      ON solicitacoes(expira_em)
  WHERE status = 'aberta';
CREATE INDEX idx_solicitacoes_cidade_id      ON solicitacoes(cidade_id);
CREATE INDEX idx_solicitacoes_tipo_servico   ON solicitacoes(tipo_servico);
CREATE INDEX idx_solicitacoes_criada_em      ON solicitacoes(criada_em);

CREATE TRIGGER trg_solicitacoes_atualizado
  BEFORE UPDATE ON solicitacoes
  FOR EACH ROW EXECUTE FUNCTION fn_atualizar_timestamp();

-- ============================================================
-- 6. OFERTAS
-- Publicadas por motoristas/prestadores (Motor 2: Carona,
-- Motor 3: Agendamento)
-- ============================================================

CREATE TABLE ofertas (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  usuario_id   UUID NOT NULL REFERENCES usuarios(id),
  tipo_usuario VARCHAR(30),

  cidade_id UUID NOT NULL REFERENCES cfg_cidades(id),

  motor        VARCHAR(50) NOT NULL,
  tipo_servico VARCHAR(50) NOT NULL,

  dados JSONB NOT NULL DEFAULT '{}'::jsonb,

  status VARCHAR(30) DEFAULT 'ativa',
  -- 'ativa' | 'aceita' | 'recusada' | 'expirada' | 'cancelada'

  aceita_por_usuario_id UUID REFERENCES usuarios(id),
  aceita_em             TIMESTAMP WITH TIME ZONE,

  criada_em    TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  expira_em    TIMESTAMP WITH TIME ZONE,
  atualizado_em TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX idx_ofertas_usuario_motor ON ofertas(usuario_id, motor);
CREATE INDEX idx_ofertas_status        ON ofertas(status);
CREATE INDEX idx_ofertas_cidade_id     ON ofertas(cidade_id);
CREATE INDEX idx_ofertas_expira_em     ON ofertas(expira_em)
  WHERE status = 'ativa';

CREATE TRIGGER trg_ofertas_atualizado
  BEFORE UPDATE ON ofertas
  FOR EACH ROW EXECUTE FUNCTION fn_atualizar_timestamp();

-- ============================================================
-- 7. USUÁRIOS INTERESSE (cidades ainda não atendidas)
-- Captados para notificação quando a cidade for ativada
-- ============================================================

CREATE TABLE usuarios_interesse (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  pushname VARCHAR(255),
  telefone VARCHAR(20) UNIQUE NOT NULL,

  cidade    VARCHAR(100),
  cidade_id UUID NOT NULL REFERENCES cfg_cidades(id),

  notificado       BOOLEAN DEFAULT false,
  data_notificacao TIMESTAMP WITH TIME ZONE,

  criado_em TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX idx_usuarios_interesse_cidade     ON usuarios_interesse(cidade_id);
CREATE INDEX idx_usuarios_interesse_notificado ON usuarios_interesse(notificado)
  WHERE notificado = false;

-- ============================================================
-- 8. CONFIGURAÇÕES: Tarifas, Cashback, Reembolso
-- ============================================================

CREATE TABLE cfg_tarifas (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  cidade_id UUID REFERENCES cfg_cidades(id),  -- NULL = global

  motor        VARCHAR(50),
  tipo_servico VARCHAR(50),

  valor_base   DECIMAL(10,2) DEFAULT 0,
  valor_km     DECIMAL(10,4) DEFAULT 0,
  valor_minuto DECIMAL(10,4) DEFAULT 0,

  taxa_percentual    DECIMAL(5,2) DEFAULT 20.00,
  taxa_minima        DECIMAL(10,2) DEFAULT 0,

  percentual_matriz      DECIMAL(5,2) DEFAULT 70.00,
  percentual_franqueado  DECIMAL(5,2) DEFAULT 30.00,

  ativa     BOOLEAN DEFAULT true,
  criado_em  TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  atualizado_em TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX idx_cfg_tarifas_cidade_motor ON cfg_tarifas(cidade_id, motor, tipo_servico);
CREATE INDEX idx_cfg_tarifas_ativa        ON cfg_tarifas(ativa);

CREATE TRIGGER trg_cfg_tarifas_atualizado
  BEFORE UPDATE ON cfg_tarifas
  FOR EACH ROW EXECUTE FUNCTION fn_atualizar_timestamp();

-- Percentual de cashback por forma de pagamento e cidade
CREATE TABLE cfg_cashback (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  cidade_id UUID REFERENCES cfg_cidades(id),  -- NULL = global

  tipo_usuario   VARCHAR(30) DEFAULT 'cliente',
  forma_pagamento VARCHAR(30) DEFAULT 'pix',   -- 'pix', 'dinheiro', 'cartao'

  percentual_cashback DECIMAL(5,2) DEFAULT 5.00,
  base_calculo        VARCHAR(50) DEFAULT 'valor_total',
  minimo_transacao    DECIMAL(10,2) DEFAULT 0,
  maximo_cashback     DECIMAL(10,2),

  ativa     BOOLEAN DEFAULT true,
  criado_em  TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX idx_cfg_cashback_cidade ON cfg_cashback(cidade_id);
CREATE INDEX idx_cfg_cashback_ativa  ON cfg_cashback(ativa);

-- Reembolso extra ao entregador quando pagamento é dinheiro/cartão
-- (padrão +10% do valor da entrega para cobrir devolução na loja)
CREATE TABLE cfg_reembolso_devolucao (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  cidade_id UUID REFERENCES cfg_cidades(id),  -- NULL = global

  tipo_pagamento       VARCHAR(30) NOT NULL,   -- 'dinheiro', 'cartao_maquina'
  percentual_reembolso DECIMAL(5,2) DEFAULT 10.00,
  descricao            VARCHAR(255),

  ativa     BOOLEAN DEFAULT true,
  criado_em  TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX idx_cfg_reembolso_tipo  ON cfg_reembolso_devolucao(tipo_pagamento);
CREATE INDEX idx_cfg_reembolso_ativa ON cfg_reembolso_devolucao(ativa);

-- ============================================================
-- 9. FINANCEIRO: TioPay, Saldos, Movimentações
-- ============================================================

CREATE TABLE tiopay (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  usuario_id UUID UNIQUE NOT NULL REFERENCES usuarios(id) ON DELETE CASCADE,

  tipo_usuario VARCHAR(30),  -- 'cliente', 'motorista', 'prestador', 'franqueado'
  saldo        DECIMAL(10,2) DEFAULT 0 CHECK (saldo >= 0),

  chave_pix      VARCHAR(255),
  tipo_chave_pix VARCHAR(20), -- 'cpf', 'email', 'telefone', 'aleatoria'

  -- Controle de saque automático
  frequencia_saque  VARCHAR(20) DEFAULT 'diaria',   -- 'diaria', 'semanal', 'mensal'
  saque_minimo      DECIMAL(10,2) DEFAULT 10.00,
  saque_maximo_dia  DECIMAL(10,2) DEFAULT 500.00,
  ultimo_saque      TIMESTAMP WITH TIME ZONE,

  atualizado_em TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX idx_tiopay_usuario_id  ON tiopay(usuario_id);
CREATE INDEX idx_tiopay_saldo       ON tiopay(saldo) WHERE saldo >= 10;
CREATE INDEX idx_tiopay_tipo_usuario ON tiopay(tipo_usuario);

CREATE TRIGGER trg_tiopay_atualizado
  BEFORE UPDATE ON tiopay
  FOR EACH ROW EXECUTE FUNCTION fn_atualizar_timestamp();

-- Saldo devedor (para crédito pré-aprovado ao entregador em entregas dinheiro)
CREATE TABLE saldo_usuario (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  usuario_id UUID UNIQUE NOT NULL REFERENCES usuarios(id) ON DELETE CASCADE,

  saldo_disponivel DECIMAL(10,2) DEFAULT 0,
  saldo_devedor    DECIMAL(10,2) DEFAULT 0,

  data_atingiu_limite TIMESTAMP WITH TIME ZONE,
  bloqueado           BOOLEAN DEFAULT false,
  motivo_bloqueio     VARCHAR(255),
  bloqueado_em        TIMESTAMP WITH TIME ZONE,

  atualizado_em TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX idx_saldo_usuario_id      ON saldo_usuario(usuario_id);
CREATE INDEX idx_saldo_devedor         ON saldo_usuario(saldo_devedor)
  WHERE saldo_devedor > 0;
CREATE INDEX idx_saldo_bloqueado       ON saldo_usuario(bloqueado)
  WHERE bloqueado = true;

CREATE TRIGGER trg_saldo_usuario_atualizado
  BEFORE UPDATE ON saldo_usuario
  FOR EACH ROW EXECUTE FUNCTION fn_atualizar_timestamp();

-- Histórico completo de entradas e saídas do TioPay
CREATE TABLE movimentacao_tiopay (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  usuario_id UUID NOT NULL REFERENCES usuarios(id),

  tipo VARCHAR(30) NOT NULL,
  -- 'cashback' | 'troco' | 'bonus' | 'recebimento' | 'saque' | 'estorno' | 'reembolso'

  valor           DECIMAL(10,2) NOT NULL,
  saldo_anterior  DECIMAL(10,2) NOT NULL,
  saldo_posterior DECIMAL(10,2) NOT NULL,

  referencia_id   UUID,            -- UUID da solicitação/entrega/promoção vinculada
  referencia_tipo VARCHAR(50),     -- 'solicitacao', 'entrega', 'promocao', 'saque'
  descricao       TEXT,

  criado_em TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX idx_movimentacao_usuario    ON movimentacao_tiopay(usuario_id);
CREATE INDEX idx_movimentacao_criado_em  ON movimentacao_tiopay(criado_em);
CREATE INDEX idx_movimentacao_tipo       ON movimentacao_tiopay(tipo);

-- Registro de cada saque processado (automático ou sob demanda)
CREATE TABLE saques_tiopay (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  usuario_id UUID NOT NULL REFERENCES usuarios(id),

  valor          DECIMAL(10,2) NOT NULL,
  chave_pix      VARCHAR(255) NOT NULL,
  tipo_chave_pix VARCHAR(20),

  tipo   VARCHAR(20) NOT NULL,      -- 'automatico', 'sob_demanda'
  status VARCHAR(20) DEFAULT 'pendente',
  -- 'pendente' | 'processando' | 'concluido' | 'erro'

  id_transacao_asaas VARCHAR(100),
  erro_descricao     TEXT,

  criado_em     TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  processado_em TIMESTAMP WITH TIME ZONE,
  concluido_em  TIMESTAMP WITH TIME ZONE
);

CREATE INDEX idx_saques_usuario   ON saques_tiopay(usuario_id);
CREATE INDEX idx_saques_status    ON saques_tiopay(status);
CREATE INDEX idx_saques_criado_em ON saques_tiopay(criado_em);

-- ============================================================
-- 10. COBRANÇAS (para saldo_devedor acima do limite)
-- ============================================================

CREATE TABLE cobrancas (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  usuario_id UUID NOT NULL REFERENCES usuarios(id),

  valor  DECIMAL(10,2) NOT NULL,
  status VARCHAR(20) DEFAULT 'pendente',
  -- 'pendente' | 'pago' | 'vencida' | 'cancelada'

  data_vencimento TIMESTAMP WITH TIME ZONE NOT NULL,
  pago_em         TIMESTAMP WITH TIME ZONE,
  pix_id_asaas    VARCHAR(100),

  criado_em    TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  atualizado_em TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX idx_cobrancas_usuario    ON cobrancas(usuario_id);
CREATE INDEX idx_cobrancas_status     ON cobrancas(status);
CREATE INDEX idx_cobrancas_vencimento ON cobrancas(data_vencimento);

CREATE TRIGGER trg_cobrancas_atualizado
  BEFORE UPDATE ON cobrancas
  FOR EACH ROW EXECUTE FUNCTION fn_atualizar_timestamp();

-- ============================================================
-- 11. ENTREGAS
-- Controla o ciclo de vida de uma entrega com código de confirmação
-- ============================================================

CREATE TABLE entregas (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  solicitacao_id UUID REFERENCES solicitacoes(id),

  -- Código alfanumérico mostrado ao destinatário para confirmar recebimento
  codigo_entrega     VARCHAR(20) UNIQUE NOT NULL,
  token_confirmacao  VARCHAR(100) UNIQUE NOT NULL,

  usuario_solicitante_id UUID NOT NULL REFERENCES usuarios(id),
  usuario_entregador_id  UUID REFERENCES usuarios(id),

  endereco_origem  VARCHAR(255),
  latitude_origem  DECIMAL(9,6),
  longitude_origem DECIMAL(9,6),

  endereco_destino  VARCHAR(255),
  latitude_destino  DECIMAL(9,6),
  longitude_destino DECIMAL(9,6),

  distancia_km         DECIMAL(6,2),
  tempo_estimado_min   INT,

  status VARCHAR(30) DEFAULT 'aguardando',
  -- 'aguardando' | 'aceita' | 'coletando' | 'em_rota' | 'entregue' | 'cancelada'

  requer_confirmacao_codigo BOOLEAN DEFAULT true,
  codigo_confirmacao        VARCHAR(10),

  valor_entrega   DECIMAL(10,2),
  forma_pagamento VARCHAR(20),

  criada_em   TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  aceita_em   TIMESTAMP WITH TIME ZONE,
  coletada_em TIMESTAMP WITH TIME ZONE,
  entregue_em TIMESTAMP WITH TIME ZONE
);

CREATE INDEX idx_entregas_codigo       ON entregas(codigo_entrega);
CREATE INDEX idx_entregas_status       ON entregas(status);
CREATE INDEX idx_entregas_solicitante  ON entregas(usuario_solicitante_id);
CREATE INDEX idx_entregas_entregador   ON entregas(usuario_entregador_id);

-- ============================================================
-- 12. PROMOÇÕES E ELEGIBILIDADE
-- ============================================================

-- Promoções criadas por estabelecimentos (usuarios com perfil 'estabelecimento')
CREATE TABLE promocoes (
  id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  estabelecimento_id UUID NOT NULL REFERENCES usuarios(id),
  cidade_id          UUID NOT NULL REFERENCES cfg_cidades(id),

  nome      VARCHAR(255) NOT NULL,
  descricao TEXT,

  desconto_percentual DECIMAL(5,2),
  desconto_valor      DECIMAL(10,2),

  minimo_compra    DECIMAL(10,2) DEFAULT 0,
  maximo_desconto  DECIMAL(10,2),

  limite_uso_total      INT,
  limite_uso_por_cliente INT DEFAULT 1,
  total_usado           INT DEFAULT 0,

  ativa BOOLEAN DEFAULT true,

  valida_de  TIMESTAMP WITH TIME ZONE,
  valida_ate TIMESTAMP WITH TIME ZONE,

  criado_em    TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  atualizado_em TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX idx_promocoes_estabelecimento ON promocoes(estabelecimento_id);
CREATE INDEX idx_promocoes_cidade          ON promocoes(cidade_id);
CREATE INDEX idx_promocoes_ativa           ON promocoes(ativa);
CREATE INDEX idx_promocoes_validade        ON promocoes(valida_ate)
  WHERE ativa = true;

CREATE TRIGGER trg_promocoes_atualizado
  BEFORE UPDATE ON promocoes
  FOR EACH ROW EXECUTE FUNCTION fn_atualizar_timestamp();

-- Registro de cada uso de promoção (com e sem desconto, se cliente inelegível)
CREATE TABLE transacoes_promocao (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  cliente_id         UUID NOT NULL REFERENCES usuarios(id),
  estabelecimento_id UUID NOT NULL REFERENCES usuarios(id),
  promocao_id        UUID NOT NULL REFERENCES promocoes(id),

  valor_original      DECIMAL(10,2) NOT NULL,
  desconto_percentual DECIMAL(5,2),
  desconto_valor      DECIMAL(10,2) NOT NULL DEFAULT 0,
  valor_final         DECIMAL(10,2) NOT NULL,

  forma_pagamento VARCHAR(20) NOT NULL,  -- 'pix', 'dinheiro', 'cartao'
  pix_id_asaas    VARCHAR(100),

  status VARCHAR(20) DEFAULT 'pendente',
  -- 'pendente' | 'pago' | 'cancelado' | 'estornado' | 'erro'

  criado_em TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  pago_em   TIMESTAMP WITH TIME ZONE
);

CREATE INDEX idx_transacoes_promo_cliente        ON transacoes_promocao(cliente_id);
CREATE INDEX idx_transacoes_promo_estabelecimento ON transacoes_promocao(estabelecimento_id);
CREATE INDEX idx_transacoes_promo_promocao       ON transacoes_promocao(promocao_id);
CREATE INDEX idx_transacoes_promo_status         ON transacoes_promocao(status);
CREATE INDEX idx_transacoes_promo_pago_em        ON transacoes_promocao(pago_em);

-- Rastreia elegibilidade e histórico de uso por cliente/promoção
CREATE TABLE elegibilidade_promocao (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  promocao_id UUID NOT NULL REFERENCES promocoes(id),
  cliente_id  UUID NOT NULL REFERENCES usuarios(id),

  elegivel        BOOLEAN DEFAULT true,
  motivo_bloqueio VARCHAR(255),

  data_primeiro_acesso TIMESTAMP WITH TIME ZONE,
  data_ultimo_acesso   TIMESTAMP WITH TIME ZONE,

  total_compras INT DEFAULT 0,
  total_gasto   DECIMAL(10,2) DEFAULT 0,

  bloqueado_ate TIMESTAMP WITH TIME ZONE,

  criado_em    TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  atualizado_em TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE UNIQUE INDEX idx_elegibilidade_promo_cliente ON elegibilidade_promocao(promocao_id, cliente_id);
CREATE INDEX idx_elegibilidade_cliente              ON elegibilidade_promocao(cliente_id);

CREATE TRIGGER trg_elegibilidade_atualizado
  BEFORE UPDATE ON elegibilidade_promocao
  FOR EACH ROW EXECUTE FUNCTION fn_atualizar_timestamp();

-- ============================================================
-- 13. AVALIAÇÕES
-- ============================================================

CREATE TABLE avaliacoes (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  avaliador_id   UUID NOT NULL REFERENCES usuarios(id),
  avaliado_id    UUID NOT NULL REFERENCES usuarios(id),
  solicitacao_id UUID REFERENCES solicitacoes(id),

  nota      INT NOT NULL CHECK (nota BETWEEN 1 AND 5),
  comentario TEXT,

  criado_em TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX idx_avaliacoes_avaliado    ON avaliacoes(avaliado_id);
CREATE INDEX idx_avaliacoes_avaliador   ON avaliacoes(avaliador_id);
CREATE INDEX idx_avaliacoes_solicitacao ON avaliacoes(solicitacao_id);

-- ============================================================
-- 14. CARDÁPIO (Motor 5 - Delivery)
-- Itens de estabelecimentos como pizzarias, restaurantes, etc.
-- ============================================================

CREATE TABLE cardapio_categorias (
  id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  estabelecimento_id UUID NOT NULL REFERENCES usuarios(id) ON DELETE CASCADE,

  nome      VARCHAR(100) NOT NULL,
  descricao TEXT,
  ordem     INT DEFAULT 0,
  ativa     BOOLEAN DEFAULT true,

  criado_em TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX idx_cardapio_cat_estabelecimento ON cardapio_categorias(estabelecimento_id);

CREATE TABLE cardapio_itens (
  id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  estabelecimento_id UUID NOT NULL REFERENCES usuarios(id) ON DELETE CASCADE,
  categoria_id       UUID REFERENCES cardapio_categorias(id),

  nome              VARCHAR(255) NOT NULL,
  descricao         TEXT,
  ingredientes      TEXT,

  preco             DECIMAL(10,2) NOT NULL,
  preco_promocional DECIMAL(10,2),

  disponivel BOOLEAN DEFAULT true,
  ativo      BOOLEAN DEFAULT true,

  criado_em    TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  atualizado_em TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX idx_cardapio_itens_estabelecimento ON cardapio_itens(estabelecimento_id);
CREATE INDEX idx_cardapio_itens_categoria       ON cardapio_itens(categoria_id);
CREATE INDEX idx_cardapio_itens_disponivel      ON cardapio_itens(disponivel, ativo)
  WHERE disponivel = true AND ativo = true;

CREATE TRIGGER trg_cardapio_itens_atualizado
  BEFORE UPDATE ON cardapio_itens
  FOR EACH ROW EXECUTE FUNCTION fn_atualizar_timestamp();

-- ============================================================
-- 15. ROW LEVEL SECURITY (Supabase)
-- RPCs e serviços internos via service_role bypassam o RLS.
-- Acesso via anon key é bloqueado por padrão em todas as tabelas.
-- ============================================================

ALTER TABLE cfg_cidades            ENABLE ROW LEVEL SECURITY;
ALTER TABLE usuarios               ENABLE ROW LEVEL SECURITY;
ALTER TABLE enderecos              ENABLE ROW LEVEL SECURITY;
ALTER TABLE sessoes                ENABLE ROW LEVEL SECURITY;
ALTER TABLE mensagens              ENABLE ROW LEVEL SECURITY;
ALTER TABLE solicitacoes           ENABLE ROW LEVEL SECURITY;
ALTER TABLE ofertas                ENABLE ROW LEVEL SECURITY;
ALTER TABLE usuarios_interesse     ENABLE ROW LEVEL SECURITY;
ALTER TABLE cfg_tarifas            ENABLE ROW LEVEL SECURITY;
ALTER TABLE cfg_cashback           ENABLE ROW LEVEL SECURITY;
ALTER TABLE cfg_reembolso_devolucao ENABLE ROW LEVEL SECURITY;
ALTER TABLE tiopay                 ENABLE ROW LEVEL SECURITY;
ALTER TABLE saldo_usuario          ENABLE ROW LEVEL SECURITY;
ALTER TABLE movimentacao_tiopay    ENABLE ROW LEVEL SECURITY;
ALTER TABLE saques_tiopay          ENABLE ROW LEVEL SECURITY;
ALTER TABLE cobrancas              ENABLE ROW LEVEL SECURITY;
ALTER TABLE entregas               ENABLE ROW LEVEL SECURITY;
ALTER TABLE promocoes              ENABLE ROW LEVEL SECURITY;
ALTER TABLE transacoes_promocao    ENABLE ROW LEVEL SECURITY;
ALTER TABLE elegibilidade_promocao ENABLE ROW LEVEL SECURITY;
ALTER TABLE avaliacoes             ENABLE ROW LEVEL SECURITY;
ALTER TABLE cardapio_categorias    ENABLE ROW LEVEL SECURITY;
ALTER TABLE cardapio_itens         ENABLE ROW LEVEL SECURITY;

-- Cidades ativas são visíveis publicamente (lookup no onboarding)
CREATE POLICY "cidades_ativas_publicas"
  ON cfg_cidades FOR SELECT
  USING (ativa = true);

-- Cardápio de estabelecimentos é visível publicamente
CREATE POLICY "cardapio_itens_publico"
  ON cardapio_itens FOR SELECT
  USING (ativo = true AND disponivel = true);

CREATE POLICY "cardapio_categorias_publico"
  ON cardapio_categorias FOR SELECT
  USING (ativa = true);

-- ============================================================
-- 16. CRON JOBS (pg_cron — ativar via Supabase Dashboard)
-- Execute manualmente no SQL Editor do Supabase para agendar.
-- ============================================================

/*
-- Expirar solicitações e ofertas (a cada 5 minutos)
SELECT cron.schedule(
  'tio-expirar-abertas',
  '*/5 * * * *',
  $$
    UPDATE solicitacoes
    SET status = 'expirada', atualizado_em = NOW()
    WHERE status = 'aberta' AND expira_em < NOW();

    UPDATE ofertas
    SET status = 'expirada', atualizado_em = NOW()
    WHERE status = 'ativa' AND expira_em < NOW();
  $$
);

-- Limpar mensagens de sessões inativas com +30 dias (toda segunda às 02:00)
SELECT cron.schedule(
  'tio-limpar-mensagens',
  '0 2 * * 1',
  $$
    DELETE FROM mensagens
    WHERE criado_em < NOW() - INTERVAL '30 days'
    AND sessao_id IN (SELECT id FROM sessoes WHERE status = 'inativa');
  $$
);

-- Gerar cobranças para saldo_devedor acima do limite (diariamente às 04:00)
SELECT cron.schedule(
  'tio-gerar-cobrancas',
  '0 4 * * *',
  $$
    INSERT INTO cobrancas (usuario_id, valor, status, data_vencimento)
    SELECT
      su.usuario_id,
      su.saldo_devedor,
      'pendente',
      NOW() + INTERVAL '7 days'
    FROM saldo_usuario su
    JOIN usuarios u ON u.id = su.usuario_id
    JOIN cfg_cidades cc ON cc.id = u.cidade_id
    WHERE su.saldo_devedor >= cc.valor_minimo_cobranca
    AND su.data_atingiu_limite < NOW() - (cc.dias_apos_atingir || ' days')::INTERVAL
    AND NOT EXISTS (
      SELECT 1 FROM cobrancas c
      WHERE c.usuario_id = su.usuario_id AND c.status = 'pendente'
    );
  $$
);

-- Bloquear usuários com cobrança vencida (a cada hora)
SELECT cron.schedule(
  'tio-bloquear-vencidos',
  '0 * * * *',
  $$
    UPDATE saldo_usuario
    SET bloqueado = true,
        motivo_bloqueio = 'Cobrança vencida',
        bloqueado_em = NOW()
    WHERE usuario_id IN (
      SELECT usuario_id FROM cobrancas
      WHERE status != 'pago'
      AND data_vencimento < NOW()
    )
    AND bloqueado = false;
  $$
);

-- Saque automático diário às 08:00
-- A lógica de chamada Asaas deve rodar via Edge Function ou N8N.
-- Este job dispara a seleção dos elegíveis e marca status 'processando'.
SELECT cron.schedule(
  'tio-saque-automatico',
  '0 8 * * *',
  $$
    INSERT INTO saques_tiopay (usuario_id, valor, chave_pix, tipo_chave_pix, tipo, status)
    SELECT
      t.usuario_id,
      t.saldo,
      t.chave_pix,
      t.tipo_chave_pix,
      'automatico',
      'pendente'
    FROM tiopay t
    WHERE t.saldo >= t.saque_minimo
    AND t.chave_pix IS NOT NULL
    AND (t.ultimo_saque IS NULL OR t.ultimo_saque < NOW() - INTERVAL '20 hours');
  $$
);
*/
