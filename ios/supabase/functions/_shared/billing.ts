// Seat billing for companies: the logic behind the billing Edge Functions, written like payments.ts as plain functions
// that take their dependencies (a database and a Stripe client) so Node can test them with fakes.
//
// What lives where:
//   - The rules (who may open billing, what the plan state is, how many seats a team needs, when a company becomes
//     read only) are in SQL, in supabase/migrations/…_seat_billing.sql, and are tested against a real Postgres.
//   - This file talks to Stripe and calls those SQL functions. It decides nothing about money or access: seat counts
//     come from the database, and a plan is only ever recorded from Stripe's own signed webhook.
//   - _shared/runtime.ts wires it to the real Stripe SDK. That wiring has never been run against live Stripe.
//
// Only erasable TypeScript syntax is used (no enums or parameter properties) so Node can run it directly.
import type { Db, HttpResult, StripeEvent } from "./payments.ts";
import { isAuthorized } from "./push.ts";

// ---------------------------------------------------------------------------
// Shapes
// ---------------------------------------------------------------------------
export interface BillingSubscription {
  id: string;
  status: string;
  items: { data: { id: string; quantity?: number | null }[] };
}

/** The part of Stripe Billing this uses. */
export interface BillingStripe {
  customers: {
    create(params: Record<string, unknown>, options?: { idempotencyKey?: string }): Promise<{ id: string }>;
  };
  checkout: {
    sessions: {
      create(params: Record<string, unknown>, options?: { idempotencyKey?: string }): Promise<{ url: string | null }>;
    };
  };
  billingPortal: {
    sessions: { create(params: Record<string, unknown>): Promise<{ url: string }> };
  };
  subscriptions: {
    retrieve(id: string): Promise<BillingSubscription>;
    cancel(id: string): Promise<{ id: string; status: string }>;
  };
  subscriptionItems: {
    update(id: string, params: Record<string, unknown>, options?: { idempotencyKey?: string }): Promise<{ id: string; quantity?: number | null }>;
  };
}

export interface BillingConfig {
  /** Where the Edge Functions are served, e.g. https://<ref>.supabase.co/functions/v1 */
  functionsBaseUrl: string;
  /** The Stripe Price for one seat for one month. Empty when billing isn't set up. */
  seatPriceId: string;
  /** Days of free trial a company that has never had a plan gets. Zero for none. */
  trialDays: number;
}

export interface BillingDeps {
  db: Db;
  stripe: BillingStripe;
  config: BillingConfig;
  log: (message: string, detail?: unknown) => void;
}

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

// ---------------------------------------------------------------------------
// The Owner opens Checkout or the billing portal
// ---------------------------------------------------------------------------
interface Prepared {
  organization_id: string;
  name: string | null;
  customer_id: string | null;
  subscription_id: string | null;
  status: string;
  seats_wanted: number;
  trial_eligible: boolean;
}

/**
 * Returns a Stripe-hosted page for the company's plan: Checkout to start one (or start again after cancelling), the
 * billing portal to change the card, read invoices or cancel. Only the Owner may; the database says who that is.
 */
