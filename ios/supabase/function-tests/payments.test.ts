import assert from "node:assert/strict";
import { describe, it } from "node:test";
import {
  connectOnboarding,
  connectRedirect,
  createPaymentIntent,
  DbError,
  handleStripeWebhook,
  issueRefunds,
  processRefundsRequest,
} from "../functions/_shared/payments.ts";
import type { Deps, StripeEvent, StripeIntent, StripeLike } from "../functions/_shared/payments.ts";

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------
type Handler = (args: Record<string, unknown>) => unknown;

class FakeDb {
  calls: { fn: string; args: Record<string, unknown> }[] = [];
  handlers: Record<string, Handler>;
  constructor(handlers: Record<string, Handler>) {
    this.handlers = handlers;
  }
  async rpc<T = unknown>(fn: string, args: Record<string, unknown> = {}): Promise<T> {
    this.calls.push({ fn, args });
    const handler = this.handlers[fn];
    if (!handler) throw new Error(`unexpected database call: ${fn}`);
    const result = handler(args);
    if (result instanceof Error) throw result;
    return result as T;
  }
  called(fn: string) {
    return this.calls.filter((call) => call.fn === fn);
  }
}

interface StripeCalls {
  intentsCreated: { params: Record<string, unknown>; key?: string }[];
  intentsRetrieved: string[];
  refunds: { params: Record<string, unknown>; key?: string }[];
  accountsCreated: { params: Record<string, unknown>; key?: string }[];
  links: Record<string, unknown>[];
}

function makeStripe(overrides: Partial<{
  createIntent: (params: Record<string, unknown>) => Promise<StripeIntent>;
  retrieveIntent: (id: string) => Promise<StripeIntent>;
  createRefund: (params: Record<string, unknown>) => Promise<{ id: string; status: string | null; failure_reason?: string | null }>;
  retrieveAccount: (id: string) => Promise<{ id: string; charges_enabled?: boolean; payouts_enabled?: boolean; details_submitted?: boolean }>;
  constructEvent: (payload: string, signature: string, secret: string) => Promise<StripeEvent>;
}> = {}): { stripe: StripeLike; calls: StripeCalls } {
  const calls: StripeCalls = { intentsCreated: [], intentsRetrieved: [], refunds: [], accountsCreated: [], links: [] };
  const stripe: StripeLike = {
    paymentIntents: {
      async create(params, options) {
        calls.intentsCreated.push({ params, key: options?.idempotencyKey });
        return overrides.createIntent ? overrides.createIntent(params) : { id: "pi_new", status: "requires_payment_method", client_secret: "pi_new_secret_x" };
      },
      async retrieve(id) {
        calls.intentsRetrieved.push(id);
        return overrides.retrieveIntent ? overrides.retrieveIntent(id) : { id, status: "requires_payment_method", client_secret: `${id}_secret` };
      },
    },
    refunds: {
      async create(params, options) {
        calls.refunds.push({ params, key: options?.idempotencyKey });
        return overrides.createRefund ? overrides.createRefund(params) : { id: "re_1", status: "succeeded" };
      },
    },
    accounts: {
      async create(params, options) {
        calls.accountsCreated.push({ params, key: options?.idempotencyKey });
        return { id: "acct_new" };
      },
      async retrieve(id) {
        return overrides.retrieveAccount ? overrides.retrieveAccount(id) : { id, charges_enabled: false, payouts_enabled: false, details_submitted: false };
      },
    },
    accountLinks: {
      async create(params) {
        calls.links.push(params);
        return { url: "https://connect.stripe.test/onboard/abc" };
      },
    },
    webhooks: {
      async constructEventAsync(payload, signature, secret) {
        if (overrides.constructEvent) return overrides.constructEvent(payload, signature, secret);
        return JSON.parse(payload) as StripeEvent;
      },
    },
  };
  return { stripe, calls };
}

function makeDeps(db: FakeDb, stripe: StripeLike, config: Partial<Deps["config"]> = {}): { deps: Deps; logs: string[] } {
  const logs: string[] = [];
  return {
    deps: {
      db,
      stripe,
      config: {
        platformFeeBps: 0,
        functionsBaseUrl: "https://ref.supabase.co/functions/v1",
        webhookSecret: "whsec_test",
        appScheme: "slate",
        ...config,
      },
      log: (message) => logs.push(message),
    },
    logs,
  };
}

const USER = "11111111-1111-4111-8111-111111111111";
const BOOKING = "22222222-2222-4222-8222-222222222222";
const PAYMENT = "33333333-3333-4333-8333-333333333333";

