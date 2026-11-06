// POST { signedPayload } from the App Store (App Store Server Notifications, version 2).
// Apple calls this when a plan renews, a payment fails, a person turns renewal off, a purchase is refunded or a
// subscription ends. In App Store Connect (the app, then App Information, then App Store Server Notifications) set both the
// Production and the Sandbox server URL to this function's address, and choose Version 2.
// Deploy with --no-verify-jwt: Apple sends no Supabase login. The signature on the message is the credential, and nothing
// is done until it checks out against Apple's certificate. This has not been run against a live project.
import { appleNotification } from "../_shared/apple_plan.ts";
import { makeAppleDeps, notAllowed, respond } from "../_shared/runtime.ts";

Deno.serve(async (request) => {
  if (request.method !== "POST") return notAllowed();
  return respond(await appleNotification(makeAppleDeps(), await request.json().catch(() => null)));
});
