// The company plan bought with Apple's In-App Purchase: the logic behind the `apple-verify` and `apple-notifications`
// Edge Functions, written like billing.ts as plain functions that take their dependencies so Node can test them.
//
// What lives where:
//   - Whether a plan is good, how many people it covers, the grace period and what happens when it ends are rules in SQL
//     (supabase/migrations/…_apple_plans.sql), tested against a real Postgres. This file decides none of that.
//   - Whether a message really came from Apple is decided by Apple's own signature, checked by an `AppleVerifier`
//     (apple_signed.ts). Nothing in a request is believed until that check passes: not the product, the company, the
//     dates or the environment. The app never says a plan is paid; it can only hand over what Apple signed.
//   - This file turns what Apple signed into the few facts the database records (status, period end, whether it renews)
//     and calls `apple_record_subscription`. The state comes from the data, never from the notification's name, so a
//     notification that arrives twice, late or out of order still leaves the right answer.
//
// Only erasable TypeScript syntax is used (no enums or parameter properties) so Node can run it directly.
import type { Db, HttpResult } from "./payments.ts";

// ---------------------------------------------------------------------------
// What Apple signs
// ---------------------------------------------------------------------------
/** The fields of a signed transaction (Apple's JWSTransactionDecodedPayload) that this uses. Dates are milliseconds. */
export interface AppleTransaction {
  bundleId?: string;
  productId?: string;
  originalTransactionId?: string;
  transactionId?: string;
  type?: string;
  environment?: string;
  /** The company's id, set by the app when it started the purchase. */
  appAccountToken?: string;
  purchaseDate?: number;
  expiresDate?: number;
  revocationDate?: number;
  /** 1 is an introductory offer. */
  offerType?: number;
  offerDiscountType?: string;
  signedDate?: number;
}

/** The fields of signed renewal information (JWSRenewalInfoDecodedPayload) that this uses. */
export interface AppleRenewalInfo {
  /** 1 when it will renew, 0 when the person turned renewal off. */
  autoRenewStatus?: number;
  isInBillingRetryPeriod?: boolean;
  gracePeriodExpiresDate?: number;
  originalTransactionId?: string;
  environment?: string;
  signedDate?: number;
}

/** A decoded App Store Server Notification (version 2). */
export interface AppleNotification {
  notificationType?: string;
  subtype?: string;
  notificationUUID?: string;
  signedDate?: number;
  data?: {
    environment?: string;
    bundleId?: string;
    signedTransactionInfo?: string;
    signedRenewalInfo?: string;
  };
}

/** Checks Apple's signature, the app's bundle id and the environment, then decodes. Each throws if anything is wrong. */
export interface AppleVerifier {
  transaction(signed: string): Promise<AppleTransaction>;
  renewal(signed: string): Promise<AppleRenewalInfo>;
  notification(signed: string): Promise<AppleNotification>;
}

/** The data didn't verify: wrong signature, another app, a malformed message. */
export class AppleVerifyError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "AppleVerifyError";
  }
}

/** Verification can't run here: Apple's settings aren't in place (for instance the app's Apple id for production). */
export class AppleConfigError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "AppleConfigError";
  }
}

export interface AppleDeps {
  db: Db;
  verifier: AppleVerifier;
  now: () => Date;
  log: (message: string, detail?: unknown) => void;
}

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const SUBSCRIPTION = "Auto-Renewable Subscription";

function ok(body: unknown): HttpResult {
  return { status: 200, body };
}

function fail(status: number, error: string): HttpResult {
  return { status, body: { error } };
}

function asObject(value: unknown): Record<string, unknown> | null {
  return typeof value === "object" && value !== null && !Array.isArray(value) ? (value as Record<string, unknown>) : null;
}

