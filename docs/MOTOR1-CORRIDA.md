# Motor 1: Corrida - Workflow N8N

## Descrição
Workflow simples para processar requisições de corrida. Recebe dados do Maestro, registra em log e retorna uma confirmação.

## Estrutura do Workflow

```
Webhook (Trigger Maestro) 
    ↓
Log (Dados Recebidos)
    ↓
Webhook Response (Retorno ao Cliente)
```

## Nós

### 1. Webhook - Trigger Maestro
- **Tipo**: Webhook (n8n-nodes-base.webhook)
- **Endpoint**: `/motor1-corrida`
- **Método**: POST
- **Descrição**: Recebe dados do Maestro
- **Input esperado**:
  ```json
  {
    "p_telefone": "string",
    "p_mensagem": "string",
    "usuario": "string"
  }
  ```

### 2. Log - Dados Recebidos
- **Tipo**: Function (n8n-nodes-base.function)
- **Descrição**: Processa e registra os dados recebidos
- **Output**: Adiciona timestamp e mensagem de confirmação

### 3. Webhook Response - Retorno
- **Tipo**: Respond to Webhook (n8n-nodes-base.respondToWebhook)
- **Descrição**: Retorna resposta ao cliente
- **Output**:
  ```json
  {
    "status": "sucesso",
    "mensagem": "Requisição processada com sucesso",
    "dados": {
      "telefone": "{{ $json.p_telefone }}",
      "usuario": "{{ $json.usuario }}",
      "timestamp": "{{ $now.toISOString() }}"
    }
  }
  ```

## Como Usar

### 1. Importar o Workflow
- Abra a interface N8N
- Clique em "Import from file"
- Selecione `motor-1-corrida.json`
- Ative o workflow

### 2. Testar com cURL
```bash
curl -X POST http://localhost:5678/webhook/motor1-corrida \
  -H "Content-Type: application/json" \
  -d '{
    "p_telefone": "11999999999",
    "p_mensagem": "Corrida solicitada",
    "usuario": "user123"
  }'
```

### 3. Resposta Esperada
```json
{
  "status": "sucesso",
  "mensagem": "Requisição processada com sucesso",
  "dados": {
    "telefone": "11999999999",
    "usuario": "user123",
    "timestamp": "2026-06-28T10:30:45.123Z"
  }
}
```

## Próximos Passos (Fase 2)
- [ ] Integração com PostgreSQL para persistir dados
- [ ] Integração com Google Maps para cálculo de rota
- [ ] Validação de entrada (telefone, usuário)
- [ ] Tratamento de erros
- [ ] Integração com sistema de pagamento
- [ ] Notificações em tempo real

## Notas
- Workflow está **desativado** por padrão
- Sem persistência de dados no momento
- Respostas configuradas manualmente (sem banco de dados)
- Pronto para fase 2 de desenvolvimento
