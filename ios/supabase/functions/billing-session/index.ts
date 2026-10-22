// POST { organization_id, action?: "checkout" | "portal" } → { kind, url }
// Opens a Stripe-hosted page for a company's seat plan: Checkout to start one, the billing portal to change the card,
// read invoices or cancel. Only the company's Owner may; the database decides. Open the returned url in the app's web
// authentication sheet. Deploy normally (with JWT verification). This has not been run against a live project.
import { billingSession } from "../_shared/billing.ts";
import { makeBillingDeps, notAllowed, respond, unauthorized, userIdFrom } from "../_shared/runtime.ts";

Deno.serve(async (request) => {
  if (request.method !== "POST") return notAllowed();
  const userId = await userIdFrom(request);
  if (!userId) return unauthorized();
  const deps = makeBillingDeps();
  if (!deps) return respond({ status: 503, body: { error: "billing_not_configured" } });
  return respond(await billingSession(deps, userId, await request.json().catch(() => null)));
});
