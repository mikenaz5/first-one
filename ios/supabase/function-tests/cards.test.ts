import assert from "node:assert/strict";
import { describe, it } from "node:test";
import {
  cardRedirect,
  cardRemove,
  cardSetup,
  cardSync,
  chargeSavedCard,
  forgetCards,
  handleCardEvent,
  SETUP_NOTICE,
} from "../functions/_shared/cards.ts";
import type { CardDeps, CardStripe, StripeCardMethod } from "../functions/_shared/cards.ts";
import { handleStripeWebhook } from "../functions/_shared/payments.ts";
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

interface Calls {
  customersCreated: { params: Record<string, unknown>; key?: string }[];
  customersDeleted: string[];
  sessions: { params: Record<string, unknown>; key?: string }[];
  listed: Record<string, unknown>[];
  detached: string[];
  intentsCreated: { params: Record<string, unknown>; key?: string }[];
  intentsRetrieved: string[];
  intentsCancelled: string[];
}

function makeStripe(overrides: Partial<{
  listMethods: (params: Record<string, unknown>) => Promise<{ data: StripeCardMethod[] }>;
  detach: (id: string) => Promise<unknown>;
  deleteCustomer: (id: string) => Promise<unknown>;
  createIntent: (params: Record<string, unknown>) => Promise<StripeIntent>;
  retrieveIntent: (id: string) => Promise<StripeIntent>;
  cancelIntent: (id: string) => Promise<StripeIntent>;
  createSession: (params: Record<string, unknown>) => Promise<{ url: string | null }>;
}> = {}): { stripe: CardStripe; calls: Calls } {
  const calls: Calls = {
    customersCreated: [], customersDeleted: [], sessions: [], listed: [], detached: [],
    intentsCreated: [], intentsRetrieved: [], intentsCancelled: [],
  };
  const stripe: CardStripe = {
    customers: {
      async create(params, options) {
        calls.customersCreated.push({ params, key: options?.idempotencyKey });
        return { id: "cus_new" };
      },
      async del(id) {
        calls.customersDeleted.push(id);
        return overrides.deleteCustomer ? overrides.deleteCustomer(id) : { id, deleted: true };
      },
    },
    checkout: {
      sessions: {
        async create(params, options) {
          calls.sessions.push({ params, key: options?.idempotencyKey });
          return overrides.createSession ? overrides.createSession(params) : { url: "https://checkout.stripe.test/c/setup_abc" };
        },
      },
    },
    paymentMethods: {
      async list(params) {
        calls.listed.push(params);
        return overrides.listMethods ? overrides.listMethods(params) : { data: [] };
      },
      async detach(id) {
        calls.detached.push(id);
        return overrides.detach ? overrides.detach(id) : { id };
      },
    },
    paymentIntents: {
      async create(params, options) {
        calls.intentsCreated.push({ params, key: options?.idempotencyKey });
        return overrides.createIntent ? overrides.createIntent(params) : { id: "pi_card", status: "succeeded", client_secret: "pi_card_secret" };
      },
      async retrieve(id) {
        calls.intentsRetrieved.push(id);
        return overrides.retrieveIntent ? overrides.retrieveIntent(id) : { id, status: "requires_payment_method", client_secret: `${id}_secret` };
      },
      async cancel(id) {
        calls.intentsCancelled.push(id);
        return overrides.cancelIntent ? overrides.cancelIntent(id) : { id, status: "canceled", client_secret: null };
      },
    },
  };
  return { stripe, calls };
}

function makeDeps(db: FakeDb, stripe: CardStripe, config: Partial<CardDeps["config"]> = {}): { deps: CardDeps; logs: string[] } {
  const logs: string[] = [];
  return {
    deps: {
      db,
      stripe,
      config: { platformFeeBps: 0, functionsBaseUrl: "https://ref.supabase.co/functions/v1", ...config },
      log: (message) => logs.push(message),
    },
    logs,
  };
}

const USER = "11111111-1111-4111-8111-111111111111";
const BOOKING = "22222222-2222-4222-8222-222222222222";
const PAYMENT = "33333333-3333-4333-8333-333333333333";
const CARD = "44444444-4444-4444-8444-444444444444";

const stripeError = (type: string, message: string, extra: Record<string, unknown> = {}) =>
  Object.assign(new Error(message), { type, ...extra });

const savedPrepared = (extra: Record<string, unknown> = {}) => ({
  payment_id: PAYMENT,
  booking_id: BOOKING,
  kind: "balance",
  amount_cents: 90000,
  currency: "usd",
  fee_cents: 0,
  destination: "acct_creator",
  existing_intent: null,
  description: "Balance for Wedding with Maya Chen",
  customer: "cus_alice",
  payment_method: "pm_alice_visa",
  ...extra,
});

