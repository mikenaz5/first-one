import assert from "node:assert/strict";
import { describe, it } from "node:test";
import {
  buildCalendar,
  calendarFeedRequest,
  escapeText,
  foldLine,
  icsAllDayEnd,
  icsDateTime,
  icsLocalDate,
  tokenFrom,
} from "../functions/_shared/calendar.ts";
import type { CalendarDeps, FeedBooking, FeedData, FeedEvent } from "../functions/_shared/calendar.ts";

// ---------------------------------------------------------------------------
// Fakes and helpers
// ---------------------------------------------------------------------------
const SECRET = "0123456789abcdef0123456789abcdef";
const NOW = new Date("2027-01-04T14:00:00Z");

function booking(over: Partial<FeedBooking> = {}): FeedBooking {
  return {
    id: "b1a2c3d4-0000-4000-8000-000000000001",
    package_name: "Portrait session",
    start_at: "2027-01-22T16:00:00+00:00",
    end_at: "2027-01-22T17:00:00+00:00",
    time_zone: "America/Chicago",
    role: "provider",
    client_name: "Sam Client",
    creator_name: "Dana Lens",
    status: "confirmed",
    ...over,
  };
}

function event(over: Partial<FeedEvent> = {}): FeedEvent {
  return {
    id: "e1a2c3d4-0000-4000-8000-000000000002",
    title: "Team meeting",
    notes: "",
    location: "",
    starts_at: "2027-01-25T15:00:00+00:00",
    ends_at: "2027-01-25T16:00:00+00:00",
    all_day: false,
    organization_name: "Northlight Films",
    time_zone: "America/Chicago",
    updated_at: "2027-01-04T12:00:00+00:00",
    ...over,
  };
}

/** Undo folding, the way a calendar app reads the file. */
function unfold(text: string): string[] {
  return text.replace(/\r\n[ \t]/g, "").split("\r\n").filter((l) => l !== "");
}

function deps(handler: (args: Record<string, unknown>) => unknown) {
  const calls: Record<string, unknown>[] = [];
  const logs: string[] = [];
  const value: CalendarDeps = {
    db: {
      async rpc<T = unknown>(fn: string, args: Record<string, unknown> = {}): Promise<T> {
        assert.equal(fn, "calendar_feed_data");
        calls.push(args);
        const result = handler(args);
        if (result instanceof Error) throw result;
        return result as T;
      },
    },
    now: () => NOW,
    log: (message) => logs.push(message),
  };
  return { value, calls, logs };
}

const URL_BASE = "https://example.supabase.co/functions/v1/calendar-feed";

// ---------------------------------------------------------------------------
describe("reading the secret out of an address", () => {
  it("takes the last part of the path, with or without .ics", () => {
    assert.equal(tokenFrom(`${URL_BASE}/${SECRET}.ics`), SECRET);
    assert.equal(tokenFrom(`${URL_BASE}/${SECRET}`), SECRET);
    assert.equal(tokenFrom(`${URL_BASE}/${SECRET}/`), SECRET);
  });

  it("takes a token query as well", () => {
    assert.equal(tokenFrom(`${URL_BASE}?token=${SECRET}`), SECRET);
  });

  it("ignores case, and returns it in lower case", () => {
    assert.equal(tokenFrom(`${URL_BASE}/${SECRET.toUpperCase()}.ics`), SECRET);
  });

  it("refuses anything that isn't 32 hex characters", () => {
    for (const bad of [`${URL_BASE}`, `${URL_BASE}/`, `${URL_BASE}/abc.ics`, `${URL_BASE}/${SECRET}0.ics`.replace(SECRET, "g".repeat(32)),
      `${URL_BASE}?token=short`, `${URL_BASE}/../${SECRET.slice(0, 31)}`]) {
      assert.equal(tokenFrom(bad), null, bad);
    }
    assert.equal(tokenFrom("not an address"), null);
  });
});