const prepared = (extra: Record<string, unknown> = {}) => ({
  payment_id: PAYMENT,
  booking_id: BOOKING,
  kind: "deposit",
  amount_cents: 50000,
  currency: "usd",
  fee_cents: 0,
  destination: "acct_creator",
  existing_intent: null,
  description: "Deposit for Portrait session with Maya Chen",
  ...extra,
});

// ---------------------------------------------------------------------------
// Paying
// ---------------------------------------------------------------------------
describe("createPaymentIntent", () => {
  it("opens a payment for the amount the database says, paid out to the creator", async () => {
    const db = new FakeDb({ payment_prepare: () => prepared(), payment_attach_intent: () => null });
    const { stripe, calls } = makeStripe();
    const { deps } = makeDeps(db, stripe);

    const result = await createPaymentIntent(deps, USER, { booking_id: BOOKING, kind: "deposit" });

    assert.equal(result.status, 200);
    assert.deepEqual(result.body, { payment_id: PAYMENT, client_secret: "pi_new_secret_x", amount_cents: 50000, currency: "usd" });
    assert.deepEqual(db.called("payment_prepare")[0].args, { p_user_id: USER, p_booking_id: BOOKING, p_kind: "deposit", p_fee_bps: 0 });
    assert.equal(calls.intentsCreated.length, 1);
    const { params, key } = calls.intentsCreated[0];
    assert.equal(params.amount, 50000);
    assert.equal(params.currency, "usd");
    assert.deepEqual(params.transfer_data, { destination: "acct_creator" });
    assert.deepEqual(params.payment_method_types, ["card"]);
    assert.deepEqual(params.metadata, { payment_id: PAYMENT, booking_id: BOOKING, kind: "deposit" });
    assert.equal("application_fee_amount" in params, false, "no fee unless the database asks for one");
    assert.equal(key, `payment-${PAYMENT}`, "a retry can't create a second charge");
    assert.deepEqual(db.called("payment_attach_intent")[0].args, { p_payment_id: PAYMENT, p_intent_id: "pi_new" });
  });

  it("charges the platform fee the database worked out", async () => {
    const db = new FakeDb({ payment_prepare: () => prepared({ fee_cents: 1250 }), payment_attach_intent: () => null });
    const { stripe, calls } = makeStripe();
    const { deps } = makeDeps(db, stripe, { platformFeeBps: 250 });

    await createPaymentIntent(deps, USER, { booking_id: BOOKING, kind: "deposit" });

    assert.equal(db.called("payment_prepare")[0].args.p_fee_bps, 250);
    assert.equal(calls.intentsCreated[0].params.application_fee_amount, 1250);
  });

  it("ignores any amount, user or destination the caller tries to send", async () => {
    const db = new FakeDb({ payment_prepare: () => prepared(), payment_attach_intent: () => null });
    const { stripe, calls } = makeStripe();
    const { deps } = makeDeps(db, stripe);

    await createPaymentIntent(deps, USER, {
      booking_id: BOOKING, kind: "deposit", amount_cents: 1, amount: 1, destination: "acct_me", user_id: "someone-else", p_fee_bps: 9999,
    });

    assert.equal(calls.intentsCreated[0].params.amount, 50000);
    assert.deepEqual(calls.intentsCreated[0].params.transfer_data, { destination: "acct_creator" });
    assert.equal(db.called("payment_prepare")[0].args.p_user_id, USER);
    assert.equal(db.called("payment_prepare")[0].args.p_fee_bps, 0);
  });

  it("rejects malformed requests before touching anything", async () => {
    const db = new FakeDb({});
    const { stripe, calls } = makeStripe();
    const { deps } = makeDeps(db, stripe);
    for (const input of [null, "x", [], {}, { booking_id: "nope", kind: "deposit" }, { booking_id: BOOKING, kind: "tip" }, { booking_id: BOOKING }]) {
      const result = await createPaymentIntent(deps, USER, input);
      assert.equal(result.status, 400, JSON.stringify(input));
    }
    assert.equal(db.calls.length, 0);
    assert.equal(calls.intentsCreated.length, 0);
  });

  it("turns the database's refusals into clear answers", async () => {
    const cases: [string, number][] = [
      ["not_found", 404], ["payments_not_ready", 409], ["hold_expired", 409], ["payment_not_due", 409],
      ["balance_not_due", 409], ["nothing_due", 409], ["already_paid", 409],
    ];
    for (const [token, status] of cases) {
      const db = new FakeDb({ payment_prepare: () => new DbError(`ERROR: ${token}`) });
      const { stripe, calls } = makeStripe();
      const { deps } = makeDeps(db, stripe);
      const result = await createPaymentIntent(deps, USER, { booking_id: BOOKING, kind: "deposit" });
      assert.equal(result.status, status, token);
      assert.deepEqual(result.body, { error: token });
      assert.equal(calls.intentsCreated.length, 0, "nothing is charged when the database says no");
    }
  });

  it("hides unexpected database errors", async () => {
    const db = new FakeDb({ payment_prepare: () => new DbError("connection reset: secret details") });
    const { stripe } = makeStripe();
    const { deps, logs } = makeDeps(db, stripe);
    const result = await createPaymentIntent(deps, USER, { booking_id: BOOKING, kind: "deposit" });
    assert.equal(result.status, 500);
    assert.deepEqual(result.body, { error: "server_error" });
    assert.equal(logs.length, 1);
  });

  it("reuses an unfinished payment instead of creating another", async () => {
    const db = new FakeDb({ payment_prepare: () => prepared({ existing_intent: "pi_old" }) });
    const { stripe, calls } = makeStripe();
    const { deps } = makeDeps(db, stripe);

    const result = await createPaymentIntent(deps, USER, { booking_id: BOOKING, kind: "deposit" });

    assert.equal(result.status, 200);
    assert.equal((result.body as { client_secret: string }).client_secret, "pi_old_secret");
    assert.equal(calls.intentsCreated.length, 0);
    assert.equal(db.called("payment_attach_intent").length, 0);
  });

  it("won't start a payment that already went through or is going through", async () => {
    for (const [status, error] of [["succeeded", "already_paid"], ["processing", "payment_processing"]]) {
      const db = new FakeDb({ payment_prepare: () => prepared({ existing_intent: "pi_old" }) });
      const { stripe, calls } = makeStripe({ retrieveIntent: async (id) => ({ id, status, client_secret: "x" }) });
      const { deps } = makeDeps(db, stripe);
      const result = await createPaymentIntent(deps, USER, { booking_id: BOOKING, kind: "deposit" });
      assert.equal(result.status, 409);
      assert.deepEqual(result.body, { error });
      assert.equal(calls.intentsCreated.length, 0);
    }
  });

  it("closes out a cancelled payment so the next attempt starts fresh", async () => {
    const db = new FakeDb({ payment_prepare: () => prepared({ existing_intent: "pi_old" }), payment_record_failure: () => null });
    const { stripe } = makeStripe({ retrieveIntent: async (id) => ({ id, status: "canceled", client_secret: null }) });
    const { deps } = makeDeps(db, stripe);
    const result = await createPaymentIntent(deps, USER, { booking_id: BOOKING, kind: "deposit" });
    assert.equal(result.status, 409);
    assert.deepEqual(result.body, { error: "payment_stale" });
    assert.equal(db.called("payment_record_failure")[0].args.p_intent_id, "pi_old");
  });

  it("reports a Stripe failure without leaking its message, and records no intent", async () => {
    const db = new FakeDb({ payment_prepare: () => prepared() });
    const { stripe } = makeStripe({ createIntent: async () => { throw new Error("sk_live_secret exploded"); } });
    const { deps } = makeDeps(db, stripe);
    const result = await createPaymentIntent(deps, USER, { booking_id: BOOKING, kind: "deposit" });
    assert.equal(result.status, 502);
    assert.deepEqual(result.body, { error: "stripe_error" });
    assert.equal(db.called("payment_attach_intent").length, 0);
  });

  it("also pays balances", async () => {
    const db = new FakeDb({
      payment_prepare: () => prepared({ kind: "balance", amount_cents: 150000 }), payment_attach_intent: () => null,
    });
    const { stripe, calls } = makeStripe();
    const { deps } = makeDeps(db, stripe);
    const result = await createPaymentIntent(deps, USER, { booking_id: BOOKING, kind: "balance" });
    assert.equal(result.status, 200);
    assert.equal(calls.intentsCreated[0].params.amount, 150000);
    assert.equal((calls.intentsCreated[0].params.metadata as Record<string, string>).kind, "balance");
  });
});

