// Stripe Connect accounts, through Stripe's Accounts v2 API.
//
// Creators are "Standard" connected accounts in the old vocabulary: they own their Stripe account and its Dashboard, they
// pay Stripe's fees themselves and Stripe covers negative balances, and the platform makes DIRECT CHARGES on their account.
// In Accounts v2 that is three settings, written once here and nowhere else:
//
//     dashboard: "full"
//     defaults.responsibilities.fees_collector: "stripe"
//     defaults.responsibilities.losses_collector: "stripe"
//     configuration.merchant.capabilities.card_payments.requested: true     (the merchant configuration is what lets the
//                                                                            account be the merchant of record)
//
// Whether such an account can take cards is `configuration.merchant.capabilities.card_payments.status === "active"`. The old
// `charges_enabled` / `payouts_enabled` fields are not used for accounts made this way.
//
// This is plain `fetch` rather than the Stripe SDK on purpose: it keeps the exact requests in one small, testable file and
// does not depend on which SDK version the Edge Functions import. v2 endpoints take and return JSON.
//
// THIS HAS NEVER BEEN RUN AGAINST STRIPE. The request and response shapes follow Stripe's Accounts v2 documentation as it was
// understood when this was written; try creating an account in a Stripe test-mode sandbox before relying on it.
//
// Only erasable TypeScript syntax is used (no enums or parameter properties) so Node can run it directly.

/** The default Stripe API version these calls are made with; STRIPE_API_VERSION overrides it. */
export const DEFAULT_STRIPE_API_VERSION = "2026-10-28.endive";

/** What this uses of `fetch`, so tests can pass a fake. */
export type FetchLike = (
  url: string,
  init: { method: string; headers: Record<string, string>; body?: string },
) => Promise<{ ok: boolean; status: number; text(): Promise<string> }>;

/** A Stripe account as the rest of the code needs to see it. */
export interface ConnectedAccount {
  id: string;
  /** configuration.merchant.capabilities.card_payments.status ("active", "pending", "restricted", ...), or null if absent. */
  cardPayments: string | null;
  /** configuration.merchant.capabilities.stripe_balance.payouts.status, or null if absent. */
  payouts: string | null;
}

/** The three calls the app's backend makes to Stripe about connected accounts. */
export interface ConnectApi {
  createAccount(input: {
    country: string;
    currency: string;
    metadata: Record<string, string>;
    idempotencyKey?: string;
  }): Promise<{ id: string }>;
  getAccount(id: string): Promise<ConnectedAccount>;
  createOnboardingLink(input: { account: string; refreshUrl: string; returnUrl: string }): Promise<{ url: string }>;
}

/** A failed Stripe call. `type` is set, so callers treat it like an error from the Stripe SDK. */
export class StripeApiError extends Error {
  type: string;
  status: number;
  code: string | null;
  constructor(status: number, message: string, code: string | null) {
    super(message);
    this.name = "StripeApiError";
    this.status = status;
    this.code = code;
    // 4xx (other than "slow down") means the request itself was wrong and will never work as it is.
    this.type = status >= 400 && status < 500 && status !== 429 ? "StripeInvalidRequestError" : "StripeAPIError";
  }
}

// ---------------------------------------------------------------------------
// The requests, as plain data
// ---------------------------------------------------------------------------
export function createAccountBody(input: { country: string; currency: string; metadata: Record<string, string> }): Record<string, unknown> {
  return {
    identity: { country: input.country.toLowerCase() },
    dashboard: "full",
    defaults: {
      currency: input.currency.toLowerCase(),
      responsibilities: { fees_collector: "stripe", losses_collector: "stripe" },
    },
    configuration: { merchant: { capabilities: { card_payments: { requested: true } } } },
    metadata: input.metadata,
  };
}

export function accountLinkBody(input: { account: string; refreshUrl: string; returnUrl: string }): Record<string, unknown> {
  return {
    account: input.account,
    use_case: {
      type: "account_onboarding",
      account_onboarding: {
        configurations: ["merchant"],
        refresh_url: input.refreshUrl,
        return_url: input.returnUrl,
      },
    },
  };
}

// ---------------------------------------------------------------------------
// The answers
// ---------------------------------------------------------------------------
function asObject(value: unknown): Record<string, unknown> | null {
  return typeof value === "object" && value !== null && !Array.isArray(value) ? (value as Record<string, unknown>) : null;
}

function statusOf(value: unknown): string | null {
  const status = asObject(value)?.status;
  return typeof status === "string" ? status : null;
}

/** Reads an account object. Throws if it has no id. */
export function parseAccount(json: unknown): ConnectedAccount {
  const account = asObject(json);
  const id = account?.id;
  if (typeof id !== "string" || !id) throw new StripeApiError(502, "Stripe's answer had no account id.", null);
  const capabilities = asObject(asObject(asObject(account?.configuration)?.merchant)?.capabilities);
  return {
    id,
    cardPayments: statusOf(capabilities?.card_payments),
    payouts: statusOf(asObject(capabilities?.stripe_balance)?.payouts),
  };
}

// ---------------------------------------------------------------------------
// The calls
// ---------------------------------------------------------------------------
const BASE = "https://api.stripe.com";

export function makeConnectApi(options: { secretKey: string; apiVersion?: string; fetchFn: FetchLike }): ConnectApi {
  const version = options.apiVersion || DEFAULT_STRIPE_API_VERSION;

  async function call(method: string, path: string, body?: Record<string, unknown>, idempotencyKey?: string): Promise<unknown> {
    const headers: Record<string, string> = {
      Authorization: `Bearer ${options.secretKey}`,
      "Stripe-Version": version,
    };
    if (body) headers["Content-Type"] = "application/json";
    if (idempotencyKey) headers["Idempotency-Key"] = idempotencyKey;
    const response = await options.fetchFn(`${BASE}${path}`, { method, headers, body: body ? JSON.stringify(body) : undefined });
    const text = await response.text();
    let json: unknown = null;
    try {
      json = text ? JSON.parse(text) : null;
    } catch {
      json = null;
    }
    if (!response.ok) {
      const error = asObject(asObject(json)?.error);
      const message = typeof error?.message === "string" ? error.message : `Stripe answered ${response.status}.`;
      const code = typeof error?.code === "string" ? error.code : null;
      throw new StripeApiError(response.status, message, code);
    }
    return json;
  }

  return {
    async createAccount(input) {
      const created = parseAccount(await call("POST", "/v2/core/accounts", createAccountBody(input), input.idempotencyKey));
      return { id: created.id };
    },
    async getAccount(id) {
      return parseAccount(await call("GET", `/v2/core/accounts/${encodeURIComponent(id)}?include[0]=configuration.merchant`));
    },
    async createOnboardingLink(input) {
      const answer = asObject(await call("POST", "/v2/core/account_links", accountLinkBody(input)));
      const url = answer?.url;
      if (typeof url !== "string" || !url.startsWith("https://")) throw new StripeApiError(502, "Stripe's answer had no onboarding link.", null);
      return { url };
    },
  };
}