describe("writing text", () => {
  it("escapes backslash, semicolon, comma and line breaks", () => {
    assert.equal(escapeText("a,b;c\\d\ne"), "a\\,b\\;c\\\\d\\ne");
    assert.equal(escapeText("one\r\ntwo\rthree"), "one\\ntwo\\nthree");
  });

  it("drops control characters", () => {
    assert.equal(escapeText("bell\u0007ring\u0000"), "bellring");
  });

  it("keeps emoji and accents", () => {
    assert.equal(escapeText("Café 📸"), "Café 📸");
  });
});

describe("folding long lines", () => {
  const octets = (s: string) => new TextEncoder().encode(s).length;

  it("leaves a short line alone", () => {
    assert.equal(foldLine("SUMMARY:Short"), "SUMMARY:Short");
  });

  it("keeps every line within 75 octets and loses nothing", () => {
    const long = "DESCRIPTION:" + "word ".repeat(80);
    const folded = foldLine(long);
    const physical = folded.split("\r\n");
    assert.ok(physical.length > 1);
    for (const piece of physical) assert.ok(octets(piece) <= 75, `${octets(piece)} octets`);
    assert.equal(unfold(folded)[0], long);
  });

  it("never cuts a character in half", () => {
    // Three-byte and four-byte characters, in a run long enough to meet the edge at every alignment.
    for (const unit of ["é", "—", "📸", "漢"]) {
      for (let prefix = 0; prefix < 6; prefix++) {
        const text = "X".repeat(60 + prefix) + unit.repeat(30);
        const folded = foldLine(text);
        for (const piece of folded.split("\r\n")) assert.ok(octets(piece) <= 75);
        assert.equal(unfold(folded)[0], text);
      }
    }
  });
});

describe("dates and times", () => {
  it("writes a moment in UTC", () => {
    assert.equal(icsDateTime("2027-01-22T16:05:09+00:00"), "20270122T160509Z");
    assert.equal(icsDateTime("2027-01-22T10:00:00-06:00"), "20270122T160000Z");
  });

  it("finds the calendar date in the company's time zone, not UTC's", () => {
    // Midnight in Chicago (UTC-6 in January) is 06:00 UTC the same day.
    assert.equal(icsLocalDate("2027-01-25T06:00:00+00:00", "America/Chicago"), "20270125");
    // 03:00 UTC is still the evening before in Chicago.
    assert.equal(icsLocalDate("2027-01-25T03:00:00+00:00", "America/Chicago"), "20270124");
  });

  it("ends an all-day event on the date after its last day", () => {
    // Midnight to midnight: the end is the next midnight, which is the exclusive end date as it stands.
    assert.equal(icsAllDayEnd("2027-01-26T06:00:00+00:00", "America/Chicago"), "20270126");
    // An end that isn't at midnight counts the whole day it falls in.
    assert.equal(icsAllDayEnd("2027-01-25T20:00:00+00:00", "America/Chicago"), "20270126");
  });

  it("copes with an unknown time zone by using UTC", () => {
    assert.equal(icsLocalDate("2027-01-25T06:00:00+00:00", "Mars/Olympus"), "20270125");
  });
});

