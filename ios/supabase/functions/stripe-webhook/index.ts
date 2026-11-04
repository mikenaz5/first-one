// Stripe's webhook endpoint for the PLATFORM's own events. Add it in the Stripe dashboard (Developers → Webhooks) as an endpoint
// for "Your account" (NOT "Connected accounts"), with these events:
//   customer.subscription.created, customer.subscription.updated, customer.subscription.deleted  (company seat plans),
//   payment_method.attached, payment_method.updated, payment_method.automatically_updated, payment_method.detached  (cards on file)
// Payments and refunds are direct charges on each creator's own Stripe account, so their events arrive at stripe-connect-webhook
// instead, signed with that endpoint's own secret.
// Deploy with --no-verify-jwt: Stripe calls it, and the request is authenticated by Stripe's signature instead.
// This has not been run against a live project.
import { handleStripeWebhook } from "../_shared/payments.ts";
import { makeDeps, notAllowed, respond } from "../_shared/runtime.ts";

Deno.serve(async (request) => {
  if (request.method !== "POST") return notAllowed();
  const rawBody = await request.text(); // The signature is over the exact bytes, so read it as text, unparsed.
  return respond(await handleStripeWebhook(makeDeps(), rawBody, request.headers.get("stripe-signature"), "platform"));
});