// ---------------------------------------------------------------------------
// Refunds
// ---------------------------------------------------------------------------
const refundRow = (id: string, amount: number, intent: string | null = "pi_paid") => ({
  refund_id: id, amount_cents: amount, payment_intent_id: intent, stripe_refund_id: null,
});

describe("issueRefunds", () => {
  it("sends each owed refund to Stripe, taking it back from the creator", async () => {
    const db = new FakeDb({ refunds_to_process: () => [refundRow("r1", 25000)], refund_record_result: () => null });
    const { stripe, calls } = makeStripe({ createRefund: async () => ({ id: "re_9", status: "succeeded" }) });
    const { deps } = makeDeps(db, stripe);

    const outcomes = await issueRefunds(deps, BOOKING);

    assert.deepEqual(outcomes, [{ refund_id: "r1", status: "succeeded" }]);
    assert.deepEqual(calls.refunds[0].params, {
      payment_intent: "pi_paid", amount: 25000, reverse_transfer: true, refund_application_fee: true, metadata: { refund_id: "r1" },
    });
    assert.equal(calls.refunds[0].key, "refund-r1", "asking twice can't refund twice");
    assert.deepEqual(db.called("refund_record_result")[0].args, { p_refund_id: "r1", p_status: "succeeded", p_stripe_refund_id: "re_9", p_message: null });
  });

  it("keeps a refund pending while Stripe is still working on it", async () => {
    const db = new FakeDb({ refunds_to_process: () => [refundRow("r1", 100)], refund_record_result: () => null });
    const { stripe } = makeStripe({ createRefund: async () => ({ id: "re_p", status: "pending" }) });
    const { deps } = makeDeps(db, stripe);
    assert.deepEqual(await issueRefunds(deps, BOOKING), [{ refund_id: "r1", status: "pending" }]);
    assert.equal(db.called("refund_record_result")[0].args.p_status, "pending");
    assert.equal(db.called("refund_record_result")[0].args.p_stripe_refund_id, "re_p");
  });

  it("records a refund Stripe reports as failed, with the reason", async () => {
    const db = new FakeDb({ refunds_to_process: () => [refundRow("r1", 100)], refund_record_result: () => null });
    const { stripe } = makeStripe({ createRefund: async () => ({ id: "re_f", status: "failed", failure_reason: "expired_or_canceled_card" }) });
    const { deps } = makeDeps(db, stripe);
    assert.deepEqual(await issueRefunds(deps, BOOKING), [{ refund_id: "r1", status: "failed" }]);
    assert.equal(db.called("refund_record_result")[0].args.p_message, "expired_or_canceled_card");
  });

  it("leaves a refund pending when Stripe can't be reached, so it is tried again", async () => {
    for (const type of ["StripeConnectionError", "StripeAPIError", "StripeRateLimitError", "StripeAuthenticationError", undefined]) {
      const db = new FakeDb({ refunds_to_process: () => [refundRow("r1", 100)], refund_record_result: () => null });
      const { stripe } = makeStripe({ createRefund: async () => { throw Object.assign(new Error("down"), { type }); } });
      const { deps } = makeDeps(db, stripe);
      assert.deepEqual(await issueRefunds(deps, BOOKING), [{ refund_id: "r1", status: "retry" }], String(type));
      assert.equal(db.called("refund_record_result").length, 0, "nothing is recorded, so it stays pending");
    }
  });

  it("gives up on a refund Stripe rejects for good", async () => {
    for (const type of ["StripeInvalidRequestError", "StripeCardError"]) {
      const db = new FakeDb({ refunds_to_process: () => [refundRow("r1", 100)], refund_record_result: () => null });
      const { stripe } = makeStripe({ createRefund: async () => { throw Object.assign(new Error("charge_already_refunded"), { type }); } });
      const { deps } = makeDeps(db, stripe);
      assert.deepEqual(await issueRefunds(deps, BOOKING), [{ refund_id: "r1", status: "failed" }]);
      assert.equal(db.called("refund_record_result")[0].args.p_status, "failed");
      assert.match(String(db.called("refund_record_result")[0].args.p_message), /charge_already_refunded/);
    }
  });

  it("handles several refunds independently", async () => {
    const db = new FakeDb({
      refunds_to_process: () => [refundRow("r1", 100), refundRow("r2", 200), refundRow("r3", 300, null)],
      refund_record_result: () => null,
    });
    let n = 0;
    const { stripe, calls } = makeStripe({
      createRefund: async () => {
        n += 1;
        if (n === 1) throw Object.assign(new Error("blip"), { type: "StripeAPIError" });
        return { id: `re_${n}`, status: "succeeded" };
      },
    });
    const { deps } = makeDeps(db, stripe);
    assert.deepEqual(await issueRefunds(deps, BOOKING), [
      { refund_id: "r1", status: "retry" }, { refund_id: "r2", status: "succeeded" }, { refund_id: "r3", status: "failed" },
    ]);
    assert.equal(calls.refunds.length, 2, "a refund with no Stripe payment behind it is never sent");
  });

  it("does nothing when nothing is owed", async () => {
    const db = new FakeDb({ refunds_to_process: () => [] });
    const { stripe, calls } = makeStripe();
    const { deps } = makeDeps(db, stripe);
    assert.deepEqual(await issueRefunds(deps, BOOKING), []);
    assert.equal(calls.refunds.length, 0);
  });
});

