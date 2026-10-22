// The payment logic behind the Edge Functions, written as plain functions that take their
// dependencies (a database and a Stripe client) as arguments. That keeps them testable with Node
// and fakes (see ios/supabase/function-tests) without Deno, a database or a Stripe account.
//
// What lives where:
//   - The rules (who may pay what, how much, refund amounts, state changes) are in SQL, in
//     supabase/migrations/…_payments.sql, and are tested against a real Postgres.
//   - This file talks to Stripe and calls those SQL functions. It decides nothing about money itself:
//     amounts always come back from the database, never from a caller.
//   - _shared/runtime.ts wires these to the real Stripe SDK and Supabase client. That wiring has never
//     been run against live services.
//
// Only erasable TypeScript syntax is used (no enums or parameter properties) so Node can run it directly.

// ---------------------------------------------------------------------------
// Shapes
// ---------------------------------------------------------------------------
export interface HttpResult {
  status: number;
  body: unknown;
  headers?: Record<string, string>;
}

/** The service-role database. `rpc` calls a SQL function and throws a DbError if it raises. */
export interface Db {
  rpc<T = unknown>(fn: string, args?: Record<string, unknown>): Promise<T>;
}

export interface StripeIntent {
  id: string;
  status: string;
  client_secret: string | null;
}

export interface StripeLike {
  paymentIntents: {
    create(params: Record<string, unknown>, options?: { idempotencyKey?: string }): Promise<StripeIntent>;
    retrieve(id: string): Promise<StripeIntent>;
  };
  refunds: {
    create(
      params: Record<string, unknown>,
      options?: { idempotencyKey?: string },
    ): Promise<{ id: string; status: string | null; failure_reason?: string | null }>;
  };
  accounts: {
    create(params: Record<string, unknown>, options?: { idempotencyKey?: string }): Promise<{ id: string }>;
    retrieve(id: string): Promise<{
      id: string;
      charges_enabled?: boolean;
      payouts_enabled?: boolean;
      details_submitted?: boolean;
    }>;
  };
  accountLinks: {
    create(params: Record<string, unknown>): Promise<{ url: string }>;
  };
  webhooks: {
    /** Verifies the signature and parses the event, or throws. */
    constructEventAsync(payload: string, signature: string, secret: string): Promise<StripeEvent>;
  };
}

export interface StripeEvent {
  id: string;
  type: string;
  // deno-lint-ignore no-explicit-any
  data: { object: any };
}

export interface Config {
  /** Platform fee in basis points (100 = 1%). Zero by default. */
  platformFeeBps: number;
  /** Where the Edge Functions are served, e.g. https://<ref>.supabase.co/functions/v1 */
  functionsBaseUrl: string;
  webhookSecret: string;
  /** The app's URL scheme, for sending the browser back to the app after Stripe onboarding. */
  appScheme: string;
}

export interface Deps {
  db: Db;
  stripe: StripeLike;
  config: Config;
  log: (message: string, detail?: unknown) => void;
}

// ---------------------------------------------------------------------------
// Errors from the database
// ---------------------------------------------------------------------------
// The SQL functions raise plain tokens such as `hold_expired`. This finds them in the error text.
const TOKENS = [
  "payments_not_ready",
  "hold_expired",
  "payment_not_due",
  "balance_not_due",
  "nothing_due",
  "already_paid",
  "not_found",
  "invalid_kind",
  "amount_mismatch",
  "unknown_payment",
] as const;

export class DbError extends Error {
  token: string | null;
  constructor(message: string) {
    super(message);
    this.name = "DbError";
    this.token = TOKENS.find((token) => message.includes(token)) ?? null;
  }
}

const PAYMENT_ERROR_STATUS: Record<string, number> = {
  not_found: 404,
  payments_not_ready: 409,
  hold_expired: 409,
  payment_not_due: 409,
  balance_not_due: 409,
  nothing_due: 409,
  already_paid: 409,
  invalid_kind: 400,
};

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

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

function dbFailure(deps: Deps, error: unknown): HttpResult {
  if (error instanceof DbError && error.token && error.token in PAYMENT_ERROR_STATUS) {
    return fail(PAYMENT_ERROR_STATUS[error.token], error.token);
  }
  deps.log("database error", messageOf(error));
  return fail(500, "server_error");
}

function stripeFailure(deps: Deps, error: unknown): HttpResult {
  deps.log("stripe error", messageOf(error));
  return fail(502, "stripe_error");
}

/** Stripe errors that mean "this will never work" rather than "try again later". */
function isPermanentStripeError(error: unknown): boolean {
  const type = asObject(error)?.type;
  return type === "StripeInvalidRequestError" || type === "StripeCardError";
}

