# Testes - Motor 1: Corrida

## Exemplos de Requisição

### Exemplo 1: Corrida Simples
```bash
curl -X POST http://localhost:5678/webhook/motor1-corrida \
  -H "Content-Type: application/json" \
  -d '{
    "p_telefone": "11999999999",
    "p_mensagem": "Corrida solicitada",
    "usuario": "user123"
  }'
```

**Resposta esperada**:
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

---

### Exemplo 2: Usuário Diferente
```bash
curl -X POST http://localhost:5678/webhook/motor1-corrida \
  -H "Content-Type: application/json" \
  -d '{
    "p_telefone": "21987654321",
    "p_mensagem": "Corrida urgente",
    "usuario": "user456"
  }'
```

---

### Exemplo 3: Com Dados Adicionais (extras ignorados)
```bash
curl -X POST http://localhost:5678/webhook/motor1-corrida \
  -H "Content-Type: application/json" \
  -d '{
    "p_telefone": "85988776655",
    "p_mensagem": "Corrida noturna",
    "usuario": "user789",
    "origem": "Avenida Paulista",
    "destino": "Rua Augusta",
    "estimativa": 15
  }'
```

---

## Teste com Postman

1. **Criar nova requisição**
   - Método: `POST`
   - URL: `http://localhost:5678/webhook/motor1-corrida`

2. **Headers**
   ```
   Content-Type: application/json
   ```

3. **Body (raw JSON)**
   ```json
   {
     "p_telefone": "11999999999",
     "p_mensagem": "Corrida solicitada",
     "usuario": "user123"
   }
   ```

4. **Send** e verificar a resposta

---

## Teste em Node.js

```javascript
const axios = require('axios');

const data = {
  p_telefone: "11999999999",
  p_mensagem: "Corrida solicitada",
  usuario: "user123"
};

axios.post('http://localhost:5678/webhook/motor1-corrida', data)
  .then(response => {
    console.log('✓ Sucesso:', response.data);
  })
  .catch(error => {
    console.error('✗ Erro:', error.message);
  });
```

---

## Verificar Execução no N8N

1. Abra a interface N8N (`http://localhost:5678`)
2. Selecione o workflow "Motor 1: Corrida"
3. Clique em "Executions" (Execuções)
4. Veja os logs e dados processados
5. Verifique se os nós foram executados na ordem correta

---

## Checklist de Teste

- [ ] Webhook recebe POST corretamente
- [ ] Dados chegam no Log Node
- [ ] Timestamp é gerado
- [ ] Response retorna status 200
- [ ] JSON response contém dados corretos
- [ ] Telefone e usuário aparecem na resposta
- [ ] Workflow completa sem erros

---

## Preparação para Fase 2

Antes de adicionar PostgreSQL e Google Maps:

1. Confirmar que o Maestro consegue fazer POST para este endpoint
2. Validar estrutura dos dados que chegam do Maestro
3. Testar com diferentes tipos de entrada
4. Preparar schema do banco de dados
5. Documentar integração com outros serviços
