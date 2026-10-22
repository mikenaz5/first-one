// The push notification logic behind the `send-push` Edge Function, as plain functions that take their
// dependencies (a database and an APNs sender) as arguments, so Node can test them with fakes
// (see ios/supabase/function-tests/push.test.ts).
//
// What lives where:
//   - What happened, and who should hear about it, is decided in SQL (supabase/migrations/…_messaging_notifications.sql),
//     which queues *facts* in `push_outbox`: a kind, a booking, and the figures. That is tested against a real Postgres.
//   - This file words each fact into a notification, sends it to the person's devices through APNs, and tells the
//     database how it went (delivered, try again later, or this device token is dead).
//   - _shared/apns.ts signs the requests; _shared/runtime.ts connects all of it to the real world. Those have never
//     been run against Apple's servers or a live project.
//
// Only erasable TypeScript syntax is used (no enums or parameter properties) so Node can run it directly.

import type { Db, HttpResult } from "./payments.ts";

// ---------------------------------------------------------------------------
// Shapes
// ---------------------------------------------------------------------------
export type PushKind =
  | "new_booking"
  | "booking_cancelled"
  | "contract_signed"
  | "payment_received"
  | "balance_due"
  | "delivery_shared"
  | "receipt_confirmed"
  | "review_received"
  | "message"
  | "shoot_reminder";

export interface Device {
  token: string;
  environment: "sandbox" | "production";
}

/** One row of the queue, as `push_claim` returns it. */
export interface QueuedPush {
  id: string;
  user_id: string;
  kind: PushKind;
  booking_id: string | null;
  data: Record<string, unknown>;
  attempts: number;
  /** How many unread messages the person has, for the app icon. */
  badge: number;
  devices: Device[];
}

export interface Notice {
  title: string;
  body: string;
  /** Where tapping it goes, e.g. slate://booking/<id>. */
  url: string;
  threadId: string | null;
  collapseId?: string;
  /** After this, Apple needn't bother delivering it. */
  expiresAt: Date;
}

export interface ApnsPayload {
  aps: {
    alert: { title: string; body: string };
    sound: "default";
    badge: number;
    "thread-id"?: string;
  };
  slate: { url: string; kind: PushKind };
}

export interface ApnsMessage {
  token: string;
  environment: Device["environment"];
  payload: ApnsPayload;
  collapseId?: string;
  /** Unix seconds. */
  expiration: number;
  priority: 5 | 10;
}

export type ApnsResult = { ok: true } | { ok: false; status: number; reason: string };

export interface ApnsSender {
  send(message: ApnsMessage): Promise<ApnsResult>;
}

export interface PushDeps {
  db: Db;
  apns: ApnsSender;
  now: () => Date;
  log: (message: string, detail?: unknown) => void;
}

// ---------------------------------------------------------------------------
// Wording
// ---------------------------------------------------------------------------
const WEEKDAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

/** "$2,400", "$2,400.50", "EUR 2,400". The same style the contracts use. */
export function money(cents: number, currency: string): string {
  const whole = Math.floor(Math.abs(cents) / 100);
  const fraction = Math.abs(cents) % 100;
  const grouped = String(whole).replace(/\B(?=(\d{3})+(?!\d))/g, ",");
  const digits = fraction === 0 ? grouped : `${grouped}.${String(fraction).padStart(2, "0")}`;
  const code = (currency || "USD").toUpperCase();
  return `${cents < 0 ? "-" : ""}${code === "USD" ? "$" : `${code} `}${digits}`;
}

interface LocalParts {
  year: number;
  month: number;
  day: number;
  hour: number;
  minute: number;
}

/** The calendar date and clock time of an instant in a time zone. An unknown zone falls back to UTC. */
export function localParts(date: Date, timeZone: string): LocalParts {
  const make = (zone: string) =>
    new Intl.DateTimeFormat("en-US", {
      timeZone: zone,
      hourCycle: "h23",
      year: "numeric",
      month: "numeric",
      day: "numeric",
      hour: "numeric",
      minute: "numeric",
    });
  let formatter: Intl.DateTimeFormat;
  try {
    formatter = make(timeZone);
  } catch {
    formatter = make("UTC");
  }
  const found: Record<string, number> = {};
  for (const part of formatter.formatToParts(date)) {
    if (part.type !== "literal") found[part.type] = Number(part.value);
  }
  return { year: found.year, month: found.month, day: found.day, hour: found.hour % 24, minute: found.minute };
}

function weekdayOf(parts: LocalParts): number {
  return new Date(Date.UTC(parts.year, parts.month - 1, parts.day)).getUTCDay();
}

