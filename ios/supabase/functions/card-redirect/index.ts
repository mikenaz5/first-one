// GET ?to=return|cancel → 302 to slate://cards/return or slate://cards/cancel
// Stripe only sends people back to https addresses, so the page where a card is typed comes back here, and this hands them
// on to the app through its own URL scheme (which closes the in-app browser sheet).
// Deploy with --no-verify-jwt: it's a browser redirect with nothing secret in it.
import { cardRedirect } from "../_shared/cards.ts";
import { respond } from "../_shared/runtime.ts";

Deno.serve((request) => {
  const to = new URL(request.url).searchParams.get("to");
  return respond(cardRedirect(to, Deno.env.get("APP_URL_SCHEME") ?? "slate"));
});
