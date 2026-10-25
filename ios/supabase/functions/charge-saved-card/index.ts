// POST { booking_id } → { payment_id, status: "succeeded" | "processing", amount_cents, currency }
// Charges the balance of a booking to the client's saved card, for a creator the client has allowed. Whoever can manage the
// booking may ask; the database works out the amount and finds the card, and refuses if the client hasn't allowed this
// creator, the balance isn't payable yet, or it is already paid. What happened is recorded when Stripe's webhook says so.
// Deploy normally (it checks the caller's JWT). This has not been run against a live project.
import { chargeSavedCard } from "../_shared/cards.ts";
import { makeCardDeps, notAllowed, respond, unauthorized, userIdFrom } from "../_shared/runtime.ts";

Deno.serve(async (request) => {
  if (request.method !== "POST") return notAllowed();
  const userId = await userIdFrom(request);
  if (!userId) return unauthorized();
  return respond(await chargeSavedCard(makeCardDeps(), userId, await request.json().catch(() => null)));
});
