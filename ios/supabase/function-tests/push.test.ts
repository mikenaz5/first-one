import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { createApnsSender, importApnsKey, makeProviderToken, pemToPkcs8, TOKEN_WINDOW_SECONDS } from "../functions/_shared/apns.ts";
import type { FetchLike } from "../functions/_shared/apns.ts";
import {
  buildPayload,
  classify,
  clock,
  compose,
  dayLabel,
  isAuthorized,
  localParts,
  money,
  runSendPush,
  sendPushRequest,
  shootTime,
  tidy,
} from "../functions/_shared/push.ts";
import type { ApnsMessage, ApnsResult, ApnsSender, Device, PushDeps, QueuedPush } from "../functions/_shared/push.ts";

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------
const BOOKING = "0f5a7c1e-3b0d-4c8e-9a52-6d7e8f9a0b1c";
const START = "2026-11-14T16:00:00+00:00"; // Saturday 10:00 AM in Chicago
const NOW = new Date("2026-11-12T20:00:00Z");

const base = { bookingId: BOOKING, packageName: "Wedding day", startAt: START, timeZone: "America/Chicago", currency: "USD" };

function row(kind: QueuedPush["kind"], data: Record<string, unknown>, extra: Partial<QueuedPush> = {}): QueuedPush {
  return {
    id: "row-1",
    user_id: "user-1",
    kind,
    booking_id: BOOKING,
    data,
    attempts: 1,
    badge: 0,
    devices: [{ token: "a".repeat(64), environment: "sandbox" }],
    ...extra,
  };
}

// ---------------------------------------------------------------------------
// Wording
// ---------------------------------------------------------------------------
describe("formatting", () => {
  it("writes money the way contracts do", () => {
    assert.equal(money(240000, "USD"), "$2,400");
    assert.equal(money(240050, "USD"), "$2,400.50");
    assert.equal(money(5, "USD"), "$0.05");
    assert.equal(money(100000, "eur"), "EUR 1,000");
    assert.equal(money(123456789, "USD"), "$1,234,567.89");
  });

  it("shows a shoot's time in the zone it happens in", () => {
    assert.equal(shootTime(new Date(START), "America/Chicago"), "Sat, Nov 14 at 10:00 AM");
    assert.equal(shootTime(new Date(START), "Asia/Tokyo"), "Sun, Nov 15 at 1:00 AM");
    assert.equal(shootTime(new Date("2026-11-14T06:00:00Z"), "America/Chicago"), "Sat, Nov 14 at 12:00 AM");
    assert.equal(shootTime(new Date("2026-11-14T18:05:00Z"), "America/Chicago"), "Sat, Nov 14 at 12:05 PM");
    assert.equal(shootTime(new Date("2026-11-15T03:59:00Z"), "America/Chicago"), "Sat, Nov 14 at 9:59 PM");
  });

  it("follows daylight saving", () => {
    assert.equal(shootTime(new Date("2026-03-08T08:30:00Z"), "America/Chicago"), "Sun, Mar 8 at 3:30 AM");
    assert.equal(shootTime(new Date("2026-03-08T07:30:00Z"), "America/Chicago"), "Sun, Mar 8 at 1:30 AM");
    assert.equal(shootTime(new Date("2026-07-04T16:00:00Z"), "America/Chicago"), "Sat, Jul 4 at 11:00 AM");
  });

  it("falls back to UTC for a zone it doesn't know", () => {
    assert.equal(shootTime(new Date(START), "Mars/Olympus"), "Sat, Nov 14 at 4:00 PM");
  });

  it("never prints hour 24", () => {
    assert.equal(localParts(new Date("2026-11-14T06:00:00Z"), "America/Chicago").hour, 0);
    assert.equal(clock({ year: 2026, month: 1, day: 1, hour: 0, minute: 0 }), "12:00 AM");
  });

  it("counts days in the shoot's zone", () => {
    const start = new Date(START); // Sat 10:00 Chicago
    assert.equal(dayLabel(start, new Date("2026-11-14T13:00:00Z"), "America/Chicago"), "today");
    assert.equal(dayLabel(start, new Date("2026-11-13T15:00:00Z"), "America/Chicago"), "tomorrow");
    assert.equal(dayLabel(start, new Date("2026-11-12T20:00:00Z"), "America/Chicago"), "Sat, Nov 14");
    // 03:00 UTC on the 14th is still the evening of the 13th in Chicago, so the shoot is tomorrow.
    assert.equal(dayLabel(start, new Date("2026-11-14T03:00:00Z"), "America/Chicago"), "tomorrow");
  });

  it("tidies names and previews", () => {
    assert.equal(tidy("  Alex \n\t Rivera\u0007 ", 40), "Alex Rivera");
    assert.equal(tidy("", 40, "fallback"), "fallback");
    assert.equal(tidy(42, 40, "fallback"), "fallback");
    assert.equal(tidy("abcdefghij", 5), "abcd…");
    assert.equal(tidy("📸".repeat(10), 4), "📸📸📸…");
    assert.equal(tidy("short", 5), "short");
  });
});

