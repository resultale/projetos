/**
 * TIO - Edge Function: webhook-asaas
 *
 * Recebe notificações do Asaas quando um PIX é confirmado.
 * Chama rpc_confirmar_pagamento_pix para atualizar a solicitação
 * e depois rpc_finalizar_servico se o serviço está pronto.
 *
 * Deploy: supabase functions deploy webhook-asaas --no-verify-jwt
 * Configurar no Asaas: Integrações → Webhooks → URL desta função
 */

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const ASAAS_WEBHOOK_TOKEN = Deno.env.get("ASAAS_WEBHOOK_TOKEN") ?? "";
const SUPABASE_URL        = Deno.env.get("SUPABASE_URL") ?? "";
const SUPABASE_SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

// Eventos que indicam pagamento confirmado no Asaas
const EVENTOS_PAGAMENTO = new Set([
  "PAYMENT_RECEIVED",
  "PAYMENT_CONFIRMED",
]);

Deno.serve(async (req: Request) => {
  // Valida token do webhook (header enviado pelo Asaas)
  const token = req.headers.get("asaas-access-token");
  if (ASAAS_WEBHOOK_TOKEN && token !== ASAAS_WEBHOOK_TOKEN) {
    return new Response("Unauthorized", { status: 401 });
  }

  if (req.method !== "POST") {
    return new Response("Method Not Allowed", { status: 405 });
  }

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return new Response("Bad Request", { status: 400 });
  }

  const evento = body.event as string;

  // Ignora eventos que não são de pagamento confirmado
  if (!EVENTOS_PAGAMENTO.has(evento)) {
    return new Response(JSON.stringify({ ignorado: true, evento }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  }

  const pagamento = body.payment as Record<string, unknown>;
  if (!pagamento) {
    return new Response("Bad Request: payment missing", { status: 400 });
  }

  const pixIdAsaas      = pagamento.id as string;
  const valor           = pagamento.value as number;
  // O externalReference deve ser o UUID da solicitacao,
  // definido ao criar o PIX dinâmico
  const solicitacaoId   = pagamento.externalReference as string;

  if (!solicitacaoId) {
    console.error("Webhook sem externalReference:", pixIdAsaas);
    return new Response(JSON.stringify({ erro: "externalReference ausente" }), {
      status: 200, // 200 para o Asaas não retentar
    });
  }

  const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_KEY);

  // Confirma pagamento e obtém dados da solicitação
  const { data: confirmacao, error: errConfirm } = await supabase.rpc(
    "rpc_confirmar_pagamento_pix",
    {
      p_pix_id_asaas:   pixIdAsaas,
      p_solicitacao_id: solicitacaoId,
      p_valor:          valor,
    }
  );

  if (errConfirm) {
    console.error("rpc_confirmar_pagamento_pix:", errConfirm);
    return new Response(JSON.stringify({ erro: errConfirm.message }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }

  if (confirmacao?.status === "ja_processado") {
    return new Response(JSON.stringify({ status: "ja_processado" }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  }

  // Para corridas e entregas (Motor 1), o PIX é pago antes do serviço.
  // A finalização e distribuição acontecem depois que o motorista conclui.
  // Para delivery (Motor 5), o estabelecimento precisa aceitar primeiro.
  // Apenas notificamos o N8N via Supabase Realtime (payload no canal).

  console.log("PIX confirmado:", {
    pixIdAsaas,
    solicitacaoId,
    valor,
    motor: confirmacao?.motor,
  });

  return new Response(
    JSON.stringify({ status: "ok", solicitacao_id: solicitacaoId }),
    {
      status: 200,
      headers: { "Content-Type": "application/json" },
    }
  );
});
