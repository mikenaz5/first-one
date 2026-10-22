// Talking to Apple's push service (APNs) with a provider token (an ES256-signed JWT made from your .p8 key).
//
// The signing and the shape of each request are tested with Node (see ios/supabase/function-tests/push.test.ts),
// including checking the token's signature with the matching public key. What has never been exercised is the
// real network call to api.push.apple.com / api.sandbox.push.apple.com, which needs an Apple developer account.
//
// Only erasable TypeScript syntax is used so Node can run it directly.

import type { ApnsMessage, ApnsResult, ApnsSender } from "./push.ts";

/** The part of `fetch` this needs, so tests can stand in for the network. */
export type FetchLike = (
  url: string,
  init: { method: string; headers: Record<string, string>; body: string },
) => Promise<{ status: number; text(): Promise<string> }>;

export interface ApnsConfig {
  /** The contents of the AuthKey_XXXX.p8 file. Literal "\n" sequences (from a one-line secret) are accepted. */
  keyPem: string;
  /** The key's ID (the XXXX in the file name). */
  keyId: string;
  /** Your Apple developer Team ID. */
  teamId: string;
  /** The app's bundle identifier, e.g. com.example.slate. */
  topic: string;
}

export function base64url(input: Uint8Array | string): string {
  const bytes = typeof input === "string" ? new TextEncoder().encode(input) : input;
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/** A .p8 file is a PKCS#8 private key in PEM; this returns the raw bytes. */
export function pemToPkcs8(pem: string) {
  const body = pem
    .replace(/\\n/g, "\n")
    .replace(/-----BEGIN [A-Z ]+-----/, "")
    .replace(/-----END [A-Z ]+-----/, "")
    .replace(/\s+/g, "");
  if (!body) throw new Error("The APNs key is empty.");
  const binary = atob(body);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

export type SigningKey = Awaited<ReturnType<typeof crypto.subtle.importKey>>;

export function importApnsKey(pem: string): Promise<SigningKey> {
  return crypto.subtle.importKey("pkcs8", pemToPkcs8(pem), { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
}

/** The JWT Apple wants: header {alg, kid}, claims {iss, iat}, signed ES256 (raw r||s, which is what WebCrypto returns). */
export async function makeProviderToken(key: SigningKey, keyId: string, teamId: string, issuedAt: number): Promise<string> {
  const header = base64url(JSON.stringify({ alg: "ES256", kid: keyId }));
  const claims = base64url(JSON.stringify({ iss: teamId, iat: issuedAt }));
  const signature = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, new TextEncoder().encode(`${header}.${claims}`));
  return `${header}.${claims}.${base64url(new Uint8Array(signature))}`;
}

export function apnsUrl(environment: "sandbox" | "production", token: string): string {
  const host = environment === "sandbox" ? "api.sandbox.push.apple.com" : "api.push.apple.com";
  return `https://${host}/3/device/${token}`;
}

/** Apple throttles providers that mint new tokens too often (no more than one per 20 minutes) and rejects ones older
 * than an hour. Tokens here are issued on 30-minute boundaries and reused until the next one. */
export const TOKEN_WINDOW_SECONDS = 30 * 60;

export function createApnsSender(config: ApnsConfig, fetchImpl: FetchLike, now: () => Date = () => new Date()): ApnsSender {
  let key: SigningKey | null = null;
  let cached: { window: number; token: string } | null = null;

  async function providerToken(): Promise<string> {
    const seconds = Math.floor(now().getTime() / 1000);
    const window = Math.floor(seconds / TOKEN_WINDOW_SECONDS) * TOKEN_WINDOW_SECONDS;
    if (cached && cached.window === window) return cached.token;
    key ??= await importApnsKey(config.keyPem);
    cached = { window, token: await makeProviderToken(key, config.keyId, config.teamId, window) };
    return cached.token;
  }

  return {
    async send(message: ApnsMessage): Promise<ApnsResult> {
      let response: { status: number; text(): Promise<string> };
      try {
        const headers: Record<string, string> = {
          authorization: `bearer ${await providerToken()}`,
          "apns-topic": config.topic,
          "apns-push-type": "alert",
          "apns-priority": String(message.priority),
          "apns-expiration": String(message.expiration),
          "content-type": "application/json",
        };
        if (message.collapseId) headers["apns-collapse-id"] = message.collapseId;
        response = await fetchImpl(apnsUrl(message.environment, message.token), {
          method: "POST",
          headers,
          body: JSON.stringify(message.payload),
        });
      } catch (error) {
        return { ok: false, status: 0, reason: `NetworkError: ${error instanceof Error ? error.message : String(error)}` };
      }

      if (response.status === 200) return { ok: true };

      let reason = `HTTP ${response.status}`;
      try {
        const parsed = JSON.parse(await response.text());
        if (parsed && typeof parsed.reason === "string") reason = parsed.reason;
      } catch {
        // Apple always sends JSON for errors; if something in between didn't, the status is all there is.
      }
      // Our token went stale (the clock moved, or Apple's window differs): make a new one next time.
      if (reason === "ExpiredProviderToken" || reason === "InvalidProviderToken") cached = null;
      return { ok: false, status: response.status, reason };
    },
  };
}