describe("processRefundsRequest", () => {
  it("lets either person on the booking trigger the refunds", async () => {
    const db = new FakeDb({ is_booking_party: () => true, refunds_to_process: () => [refundRow("r1", 100)], refund_record_result: () => null });
    const { stripe, calls } = makeStripe();
    const { deps } = makeDeps(db, stripe);
    const result = await processRefundsRequest(deps, USER, { booking_id: BOOKING });
    assert.equal(result.status, 200);
    assert.deepEqual(result.body, { refunds: [{ refund_id: "r1", status: "succeeded" }] });
    assert.deepEqual(db.called("is_booking_party")[0].args, { p_user_id: USER, p_booking_id: BOOKING });
    assert.equal(calls.refunds.length, 1);
  });

  it("tells strangers there is no such booking", async () => {
    const db = new FakeDb({ is_booking_party: () => false });
    const { stripe, calls } = makeStripe();
    const { deps } = makeDeps(db, stripe);
    const result = await processRefundsRequest(deps, USER, { booking_id: BOOKING });
    assert.equal(result.status, 404);
    assert.equal(calls.refunds.length, 0);
    assert.equal(db.called("refunds_to_process").length, 0);
  });

  it("rejects a malformed booking id", async () => {
    const { stripe } = makeStripe();
    const { deps } = makeDeps(new FakeDb({}), stripe);
    assert.equal((await processRefundsRequest(deps, USER, { booking_id: "../../etc" })).status, 400);
    assert.equal((await processRefundsRequest(deps, USER, null)).status, 400);
  });
});

