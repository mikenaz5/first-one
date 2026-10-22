// POST { booking_id } → { refunds: [{ refund_id, status }] }
// Called by the app after a cancellation to send the refunds the database says are owed to Stripe.
// Safe to call again: refunds that failed to reach Stripe stay pending. Deploy normally.
// This has not been run against a live project.
import { processRefundsRequest } from "../_shared/payments.ts";
import { makeDeps, notAllowed, respond, unauthorized, userIdFrom } from "../_shared/runtime.ts";

Deno.serve(async (request) => {
  if (request.method !== "POST") return notAllowed();
  const userId = await userIdFrom(request);
  if (!userId) return unauthorized();
  return respond(await processRefundsRequest(makeDeps(), userId, await request.json().catch(() => null)));
});
