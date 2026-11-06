// POST { organization_id, signed_transaction, signed_renewal_info? } → { status, seats, state }
// The app calls this after the Owner buys the company plan with Apple's purchase sheet, and again whenever it sees the
// current purchase (when billing opens, when a renewal arrives while the app is open). It hands over what Apple signed;
// the server checks Apple's signature itself and records the plan. The app can never mark a plan paid by saying so.
// Deploy normally (with JWT verification): only the signed-in Owner of that company may call it. This has not been run
// against a live project.
import { appleVerify } from "../_shared/apple_plan.ts";
import { makeAppleDeps, notAllowed, respond, unauthorized, userIdFrom } from "../_shared/runtime.ts";

Deno.serve(async (request) => {
  if (request.method !== "POST") return notAllowed();
  const userId = await userIdFrom(request);
  if (!userId) return unauthorized();
  return respond(await appleVerify(makeAppleDeps(), userId, await request.json().catch(() => null)));
});