// ---------------------------------------------------------------------------
// Webhook
// ---------------------------------------------------------------------------
const event = (type: string, object: Record<string, unknown>, id = "evt_1"): string =>
  JSON.stringify({ id, type, data: { object } });

const ourIntent = (extra: Record<string, unknown> = {}) => ({
  id: "pi_new", amount: 50000, amount_received: 50000, latest_charge: "ch_1", metadata: { payment_id: PAYMENT, booking_id: BOOKING, kind: "deposit" }, ...extra,
});

const webhookDb = (extra: Record<string, Handler> = {}) =>
  new FakeDb({
    webhook_claim_event: () => true,
    webhook_event_done: () => null,
    payment_record_success: () => ({ action: "confirmed", booking_id: BOOKING }),
    payment_record_failure: () => null,
    refund_record_by_stripe_id: () => null,
    connect_account_update: () => null,
    ...extra,
  });

describe("handleStripeWebhook", () => {
  it("refuses requests that aren't signed by Stripe", async () => {
    const db = webhookDb();
    const { stripe } = makeStripe({ constructEvent: async () => { throw new Error("No signatures found matching"); } });
    const { deps } = makeDeps(db, stripe);
    assert.equal((await handleStripeWebhook(deps, "{}", "t=1,v1=bad")).status, 400);
    assert.equal((await handleStripeWebhook(deps, "{}", null)).status, 400);
    assert.equal(db.calls.length, 0, "an unsigned request changes nothing");
  });

  it("verifies against the webhook secret using the exact body", async () => {
    let seen: string[] = [];
    const { stripe } = makeStripe({ constructEvent: async (payload, signature, secret) => { seen = [payload, signature, secret]; return JSON.parse(payload); } });
    const { deps } = makeDeps(webhookDb(), stripe);
    const body = event("ping", {});
    await handleStripeWebhook(deps, body, "t=1,v1=abc");
    assert.deepEqual(seen, [body, "t=1,v1=abc", "whsec_test"]);
  });

  it("records a successful payment and marks the event done", async () => {
    const db = webhookDb();
    const { stripe, calls } = makeStripe();
    const { deps } = makeDeps(db, stripe);

    const result = await handleStripeWebhook(deps, event("payment_intent.succeeded", ourIntent()), "sig");

    assert.equal(result.status, 200);
    assert.deepEqual(db.called("payment_record_success")[0].args, {
      p_intent_id: "pi_new", p_amount_cents: 50000, p_charge_id: "ch_1", p_method: "apple_pay",
    });
    assert.deepEqual(db.calls.map((call) => call.fn), ["webhook_claim_event", "payment_record_success", "webhook_event_done"]);
    assert.equal(calls.refunds.length, 0);
  });

  it("takes the amount from what Stripe says it received, not from our own records", async () => {
    const db = webhookDb();
    const { stripe } = makeStripe();
    const { deps } = makeDeps(db, stripe);
    await handleStripeWebhook(deps, event("payment_intent.succeeded", ourIntent({ amount: 50000, amount_received: 49000 })), "sig");
    assert.equal(db.called("payment_record_success")[0].args.p_amount_cents, 49000);
  });

  it("ignores payments that didn't come from this app", async () => {
    const db = webhookDb();
    const { stripe } = makeStripe();
    const { deps } = makeDeps(db, stripe);
    const result = await handleStripeWebhook(deps, event("payment_intent.succeeded", { id: "pi_other", amount: 1, metadata: {} }), "sig");
    assert.equal(result.status, 200);
    assert.equal(db.called("payment_record_success").length, 0);
    assert.equal(db.called("webhook_event_done").length, 1);
  });

  it("sends money back when it arrived for a booking that can't be honoured", async () => {
    const db = webhookDb({
      payment_record_success: () => ({ action: "refund_required", booking_id: BOOKING }),
      refunds_to_process: () => [refundRow("r1", 50000, "pi_new")],
      refund_record_result: () => null,
    });
    const { stripe, calls } = makeStripe();
    const { deps } = makeDeps(db, stripe);

    const result = await handleStripeWebhook(deps, event("payment_intent.succeeded", ourIntent()), "sig");

    assert.equal(result.status, 200);
    assert.equal(calls.refunds.length, 1);
    assert.equal(calls.refunds[0].params.amount, 50000);
    assert.equal(calls.refunds[0].params.payment_intent, "pi_new");
    assert.deepEqual(db.called("refunds_to_process")[0].args, { p_booking_id: BOOKING });
  });

  it("answers 500, and doesn't mark the event done, when recording fails, so Stripe tries again", async () => {
    const db = webhookDb({ payment_record_success: () => new DbError("deadlock detected") });
    const { stripe } = makeStripe();
    const { deps, logs } = makeDeps(db, stripe);
    const result = await handleStripeWebhook(deps, event("payment_intent.succeeded", ourIntent()), "sig");
    assert.equal(result.status, 500);
    assert.equal(db.called("webhook_event_done").length, 0);
    assert.ok(logs.length > 0);
  });

  it("surfaces a payment whose amount doesn't match instead of swallowing it", async () => {
    const db = webhookDb({ payment_record_success: () => new DbError("amount_mismatch") });
    const { stripe } = makeStripe();
    const { deps } = makeDeps(db, stripe);
    assert.equal((await handleStripeWebhook(deps, event("payment_intent.succeeded", ourIntent()), "sig")).status, 500);
  });

  it("skips an event it has already finished", async () => {
    const db = webhookDb({ webhook_claim_event: () => false });
    const { stripe } = makeStripe();
    const { deps } = makeDeps(db, stripe);
    const result = await handleStripeWebhook(deps, event("payment_intent.succeeded", ourIntent()), "sig");
    assert.equal(result.status, 200);
    assert.deepEqual(result.body, { received: true, duplicate: true });
    assert.equal(db.called("payment_record_success").length, 0);
  });

  it("records a failed payment with the reason", async () => {
    const db = webhookDb();
    const { stripe } = makeStripe();
    const { deps } = makeDeps(db, stripe);
    await handleStripeWebhook(deps, event("payment_intent.payment_failed", ourIntent({ last_payment_error: { message: "Your card was declined." } })), "sig");
    assert.deepEqual(db.called("payment_record_failure")[0].args, { p_intent_id: "pi_new", p_message: "Your card was declined." });
  });

  it("follows a refund through to its end", async () => {
    const cases: [string, Record<string, unknown>, string][] = [
      ["refund.updated", { id: "re_1", status: "succeeded" }, "succeeded"],
      ["refund.updated", { id: "re_1", status: "pending" }, "pending"],
      ["refund.updated", { id: "re_1", status: "requires_action" }, "pending"],
      ["refund.updated", { id: "re_1", status: "canceled" }, "failed"],
      ["refund.failed", { id: "re_1", status: "failed", failure_reason: "lost_or_stolen_card" }, "failed"],
      ["charge.refund.updated", { id: "re_1", status: "succeeded" }, "succeeded"],
    ];
    for (const [type, object, expected] of cases) {
      const db = webhookDb();
      const { stripe } = makeStripe();
      const { deps } = makeDeps(db, stripe);
      await handleStripeWebhook(deps, event(type, object), "sig");
      assert.equal(db.called("refund_record_by_stripe_id")[0].args.p_status, expected, `${type} ${object.status}`);
      assert.equal(db.called("refund_record_by_stripe_id")[0].args.p_stripe_refund_id, "re_1");
    }
  });

  it("updates what a creator can do when Stripe changes their account", async () => {
    const db = webhookDb();
    const { stripe } = makeStripe();
    const { deps } = makeDeps(db, stripe);
    await handleStripeWebhook(deps, event("account.updated", { id: "acct_1", charges_enabled: true, payouts_enabled: false, details_submitted: true }), "sig");
    assert.deepEqual(db.called("connect_account_update")[0].args, { p_account_id: "acct_1", p_charges: true, p_payouts: false, p_details: true });
  });

  it("acknowledges events it doesn't use", async () => {
    const db = webhookDb();
    const { stripe } = makeStripe();
    const { deps } = makeDeps(db, stripe);
    const result = await handleStripeWebhook(deps, event("customer.created", { id: "cus_1" }), "sig");
    assert.equal(result.status, 200);
    assert.deepEqual(db.calls.map((call) => call.fn), ["webhook_claim_event", "webhook_event_done"]);
  });
});