/** "10:00 AM" */
export function clock(parts: LocalParts): string {
  const hour12 = parts.hour % 12 === 0 ? 12 : parts.hour % 12;
  return `${hour12}:${String(parts.minute).padStart(2, "0")} ${parts.hour < 12 ? "AM" : "PM"}`;
}

/** "Sat, Nov 14" */
export function shortDate(parts: LocalParts): string {
  return `${WEEKDAYS[weekdayOf(parts)]}, ${MONTHS[parts.month - 1]} ${parts.day}`;
}

/** "Sat, Nov 14 at 10:00 AM", in the zone the shoot happens in. */
export function shootTime(start: Date, timeZone: string): string {
  const parts = localParts(start, timeZone);
  return `${shortDate(parts)} at ${clock(parts)}`;
}

/** "today", "tomorrow", or "Sat, Nov 14", counted in calendar days in the shoot's zone. */
export function dayLabel(start: Date, now: Date, timeZone: string): string {
  const s = localParts(start, timeZone);
  const n = localParts(now, timeZone);
  const days = Math.round((Date.UTC(s.year, s.month - 1, s.day) - Date.UTC(n.year, n.month - 1, n.day)) / 86_400_000);
  if (days === 0) return "today";
  if (days === 1) return "tomorrow";
  return shortDate(s);
}

/** Strips control characters and runs of whitespace, and shortens by whole characters (never half an emoji). */
export function tidy(value: unknown, max: number, fallback = ""): string {
  const text = typeof value === "string" ? value : "";
  // deno-lint-ignore no-control-regex
  const clean = text.replace(/[\u0000-\u001f\u007f]+/g, " ").replace(/\s+/g, " ").trim();
  if (!clean) return fallback;
  const characters = Array.from(clean);
  return characters.length <= max ? clean : `${characters.slice(0, max - 1).join("").trimEnd()}…`;
}

function whole(value: unknown): number {
  return typeof value === "number" && Number.isFinite(value) ? Math.trunc(value) : 0;
}