describe("wording each kind of notification", () => {
  it("announces a new booking to the creator", () => {
    const n = compose(row("new_booking", { ...base, role: "creator", clientName: "Alex Rivera", pendingDeposit: false }), NOW);
    assert.equal(n.title, "New booking from Alex Rivera");
    assert.equal(n.body, "Wedding day · Sat, Nov 14 at 10:00 AM");
    assert.equal(n.url, `slate://booking/${BOOKING}`);
    assert.equal(n.threadId, `booking-${BOOKING}`);
  });

  it("says when a deposit is still awaited", () => {
    const n = compose(row("new_booking", { ...base, role: "creator", clientName: "Alex", pendingDeposit: true }), NOW);
    assert.equal(n.body, "Wedding day · Sat, Nov 14 at 10:00 AM · Waiting for the deposit");
  });

  it("copes with a client with no name", () => {
    assert.equal(compose(row("new_booking", { ...base, clientName: "  " }), NOW).title, "New booking from a client");
  });

  it("tells the creator a client cancelled, with any refund", () => {
    const n = compose(row("booking_cancelled", { ...base, role: "creator", byName: "Alex", refundCents: 25000 }), NOW);
    assert.equal(n.title, "Alex cancelled");
    assert.equal(n.body, "Wedding day · Sat, Nov 14 at 10:00 AM · $250 refunded");
    assert.equal(compose(row("booking_cancelled", { ...base, role: "creator", byName: "Alex", refundCents: 0 }), NOW).body, "Wedding day · Sat, Nov 14 at 10:00 AM");
  });

  it("tells a client the creator cancelled, with the refund they'll get", () => {
    const n = compose(row("booking_cancelled", { ...base, role: "client", byName: "Maya Chen", refundCents: 50000 }), NOW);
    assert.equal(n.title, "Maya Chen cancelled your booking");
    assert.equal(n.body, "Wedding day · Sat, Nov 14 at 10:00 AM · You'll be refunded $500");
  });

  it("announces a signed contract to each side", () => {
    const n = compose(row("contract_signed", { ...base, role: "client", otherName: "Maya Chen" }), NOW);
    assert.equal(n.title, "Contract signed");
    assert.equal(n.body, "Wedding day with Maya Chen · Sat, Nov 14 at 10:00 AM");
  });

  it("announces a payment to the creator and to the client", () => {
    const creator = compose(row("payment_received", { ...base, role: "creator", paymentKind: "deposit", amountCents: 50000, clientName: "Alex" }), NOW);
    assert.equal(creator.title, "Payment received");
    assert.equal(creator.body, "$500 deposit from Alex");
    const client = compose(row("payment_received", { ...base, role: "client", paymentKind: "balance", amountCents: 150050 }), NOW);
    assert.equal(client.body, "Your $1,500.50 balance for Wedding day went through.");
  });

  it("tells the client their balance is due", () => {
    const n = compose(row("balance_due", { ...base, role: "client", creatorName: "Maya Chen", balanceCents: 150000 }), NOW);
    assert.equal(n.title, "Balance due");
    assert.equal(n.body, "Maya Chen delivered Wedding day. $1,500 is due.");
    assert.equal(n.url, `slate://booking/${BOOKING}`);
  });

  it("shows a message as its sender and words, and opens the conversation", () => {
    const n = compose(row("message", { ...base, senderName: "Alex Rivera", preview: "Could we move the start to 11?" }), NOW);
    assert.equal(n.title, "Alex Rivera");
    assert.equal(n.body, "Could we move the start to 11?");
    assert.equal(n.url, `slate://messages/${BOOKING}`);
  });

  it("shortens a long message without cutting a character in half", () => {
    const n = compose(row("message", { senderName: "A", preview: "📸".repeat(500) }), NOW);
    assert.equal(Array.from(n.body).length, 160);
    assert.ok(n.body.endsWith("…"));
    assert.ok(!n.body.includes("�"));
  });

  it("keeps a message's line breaks out of the banner", () => {
    assert.equal(compose(row("message", { senderName: "A", preview: "one\n\ntwo" }), NOW).body, "one two");
  });

  it("words the day-before reminder", () => {
    const tomorrow = compose(row("shoot_reminder", { ...base, role: "client", otherName: "Maya Chen", leadMinutes: 1440 }), new Date("2026-11-13T16:00:00Z"));
    assert.equal(tomorrow.title, "Shoot tomorrow");
    assert.equal(tomorrow.body, "Wedding day with Maya Chen at 10:00 AM");
  });

  it("says the date when a late run makes 'tomorrow' wrong", () => {
    const n = compose(row("shoot_reminder", { ...base, otherName: "Maya", leadMinutes: 1440 }), new Date("2026-11-12T16:00:00Z"));
    assert.equal(n.title, "Shoot coming up");
    assert.equal(n.body, "Wedding day with Maya on Sat, Nov 14 at 10:00 AM");
    const today = compose(row("shoot_reminder", { ...base, otherName: "Maya", leadMinutes: 1440 }), new Date("2026-11-14T13:00:00Z"));
    assert.equal(today.title, "Shoot today");
  });

  it("words the two-hour reminder", () => {
    const n = compose(row("shoot_reminder", { ...base, otherName: "Maya", leadMinutes: 120 }), new Date("2026-11-14T14:00:00Z"));
    assert.equal(n.title, "Shoot in 2 hours");
    assert.equal(n.body, "Wedding day with Maya at 10:00 AM");
    assert.equal(compose(row("shoot_reminder", { ...base, leadMinutes: 60 }), NOW).title, "Shoot in 1 hour");
  });

  it("lets a reminder replace an earlier copy of itself, and expire when the shoot starts", () => {
    const n = compose(row("shoot_reminder", { ...base, leadMinutes: 120 }), NOW);
    assert.equal(n.collapseId, `rem-${BOOKING}-120`);
    assert.ok(n.collapseId!.length <= 64);
    assert.equal(n.expiresAt.toISOString(), new Date(START).toISOString());
  });

  it("refuses a row with no booking, or an unknown kind", () => {
    assert.throws(() => compose(row("message", { preview: "hi" }, { booking_id: null }), NOW), /no booking/);
    assert.throws(() => compose(row("message", { bookingId: "not-a-uuid" }, { booking_id: "nope" }), NOW), /no booking/);
    assert.throws(() => compose(row("mystery" as never, base), NOW), /unknown notification kind/);
  });

  it("falls back to the row's booking when the data lacks one", () => {
    const n = compose(row("balance_due", { creatorName: "Maya", balanceCents: 100 }), NOW);
    assert.equal(n.url, `slate://booking/${BOOKING}`);
  });

  it("cleans names that someone typed", () => {
    const n = compose(row("new_booking", { ...base, clientName: "Eve\u0007\n\n<b>Evil</b>" }), NOW);
    assert.equal(n.title, "New booking from Eve <b>Evil</b>");
  });
});

