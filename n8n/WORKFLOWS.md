# TIO - N8N Workflows

## Visão geral

O N8N é o orquestrador central do TIO. Todo fluxo começa com uma
mensagem WhatsApp chegando via Evolution API e termina com uma
resposta enviada de volta.

```
Evolution API
  └── Webhook → N8N: Maestro Workflow
                  ├── rpc_obter_usuario (Supabase)
                  ├── rpc_obter_ou_criar_sessao
                  └── Roteamento → Subworkflow do Motor
                                    └── RPCs Supabase
                                    └── Evolution API (resposta)
```

---

## Workflow 0: Maestro (Entry Point)

**Trigger:** Webhook recebido da Evolution API
**URL do webhook:** `/webhook/tio-maestro`

### Nós em ordem

```
1. Webhook (POST)
   Extrai: pushname, telefone, mensagem, instancia

2. HTTP Request → rpc_atualizar_pushname
   Body: { p_telefone, p_pushname }

3. HTTP Request → rpc_obter_usuario
   Body: { p_telefone: "{{$json.telefone}}" }
   Salva: usuario (objeto completo)

4. IF: usuario.encontrado = false
   TRUE  → Subworkflow: Onboarding
   FALSE → Continuar

5. IF: usuario.bloqueado = true
   TRUE  → Enviar msg "Sua conta está bloqueada..."
   FALSE → Continuar

6. HTTP Request → rpc_obter_ou_criar_sessao
   Body: { p_usuario_id: "{{usuario.id}}" }
   Salva: sessao

7. IF: sessao.motor_atual != null
   TRUE  → Continuar sessão do motor em andamento
            Switch por sessao.motor_atual → Subworkflow correspondente
   FALSE → Reconhecimento de intenção (passo 8)

8. Code Node: Reconhece intenção da mensagem
   Lógica de palavras-chave / regex:
   - "moto|corrida|carro|uber"         → motor_1_corrida
   - "entrega|entregar"                → motor_1_entrega
   - "carona|vou pra|viagem"           → motor_2_carona
   - "cortar|barbearia|cabelo|salão"   → motor_3_servico
   - "encanador|eletricista|reparo"    → motor_4_reparo
   - "pizza|hamburguer|comida|delivery"→ motor_5_delivery
   - else                              → menu_principal

9. Switch: intent_detectada
   ├── motor_1_corrida  → Subworkflow Motor 1A
   ├── motor_1_entrega  → Subworkflow Motor 1B
   ├── motor_2_carona   → Subworkflow Motor 2
   ├── motor_3_servico  → Subworkflow Motor 3
   ├── motor_4_reparo   → Subworkflow Motor 4
   ├── motor_5_delivery → Subworkflow Motor 5
   └── menu_principal   → Envia menu completo
```

---

## Workflow 0A: Onboarding

Chamado pelo Maestro quando usuário não existe.

```
1. HTTP Request → rpc_verificar_cidade
   Body: { p_nome: "{{mensagem}}" }

2. IF: cidade.ativa = true
   TRUE  → Fluxo onboarding completo (passos 3-9)
   FALSE → IF cidade.encontrada = true
             TRUE → rpc_registrar_interesse + mensagem de espera
             FALSE → Pede nova cidade

3. Envia: "Qual é seu nome completo?"
   Aguarda resposta → salva p_nome

4. Envia: "Qual seu sexo? 👨 Masculino | 👩 Feminino | ⭐ Prefiro..."
   Aguarda resposta → salva p_sexo

5. Envia: "Qual seu endereço? (Rua, número, complemento)"
   Aguarda resposta

6. HTTP Request → Google Maps Geocoding API
   Input: endereço + cidade
   Salva: lat, lng, endereco_formatado

7. Envia confirmação do endereço → aguarda SIM/NÃO
   NÃO → volta ao passo 5

8. Envia: "Como chamar esse endereço? 🏠 Casa | 💼 Trabalho | 🏋️ Academia | ⭐ Outro"
   Aguarda resposta → salva p_tipo_endereco

9. Code Node: Gera hash bcrypt da senha padrão
   (Senha inicial = últimos 4 dígitos do telefone ou aleatória)

10. HTTP Request → rpc_criar_usuario
    Body: { p_telefone, p_pushname, p_nome, p_sexo,
            p_cidade_id, p_cidade_nome, p_senha (hash),
            p_tipo_endereco, p_endereco, p_numero, p_complemento,
            p_latitude, p_longitude }

11. Envia mensagem de boas-vindas com menu completo
```