// ---------------------------------------------------------------------------
// Paying: deposit and balance
// ---------------------------------------------------------------------------
interface Prepared {
  payment_id: string;
  booking_id: string;
  kind: string;
  amount_cents: number;
  currency: string;
  fee_cents: number;
  destination: string;
  existing_intent: string | null;
  description: string;
}

/**
 * Opens (or reuses) a PaymentIntent for a booking's deposit or balance and returns its client secret,
 * which the app's Apple Pay sheet uses to pay. The amount and destination come from the database.
 */
export async function createPaymentIntent(deps: Deps, userId: string, input: unknown): Promise<HttpResult> {
  const body = asObject(input);
  const bookingId = body?.booking_id;
  const kind = body?.kind;
  if (typeof bookingId !== "string" || !UUID.test(bookingId) || (kind !== "deposit" && kind !== "balance")) {
    return fail(400, "invalid_request");
  }

  let prepared: Prepared;
  try {
    prepared = await deps.db.rpc<Prepared>("payment_prepare", {
      p_user_id: userId,
      p_booking_id: bookingId,
      p_kind: kind,
      p_fee_bps: deps.config.platformFeeBps,
    });
  } catch (error) {
    return dbFailure(deps, error);
  }

  const respond = (clientSecret: string): HttpResult =>
    ok({
      payment_id: prepared.payment_id,
      client_secret: clientSecret,
      amount_cents: prepared.amount_cents,
      currency: prepared.currency,
    });

  // A second tap, or a retry after the app lost the first answer: use the intent already made.
  if (prepared.existing_intent) {
    let existing: StripeIntent;
    try {
      existing = await deps.stripe.paymentIntents.retrieve(prepared.existing_intent);
    } catch (error) {
      return stripeFailure(deps, error);
    }
    if (existing.status === "succeeded") return fail(409, "already_paid");
    if (existing.status === "processing") return fail(409, "payment_processing");
    if (existing.status === "canceled") {
      // Can't be used again. Close it out so the next attempt starts a fresh payment.
      try {
        await deps.db.rpc("payment_record_failure", { p_intent_id: existing.id, p_message: "This payment was cancelled." });
      } catch (error) {
        return dbFailure(deps, error);
      }
      return fail(409, "payment_stale");
    }
    if (!existing.client_secret) return fail(502, "stripe_error");
    return respond(existing.client_secret);
  }

  let intent: StripeIntent;
  try {
    const params: Record<string, unknown> = {
      amount: prepared.amount_cents,
      currency: prepared.currency,
      // Apple Pay is a card payment method as far as Stripe is concerned.
      payment_method_types: ["card"],
      // The creator is paid directly; the platform keeps only its fee (none by default).
      transfer_data: { destination: prepared.destination },
      description: prepared.description,
      metadata: { payment_id: prepared.payment_id, booking_id: prepared.booking_id, kind: prepared.kind },
    };
    if (prepared.fee_cents > 0) params.application_fee_amount = prepared.fee_cents;
    intent = await deps.stripe.paymentIntents.create(params, { idempotencyKey: `payment-${prepared.payment_id}` });
  } catch (error) {
    return stripeFailure(deps, error);
  }
  if (!intent.client_secret) return fail(502, "stripe_error");

  try {
    await deps.db.rpc("payment_attach_intent", { p_payment_id: prepared.payment_id, p_intent_id: intent.id });
  } catch (error) {
    return dbFailure(deps, error);
  }
  return respond(intent.client_secret);
}

// ---------------------------------------------------------------------------
// Refunds
// ---------------------------------------------------------------------------
interface RefundRow {
  refund_id: string;
  amount_cents: number;
  payment_intent_id: string | null;
  stripe_refund_id: string | null;
}

export interface RefundOutcome {
  refund_id: string;
  /** retry = couldn't reach Stripe; it stays pending and a later call will try again. */
  status: "succeeded" | "pending" | "failed" | "retry";
}

function refundStatus(stripeStatus: string | null): "succeeded" | "pending" | "failed" {
  if (stripeStatus === "succeeded") return "succeeded";
  if (stripeStatus === "failed" || stripeStatus === "canceled") return "failed";
  return "pending";
}

/**
 * Sends every refund the database says is owed for a booking to Stripe. The refund *amounts* were decided
 * in SQL when the booking was cancelled; this only carries them out. Safe to run repeatedly: Stripe is given
 * a fixed idempotency key per refund, and a refund that Stripe couldn't be reached for stays pending.
 */
