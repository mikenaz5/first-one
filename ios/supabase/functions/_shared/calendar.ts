// The calendar link behind the `calendar-feed` Edge Function, as plain functions that take their dependencies as
// arguments, so Node can test them with fakes (see function-tests/calendar.test.ts).
//
// What lives where:
//   - Who a secret belongs to, which bookings and team events are theirs, and what is left out (money, contracts, notes
//     of a booking, contact details) are decided in SQL (…_team_events.sql, `calendar_feed_data`), which is tested against
//     a real Postgres.
//   - This file turns that data into an iCalendar file (RFC 5545) that Apple Calendar, Google Calendar, Outlook and others
//     can subscribe to, and answers the request. Reading is the only thing a link can do.
//   - _shared/runtime.ts connects it to the real database. That has never been run against a live project.
//
// Only erasable TypeScript syntax is used (no enums or parameter properties) so Node can run it directly.

import type { Db, HttpResult } from "./payments.ts";

export interface CalendarDeps {
  db: Db;
  now: () => Date;
  log: (message: string, detail?: unknown) => void;
}

export interface FeedBooking {
  id: string;
  package_name: string;
  start_at: string;
  end_at: string;
  time_zone: string;
  /** "provider" for the person doing the job, "client" for the person who booked. */
  role: string;
  client_name: string;
  creator_name: string;
  status: string;
}

export interface FeedEvent {
  id: string;
  title: string;
  notes: string;
  location: string;
  starts_at: string;
  ends_at: string;
  all_day: boolean;
  organization_name: string;
  time_zone: string;
  updated_at: string;
}

export interface FeedData {
  bookings: FeedBooking[];
  events: FeedEvent[];
}

/** UIDs must be globally unique and never change for the same booking or event. */
export const UID_DOMAIN = "slateproapp.com";
const TOKEN = /([0-9a-f]{32})(?:\.ics)?\/?$/i;

/** The secret in a request address: the last part of the path (with or without ".ics"), or a `token` query. */
export function tokenFrom(address: string): string | null {
  let url: URL;
  try {
    url = new URL(address);
  } catch {
    return null;
  }
  const fromPath = TOKEN.exec(url.pathname);
  if (fromPath) return fromPath[1].toLowerCase();
  const fromQuery = url.searchParams.get("token");
  return fromQuery && /^[0-9a-f]{32}$/i.test(fromQuery) ? fromQuery.toLowerCase() : null;
}

// ---------------------------------------------------------------------------
// Writing iCalendar
// ---------------------------------------------------------------------------

/** Text values: backslash, semicolon, comma and line breaks are escaped; control characters are dropped. */
export function escapeText(text: string): string {
  return text
    .replace(/\r\n?/g, "\n")
    // deno-lint-ignore no-control-regex
    .replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/g, "")
    .replace(/\\/g, "\\\\")
    .replace(/;/g, "\\;")
    .replace(/,/g, "\\,")
    .replace(/\n/g, "\\n");
}

/** Lines are at most 75 octets: longer ones continue on the next line after CRLF and a space. No character is split. */
export function foldLine(line: string): string {
  const encoder = new TextEncoder();
  if (encoder.encode(line).length <= 75) return line;
  const parts: string[] = [];
  let current = "";
  let size = 0;
  let limit = 75;
  for (const character of line) {
    const width = encoder.encode(character).length;
    if (size + width > limit) {
      parts.push(current);
      current = "";
      size = 0;
      limit = 74; // the leading space of a continuation line counts
    }
    current += character;
    size += width;
  }
  parts.push(current);
  return parts.join("\r\n ");
}

function pad(value: number, width = 2): string {
  return String(value).padStart(width, "0");
}

/** A moment as UTC: 20270114T153000Z. */
export function icsDateTime(iso: string): string {
  const d = new Date(iso);
  return `${pad(d.getUTCFullYear(), 4)}${pad(d.getUTCMonth() + 1)}${pad(d.getUTCDate())}T${pad(d.getUTCHours())}${pad(d.getUTCMinutes())}${pad(d.getUTCSeconds())}Z`;
}

interface LocalParts {
  year: number;
  month: number;
  day: number;
  hour: number;
  minute: number;
}

function localParts(iso: string, timeZone: string): LocalParts {
  let zone = timeZone;
  try {
    new Intl.DateTimeFormat("en-US", { timeZone: zone });
  } catch {
    zone = "UTC";
  }
  const formatter = new Intl.DateTimeFormat("en-US", {
    timeZone: zone, hourCycle: "h23", year: "numeric", month: "numeric", day: "numeric", hour: "numeric", minute: "numeric",
  });
  const out: Record<string, number> = {};
  for (const part of formatter.formatToParts(new Date(iso))) {
    if (part.type !== "literal") out[part.type] = Number(part.value);
  }
  return { year: out.year, month: out.month, day: out.day, hour: out.hour, minute: out.minute };
}

/** The calendar date (YYYYMMDD) a moment falls on in a time zone. */
export function icsLocalDate(iso: string, timeZone: string): string {
  const p = localParts(iso, timeZone);
  return `${pad(p.year, 4)}${pad(p.month)}${pad(p.day)}`;
}

