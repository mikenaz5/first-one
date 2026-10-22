// POST (no body) → { updated, cancelled, failed }
// Pushes seat changes to Stripe (more seats are charged at once, fewer lower the next invoice), ends the plans of
// companies that were closed, and makes companies whose payment is overdue past the grace period read only.
// Run it on a schedule (see "Turning on seat billing" in ios/README.md). Safe to call as often as you like.
// Deploy with --no-verify-jwt: the caller is your scheduler, authenticated inside the function by the service role
// key or PUSH_CRON_SECRET. This has not been run against a live project.
import { billingSyncRequest } from "../_shared/billing.ts";
import { makeBillingDeps, pushSecrets, respond } from "../_shared/runtime.ts";

Deno.serve(async (request) => {
  return respond(
    await billingSyncRequest(
      { method: request.method, authorization: request.headers.get("Authorization") },
      pushSecrets(),
      makeBillingDeps(),
    ),
  );
});