export async function issueRefunds(deps: Deps, bookingId: string): Promise<RefundOutcome[]> {
  const rows = await deps.db.rpc<RefundRow[]>("refunds_to_process", { p_booking_id: bookingId });
  const outcomes: RefundOutcome[] = [];

  for (const row of rows ?? []) {
    if (!row.payment_intent_id) {
      await deps.db.rpc("refund_record_result", {
        p_refund_id: row.refund_id,
        p_status: "failed",
        p_stripe_refund_id: null,
        p_message: "There is no Stripe payment to refund.",
      });
      outcomes.push({ refund_id: row.refund_id, status: "failed" });
      continue;
    }

    try {
      const refund = await deps.stripe.refunds.create(
        {
          payment_intent: row.payment_intent_id,
          amount: row.amount_cents,
          // The payment went to the creator: take it back from them, and give back any platform fee pro rata.
          reverse_transfer: true,
          refund_application_fee: true,
          metadata: { refund_id: row.refund_id },
        },
        { idempotencyKey: `refund-${row.refund_id}` },
      );
      const status = refundStatus(refund.status);
      await deps.db.rpc("refund_record_result", {
        p_refund_id: row.refund_id,
        p_status: status,
        p_stripe_refund_id: refund.id,
        p_message: refund.failure_reason ?? null,
      });
      outcomes.push({ refund_id: row.refund_id, status });
    } catch (error) {
      if (!isPermanentStripeError(error)) {
        deps.log("refund will be retried", { refund: row.refund_id, error: messageOf(error) });
        outcomes.push({ refund_id: row.refund_id, status: "retry" });
        continue;
      }
      await deps.db.rpc("refund_record_result", {
        p_refund_id: row.refund_id,
        p_status: "failed",
        p_stripe_refund_id: null,
        p_message: messageOf(error).slice(0, 300),
      });
      outcomes.push({ refund_id: row.refund_id, status: "failed" });
    }
  }
  return outcomes;
}

/** The app calls this after cancelling. Either person on the booking may; nobody else. */
export async function processRefundsRequest(deps: Deps, userId: string, input: unknown): Promise<HttpResult> {
  const bookingId = asObject(input)?.booking_id;
  if (typeof bookingId !== "string" || !UUID.test(bookingId)) return fail(400, "invalid_request");

  try {
    const isParty = await deps.db.rpc<boolean>("is_booking_party", { p_user_id: userId, p_booking_id: bookingId });
    if (!isParty) return fail(404, "not_found");
    return ok({ refunds: await issueRefunds(deps, bookingId) });
  } catch (error) {
    return dbFailure(deps, error);
  }
}

// ---------------------------------------------------------------------------
// Stripe's webhook
// ---------------------------------------------------------------------------
/**
 * Stripe tells us what really happened to a payment. Everything that changes a booking because of money
 * starts here, never from the app, so a client can't claim to have paid.
 */
export async function handleStripeWebhook(deps: Deps, rawBody: string, signature: string | null): Promise<HttpResult> {
  if (!signature) return fail(400, "bad_signature");

  let event: StripeEvent;
  try {
    event = await deps.stripe.webhooks.constructEventAsync(rawBody, signature, deps.config.webhookSecret);
  } catch (error) {
    deps.log("webhook signature rejected", messageOf(error));
    return fail(400, "bad_signature");
  }

  try {
    const claimed = await deps.db.rpc<boolean>("webhook_claim_event", { p_event_id: event.id, p_type: event.type });
    if (!claimed) return ok({ received: true, duplicate: true });

    await dispatch(deps, event);
    await deps.db.rpc("webhook_event_done", { p_event_id: event.id });
    return ok({ received: true });
  } catch (error) {
    // Not marked as done, and a 500 makes Stripe send it again.
    deps.log("webhook failed; Stripe will retry", { event: event.id, type: event.type, error: messageOf(error) });
    return fail(500, "webhook_failed");
  }
}

