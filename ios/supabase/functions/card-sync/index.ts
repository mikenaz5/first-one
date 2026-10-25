// POST (no body) → { cards, removed }
// Makes the person's cards here match the ones Stripe has: records new ones, forgets ones Stripe no longer has. The app
// calls it when it comes back from Stripe's page (the webhook may be a moment behind) and when the cards screen opens.
// Deploy normally (it checks the caller's JWT). This has not been run against a live project.
import { cardSync } from "../_shared/cards.ts";
import { makeCardDeps, notAllowed, respond, unauthorized, userIdFrom } from "../_shared/runtime.ts";

Deno.serve(async (request) => {
  if (request.method !== "POST") return notAllowed();
  const userId = await userIdFrom(request);
  if (!userId) return unauthorized();
  return respond(await cardSync(makeCardDeps(), userId));
});
