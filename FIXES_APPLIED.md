# Fixes Applied to WF_ENTREGA (2026-07-24)

## Issue 1: Agent_tio Red Error - "No prompt specified"

### Root Cause
The Agent_tio node's text parameter was using an incorrect expression syntax:
```
{{ $('execute').first().json.rpc_contexto.conteudo_msg || ... }}
```

This expression was not resolving properly in the context of the agent node, causing a red error state even when manually edited.

### Fix Applied
Changed the expression to use `$json` which properly references the current item's data:
```
{{ $json.rpc_contexto.conteudo_msg || "(O usuário enviou uma localização ou mídia sem texto. Analise o estado e continue a coleta.)" }}
```

**Result**: Agent node now properly resolves the user message from the incoming data flow.

---

## Issue 2: Looping Address Validation - "não esta localizando o endereço"

### Root Cause
The Validar_Endereco_Google node had `retryOnFail: true` configuration, which was causing:
1. When Google Maps API returns ZERO_RESULTS, the node retries automatically
2. The retry mechanism causes pairedItem indexing corruption (same bug as Sanitizar_Memoria)
3. The agent gets stuck asking for the address repeatedly without progress

### Fix Applied
Disabled the `retryOnFail: true` setting on Validar_Endereco_Google node.

**Result**: When address validation fails (ZERO_RESULTS), the agent now properly handles the error and asks the user for the address again, instead of looping infinitely.

---

## Related Configuration Changes

Both fixes follow the same pattern we discovered and fixed in earlier iterations:
- Removed `retryOnFail: true` from Sanitizar_Memoria (previous fix)
- Now removed `retryOnFail: true` from Validar_Endereco_Google (current fix)

These retry configurations with n8n's pairedItem indexing can cause data flow corruption. Better to let the agent/downstream nodes handle failures gracefully.

---

## Testing

After these fixes, the WF_ENTREGA workflow should:
1. ✅ Agent_tio no longer shows red error
2. ✅ Agent can properly access the user message
3. ✅ Address validation handles failures without looping
4. ✅ Full delivery flow works end-to-end

Test by triggering a delivery request through the normal flow.