const visaMethod = (extra: Partial<StripeCardMethod> = {}): StripeCardMethod => ({
  id: "pm_alice_visa",
  type: "card",
  customer: "cus_alice",
  card: { brand: "visa", last4: "4242", exp_month: 8, exp_year: 2099 },
  ...extra,
});

// ---------------------------------------------------------------------------
// Adding a card
// ---------------------------------------------------------------------------
describe("cardSetup", () => {
  it("opens Stripe's page to save a card for a customer that already exists, and charges nothing", async () => {
    const db = new FakeDb({ card_prepare: () => ({ customer_id: "cus_alice", card_count: 1 }) });
    const { stripe, calls } = makeStripe();
    const { deps } = makeDeps(db, stripe);

    const result = await cardSetup(deps, USER);

    assert.equal(result.status, 200);
    assert.deepEqual(result.body, { url: "https://checkout.stripe.test/c/setup_abc" });
    assert.equal(calls.customersCreated.length, 0, "no second customer");
    const { params } = calls.sessions[0];
    assert.equal(params.mode, "setup", "saving a card, not paying");
    assert.equal(params.customer, "cus_alice");
    assert.deepEqual(params.payment_method_types, ["card"]);
    assert.equal("line_items" in params, false);
    assert.equal(params.success_url, "https://ref.supabase.co/functions/v1/card-redirect?to=return");
    assert.equal(params.cancel_url, "https://ref.supabase.co/functions/v1/card-redirect?to=cancel");
    assert.deepEqual(params.setup_intent_data, { metadata: { user_id: USER } });
    assert.deepEqual(params.custom_text, { submit: { message: SETUP_NOTICE } });
    assert.deepEqual(db.called("card_prepare")[0].args, { p_user: USER });
  });

  it("says what the card may be used for, on Stripe's page", () => {
    assert.match(SETUP_NOTICE, /never sees the number/);
    assert.match(SETUP_NOTICE, /only if you allow them/);
    assert.match(SETUP_NOTICE, /balance of a booking/);
    assert.match(SETUP_NOTICE, /stop that, or remove the card, at any time/);
  });

  it("makes a Stripe customer the first time, holding nothing but the person's id", async () => {
    const db = new FakeDb({
      card_prepare: () => ({ customer_id: null, card_count: 0 }),
      card_customer_save: () => null,
      card_customer_for: () => "cus_new",
    });
    const { stripe, calls } = makeStripe();
    const { deps } = makeDeps(db, stripe);

    const result = await cardSetup(deps, USER);

    assert.equal(result.status, 200);
    assert.deepEqual(calls.customersCreated[0].params, { metadata: { user_id: USER } });
    assert.equal(calls.customersCreated[0].key, `card-customer-${USER}`, "two taps make one customer");
    assert.deepEqual(db.called("card_customer_save")[0].args, { p_user: USER, p_customer_id: "cus_new" });
    assert.equal(calls.sessions[0].params.customer, "cus_new");
  });

  it("uses the customer another request saved first", async () => {
    const db = new FakeDb({
      card_prepare: () => ({ customer_id: null, card_count: 0 }),
      card_customer_save: () => null,
      card_customer_for: () => "cus_first",
    });
    const { stripe, calls } = makeStripe();
    const { deps } = makeDeps(db, stripe);

    await cardSetup(deps, USER);

    assert.equal(calls.sessions[0].params.customer, "cus_first");
  });

  it("refuses at the limit, before Stripe is asked anything", async () => {
    const db = new FakeDb({ card_prepare: () => new Error("too_many_cards P0001") });
    const { stripe, calls } = makeStripe();
    const { deps } = makeDeps(db, stripe);

    const result = await cardSetup(deps, USER);

    assert.equal(result.status, 409);
    assert.deepEqual(result.body, { error: "too_many_cards" });
    assert.equal(calls.sessions.length + calls.customersCreated.length, 0);
  });

  it("is a bad gateway when Stripe fails, and never says why", async () => {
    const db = new FakeDb({ card_prepare: () => ({ customer_id: "cus_alice", card_count: 0 }) });
    const { stripe } = makeStripe({ createSession: async () => { throw stripeError("StripeAPIError", "secret detail sk_live_nope"); } });
    const { deps, logs } = makeDeps(db, stripe);

    const result = await cardSetup(deps, USER);

    assert.equal(result.status, 502);
    assert.deepEqual(result.body, { error: "stripe_error" });
    assert.equal(logs.length, 1);
  });

  it("is a bad gateway when Stripe gives no page", async () => {
    const db = new FakeDb({ card_prepare: () => ({ customer_id: "cus_alice", card_count: 0 }) });
    const { stripe } = makeStripe({ createSession: async () => ({ url: null }) });
    const { deps } = makeDeps(db, stripe);
    assert.equal((await cardSetup(deps, USER)).status, 502);
  });
});

