// POST (no body) → { expired, drafts_removed, uploads_lapsed, warned, purged, skipped, waiting, errors }
// Ends deliveries whose 30 days are up, tidies drafts and uploads nobody finished, warns clients whose files are about to go,
// and deletes the bytes of everything that is gone from private storage. Run it on a schedule, once an hour is plenty
// (see "Slate Files" in ios/README.md). Safe to call as often as you like.
// Deploy with --no-verify-jwt: the caller is your scheduler, and it is authenticated inside the function by the service
// role key or PUSH_CRON_SECRET (the same one send-push takes). This has not been run against a live project.
import { expireFilesRequest } from "../_shared/files.ts";
import { makeFilesDeps, pushSecrets, respond } from "../_shared/runtime.ts";

Deno.serve(async (request) => {
  return respond(
    await expireFilesRequest(
      { method: request.method, authorization: request.headers.get("Authorization") },
      pushSecrets(),
      makeFilesDeps(),
    ),
  );
});