---

## Workflow 1A: Motor Aceite Direto — Corrida

```
FASE 1: Coleta de dados
1. Detecta tipo de veículo: moto / carro econômico / confort / premium
2. Identifica endereço de origem:
   - Se mensagem menciona "em casa" / "aqui" → usa endereço principal
   - Senão → pede endereço ou usa menção direta
3. Identifica endereço de destino da mensagem

FASE 2: Cálculo
4. HTTP Request → Google Maps Directions API
   Obtém: distancia_km, tempo_estimado_min
5. HTTP Request → rpc_calcular_tarifa
   Body: { p_motor: "aceite_direto", p_tipo_servico: "corrida_moto|corrida_carro",
           p_distancia_km, p_cidade_id }
6. Envia resumo com valor e pergunta forma de pagamento
7. IF forma = pix:
     HTTP Request → Asaas: POST /payments (PIX dinâmico)
     Salva: pix_id, qr_code, copia_cola
     Envia QR Code e copia-e-cola
     Aguarda webhook de confirmação (Supabase Realtime ou polling)
   IF forma = dinheiro/cartão:
     Confirma pedido

FASE 3: Solicitação e aceite
8. HTTP Request → rpc_criar_solicitacao
   dados: { origem, destino, distancia_km, valor, forma_pagamento,
             pix_id_asaas (se pix), lat/lng de origem e destino }
9. HTTP Request → rpc_buscar_executores_proximos
   Envia notificação WhatsApp para até 10 motoristas próximos
10. Aguarda aceite do primeiro motorista
    HTTP Request → rpc_aceitar_solicitacao
11. Notifica cliente com dados do motorista aceito

FASE 4: Durante trajeto (moto somente)
12. Timer: 5 min antes do destino estimado
    HTTP Request → busca promoções ativas no raio de 500m do destino
    IF promoção encontrada → envia sugestão pro cliente

FASE 5: Finalização
13. Motorista sinaliza chegada
    HTTP Request → rpc_finalizar_servico
14. Notifica cliente: cashback ganho (se PIX), saldo TioPay
15. Envia solicitação de avaliação
16. IF avaliação dada → rpc_avaliar_usuario
```

---

## Workflow 1B: Motor Aceite Direto — Entrega

```
1. Coleta endereço de origem e destino
2. Pergunta se precisa de código de confirmação
3. HTTP Request → rpc_calcular_tarifa (tipo_servico: 'entrega')
4. Forma de pagamento → PIX dinâmico se escolhido
5. HTTP Request → rpc_criar_solicitacao
   Code Node: gera codigo_confirmacao (4 dígitos) e token
6. INSERT na tabela entregas com código gerado
7. Busca entregadores → rpc_buscar_executores_proximos
8. Notifica entregadores
9. rpc_aceitar_solicitacao
10. Quando entregador chega no destino:
    Exibe código para o destinatário confirmar
11. rpc_finalizar_servico
    IF pagamento dinheiro/cartão → rpc_processar_troco_digital
```

---

## Workflow 2: Motor Carona Compartilhada

### Publicar (motorista)

```
1. Detecta intenção de publicar carona
2. Coleta: destino, data, hora, total_vagas, valor_total
3. HTTP Request → Google Maps → km_total + paradas sugeridas
4. Confirma resumo com motorista
5. rpc_publicar_carona
6. Envia confirmação com ID da carona
```

### Buscar (passageiro)

```
1. Detecta busca de carona
2. Coleta: origem, destino, data preferida
3. HTTP Request → rpc_buscar_caronas
4. IF caronas encontradas:
   Exibe lista com motorista, horário, vagas e preço
5. Passageiro escolhe → calcula trecho via rpc_calcular_trecho_carona
6. Notifica motorista para confirmar
7. Motorista confirma → gera PIX → passageiro paga
8. rpc_entrar_carona
```

---

## Workflow 3: Motor Oferta e Agendamento (Serviços)

```
1. Identifica tipo de serviço (barbearia, salão, massagem...)
2. Coleta: período preferido (manhã / tarde / noite)
   NÃO perguntar horário exato — o prestador que sugere
3. rpc_buscar_prestadores (tipo_servico, cidade_id)
4. Exibe até 3 opções com rating e preço estimado
5. Cliente escolhe prestador
6. rpc_criar_agendamento (motor: 'oferta_agendamento')
7. Notifica prestador via WhatsApp:
   "Cliente quer [serviço] [período]. Confirma? [OK] [RECUSAR]"
8. Prestador responde com horário disponível
9. rpc_confirmar_agendamento (com dados_resposta.horario_confirmado)
10. Notifica cliente:
    "Confirmado! [Prestador] às [horário]. Ao chegar diga 'quero pagar com TIO'"
    Detalha cashback que vai ganhar se pagar com PIX
```

