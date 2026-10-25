// Cards on file: the logic behind the card Edge Functions, written like payments.ts and billing.ts as plain functions
// that take their dependencies (a database and a Stripe client), so Node can test them with fakes.
//
// What lives where:
//   - The rules (who may allow a creator, who may charge, what is owed, whether a card has expired) are in SQL, in
//     supabase/migrations/…_cards_on_file.sql, and are tested against a real Postgres.
//   - This file talks to Stripe and calls those SQL functions. It decides nothing about money or access: the amount,
//     the card and who may ask all come back from the database, and a payment is only ever recorded as received from
//     Stripe's own signed webhook (payments.ts), never from the answer to a charge made here.
//   - A card number never passes through here. Stripe's own page collects it; the functions only ever see Stripe's
//     references (cus_…, pm_…) and what is shown on screen: brand, last four digits, expiry.
//   - _shared/runtime.ts wires this to the real Stripe SDK. That wiring has never been run against live Stripe.
//
// Only erasable TypeScript syntax is used (no enums or parameter properties) so Node can run it directly.
import type { Db, HttpResult, StripeEvent, StripeIntent } from "./payments.ts";

// ---------------------------------------------------------------------------
// Shapes
// ---------------------------------------------------------------------------
/** A card as Stripe describes it. */
export interface StripeCardMethod {
  id: string;
  type?: string;
  customer?: string | null;
  card?: { brand?: string; last4?: string; exp_month?: number; exp_year?: number } | null;
}

/** The part of Stripe this uses. */
export interface CardStripe {
  customers: {
    create(params: Record<string, unknown>, options?: { idempotencyKey?: string }): Promise<{ id: string }>;
    del(id: string): Promise<unknown>;
  };
  checkout: {
    sessions: {
      create(params: Record<string, unknown>, options?: { idempotencyKey?: string }): Promise<{ url: string | null }>;
    };
  };
  paymentMethods: {
    list(params: Record<string, unknown>): Promise<{ data: StripeCardMethod[] }>;
    detach(id: string): Promise<unknown>;
  };
  paymentIntents: {
    create(params: Record<string, unknown>, options?: { idempotencyKey?: string }): Promise<StripeIntent>;
    retrieve(id: string): Promise<StripeIntent>;
    cancel(id: string): Promise<StripeIntent>;
  };
}

export interface CardConfig {
  /** Platform fee in basis points (100 = 1%), the same setting as for any payment. Zero by default. */
  platformFeeBps: number;
  /** Where the Edge Functions are served, e.g. https://<ref>.supabase.co/functions/v1 */
  functionsBaseUrl: string;
}

export interface CardDeps {
  db: Db;
  stripe: CardStripe;
  config: CardConfig;
  log: (message: string, detail?: unknown) => void;
}

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** What the database refuses with, and the HTTP status each is answered with. */
const REFUSALS: Record<string, number> = {
  not_found: 404,
  card_not_found: 404,
  no_card_access: 409,
  card_expired: 409,
  too_many_cards: 409,
  balance_not_due: 409,
  nothing_due: 409,
  already_paid: 409,
  payments_not_ready: 409,
};

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

function refusalOf(error: unknown): string | null {
  const message = messageOf(error);
  return Object.keys(REFUSALS).find((token) => new RegExp(`\\b${token}\\b`).test(message)) ?? null;
}

/** Anything Stripe threw, or the database refused, as the answer to the app. */
function failure(deps: CardDeps, error: unknown): HttpResult {
  if (asObject(error)?.type) {
    deps.log("stripe error", messageOf(error));
    return fail(502, "stripe_error");
  }
  const token = refusalOf(error);
  if (token) return fail(REFUSALS[token], token);
  deps.log("database error", messageOf(error));
  return fail(500, "server_error");
}

// ---------------------------------------------------------------------------
// Adding a card: Stripe's own page
// ---------------------------------------------------------------------------
/** What the page says under the button, in Stripe's words box. Plain, and true: see 8.14 in the spec. */
export const SETUP_NOTICE =
  "Stripe keeps this card; Slate Pro never sees the number. A creator can charge it only if you allow them in Slate Pro, " +
  "and only for the balance of a booking, once you've confirmed you have your files. You can stop that, or remove the card, at any time.";

