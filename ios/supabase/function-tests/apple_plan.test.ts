import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { AppleConfigError, AppleVerifyError, appleNotification, appleVerify, planFacts } from "../functions/_shared/apple_plan.ts";
import type { AppleDeps, AppleNotification, AppleRenewalInfo, AppleTransaction, AppleVerifier } from "../functions/_shared/apple_plan.ts";

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------
const USER = "aaaaaaaa-1111-4222-8333-444444444444";
const ORG = "bbbbbbbb-1111-4222-8333-444444444444";
const NOW = new Date("2026-11-10T12:00:00Z");
const DAY = 86_400_000;

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

function tx(extra: Partial<AppleTransaction> = {}): AppleTransaction {
  return {
    bundleId: "com.slateproapp.app",
    productId: "com.slateproapp.app.company.team5",
    originalTransactionId: "1000000000000001",
    transactionId: "1000000000000002",
    type: "Auto-Renewable Subscription",
    environment: "Production",
    appAccountToken: ORG,
    purchaseDate: NOW.getTime() - DAY,
    expiresDate: NOW.getTime() + 29 * DAY,
    signedDate: NOW.getTime() - 1000,
    ...extra,
  };
}

/** A verifier that "verifies" by looking the message up, so tests choose what Apple "signed". */
function makeVerifier(table: Record<string, unknown>): AppleVerifier {
  const find = (signed: string) => {
    if (!(signed in table)) throw new AppleVerifyError("bad signature");
    const found = table[signed];
    if (found instanceof Error) throw found;
    return found;
  };
  return {
    transaction: async (signed) => find(signed) as AppleTransaction,
    renewal: async (signed) => find(signed) as AppleRenewalInfo,
    notification: async (signed) => find(signed) as AppleNotification,
  };
}

const RECORDED = { status: "active", seats: 5, state: "active" };

function makeDeps(table: Record<string, unknown>, handlers: Record<string, Handler> = {}) {
  const logs: unknown[][] = [];
  const db = new FakeDb({
    billing_authorize: () => true,
    apple_record_subscription: () => RECORDED,
    apple_org_for_transaction: () => null,
    ...handlers,
  });
  const deps: AppleDeps = {
    db,
    verifier: makeVerifier(table),
    now: () => NOW,
    log: (...args) => logs.push(args),
  };
  return { deps, db, logs };
}

// ---------------------------------------------------------------------------
describe("reading a plan's state from what Apple signed", () => {
  it("is active inside a paid period", () => {
    const facts = planFacts(tx(), null, NOW);
    assert.equal(facts.status, "active");
    assert.equal(facts.periodEnd?.getTime(), NOW.getTime() + 29 * DAY);
    assert.equal(facts.trialEnd, null);
    assert.equal(facts.renews, null, "a transaction alone doesn't say whether it renews");
  });

  it("is a trial inside the introductory free offer", () => {
    const facts = planFacts(tx({ offerType: 1, offerDiscountType: "FREE_TRIAL", expiresDate: NOW.getTime() + 6 * DAY }), null, NOW);
    assert.equal(facts.status, "trialing");
    assert.equal(facts.trialEnd?.getTime(), NOW.getTime() + 6 * DAY);
  });

  it("is not a trial for other introductory prices or offer codes", () => {
    assert.equal(planFacts(tx({ offerType: 1, offerDiscountType: "PAY_AS_YOU_GO" }), null, NOW).status, "active");
    assert.equal(planFacts(tx({ offerType: 3, offerDiscountType: "FREE_TRIAL" }), null, NOW).status, "active");
  });

  it("reads whether it renews from the renewal information", () => {
    assert.equal(planFacts(tx(), { autoRenewStatus: 0 }, NOW).renews, false);
    assert.equal(planFacts(tx(), { autoRenewStatus: 1 }, NOW).renews, true);
  });

  it("is over once refunded or revoked, whatever the dates say", () => {
    const facts = planFacts(tx({ revocationDate: NOW.getTime() - 1000 }), { autoRenewStatus: 1 }, NOW);
    assert.equal(facts.status, "canceled");
    assert.equal(facts.renews, false);
  });

  it("is past due, inside Apple's grace period, when a renewal failed", () => {
    const grace = NOW.getTime() + 5 * DAY;
    const facts = planFacts(tx({ expiresDate: NOW.getTime() - 1000 }), { isInBillingRetryPeriod: true, gracePeriodExpiresDate: grace, autoRenewStatus: 1 }, NOW);
    assert.equal(facts.status, "past_due");
    assert.equal(facts.graceUntil?.getTime(), grace);
  });

  it("is past due while Apple keeps trying the card, even with no grace period", () => {
    const facts = planFacts(tx({ expiresDate: NOW.getTime() - 1000 }), { isInBillingRetryPeriod: true, autoRenewStatus: 1 }, NOW);
    assert.equal(facts.status, "past_due");
    assert.equal(facts.graceUntil, null);
  });

  it("is over when the period ended and nothing more is coming", () => {
    assert.equal(planFacts(tx({ expiresDate: NOW.getTime() - DAY }), { autoRenewStatus: 0 }, NOW).status, "canceled");
    assert.equal(planFacts(tx({ expiresDate: NOW.getTime() - DAY }), null, NOW).status, "canceled");
  });

  it("ignores a grace period that has already passed", () => {
    const facts = planFacts(tx({ expiresDate: NOW.getTime() - DAY }), { gracePeriodExpiresDate: NOW.getTime() - 1000, isInBillingRetryPeriod: false }, NOW);
    assert.equal(facts.status, "canceled");
  });
});