describe("cardRedirect", () => {
  it("hands the person back to the app", () => {
    for (const to of ["return", "cancel"]) {
      const result = cardRedirect(to, "slate");
      assert.equal(result.status, 302);
      assert.equal(result.headers?.Location, `slate://cards/${to}`);
    }
  });

  it("goes nowhere else", () => {
    for (const to of [null, "", "https://evil.test", "return/../x"]) {
      assert.equal(cardRedirect(to, "slate").status, 400, String(to));
    }
  });
});

// ---------------------------------------------------------------------------
// Keeping the two lists in step
// ---------------------------------------------------------------------------
describe("cardSync", () => {
  it("records the cards Stripe has and forgets the ones it doesn't", async () => {
    const db = new FakeDb({ card_customer_for: () => "cus_alice", card_record: () => CARD, card_prune: () => 1 });
    const { stripe, calls } = makeStripe({
      listMethods: async () => ({ data: [visaMethod(), visaMethod({ id: "pm_mc", card: { brand: "mastercard", last4: "4444", exp_month: 1, exp_year: 2030 } })] }),
    });
    const { deps } = makeDeps(db, stripe);

    const result = await cardSync(deps, USER);

    assert.deepEqual(result.body, { cards: 2, removed: 1 });
    assert.deepEqual(calls.listed[0], { customer: "cus_alice", type: "card", limit: 20 });
    assert.deepEqual(db.called("card_record").map((c) => c.args), [
      { p_customer_id: "cus_alice", p_payment_method_id: "pm_alice_visa", p_brand: "visa", p_last4: "4242", p_exp_month: 8, p_exp_year: 2099 },
      { p_customer_id: "cus_alice", p_payment_method_id: "pm_mc", p_brand: "mastercard", p_last4: "4444", p_exp_month: 1, p_exp_year: 2030 },
    ]);
    assert.deepEqual(db.called("card_prune")[0].args, { p_user: USER, p_keep: ["pm_alice_visa", "pm_mc"] });
  });

  it("has nothing to do for someone who never saved a card", async () => {
    const db = new FakeDb({ card_customer_for: () => null });
    const { stripe, calls } = makeStripe();
    const { deps } = makeDeps(db, stripe);
    assert.deepEqual((await cardSync(deps, USER)).body, { cards: 0, removed: 0 });
    assert.equal(calls.listed.length, 0);
  });

  it("forgets nothing when Stripe can't be asked", async () => {
    const db = new FakeDb({ card_customer_for: () => "cus_alice", card_prune: () => 9 });
    const { stripe } = makeStripe({ listMethods: async () => { throw stripeError("StripeConnectionError", "network down"); } });
    const { deps } = makeDeps(db, stripe);

    const result = await cardSync(deps, USER);

    assert.equal(result.status, 502);
    assert.equal(db.called("card_prune").length, 0, "no answer is not the same as no cards");
  });

  it("keeps a card whose details Stripe left out, without recording it", async () => {
    const db = new FakeDb({ card_customer_for: () => "cus_alice", card_record: () => CARD, card_prune: () => 0 });
    const { stripe } = makeStripe({ listMethods: async () => ({ data: [{ id: "pm_odd", type: "card", customer: "cus_alice", card: null }] }) });
    const { deps } = makeDeps(db, stripe);

    await cardSync(deps, USER);

    assert.equal(db.called("card_record").length, 0);
    assert.deepEqual(db.called("card_prune")[0].args.p_keep, ["pm_odd"], "not forgotten just because it can't be shown");
  });
});