/**
 * Returns a Stripe-hosted page where the person types a card to keep. Stripe tells the app when it is saved
 * (the webhook, or card-sync). Nothing is charged.
 */
export async function cardSetup(deps: CardDeps, userId: string): Promise<HttpResult> {
  try {
    // Refuses (too_many_cards) when the person is at the limit.
    const prepared = await deps.db.rpc<{ customer_id: string | null; card_count: number }>("card_prepare", { p_user: userId });

    let customer = prepared.customer_id;
    if (!customer) {
      const created = await deps.stripe.customers.create(
        // Only the person's id, so there is nothing about them at Stripe that Slate Pro doesn't already hold.
        { metadata: { user_id: userId } },
        // One customer per person even if two taps race.
        { idempotencyKey: `card-customer-${userId}` },
      );
      await deps.db.rpc("card_customer_save", { p_user: userId, p_customer_id: created.id });
      // If another request saved a customer first, that one stays; use it.
      customer = (await deps.db.rpc<string | null>("card_customer_for", { p_user: userId })) ?? created.id;
    }

    const session = await deps.stripe.checkout.sessions.create({
      mode: "setup",
      customer,
      payment_method_types: ["card"],
      setup_intent_data: { metadata: { user_id: userId } },
      metadata: { user_id: userId },
      client_reference_id: userId,
      custom_text: { submit: { message: SETUP_NOTICE } },
      success_url: `${deps.config.functionsBaseUrl}/card-redirect?to=return`,
      cancel_url: `${deps.config.functionsBaseUrl}/card-redirect?to=cancel`,
    });
    if (!session.url) return fail(502, "stripe_error");
    return ok({ url: session.url });
  } catch (error) {
    return failure(deps, error);
  }
}

/** Stripe only sends people back to https addresses, so it returns them here and this hands them on to the app. */
export function cardRedirect(to: string | null, appScheme: string): HttpResult {
  if (to !== "return" && to !== "cancel") return fail(400, "invalid_request");
  const location = `${appScheme}://cards/${to}`;
  return {
    status: 302,
    headers: { Location: location, "Content-Type": "text/html; charset=utf-8" },
    body: `<!doctype html><meta charset="utf-8"><title>Returning to Slate Pro</title><p>Returning to Slate Pro… <a href="${location}">Tap here if nothing happens.</a></p>`,
  };
}

// ---------------------------------------------------------------------------
// Keeping Stripe's list and ours in step
// ---------------------------------------------------------------------------
const hasCardDetails = (method: StripeCardMethod): boolean =>
  !!method.card &&
  typeof method.card.last4 === "string" &&
  typeof method.card.exp_month === "number" &&
  typeof method.card.exp_year === "number";

async function recordCard(deps: Pick<CardDeps, "db">, customer: string, method: StripeCardMethod): Promise<void> {
  const card = method.card!;
  await deps.db.rpc("card_record", {
    p_customer_id: customer,
    p_payment_method_id: method.id,
    p_brand: card.brand ?? "unknown",
    p_last4: card.last4,
    p_exp_month: card.exp_month,
    p_exp_year: card.exp_year,
  });
}

/**
 * The app calls this when it comes back from Stripe's page (the webhook may be a moment behind) and when the cards screen
 * opens. It records the cards Stripe has for the person and forgets the ones Stripe no longer has.
 */
export async function cardSync(deps: CardDeps, userId: string): Promise<HttpResult> {
  try {
    const customer = await deps.db.rpc<string | null>("card_customer_for", { p_user: userId });
    if (!customer) return ok({ cards: 0, removed: 0 });

    // If Stripe can't be asked, nothing is forgotten: an empty answer must mean "no cards", not "no answer".
    const listed = await deps.stripe.paymentMethods.list({ customer, type: "card", limit: 20 });
    const keep: string[] = [];
    for (const method of listed.data) {
      keep.push(method.id);
      if (hasCardDetails(method)) await recordCard(deps, customer, method);
    }
    const removed = await deps.db.rpc<number>("card_prune", { p_user: userId, p_keep: keep });
    return ok({ cards: keep.length, removed });
  } catch (error) {
    return failure(deps, error);
  }
}