describe("the payload", () => {
  it("has the alert, sound, badge, thread and where to go", () => {
    const notice = compose(row("balance_due", { ...base, creatorName: "Maya", balanceCents: 100 }), NOW);
    const payload = buildPayload(notice, "balance_due", 3);
    assert.deepEqual(payload, {
      aps: { alert: { title: "Balance due", body: "Maya delivered Wedding day. $1 is due." }, sound: "default", badge: 3, "thread-id": `booking-${BOOKING}` },
      slate: { url: `slate://booking/${BOOKING}`, kind: "balance_due" },
    });
  });

  it("never sends a negative or fractional badge", () => {
    const notice = compose(row("message", { senderName: "A", preview: "x" }), NOW);
    assert.equal(buildPayload(notice, "message", -4).aps.badge, 0);
    assert.equal(buildPayload(notice, "message", 2.9).aps.badge, 2);
    assert.equal(buildPayload(notice, "message", Number.NaN).aps.badge, 0);
  });

  it("stays well inside Apple's 4 KB limit with the longest text", () => {
    const notice = compose(row("message", { senderName: "N".repeat(500), preview: "📸".repeat(500) }), NOW);
    assert.ok(new TextEncoder().encode(JSON.stringify(buildPayload(notice, "message", 99))).length < 1500);
  });
});

