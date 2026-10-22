// POST (no body) → { reminders_queued, claimed, delivered, retrying, devices_sent, devices_removed }
// Queues shoot reminders that are due, then sends every push notification waiting in the database through APNs.
// Run it on a schedule (see "Turning on notifications" in ios/README.md). Safe to call as often as you like.
// Deploy with --no-verify-jwt: the caller is your scheduler, and it is authenticated inside the function by the
// service role key or PUSH_CRON_SECRET. This has not been run against a live project or Apple's servers.
import { sendPushRequest } from "../_shared/push.ts";
import { makePushDeps, pushSecrets, respond } from "../_shared/runtime.ts";

Deno.serve(async (request) => {
  const result = await sendPushRequest(
    { method: request.method, authorization: request.headers.get("Authorization") },
    pushSecrets(),
    makePushDeps(),
  );
  return respond(result);
});
