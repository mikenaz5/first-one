// Stripe's webhook endpoint. Add it in the Stripe dashboard (Developers → Webhooks) with these events:
//   payment_intent.succeeded, payment_intent.payment_failed, refund.created, refund.updated, refund.failed,
//   charge.refund.updated, account.updated  (Connect events: turn on "Listen to events on Connected accounts"
//   only if you want account.updated for connected accounts to arrive here),
//   customer.subscription.created, customer.subscription.updated, customer.subscription.deleted  (company seat plans)
// Deploy with --no-verify-jwt: Stripe calls it, and the request is authenticated by Stripe's signature instead.
// This has not been run against a live project.
import { handleStripeWebhook } from "../_shared/payments.ts";
import { makeDeps, notAllowed, respond } from "../_shared/runtime.ts";

Deno.serve(async (request) => {
  if (request.method !== "POST") return notAllowed();
  const rawBody = await request.text(); // The signature is over the exact bytes, so read it as text, unparsed.
  return respond(await handleStripeWebhook(makeDeps(), rawBody, request.headers.get("stripe-signature")));
});
