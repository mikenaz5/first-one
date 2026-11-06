import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { describe, it } from "node:test";
import { Environment, SignedDataVerifier } from "@apple/app-store-server-library";
import { AppleConfigError, AppleVerifyError } from "../functions/_shared/apple_plan.ts";
import { APPLE_ROOT_CA_G3_BASE64, appleRootCertificates } from "../functions/_shared/apple_roots.ts";
import { createAppleVerifier, peekEnvironment } from "../functions/_shared/apple_signed.ts";
import type { AppleLibrary } from "../functions/_shared/apple_signed.ts";
import { makeChain, signJws } from "./apple_test_support.ts";

const BUNDLE = "com.slateproapp.app";
const ORG = "bbbbbbbb-1111-4222-8333-444444444444";
const library = { Environment, SignedDataVerifier } as unknown as AppleLibrary;

const chain = makeChain("Test");
const stranger = makeChain("Somebody Else");

function transaction(extra: Record<string, unknown> = {}) {
  return {
    bundleId: BUNDLE,
    productId: "com.slateproapp.app.company.team5",
    originalTransactionId: "1000000000000001",
    transactionId: "1000000000000001",
    type: "Auto-Renewable Subscription",
    environment: "Sandbox",
    appAccountToken: ORG,
    purchaseDate: Date.now(),
    expiresDate: Date.now() + 7 * 86_400_000,
    signedDate: Date.now(),
    ...extra,
  };
}

function verifier(options: { appAppleId?: number | null; roots?: Uint8Array[] } = {}) {
  return createAppleVerifier({ bundleId: BUNDLE, appAppleId: options.appAppleId ?? null, roots: options.roots ?? [chain.rootDer], library });
}

describe("Apple's root certificate", () => {
  it("is the one Apple publishes", () => {
    const der = Buffer.from(APPLE_ROOT_CA_G3_BASE64, "base64");
    assert.equal(
      createHash("sha256").update(der).digest("hex").toUpperCase(),
      "63343ABFB89A6A03EBB57E9B3F5FA7BE7C4F5C756F3017B3A8C488C3653E9179",
    );
    assert.equal(appleRootCertificates().length, 1);
    assert.deepEqual([...appleRootCertificates()[0]], [...der]);
  });
});

describe("reading which environment a message is for", () => {
  it("reads a transaction, renewal info and a notification", () => {
    assert.equal(peekEnvironment(signJws(chain, { environment: "Sandbox" }), "transaction"), "Sandbox");
    assert.equal(peekEnvironment(signJws(chain, { environment: "Production" }), "renewal"), "Production");
    assert.equal(peekEnvironment(signJws(chain, { data: { environment: "Production" } }), "notification"), "Production");
  });
  it("refuses anything else", () => {
    assert.throws(() => peekEnvironment(signJws(chain, { environment: "Xcode" }), "transaction"), AppleVerifyError);
    assert.throws(() => peekEnvironment("not a message", "transaction"), AppleVerifyError);
    assert.throws(() => peekEnvironment(signJws(chain, {}), "notification"), AppleVerifyError);
  });
});

describe("checking Apple's signature with Apple's own library", () => {
  it("accepts a transaction signed through a chain that leads to a trusted root", async () => {
    const got = await verifier().transaction(signJws(chain, transaction()));
    assert.equal(got.productId, "com.slateproapp.app.company.team5");
    assert.equal(got.appAccountToken, ORG);
    assert.equal(got.environment, "Sandbox");
  });

  it("accepts renewal information the same way", async () => {
    const got = await verifier().renewal(
      signJws(chain, { environment: "Sandbox", originalTransactionId: "1000000000000001", autoRenewStatus: 0, signedDate: Date.now() }),
    );
    assert.equal(got.autoRenewStatus, 0);
  });

  it("accepts a notification, and its transaction inside it", async () => {
    const inner = signJws(chain, transaction());
    const outer = signJws(chain, {
      notificationType: "SUBSCRIBED",
      subtype: "INITIAL_BUY",
      notificationUUID: "00000000-0000-4000-8000-000000000001",
      signedDate: Date.now(),
      version: "2.0",
      data: { environment: "Sandbox", bundleId: BUNDLE, signedTransactionInfo: inner },
    });
    const v = verifier();
    const note = await v.notification(outer);
    assert.equal(note.notificationType, "SUBSCRIBED");
    assert.equal((await v.transaction(note.data!.signedTransactionInfo!)).originalTransactionId, "1000000000000001");
  });

  it("refuses a chain that doesn't lead to a trusted root", async () => {
    await assert.rejects(verifier().transaction(signJws(stranger, transaction())), AppleVerifyError);
  });

  it("refuses a message whose contents were changed after it was signed", async () => {
    const [header, , signature] = signJws(chain, transaction()).split(".");
    const forged = Buffer.from(JSON.stringify(transaction({ appAccountToken: "cccccccc-1111-4222-8333-444444444444" }))).toString("base64url");
    await assert.rejects(verifier().transaction(`${header}.${forged}.${signature}`), AppleVerifyError);
  });

  it("refuses a message signed by someone who only has their own key", async () => {
    const real = signJws(chain, transaction()).split(".");
    const impostor = signJws(stranger, transaction()).split(".");
    await assert.rejects(verifier().transaction(`${real[0]}.${real[1]}.${impostor[2]}`), AppleVerifyError);
  });

  it("refuses a chain with a certificate missing", async () => {
    await assert.rejects(verifier().transaction(signJws(chain, transaction(), { x5c: chain.x5c.slice(0, 2) })), AppleVerifyError);
  });

  it("refuses another app's purchase", async () => {
    await assert.rejects(verifier().transaction(signJws(chain, transaction({ bundleId: "com.example.other" }))), AppleVerifyError);
  });

  it("refuses unsigned or garbled input", async () => {
    await assert.rejects(verifier().transaction("a.b.c"), AppleVerifyError);
    await assert.rejects(verifier().transaction(""), AppleVerifyError);
    await assert.rejects(verifier().notification("{}"), AppleVerifyError);
  });

  it("refuses a message for an environment that isn't Sandbox or Production", async () => {
    await assert.rejects(verifier().transaction(signJws(chain, transaction({ environment: "Xcode" }))), AppleVerifyError);
  });
});

describe("Production needs the app's Apple id", () => {
  it("says so (a configuration problem, not a bad message) when it is missing", async () => {
    await assert.rejects(verifier().transaction(signJws(chain, transaction({ environment: "Production" }))), AppleConfigError);
  });

  it("verifies a Production transaction once it is set, and still checks the notification's app id", async () => {
    const v = verifier({ appAppleId: 1234567890 });
    assert.equal((await v.transaction(signJws(chain, transaction({ environment: "Production" })))).environment, "Production");
    const note = (appAppleId: number) =>
      signJws(chain, {
        notificationType: "DID_RENEW",
        notificationUUID: "00000000-0000-4000-8000-000000000002",
        signedDate: Date.now(),
        version: "2.0",
        data: { environment: "Production", bundleId: BUNDLE, appAppleId },
      });
    assert.equal((await v.notification(note(1234567890))).notificationType, "DID_RENEW");
    await assert.rejects(v.notification(note(999)), AppleVerifyError);
  });

  it("keeps Sandbox working without it", async () => {
    assert.equal((await verifier().transaction(signJws(chain, transaction()))).environment, "Sandbox");
  });
});