describe("cardRemove", () => {
  it("removes the card at Stripe first, then here", async () => {
    const order: string[] = [];
    const db = new FakeDb({
      card_lookup: () => { order.push("lookup"); return "pm_alice_visa"; },
      card_forget: () => { order.push("forget"); return null; },
    });
    const { stripe, calls } = makeStripe({ detach: async (id) => { order.push("detach"); return { id }; } });
    const { deps } = makeDeps(db, stripe);

    const result = await cardRemove(deps, USER, { card_id: CARD });

    assert.deepEqual(result.body, { removed: true });
    assert.deepEqual(order, ["lookup", "detach", "forget"]);
    assert.deepEqual(calls.detached, ["pm_alice_visa"]);
    assert.deepEqual(db.called("card_lookup")[0].args, { p_user: USER, p_card_id: CARD });
  });

  it("keeps the card here if Stripe could not remove it", async () => {
    const db = new FakeDb({ card_lookup: () => "pm_alice_visa", card_forget: () => null });
    const { stripe } = makeStripe({ detach: async () => { throw stripeError("StripeConnectionError", "network down"); } });
    const { deps } = makeDeps(db, stripe);

    const result = await cardRemove(deps, USER, { card_id: CARD });

    assert.equal(result.status, 502);
    assert.equal(db.called("card_forget").length, 0, "the two never disagree about a card that is still usable");
  });

  it("treats a card already gone from Stripe as removed", async () => {
    const db = new FakeDb({ card_lookup: () => "pm_alice_visa", card_forget: () => null });
    const { stripe } = makeStripe({ detach: async () => { throw stripeError("StripeInvalidRequestError", "No such PaymentMethod: 'pm_alice_visa'"); } });
    const { deps } = makeDeps(db, stripe);

    assert.equal((await cardRemove(deps, USER, { card_id: CARD })).status, 200);
    assert.equal(db.called("card_forget").length, 1);
  });

  it("answers 404 for a card that isn't the person's", async () => {
    const db = new FakeDb({ card_lookup: () => new Error("card_not_found P0001") });
    const { stripe, calls } = makeStripe();
    const { deps } = makeDeps(db, stripe);

    const result = await cardRemove(deps, USER, { card_id: CARD });

    assert.equal(result.status, 404);
    assert.equal(calls.detached.length, 0);
  });

  it("rejects malformed requests before touching anything", async () => {
    const db = new FakeDb({});
    const { stripe, calls } = makeStripe();
    const { deps } = makeDeps(db, stripe);
    for (const input of [null, "x", [], {}, { card_id: "nope" }, { card_id: 7 }, { payment_method: "pm_alice_visa" }]) {
      assert.equal((await cardRemove(deps, USER, input)).status, 400, JSON.stringify(input));
    }
    assert.equal(db.calls.length, 0);
    assert.equal(calls.detached.length, 0);
  });
});

describe("forgetCards (deleting an account)", () => {
  it("deletes the Stripe customer and with it every card", async () => {
    const db = new FakeDb({ card_customer_for: () => "cus_alice" });
    const { stripe, calls } = makeStripe();

    assert.equal(await forgetCards({ db, stripe }, USER), "deleted");
    assert.deepEqual(calls.customersDeleted, ["cus_alice"]);
  });

  it("has nothing to do without a customer", async () => {
    const db = new FakeDb({ card_customer_for: () => null });
    const { stripe, calls } = makeStripe();

    assert.equal(await forgetCards({ db, stripe }, USER), "none");
    assert.equal(calls.customersDeleted.length, 0);
  });

  it("counts a customer already gone as done", async () => {
    const db = new FakeDb({ card_customer_for: () => "cus_alice" });
    const { stripe } = makeStripe({ deleteCustomer: async () => { throw stripeError("StripeInvalidRequestError", "No such customer: 'cus_alice'"); } });
    assert.equal(await forgetCards({ db, stripe }, USER), "deleted");
  });

  it("throws if Stripe can't be reached, so the account isn't deleted with its cards left behind", async () => {
    const db = new FakeDb({ card_customer_for: () => "cus_alice" });
    const { stripe } = makeStripe({ deleteCustomer: async () => { throw stripeError("StripeConnectionError", "network down"); } });
    await assert.rejects(() => forgetCards({ db, stripe }, USER), /network down/);
  });
});

// ---------------------------------------------------------------------------
// Stripe's webhook, for cards
// ---------------------------------------------------------------------------
const eventOf = (type: string, object: Record<string, unknown>): StripeEvent => ({ id: `evt_${type}`, type, data: { object } });

