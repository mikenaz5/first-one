import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { expireFilesRequest, isOurPath, MAX_BATCHES, PURGE_BATCH, runExpireFiles } from "../functions/_shared/files.ts";
import type { FilesDeps, StorageLike } from "../functions/_shared/files.ts";

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------
type Handler = (args: Record<string, unknown>) => unknown;

class FakeDb {
  calls: { fn: string; args: Record<string, unknown> }[] = [];
  handlers: Record<string, Handler>;
  constructor(handlers: Record<string, Handler>) {
    this.handlers = handlers;
  }
  async rpc<T = unknown>(fn: string, args: Record<string, unknown> = {}): Promise<T> {
    this.calls.push({ fn, args });
    const handler = this.handlers[fn];
    if (!handler) throw new Error(`unexpected database call: ${fn}`);
    const result = handler(args);
    if (result instanceof Error) throw result;
    return result as T;
  }
  called(fn: string) {
    return this.calls.filter((call) => call.fn === fn);
  }
}

const OWNER = "0f5a7c1e-3b0d-4c8e-9a52-6d7e8f9a0b1c";
const BOOKING = "1a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d";
function pathFor(n: number, part: "original" | "preview" = "original"): string {
  const file = `${String(n).padStart(8, "0")}-aaaa-4bbb-8ccc-dddddddddddd`;
  return `${OWNER}/${BOOKING}/${file}/${part}`;
}

/** A queue that behaves like storage_purge: pending returns the first `limit`, done forgets what it is told. */
function makeQueue(paths: string[]) {
  const queue = [...paths];
  return {
    queue,
    pending: (args: Record<string, unknown>) => queue.slice(0, Number(args.p_limit ?? PURGE_BATCH)),
    done: (args: Record<string, unknown>) => {
      const gone = new Set(args.p_paths as string[]);
      let removed = 0;
      for (let i = queue.length - 1; i >= 0; i--) {
        if (gone.has(queue[i])) {
          queue.splice(i, 1);
          removed++;
        }
      }
      return removed;
    },
  };
}

function makeStorage(failWith?: Error): { storage: StorageLike; removed: string[][] } {
  const removed: string[][] = [];
  return {
    removed,
    storage: {
      async remove(paths) {
        if (failWith) throw failWith;
        removed.push([...paths]);
      },
    },
  };
}

const DUE = { expired: 2, drafts_removed: 1, uploads_lapsed: 3, warned: 4 };

function setup(paths: string[], opts: { storageError?: Error; due?: Handler } = {}) {
  const q = makeQueue(paths);
  const db = new FakeDb({ files_expire_due: opts.due ?? (() => DUE), files_purge_pending: q.pending, files_purge_done: q.done });
  const { storage, removed } = makeStorage(opts.storageError);
  const logs: string[] = [];
  const deps: FilesDeps = { db, storage, log: (message) => logs.push(message) };
  return { db, deps, q, removed, logs };
}

// ---------------------------------------------------------------------------
describe("which queued paths are ours to delete", () => {
  it("accepts <owner>/<booking>/<file>/original and /preview, lowercase", () => {
    assert.equal(isOurPath(pathFor(1)), true);
    assert.equal(isOurPath(pathFor(2, "preview")), true);
  });
  it("refuses anything else", () => {
    for (const bad of [
      "",
      "avatars/me.png",
      `${OWNER}/${BOOKING}`,
      `${OWNER}/${BOOKING}/${BOOKING}/thumb`,
      `${OWNER}/${BOOKING}/${BOOKING}/original/extra`,
      `../${OWNER}/${BOOKING}/${BOOKING}/original`,
      pathFor(1).toUpperCase(),
      `${OWNER}/${BOOKING}/${BOOKING}/original\n`,
    ]) {
      assert.equal(isOurPath(bad), false, JSON.stringify(bad));
    }
    assert.equal(isOurPath(null), false);
    assert.equal(isOurPath(42), false);
  });
});

describe("a run", () => {
  it("ends what is due, then deletes the queued bytes and forgets them", async () => {
    const { db, deps, q, removed } = setup([pathFor(1), pathFor(1, "preview"), pathFor(2)]);
    const report = await runExpireFiles(deps);
    assert.deepEqual(report, { ...DUE, purged: 3, skipped: 0, waiting: 0, errors: [] });
    assert.deepEqual(removed, [[pathFor(1), pathFor(1, "preview"), pathFor(2)]]);
    assert.deepEqual(q.queue, []);
    assert.deepEqual(db.calls.map((c) => c.fn), ["files_expire_due", "files_purge_pending", "files_purge_done"]);
  });

  it("with nothing queued, doesn't call storage at all", async () => {
    const { db, deps, removed } = setup([]);
    const report = await runExpireFiles(deps);
    assert.equal(report.purged, 0);
    assert.deepEqual(removed, []);
    assert.equal(db.called("files_purge_done").length, 0);
  });

  it("deletes in batches until the queue is empty", async () => {
    const many = Array.from({ length: PURGE_BATCH * 2 + 5 }, (_, i) => pathFor(i + 1));
    const { deps, q, removed } = setup(many);
    const report = await runExpireFiles(deps);
    assert.equal(report.purged, many.length);
    assert.deepEqual(removed.map((batch) => batch.length), [PURGE_BATCH, PURGE_BATCH, 5]);
    assert.deepEqual(q.queue, []);
  });

  it("stops after a bounded number of batches, leaving the rest for next time", async () => {
    const many = Array.from({ length: PURGE_BATCH * (MAX_BATCHES + 3) }, (_, i) => pathFor(i + 1));
    const { deps, q, removed } = setup(many);
    const report = await runExpireFiles(deps);
    assert.equal(removed.length, MAX_BATCHES);
    assert.equal(report.purged, PURGE_BATCH * MAX_BATCHES);
    assert.equal(q.queue.length, PURGE_BATCH * 3);
    assert.deepEqual(report.errors, []);
  });

  it("asks for a bounded batch size", async () => {
    const { db, deps } = setup([pathFor(1)]);
    await runExpireFiles(deps);
    assert.equal(db.called("files_purge_pending")[0].args.p_limit, PURGE_BATCH);
  });

  it("running again straight away does nothing more", async () => {
    const { deps, removed } = setup([pathFor(1), pathFor(2)]);
    await runExpireFiles(deps);
    const second = await runExpireFiles(deps);
    assert.equal(second.purged, 0);
    assert.equal(removed.length, 1);
  });
});