// ---------------------------------------------------------------------------
// Connect
// ---------------------------------------------------------------------------
describe("connectOnboarding", () => {
  it("creates an account the first time and returns a link to finish setting up", async () => {
    let stored: string | null = null;
    const db = new FakeDb({
      connect_account_for: () => stored,
      connect_account_save: (args) => { stored = args.p_account_id as string; return null; },
      connect_account_update: () => null,
    });
    const { stripe, calls } = makeStripe();
    const { deps } = makeDeps(db, stripe);

    const result = await connectOnboarding(deps, USER, {});

    assert.equal(result.status, 200);
    assert.deepEqual(result.body, {
      connected: true, charges_enabled: false, payouts_enabled: false, details_submitted: false, url: "https://connect.stripe.test/onboard/abc",
    });
    assert.equal(calls.accountsCreated.length, 1);
    assert.equal(calls.accountsCreated[0].params.type, "express");
    assert.deepEqual(calls.accountsCreated[0].params.capabilities, { card_payments: { requested: true }, transfers: { requested: true } });
    assert.equal(calls.accountsCreated[0].key, `connect-account-${USER}`, "two taps can't make two accounts");
    assert.deepEqual(db.called("connect_account_save")[0].args, { p_creator_id: USER, p_account_id: "acct_new" });
    assert.equal(calls.links[0].account, "acct_new");
    assert.equal(calls.links[0].type, "account_onboarding");
    assert.equal(calls.links[0].return_url, "https://ref.supabase.co/functions/v1/connect-redirect?to=return");
    assert.equal(calls.links[0].refresh_url, "https://ref.supabase.co/functions/v1/connect-redirect?to=refresh");
  });

  it("reuses the account it already has", async () => {
    const db = new FakeDb({ connect_account_for: () => "acct_existing", connect_account_update: () => null });
    const { stripe, calls } = makeStripe();
    const { deps } = makeDeps(db, stripe);
    await connectOnboarding(deps, USER, {});
    assert.equal(calls.accountsCreated.length, 0);
    assert.equal(calls.links[0].account, "acct_existing");
  });

  it("records what Stripe says and sends no link once the creator can be paid", async () => {
    const db = new FakeDb({ connect_account_for: () => "acct_ready", connect_account_update: () => null });
    const { stripe, calls } = makeStripe({ retrieveAccount: async (id) => ({ id, charges_enabled: true, payouts_enabled: true, details_submitted: true }) });
    const { deps } = makeDeps(db, stripe);
    const result = await connectOnboarding(deps, USER, {});
    assert.deepEqual(result.body, { connected: true, charges_enabled: true, payouts_enabled: true, details_submitted: true });
    assert.deepEqual(db.called("connect_account_update")[0].args, { p_account_id: "acct_ready", p_charges: true, p_payouts: true, p_details: true });
    assert.equal(calls.links.length, 0);
  });

  it("still offers a link when payments work but payouts aren't set up", async () => {
    const db = new FakeDb({ connect_account_for: () => "acct_half", connect_account_update: () => null });
    const { stripe, calls } = makeStripe({ retrieveAccount: async (id) => ({ id, charges_enabled: true, payouts_enabled: false, details_submitted: true }) });
    const { deps } = makeDeps(db, stripe);
    const result = await connectOnboarding(deps, USER, {});
    assert.equal((result.body as { url?: string }).url, "https://connect.stripe.test/onboard/abc");
    assert.equal(calls.links.length, 1);
  });

  it("can just report status, creating nothing", async () => {
    const db = new FakeDb({ connect_account_for: () => null });
    const { stripe, calls } = makeStripe();
    const { deps } = makeDeps(db, stripe);
    const result = await connectOnboarding(deps, USER, { action: "status" });
    assert.deepEqual(result.body, { connected: false, charges_enabled: false, payouts_enabled: false, details_submitted: false });
    assert.equal(calls.accountsCreated.length, 0);

    const db2 = new FakeDb({ connect_account_for: () => "acct_1", connect_account_update: () => null });
    const second = makeDeps(db2, makeStripe().stripe);
    const status = await connectOnboarding(second.deps, USER, { action: "status" });
    assert.equal("url" in (status.body as object), false);
  });

  it("sets up a company's account, not the person's, when its Owner asks", async () => {
    const COMPANY = "11111111-2222-4333-8444-555555555555";
    let stored: string | null = null;
    const db = new FakeDb({
      connect_authorize: () => true,
      connect_account_for: () => stored,
      connect_account_save: (args) => { stored = args.p_account_id as string; return null; },
      connect_account_update: () => null,
    });
    const { stripe, calls } = makeStripe();
    const { deps } = makeDeps(db, stripe);

    const result = await connectOnboarding(deps, USER, { organization_id: COMPANY });

    assert.equal(result.status, 200);
    assert.deepEqual(db.called("connect_authorize")[0].args, { p_user: USER, p_owner: COMPANY });
    assert.deepEqual(db.called("connect_account_save")[0].args, { p_creator_id: COMPANY, p_account_id: "acct_new" });
    assert.equal(calls.accountsCreated[0].key, `connect-account-${COMPANY}`, "one account per company");
    assert.deepEqual(calls.accountsCreated[0].params.metadata, { user_id: USER, organization_id: COMPANY });
  });

  it("refuses to touch a company's account for anyone who isn't allowed to", async () => {
    const COMPANY = "11111111-2222-4333-8444-555555555555";
    const db = new FakeDb({ connect_authorize: () => false });
    const { stripe, calls } = makeStripe();
    const { deps } = makeDeps(db, stripe);

    const result = await connectOnboarding(deps, USER, { organization_id: COMPANY });

    assert.equal(result.status, 404);
    assert.deepEqual(result.body, { error: "not_found" });
    assert.equal(calls.accountsCreated.length, 0);
    assert.equal(db.called("connect_account_for").length, 0, "nothing is even looked up");
    assert.equal(db.called("connect_account_save").length, 0);
  });

  it("refuses a company id that isn't one", async () => {
    const db = new FakeDb({});
    const { stripe } = makeStripe();
    const { deps } = makeDeps(db, stripe);
    for (const bad of ["acct_123", 7, "", null, "../../etc"]) {
      const result = await connectOnboarding(deps, USER, { organization_id: bad });
      assert.equal(result.status, 400, JSON.stringify(bad));
    }
    assert.equal(db.calls.length, 0);
  });

  it("asks for a profile first when the creator hasn't made one", async () => {
    const db = new FakeDb({
      connect_account_for: () => null,
      connect_account_save: () => new DbError('insert or update on table "creator_payment_accounts" violates foreign key constraint'),
    });
    const { stripe } = makeStripe();
    const { deps } = makeDeps(db, stripe);
    const result = await connectOnboarding(deps, USER, {});
    assert.equal(result.status, 409);
    assert.deepEqual(result.body, { error: "profile_required" });
  });

  it("reports Stripe trouble without its details", async () => {
    const db = new FakeDb({ connect_account_for: () => "acct_1", connect_account_update: () => null });
    const { stripe } = makeStripe({ retrieveAccount: async () => { throw Object.assign(new Error("rk_live_oops"), { type: "StripeAPIError" }); } });
    const { deps } = makeDeps(db, stripe);
    const result = await connectOnboarding(deps, USER, {});
    assert.equal(result.status, 502);
    assert.deepEqual(result.body, { error: "stripe_error" });
  });
});

describe("connectRedirect", () => {
  it("hands people back to the app", () => {
    for (const to of ["return", "refresh"]) {
      const result = connectRedirect(to, "slate");
      assert.equal(result.status, 302);
      assert.equal(result.headers?.Location, `slate://stripe/${to}`);
      assert.match(String(result.body), new RegExp(`slate://stripe/${to}`));
    }
  });

  it("only goes where it is meant to", () => {
    for (const to of [null, "", "other", "../x", "return?x=1", "http://evil.test"]) {
      assert.equal(connectRedirect(to, "slate").status, 400, String(to));
    }
  });
});
