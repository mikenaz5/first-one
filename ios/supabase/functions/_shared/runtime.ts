// Connects the handlers in payments.ts to the real world: the Stripe SDK and the Supabase client.
//
// This is deliberately thin. It has never been run against live Stripe or Supabase, so it is kept to plain
// adapters, and everything with logic in it is in payments.ts, where it is tested.
//
// Secrets this needs (set with `supabase secrets set`):
//   STRIPE_SECRET_KEY       sk_test_… or sk_live_…
//   STRIPE_WEBHOOK_SECRET   whsec_… from the webhook endpoint you add in the Stripe dashboard
//   PLATFORM_FEE_BPS        optional, defaults to 0 (the platform takes nothing)
//   APP_URL_SCHEME          optional, defaults to "slate"
// For seat billing (billing-session, billing-sync):
//   STRIPE_SEAT_PRICE_ID    the id of the Stripe Price for one seat for one month (price_…); billing is off without it
//   BILLING_TRIAL_DAYS      optional, free-trial days for a company's first plan, defaults to 14 (0 for none)
// For push notifications (send-push):
//   APNS_KEY_P8             the contents of the AuthKey_XXXX.p8 file from your Apple developer account
//   APNS_KEY_ID             that key's ID
//   APNS_TEAM_ID            your Apple developer Team ID
//   APNS_TOPIC              the app's bundle identifier, e.g. com.example.slate
//   PUSH_CRON_SECRET        optional: a long random secret the scheduler can send instead of the service role key
// Supabase provides SUPABASE_URL, SUPABASE_ANON_KEY and SUPABASE_SERVICE_ROLE_KEY itself.

import Stripe from "npm:stripe@17";
import { createClient } from "npm:@supabase/supabase-js@2";
import { DbError } from "./payments.ts";
import type { Db, Deps, HttpResult } from "./payments.ts";
import { createApnsSender } from "./apns.ts";
import type { BillingDeps } from "./billing.ts";
import type { CardDeps } from "./cards.ts";
import type { PushDeps } from "./push.ts";

let cached: Deps | null = null;

export function makeDeps(): Deps {
  if (cached) return cached;

  const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY")!, { httpClient: Stripe.createFetchHttpClient() });
  const cryptoProvider = Stripe.createSubtleCryptoProvider();
  const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false },
  });

  cached = {
    db: {
      async rpc(fn, args) {
        const { data, error } = await admin.rpc(fn, args ?? {});
        if (error) throw new DbError(`${error.message} ${error.code ?? ""} ${error.details ?? ""}`);
        return data;
      },
    },
    stripe: {
      paymentIntents: {
        create: (params, options) => stripe.paymentIntents.create(params as never, options),
        retrieve: (id) => stripe.paymentIntents.retrieve(id),
      },
      refunds: { create: (params, options) => stripe.refunds.create(params as never, options) },
      accounts: {
        create: (params, options) => stripe.accounts.create(params as never, options),
        retrieve: (id) => stripe.accounts.retrieve(id),
      },
      accountLinks: { create: (params) => stripe.accountLinks.create(params as never) },
      webhooks: {
        constructEventAsync: (payload, signature, secret) =>
          stripe.webhooks.constructEventAsync(payload, signature, secret, undefined, cryptoProvider) as never,
      },
    },
    config: {
      platformFeeBps: Number(Deno.env.get("PLATFORM_FEE_BPS") ?? "0") || 0,
      functionsBaseUrl: `${Deno.env.get("SUPABASE_URL")}/functions/v1`,
      webhookSecret: Deno.env.get("STRIPE_WEBHOOK_SECRET") ?? "",
      appScheme: Deno.env.get("APP_URL_SCHEME") ?? "slate",
    },
    log: (message, detail) => console.error(message, detail ?? ""),
  };
  return cached;
}