describe("a path that isn't a delivery object", () => {
  it("is never sent to storage, and is forgotten so it doesn't block the queue", async () => {
    const { deps, q, removed, logs } = setup(["avatars/someone.png", pathFor(1), "../../etc/passwd"]);
    const report = await runExpireFiles(deps);
    assert.deepEqual(removed, [[pathFor(1)]]);
    assert.equal(report.purged, 1);
    assert.equal(report.skipped, 2);
    assert.deepEqual(q.queue, []);
    assert.ok(logs.some((l) => l.includes("not delivery objects")));
  });
});

describe("when something goes wrong", () => {
  it("leaves the bytes queued when storage refuses, says so, and doesn't keep trying", async () => {
    const { db, deps, q } = setup([pathFor(1), pathFor(2)], { storageError: new Error("storage is down") });
    const report = await runExpireFiles(deps);
    assert.equal(report.purged, 0);
    assert.equal(report.waiting, 2);
    assert.equal(q.queue.length, 2);
    assert.equal(db.called("files_purge_done").length, 0);
    assert.equal(db.called("files_purge_pending").length, 1);
    assert.ok(report.errors[0].includes("storage is down"));
  });

  it("still deletes the queued bytes when ending deliveries fails", async () => {
    const { deps, removed } = setup([pathFor(1)], { due: () => new Error("database busy") });
    const report = await runExpireFiles(deps);
    assert.equal(report.purged, 1);
    assert.deepEqual(removed, [[pathFor(1)]]);
    assert.equal(report.expired, 0);
    assert.ok(report.errors[0].startsWith("expire:") && report.errors[0].includes("database busy"));
  });

  it("stops when the queue can't be read", async () => {
    const db = new FakeDb({ files_expire_due: () => DUE, files_purge_pending: () => new Error("no queue") });
    const { storage, removed } = makeStorage();
    const report = await runExpireFiles({ db, storage, log: () => {} });
    assert.deepEqual(removed, []);
    assert.ok(report.errors[0].includes("no queue"));
  });

  it("reports it if forgetting the paths fails (they are simply deleted again next time)", async () => {
    const q = makeQueue([pathFor(1)]);
    const db = new FakeDb({ files_expire_due: () => DUE, files_purge_pending: q.pending, files_purge_done: () => new Error("lost connection") });
    const { storage } = makeStorage();
    const report = await runExpireFiles({ db, storage, log: () => {} });
    assert.equal(report.purged, 0);
    assert.ok(report.errors[0].includes("lost connection"));
    assert.equal(q.queue.length, 1);
  });

  it("copes with odd answers from the database", async () => {
    const db = new FakeDb({ files_expire_due: () => null, files_purge_pending: () => null });
    const { storage } = makeStorage();
    const report = await runExpireFiles({ db, storage, log: () => {} });
    assert.deepEqual(report, { expired: 0, drafts_removed: 0, uploads_lapsed: 0, warned: 0, purged: 0, skipped: 0, waiting: 0, errors: [] });
  });
});

describe("who may run it", () => {
  const secret = "s".repeat(32);
  const post = (authorization: string | null, secrets: (string | undefined)[] = [secret]) => {
    const { deps, db } = setup([pathFor(1)]);
    return expireFilesRequest({ method: "POST", authorization }, secrets, deps).then((result) => ({ result, db }));
  };

  it("takes POST only", async () => {
    const { deps } = setup([]);
    const result = await expireFilesRequest({ method: "GET", authorization: `Bearer ${secret}` }, [secret], deps);
    assert.equal(result.status, 405);
  });

  it("refuses anyone without the secret, and touches nothing", async () => {
    for (const authorization of [null, "", "Bearer", "Bearer wrong", `Basic ${secret}`, `Bearer ${secret} extra`]) {
      const { result, db } = await post(authorization);
      assert.equal(result.status, 401, String(authorization));
      assert.equal(db.calls.length, 0);
    }
  });

  it("refuses a short or missing secret, so a blank setting lets nobody in", async () => {
    assert.equal((await post("Bearer short", ["short"])).result.status, 401);
    assert.equal((await post("Bearer ", [""])).result.status, 401);
    assert.equal((await post("Bearer anything-long-enough-xx", [undefined])).result.status, 401);
  });

  it("accepts the service key or the cron secret", async () => {
    const service = "k".repeat(40);
    assert.equal((await post(`Bearer ${service}`, [service, secret])).result.status, 200);
    assert.equal((await post(`Bearer ${secret}`, [service, secret])).result.status, 200);
  });

  it("answers 500 when something failed, so the scheduler shows it", async () => {
    const { deps } = setup([pathFor(1)], { storageError: new Error("down") });
    const result = await expireFilesRequest({ method: "POST", authorization: `Bearer ${secret}` }, [secret], deps);
    assert.equal(result.status, 500);
    assert.ok((result.body as { errors: string[] }).errors.length > 0);
  });
});