describe("the calendar file", () => {
  const data: FeedData = {
    bookings: [booking(), booking({ id: "b1a2c3d4-0000-4000-8000-000000000002", role: "client", client_name: "Sam Client", creator_name: "Dana Lens" })],
    events: [
      event(),
      event({ id: "e1a2c3d4-0000-4000-8000-000000000003", title: "Leave", all_day: true, starts_at: "2027-02-01T06:00:00+00:00", ends_at: "2027-02-04T06:00:00+00:00" }),
    ],
  };
  const file = buildCalendar(data, NOW);
  const lines = unfold(file);

  it("is a calendar with the right framing and CRLF line endings", () => {
    assert.equal(lines[0], "BEGIN:VCALENDAR");
    assert.equal(lines[lines.length - 1], "END:VCALENDAR");
    assert.ok(lines.includes("VERSION:2.0"));
    assert.ok(lines.includes("PRODID:-//Slate Pro//Calendar//EN"));
    assert.ok(lines.includes("X-WR-CALNAME:Slate Pro"));
    assert.ok(file.endsWith("\r\n"));
    assert.equal(file.replace(/\r\n/g, "").includes("\n"), false, "no bare line feeds");
  });

  it("has one event for each booking and each team event", () => {
    assert.equal(lines.filter((l) => l === "BEGIN:VEVENT").length, 4);
    assert.equal(lines.filter((l) => l === "END:VEVENT").length, 4);
  });

  it("gives every event a stable, unique id", () => {
    const uids = lines.filter((l) => l.startsWith("UID:"));
    assert.equal(new Set(uids).size, 4);
    assert.ok(uids.includes("UID:booking-b1a2c3d4-0000-4000-8000-000000000001@slateproapp.com"));
    assert.ok(uids.includes("UID:event-e1a2c3d4-0000-4000-8000-000000000002@slateproapp.com"));
    assert.deepEqual(unfold(buildCalendar(data, new Date("2030-01-01T00:00:00Z"))).filter((l) => l.startsWith("UID:")), uids);
  });

  it("stamps each event with the time the file was made", () => {
    assert.equal(lines.filter((l) => l === "DTSTAMP:20270104T140000Z").length, 4);
  });

  it("names a booking for the person doing the job after the client, and for the client after the creator", () => {
    assert.ok(lines.includes("SUMMARY:Portrait session: Sam Client"));
    assert.ok(lines.includes("SUMMARY:Portrait session with Dana Lens"));
  });

  it("writes timed events in UTC", () => {
    assert.ok(lines.includes("DTSTART:20270122T160000Z"));
    assert.ok(lines.includes("DTEND:20270122T170000Z"));
    assert.ok(lines.includes("DTSTART:20270125T150000Z"));
  });

  it("writes an all-day event as dates", () => {
    assert.ok(lines.includes("DTSTART;VALUE=DATE:20270201"));
    assert.ok(lines.includes("DTEND;VALUE=DATE:20270204"));
  });

  it("says when an event last changed", () => {
    assert.ok(lines.includes("LAST-MODIFIED:20270104T120000Z"));
  });

  it("names the company in a team event and keeps it out of the title", () => {
    assert.ok(lines.includes("SUMMARY:Team meeting"));
    assert.ok(lines.some((l) => l === "DESCRIPTION:Northlight Films team event"));
  });

  it("a booking says nothing about money, contracts or the client's contact details", () => {
    const text = lines.join("\n").toLowerCase();
    for (const word of ["$", "price", "deposit", "balance", "contract", "email", "phone", "@gmail", "notes"]) {
      assert.equal(text.includes(word), false, word);
    }
  });

  it("puts a place and notes in a team event, escaped", () => {
    const out = unfold(buildCalendar({
      bookings: [],
      events: [event({ location: "Studio B, 2nd floor", notes: "Bring: the 24-70;\nand the gimbal" })],
    }, NOW));
    assert.ok(out.includes("LOCATION:Studio B\\, 2nd floor"));
    assert.ok(out.includes("DESCRIPTION:Northlight Films team event\\n\\nBring: the 24-70\\;\\nand the gimbal"));
  });

  it("leaves out a place and notes that are empty", () => {
    const out = unfold(buildCalendar({ bookings: [], events: [event({ organization_name: "" })] }, NOW));
    assert.equal(out.some((l) => l.startsWith("LOCATION")), false);
    assert.equal(out.some((l) => l.startsWith("DESCRIPTION")), false);
  });

  it("calls a client with no name 'Client'", () => {
    const out = unfold(buildCalendar({ bookings: [booking({ client_name: "  " })], events: [] }, NOW));
    assert.ok(out.includes("SUMMARY:Portrait session: Client"));
  });

  it("a person with nothing booked still gets a valid, empty calendar", () => {
    const out = unfold(buildCalendar({ bookings: [], events: [] }, NOW));
    assert.equal(out.filter((l) => l === "BEGIN:VEVENT").length, 0);
    assert.equal(out[out.length - 1], "END:VCALENDAR");
  });

  it("escapes what a person typed so it can't add lines of its own", () => {
    const out = buildCalendar({ bookings: [], events: [event({ title: "Hi\r\nEND:VEVENT\r\nBEGIN:VEVENT" })] }, NOW);
    assert.equal(unfold(out).filter((l) => l === "BEGIN:VEVENT").length, 1);
  });
});

