// POST (no body) → { url }
// Returns a Stripe-hosted page where the signed-in person types a card to keep on file. Open it in the app's web
// authentication sheet; Stripe sends them back through card-redirect. Nothing is charged, and Slate Pro never sees the
// card. Deploy normally (it checks the caller's JWT). This has not been run against a live project.
import { cardSetup } from "../_shared/cards.ts";
import { makeCardDeps, notAllowed, respond, unauthorized, userIdFrom } from "../_shared/runtime.ts";

Deno.serve(async (request) => {
  if (request.method !== "POST") return notAllowed();
  const userId = await userIdFrom(request);
  if (!userId) return unauthorized();
  return respond(await cardSetup(makeCardDeps(), userId));
});