// ---------------------------------------------------------------------------
describe("apple-verify: the Owner hands over a purchase", () => {
  const input = (extra: Record<string, unknown> = {}) => ({ organization_id: ORG, signed_transaction: "tx-ok", ...extra });

  it("records a purchase made for this company", async () => {
    const { deps, db } = makeDeps({ "tx-ok": tx() });
    const result = await appleVerify(deps, USER, input());
    assert.equal(result.status, 200);
    assert.deepEqual(result.body, { status: "active", seats: 5, state: "active", ignored: null });
    assert.deepEqual(db.called("billing_authorize")[0].args, { p_user: USER, p_org: ORG });
    const args = db.called("apple_record_subscription")[0].args;
    assert.equal(args.p_org, ORG);
    assert.equal(args.p_original_transaction_id, "1000000000000001");
    assert.equal(args.p_product_id, "com.slateproapp.app.company.team5");
    assert.equal(args.p_environment, "Production");
    assert.equal(args.p_status, "active");
    assert.equal(args.p_period_end, new Date(NOW.getTime() + 29 * DAY).toISOString());
    assert.equal(args.p_trial_end, null);
    assert.equal(args.p_renews, null);
    assert.equal(args.p_grace_until, null);
    assert.equal(args.p_signed_at, new Date(NOW.getTime() - 1000).toISOString());
  });

  it("records a free trial as a trial", async () => {
    const { deps, db } = makeDeps({ "tx-ok": tx({ offerType: 1, offerDiscountType: "FREE_TRIAL", expiresDate: NOW.getTime() + 7 * DAY, environment: "Sandbox" }) });
    await appleVerify(deps, USER, input());
    const args = db.called("apple_record_subscription")[0].args;
    assert.equal(args.p_status, "trialing");
    assert.equal(args.p_trial_end, new Date(NOW.getTime() + 7 * DAY).toISOString());
    assert.equal(args.p_environment, "Sandbox");
  });

  it("uses the renewal information when the app sends it", async () => {
    const { deps, db } = makeDeps({ "tx-ok": tx(), "renew-ok": { autoRenewStatus: 0, originalTransactionId: "1000000000000001" } });
    await appleVerify(deps, USER, input({ signed_renewal_info: "renew-ok" }));
    assert.equal(db.called("apple_record_subscription")[0].args.p_renews, false);
  });

  it("refuses renewal information about a different subscription", async () => {
    const { deps, db } = makeDeps({ "tx-ok": tx(), "renew-other": { autoRenewStatus: 1, originalTransactionId: "999" } });
    const result = await appleVerify(deps, USER, input({ signed_renewal_info: "renew-other" }));
    assert.equal(result.status, 400);
    assert.equal(db.called("apple_record_subscription").length, 0);
  });

  it("matches the company id without caring about letter case", async () => {
    const { deps } = makeDeps({ "tx-ok": tx({ appAccountToken: ORG.toUpperCase() }) });
    assert.equal((await appleVerify(deps, USER, { organization_id: ORG.toUpperCase(), signed_transaction: "tx-ok" })).status, 200);
  });

  it("refuses malformed requests before touching anything", async () => {
    const { deps, db } = makeDeps({});
    for (const bad of [null, "x", {}, { organization_id: "nope", signed_transaction: "a" }, { organization_id: ORG },
                       { organization_id: ORG, signed_transaction: "" }, { organization_id: ORG, signed_transaction: 5 },
                       { organization_id: ORG, signed_transaction: "a", signed_renewal_info: 7 },
                       { organization_id: ORG, signed_transaction: "x".repeat(20001) }]) {
      assert.equal((await appleVerify(deps, USER, bad)).status, 400, JSON.stringify(bad)?.slice(0, 60));
    }
    assert.equal(db.calls.length, 0);
  });

  it("answers 404 for someone who may not manage this company's billing, and checks nothing else first", async () => {
    const { deps, db } = makeDeps({ "tx-ok": tx() }, { billing_authorize: () => false });
    const result = await appleVerify(deps, USER, input());
    assert.equal(result.status, 404);
    assert.equal(db.called("apple_record_subscription").length, 0);
  });

  it("refuses data Apple didn't sign", async () => {
    const { deps, db, logs } = makeDeps({});
    const result = await appleVerify(deps, USER, input({ signed_transaction: "made-up" }));
    assert.deepEqual(result, { status: 400, body: { error: "invalid_transaction" } });
    assert.equal(db.called("apple_record_subscription").length, 0);
    assert.equal(logs.length, 1);
  });

  it("says when Apple's settings aren't in place", async () => {
    const { deps } = makeDeps({ "tx-ok": new AppleConfigError("APPLE_APP_ID is not set") });
    assert.deepEqual(await appleVerify(deps, USER, input()), { status: 503, body: { error: "apple_not_configured" } });
  });

  it("refuses a purchase made for another company", async () => {
    const { deps, db } = makeDeps({ "tx-ok": tx({ appAccountToken: "cccccccc-1111-4222-8333-444444444444" }) });
    assert.deepEqual(await appleVerify(deps, USER, input()), { status: 409, body: { error: "wrong_company" } });
    assert.equal(db.called("apple_record_subscription").length, 0);
  });

  it("refuses a purchase with no company on it", async () => {
    const { deps } = makeDeps({ "tx-ok": tx({ appAccountToken: undefined }) });
    assert.equal((await appleVerify(deps, USER, input())).status, 409);
  });

  it("refuses something that isn't a subscription, or is missing its ids", async () => {
    for (const bad of [tx({ type: "Consumable" }), tx({ productId: undefined }), tx({ originalTransactionId: "" }), tx({ environment: "Xcode" })]) {
      const { deps, db } = makeDeps({ "tx-ok": bad });
      assert.deepEqual(await appleVerify(deps, USER, input()), { status: 400, body: { error: "not_a_plan" } });
      assert.equal(db.called("apple_record_subscription").length, 0);
    }
  });

  it("turns the database's refusals into answers the app can act on", async () => {
    const cases: [string, number, string][] = [
      ["unknown_product", 422, "unknown_product"],
      ["transaction_in_use", 409, "transaction_in_use"],
      ["plan_exists", 409, "plan_exists"],
      ["not_found", 404, "not_found"],
      ["invalid_input", 400, "invalid_input"],
    ];
    for (const [token, status, error] of cases) {
      const { deps } = makeDeps({ "tx-ok": tx() }, { apple_record_subscription: () => new Error(`ERROR: ${token}`) });
      assert.deepEqual(await appleVerify(deps, USER, input()), { status, body: { error } }, token);
    }
  });

  it("says so, without details, when the database fails", async () => {
    const { deps, logs } = makeDeps({ "tx-ok": tx() }, { apple_record_subscription: () => new Error("connection reset") });
    assert.deepEqual(await appleVerify(deps, USER, input()), { status: 500, body: { error: "server_error" } });
    assert.equal(logs.length, 1);
  });

  it("passes on that a stale message was ignored", async () => {
    const { deps } = makeDeps({ "tx-ok": tx() }, { apple_record_subscription: () => ({ status: "active", ignored: "stale" }) });
    const result = await appleVerify(deps, USER, input());
    assert.equal(result.status, 200);
    assert.equal((result.body as { ignored: string }).ignored, "stale");
  });
});

