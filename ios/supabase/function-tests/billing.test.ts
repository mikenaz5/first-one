import assert from "node:assert/strict";
import { describe, it } from "node:test";
import {
  billingRedirect,
  billingSession,
  billingSyncRequest,
  handleBillingEvent,
  planStatus,
  syncSeats,
} from "../functions/_shared/billing.ts";
import type { BillingDeps, BillingStripe, BillingSubscription } from "../functions/_shared/billing.ts";
import { handleStripeWebhook } from "../functions/_shared/payments.ts";
import type { Deps, StripeEvent } from "../functions/_shared/payments.ts";

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------
const USER = "aaaaaaaa-1111-4222-8333-444444444444";
const ORG = "bbbbbbbb-1111-4222-8333-444444444444";

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
  customers: { params: Record<string, unknown>; key?: string }[];
  checkouts: Record<string, unknown>[];
  portals: Record<string, unknown>[];
  cancelled: string[];
  updates: { id: string; params: Record<string, unknown>; key?: string }[];
}

function makeStripe(overrides: Partial<BillingStripe> = {}, subscription?: BillingSubscription) {
  const calls: StripeCalls = { customers: [], checkouts: [], portals: [], cancelled: [], updates: [] };
  const stripe: BillingStripe = {
    customers: {
      create: async (params, options) => {
        calls.customers.push({ params, key: options?.idempotencyKey });
        return { id: "cus_new" };
      },
    },
    checkout: {
      sessions: {
        create: async (params) => {
          calls.checkouts.push(params);
          return { url: "https://checkout.stripe.test/c/abc" };
        },
      },
    },
    billingPortal: {
      sessions: {
        create: async (params) => {
          calls.portals.push(params);
          return { url: "https://billing.stripe.test/p/abc" };
        },
      },
    },
    subscriptions: {
      retrieve: async (id) => subscription ?? { id, status: "active", items: { data: [{ id: "si_1", quantity: 10 }] } },
      cancel: async (id) => {
        calls.cancelled.push(id);
        return { id, status: "canceled" };
      },
    },
    subscriptionItems: {
      update: async (id, params, options) => {
        calls.updates.push({ id, params, key: options?.idempotencyKey });
        return { id, quantity: params.quantity as number };
      },
    },
    ...overrides,
  };
  return { stripe, calls };
}

function makeDeps(db: FakeDb, stripe: BillingStripe, config: Partial<BillingDeps["config"]> = {}) {
  const logs: { message: string; detail?: unknown }[] = [];
  const deps: BillingDeps = {
    db,
    stripe,
    config: { functionsBaseUrl: "https://ref.supabase.co/functions/v1", seatPriceId: "price_seat", trialDays: 14, ...config },
    log: (message, detail) => logs.push({ message, detail }),
  };
  return { deps, logs };
}

const prepared = (over: Record<string, unknown> = {}) => ({
  organization_id: ORG,
  name: "Acme Films",
  customer_id: null,
  subscription_id: null,
  status: "none",
  seats_wanted: 12,
  trial_eligible: true,
  ...over,
});