async function dispatch(deps: Deps, event: StripeEvent): Promise<void> {
  const object = event.data.object;

  switch (event.type) {
    case "payment_intent.succeeded": {
      // Only payments this app started carry our metadata.
      if (!object?.metadata?.payment_id) return;
      const result = await deps.db.rpc<{ action: string; booking_id: string }>("payment_record_success", {
        p_intent_id: object.id,
        p_amount_cents: object.amount_received ?? object.amount,
        p_charge_id: typeof object.latest_charge === "string" ? object.latest_charge : null,
        // Apple Pay is the only way the app collects money.
        p_method: "apple_pay",
      });
      if (result.action === "refund_required") {
        // The money arrived too late (or for a cancelled booking). Send it back.
        await issueRefunds(deps, result.booking_id);
      }
      return;
    }
    case "payment_intent.payment_failed": {
      if (!object?.metadata?.payment_id) return;
      await deps.db.rpc("payment_record_failure", {
        p_intent_id: object.id,
        p_message: object.last_payment_error?.message ?? null,
      });
      return;
    }
    case "refund.created":
    case "refund.updated":
    case "refund.failed":
    case "charge.refund.updated": {
      if (!object?.id) return;
      await deps.db.rpc("refund_record_by_stripe_id", {
        p_stripe_refund_id: object.id,
        p_status: event.type === "refund.failed" ? "failed" : refundStatus(object.status ?? null),
        p_message: object.failure_reason ?? null,
      });
      return;
    }
    case "account.updated": {
      if (!object?.id) return;
      await deps.db.rpc("connect_account_update", {
        p_account_id: object.id,
        p_charges: !!object.charges_enabled,
        p_payouts: !!object.payouts_enabled,
        p_details: !!object.details_submitted,
      });
      return;
    }
    default:
      return; // Events we don't care about are acknowledged and ignored.
  }
}

// ---------------------------------------------------------------------------
// Stripe Connect: getting a creator ready to be paid
// ---------------------------------------------------------------------------
export interface ConnectStatus {
  connected: boolean;
  charges_enabled: boolean;
  payouts_enabled: boolean;
  details_submitted: boolean;
  /** Where to send the creator to finish setting up, when there is more to do. */
  url?: string;
}

/**
 * Creates the creator's Stripe Express account the first time, refreshes what Stripe says about it, and
 * (unless `action` is "status") returns a link to finish onboarding when there is more to do.
 */
export async function connectOnboarding(deps: Deps, userId: string, input: unknown): Promise<HttpResult> {
  const wantsLink = asObject(input)?.action !== "status";

  try {
    let accountId = await deps.db.rpc<string | null>("connect_account_for", { p_creator_id: userId });

    if (!accountId) {
      if (!wantsLink) {
        const none: ConnectStatus = { connected: false, charges_enabled: false, payouts_enabled: false, details_submitted: false };
        return ok(none);
      }
      const created = await deps.stripe.accounts.create(
        {
          type: "express",
          capabilities: { card_payments: { requested: true }, transfers: { requested: true } },
          metadata: { user_id: userId },
        },
        // One account per person even if two taps race.
        { idempotencyKey: `connect-account-${userId}` },
      );
      try {
        await deps.db.rpc("connect_account_save", { p_creator_id: userId, p_account_id: created.id });
      } catch (error) {
        // The creator has no profile yet; the account is kept by Stripe and picked up again next time.
        if (/foreign key|creator_profiles/i.test(messageOf(error))) return fail(409, "profile_required");
        throw error;
      }
      accountId = (await deps.db.rpc<string | null>("connect_account_for", { p_creator_id: userId })) ?? created.id;
    }

    const account = await deps.stripe.accounts.retrieve(accountId);
    await deps.db.rpc("connect_account_update", {
      p_account_id: accountId,
      p_charges: !!account.charges_enabled,
      p_payouts: !!account.payouts_enabled,
      p_details: !!account.details_submitted,
    });

    const status: ConnectStatus = {
      connected: true,
      charges_enabled: !!account.charges_enabled,
      payouts_enabled: !!account.payouts_enabled,
      details_submitted: !!account.details_submitted,
    };
    if (!wantsLink || (status.charges_enabled && status.payouts_enabled)) return ok(status);

    const link = await deps.stripe.accountLinks.create({
      account: accountId,
      type: "account_onboarding",
      refresh_url: `${deps.config.functionsBaseUrl}/connect-redirect?to=refresh`,
      return_url: `${deps.config.functionsBaseUrl}/connect-redirect?to=return`,
    });
    return ok({ ...status, url: link.url });
  } catch (error) {
    if (asObject(error)?.type) return stripeFailure(deps, error);
    return dbFailure(deps, error);
  }
}

/**
 * Stripe only sends people back to https addresses, so it returns them here, and this hands them on to the
 * app through its own URL scheme (which closes the in-app browser sheet).
 */
export function connectRedirect(to: string | null, appScheme: string): HttpResult {
  if (to !== "return" && to !== "refresh") return fail(400, "invalid_request");
  const location = `${appScheme}://stripe/${to}`;
  return {
    status: 302,
    headers: { Location: location, "Content-Type": "text/html; charset=utf-8" },
    body: `<!doctype html><meta charset="utf-8"><title>Returning to Slate</title><p>Returning to Slate… <a href="${location}">Tap here if nothing happens.</a></p>`,
  };
}