describe("handleCardEvent", () => {
  it("records a card saved on Stripe's page", async () => {
    const db = new FakeDb({ card_record: () => CARD });
    const logs: string[] = [];

    const mine = await handleCardEvent({ db, log: (m) => logs.push(m) }, eventOf("payment_method.attached", visaMethod() as never));

    assert.equal(mine, true);
    assert.deepEqual(db.called("card_record")[0].args, {
      p_customer_id: "cus_alice", p_payment_method_id: "pm_alice_visa", p_brand: "visa", p_last4: "4242", p_exp_month: 8, p_exp_year: 2099,
    });
  });

  it("updates a card whose expiry changed", async () => {
    for (const type of ["payment_method.updated", "payment_method.automatically_updated"]) {
      const db = new FakeDb({ card_record: () => CARD });
      await handleCardEvent({ db, log: () => {} }, eventOf(type, visaMethod({ card: { brand: "visa", last4: "4242", exp_month: 3, exp_year: 2101 } }) as never));
      assert.equal(db.called("card_record")[0].args.p_exp_year, 2101, type);
    }
  });

  it("forgets a card removed on Stripe's side", async () => {
    const db = new FakeDb({ card_forget_method: () => null });
    await handleCardEvent({ db, log: () => {} }, eventOf("payment_method.detached", { id: "pm_alice_visa", customer: null }));
    assert.deepEqual(db.called("card_forget_method")[0].args, { p_payment_method_id: "pm_alice_visa" });
  });

  it("leaves alone a card on a customer that isn't a client's, such as a company's plan", async () => {
    const db = new FakeDb({ card_record: () => new Error("unknown_customer P0001") });
    assert.equal(await handleCardEvent({ db, log: () => {} }, eventOf("payment_method.attached", visaMethod({ customer: "cus_company" }) as never)), true);
  });

  it("lets a real failure through, so Stripe sends the event again", async () => {
    const db = new FakeDb({ card_record: () => new Error("connection lost") });
    await assert.rejects(() => handleCardEvent({ db, log: () => {} }, eventOf("payment_method.attached", visaMethod() as never)), /connection lost/);
  });

  it("ignores anything that isn't a card with a customer", async () => {
    const db = new FakeDb({});
    for (const object of [{ id: "pm_x", type: "us_bank_account", customer: "cus_alice" }, { id: "pm_x", type: "card", customer: null, card: { last4: "1", exp_month: 1, exp_year: 2030 } }, { id: "pm_x", type: "card", customer: "cus_a" }]) {
      assert.equal(await handleCardEvent({ db, log: () => {} }, eventOf("payment_method.attached", object)), true);
    }
    assert.equal(db.calls.length, 0);
  });

  it("says no to events that aren't about cards", async () => {
    const db = new FakeDb({});
    assert.equal(await handleCardEvent({ db, log: () => {} }, eventOf("payment_intent.succeeded", {})), false);
    assert.equal(await handleCardEvent({ db, log: () => {} }, eventOf("customer.subscription.updated", {})), false);
  });
});

describe("Stripe's webhook, with cards", () => {
  function webhookDeps(db: FakeDb): Deps {
    const stripe = {
      webhooks: { constructEventAsync: async (payload: string) => JSON.parse(payload) as StripeEvent },
    } as unknown as StripeLike;
    return {
      db,
      stripe,
      config: { platformFeeBps: 0, functionsBaseUrl: "https://ref.supabase.co/functions/v1", webhookSecret: "whsec", appScheme: "slate" },
      log: () => {},
    };
  }

  const claim = { webhook_claim_event: () => true, webhook_event_done: () => null };

  it("records a payment from a saved card as a card payment", async () => {
    const db = new FakeDb({ ...claim, payment_record_success: () => ({ action: "completed", booking_id: BOOKING }) });
    const body = JSON.stringify(eventOf("payment_intent.succeeded", {
      id: "pi_card", amount: 90000, amount_received: 90000, latest_charge: "ch_1",
      metadata: { payment_id: PAYMENT, booking_id: BOOKING, kind: "balance", saved_card: "true" },
    }));

    const result = await handleStripeWebhook(webhookDeps(db), body, "sig");

    assert.equal(result.status, 200);
    assert.deepEqual(db.called("payment_record_success")[0].args, {
      p_intent_id: "pi_card", p_amount_cents: 90000, p_charge_id: "ch_1", p_method: "card",
    });
  });

  it("still records an Apple Pay payment as Apple Pay", async () => {
    const db = new FakeDb({ ...claim, payment_record_success: () => ({ action: "completed", booking_id: BOOKING }) });
    const body = JSON.stringify(eventOf("payment_intent.succeeded", {
      id: "pi_wallet", amount: 90000, amount_received: 90000, latest_charge: "ch_2",
      metadata: { payment_id: PAYMENT, booking_id: BOOKING, kind: "balance" },
    }));

    await handleStripeWebhook(webhookDeps(db), body, "sig");

    assert.equal(db.called("payment_record_success")[0].args.p_method, "apple_pay");
  });

  it("sends card events to the card code", async () => {
    const db = new FakeDb({ ...claim, card_record: () => CARD });
    const result = await handleStripeWebhook(webhookDeps(db), JSON.stringify(eventOf("payment_method.attached", visaMethod() as never)), "sig");
    assert.equal(result.status, 200);
    assert.equal(db.called("card_record").length, 1);
    assert.equal(db.called("webhook_event_done").length, 1);
  });

  it("asks Stripe to send it again when recording a card fails", async () => {
    const db = new FakeDb({ ...claim, card_record: () => new Error("connection lost") });
    const result = await handleStripeWebhook(webhookDeps(db), JSON.stringify(eventOf("payment_method.attached", visaMethod() as never)), "sig");
    assert.equal(result.status, 500);
    assert.equal(db.called("webhook_event_done").length, 0);
  });

  it("records a failed saved-card payment like any failed payment", async () => {
    const db = new FakeDb({ ...claim, payment_record_failure: () => null });
    const body = JSON.stringify(eventOf("payment_intent.payment_failed", {
      id: "pi_card", metadata: { payment_id: PAYMENT, saved_card: "true" }, last_payment_error: { message: "Your card was declined." },
    }));
    await handleStripeWebhook(webhookDeps(db), body, "sig");
    assert.deepEqual(db.called("payment_record_failure")[0].args, { p_intent_id: "pi_card", p_message: "Your card was declined." });
  });
});

