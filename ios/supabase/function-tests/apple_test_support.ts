// Makes a certificate chain that looks like Apple's (a root, an intermediate and a signing certificate, with the two marks
// Apple puts on the last two), and signs messages with it the way the App Store signs them. It uses the `openssl` that every
// Mac, Linux box and GitHub runner has. The root is the test's own, so nothing here can be mistaken for Apple's real one.
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { sign as cryptoSign } from "node:crypto";

export interface TestChain {
  rootDer: Uint8Array;
  /** Base64 of each certificate's DER, leaf first, as the x5c header wants them. */
  x5c: string[];
  leafKeyPem: string;
}

function openssl(args: string[], cwd: string) {
  execFileSync("openssl", args, { cwd, stdio: ["ignore", "ignore", "pipe"] });
}

function der(pemPath: string): Uint8Array {
  const body = readFileSync(pemPath, "utf8").replace(/-----[^-]+-----/g, "").replace(/\s+/g, "");
  return Uint8Array.from(Buffer.from(body, "base64"));
}

export function makeChain(name = "Test"): TestChain {
  const dir = mkdtempSync(join(tmpdir(), "apple-chain-"));
  const days = "3650";

  openssl(["ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", "root.key"], dir);
  openssl(["req", "-x509", "-new", "-key", "root.key", "-sha256", "-days", days, "-subj", `/CN=${name} Root CA`, "-out", "root.pem",
    "-addext", "basicConstraints=critical,CA:TRUE", "-addext", "keyUsage=critical,keyCertSign"], dir);

  openssl(["ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", "int.key"], dir);
  openssl(["req", "-new", "-key", "int.key", "-subj", `/CN=${name} Intermediate`, "-out", "int.csr"], dir);
  // Apple marks its intermediate with 1.2.840.113635.100.6.2.1 and its signing certificate with 1.2.840.113635.100.6.11.1.
  writeFileSync(join(dir, "int.ext"), "basicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign\n1.2.840.113635.100.6.2.1=ASN1:NULL\n");
  openssl(["x509", "-req", "-in", "int.csr", "-CA", "root.pem", "-CAkey", "root.key", "-CAcreateserial", "-days", days, "-sha256",
    "-extfile", "int.ext", "-out", "int.pem"], dir);

  openssl(["ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", "leaf.key"], dir);
  openssl(["req", "-new", "-key", "leaf.key", "-subj", `/CN=${name} Signing`, "-out", "leaf.csr"], dir);
  writeFileSync(join(dir, "leaf.ext"), "basicConstraints=CA:FALSE\nkeyUsage=digitalSignature\n1.2.840.113635.100.6.11.1=ASN1:NULL\n");
  openssl(["x509", "-req", "-in", "leaf.csr", "-CA", "int.pem", "-CAkey", "int.key", "-CAcreateserial", "-days", days, "-sha256",
    "-extfile", "leaf.ext", "-out", "leaf.pem"], dir);

  const rootDer = der(join(dir, "root.pem"));
  return {
    rootDer,
    x5c: [der(join(dir, "leaf.pem")), der(join(dir, "int.pem")), rootDer].map((bytes) => Buffer.from(bytes).toString("base64")),
    leafKeyPem: readFileSync(join(dir, "leaf.key"), "utf8"),
  };
}

const b64url = (input: Buffer | string) => Buffer.from(input).toString("base64url");

/** A signed message in the shape the App Store sends (an ES256 JWS with the certificate chain in its header). */
export function signJws(chain: TestChain, payload: Record<string, unknown>, options: { x5c?: string[] } = {}): string {
  const header = b64url(JSON.stringify({ alg: "ES256", typ: "JWT", x5c: options.x5c ?? chain.x5c }));
  const body = b64url(JSON.stringify(payload));
  const signature = cryptoSign("sha256", Buffer.from(`${header}.${body}`), { key: chain.leafKeyPem, dsaEncoding: "ieee-p1363" });
  return `${header}.${body}.${b64url(signature)}`;
}
