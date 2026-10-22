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
// Supabase provides SUPABASE_URL, SUPABASE_ANON_KEY and SUPABASE_SERVICE_ROLE_KEY itself.

import Stripe from "npm:stripe@17";
import { createClient } from "npm:@supabase/supabase-js@2";
import { DbError } from "./payments.ts";
import type { Deps, HttpResult } from "./payments.ts";

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
