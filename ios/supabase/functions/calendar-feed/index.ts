// GET /functions/v1/calendar-feed/<secret>.ics  →  a calendar file (text/calendar) for the person the secret belongs to.
// This is the address a person subscribes to from Apple Calendar, Google Calendar or Outlook (the app makes it: Profile ▸
// Settings ▸ Connect your calendar). It holds their bookings and the team events that are for them, and nothing else.
// Deploy with --no-verify-jwt: calendar apps can't send a login, so the secret in the address is the only gate. It is long
// and random, and the person can replace it at any time in the app, which stops the old address at once. This has not
// been run against a live project.
import { calendarFeedRequest } from "../_shared/calendar.ts";
import { makeCalendarDeps, respond } from "../_shared/runtime.ts";

Deno.serve(async (request) => {
  return respond(await calendarFeedRequest({ method: request.method, url: request.url }, makeCalendarDeps()));
});
