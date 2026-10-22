// GET ?to=return|refresh → 302 to slate://stripe/<to>
// Stripe sends people back to an https address after onboarding; this passes them on to the app.
// Deploy with --no-verify-jwt (a browser follows this link, with no app token).
// This has not been run against a live project.
import { connectRedirect } from "../_shared/payments.ts";
import { respond } from "../_shared/runtime.ts";

Deno.serve((request) => {
  const to = new URL(request.url).searchParams.get("to");
  return respond(connectRedirect(to, Deno.env.get("APP_URL_SCHEME") ?? "slate"));
});