function messageOf(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

function isDate(ms: unknown): ms is number {
  return typeof ms === "number" && Number.isFinite(ms) && ms > 0;
}

function toDate(ms: number | undefined): Date | null {
  return isDate(ms) ? new Date(ms) : null;
}

// ---------------------------------------------------------------------------
// From what Apple signed to what the database records
// ---------------------------------------------------------------------------
export type PlanStatus = "trialing" | "active" | "past_due" | "canceled";

export interface PlanFacts {
  status: PlanStatus;
  /** When the paid (or free) period being recorded ends. */
  periodEnd: Date | null;
  /** The end of the free trial, only while it is one. */
  trialEnd: Date | null;
  /** True or false when Apple said, null when this message doesn't say (the database then leaves it as it is). */
  renews: boolean | null;
  /** Apple's own grace period for a failed payment, when it gave one. */
  graceUntil: Date | null;
}

/**
 * The state of a plan, read from a signed transaction and (when there is one) its signed renewal information.
 *  - A refund or revoked purchase is over.
 *  - A period that hasn't ended is a plan in good standing, a free trial while it is the introductory free offer.
 *  - A period that has ended with Apple still trying the card is past due (inside Apple's grace period if it has one).
 *  - A period that has ended and nothing more is coming is over.
 */
export function planFacts(tx: AppleTransaction, renewal: AppleRenewalInfo | null, now: Date): PlanFacts {
  const expires = toDate(tx.expiresDate);
  const renews = renewal && typeof renewal.autoRenewStatus === "number" ? renewal.autoRenewStatus === 1 : null;
  const grace = renewal && isDate(renewal.gracePeriodExpiresDate) ? new Date(renewal.gracePeriodExpiresDate) : null;
  const retrying = renewal?.isInBillingRetryPeriod === true;

  if (isDate(tx.revocationDate)) {
    return { status: "canceled", periodEnd: expires, trialEnd: null, renews: false, graceUntil: null };
  }
  if (expires && expires.getTime() > now.getTime()) {
    const trial = tx.offerType === 1 && tx.offerDiscountType === "FREE_TRIAL";
    return { status: trial ? "trialing" : "active", periodEnd: expires, trialEnd: trial ? expires : null, renews, graceUntil: null };
  }
  if (grace && grace.getTime() > now.getTime()) {
    return { status: "past_due", periodEnd: expires, trialEnd: null, renews, graceUntil: grace };
  }
  if (retrying) {
    return { status: "past_due", periodEnd: expires, trialEnd: null, renews, graceUntil: null };
  }
  return { status: "canceled", periodEnd: expires, trialEnd: null, renews: false, graceUntil: null };
}

interface Recorded {
  status?: string;
  seats?: number;
  state?: string;
  ignored?: string;
}

async function record(deps: AppleDeps, org: string, tx: AppleTransaction, facts: PlanFacts, signedAt: Date): Promise<Recorded> {
  return await deps.db.rpc<Recorded>("apple_record_subscription", {
    p_org: org,
    p_original_transaction_id: tx.originalTransactionId,
    p_product_id: tx.productId,
    p_environment: tx.environment,
    p_status: facts.status,
    p_period_end: facts.periodEnd ? facts.periodEnd.toISOString() : null,
    p_trial_end: facts.trialEnd ? facts.trialEnd.toISOString() : null,
    p_renews: facts.renews,
    p_grace_until: facts.graceUntil ? facts.graceUntil.toISOString() : null,
    p_signed_at: signedAt.toISOString(),
  });
}

/** What the database refuses, as an answer the app can act on. */
function recordFailure(error: unknown): HttpResult | null {
  const text = messageOf(error);
  if (/unknown_product/.test(text)) return fail(422, "unknown_product");
  if (/transaction_in_use/.test(text)) return fail(409, "transaction_in_use");
  if (/plan_exists/.test(text)) return fail(409, "plan_exists");
  if (/not_found/.test(text)) return fail(404, "not_found");
  if (/invalid_input/.test(text)) return fail(400, "invalid_input");
  return null;
}

function usable(tx: AppleTransaction): boolean {
  return (
    typeof tx.originalTransactionId === "string" && tx.originalTransactionId !== "" &&
    typeof tx.productId === "string" && tx.productId !== "" &&
    (tx.environment === "Sandbox" || tx.environment === "Production")
  );
}

// ---------------------------------------------------------------------------
// apple-verify: the app hands over a purchase it has just made (or the one it holds now)
// ---------------------------------------------------------------------------
/**
 * POST { organization_id, signed_transaction, signed_renewal_info? } from the signed-in Owner. The company must be the one
 * the purchase was made for: the id the app put on the purchase is inside what Apple signed, so it can't be changed.
 */
export async function appleVerify(deps: AppleDeps, userId: string, input: unknown): Promise<HttpResult> {
  const asked = asObject(input);
  const org = asked?.organization_id;
  const signedTransaction = asked?.signed_transaction;
  const signedRenewal = asked?.signed_renewal_info;
  if (
    typeof org !== "string" || !UUID.test(org) ||
    typeof signedTransaction !== "string" || signedTransaction === "" || signedTransaction.length > 20000 ||
    (signedRenewal !== undefined && signedRenewal !== null && (typeof signedRenewal !== "string" || signedRenewal.length > 20000))
  ) {
    return fail(400, "invalid_request");
  }
  const organizationId = org.toLowerCase();

  try {
    if (!(await deps.db.rpc<boolean>("billing_authorize", { p_user: userId, p_org: organizationId }))) {
      return fail(404, "not_found");
    }

    let tx: AppleTransaction;
    let renewal: AppleRenewalInfo | null = null;
    try {
      tx = await deps.verifier.transaction(signedTransaction);
      if (typeof signedRenewal === "string" && signedRenewal !== "") renewal = await deps.verifier.renewal(signedRenewal);
    } catch (error) {
      if (error instanceof AppleConfigError) {
        deps.log("apple is not configured", messageOf(error));
        return fail(503, "apple_not_configured");
      }
      deps.log("apple data did not verify", messageOf(error));
      return fail(400, "invalid_transaction");
    }

    if (!usable(tx) || tx.type !== SUBSCRIPTION) return fail(400, "not_a_plan");
    if (renewal && renewal.originalTransactionId !== undefined && renewal.originalTransactionId !== tx.originalTransactionId) {
      return fail(400, "invalid_transaction");
    }
    if (typeof tx.appAccountToken !== "string" || tx.appAccountToken.toLowerCase() !== organizationId) {
      return fail(409, "wrong_company");
    }

    const now = deps.now();
    const facts = planFacts(tx, renewal, now);
    const signedAt = toDate(tx.signedDate) ?? now;
    const result = await record(deps, organizationId, tx, facts, signedAt);
    return ok({ status: result.status ?? facts.status, seats: result.seats ?? null, state: result.state ?? null, ignored: result.ignored ?? null });
  } catch (error) {
    const known = recordFailure(error);
    if (known) return known;
    deps.log("database error", messageOf(error));
    return fail(500, "server_error");
  }
}

// ---------------------------------------------------------------------------
// apple-notifications: Apple tells the server what happened (App Store Server Notifications, version 2)
// ---------------------------------------------------------------------------
/**
 * POST { signedPayload } from Apple. The signature is the only credential, so nothing happens until it verifies. A
 * message that is fine but can't be used (an unknown company, a product we don't sell) is answered 200 and logged, so Apple
 * doesn't retry it for days; a message that fails because the database is down is answered 500, so Apple does.
 */
export async function appleNotification(deps: AppleDeps, input: unknown): Promise<HttpResult> {
  const asked = asObject(input);
  const signedPayload = asked?.signedPayload;
  if (typeof signedPayload !== "string" || signedPayload === "" || signedPayload.length > 100000) {
    return fail(400, "invalid_request");
  }

  let notification: AppleNotification;
  try {
    notification = await deps.verifier.notification(signedPayload);
  } catch (error) {
    if (error instanceof AppleConfigError) {
      deps.log("apple is not configured", messageOf(error));
      return fail(503, "apple_not_configured");
    }
    deps.log("apple notification did not verify", messageOf(error));
    return fail(400, "invalid_notification");
  }

  const type = notification.notificationType ?? "";
  const signedTransaction = notification.data?.signedTransactionInfo;
  if (type === "TEST" || typeof signedTransaction !== "string" || signedTransaction === "") {
    return ok({ ignored: type === "TEST" ? "test" : "no_transaction" });
  }

  try {
    let tx: AppleTransaction;
    let renewal: AppleRenewalInfo | null = null;
    try {
      tx = await deps.verifier.transaction(signedTransaction);
      const signedRenewal = notification.data?.signedRenewalInfo;
      if (typeof signedRenewal === "string" && signedRenewal !== "") renewal = await deps.verifier.renewal(signedRenewal);
    } catch (error) {
      deps.log("apple transaction in a notification did not verify", messageOf(error));
      return fail(400, "invalid_notification");
    }
    if (!usable(tx) || tx.type !== SUBSCRIPTION) return ok({ ignored: "not_a_plan" });

    // The company: the id the app put on the purchase, or, for a subscription we have seen before, the one it belongs to.
    let org: string | null = null;
    if (typeof tx.appAccountToken === "string" && UUID.test(tx.appAccountToken)) org = tx.appAccountToken.toLowerCase();
    if (!org) org = await deps.db.rpc<string | null>("apple_org_for_transaction", { p_original_transaction_id: tx.originalTransactionId });
    if (!org) {
      deps.log("apple notification for a subscription no company owns", { type, originalTransactionId: tx.originalTransactionId });
      return ok({ ignored: "unknown_company" });
    }

    const now = deps.now();
    const facts = planFacts(tx, renewal, now);
    const signedAt = toDate(notification.signedDate) ?? toDate(tx.signedDate) ?? now;
    try {
      const result = await record(deps, org, tx, facts, signedAt);
      return ok({ status: result.status ?? facts.status, ignored: result.ignored ?? null });
    } catch (error) {
      const known = recordFailure(error);
      if (known) {
        deps.log("apple notification could not be recorded", { type, error: known.body });
        return ok({ ignored: (known.body as { error: string }).error });
      }
      throw error;
    }
  } catch (error) {
    deps.log("database error", messageOf(error));
    return fail(500, "server_error");
  }
}