// ---------------------------------------------------------------------------
// The Owner opens a Stripe page
// ---------------------------------------------------------------------------
describe("billingSession", () => {
  it("starts a plan: makes the customer once and opens Checkout for the seats the team needs", async () => {
    let saved: string | null = null;
    const db = new FakeDb({
      billing_authorize: () => true,
      billing_prepare: () => prepared({ customer_id: saved }),
      billing_save_customer: (args) => { saved = args.p_customer_id as string; return null; },
    });
    const { stripe, calls } = makeStripe();
    const { deps } = makeDeps(db, stripe);

    const result = await billingSession(deps, USER, { organization_id: ORG });

    assert.equal(result.status, 200);
    assert.deepEqual(result.body, { kind: "checkout", url: "https://checkout.stripe.test/c/abc" });
    assert.equal(calls.customers.length, 1);
    assert.equal(calls.customers[0].key, `billing-customer-${ORG}`, "two taps can't make two customers");
    assert.deepEqual(calls.customers[0].params, { name: "Acme Films", metadata: { organization_id: ORG } });
    assert.deepEqual(db.called("billing_save_customer")[0].args, { p_org: ORG, p_customer_id: "cus_new" });
    const session = calls.checkouts[0];
    assert.equal(session.mode, "subscription");
    assert.equal(session.customer, "cus_new");
    assert.deepEqual(session.line_items, [{ price: "price_seat", quantity: 12 }]);
    assert.deepEqual(session.subscription_data, { metadata: { organization_id: ORG }, trial_period_days: 14 });
    assert.equal(session.client_reference_id, ORG);
    assert.equal(session.success_url, "https://ref.supabase.co/functions/v1/billing-redirect?to=return");
    assert.equal(session.cancel_url, "https://ref.supabase.co/functions/v1/billing-redirect?to=cancel");
  });

  it("asks the database whether the person may, before anything else", async () => {
    const db = new FakeDb({ billing_authorize: () => false });
    const { stripe, calls } = makeStripe();
    const { deps } = makeDeps(db, stripe);

    const result = await billingSession(deps, USER, { organization_id: ORG });

    assert.equal(result.status, 404);
    assert.deepEqual(db.called("billing_authorize")[0].args, { p_user: USER, p_org: ORG });
    assert.equal(db.called("billing_prepare").length, 0);
    assert.equal(calls.customers.length + calls.checkouts.length + calls.portals.length, 0);
  });

  it("gives no trial to a company that has had a plan before", async () => {
    const db = new FakeDb({
      billing_authorize: () => true,
      billing_prepare: () => prepared({ customer_id: "cus_old", trial_eligible: false, subscription_id: "sub_old", status: "canceled" }),
    });
    const { stripe, calls } = makeStripe();
    const { deps } = makeDeps(db, stripe);
    const result = await billingSession(deps, USER, { organization_id: ORG });
    assert.equal((result.body as { kind: string }).kind, "checkout", "a cancelled plan starts again");
    assert.deepEqual(calls.checkouts[0].subscription_data, { metadata: { organization_id: ORG } });
    assert.equal(calls.customers.length, 0, "the existing customer is reused");
  });

  it("gives no trial when none is configured", async () => {
    const db = new FakeDb({ billing_authorize: () => true, billing_prepare: () => prepared({ customer_id: "cus_1" }) });
    const { stripe, calls } = makeStripe();
    const { deps } = makeDeps(db, stripe, { trialDays: 0 });
    await billingSession(deps, USER, { organization_id: ORG });
    assert.deepEqual(calls.checkouts[0].subscription_data, { metadata: { organization_id: ORG } });
  });

  it("opens the billing portal for a company that has a plan", async () => {
    const db = new FakeDb({
      billing_authorize: () => true,
      billing_prepare: () => prepared({ customer_id: "cus_1", subscription_id: "sub_1", status: "active", trial_eligible: false }),
    });
    const { stripe, calls } = makeStripe();
    const { deps } = makeDeps(db, stripe);
    const result = await billingSession(deps, USER, { organization_id: ORG });
    assert.deepEqual(result.body, { kind: "portal", url: "https://billing.stripe.test/p/abc" });
    assert.deepEqual(calls.portals[0], { customer: "cus_1", return_url: "https://ref.supabase.co/functions/v1/billing-redirect?to=return" });
    assert.equal(calls.checkouts.length, 0);
  });

  it("won't start a second plan while one is running", async () => {
    const db = new FakeDb({
      billing_authorize: () => true,
      billing_prepare: () => prepared({ customer_id: "cus_1", subscription_id: "sub_1", status: "past_due", trial_eligible: false }),
    });
    const { stripe, calls } = makeStripe();
    const { deps } = makeDeps(db, stripe);
    const result = await billingSession(deps, USER, { organization_id: ORG, action: "checkout" });
    assert.equal(result.status, 409);
    assert.deepEqual(result.body, { error: "already_subscribed" });
    assert.equal(calls.checkouts.length, 0);
  });

  it("refuses requests that make no sense", async () => {
    const db = new FakeDb({});
    const { stripe } = makeStripe();
    const { deps } = makeDeps(db, stripe);
    for (const bad of [null, {}, { organization_id: "acct_1" }, { organization_id: 5 }, { organization_id: ORG, action: "delete" }]) {
      assert.equal((await billingSession(deps, USER, bad)).status, 400, JSON.stringify(bad));
    }
    assert.equal(db.calls.length, 0);
  });

  it("says plainly when billing isn't set up", async () => {
    const { stripe } = makeStripe();
    const { deps } = makeDeps(new FakeDb({}), stripe, { seatPriceId: "" });
    const result = await billingSession(deps, USER, { organization_id: ORG });
    assert.equal(result.status, 503);
    assert.deepEqual(result.body, { error: "billing_not_configured" });
  });

  it("reports a Stripe failure as one, and a database failure as one", async () => {
    const db = new FakeDb({ billing_authorize: () => true, billing_prepare: () => prepared({ customer_id: "cus_1" }) });
    const { stripe } = makeStripe({
      checkout: { sessions: { create: async () => { throw Object.assign(new Error("boom"), { type: "StripeAPIError" }); } } },
    });
    const { deps, logs } = makeDeps(db, stripe);
    assert.equal((await billingSession(deps, USER, { organization_id: ORG })).status, 502);
    assert.equal(logs[0].message, "stripe error");

    const broken = makeDeps(new FakeDb({ billing_authorize: () => { throw new Error("connection lost"); } }), makeStripe().stripe);
    assert.equal((await billingSession(broken.deps, USER, { organization_id: ORG })).status, 500);
  });
});

