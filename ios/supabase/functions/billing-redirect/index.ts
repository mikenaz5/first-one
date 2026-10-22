// GET ?to=return|cancel → 302 to slate://billing/return or slate://billing/cancel
// Stripe only sends people back to https addresses, so Checkout and the billing portal come back here, and this hands
// them on to the app through its own URL scheme (which closes the in-app browser sheet).
// Deploy with --no-verify-jwt: it's a browser redirect with nothing secret in it.
import { billingRedirect } from "../_shared/billing.ts";
import { respond } from "../_shared/runtime.ts";

Deno.serve((request) => {
  const to = new URL(request.url).searchParams.get("to");
  return respond(billingRedirect(to, Deno.env.get("APP_URL_SCHEME") ?? "slate"));
});
