# 🗄️ Integração Database - Sistema TIO

## Função RPC: rpc_processar_mensagem

### O que faz?

Processa **todas as mensagens** que chegam do WhatsApp/Maestro:
1. Valida/cria usuário
2. Gerencia sessão conversacional
3. Detecta loop de processamento
4. Roteia para workflow correto

### Entrada (8 parâmetros)

```sql
SELECT public.rpc_processar_mensagem(
  p_telefone,           -- '11999999999'
  p_mensagem,          -- Conteúdo da mensagem
  p_msg_id,            -- ID único da mensagem
  p_context_msg_id,    -- ID da mensagem anterior (thread)
  p_codigo_oferta,     -- Código de campanha (nullable)
  p_push_name,         -- Nome no contato WhatsApp
  p_latitude,          -- Localização GPS (nullable)
  p_longitude          -- Localização GPS (nullable)
)
```

### Saída (JSONB)

```json
{
  "tipo": "EXECUTAR | CHAMAR_MAESTRO | BLOQUEADO | SUPORTE_*",
  "workflow_id": "ID do N8N workflow",
  "sessao_id": "UUID do usuário",
  "estado_atual": "etapa da conversa",
  "em_coleta_ativa": true,
  "fluxo_atual": "cadastro | motor1-corrida | menu_principal",
  "usuario": {
    "id": "UUID",
    "nome": "João Silva",
    "telefone": "11999999999",
    "cidade_id": "UUID",
    "cidade_nome": "São Paulo",
    "sexo": "M|F|outro",
    "servicos_ativos": ["motor1", "motor2"]
  },
  "contexto_memoria": {...},
  "veiculos_disponiveis": [
    {
      "chave": "motor1",
      "nome": "Corrida",
      "valor_base": 5.00,
      "valor_por_km": 2.50,
      "valor_minimo": 10.00
    }
  ]
}
```

## Fluxos de Roteamento

### 1️⃣ Novo Usuário → CADASTRO

```
Primeira mensagem
    ↓
rpc_processar_mensagem
    ↓
tipo: "EXECUTAR"
workflow_id: "cadastro"
    ↓
N8N: Coleta cidade, nome, sexo
    ↓
Atualiza conversation_state
    ↓
Próxima mensagem → Menu Principal
```

### 2️⃣ Usuário em Fluxo → SUB-WORKFLOW

```
conversation_state.fluxo_atual = "motor1-corrida"
    ↓
rpc_processar_mensagem
    ↓
tipo: "EXECUTAR"
workflow_id: "motor1-corrida"
    ↓
N8N: Motor 1 workflow processa a mensagem
```

### 3️⃣ Menu Principal → MAESTRO

```
conversation_state.fluxo_atual = "menu_principal"
    ↓
rpc_processar_mensagem
    ↓
tipo: "CHAMAR_MAESTRO"
workflow_id: null
    ↓
N8N: Maestro orquestra o próximo passo
```

## Proteções

### ⏱️ Timeout de Sessão (1 hora)
- Se últim mensagem > 1h: reseta fluxo
- Usuário volta ao menu_principal

### 🔁 Anti-Loop (1.8s)
- Duas mensagens < 1.8s = possível loop
- Retorna BLOQUEADO

### 🚨 Suporte Humano Ativo
- Se `suporte_ativo = true`: bloqueia bot
- Operador processa a mensagem
- Digite `!retomar` para voltar ao bot

### 🛡️ Self-Healing
- Detecta cidade faltando
- Busca e atualiza automaticamente

## Integração com N8N

### 1. Call rpc_processar_mensagem

**Node: PostgreSQL**
```sql
SELECT public.rpc_processar_mensagem(
  $1,  -- {{$json.telefone}}
  $2,  -- {{$json.mensagem}}
  $3,  -- {{$json.msg_id}}
  $4,  -- {{$json.context_msg_id}}
  $5,  -- {{$json.codigo_oferta}}
  $6,  -- {{$json.push_name}}
  $7,  -- {{$json.latitude}}
  $8   -- {{$json.longitude}}
)
```

### 2. Avaliar Tipo de Resposta

**Node: IF (switch)**
```javascript
if (resultado.tipo === 'EXECUTAR') {
  // Executa workflow indicado
  return resultado.workflow_id;
} else if (resultado.tipo === 'CHAMAR_MAESTRO') {
  // Chama Maestro workflow
  return 'maestro-orchestrator';
} else if (resultado.tipo === 'BLOQUEADO') {
  // Descarta (anti-loop)
  return null;
}
```

### 3. Passar Contexto Completo

**Todos os nodes subsequentes** recebem:
```javascript
const contexto = {{$json}}; // Resultado da RPC

// Acessar dados do usuário
const usuario = contexto.usuario;
const workflow = contexto.workflow_id;
const fluxo = contexto.fluxo_atual;

// Usar em sub-workflows
return {
  usuario_id: usuario.id,
  telefone: usuario.telefone,
  cidade_id: usuario.cidade_id,
  workflow_id: workflow
};
```

## Tabelas Envolvidas

### usuarios
```sql
id, telefone, nome, status_conta, cidade_id, cidade, sexo, perfis[], saldo_tiopay
```

### conversation_state
```sql
telefone (PK), usuario_id, fluxo_atual, etapa_atual, contexto (JSONB), 
historico_contexto (JSONB), ultima_mensagem_at, 
suporte_ativo, operador_id, timestamp_suporte_inicio, timestamp_suporte_fim
```

### suporte_logs
```sql
id, usuario_telefone, operador_id, motivo_suporte, 
timestamp_inicio, timestamp_fim, resolvido, duracao_minutos
```

### cfg_workflows
```sql
codigo, workflow_id, ativa, prioridade, descricao
```

### cfg_cidades
```sql
cidade_id, servicos_ativos (JSONB), config (JSONB)
```

## Exemplo Completo: Novo Usuário Pede Corrida

```
1. Usuário envia: "Oi, quero uma corrida"
   ↓
2. POST /webhook/motor1-corrida
   {
     "telefone": "11999999999",
     "mensagem": "Oi, quero uma corrida",
     "msg_id": "wamsgxxx",
     "context_msg_id": null,
     "codigo_oferta": null,
     "push_name": "João"
   }
   ↓
3. N8N: rpc_processar_mensagem()
   ↓
4. Retorna:
   {
     "tipo": "EXECUTAR",
     "workflow_id": "cadastro",
     "usuario": {
       "nome": "João",
       "telefone": "11999999999",
       "cidade_id": null
     }
   }
   ↓
5. N8N: Executa cadastro workflow
   → Coleta: Qual sua cidade?
   ↓
6. Usuário responde: "São Paulo"
   ↓
7. rpc_processar_mensagem() novamente
   ↓
8. Retorna:
   {
     "tipo": "EXECUTAR",
     "workflow_id": "motor1-corrida",
     "usuario": {
       "nome": "João",
       "cidade_id": "uuid-sp",
       "servicos_ativos": ["motor1"]
     }
   }
   ↓
9. N8N: Executa Motor 1: Corrida workflow
   → Processa corrida
```

## Performance

⚡ **Tempo de execução esperado**: 50-150ms

- Lookup usuário: ~5ms
- Lookup sessão: ~10ms
- Validações: ~20ms
- Consultas de tarifas: ~50ms
- Retorno JSONB: ~30ms

## Próximos Passos

- [ ] Executar no banco de produção
- [ ] Integrar no N8N Maestro
- [ ] Testes de carga (> 1000 msg/min)
- [ ] Monitorar timeouts de banco
- [ ] Backup automático de conversation_state
