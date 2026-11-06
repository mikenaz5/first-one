// Checks that data really came from the App Store, using Apple's own library for the hard part: reading the certificate
// chain inside a signed message, checking each link back to Apple's root, and checking the signature. Nothing here
// implements that by hand, because a mistake in it would let anyone claim a plan they haven't paid for.
//
// What this adds around the library:
//   - It picks the Sandbox or the Production verifier by the environment the message says it is for (read before it is
//     trusted, only to choose; the library then insists the verified message agrees). TestFlight and App Review purchases
//     are Sandbox, so a live server needs both.
//   - Production needs the app's Apple id (the number on the App Store page, in App Store Connect under General, App
//     Information). Without it Production messages are refused with an AppleConfigError, and Sandbox still works.
//   - It insists on the app's bundle id, so a message about some other app is refused.
//   - Every failure of the library becomes an AppleVerifyError, so the handlers have one thing to catch.
//
// The library is passed in (`library`) so this file imports nothing and Node can test it with the real library and a
// made-up certificate chain. _shared/runtime.ts passes the real one, with Apple's real root (apple_roots.ts). That wiring
// has never been run on a live Supabase project.
import { AppleConfigError, AppleVerifyError } from "./apple_plan.ts";
import type { AppleNotification, AppleRenewalInfo, AppleTransaction, AppleVerifier } from "./apple_plan.ts";

/** The part of @apple/app-store-server-library this uses. */
export interface AppleLibrary {
  Environment: { SANDBOX: unknown; PRODUCTION: unknown };
  SignedDataVerifier: new (
    rootCertificates: Uint8Array[],
    enableOnlineChecks: boolean,
    environment: unknown,
    bundleId: string,
    appAppleId?: number,
  ) => {
    verifyAndDecodeTransaction(signed: string): Promise<AppleTransaction>;
    verifyAndDecodeRenewalInfo(signed: string): Promise<AppleRenewalInfo>;
    verifyAndDecodeNotification(signed: string): Promise<AppleNotification>;
  };
}

export interface AppleSignedConfig {
  bundleId: string;
  /** The app's Apple id, a number. Needed to verify Production messages. */
  appAppleId?: number | null;
  /** The DER bytes of every root certificate to trust. */
  roots: Uint8Array[];
  library: AppleLibrary;
}

type Kind = "transaction" | "renewal" | "notification";

function base64UrlToBytes(text: string): Uint8Array {
  const padded = text.replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(text.length / 4) * 4, "=");
  return Uint8Array.from(atob(padded), (c) => c.charCodeAt(0));
}

/** The environment a signed message says it is for, read WITHOUT trusting it. Only used to choose a verifier. */
export function peekEnvironment(signed: string, kind: Kind): "Sandbox" | "Production" {
  let payload: Record<string, unknown>;
  try {
    const part = signed.split(".")[1];
    payload = JSON.parse(new TextDecoder().decode(base64UrlToBytes(part ?? ""))) as Record<string, unknown>;
  } catch {
    throw new AppleVerifyError("the message can't be read");
  }
  const data = (typeof payload.data === "object" && payload.data !== null ? payload.data : null) as Record<string, unknown> | null;
  const environment = kind === "notification" ? data?.environment : payload.environment;
  if (environment === "Sandbox" || environment === "Production") return environment;
  throw new AppleVerifyError("the message is for neither Sandbox nor Production");
}

export function createAppleVerifier(config: AppleSignedConfig): AppleVerifier {
  const cache: Record<string, ReturnType<typeof build>> = {};

  function build(environment: "Sandbox" | "Production") {
    const { library } = config;
    if (environment === "Production") {
      if (!config.appAppleId) throw new AppleConfigError("APPLE_APP_ID is not set, so Production purchases can't be verified");
      return new library.SignedDataVerifier(config.roots, false, library.Environment.PRODUCTION, config.bundleId, config.appAppleId);
    }
    // Sandbox: the library asks for no app id.
    return new library.SignedDataVerifier(config.roots, false, library.Environment.SANDBOX, config.bundleId);
  }

  function forMessage(signed: string, kind: Kind) {
    const environment = peekEnvironment(signed, kind);
    return (cache[environment] ??= build(environment));
  }

  async function guarded<T>(work: () => Promise<T>): Promise<T> {
    try {
      return await work();
    } catch (error) {
      if (error instanceof AppleConfigError || error instanceof AppleVerifyError) throw error;
      const status = (error as { status?: unknown })?.status;
      throw new AppleVerifyError(`Apple's data did not verify${status !== undefined ? ` (${String(status)})` : ""}`);
    }
  }

  return {
    transaction: (signed) => guarded(() => forMessage(signed, "transaction").verifyAndDecodeTransaction(signed)),
    renewal: (signed) => guarded(() => forMessage(signed, "renewal").verifyAndDecodeRenewalInfo(signed)),
    notification: (signed) => guarded(() => forMessage(signed, "notification").verifyAndDecodeNotification(signed)),
  };
}