describe("billingRedirect", () => {
  it("hands the browser back to the app", () => {
    const result = billingRedirect("return", "slate");
    assert.equal(result.status, 302);
    assert.equal(result.headers?.Location, "slate://billing/return");
    assert.equal(billingRedirect("cancel", "slate").headers?.Location, "slate://billing/cancel");
  });
  it("sends nowhere else", () => {
    for (const to of [null, "", "https://evil.test", "return/../x"]) assert.equal(billingRedirect(to, "slate").status, 400);
  });
});

// ---------------------------------------------------------------------------
// Stripe's word on a plan
// ---------------------------------------------------------------------------
describe("planStatus", () => {
  it("folds Stripe's statuses into the four the app knows", () => {
    assert.equal(planStatus("trialing"), "trialing");
    assert.equal(planStatus("active"), "active");
    for (const s of ["past_due", "unpaid", "paused"]) assert.equal(planStatus(s), "past_due", s);
    for (const s of ["canceled", "incomplete_expired"]) assert.equal(planStatus(s), "canceled", s);
    assert.equal(planStatus("incomplete"), null, "no plan until the first payment goes through");
    assert.equal(planStatus(undefined), null);
  });
});

const subscriptionEvent = (type: string, object: Record<string, unknown>): StripeEvent => ({ id: "evt_1", type, data: { object } });
const subscriptionObject = (over: Record<string, unknown> = {}) => ({
  id: "sub_1",
  customer: "cus_1",
  status: "active",
  cancel_at_period_end: false,
  current_period_end: 1_800_000_000,
  trial_end: null,
  items: { data: [{ id: "si_1", quantity: 12 }] },
  metadata: { organization_id: ORG },
  ...over,
});

