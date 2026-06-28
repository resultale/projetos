# Projetos N8N

## Motor 1: Corrida 🚗

Workflow N8N para gerenciar requisições de corrida. Estrutura base simples para receber dados do Maestro, processar e retornar confirmação.

### 📁 Estrutura

```
/workflows
  └── motor-1-corrida.json       # Workflow N8N completo em JSON
/docs
  ├── MOTOR1-CORRIDA.md          # Documentação detalhada
  └── TESTE-MOTOR1.md            # Guia de testes e exemplos
```

### ⚡ Quick Start

1. **Importar workflow**
   - Abra N8N
   - Import → `workflows/motor-1-corrida.json`

2. **Ativar workflow**
   - Clique em "Activate"

3. **Testar**
   ```bash
   curl -X POST http://localhost:5678/webhook/motor1-corrida \
     -H "Content-Type: application/json" \
     -d '{"p_telefone":"11999999999","p_mensagem":"Corrida","usuario":"user123"}'
   ```

### 📋 O que está incluído

✅ Webhook trigger para receber dados do Maestro  
✅ Log node para processar e registrar dados  
✅ Webhook response para retornar confirmação  
✅ Documentação completa  
✅ Exemplos de teste  

### 🚀 Próximas Fases

**Fase 2 - Persistência**
- PostgreSQL para armazenar corridas
- Validação de entrada
- Tratamento de erros

**Fase 3 - Inteligência**
- Google Maps API para rotas
- Cálculo de distância e tempo
- Estimativa de valor

**Fase 4 - Integração**
- Sistema de pagamento
- Notificações em tempo real
- Dashboard

### 📚 Referências

- [N8N Documentation](https://docs.n8n.io/)
- [Webhook Integration Guide](docs/MOTOR1-CORRIDA.md)
- [Testing Guide](docs/TESTE-MOTOR1.md)

---

**Status**: Base structure complete ✓  
**Versão**: 1.0.0  
**Data**: 2026-06-28