/** An all-day event ends on the date after its last day; an end that isn't at midnight rounds up to the next date. */
export function icsAllDayEnd(iso: string, timeZone: string): string {
  const p = localParts(iso, timeZone);
  const date = icsLocalDate(iso, timeZone);
  if (p.hour === 0 && p.minute === 0) return date;
  const next = new Date(Date.UTC(p.year, p.month - 1, p.day) + 86_400_000);
  return `${pad(next.getUTCFullYear(), 4)}${pad(next.getUTCMonth() + 1)}${pad(next.getUTCDate())}`;
}

function line(lines: string[], name: string, value: string): void {
  lines.push(foldLine(`${name}:${value}`));
}

/** The whole calendar file for one person. */
export function buildCalendar(data: FeedData, now: Date): string {
  const stamp = icsDateTime(now.toISOString());
  const lines: string[] = [];
  lines.push("BEGIN:VCALENDAR");
  lines.push("VERSION:2.0");
  lines.push("PRODID:-//Slate Pro//Calendar//EN");
  lines.push("CALSCALE:GREGORIAN");
  lines.push("METHOD:PUBLISH");
  lines.push("X-WR-CALNAME:Slate Pro");
  // Calendar apps decide for themselves how often to look again; these are the hints they take.
  lines.push("X-PUBLISHED-TTL:PT1H");
  lines.push("REFRESH-INTERVAL;VALUE=DURATION:PT1H");

  for (const booking of data.bookings) {
    const provider = booking.role === "provider";
    const summary = provider
      ? `${booking.package_name}: ${booking.client_name.trim() === "" ? "Client" : booking.client_name}`
      : `${booking.package_name} with ${booking.creator_name}`;
    lines.push("BEGIN:VEVENT");
    line(lines, "UID", `booking-${booking.id}@${UID_DOMAIN}`);
    line(lines, "DTSTAMP", stamp);
    line(lines, "DTSTART", icsDateTime(booking.start_at));
    line(lines, "DTEND", icsDateTime(booking.end_at));
    line(lines, "SUMMARY", escapeText(summary));
    line(lines, "DESCRIPTION", escapeText("A Slate Pro booking. Open the Slate Pro app for the details."));
    line(lines, "STATUS", "CONFIRMED");
    line(lines, "TRANSP", "OPAQUE");
    lines.push("END:VEVENT");
  }

  for (const event of data.events) {
    lines.push("BEGIN:VEVENT");
    line(lines, "UID", `event-${event.id}@${UID_DOMAIN}`);
    line(lines, "DTSTAMP", stamp);
    if (event.all_day) {
      line(lines, "DTSTART;VALUE=DATE", icsLocalDate(event.starts_at, event.time_zone));
      line(lines, "DTEND;VALUE=DATE", icsAllDayEnd(event.ends_at, event.time_zone));
    } else {
      line(lines, "DTSTART", icsDateTime(event.starts_at));
      line(lines, "DTEND", icsDateTime(event.ends_at));
    }
    line(lines, "SUMMARY", escapeText(event.title));
    if (event.location.trim() !== "") line(lines, "LOCATION", escapeText(event.location));
    const description = [event.organization_name.trim() === "" ? "" : `${event.organization_name} team event`, event.notes.trim()]
      .filter((part) => part !== "")
      .join("\n\n");
    if (description !== "") line(lines, "DESCRIPTION", escapeText(description));
    if (event.updated_at) line(lines, "LAST-MODIFIED", icsDateTime(event.updated_at));
    line(lines, "STATUS", "CONFIRMED");
    line(lines, "TRANSP", "OPAQUE");
    lines.push("END:VEVENT");
  }

  lines.push("END:VCALENDAR");
  return lines.join("\r\n") + "\r\n";
}

// ---------------------------------------------------------------------------
// The request
// ---------------------------------------------------------------------------

export interface FeedRequest {
  method: string;
  url: string;
}

const NOT_FOUND: HttpResult = { status: 404, body: { error: "not_found" } };

/**
 * GET (or HEAD) the calendar for a secret. An unknown or malformed secret is a plain 404 that says nothing about which.
 * Answers with the file and "private" caching, because the address is a secret and the content is personal.
 */
export async function calendarFeedRequest(request: FeedRequest, deps: CalendarDeps): Promise<HttpResult> {
  if (request.method !== "GET" && request.method !== "HEAD") {
    return { status: 405, body: { error: "method_not_allowed" }, headers: { Allow: "GET, HEAD" } };
  }
  const token = tokenFrom(request.url);
  if (!token) return NOT_FOUND;

  let data: FeedData | null;
  try {
    data = await deps.db.rpc<FeedData | null>("calendar_feed_data", { p_token: token });
  } catch (error) {
    deps.log("calendar_feed_data failed", error instanceof Error ? error.message : String(error));
    return { status: 500, body: { error: "unavailable" } };
  }
  if (!data) return NOT_FOUND;

  const file = buildCalendar(
    { bookings: Array.isArray(data.bookings) ? data.bookings : [], events: Array.isArray(data.events) ? data.events : [] },
    deps.now(),
  );
  return {
    status: 200,
    body: request.method === "HEAD" ? "" : file,
    headers: {
      "Content-Type": "text/calendar; charset=utf-8",
      "Content-Disposition": 'inline; filename="slate-pro.ics"',
      "Cache-Control": "private, max-age=300",
      "X-Robots-Tag": "noindex, nofollow",
    },
  };
}