describe("handleBillingEvent", () => {
  it("records a subscription with the seats and dates Stripe reports", async () => {
    const db = new FakeDb({ billing_record_subscription: () => ({}) });
    const { deps } = makeDeps(db, makeStripe().stripe);
    const handled = await handleBillingEvent(deps, subscriptionEvent("customer.subscription.updated", subscriptionObject({ trial_end: 1_790_000_000, cancel_at_period_end: true })));
    assert.equal(handled, true);
    assert.deepEqual(db.called("billing_record_subscription")[0].args, {
      p_org: ORG,
      p_customer_id: "cus_1",
      p_subscription_id: "sub_1",
      p_status: "active",
      p_quantity: 12,
      p_period_end: new Date(1_800_000_000_000).toISOString(),
      p_trial_end: new Date(1_790_000_000_000).toISOString(),
      p_cancel_at_period_end: true,
    });
  });

  it("finds the company by customer when the metadata is missing", async () => {
    const db = new FakeDb({ billing_org_for_customer: () => ORG, billing_record_subscription: () => ({}) });
    const { deps } = makeDeps(db, makeStripe().stripe);
    await handleBillingEvent(deps, subscriptionEvent("customer.subscription.created", subscriptionObject({ metadata: {} })));
    assert.deepEqual(db.called("billing_org_for_customer")[0].args, { p_customer_id: "cus_1" });
    assert.equal(db.called("billing_record_subscription")[0].args.p_org, ORG);
  });

  it("ignores a customer it doesn't know, and says so", async () => {
    const db = new FakeDb({ billing_org_for_customer: () => null });
    const { deps, logs } = makeDeps(db, makeStripe().stripe);
    assert.equal(await handleBillingEvent(deps, subscriptionEvent("customer.subscription.created", subscriptionObject({ metadata: {} }))), true);
    assert.equal(db.called("billing_record_subscription").length, 0);
    assert.equal(logs.length, 1);
  });

  it("treats a deleted subscription as cancelled whatever its last status said", async () => {
    const db = new FakeDb({ billing_record_subscription: () => ({}) });
    const { deps } = makeDeps(db, makeStripe().stripe);
    await handleBillingEvent(deps, subscriptionEvent("customer.subscription.deleted", subscriptionObject({ status: "active" })));
    assert.equal(db.called("billing_record_subscription")[0].args.p_status, "canceled");
  });

  it("records past due as past due", async () => {
    const db = new FakeDb({ billing_record_subscription: () => ({}) });
    const { deps } = makeDeps(db, makeStripe().stripe);
    await handleBillingEvent(deps, subscriptionEvent("customer.subscription.updated", subscriptionObject({ status: "unpaid" })));
    assert.equal(db.called("billing_record_subscription")[0].args.p_status, "past_due");
  });

  it("records nothing until the first payment has gone through", async () => {
    const db = new FakeDb({});
    const { deps } = makeDeps(db, makeStripe().stripe);
    assert.equal(await handleBillingEvent(deps, subscriptionEvent("customer.subscription.created", subscriptionObject({ status: "incomplete" }))), true);
    assert.equal(db.calls.length, 0);
  });

  it("leaves other events alone", async () => {
    const db = new FakeDb({});
    const { deps } = makeDeps(db, makeStripe().stripe);
    assert.equal(await handleBillingEvent(deps, subscriptionEvent("payment_intent.succeeded", {})), false);
    assert.equal(await handleBillingEvent(deps, subscriptionEvent("invoice.paid", {})), false);
    assert.equal(db.calls.length, 0);
  });

  it("is reached through the one webhook, after the signature is checked", async () => {
    const event = subscriptionEvent("customer.subscription.updated", subscriptionObject());
    const db = new FakeDb({ webhook_claim_event: () => true, webhook_event_done: () => null, billing_record_subscription: () => ({}) });
    const logs: unknown[] = [];
    const deps = {
      db,
      stripe: { webhooks: { constructEventAsync: async () => event } },
      config: { platformFeeBps: 0, functionsBaseUrl: "", webhookSecret: "whsec", appScheme: "slate" },
      log: (m: string) => logs.push(m),
    } as unknown as Deps;
    const result = await handleStripeWebhook(deps, "{}", "sig");
    assert.equal(result.status, 200);
    assert.equal(db.called("billing_record_subscription").length, 1);
    assert.equal(db.called("webhook_event_done").length, 1);

    const unsigned = await handleStripeWebhook(deps, "{}", null);
    assert.equal(unsigned.status, 400, "no signature, no plan");
  });
});

// ---------------------------------------------------------------------------
// Seat sync
// ---------------------------------------------------------------------------
const due = (over: Record<string, unknown> = {}) => ({
  organization_id: ORG,
  subscription_id: "sub_1",
  seats_wanted: 12,
  seats_billed: 10,
  closed: false,
  ...over,
});

