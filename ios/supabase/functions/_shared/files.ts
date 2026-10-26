// The scheduled job behind the `expire-files` Edge Function, as plain functions that take their dependencies (a database
// and a storage client) as arguments, so Node can test them with fakes (see function-tests/files.test.ts).
//
// What lives where:
//   - Whether a delivery has run out, which drafts and half-finished uploads to tidy, who to warn and what to tell the
//     creator are all decided in SQL (…_slate_files.sql, `files_expire_due`), which is tested against a real Postgres.
//   - Deleting rows doesn't free bytes: every path that stops being needed is queued in `storage_purge`. This file
//     deletes those objects from private storage, in batches, and only then forgets them, so a failure leaves them queued
//     for the next run.
//   - _shared/runtime.ts connects it to the real Storage API. That has never been run against a live project.
//
// Only erasable TypeScript syntax is used (no enums or parameter properties) so Node can run it directly.

import type { Db, HttpResult } from "./payments.ts";
import { isAuthorized } from "./push.ts";

export const PURGE_BATCH = 200;
/** One run deletes at most this many batches, so a huge backlog can't run past the function's time limit. */
export const MAX_BATCHES = 25;

export interface StorageLike {
  /** Deletes objects from the private "deliveries" bucket. Objects that are already gone are not an error. */
  remove(paths: string[]): Promise<void>;
}

export interface FilesDeps {
  db: Db;
  storage: StorageLike;
  log: (message: string, detail?: unknown) => void;
}

export interface ExpireDue {
  expired: number;
  drafts_removed: number;
  uploads_lapsed: number;
  warned: number;
}

export interface FilesReport extends ExpireDue {
  /** Objects removed from storage. */
  purged: number;
  /** Queue entries that weren't a path we make, forgotten without touching storage. */
  skipped: number;
  /** Objects still queued because storage refused (they are tried again next time). */
  waiting: number;
  errors: string[];
}

// <owner>/<booking>/<file>/original or /preview, all lowercase ids. Anything else in the queue is not ours to delete.
const OBJECT_PATH = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}(\/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}){2}\/(original|preview)$/;

export function isOurPath(path: unknown): path is string {
  return typeof path === "string" && OBJECT_PATH.test(path);
}

function describe(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

const EMPTY: ExpireDue = { expired: 0, drafts_removed: 0, uploads_lapsed: 0, warned: 0 };

/** Ends what is due, then deletes the bytes that are no longer needed. Safe to run twice, or while another run is going. */
export async function runExpireFiles(deps: FilesDeps): Promise<FilesReport> {
  const report: FilesReport = { ...EMPTY, purged: 0, skipped: 0, waiting: 0, errors: [] };

  try {
    const done = await deps.db.rpc<Partial<ExpireDue> | null>("files_expire_due");
    report.expired = Number(done?.expired ?? 0);
    report.drafts_removed = Number(done?.drafts_removed ?? 0);
    report.uploads_lapsed = Number(done?.uploads_lapsed ?? 0);
    report.warned = Number(done?.warned ?? 0);
  } catch (error) {
    // The bytes already queued can still go, so carry on.
    report.errors.push(`expire: ${describe(error)}`);
    deps.log("files_expire_due failed", error);
  }

  for (let batch = 0; batch < MAX_BATCHES; batch++) {
    let queued: string[];
    try {
      const rows = await deps.db.rpc<string[] | null>("files_purge_pending", { p_limit: PURGE_BATCH });
      queued = Array.isArray(rows) ? rows.filter((path): path is string => typeof path === "string") : [];
    } catch (error) {
      report.errors.push(`queue: ${describe(error)}`);
      deps.log("files_purge_pending failed", error);
      break;
    }
    if (queued.length === 0) break;

    const ours = queued.filter(isOurPath);
    const foreign = queued.filter((path) => !isOurPath(path));
    if (foreign.length > 0) deps.log("ignoring queued paths that are not delivery objects", foreign);

    try {
      if (ours.length > 0) await deps.storage.remove(ours);
    } catch (error) {
      // Leave them queued; asking again would just fail the same way, so stop here.
      report.errors.push(`storage: ${describe(error)}`);
      report.waiting = ours.length;
      deps.log("deleting from storage failed", error);
      break;
    }

    try {
      await deps.db.rpc("files_purge_done", { p_paths: queued });
    } catch (error) {
      // The bytes are gone but the queue still lists them. The next run deletes them again, which does no harm.
      report.errors.push(`queue: ${describe(error)}`);
      deps.log("files_purge_done failed", error);
      break;
    }
    report.purged += ours.length;
    report.skipped += foreign.length;
    if (queued.length < PURGE_BATCH) break;
  }
  return report;
}

/** POST (no body). Only the scheduler may call it: the service role key, or the same long secret send-push accepts. */
export async function expireFilesRequest(
  request: { method: string; authorization: string | null },
  secrets: (string | undefined)[],
  deps: FilesDeps,
): Promise<HttpResult> {
  if (request.method !== "POST") return { status: 405, body: { error: "method_not_allowed" } };
  if (!isAuthorized(request.authorization, secrets)) return { status: 401, body: { error: "unauthorized" } };
  const report = await runExpireFiles(deps);
  return { status: report.errors.length > 0 ? 500 : 200, body: report };
}