function dateOf(value: unknown, fallback: Date): Date {
  const parsed = typeof value === "string" ? new Date(value) : null;
  return parsed && !Number.isNaN(parsed.getTime()) ? parsed : fallback;
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** Words one queued fact as a notification. Throws if the row is missing what its kind needs. */
export function compose(row: Pick<QueuedPush, "kind" | "booking_id" | "data">, now: Date): Notice {
  const d = row.data ?? {};
  const bookingId = typeof d.bookingId === "string" && UUID.test(d.bookingId) ? d.bookingId : row.booking_id;
  if (!bookingId || !UUID.test(bookingId)) throw new Error(`no booking for a ${row.kind} notification`);

  const role = d.role === "client" ? "client" : "creator";
  const pkg = tidy(d.packageName, 60, "your booking");
  const currency = typeof d.currency === "string" ? d.currency : "USD";
  const zone = typeof d.timeZone === "string" ? d.timeZone : "UTC";
  const start = dateOf(d.startAt, now);
  const when = d.startAt ? shootTime(start, zone) : "";
  const in2Days = new Date(now.getTime() + 2 * 86_400_000);

  const notice = (title: string, body: string, extra: Partial<Notice> = {}): Notice => ({
    title,
    body,
    url: `slate://booking/${bookingId}`,
    threadId: `booking-${bookingId}`,
    expiresAt: in2Days,
    ...extra,
  });
  const dotted = (...parts: string[]) => parts.filter(Boolean).join(" · ");

  switch (row.kind) {
    case "new_booking": {
      const client = tidy(d.clientName, 60, "a client");
      return notice(
        `New booking from ${client}`,
        // A company booking waiting for someone to take it says so, to the people who can assign it.
        dotted(pkg, when, d.unassigned === true ? "Needs someone assigned" : "", d.pendingDeposit ? "Waiting for the deposit" : ""),
      );
    }
    case "booking_cancelled": {
      const by = tidy(d.byName, 60);
      const refund = whole(d.refundCents);
      if (role === "client") {
        return notice(
          `${by || "Your creator"} cancelled your booking`,
          dotted(pkg, when, refund > 0 ? `You'll be refunded ${money(refund, currency)}` : ""),
        );
      }
      return notice(`${by || "A client"} cancelled`, dotted(pkg, when, refund > 0 ? `${money(refund, currency)} refunded` : ""));
    }
    case "contract_signed": {
      const other = tidy(d.otherName, 60);
      return notice("Contract signed", dotted(other ? `${pkg} with ${other}` : pkg, when));
    }
    case "payment_received": {
      const what = d.paymentKind === "balance" ? "balance" : "deposit";
      const amount = money(whole(d.amountCents), currency);
      if (role === "client") {
        return notice("Payment received", `Your ${amount} ${what} for ${pkg} went through.`);
      }
      return notice("Payment received", `${amount} ${what} from ${tidy(d.clientName, 60, "your client")}`);
    }
    case "balance_due": {
      const creator = tidy(d.creatorName, 60, "Your creator");
      return notice("Balance due", `${creator} delivered ${pkg}. ${money(whole(d.balanceCents), currency)} is due.`);
    }
    case "delivery_shared": {
      const creator = tidy(d.creatorName, 60, "Your creator");
      if (d.revised === true) {
        return notice("Link to your files updated", `${creator} replaced the link to the final files for ${pkg}.`);
      }
      return notice("Your files are ready", `${creator} shared the final files for ${pkg}. Open Slate to confirm you have them.`);
    }
    case "receipt_confirmed": {
      const client = tidy(d.clientName, 60, "Your client");
      const balance = whole(d.balanceCents);
      return notice(
        `${client} confirmed receipt`,
        dotted(pkg, balance > 0 ? `${money(balance, currency)} balance is now payable` : "Nothing more to pay"),
      );
    }
    case "review_received": {
      const reviewer = tidy(d.reviewerName, 60, "A client");
      const stars = Math.min(5, Math.max(1, whole(d.rating)));
      return notice(`${reviewer} left a ${stars}-star review`, pkg);
    }
    case "message": {
      return notice(tidy(d.senderName, 60, "New message"), tidy(d.preview, 160, "Sent you a message"), {
        url: `slate://messages/${bookingId}`,
        expiresAt: new Date(now.getTime() + 7 * 86_400_000),
      });
    }
    case "shoot_reminder": {
      const lead = whole(d.leadMinutes);
      const other = tidy(d.otherName, 60);
      const label = dayLabel(start, now, zone);
      const time = clock(localParts(start, zone));
      const withWho = other ? `${pkg} with ${other}` : pkg;
      const reminder = {
        collapseId: `rem-${bookingId}-${lead}`,
        expiresAt: start,
      };
      if (d.unassigned === true && role === "creator") {
        // Said to the people who can assign it: nobody is booked for this shoot yet.
        const day = label === "today" || label === "tomorrow" ? label : `on ${label}`;
        return notice("Shoot still unassigned", `${withWho} ${day} at ${time}`, reminder);
      }
      if (lead >= 720) {
        const title = label === "tomorrow" ? "Shoot tomorrow" : label === "today" ? "Shoot today" : "Shoot coming up";
        const body = label === "today" || label === "tomorrow" ? `${withWho} at ${time}` : `${withWho} on ${label} at ${time}`;
        return notice(title, body, reminder);
      }
      const hours = Math.max(1, Math.round(lead / 60));
      return notice(`Shoot in ${hours} hour${hours === 1 ? "" : "s"}`, `${withWho} at ${time}`, reminder);
    }
    default:
      throw new Error(`unknown notification kind: ${row.kind}`);
  }
}

export function buildPayload(notice: Notice, kind: PushKind, badge: number): ApnsPayload {
  const aps: ApnsPayload["aps"] = {
    alert: { title: notice.title, body: notice.body },
    sound: "default",
    badge: Math.max(0, Math.trunc(badge) || 0),
  };
  if (notice.threadId) aps["thread-id"] = notice.threadId;
  return { aps, slate: { url: notice.url, kind } };
}

// ---------------------------------------------------------------------------
// What Apple's answers mean
// ---------------------------------------------------------------------------
// These say the device token will never work again (the app was deleted, or the token belongs to the other APNs server).
const DEAD_REASONS = new Set(["BadDeviceToken", "Unregistered", "DeviceTokenNotForTopic"]);

export type Outcome = "sent" | "dead" | "failed";

export function classify(result: ApnsResult): Outcome {
  if (result.ok) return "sent";
  if (result.status === 410 || DEAD_REASONS.has(result.reason)) return "dead";
  // Everything else (throttling, Apple having a bad moment, a network error, or a configuration mistake that
  // someone may fix) is worth trying again a few times.
  return "failed";
}

// ---------------------------------------------------------------------------
// One run
// ---------------------------------------------------------------------------
export const BATCH = 100;
const CONCURRENCY = 8;

export interface RunSummary {
  reminders_queued: number;
  claimed: number;
  delivered: number;
  retrying: number;
  devices_sent: number;
  devices_removed: number;
}

async function eachLimited<T>(items: T[], limit: number, work: (item: T) => Promise<void>): Promise<void> {
  let next = 0;
  const lanes = Array.from({ length: Math.min(limit, items.length) }, async () => {
    while (next < items.length) {
      const item = items[next++];
      await work(item);
    }
  });
  await Promise.all(lanes);
}

/**
 * Queues any shoot reminders that are due, sends what is waiting, and tidies up. Safe to run as often as you like
 * (cron does it every minute): the database hands each notification to one run at a time.
 */
export async function runSendPush(deps: PushDeps): Promise<RunSummary> {
  const { db, apns, now, log } = deps;
  const summary: RunSummary = { reminders_queued: 0, claimed: 0, delivered: 0, retrying: 0, devices_sent: 0, devices_removed: 0 };

  summary.reminders_queued = await db.rpc<number>("enqueue_due_reminders");
  const rows = await db.rpc<QueuedPush[]>("push_claim", { p_limit: BATCH });
  summary.claimed = rows.length;

  await eachLimited(rows, CONCURRENCY, async (row) => {
    const complete = (delivered: boolean, error: string | null, dead: string[]) =>
      db.rpc("push_complete", { p_id: row.id, p_delivered: delivered, p_error: error, p_dead_tokens: dead });

    let notice: Notice;
    try {
      notice = compose(row, now());
    } catch (error) {
      // Retrying wouldn't change what's in the row, so close it and say why.
      log("couldn't word a notification", { id: row.id, kind: row.kind, error: String(error) });
      await complete(true, `unsendable: ${error instanceof Error ? error.message : String(error)}`, []);
      summary.delivered++;
      return;
    }

    if (row.devices.length === 0) {
      await complete(true, "no_devices", []);
      summary.delivered++;
      return;
    }

    const payload = buildPayload(notice, row.kind, row.badge);
    const results = await Promise.all(
      row.devices.map(async (device) => {
        try {
          return await apns.send({
            token: device.token,
            environment: device.environment,
            payload,
            collapseId: notice.collapseId,
            expiration: Math.floor(notice.expiresAt.getTime() / 1000),
            priority: 10,
          });
        } catch (error) {
          return { ok: false, status: 0, reason: `NetworkError: ${String(error)}` } as ApnsResult;
        }
      }),
    );

    const outcomes = results.map(classify);
    const dead = row.devices.filter((_, i) => outcomes[i] === "dead").map((device) => device.token);
    const sent = outcomes.filter((o) => o === "sent").length;
    const problems = results
      .flatMap((result, i) => (result.ok ? [] : [`${outcomes[i]}: ${result.reason}`]))
      .join("; ");
    summary.devices_sent += sent;
    summary.devices_removed += dead.length;

    if (sent > 0) {
      // Delivered somewhere. Sending again to try the others would only give the working devices a duplicate.
      await complete(true, problems || null, dead);
      summary.delivered++;
    } else if (dead.length === row.devices.length) {
      await complete(true, "all_devices_unregistered", dead);
      summary.delivered++;
    } else {
      log("push failed; will retry", { id: row.id, kind: row.kind, attempts: row.attempts, problems });
      await complete(false, problems, dead);
      summary.retrying++;
    }
  });

  await db.rpc("push_prune");
  return summary;
}

// ---------------------------------------------------------------------------
// The request
// ---------------------------------------------------------------------------
function safeEqual(a: string, b: string): boolean {
  const x = new TextEncoder().encode(a);
  const y = new TextEncoder().encode(b);
  let diff = x.length ^ y.length;
  const length = Math.max(x.length, y.length);
  for (let i = 0; i < length; i++) diff |= (x[i] ?? 0) ^ (y[i] ?? 0);
  return diff === 0;
}

/**
 * The function is for the scheduler, not for people: it must be called with the project's service role key, or a
 * long secret you chose (PUSH_CRON_SECRET). Anything shorter than 16 characters is never accepted as a secret, so a
 * blank setting can't let blank requests in.
 */
export function isAuthorized(authorization: string | null, secrets: (string | undefined)[]): boolean {
  const match = /^Bearer (\S+)$/.exec(authorization ?? "");
  if (!match) return false;
  return secrets.some((secret) => typeof secret === "string" && secret.length >= 16 && safeEqual(match[1], secret));
}

export async function sendPushRequest(
  request: { method: string; authorization: string | null },
  secrets: (string | undefined)[],
  deps: PushDeps | null,
): Promise<HttpResult> {
  if (request.method !== "POST") return { status: 405, body: { error: "method_not_allowed" } };
  if (!isAuthorized(request.authorization, secrets)) return { status: 401, body: { error: "unauthorized" } };
  if (!deps) return { status: 503, body: { error: "push_not_configured" } };
  return { status: 200, body: await runSendPush(deps) };
}