/** Removes a card at Stripe first, then here (and with it every permission that used it). */
export async function cardRemove(deps: CardDeps, userId: string, input: unknown): Promise<HttpResult> {
  const cardId = asObject(input)?.card_id;
  if (typeof cardId !== "string" || !UUID.test(cardId)) return fail(400, "invalid_request");
  try {
    const method = await deps.db.rpc<string>("card_lookup", { p_user: userId, p_card_id: cardId });
    try {
      await deps.stripe.paymentMethods.detach(method);
    } catch (error) {
      // Already gone from Stripe is the outcome we wanted.
      if (!/no such paymentmethod|resource_missing|not attached/i.test(messageOf(error))) throw error;
    }
    await deps.db.rpc("card_forget", { p_user: userId, p_card_id: cardId });
    return ok({ removed: true });
  } catch (error) {
    return failure(deps, error);
  }
}

/**
 * Deleting an account takes its Stripe customer, and every card with it. Throws if Stripe can't be reached, so the
 * account is not deleted with its cards left behind where nobody could reach them.
 */
export async function forgetCards(deps: Pick<CardDeps, "db" | "stripe">, userId: string): Promise<"none" | "deleted"> {
  const customer = await deps.db.rpc<string | null>("card_customer_for", { p_user: userId });
  if (!customer) return "none";
  try {
    await deps.stripe.customers.del(customer);
  } catch (error) {
    if (!/no such customer|resource_missing/i.test(messageOf(error))) throw error;
  }
  return "deleted";
}

/**
 * Stripe's webhook, for cards. Returns whether the event was about a card (the others are for the payments code).
 * A card saved on Stripe's page arrives as payment_method.attached; a new expiry as payment_method.updated or
 * payment_method.automatically_updated; a card removed anywhere as payment_method.detached.
 */
export async function handleCardEvent(deps: Pick<CardDeps, "db" | "log">, event: StripeEvent): Promise<boolean> {
  const object = event.data.object;
  switch (event.type) {
    case "payment_method.attached":
    case "payment_method.updated":
    case "payment_method.automatically_updated": {
      if (object?.type !== "card" || typeof object.customer !== "string" || typeof object.id !== "string") return true;
      if (!hasCardDetails(object)) return true;
      try {
        await recordCard(deps, object.customer, object);
      } catch (error) {
        // A customer that isn't a client's (a company's plan, for one) has cards we don't keep.
        if (/unknown_customer/.test(messageOf(error))) return true;
        throw error;
      }
      return true;
    }
    case "payment_method.detached": {
      if (typeof object?.id === "string") await deps.db.rpc("card_forget_method", { p_payment_method_id: object.id });
      return true;
    }
    default:
      return false;
  }
}

// ---------------------------------------------------------------------------
// Charging the balance to a saved card
// ---------------------------------------------------------------------------
interface SavedPrepared {
  payment_id: string;
  booking_id: string;
  kind: string;
  amount_cents: number;
  currency: string;
  fee_cents: number;
  destination: string;
  existing_intent: string | null;
  description: string;
  customer: string;
  payment_method: string;
}

const DECLINED = "The card was declined.";
const NEEDS_CLIENT = "The bank needs the client to approve this payment.";

/**
 * Charges the balance of a booking to the client's saved card, for whoever can manage the booking, if the client has
 * allowed that creator. The amount, the card and the right to ask all come from the database. This function only
 * carries the charge out; whether it worked is recorded when Stripe's webhook says so, and the answer here is just
 * what to tell the person who asked.
 */