// ---------------------------------------------------------------------------
// Charging the saved card
// ---------------------------------------------------------------------------
describe("chargeSavedCard", () => {
  it("charges the balance the database worked out to the card the client chose, without the client there", async () => {
    const db = new FakeDb({ payment_prepare_saved: () => savedPrepared(), payment_attach_intent: () => null });
    const { stripe, calls } = makeStripe();
    const { deps } = makeDeps(db, stripe);

    const result = await chargeSavedCard(deps, USER, { booking_id: BOOKING });

    assert.equal(result.status, 200);
    assert.deepEqual(result.body, { payment_id: PAYMENT, status: "succeeded", amount_cents: 90000, currency: "usd" });
    assert.deepEqual(db.called("payment_prepare_saved")[0].args, { p_actor: USER, p_booking_id: BOOKING, p_fee_bps: 0 });
    const { params, key } = calls.intentsCreated[0];
    assert.equal(params.amount, 90000);
    assert.equal(params.currency, "usd");
    assert.equal(params.customer, "cus_alice");
    assert.equal(params.payment_method, "pm_alice_visa");
    assert.equal(params.off_session, true);
    assert.equal(params.confirm, true);
    assert.deepEqual(params.payment_method_types, ["card"]);
    assert.deepEqual(params.transfer_data, { destination: "acct_creator" });
    assert.deepEqual(params.metadata, { payment_id: PAYMENT, booking_id: BOOKING, kind: "balance", saved_card: "true" });
    assert.equal("application_fee_amount" in params, false);
    assert.equal(key, `payment-${PAYMENT}`, "a retry can't charge twice");
    assert.deepEqual(db.called("payment_attach_intent")[0].args, { p_payment_id: PAYMENT, p_intent_id: "pi_card" });
  });

  it("never records the money itself: that is the webhook's job", async () => {
    const db = new FakeDb({ payment_prepare_saved: () => savedPrepared(), payment_attach_intent: () => null });
    const { stripe } = makeStripe();
    const { deps } = makeDeps(db, stripe);

    await chargeSavedCard(deps, USER, { booking_id: BOOKING });

    const names = db.calls.map((c) => c.fn);
    assert.equal(names.includes("payment_record_success"), false);
    assert.deepEqual(names, ["payment_prepare_saved", "payment_attach_intent"]);
  });

  it("charges the platform fee the database worked out", async () => {
    const db = new FakeDb({ payment_prepare_saved: () => savedPrepared({ fee_cents: 2250 }), payment_attach_intent: () => null });
    const { stripe, calls } = makeStripe();
    const { deps } = makeDeps(db, stripe, { platformFeeBps: 250 });

    await chargeSavedCard(deps, USER, { booking_id: BOOKING });

    assert.equal(db.called("payment_prepare_saved")[0].args.p_fee_bps, 250);
    assert.equal(calls.intentsCreated[0].params.application_fee_amount, 2250);
  });

  it("ignores any amount, card, customer or person the caller tries to send", async () => {
    const db = new FakeDb({ payment_prepare_saved: () => savedPrepared(), payment_attach_intent: () => null });
    const { stripe, calls } = makeStripe();
    const { deps } = makeDeps(db, stripe);

    await chargeSavedCard(deps, USER, {
      booking_id: BOOKING, amount: 1, amount_cents: 1, payment_method: "pm_mine", customer: "cus_mine", user_id: "someone-else", p_actor: "someone-else",
      destination: "acct_me", p_fee_bps: 9999,
    });

    assert.equal(calls.intentsCreated[0].params.amount, 90000);
    assert.equal(calls.intentsCreated[0].params.payment_method, "pm_alice_visa");
    assert.equal(calls.intentsCreated[0].params.customer, "cus_alice");
    assert.deepEqual(calls.intentsCreated[0].params.transfer_data, { destination: "acct_creator" });
    assert.equal(db.called("payment_prepare_saved")[0].args.p_actor, USER);
    assert.equal(db.called("payment_prepare_saved")[0].args.p_fee_bps, 0);
  });

  it("rejects malformed requests before touching anything", async () => {
    const db = new FakeDb({});
    const { stripe, calls } = makeStripe();
    const { deps } = makeDeps(db, stripe);
    for (const input of [null, "x", [], {}, { booking_id: "nope" }, { booking_id: 5 }]) {
      assert.equal((await chargeSavedCard(deps, USER, input)).status, 400, JSON.stringify(input));
    }
    assert.equal(db.calls.length, 0);
    assert.equal(calls.intentsCreated.length, 0);
  });

  it("turns the database's refusals into clear answers, and charges nothing", async () => {
    const cases: [string, number][] = [
      ["not_found", 404], ["no_card_access", 409], ["card_expired", 409], ["balance_not_due", 409],
      ["nothing_due", 409], ["already_paid", 409], ["payments_not_ready", 409],
    ];
    for (const [token, status] of cases) {
      const db = new FakeDb({ payment_prepare_saved: () => new Error(`${token} P0001`) });
      const { stripe, calls } = makeStripe();
      const { deps } = makeDeps(db, stripe);
      const result = await chargeSavedCard(deps, USER, { booking_id: BOOKING });
      assert.equal(result.status, status, token);
      assert.deepEqual(result.body, { error: token });
      assert.equal(calls.intentsCreated.length, 0, token);
    }
  });

  it("is a server error, with no detail, for anything it doesn't know", async () => {
    const db = new FakeDb({ payment_prepare_saved: () => new Error("relation payments is on fire") });
    const { stripe } = makeStripe();
    const { deps, logs } = makeDeps(db, stripe);
    const result = await chargeSavedCard(deps, USER, { booking_id: BOOKING });
    assert.equal(result.status, 500);
    assert.deepEqual(result.body, { error: "server_error" });
    assert.equal(logs.length, 1);
  });

  it("reports a payment still being processed", async () => {
    const db = new FakeDb({ payment_prepare_saved: () => savedPrepared(), payment_attach_intent: () => null });
    const { stripe } = makeStripe({ createIntent: async () => ({ id: "pi_card", status: "processing", client_secret: null }) });
    const { deps } = makeDeps(db, stripe);
    const result = await chargeSavedCard(deps, USER, { booking_id: BOOKING });
    assert.equal(result.status, 200);
    assert.equal((result.body as { status: string }).status, "processing");
  });

  describe("a payment already waiting on the booking", () => {
    const waiting = () => savedPrepared({ existing_intent: "pi_old" });

    it("closes an unfinished one and starts clean", async () => {
      let prepared = 0;
      const db = new FakeDb({
        payment_prepare_saved: () => (++prepared === 1 ? waiting() : savedPrepared({ payment_id: "55555555-5555-4555-8555-555555555555" })),
        payment_record_failure: () => null,
        payment_attach_intent: () => null,
      });
      const { stripe, calls } = makeStripe();
      const { deps } = makeDeps(db, stripe);

      const result = await chargeSavedCard(deps, USER, { booking_id: BOOKING });

      assert.equal(result.status, 200);
      assert.deepEqual(calls.intentsCancelled, ["pi_old"]);
      assert.deepEqual(db.called("payment_record_failure")[0].args, { p_intent_id: "pi_old", p_message: "Replaced by a payment from the saved card." });
      assert.equal(calls.intentsCreated.length, 1);
      assert.equal(calls.intentsCreated[0].key, "payment-55555555-5555-4555-8555-555555555555", "the new payment has its own key");
    });

    it("leaves a payment that already went through alone", async () => {
      const db = new FakeDb({ payment_prepare_saved: waiting });
      const { stripe, calls } = makeStripe({ retrieveIntent: async (id) => ({ id, status: "succeeded", client_secret: null }) });
      const { deps } = makeDeps(db, stripe);

      const result = await chargeSavedCard(deps, USER, { booking_id: BOOKING });

      assert.equal(result.status, 409);
      assert.deepEqual(result.body, { error: "already_paid" });
      assert.equal(calls.intentsCancelled.length + calls.intentsCreated.length, 0);
    });

    it("leaves one that is processing alone", async () => {
      const db = new FakeDb({ payment_prepare_saved: waiting });
      const { stripe, calls } = makeStripe({ retrieveIntent: async (id) => ({ id, status: "processing", client_secret: null }) });
      const { deps } = makeDeps(db, stripe);

      const result = await chargeSavedCard(deps, USER, { booking_id: BOOKING });

      assert.deepEqual(result.body, { error: "payment_processing" });
      assert.equal(calls.intentsCancelled.length + calls.intentsCreated.length, 0);
    });

    it("notices when it went through while being cancelled", async () => {
      const db = new FakeDb({ payment_prepare_saved: waiting });
      let asked = 0;
      const { stripe, calls } = makeStripe({
        retrieveIntent: async (id) => ({ id, status: ++asked === 1 ? "requires_payment_method" : "succeeded", client_secret: null }),
        cancelIntent: async () => { throw stripeError("StripeInvalidRequestError", "payment_intent_unexpected_state"); },
      });
      const { deps } = makeDeps(db, stripe);

      const result = await chargeSavedCard(deps, USER, { booking_id: BOOKING });

      assert.deepEqual(result.body, { error: "already_paid" });
      assert.equal(calls.intentsCreated.length, 0);
    });

    it("gives up cleanly if the old payment is still there after being replaced", async () => {
      const db = new FakeDb({ payment_prepare_saved: waiting, payment_record_failure: () => null });
      const { stripe, calls } = makeStripe();
      const { deps } = makeDeps(db, stripe);

      const result = await chargeSavedCard(deps, USER, { booking_id: BOOKING });

      assert.equal(result.status, 409);
      assert.deepEqual(result.body, { error: "payment_stale" });
      assert.equal(calls.intentsCreated.length, 0);
    });
  });

  describe("when the bank says no", () => {
    it("closes the payment as failed, tells the creator it was declined, and does not try again", async () => {
      const db = new FakeDb({ payment_prepare_saved: () => savedPrepared(), payment_attach_intent: () => null, payment_record_failure: () => null });
      const { stripe, calls } = makeStripe({
        createIntent: async () => { throw stripeError("StripeCardError", "Your card was declined.", { code: "card_declined", payment_intent: { id: "pi_declined" } }); },
      });
      const { deps } = makeDeps(db, stripe);

      const result = await chargeSavedCard(deps, USER, { booking_id: BOOKING });

      assert.equal(result.status, 402);
      assert.deepEqual(result.body, { error: "card_declined" });
      assert.equal(calls.intentsCreated.length, 1, "one try");
      assert.deepEqual(db.called("payment_attach_intent")[0].args, { p_payment_id: PAYMENT, p_intent_id: "pi_declined" });
      assert.deepEqual(db.called("payment_record_failure")[0].args, { p_intent_id: "pi_declined", p_message: "The card was declined." });
    });

    it("says so when the bank wants the client to approve it", async () => {
      const db = new FakeDb({ payment_prepare_saved: () => savedPrepared(), payment_attach_intent: () => null, payment_record_failure: () => null });
      const { stripe } = makeStripe({
        createIntent: async () => { throw stripeError("StripeCardError", "Authentication required", { code: "authentication_required", payment_intent: { id: "pi_auth" } }); },
      });
      const { deps } = makeDeps(db, stripe);

      const result = await chargeSavedCard(deps, USER, { booking_id: BOOKING });

      assert.equal(result.status, 402);
      assert.deepEqual(result.body, { error: "authentication_required" });
      assert.equal(db.called("payment_record_failure")[0].args.p_message, "The bank needs the client to approve this payment.");
    });

    it("cancels an intent that comes back needing approval, so it can't be finished later by surprise", async () => {
      const db = new FakeDb({ payment_prepare_saved: () => savedPrepared(), payment_attach_intent: () => null, payment_record_failure: () => null });
      const { stripe, calls } = makeStripe({ createIntent: async () => ({ id: "pi_wait", status: "requires_action", client_secret: "s" }) });
      const { deps } = makeDeps(db, stripe);

      const result = await chargeSavedCard(deps, USER, { booking_id: BOOKING });

      assert.equal(result.status, 402);
      assert.deepEqual(result.body, { error: "authentication_required" });
      assert.deepEqual(calls.intentsCancelled, ["pi_wait"]);
      assert.equal(db.called("payment_record_failure")[0].args.p_intent_id, "pi_wait");
    });

    it("is still a decline if recording it fails", async () => {
      const db = new FakeDb({
        payment_prepare_saved: () => savedPrepared(),
        payment_attach_intent: () => new Error("connection lost"),
      });
      const { stripe } = makeStripe({
        createIntent: async () => { throw stripeError("StripeCardError", "declined", { code: "card_declined", payment_intent: { id: "pi_declined" } }); },
      });
      const { deps, logs } = makeDeps(db, stripe);

      const result = await chargeSavedCard(deps, USER, { booking_id: BOOKING });

      assert.deepEqual(result.body, { error: "card_declined" });
      assert.equal(logs.length, 1, "the webhook will record it too");
    });

    it("treats any other Stripe trouble as a bad gateway, with nothing recorded as paid", async () => {
      const db = new FakeDb({ payment_prepare_saved: () => savedPrepared(), payment_attach_intent: () => null });
      const { stripe } = makeStripe({ createIntent: async () => { throw stripeError("StripeConnectionError", "network down"); } });
      const { deps } = makeDeps(db, stripe);

      const result = await chargeSavedCard(deps, USER, { booking_id: BOOKING });

      assert.equal(result.status, 502);
      assert.deepEqual(result.body, { error: "stripe_error" });
      assert.equal(db.called("payment_attach_intent").length, 0);
    });
  });
});
