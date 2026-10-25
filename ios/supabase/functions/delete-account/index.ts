// Deletes the signed-in user's account: their cards at Stripe, their files, then the auth user (which cascades to
// creator_profiles and portfolio_items through foreign keys).
//
// Refuses (409) while the person is the Owner of a company; see account_blockers.
//
// Needs the service role, so it must run server-side and never in the app.
//
// TODO before App Store submission: Apple requires revoking the Sign in with Apple token when
// an account is deleted. That needs the user's authorization code and a client secret signed
// with your Apple key; see https://developer.apple.com/documentation/sign_in_with_apple/revoke_tokens
//
// This function has not been run against a live project yet.

import { createClient } from "jsr:@supabase/supabase-js@2";
import { forgetCards } from "../_shared/cards.ts";
import { makeCardDeps } from "../_shared/runtime.ts";

const BUCKETS = ["avatars", "portfolio"];

Deno.serve(async (request) => {
  if (request.method !== "POST") {
    return new Response("Method not allowed", { status: 405 });
  }

  const authorization = request.headers.get("Authorization");
  if (!authorization) {
    return new Response("Unauthorized", { status: 401 });
  }

  const url = Deno.env.get("SUPABASE_URL")!;
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

  // Identify the caller from their own JWT. Never trust a user id sent in the body.
  const asUser = createClient(url, anonKey, { global: { headers: { Authorization: authorization } } });
  const { data: { user }, error: userError } = await asUser.auth.getUser();
  if (userError || !user) {
    return new Response("Unauthorized", { status: 401 });
  }

  const admin = createClient(url, serviceKey);

  // The Owner of a company can't walk away from it: it would be left with no one to run it or pay for it. They hand
  // it to someone else or close it first (account_blockers lists the companies they still own).
  const { data: blockers, error: blockersError } = await admin.rpc("account_blockers", { p_user: user.id });
  if (blockersError) {
    return new Response(`Could not check companies: ${blockersError.message}`, { status: 500 });
  }
  if (Array.isArray(blockers) && blockers.length > 0) {
    return new Response(JSON.stringify({ error: "owns_company", companies: blockers }), {
      status: 409,
      headers: { "Content-Type": "application/json" },
    });
  }

  // Cards kept at Stripe go first: once the account is gone nothing here points at them any more. Without Stripe set up
  // there can be no cards.
  if (Deno.env.get("STRIPE_SECRET_KEY")) {
    try {
      await forgetCards(makeCardDeps(), user.id);
    } catch (error) {
      console.error("could not remove the cards at Stripe", error);
      return new Response(JSON.stringify({ error: "cards_not_removed" }), {
        status: 502,
        headers: { "Content-Type": "application/json" },
      });
    }
  }

  for (const bucket of BUCKETS) {
    const { data: files, error: listError } = await admin.storage.from(bucket).list(user.id, { limit: 1000 });
    if (listError) {
      return new Response(`Could not list ${bucket}: ${listError.message}`, { status: 500 });
    }
    if (files && files.length > 0) {
      const { error: removeError } = await admin.storage
        .from(bucket)
        .remove(files.map((file) => `${user.id}/${file.name}`));
      if (removeError) {
        return new Response(`Could not clean ${bucket}: ${removeError.message}`, { status: 500 });
      }
    }
  }

  const { error: deleteError } = await admin.auth.admin.deleteUser(user.id);
  if (deleteError) {
    return new Response(`Could not delete user: ${deleteError.message}`, { status: 500 });
  }

  return new Response(JSON.stringify({ deleted: true }), {
    status: 200,
    headers: { "Content-Type": "application/json" },
  });
});