/** Everything the billing functions need, or null when no seat price is configured. */
export function makeBillingDeps(): BillingDeps | null {
  const seatPriceId = Deno.env.get("STRIPE_SEAT_PRICE_ID");
  if (!seatPriceId) return null;
  const base = makeDeps();
  const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY")!, { httpClient: Stripe.createFetchHttpClient() });
  const trial = Number(Deno.env.get("BILLING_TRIAL_DAYS") ?? "14");
  return {
    db: base.db,
    stripe: {
      customers: { create: (params, options) => stripe.customers.create(params as never, options) },
      checkout: { sessions: { create: (params, options) => stripe.checkout.sessions.create(params as never, options) } },
      billingPortal: { sessions: { create: (params) => stripe.billingPortal.sessions.create(params as never) } },
      subscriptions: {
        retrieve: (id) => stripe.subscriptions.retrieve(id) as never,
        cancel: (id) => stripe.subscriptions.cancel(id),
      },
      subscriptionItems: { update: (id, params, options) => stripe.subscriptionItems.update(id, params as never, options) },
    },
    config: {
      functionsBaseUrl: base.config.functionsBaseUrl,
      seatPriceId,
      trialDays: Number.isFinite(trial) && trial > 0 ? Math.floor(trial) : 0,
    },
    log: base.log,
  };
}

/** Everything the card functions need. */
export function makeCardDeps(): CardDeps {
  const base = makeDeps();
  const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY")!, { httpClient: Stripe.createFetchHttpClient() });
  return {
    db: base.db,
    stripe: {
      customers: {
        create: (params, options) => stripe.customers.create(params as never, options),
        del: (id) => stripe.customers.del(id),
      },
      checkout: { sessions: { create: (params, options) => stripe.checkout.sessions.create(params as never, options) } },
      paymentMethods: {
        list: (params) => stripe.paymentMethods.list(params as never) as never,
        detach: (id) => stripe.paymentMethods.detach(id),
      },
      paymentIntents: {
        create: (params, options) => stripe.paymentIntents.create(params as never, options),
        retrieve: (id) => stripe.paymentIntents.retrieve(id),
        cancel: (id) => stripe.paymentIntents.cancel(id),
      },
    },
    config: { platformFeeBps: base.config.platformFeeBps, functionsBaseUrl: base.config.functionsBaseUrl },
    log: base.log,
  };
}

/** The signed-in person, from their own JWT. Never trust a user id sent in a request body. */
export async function userIdFrom(request: Request): Promise<string | null> {
  const authorization = request.headers.get("Authorization");
  if (!authorization) return null;
  const asUser = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: authorization } },
    auth: { persistSession: false },
  });
  const { data, error } = await asUser.auth.getUser();
  return error || !data.user ? null : data.user.id;
}

export function respond(result: HttpResult): Response {
  const body = typeof result.body === "string" ? result.body : JSON.stringify(result.body);
  return new Response(body, {
    status: result.status,
    headers: { "Content-Type": "application/json", ...result.headers },
  });
}

export const unauthorized = (): Response => respond({ status: 401, body: { error: "unauthorized" } });
export const notAllowed = (): Response => respond({ status: 405, body: { error: "method_not_allowed" } });

function adminDb(): Db {
  const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false },
  });
  return {
    async rpc(fn, args) {
      const { data, error } = await admin.rpc(fn, args ?? {});
      if (error) throw new DbError(`${error.message} ${error.code ?? ""} ${error.details ?? ""}`);
      return data;
    },
  };
}

/** Everything send-push needs, or null when APNs isn't set up (the function then answers 503 and touches nothing). */
export function makePushDeps(): PushDeps | null {
  const keyPem = Deno.env.get("APNS_KEY_P8");
  const keyId = Deno.env.get("APNS_KEY_ID");
  const teamId = Deno.env.get("APNS_TEAM_ID");
  const topic = Deno.env.get("APNS_TOPIC");
  if (!keyPem || !keyId || !teamId || !topic) return null;
  return {
    db: adminDb(),
    // Deno's fetch speaks HTTP/2 to Apple, which APNs requires.
    apns: createApnsSender({ keyPem, keyId, teamId, topic }, (url, init) => fetch(url, init)),
    now: () => new Date(),
    log: (message, detail) => console.error(message, detail ?? ""),
  };
}

/** Who may call send-push: the service role key, or PUSH_CRON_SECRET. */
export function pushSecrets(): (string | undefined)[] {
  return [Deno.env.get("SUPABASE_SERVICE_ROLE_KEY"), Deno.env.get("PUSH_CRON_SECRET")];
}
