// POST { card_id } → { removed: true }
// Removes one of the signed-in person's cards at Stripe and then here, and with it every permission that used it.
// Deploy normally (it checks the caller's JWT). This has not been run against a live project.
import { cardRemove } from "../_shared/cards.ts";
import { makeCardDeps, notAllowed, respond, unauthorized, userIdFrom } from "../_shared/runtime.ts";

Deno.serve(async (request) => {
  if (request.method !== "POST") return notAllowed();
  const userId = await userIdFrom(request);
  if (!userId) return unauthorized();
  return respond(await cardRemove(makeCardDeps(), userId, await request.json().catch(() => null)));
});