export async function billingSession(deps: BillingDeps, userId: string, input: unknown): Promise<HttpResult> {
  const asked = asObject(input);
  const org = asked?.organization_id;
  const action = asked?.action;
  if (typeof org !== "string" || !UUID.test(org) || (action !== undefined && action !== "checkout" && action !== "portal")) {
    return fail(400, "invalid_request");
  }
  if (!deps.config.seatPriceId) return fail(503, "billing_not_configured");
  const organizationId = org.toLowerCase();

  try {
    if (!(await deps.db.rpc<boolean>("billing_authorize", { p_user: userId, p_org: organizationId }))) {
      return fail(404, "not_found");
    }
    let prepared = await deps.db.rpc<Prepared>("billing_prepare", { p_user: userId, p_org: organizationId });

    let customer = prepared.customer_id;
    if (!customer) {
      const created = await deps.stripe.customers.create(
        { name: prepared.name ?? undefined, metadata: { organization_id: organizationId } },
        // One customer per company even if two taps race.
        { idempotencyKey: `billing-customer-${organizationId}` },
      );
      await deps.db.rpc("billing_save_customer", { p_org: organizationId, p_customer_id: created.id });
      // If another request saved a customer first, that one stays; use it.
      prepared = await deps.db.rpc<Prepared>("billing_prepare", { p_user: userId, p_org: organizationId });
      customer = prepared.customer_id ?? created.id;
    }

    const hasPlan = prepared.subscription_id !== null && prepared.status !== "none" && prepared.status !== "canceled";
    const kind = action ?? (hasPlan ? "portal" : "checkout");
    const returnUrl = `${deps.config.functionsBaseUrl}/billing-redirect?to=return`;

    if (kind === "portal") {
      if (!prepared.customer_id && !customer) return fail(409, "no_plan");
      const portal = await deps.stripe.billingPortal.sessions.create({ customer, return_url: returnUrl });
      return ok({ kind: "portal", url: portal.url });
    }

    if (hasPlan) return fail(409, "already_subscribed");
    const trial = prepared.trial_eligible && deps.config.trialDays > 0 ? { trial_period_days: deps.config.trialDays } : {};
    const session = await deps.stripe.checkout.sessions.create({
      mode: "subscription",
      customer,
      // The quantity is what the team needs now (never below the floor). The database worked it out.
      line_items: [{ price: deps.config.seatPriceId, quantity: prepared.seats_wanted }],
      subscription_data: { metadata: { organization_id: organizationId }, ...trial },
      metadata: { organization_id: organizationId },
      client_reference_id: organizationId,
      success_url: returnUrl,
      cancel_url: `${deps.config.functionsBaseUrl}/billing-redirect?to=cancel`,
    });
    if (!session.url) return fail(502, "stripe_error");
    return ok({ kind: "checkout", url: session.url });
  } catch (error) {
    if (asObject(error)?.type) {
      deps.log("stripe error", messageOf(error));
      return fail(502, "stripe_error");
    }
    if (/not_found/.test(messageOf(error))) return fail(404, "not_found");
    deps.log("database error", messageOf(error));
    return fail(500, "server_error");
  }
}

/** Stripe only sends people back to https addresses, so it returns them here and this hands them on to the app. */
export function billingRedirect(to: string | null, appScheme: string): HttpResult {
  if (to !== "return" && to !== "cancel") return fail(400, "invalid_request");
  const location = `${appScheme}://billing/${to}`;
  return {
    status: 302,
    headers: { Location: location, "Content-Type": "text/html; charset=utf-8" },
    body: `<!doctype html><meta charset="utf-8"><title>Returning to Slate Pro</title><p>Returning to Slate Pro… <a href="${location}">Tap here if nothing happens.</a></p>`,
  };
}

// ---------------------------------------------------------------------------
// Stripe's webhook: what really happened to a plan
// ---------------------------------------------------------------------------
/** Stripe has more statuses than the app has states. This folds them; null means "say nothing yet". */
export function planStatus(stripeStatus: unknown): "trialing" | "active" | "past_due" | "canceled" | null {
  switch (stripeStatus) {
    case "trialing":
      return "trialing";
    case "active":
      return "active";
    case "past_due":
    case "unpaid":
    case "paused":
      return "past_due";
    case "canceled":
    case "incomplete_expired":
      return "canceled";
    default:
      return null; // "incomplete": the first payment hasn't gone through, so there is no plan to record yet.
  }
}

const seconds = (value: unknown): string | null =>
  typeof value === "number" && Number.isFinite(value) ? new Date(value * 1000).toISOString() : null;

