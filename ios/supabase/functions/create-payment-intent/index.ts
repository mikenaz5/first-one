// POST { booking_id, kind: "deposit" | "balance" } → { payment_id, client_secret, amount_cents, currency }
// Called by the app just before it shows the Apple Pay sheet. Deploy normally (it checks the caller's JWT).
// This has not been run against a live project.
import { createPaymentIntent } from "../_shared/payments.ts";
import { makeDeps, notAllowed, respond, unauthorized, userIdFrom } from "../_shared/runtime.ts";

Deno.serve(async (request) => {
  if (request.method !== "POST") return notAllowed();
  const userId = await userIdFrom(request);
  if (!userId) return unauthorized();
  return respond(await createPaymentIntent(makeDeps(), userId, await request.json().catch(() => null)));
});