export async function chargeSavedCard(deps: CardDeps, userId: string, input: unknown): Promise<HttpResult> {
  const bookingId = asObject(input)?.booking_id;
  if (typeof bookingId !== "string" || !UUID.test(bookingId)) return fail(400, "invalid_request");

  const prepare = () =>
    deps.db.rpc<SavedPrepared>("payment_prepare_saved", {
      p_actor: userId,
      p_booking_id: bookingId,
      p_fee_bps: deps.config.platformFeeBps,
    });

  let prepared: SavedPrepared;
  try {
    prepared = await prepare();

    // A payment is already waiting on this booking: say the client started paying another way and didn't finish, or an
    // earlier try failed. If it is done or under way, leave it be; if not, close it so this one starts clean.
    if (prepared.existing_intent) {
      const existing = await deps.stripe.paymentIntents.retrieve(prepared.existing_intent);
      if (existing.status === "succeeded") return fail(409, "already_paid");
      if (existing.status === "processing") return fail(409, "payment_processing");
      if (existing.status !== "canceled") {
        try {
          await deps.stripe.paymentIntents.cancel(existing.id);
        } catch (error) {
          // It may have gone through a moment ago.
          const again = await deps.stripe.paymentIntents.retrieve(existing.id);
          if (again.status === "succeeded") return fail(409, "already_paid");
          if (again.status === "processing") return fail(409, "payment_processing");
          if (again.status !== "canceled") throw error;
        }
      }
      await deps.db.rpc("payment_record_failure", { p_intent_id: existing.id, p_message: "Replaced by a payment from the saved card." });
      prepared = await prepare();
      if (prepared.existing_intent) return fail(409, "payment_stale");
    }
  } catch (error) {
    return failure(deps, error);
  }

  const params: Record<string, unknown> = {
    amount: prepared.amount_cents,
    currency: prepared.currency,
    customer: prepared.customer,
    payment_method: prepared.payment_method,
    payment_method_types: ["card"],
    // The client isn't there: the bank may refuse it, and then the client pays in the app.
    off_session: true,
    confirm: true,
    transfer_data: { destination: prepared.destination },
    description: prepared.description,
    metadata: { payment_id: prepared.payment_id, booking_id: prepared.booking_id, kind: prepared.kind, saved_card: "true" },
  };
  if (prepared.fee_cents > 0) params.application_fee_amount = prepared.fee_cents;

  let intent: StripeIntent;
  try {
    intent = await deps.stripe.paymentIntents.create(params, { idempotencyKey: `payment-${prepared.payment_id}` });
  } catch (error) {
    const stripeError = asObject(error);
    if (stripeError?.type !== "StripeCardError") return failure(deps, error);
    // The bank said no. The payment is closed out as failed, so a later try starts a new one.
    const needsClient = stripeError.code === "authentication_required";
    const attempted = asObject(stripeError.payment_intent)?.id;
    try {
      if (typeof attempted === "string") {
        await deps.db.rpc("payment_attach_intent", { p_payment_id: prepared.payment_id, p_intent_id: attempted });
        await deps.db.rpc("payment_record_failure", { p_intent_id: attempted, p_message: needsClient ? NEEDS_CLIENT : DECLINED });
      }
    } catch (recording) {
      deps.log("could not record a declined card", messageOf(recording));
    }
    return fail(402, needsClient ? "authentication_required" : "card_declined");
  }

  try {
    await deps.db.rpc("payment_attach_intent", { p_payment_id: prepared.payment_id, p_intent_id: intent.id });
  } catch (error) {
    return failure(deps, error);
  }

  if (intent.status === "succeeded" || intent.status === "processing") {
    return ok({ payment_id: prepared.payment_id, status: intent.status, amount_cents: prepared.amount_cents, currency: prepared.currency });
  }

  // Anything else (the bank wants the client to approve it) can't be finished without them. Close it so it can't be
  // completed later by surprise.
  try {
    await deps.stripe.paymentIntents.cancel(intent.id);
  } catch (error) {
    deps.log("could not cancel an unfinished card payment", messageOf(error));
  }
  try {
    await deps.db.rpc("payment_record_failure", { p_intent_id: intent.id, p_message: NEEDS_CLIENT });
  } catch (error) {
    return failure(deps, error);
  }
  return fail(402, "authentication_required");
}
