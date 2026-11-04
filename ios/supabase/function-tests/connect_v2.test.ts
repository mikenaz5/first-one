import assert from "node:assert/strict";
import { describe, it } from "node:test";
import {
  accountLinkBody,
  createAccountBody,
  DEFAULT_STRIPE_API_VERSION,
  makeConnectApi,
  parseAccount,
  StripeApiError,
} from "../functions/_shared/connect_v2.ts";
import type { FetchLike } from "../functions/_shared/connect_v2.ts";

interface Sent {
  url: string;
  method: string;
  headers: Record<string, string>;
  body: unknown;
}

/** A fake `fetch` that records what was sent and answers with `reply` (a status and a JSON body). */
function fakeFetch(reply: { status?: number; json?: unknown; text?: string } = {}): { fetchFn: FetchLike; sent: Sent[] } {
  const sent: Sent[] = [];
  const fetchFn: FetchLike = async (url, init) => {
    sent.push({ url, method: init.method, headers: init.headers, body: init.body ? JSON.parse(init.body) : undefined });
    const status = reply.status ?? 200;
    return { ok: status >= 200 && status < 300, status, text: async () => reply.text ?? JSON.stringify(reply.json ?? { id: "acct_new" }) };
  };
  return { fetchFn, sent };
}

describe("an account made for direct charges", () => {
  it("is a Standard-style account: full Dashboard, Stripe collects fees and covers losses, and it is a merchant that takes cards", () => {
    const body = createAccountBody({ country: "US", currency: "USD", metadata: { user_id: "u1" } });
    assert.equal(body.dashboard, "full");
    assert.deepEqual((body.defaults as Record<string, unknown>).responsibilities, { fees_collector: "stripe", losses_collector: "stripe" });
    assert.deepEqual(body.configuration, { merchant: { capabilities: { card_payments: { requested: true } } } });
    assert.deepEqual(body.identity, { country: "us" });
    assert.equal((body.defaults as Record<string, unknown>).currency, "usd");
    assert.deepEqual(body.metadata, { user_id: "u1" });
  });

  it("is not made the old way", () => {
    const text = JSON.stringify(createAccountBody({ country: "us", currency: "usd", metadata: {} }));
    for (const old of ["express", "standard", "\"type\"", "transfers", "recipient", "application"]) {
      assert.equal(text.includes(old), false, old);
    }
  });
});