describe("what Apple's answers mean", () => {
  const fail = (status: number, reason: string): ApnsResult => ({ ok: false, status, reason });
  it("sorts them", () => {
    assert.equal(classify({ ok: true }), "sent");
    assert.equal(classify(fail(410, "Unregistered")), "dead");
    assert.equal(classify(fail(400, "BadDeviceToken")), "dead");
    assert.equal(classify(fail(400, "DeviceTokenNotForTopic")), "dead");
    assert.equal(classify(fail(429, "TooManyRequests")), "failed");
    assert.equal(classify(fail(503, "ServiceUnavailable")), "failed");
    assert.equal(classify(fail(403, "ExpiredProviderToken")), "failed");
    assert.equal(classify(fail(400, "BadTopic")), "failed");
    assert.equal(classify(fail(0, "NetworkError: offline")), "failed");
  });
});

// ---------------------------------------------------------------------------
// A run
// ---------------------------------------------------------------------------
class FakeDb {
  calls: { fn: string; args: Record<string, unknown> }[] = [];
  queue: QueuedPush[];
  reminders: number;
  failClaim = false;
  constructor(queue: QueuedPush[], reminders = 0) {
    this.queue = queue;
    this.reminders = reminders;
  }
  async rpc<T = unknown>(fn: string, args: Record<string, unknown> = {}): Promise<T> {
    this.calls.push({ fn, args });
    if (fn === "enqueue_due_reminders") return this.reminders as T;
    if (fn === "push_claim") {
      if (this.failClaim) throw new Error("database down");
      return this.queue as T;
    }
    if (fn === "push_complete" || fn === "push_prune") return undefined as T;
    throw new Error(`unexpected call ${fn}`);
  }
  completions() {
    return this.calls.filter((c) => c.fn === "push_complete").map((c) => c.args);
  }
  completion(id: string) {
    return this.completions().find((c) => c.p_id === id)!;
  }
}

class FakeApns implements ApnsSender {
  sent: ApnsMessage[] = [];
  respond: (message: ApnsMessage) => ApnsResult | Promise<ApnsResult> = () => ({ ok: true });
  active = 0;
  peak = 0;
  async send(message: ApnsMessage): Promise<ApnsResult> {
    this.sent.push(message);
    this.active++;
    this.peak = Math.max(this.peak, this.active);
    try {
      return await this.respond(message);
    } finally {
      this.active--;
    }
  }
}

function deps(db: FakeDb, apns: FakeApns): { deps: PushDeps; logs: string[] } {
  const logs: string[] = [];
  return { deps: { db, apns, now: () => NOW, log: (m) => logs.push(m) }, logs };
}

const device = (n: number, environment: Device["environment"] = "sandbox"): Device => ({ token: String(n).repeat(64).slice(0, 64), environment });
const msg = (id: string, devices: Device[], extra: Partial<QueuedPush> = {}) =>
  row("message", { ...base, senderName: "Alex", preview: `hello ${id}` }, { id, devices, ...extra });