/** Records a subscription event. Returns whether it was one of ours (the others are for the payments code). */
export async function handleBillingEvent(deps: Pick<BillingDeps, "db" | "log">, event: StripeEvent): Promise<boolean> {
  if (
    event.type !== "customer.subscription.created" &&
    event.type !== "customer.subscription.updated" &&
    event.type !== "customer.subscription.deleted"
  ) {
    return false;
  }
  const object = event.data.object;
  const customer = typeof object?.customer === "string" ? object.customer : null;
  const subscription = typeof object?.id === "string" ? object.id : null;
  if (!customer || !subscription) return true;

  const status = event.type === "customer.subscription.deleted" ? "canceled" : planStatus(object.status);
  if (!status) return true;

  let org: string | null = typeof object.metadata?.organization_id === "string" ? object.metadata.organization_id : null;
  if (!org || !UUID.test(org)) {
    org = await deps.db.rpc<string | null>("billing_org_for_customer", { p_customer_id: customer });
  }
  if (!org) {
    deps.log("subscription for a customer we don't know", { customer, subscription });
    return true;
  }

  const quantity = object.items?.data?.[0]?.quantity;
  await deps.db.rpc("billing_record_subscription", {
    p_org: org.toLowerCase(),
    p_customer_id: customer,
    p_subscription_id: subscription,
    p_status: status,
    p_quantity: typeof quantity === "number" ? quantity : 0,
    p_period_end: seconds(object.current_period_end),
    p_trial_end: seconds(object.trial_end),
    p_cancel_at_period_end: object.cancel_at_period_end === true,
  });
  return true;
}

// ---------------------------------------------------------------------------
// Keeping Stripe's seat count in step with the team
// ---------------------------------------------------------------------------
interface DueRow {
  organization_id: string;
  subscription_id: string;
  seats_wanted: number;
  seats_billed: number;
  closed: boolean;
}

export interface SyncResult {
  updated: number;
  cancelled: number;
  failed: number;
}

/**
 * Pushes seat changes to Stripe, and ends the plans of companies that were closed. More seats are charged at once
 * (prorated). Fewer seats lower the next invoice and refund nothing for the rest of the period. A failure for one
 * company is logged and retried on the next run; it stops no one else.
 */
export async function syncSeats(deps: BillingDeps): Promise<SyncResult> {
  const result: SyncResult = { updated: 0, cancelled: 0, failed: 0 };
  const due = await deps.db.rpc<DueRow[]>("billing_sync_due");

  for (const row of due) {
    try {
      if (row.closed) {
        try {
          await deps.stripe.subscriptions.cancel(row.subscription_id);
        } catch (error) {
          // Already gone on Stripe's side is the outcome we wanted.
          if (!/no such subscription|resource_missing/i.test(messageOf(error))) throw error;
        }
        await deps.db.rpc("billing_sync_done", { p_org: row.organization_id, p_seats: 0, p_cancelled: true });
        result.cancelled += 1;
        continue;
      }

      const subscription = await deps.stripe.subscriptions.retrieve(row.subscription_id);
      const item = subscription.items.data[0];
      if (!item) {
        deps.log("subscription has no seat item", { organization: row.organization_id });
        result.failed += 1;
        continue;
      }
      await deps.stripe.subscriptionItems.update(
        item.id,
        {
          quantity: row.seats_wanted,
          proration_behavior: row.seats_wanted > row.seats_billed ? "create_prorations" : "none",
        },
        // The same change twice is one change.
        { idempotencyKey: `seats-${row.organization_id}-${row.seats_billed}-${row.seats_wanted}` },
      );
      await deps.db.rpc("billing_sync_done", { p_org: row.organization_id, p_seats: row.seats_wanted, p_cancelled: false });
      result.updated += 1;
    } catch (error) {
      deps.log("seat sync will be retried", { organization: row.organization_id, error: messageOf(error) });
      result.failed += 1;
    }
  }

  // Companies whose payment is overdue past the grace period become read only.
  await deps.db.rpc("billing_sweep");
  return result;
}

/** The scheduler calls this. Only the service role key or the cron secret may. */
export async function billingSyncRequest(
  request: { method: string; authorization: string | null },
  secrets: (string | undefined)[],
  deps: BillingDeps | null,
): Promise<HttpResult> {
  if (request.method !== "POST") return fail(405, "method_not_allowed");
  if (!isAuthorized(request.authorization, secrets)) return fail(401, "unauthorized");
  if (!deps) return fail(503, "billing_not_configured");
  return ok(await syncSeats(deps));
}