describe("makeConnectApi", () => {
  it("creates an account with a JSON body, the key, the version and an idempotency key", async () => {
    const { fetchFn, sent } = fakeFetch();
    const api = makeConnectApi({ secretKey: "sk_test_x", fetchFn });
    const created = await api.createAccount({ country: "us", currency: "usd", metadata: { user_id: "u1" }, idempotencyKey: "connect-account-u1" });
    assert.deepEqual(created, { id: "acct_new" });
    assert.equal(sent.length, 1);
    assert.equal(sent[0].url, "https://api.stripe.com/v2/core/accounts");
    assert.equal(sent[0].method, "POST");
    assert.equal(sent[0].headers.Authorization, "Bearer sk_test_x");
    assert.equal(sent[0].headers["Stripe-Version"], DEFAULT_STRIPE_API_VERSION);
    assert.equal(sent[0].headers["Content-Type"], "application/json");
    assert.equal(sent[0].headers["Idempotency-Key"], "connect-account-u1");
    assert.deepEqual(sent[0].body, createAccountBody({ country: "us", currency: "usd", metadata: { user_id: "u1" } }));
  });

  it("uses the API version it is given", async () => {
    const { fetchFn, sent } = fakeFetch();
    await makeConnectApi({ secretKey: "sk", apiVersion: "2099-01-01.test", fetchFn }).createAccount({ country: "us", currency: "usd", metadata: {} });
    assert.equal(sent[0].headers["Stripe-Version"], "2099-01-01.test");
  });

  it("reads whether card payments are active from the merchant configuration", async () => {
    const answers: [unknown, string | null, string | null][] = [
      [{ id: "acct_1", configuration: { merchant: { capabilities: { card_payments: { status: "active" } } } } }, "active", null],
      [{ id: "acct_1", configuration: { merchant: { capabilities: { card_payments: { status: "pending" }, stripe_balance: { payouts: { status: "active" } } } } } }, "pending", "active"],
      [{ id: "acct_1", configuration: { merchant: { capabilities: {} } } }, null, null],
      [{ id: "acct_1" }, null, null],
    ];
    for (const [json, cardPayments, payouts] of answers) {
      const { fetchFn, sent } = fakeFetch({ json });
      const account = await makeConnectApi({ secretKey: "sk", fetchFn }).getAccount("acct_1");
      assert.deepEqual(account, { id: "acct_1", cardPayments, payouts }, JSON.stringify(json));
      assert.equal(sent[0].method, "GET");
      assert.equal(sent[0].url, "https://api.stripe.com/v2/core/accounts/acct_1?include[0]=configuration.merchant");
      assert.equal(sent[0].body, undefined);
      assert.equal("Content-Type" in sent[0].headers, false);
    }
  });

  it("never uses the old charges_enabled or payouts_enabled fields", () => {
    const account = parseAccount({ id: "acct_1", charges_enabled: true, payouts_enabled: true });
    assert.deepEqual(account, { id: "acct_1", cardPayments: null, payouts: null });
  });

  it("makes an onboarding link for the merchant configuration", async () => {
    const { fetchFn, sent } = fakeFetch({ json: { url: "https://connect.stripe.com/setup/abc", expires_at: "2026-11-05T00:00:00Z" } });
    const link = await makeConnectApi({ secretKey: "sk", fetchFn }).createOnboardingLink({
      account: "acct_1", refreshUrl: "https://x.test/refresh", returnUrl: "https://x.test/return",
    });
    assert.deepEqual(link, { url: "https://connect.stripe.com/setup/abc" });
    assert.equal(sent[0].url, "https://api.stripe.com/v2/core/account_links");
    assert.deepEqual(sent[0].body, accountLinkBody({ account: "acct_1", refreshUrl: "https://x.test/refresh", returnUrl: "https://x.test/return" }));
    assert.deepEqual(sent[0].body, {
      account: "acct_1",
      use_case: {
        type: "account_onboarding",
        account_onboarding: { configurations: ["merchant"], refresh_url: "https://x.test/refresh", return_url: "https://x.test/return" },
      },
    });
  });

  it("refuses a link that isn't https", async () => {
    for (const url of ["http://evil.test", "javascript:alert(1)", "", 5, null]) {
      const { fetchFn } = fakeFetch({ json: { url } });
      await assert.rejects(
        makeConnectApi({ secretKey: "sk", fetchFn }).createOnboardingLink({ account: "acct_1", refreshUrl: "https://a.test", returnUrl: "https://b.test" }),
        StripeApiError,
        String(url),
      );
    }
  });

  it("turns Stripe's errors into errors that say what kind they are, without the key", async () => {
    const cases: [number, string][] = [[400, "StripeInvalidRequestError"], [401, "StripeInvalidRequestError"], [404, "StripeInvalidRequestError"], [429, "StripeAPIError"], [500, "StripeAPIError"], [503, "StripeAPIError"]];
    for (const [status, type] of cases) {
      const { fetchFn } = fakeFetch({ status, json: { error: { message: "Nope.", code: "some_code" } } });
      await assert.rejects(
        makeConnectApi({ secretKey: "sk_live_SECRET", fetchFn }).getAccount("acct_1"),
        (error: unknown) => {
          assert.ok(error instanceof StripeApiError);
          assert.equal((error as StripeApiError).type, type, String(status));
          assert.equal((error as StripeApiError).code, "some_code");
          assert.equal(String((error as Error).message).includes("sk_live_SECRET"), false);
          return true;
        },
      );
    }
  });

  it("copes with an answer that isn't JSON", async () => {
    await assert.rejects(makeConnectApi({ secretKey: "sk", fetchFn: fakeFetch({ status: 502, text: "<html>bad gateway</html>" }).fetchFn }).getAccount("acct_1"), StripeApiError);
    await assert.rejects(makeConnectApi({ secretKey: "sk", fetchFn: fakeFetch({ text: "not json" }).fetchFn }).getAccount("acct_1"), StripeApiError);
  });

  it("puts an account id in the address safely", async () => {
    const { fetchFn, sent } = fakeFetch({ json: { id: "acct_1" } });
    await makeConnectApi({ secretKey: "sk", fetchFn }).getAccount("acct_1/../../x?y=1");
    assert.equal(sent[0].url.startsWith("https://api.stripe.com/v2/core/accounts/acct_1%2F"), true, sent[0].url);
  });
});