describe("a run", () => {
  it("queues reminders, claims, sends, completes, then tidies, in that order", async () => {
    const db = new FakeDb([msg("a", [device(1)])], 4);
    const { deps: d } = deps(db, new FakeApns());
    const summary = await runSendPush(d);
    assert.deepEqual(db.calls.map((c) => c.fn), ["enqueue_due_reminders", "push_claim", "push_complete", "push_prune"]);
    assert.deepEqual(summary, { reminders_queued: 4, claimed: 1, delivered: 1, retrying: 0, devices_sent: 1, devices_removed: 0 });
    assert.equal(db.calls[1].args.p_limit, 100);
  });

  it("sends the worded notification to every device, with each one's own APNs server", async () => {
    const apns = new FakeApns();
    const db = new FakeDb([msg("a", [device(1, "sandbox"), device(2, "production")], { badge: 5 })]);
    await runSendPush(deps(db, apns).deps);
    assert.equal(apns.sent.length, 2);
    assert.deepEqual(apns.sent.map((s) => [s.token, s.environment]), [[device(1).token, "sandbox"], [device(2).token, "production"]]);
    const first = apns.sent[0];
    assert.equal(first.payload.aps.alert.title, "Alex");
    assert.equal(first.payload.aps.alert.body, "hello a");
    assert.equal(first.payload.aps.badge, 5);
    assert.equal(first.priority, 10);
    assert.equal(first.expiration, Math.floor(NOW.getTime() / 1000) + 7 * 86400);
    assert.deepEqual(db.completion("a"), { p_id: "a", p_delivered: true, p_error: null, p_dead_tokens: [] });
  });

  it("passes a reminder's collapse id and an expiry at the start of the shoot", async () => {
    const apns = new FakeApns();
    const db = new FakeDb([row("shoot_reminder", { ...base, otherName: "Maya", leadMinutes: 120 }, { id: "r" })]);
    await runSendPush(deps(db, apns).deps);
    assert.equal(apns.sent[0].collapseId, `rem-${BOOKING}-120`);
    assert.equal(apns.sent[0].expiration, Math.floor(new Date(START).getTime() / 1000));
  });

  it("closes a notification for a person with no devices", async () => {
    const apns = new FakeApns();
    const db = new FakeDb([msg("a", [])]);
    const summary = await runSendPush(deps(db, apns).deps);
    assert.equal(apns.sent.length, 0);
    assert.deepEqual(db.completion("a"), { p_id: "a", p_delivered: true, p_error: "no_devices", p_dead_tokens: [] });
    assert.equal(summary.delivered, 1);
  });

  it("forgets a dead token and still counts it delivered if another device took it", async () => {
    const apns = new FakeApns();
    apns.respond = (m) => (m.token === device(1).token ? { ok: false, status: 410, reason: "Unregistered" } : { ok: true });
    const db = new FakeDb([msg("a", [device(1), device(2)])]);
    const summary = await runSendPush(deps(db, apns).deps);
    const done = db.completion("a");
    assert.equal(done.p_delivered, true);
    assert.deepEqual(done.p_dead_tokens, [device(1).token]);
    assert.match(String(done.p_error), /dead: Unregistered/);
    assert.equal(summary.devices_removed, 1);
    assert.equal(summary.devices_sent, 1);
  });

  it("closes a notification whose every device is dead", async () => {
    const apns = new FakeApns();
    apns.respond = () => ({ ok: false, status: 400, reason: "BadDeviceToken" });
    const db = new FakeDb([msg("a", [device(1), device(2)])]);
    const summary = await runSendPush(deps(db, apns).deps);
    assert.deepEqual(db.completion("a"), { p_id: "a", p_delivered: true, p_error: "all_devices_unregistered", p_dead_tokens: [device(1).token, device(2).token] });
    assert.equal(summary.delivered, 1);
    assert.equal(summary.retrying, 0);
  });

  it("asks to retry when nothing got through for a reason that may pass", async () => {
    const apns = new FakeApns();
    apns.respond = () => ({ ok: false, status: 503, reason: "ServiceUnavailable" });
    const db = new FakeDb([msg("a", [device(1)])]);
    const { deps: d, logs } = deps(db, apns);
    const summary = await runSendPush(d);
    const done = db.completion("a");
    assert.equal(done.p_delivered, false);
    assert.equal(done.p_error, "failed: ServiceUnavailable");
    assert.equal(summary.retrying, 1);
    assert.equal(summary.delivered, 0);
    assert.equal(logs.length, 1);
  });

  it("retries when one device is dead and the other is only unreachable, forgetting the dead one", async () => {
    const apns = new FakeApns();
    apns.respond = (m) => (m.token === device(1).token ? { ok: false, status: 410, reason: "Unregistered" } : { ok: false, status: 429, reason: "TooManyRequests" });
    const db = new FakeDb([msg("a", [device(1), device(2)])]);
    await runSendPush(deps(db, apns).deps);
    const done = db.completion("a");
    assert.equal(done.p_delivered, false);
    assert.deepEqual(done.p_dead_tokens, [device(1).token]);
  });

  it("doesn't resend to a device that already has it when another failed", async () => {
    const apns = new FakeApns();
    apns.respond = (m) => (m.token === device(1).token ? { ok: true } : { ok: false, status: 503, reason: "ServiceUnavailable" });
    const db = new FakeDb([msg("a", [device(1), device(2)])]);
    await runSendPush(deps(db, apns).deps);
    const done = db.completion("a");
    assert.equal(done.p_delivered, true);
    assert.match(String(done.p_error), /failed: ServiceUnavailable/);
  });

  it("treats a crash while sending as a failure to retry, not a crash of the run", async () => {
    const apns = new FakeApns();
    apns.respond = () => {
      throw new Error("socket hang up");
    };
    const db = new FakeDb([msg("a", [device(1)]), msg("b", [device(2)])]);
    const summary = await runSendPush(deps(db, apns).deps);
    assert.equal(summary.retrying, 2);
    assert.match(String(db.completion("a").p_error), /NetworkError/);
  });

  it("closes a row it can't word, instead of retrying it for ever", async () => {
    const apns = new FakeApns();
    const db = new FakeDb([row("message", { preview: "x" }, { id: "bad", booking_id: null })]);
    const { deps: d, logs } = deps(db, apns);
    await runSendPush(d);
    assert.equal(apns.sent.length, 0);
    assert.equal(db.completion("bad").p_delivered, true);
    assert.match(String(db.completion("bad").p_error), /^unsendable: /);
    assert.equal(logs.length, 1);
  });

  it("keeps going when one row fails", async () => {
    const apns = new FakeApns();
    apns.respond = (m) => (m.payload.aps.alert.body === "hello bad" ? { ok: false, status: 503, reason: "ServiceUnavailable" } : { ok: true });
    const db = new FakeDb([msg("a", [device(1)]), msg("bad", [device(2)]), msg("c", [device(3)])]);
    const summary = await runSendPush(deps(db, apns).deps);
    assert.deepEqual([summary.delivered, summary.retrying], [2, 1]);
    assert.equal(db.completions().length, 3);
  });

  it("sends several at once, but never more than eight", async () => {
    const apns = new FakeApns();
    apns.respond = () => new Promise((resolve) => setTimeout(() => resolve({ ok: true }), 5));
    const db = new FakeDb(Array.from({ length: 30 }, (_, i) => msg(`m${i}`, [device(i % 9)])));
    const summary = await runSendPush(deps(db, apns).deps);
    assert.equal(summary.delivered, 30);
    assert.ok(apns.peak > 1 && apns.peak <= 8, `peak ${apns.peak}`);
  });

  it("does nothing when nothing is waiting", async () => {
    const apns = new FakeApns();
    const summary = await runSendPush(deps(new FakeDb([]), apns).deps);
    assert.equal(summary.claimed, 0);
    assert.equal(apns.sent.length, 0);
  });

  it("lets a database failure surface", async () => {
    const db = new FakeDb([]);
    db.failClaim = true;
    await assert.rejects(runSendPush(deps(db, new FakeApns()).deps), /database down/);
  });
});

