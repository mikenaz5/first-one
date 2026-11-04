// Stripe's webhook endpoint for events on creators' CONNECTED accounts: where payments and refunds are reported. Add it in the
// Stripe dashboard (Developers → Webhooks) as an endpoint for "Connected accounts" ("Listen to events on Connected accounts"),
// with these events:
//   payment_intent.succeeded, payment_intent.payment_failed, refund.created, refund.updated, refund.failed, charge.refund.updated
// and set the signing secret it shows as STRIPE_CONNECT_WEBHOOK_SECRET. A booking is marked deposit paid only from here.
// Deploy with --no-verify-jwt: Stripe calls it, and the request is authenticated by Stripe's signature instead.
// This has not been run against a live project.
import { handleStripeWebhook } from "../_shared/payments.ts";
import { makeDeps, notAllowed, respond } from "../_shared/runtime.ts";

Deno.serve(async (request) => {
  if (request.method !== "POST") return notAllowed();
  const rawBody = await request.text(); // The signature is over the exact bytes, so read it as text, unparsed.
  return respond(await handleStripeWebhook(makeDeps(), rawBody, request.headers.get("stripe-signature"), "connect"));
});