describe("answering a request", () => {
  const data: FeedData = { bookings: [booking()], events: [event()] };

  it("gives the calendar for a known secret, privately", async () => {
    const d = deps(() => data);
    const result = await calendarFeedRequest({ method: "GET", url: `${URL_BASE}/${SECRET}.ics` }, d.value);
    assert.equal(result.status, 200);
    assert.equal(typeof result.body, "string");
    assert.ok((result.body as string).startsWith("BEGIN:VCALENDAR\r\n"));
    assert.equal(result.headers?.["Content-Type"], "text/calendar; charset=utf-8");
    assert.match(result.headers?.["Cache-Control"] ?? "", /private/);
    assert.match(result.headers?.["X-Robots-Tag"] ?? "", /noindex/);
    assert.deepEqual(d.calls, [{ p_token: SECRET }]);
  });

  it("asks the database in lower case whatever case the address had", async () => {
    const d = deps(() => data);
    await calendarFeedRequest({ method: "GET", url: `${URL_BASE}/${SECRET.toUpperCase()}.ics` }, d.value);
    assert.deepEqual(d.calls, [{ p_token: SECRET }]);
  });

  it("answers a HEAD request with the headers and no body", async () => {
    const result = await calendarFeedRequest({ method: "HEAD", url: `${URL_BASE}/${SECRET}.ics` }, deps(() => data).value);
    assert.equal(result.status, 200);
    assert.equal(result.body, "");
    assert.equal(result.headers?.["Content-Type"], "text/calendar; charset=utf-8");
  });

  it("answers an unknown secret with a plain not found", async () => {
    const d = deps(() => null);
    const result = await calendarFeedRequest({ method: "GET", url: `${URL_BASE}/${SECRET}.ics` }, d.value);
    assert.equal(result.status, 404);
    assert.deepEqual(result.body, { error: "not_found" });
  });

  it("doesn't even ask the database about something that can't be a secret", async () => {
    const d = deps(() => data);
    const result = await calendarFeedRequest({ method: "GET", url: `${URL_BASE}/hello.ics` }, d.value);
    assert.equal(result.status, 404);
    assert.equal(d.calls.length, 0);
  });

  it("allows reading and nothing else", async () => {
    for (const method of ["POST", "PUT", "DELETE", "PATCH"]) {
      const d = deps(() => data);
      const result = await calendarFeedRequest({ method, url: `${URL_BASE}/${SECRET}.ics` }, d.value);
      assert.equal(result.status, 405, method);
      assert.equal(d.calls.length, 0, method);
    }
  });

  it("says nothing about a database failure except that it's unavailable", async () => {
    const d = deps(() => new Error("connection to 10.0.0.5 refused, password=hunter2"));
    const result = await calendarFeedRequest({ method: "GET", url: `${URL_BASE}/${SECRET}.ics` }, d.value);
    assert.equal(result.status, 500);
    assert.deepEqual(result.body, { error: "unavailable" });
    assert.equal(d.logs.length, 1);
  });

  it("copes with a database that returns pieces missing", async () => {
    const result = await calendarFeedRequest({ method: "GET", url: `${URL_BASE}/${SECRET}.ics` }, deps(() => ({})).value);
    assert.equal(result.status, 200);
    assert.ok((result.body as string).includes("END:VCALENDAR"));
  });
});