// ---------------------------------------------------------------------------
// Who may call it
// ---------------------------------------------------------------------------
const SERVICE = "service-role-key-0123456789abcdef";
const CRON = "cron-secret-0123456789abcdef";

describe("who may call send-push", () => {
  it("accepts the service role key or the cron secret", () => {
    assert.equal(isAuthorized(`Bearer ${SERVICE}`, [SERVICE, CRON]), true);
    assert.equal(isAuthorized(`Bearer ${CRON}`, [SERVICE, CRON]), true);
  });

  it("refuses everyone else", () => {
    assert.equal(isAuthorized(null, [SERVICE]), false);
    assert.equal(isAuthorized("", [SERVICE]), false);
    assert.equal(isAuthorized(SERVICE, [SERVICE]), false); // no "Bearer"
    assert.equal(isAuthorized("Bearer wrong-wrong-wrong-wrong", [SERVICE, CRON]), false);
    assert.equal(isAuthorized(`Bearer ${SERVICE}x`, [SERVICE]), false);
    assert.equal(isAuthorized(`Bearer ${SERVICE.slice(0, -1)}`, [SERVICE]), false);
    assert.equal(isAuthorized("Bearer anon-key-that-everybody-has-0000", [SERVICE, CRON]), false);
    assert.equal(isAuthorized(`Basic ${SERVICE}`, [SERVICE]), false);
  });

  it("never lets a blank or short setting let blank or short requests in", () => {
    assert.equal(isAuthorized("Bearer ", ["", undefined]), false);
    assert.equal(isAuthorized("Bearer x", ["x"]), false);
    assert.equal(isAuthorized("Bearer short-secret", ["short-secret"]), false);
    assert.equal(isAuthorized(`Bearer ${CRON}`, [undefined, ""]), false);
  });

  it("answers 405, 401 and 503 before touching the queue", async () => {
    const db = new FakeDb([msg("a", [device(1)])]);
    const live = deps(db, new FakeApns()).deps;
    assert.equal((await sendPushRequest({ method: "GET", authorization: `Bearer ${SERVICE}` }, [SERVICE], live)).status, 405);
    assert.equal((await sendPushRequest({ method: "POST", authorization: null }, [SERVICE], live)).status, 401);
    assert.equal((await sendPushRequest({ method: "POST", authorization: `Bearer ${SERVICE}` }, [SERVICE], null)).status, 503);
    assert.equal(db.calls.length, 0);
  });

  it("runs for an authorised POST", async () => {
    const db = new FakeDb([msg("a", [device(1)])]);
    const result = await sendPushRequest({ method: "POST", authorization: `Bearer ${CRON}` }, [SERVICE, CRON], deps(db, new FakeApns()).deps);
    assert.equal(result.status, 200);
    assert.equal((result.body as { claimed: number }).claimed, 1);
  });
});