// ---------------------------------------------------------------------------
describe("apple-notifications: Apple reports what happened", () => {
  function note(type: string, extra: Partial<AppleNotification> = {}, data: Record<string, unknown> | null = {}): AppleNotification {
    return {
      notificationType: type,
      notificationUUID: "00000000-0000-4000-8000-000000000001",
      signedDate: NOW.getTime(),
      ...(data === null ? {} : { data: { environment: "Production", bundleId: "com.slateproapp.app", signedTransactionInfo: "tx-ok", ...data } }),
      ...extra,
    };
  }
  const body = (signedPayload = "note-ok") => ({ signedPayload });

  it("records a new subscription", async () => {
    const { deps, db } = makeDeps({ "note-ok": note("SUBSCRIBED"), "tx-ok": tx() });
    const result = await appleNotification(deps, body());
    assert.deepEqual(result, { status: 200, body: { status: "active", ignored: null } });
    const args = db.called("apple_record_subscription")[0].args;
    assert.equal(args.p_org, ORG);
    assert.equal(args.p_signed_at, NOW.toISOString(), "the notification's own signing time orders it");
    assert.equal(db.called("apple_org_for_transaction").length, 0, "the company is on the purchase");
  });

  it("finds the company from the subscription when the purchase carries none", async () => {
    const { deps, db } = makeDeps({ "note-ok": note("DID_RENEW"), "tx-ok": tx({ appAccountToken: undefined }) }, { apple_org_for_transaction: () => ORG });
    assert.equal((await appleNotification(deps, body())).status, 200);
    assert.deepEqual(db.called("apple_org_for_transaction")[0].args, { p_original_transaction_id: "1000000000000001" });
    assert.equal(db.called("apple_record_subscription")[0].args.p_org, ORG);
  });

  it("answers 200 and logs when no company owns the subscription, so Apple doesn't keep retrying", async () => {
    const { deps, db, logs } = makeDeps({ "note-ok": note("DID_RENEW"), "tx-ok": tx({ appAccountToken: "not-a-uuid" }) });
    assert.deepEqual(await appleNotification(deps, body()), { status: 200, body: { ignored: "unknown_company" } });
    assert.equal(db.called("apple_record_subscription").length, 0);
    assert.equal(logs.length, 1);
  });

  it("reads a failed renewal inside the grace period as past due", async () => {
    const grace = NOW.getTime() + 6 * DAY;
    const { deps, db } = makeDeps({
      "note-ok": note("DID_FAIL_TO_RENEW", { subtype: "GRACE_PERIOD" }, { signedTransactionInfo: "tx-late", signedRenewalInfo: "renew-grace" }),
      "tx-late": tx({ expiresDate: NOW.getTime() - 1000 }),
      "renew-grace": { isInBillingRetryPeriod: true, gracePeriodExpiresDate: grace, autoRenewStatus: 1, originalTransactionId: "1000000000000001" },
    });
    await appleNotification(deps, body());
    const args = db.called("apple_record_subscription")[0].args;
    assert.equal(args.p_status, "past_due");
    assert.equal(args.p_grace_until, new Date(grace).toISOString());
    assert.equal(args.p_renews, true);
  });

  it("reads an expired subscription as over", async () => {
    const { deps, db } = makeDeps({
      "note-ok": note("EXPIRED", { subtype: "VOLUNTARY" }, { signedTransactionInfo: "tx-old", signedRenewalInfo: "renew-off" }),
      "tx-old": tx({ expiresDate: NOW.getTime() - DAY }),
      "renew-off": { autoRenewStatus: 0, isInBillingRetryPeriod: false },
    });
    await appleNotification(deps, body());
    assert.equal(db.called("apple_record_subscription")[0].args.p_status, "canceled");
  });

  it("reads a refund as over, even though the period had not ended", async () => {
    const { deps, db } = makeDeps({ "note-ok": note("REFUND"), "tx-ok": tx({ revocationDate: NOW.getTime() - 5000 }) });
    await appleNotification(deps, body());
    assert.equal(db.called("apple_record_subscription")[0].args.p_status, "canceled");
  });

  it("reads turning renewal off as 'ending, but still good until then'", async () => {
    const { deps, db } = makeDeps({
      "note-ok": note("DID_CHANGE_RENEWAL_STATUS", { subtype: "AUTO_RENEW_DISABLED" }, { signedRenewalInfo: "renew-off" }),
      "tx-ok": tx(),
      "renew-off": { autoRenewStatus: 0 },
    });
    await appleNotification(deps, body());
    const args = db.called("apple_record_subscription")[0].args;
    assert.equal(args.p_status, "active");
    assert.equal(args.p_renews, false);
  });

  it("reads a move to a bigger step as the new product", async () => {
    const { deps, db } = makeDeps({
      "note-ok": note("DID_CHANGE_RENEWAL_PREF", { subtype: "UPGRADE" }),
      "tx-ok": tx({ productId: "com.slateproapp.app.company.team10" }),
    });
    await appleNotification(deps, body());
    assert.equal(db.called("apple_record_subscription")[0].args.p_product_id, "com.slateproapp.app.company.team10");
  });

  it("answers a test notification and one with nothing in it", async () => {
    const { deps, db } = makeDeps({ "note-test": note("TEST", {}, null), "note-none": note("PRICE_INCREASE", {}, { signedTransactionInfo: undefined }) });
    assert.deepEqual(await appleNotification(deps, body("note-test")), { status: 200, body: { ignored: "test" } });
    assert.deepEqual(await appleNotification(deps, body("note-none")), { status: 200, body: { ignored: "no_transaction" } });
    assert.equal(db.calls.length, 0);
  });

  it("ignores something that isn't a plan", async () => {
    const { deps, db } = makeDeps({ "note-ok": note("ONE_TIME_CHARGE"), "tx-ok": tx({ type: "Consumable" }) });
    assert.deepEqual(await appleNotification(deps, body()), { status: 200, body: { ignored: "not_a_plan" } });
    assert.equal(db.calls.length, 0);
  });

  it("refuses a payload Apple didn't sign", async () => {
    const { deps, db } = makeDeps({});
    assert.deepEqual(await appleNotification(deps, body("forged")), { status: 400, body: { error: "invalid_notification" } });
    assert.equal(db.calls.length, 0);
  });

  it("refuses a genuine payload that carries a transaction Apple didn't sign", async () => {
    const { deps, db } = makeDeps({ "note-ok": note("SUBSCRIBED", {}, { signedTransactionInfo: "forged-inner" }) });
    assert.deepEqual(await appleNotification(deps, body()), { status: 400, body: { error: "invalid_notification" } });
    assert.equal(db.called("apple_record_subscription").length, 0);
  });

  it("refuses malformed requests", async () => {
    const { deps } = makeDeps({});
    for (const bad of [null, {}, { signedPayload: "" }, { signedPayload: 3 }, "x"]) {
      assert.equal((await appleNotification(deps, bad)).status, 400);
    }
  });

  it("says when Apple's settings aren't in place", async () => {
    const { deps } = makeDeps({ "note-ok": new AppleConfigError("APPLE_APP_ID is not set") });
    assert.equal((await appleNotification(deps, body())).status, 503);
  });

  it("answers 200 for a message the database can't use, so Apple stops retrying it", async () => {
    for (const token of ["unknown_product", "transaction_in_use", "plan_exists", "not_found"]) {
      const { deps, logs } = makeDeps({ "note-ok": note("DID_RENEW"), "tx-ok": tx() }, { apple_record_subscription: () => new Error(`ERROR: ${token}`) });
      assert.deepEqual(await appleNotification(deps, body()), { status: 200, body: { ignored: token } }, token);
      assert.equal(logs.length, 1);
    }
  });

  it("answers 500 when the database is down, so Apple tries again", async () => {
    const { deps } = makeDeps({ "note-ok": note("DID_RENEW"), "tx-ok": tx() }, { apple_record_subscription: () => new Error("connection reset") });
    assert.deepEqual(await appleNotification(deps, body()), { status: 500, body: { error: "server_error" } });
  });

  it("passes on that the database ignored it as stale", async () => {
    const { deps } = makeDeps({ "note-ok": note("DID_RENEW"), "tx-ok": tx() }, { apple_record_subscription: () => ({ status: "active", ignored: "stale" }) });
    assert.deepEqual(await appleNotification(deps, body()), { status: 200, body: { status: "active", ignored: "stale" } });
  });
});
