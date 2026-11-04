// POST { action?: "status" } → { connected, charges_enabled, payouts_enabled, details_submitted, url? }
// Creates the creator's own Stripe account the first time (Accounts v2, Standard-style: they own it and its Dashboard) and returns a link to finish onboarding.
// Deploy normally. This has not been run against a live project.
import { connectOnboarding } from "../_shared/payments.ts";
import { makeDeps, notAllowed, respond, unauthorized, userIdFrom } from "../_shared/runtime.ts";

Deno.serve(async (request) => {
  if (request.method !== "POST") return notAllowed();
  const userId = await userIdFrom(request);
  if (!userId) return unauthorized();
  return respond(await connectOnboarding(makeDeps(), userId, await request.json().catch(() => null)));
});