describe("syncSeats", () => {
  it("charges more seats at once, prorated", async () => {
    const db = new FakeDb({ billing_sync_due: () => [due()], billing_sync_done: () => null, billing_sweep: () => 0 });
    const { stripe, calls } = makeStripe();
    const { deps } = makeDeps(db, stripe);
    const result = await syncSeats(deps);
    assert.deepEqual(result, { updated: 1, cancelled: 0, failed: 0 });
    assert.equal(calls.updates[0].id, "si_1");
    assert.deepEqual(calls.updates[0].params, { quantity: 12, proration_behavior: "create_prorations" });
    assert.equal(calls.updates[0].key, `seats-${ORG}-10-12`);
    assert.deepEqual(db.called("billing_sync_done")[0].args, { p_org: ORG, p_seats: 12, p_cancelled: false });
  });

  it("lowers the next invoice without crediting this one", async () => {
    const db = new FakeDb({ billing_sync_due: () => [due({ seats_wanted: 10, seats_billed: 14 })], billing_sync_done: () => null, billing_sweep: () => 0 });
    const { stripe, calls } = makeStripe();
    const { deps } = makeDeps(db, stripe);
    await syncSeats(deps);
    assert.deepEqual(calls.updates[0].params, { quantity: 10, proration_behavior: "none" });
  });

  it("ends the plan of a company that was closed", async () => {
    const db = new FakeDb({ billing_sync_due: () => [due({ closed: true })], billing_sync_done: () => null, billing_sweep: () => 0 });
    const { stripe, calls } = makeStripe();
    const { deps } = makeDeps(db, stripe);
    const result = await syncSeats(deps);
    assert.deepEqual(result, { updated: 0, cancelled: 1, failed: 0 });
    assert.deepEqual(calls.cancelled, ["sub_1"]);
    assert.equal(calls.updates.length, 0);
    assert.deepEqual(db.called("billing_sync_done")[0].args, { p_org: ORG, p_seats: 0, p_cancelled: true });
  });

  it("is content if Stripe already ended it", async () => {
    const db = new FakeDb({ billing_sync_due: () => [due({ closed: true })], billing_sync_done: () => null, billing_sweep: () => 0 });
    const { stripe } = makeStripe({
      subscriptions: {
        retrieve: async () => { throw new Error("unused"); },
        cancel: async () => { throw new Error("No such subscription: 'sub_1'"); },
      },
    });
    const { deps } = makeDeps(db, stripe);
    assert.deepEqual(await syncSeats(deps), { updated: 0, cancelled: 1, failed: 0 });
  });

  it("carries on past a company that fails, and tries it again next time", async () => {
    const other = "cccccccc-1111-4222-8333-444444444444";
    const db = new FakeDb({
      billing_sync_due: () => [due({ subscription_id: "sub_bad" }), due({ organization_id: other, subscription_id: "sub_ok", seats_wanted: 11 })],
      billing_sync_done: () => null,
      billing_sweep: () => 0,
    });
    const { stripe, calls } = makeStripe({
      subscriptions: {
        retrieve: async (id) => {
          if (id === "sub_bad") throw new Error("Stripe is having a moment");
          return { id, status: "active", items: { data: [{ id: "si_ok", quantity: 10 }] } };
        },
        cancel: async (id) => ({ id, status: "canceled" }),
      },
    });
    const { deps, logs } = makeDeps(db, stripe);
    assert.deepEqual(await syncSeats(deps), { updated: 1, cancelled: 0, failed: 1 });
    assert.equal(calls.updates[0].id, "si_ok");
    assert.equal(db.called("billing_sync_done").length, 1, "the failed one is not marked done");
    assert.equal(logs[0].message, "seat sync will be retried");
  });

  it("skips a subscription with no seat item rather than guessing", async () => {
    const db = new FakeDb({ billing_sync_due: () => [due()], billing_sweep: () => 0 });
    const { stripe, calls } = makeStripe({}, { id: "sub_1", status: "active", items: { data: [] } });
    const { deps } = makeDeps(db, stripe);
    assert.deepEqual(await syncSeats(deps), { updated: 0, cancelled: 0, failed: 1 });
    assert.equal(calls.updates.length, 0);
  });

  it("always sweeps for plans that are overdue", async () => {
    const db = new FakeDb({ billing_sync_due: () => [], billing_sweep: () => 2 });
    const { deps } = makeDeps(db, makeStripe().stripe);
    await syncSeats(deps);
    assert.equal(db.called("billing_sweep").length, 1);
  });
});

describe("billingSyncRequest", () => {
  const SECRET = "a-very-long-service-role-secret";
  const ready = () => makeDeps(new FakeDb({ billing_sync_due: () => [], billing_sweep: () => 0 }), makeStripe().stripe).deps;

  it("answers only POST from the scheduler", async () => {
    assert.equal((await billingSyncRequest({ method: "GET", authorization: `Bearer ${SECRET}` }, [SECRET], ready())).status, 405);
    assert.equal((await billingSyncRequest({ method: "POST", authorization: null }, [SECRET], ready())).status, 401);
    assert.equal((await billingSyncRequest({ method: "POST", authorization: "Bearer wrong-secret-of-some-length" }, [SECRET], ready())).status, 401);
    assert.equal((await billingSyncRequest({ method: "POST", authorization: `Bearer ${SECRET}` }, [SECRET], null)).status, 503);
  });

  it("runs for the right secret", async () => {
    const result = await billingSyncRequest({ method: "POST", authorization: `Bearer ${SECRET}` }, [undefined, SECRET], ready());
    assert.equal(result.status, 200);
    assert.deepEqual(result.body, { updated: 0, cancelled: 0, failed: 0 });
  });

  it("is not opened by a short or missing secret", async () => {
    assert.equal((await billingSyncRequest({ method: "POST", authorization: "Bearer short" }, ["short"], ready())).status, 401);
    assert.equal((await billingSyncRequest({ method: "POST", authorization: "Bearer undefined" }, [undefined], ready())).status, 401);
  });
});