---

## Workflow 4: Motor Indicação e Orçamento (Reparos)

```
1. Identifica problema (chuveiro, pia, elétrica, pintura...)
2. Conversa natural para coletar mais detalhes:
   - Qual exatamente o problema?
   - É elétrico ou hidráulico? (para chuveiro)
   - Quantos cômodos? (para pintura)
3. Determina tipo de profissional necessário (eletricista/encanador/pintor)
4. rpc_buscar_prestadores (tipo_servico determinado)
5. Exibe opções com especialidade e rating
6. Cliente escolhe
7. rpc_criar_agendamento (motor: 'indicacao_orcamento')
   dados: { descricao_problema, tipo_profissional }
8. Notifica prestador:
   "Cliente tem problema: [descrição]. Quer fazer orçamento?
    [OK — propor horário] [RECUSAR]"
9. Prestador propõe horário para visita
10. rpc_confirmar_agendamento
11. Notifica cliente com horário confirmado
```

---

## Workflow 5: Motor Delivery Inteligente

```
FASE 1: Entendendo o pedido (conversa natural)
1. Extrai tipo de comida da mensagem
2. rpc_buscar_estabelecimentos (tipo, cidade_id)
3. IF não encontrar exato → sugere opções similares
4. Exibe estabelecimentos com rating, tempo e taxa
5. Cliente escolhe

FASE 2: Montando o pedido
6. rpc_buscar_itens_cardapio com busca pelo que cliente mencionou
7. Exibe itens encontrados com preço
8. Cross-sell: sugere 1 item complementar ("combina muito com...")
9. Cliente confirma pedido

FASE 3: Entrega ou retirada
10. Pergunta: "Entregar em casa ou você vai buscar?"
    Casa → usa endereço principal (ou pede confirmação)
    Buscar → avança sem taxa de entrega

FASE 4: Pagamento
11. Mostra resumo: itens + taxa entrega + total
12. Pergunta forma de pagamento
    PIX → destaca cashback que vai ganhar
    Dinheiro → pergunta se precisa troco, qual nota
13. IF PIX:
      Asaas POST /payments → QR Code
      Aguarda webhook confirmação
14. rpc_criar_pedido_delivery

FASE 5: Acompanhamento
15. Notifica estabelecimento via WhatsApp
16. rpc_aceitar_pedido_delivery (aguarda resposta)
17. Quando estabelecimento aceita:
    Notifica cliente: "Seu pedido foi aceito! Preparando..."
18. Estabelecimento sinaliza que saiu para entrega
    rpc_despachar_pedido
    Notifica cliente com nome do entregador
19. Entregador confirma entrega
    IF dinheiro E troco pedido:
      rpc_processar_troco_digital
    rpc_finalizar_servico
20. Notifica cliente: troco em TioPay / cashback
```

---

## Variáveis de Ambiente N8N

```
SUPABASE_URL=https://xxxx.supabase.co
SUPABASE_SERVICE_KEY=eyJ...
EVOLUTION_API_URL=http://seu-evolution:8080
EVOLUTION_API_KEY=sua-chave
EVOLUTION_INSTANCE=tio-prod
GOOGLE_MAPS_API_KEY=AIza...
ASAAS_API_KEY=sua-chave-asaas
ASAAS_BASE_URL=https://api.asaas.com/v3
```

## Chamando RPCs pelo N8N

Use o nó **HTTP Request** com:

```
Method: POST
URL:    {{$env.SUPABASE_URL}}/rest/v1/rpc/rpc_nome_da_funcao
Headers:
  apikey:        {{$env.SUPABASE_SERVICE_KEY}}
  Authorization: Bearer {{$env.SUPABASE_SERVICE_KEY}}
  Content-Type:  application/json
Body: { "p_parametro": "valor" }
```

## Enviando mensagem WhatsApp pelo N8N

```
Method: POST
URL:    {{$env.EVOLUTION_API_URL}}/message/sendText/{{$env.EVOLUTION_INSTANCE}}
Headers:
  apikey: {{$env.EVOLUTION_API_KEY}}
Body:
{
  "number": "{{telefone}}",
  "text": "Sua mensagem aqui"
}
```