// ---------------------------------------------------------------------------
// Talking to APNs
// ---------------------------------------------------------------------------
async function makeKey() {
  const pair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as unknown as {
    privateKey: never;
    publicKey: never;
  };
  const pkcs8 = new Uint8Array(await crypto.subtle.exportKey("pkcs8", pair.privateKey));
  const lines = Buffer.from(pkcs8).toString("base64").match(/.{1,64}/g)!.join("\n");
  return { pem: `-----BEGIN PRIVATE KEY-----\n${lines}\n-----END PRIVATE KEY-----\n`, publicKey: pair.publicKey, pkcs8 };
}

function decodePart(part: string) {
  return new Uint8Array(Buffer.from(part.replace(/-/g, "+").replace(/_/g, "/"), "base64"));
}

const message = (extra: Partial<ApnsMessage> = {}): ApnsMessage => ({
  token: "ab".repeat(32),
  environment: "sandbox",
  payload: { aps: { alert: { title: "T", body: "B" }, sound: "default", badge: 1 }, slate: { url: "slate://booking/x", kind: "message" } },
  expiration: 1_800_000_000,
  priority: 10,
  ...extra,
});

describe("the provider token", () => {
  it("reads a .p8 key, with real or literal line breaks", async () => {
    const { pem, pkcs8 } = await makeKey();
    assert.deepEqual(pemToPkcs8(pem), pkcs8);
    assert.deepEqual(pemToPkcs8(pem.trim().replace(/\n/g, "\\n")), pkcs8);
    assert.throws(() => pemToPkcs8("-----BEGIN PRIVATE KEY-----\n-----END PRIVATE KEY-----"), /empty/);
  });

  it("is a JWT Apple's key would verify, with the right header and claims", async () => {
    const { pem, publicKey } = await makeKey();
    const token = await makeProviderToken(await importApnsKey(pem), "KEY1234567", "TEAM123456", 1_800_000_000);
    const [h, c, s] = token.split(".");
    assert.deepEqual(JSON.parse(Buffer.from(decodePart(h)).toString()), { alg: "ES256", kid: "KEY1234567" });
    assert.deepEqual(JSON.parse(Buffer.from(decodePart(c)).toString()), { iss: "TEAM123456", iat: 1_800_000_000 });
    assert.equal(decodePart(s).length, 64); // raw r||s, which is what JWS ES256 wants
    assert.equal(await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, publicKey, decodePart(s), new TextEncoder().encode(`${h}.${c}`)), true);
    assert.equal(await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, publicKey, decodePart(s), new TextEncoder().encode(`${h}.${c}x`)), false);
    assert.ok(!/[+/=]/.test(token), "base64url, no padding");
  });
});

describe("the APNs request", () => {
  async function sender(respond: (url: string, init: Parameters<FetchLike>[1]) => { status: number; body?: string } | Error, clock = { now: new Date("2026-11-12T20:00:00Z") }) {
    const { pem } = await makeKey();
    const requests: { url: string; init: Parameters<FetchLike>[1] }[] = [];
    const fetchImpl: FetchLike = async (url, init) => {
      requests.push({ url, init });
      const answer = respond(url, init);
      if (answer instanceof Error) throw answer;
      return { status: answer.status, text: async () => answer.body ?? "" };
    };
    const apns = createApnsSender({ keyPem: pem, keyId: "KEY1234567", teamId: "TEAM123456", topic: "com.example.slate" }, fetchImpl, () => clock.now);
    return { apns, requests, clock };
  }

  it("posts the payload to the right server with the headers Apple requires", async () => {
    const { apns, requests } = await sender(() => ({ status: 200 }));
    const result = await apns.send(message({ collapseId: "rem-1" }));
    assert.deepEqual(result, { ok: true });
    const { url, init } = requests[0];
    assert.equal(url, `https://api.sandbox.push.apple.com/3/device/${"ab".repeat(32)}`);
    assert.equal(init.method, "POST");
    assert.match(init.headers.authorization, /^bearer [\w-]+\.[\w-]+\.[\w-]+$/);
    assert.equal(init.headers["apns-topic"], "com.example.slate");
    assert.equal(init.headers["apns-push-type"], "alert");
    assert.equal(init.headers["apns-priority"], "10");
    assert.equal(init.headers["apns-expiration"], "1800000000");
    assert.equal(init.headers["apns-collapse-id"], "rem-1");
    assert.deepEqual(JSON.parse(init.body), message().payload);
  });

  it("uses the production server for production tokens, and omits a missing collapse id", async () => {
    const { apns, requests } = await sender(() => ({ status: 200 }));
    await apns.send(message({ environment: "production" }));
    assert.ok(requests[0].url.startsWith("https://api.push.apple.com/3/device/"));
    assert.equal("apns-collapse-id" in requests[0].init.headers, false);
  });

  it("reads Apple's reasons", async () => {
    const { apns } = await sender(() => ({ status: 410, body: JSON.stringify({ reason: "Unregistered", timestamp: 1 }) }));
    assert.deepEqual(await apns.send(message()), { ok: false, status: 410, reason: "Unregistered" });
  });

  it("copes with an answer that isn't JSON", async () => {
    const { apns } = await sender(() => ({ status: 502, body: "<html>Bad gateway</html>" }));
    assert.deepEqual(await apns.send(message()), { ok: false, status: 502, reason: "HTTP 502" });
  });

  it("reports a network failure as a failure with status 0", async () => {
    const { apns } = await sender(() => new Error("connection reset"));
    const result = await apns.send(message());
    assert.equal(result.ok, false);
    assert.equal((result as { status: number }).status, 0);
    assert.match((result as { reason: string }).reason, /NetworkError: connection reset/);
  });

  it("reuses one token for half an hour, then makes a new one", async () => {
    const { apns, requests, clock } = await sender(() => ({ status: 200 }));
    await apns.send(message());
    clock.now = new Date(clock.now.getTime() + 60_000);
    await apns.send(message());
    assert.equal(requests[0].init.headers.authorization, requests[1].init.headers.authorization);
    clock.now = new Date(clock.now.getTime() + TOKEN_WINDOW_SECONDS * 1000);
    await apns.send(message());
    assert.notEqual(requests[2].init.headers.authorization, requests[0].init.headers.authorization);
    const claims = JSON.parse(Buffer.from(decodePart(requests[2].init.headers.authorization.split(" ")[1].split(".")[1])).toString());
    assert.equal(claims.iat % TOKEN_WINDOW_SECONDS, 0);
  });

  it("makes a new token after Apple says ours expired", async () => {
    let first = true;
    const { apns, requests } = await sender(() => {
      if (first) {
        first = false;
        return { status: 403, body: JSON.stringify({ reason: "ExpiredProviderToken" }) };
      }
      return { status: 200 };
    });
    assert.equal((await apns.send(message())).ok, false);
    assert.equal((await apns.send(message())).ok, true);
    assert.notEqual(requests[0].init.headers.authorization, requests[1].init.headers.authorization);
  });

  it("doesn't build a token until something is sent", async () => {
    const created = await sender(() => ({ status: 200 }));
    assert.equal(created.requests.length, 0);
  });

  it("reports an unreadable key as a failed send, not a crash", async () => {
    const apns = createApnsSender({ keyPem: "not a key", keyId: "K", teamId: "T", topic: "t" }, async () => ({ status: 200, text: async () => "" }));
    const result = await apns.send(message());
    assert.equal(result.ok, false);
    assert.equal((result as { status: number }).status, 0);
  });
});
