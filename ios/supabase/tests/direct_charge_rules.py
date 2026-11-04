"""Applies the migrations to a throwaway Postgres and tries to break direct charges and the manual fallback: that a payment is
prepared on the creator's own Stripe account (and with no platform fee), that a payment event from some other account is
ignored, who can save a payment link and who can read it, who can mark a payment received or a refund sent, what that does
to the booking, and that Apple Pay attempts and manual payments can't both take money for the same thing.

Needs a Postgres server (16 recommended) and psycopg2, like the other scripts here:

    PGPORT=5432 python3 ios/supabase/tests/direct_charge_rules.py
"""
import os
import pathlib
import sys
import uuid

import psycopg2
import psycopg2.extras

HOST = dict(
    host=os.environ.get("PGHOST", "127.0.0.1"),
    port=int(os.environ.get("PGPORT", "5432")),
    user=os.environ.get("PGUSER", "postgres"),
)
if os.environ.get("PGPASSWORD"):
    HOST["password"] = os.environ["PGPASSWORD"]
HERE = pathlib.Path(__file__).resolve().parent
MIG = HERE.parent / "migrations"
DB = "slate_direct"


def connect(db=DB):
    c = psycopg2.connect(dbname=db, **HOST)
    c.autocommit = True
    return c


root = connect("postgres")
root.cursor().execute(f"drop database if exists {DB}")
root.cursor().execute(f"create database {DB}")
root.close()
admin = connect()
a = admin.cursor()
a.execute("select 1 from pg_roles where rolname = 'anon'")
stubs = (HERE / "stubs.sql").read_text()
if a.fetchone():
    for role in ("create role anon nologin;", "create role authenticated nologin;", "create role service_role nologin bypassrls;"):
        stubs = stubs.replace(role, "")
a.execute(stubs)
for f in sorted(MIG.glob("*.sql")):
    a.execute(f.read_text())
    print("applied", f.name)
# These checks are about payments, not about paying for seats (billing_rules.py is).
a.execute("update app_settings set value = value || '{\"required\": false}'::jsonb where key = 'billing'")

failures = []


def check(name, cond, detail=""):
    print(("  ok   " if cond else "  FAIL ") + name + (f"   [{detail}]" if (detail and not cond) else ""))
    if not cond:
        failures.append(name)


def first_line(e):
    return "ERR:" + (e.pgerror or str(e)).strip().splitlines()[0]


def err(result, token):
    return isinstance(result, str) and result.startswith("ERR:") and token in result


def as_user(uid, role="authenticated"):
    c = connect()
    k = c.cursor()
    if uid:
        k.execute("select set_config('request.jwt.claim.sub', %s, false)", (uid,))
    k.execute(f"set role {role}")
    return c, k


def sql_as(uid, query, args=None, role="authenticated"):
    c, k = as_user(uid, role)
    try:
        k.execute(query, args)
        rows = k.fetchall() if k.description else []
        return rows, k.rowcount
    except psycopg2.Error as e:
        return first_line(e)
    finally:
        c.close()


def rpc(uid, fn, *args, role="authenticated"):
    res = sql_as(uid, f"select {fn}({', '.join(['%s'] * len(args))})", args, role)
    if isinstance(res, str):
        return res
    value = res[0][0][0]
    return None if value == "" else value


def svc(fn, *args):
    return rpc(None, fn, *args, role="service_role")


def one(query, args=None):
    a.execute(query, args)
    r = a.fetchone()
    return r[0] if r else None


def rows(query, args=None):
    a.execute(query, args)
    return a.fetchall()


def new_user(handle=None, name="User"):
    uid = str(uuid.uuid4())
    a.execute("insert into auth.users (id, email) values (%s, %s)", (uid, f"{uid[:8]}@example.com"))
    if handle:
        a.execute("insert into creator_profiles (id, handle, display_name) values (%s,%s,%s)", (uid, handle, name))
    return uid


def add_signature(uid, name):
    a.execute("insert into creator_signatures (creator_id, signed_name, method) values (%s,%s,'typed')", (uid, name))


def join(org, inviter, role, uid, name=None):
    inv = rpc(inviter, "invite_create", org, role, None)
    return inv if isinstance(inv, str) else rpc(uid, "accept_invite", inv["token"], name)


def connect_account(owner, charges=True, account=None):
    a.execute(
        "insert into creator_payment_accounts (creator_id, stripe_account_id, charges_enabled, payouts_enabled, details_submitted)"
        " values (%s, %s, %s, %s, %s)", (owner, account or "acct_" + owner[:8], charges, charges, charges))


days = [20]


def booking(creator, client, assigned=None, total=100000, deposit=30000, status="held", received=False, deposit_paid=False,
            same_day=None):
    """A booking made as the database owner (notification triggers off), in the future, so deposits and balances are due."""
    if same_day is None:
        days[0] += 1
    d = same_day or days[0]
    a.execute("alter table bookings disable trigger user")
    try:
        a.execute(
            """insert into bookings (creator_id, client_id, creator_name, package_name, start_at, end_at, blocked_until, time_zone,
                                     currency_code, total_cents, deposit_cents, status, assigned_to, hold_expires_at,
                                     delivered_at, receipt_confirmed_at)
               values (%s, %s, 'Test Creator', 'Wedding', now() + make_interval(days => %s),
                       now() + make_interval(days => %s) + interval '4 hours', now() + make_interval(days => %s) + interval '4 hours',
                       'America/Chicago', 'USD', %s, %s, %s, %s, case when %s = 'held' then now() + interval '15 minutes' end,
                       case when %s then now() - interval '1 day' end, case when %s then now() - interval '1 hour' end)
               returning id""",
            (creator, client, d, d, d, total, deposit, status, assigned or creator, status, received, received))
        bid = a.fetchone()[0]
    finally:
        a.execute("alter table bookings enable trigger user")
    if deposit_paid and deposit > 0:
        a.execute(
            "insert into payments (booking_id, kind, amount_cents, currency_code, status, method, stripe_payment_intent_id,"
            " stripe_account_id, paid_at) values (%s, 'deposit', %s, 'USD', 'succeeded', 'apple_pay', %s, %s, now())",
            (bid, deposit, "pi_dep_" + uuid.uuid4().hex[:10], "acct_" + creator[:8]))
    return bid


def pay_rows(bid, kind=None):
    if kind:
        return rows("select kind, status, method, amount_cents, stripe_account_id, marked_by::text, note, platform_fee_cents"
                    " from payments where booking_id = %s and kind = %s order by created_at", (bid, kind))
    return rows("select kind, status, method, amount_cents, stripe_account_id, marked_by::text, note, platform_fee_cents"
                " from payments where booking_id = %s order by created_at", (bid,))


def status_of(bid):
    return one("select status from bookings where id = %s", (bid,))


# =============================================================================
print("\n[setting up people]")
olivia = new_user("olivia-ng", "Olivia Ng")
add_signature(olivia, "Olivia Ng")
dee, cal, vee = new_user(), new_user("cal-r", "Cal R"), new_user()
carol = new_user("carol-c", "Carol Chen")
add_signature(carol, "Carol Chen")
nora = new_user("nora-n", "Nora N")  # a creator with no Stripe account at all
add_signature(nora, "Nora N")
alice, bea, stranger = new_user(), new_user(), new_user()
ORG = rpc(olivia, "org_create", "acme-films", "Acme Films", "Acme Films LLC", "1 Main St", "", ["weddings"], "Austin, TX")["organization_id"]
join(ORG, olivia, "admin", dee, "Dee Okafor")
join(ORG, olivia, "creator", cal)
join(ORG, olivia, "viewer", vee, "Vee T")
connect_account(carol)
connect_account(ORG)
check("people are set up", one("select count(*) from memberships where organization_id = %s and removed_at is null", (ORG,)) == 4,
      one("select string_agg(role, ',') from memberships where organization_id = %s and removed_at is null", (ORG,)))

# =============================================================================
print("\n[a payment is prepared on the creator's own Stripe account]")
b1 = booking(carol, alice)
prep = svc("payment_prepare", alice, b1, "deposit", 0)
check("the answer names the creator's account, not a destination", isinstance(prep, dict) and prep.get("account") == "acct_" + carol[:8]
      and "destination" not in prep, prep)
check("the payment row remembers the account it lives on", pay_rows(b1)[0][4] == "acct_" + carol[:8], pay_rows(b1))
check("there is no platform fee by default", prep["fee_cents"] == 0 and pay_rows(b1)[0][7] == 0, prep)
check("asking again reuses the same payment", svc("payment_prepare", alice, b1, "deposit", 0)["payment_id"] == prep["payment_id"])
b1b = booking(carol, bea)
check("a fee in basis points is still understood for later (1% of $300 is $3)",
      svc("payment_prepare", bea, b1b, "deposit", 100)["fee_cents"] == 300)
check("only the booking's client can ask", err(svc("payment_prepare", stranger, b1, "deposit", 0), "not_found"))
check("a creator with no Stripe account can't have a payment prepared",
      err(svc("payment_prepare", alice, booking(nora, alice), "deposit", 0), "payments_not_ready"))

# =============================================================================
print("\n[the webhook for the connected account]")
svc("payment_attach_intent", prep["payment_id"], "pi_direct_1")
wrong = svc("payment_record_success", "pi_direct_1", 30000, "ch_1", "apple_pay", "acct_somebody_else")
check("an event from a different account is ignored", wrong["action"] == "ignored" and status_of(b1) == "held" and pay_rows(b1)[0][1] == "pending", wrong)
none_given = svc("payment_record_success", "pi_direct_1", 30000, "ch_1", "apple_pay", None)
check("the same intent with the right account confirms the booking",
      svc("payment_record_success", "pi_direct_1", 30000, "ch_1", "apple_pay", "acct_" + carol[:8])["action"] in ("confirmed", "noop")
      and status_of(b1) == "confirmed", status_of(b1))
check("an internal call with no account still works (and is safe to repeat)", none_given["action"] in ("confirmed", "noop"))
check("the payment is recorded as Apple Pay with its charge", pay_rows(b1, "deposit")[0][1:3] == ("succeeded", "apple_pay"), pay_rows(b1))
check("an amount that doesn't match is refused",
      err(svc("payment_record_success", svc("payment_attach_intent", svc("payment_prepare", bea, b1b, "deposit", 0)["payment_id"], "pi_direct_2") or "pi_direct_2",
              1, "ch_2", "apple_pay", "acct_" + carol[:8]), "amount_mismatch"))

b2 = booking(carol, alice)
p2 = svc("payment_prepare", alice, b2, "deposit", 0)
svc("payment_attach_intent", p2["payment_id"], "pi_old_account")
a.execute("update creator_payment_accounts set stripe_account_id = 'acct_carol_new' where creator_id = %s", (carol,))
p2b = svc("payment_prepare", alice, b2, "deposit", 0)
check("after the creator connects another account, a fresh payment is made on it",
      p2b["payment_id"] != p2["payment_id"] and p2b["account"] == "acct_carol_new" and p2b["existing_intent"] is None, p2b)
check("the attempt on the old account is closed",
      one("select status from payments where id = %s", (p2["payment_id"],)) == "canceled")
a.execute("update creator_payment_accounts set stripe_account_id = %s where creator_id = %s", ("acct_" + carol[:8], carol))

# =============================================================================
print("\n[a creator's payment link]")
check("a person can save their own link", rpc(carol, "payment_link_save", carol, "https://pay.example.com/carol", "Zelle: carol@example.com") is None)
row = rows("select url, instructions from creator_payment_links where creator_id = %s", (carol,))
check("it is kept as given", row == [("https://pay.example.com/carol", "Zelle: carol@example.com")], row)
check("saving again replaces it", rpc(carol, "payment_link_save", carol, "https://pay.example.com/carol2", "") is None
      and rows("select url from creator_payment_links where creator_id = %s", (carol,)) == [("https://pay.example.com/carol2",)])
for bad in ("http://pay.example.com/x", "pay.example.com", "javascript:alert(1)", "https://localhost/x", "https://a b.example.com", "https://" + "x" * 2100 + ".com"):
    check(f"{bad[:40]!r} is not accepted", err(rpc(carol, "payment_link_save", carol, bad, ""), "invalid_link"))
check("instructions are limited to 300 characters", rows("select char_length(instructions) from creator_payment_links where creator_id = %s", (carol,))[0][0] <= 300)
rpc(carol, "payment_link_save", carol, "https://pay.example.com/carol", "x" * 500)
check("longer instructions are cut, not refused", rows("select char_length(instructions) from creator_payment_links where creator_id = %s", (carol,))[0][0] == 300)
check("someone else can't save it for them", err(rpc(stranger, "payment_link_save", carol, "https://evil.example.com", ""), "not_found"))
check("someone else can't read it from the table", sql_as(stranger, "select count(*) from creator_payment_links")[0][0][0] == 0)
check("the owner reads their own", sql_as(carol, "select count(*) from creator_payment_links")[0][0][0] == 1)
check("nobody writes the table directly", isinstance(sql_as(carol, "update creator_payment_links set url = 'https://evil.example.com' where true"), str)
      or sql_as(carol, "update creator_payment_links set url = 'https://evil.example.com' where true")[1] == 0)
check("a company's link is the Owner's to set (an Admin can't)", err(rpc(dee, "payment_link_save", ORG, "https://pay.example.com/acme", ""), "not_found")
      and rpc(olivia, "payment_link_save", ORG, "https://pay.example.com/acme", "Invoice by email") is None)
check("an Admin can't read the company's link from the table either", sql_as(dee, "select count(*) from creator_payment_links where creator_id = %s", (ORG,))[0][0][0] == 0)
check("a person with no profile can't have one", err(rpc(stranger, "payment_link_save", stranger, "https://pay.example.com/x", ""), "profile_required"))
check("an empty address takes the link away", rpc(olivia, "payment_link_save", ORG, "  ", "") is None
      and one("select count(*) from creator_payment_links where creator_id = %s", (ORG,)) == 0)

# What the client sees.
check("the booking's client sees how they can pay",
      rpc(alice, "payment_options", b1) == {"stripe_ready": True, "link_url": "https://pay.example.com/carol", "instructions": "x" * 300}, rpc(alice, "payment_options", b1))
check("nobody else does", rpc(stranger, "payment_options", b1) is None and rpc(carol, "payment_options", b1) is None)
rpc(nora, "payment_link_save", nora, "https://pay.example.com/nora", "PayPal @nora")
bn = booking(nora, alice)
check("a creator with only a link is not 'stripe ready' but has a link",
      rpc(alice, "payment_options", bn) == {"stripe_ready": False, "link_url": "https://pay.example.com/nora", "instructions": "PayPal @nora"}, rpc(alice, "payment_options", bn))
a.execute("insert into packages (creator_id, name, price_cents, duration_minutes, deposit_cents, is_published) values (%s, 'Wedding', 100000, 240, 30000, false) returning id", (nora,))
pkg_nora = a.fetchone()[0]
check("a deposit package is bookable with a link and no Stripe account", svc("assert_payments_ready", pkg_nora) is None)
rpc(nora, "payment_link_save", nora, "", "")
check("and not with neither", err(svc("assert_payments_ready", pkg_nora), "payments_not_ready"))
rpc(nora, "payment_link_save", nora, "https://pay.example.com/nora", "PayPal @nora")

# =============================================================================
print("\n[marking a deposit received by hand]")
bm = booking(nora, alice)
check("a client can't mark their own payment", err(rpc(alice, "payment_mark_received", bm, "deposit", None), "not_found"))
check("a stranger can't", err(rpc(stranger, "payment_mark_received", bm, "deposit", None), "not_found"))
check("a made-up kind is refused", err(rpc(nora, "payment_mark_received", bm, "tip", None), "invalid_kind"))
res = rpc(nora, "payment_mark_received", bm, "deposit", "  Zelle, Tuesday  ")
check("the creator can: the booking is confirmed", isinstance(res, dict) and res["action"] == "confirmed" and status_of(bm) == "confirmed", res)
row = pay_rows(bm, "deposit")
check("the payment is recorded as manual, by them, with their note, for the deposit amount and nothing from Stripe",
      row == [("deposit", "succeeded", "manual", 30000, None, nora, "Zelle, Tuesday", 0)], row)
check("it holds no Stripe ids", one("select stripe_payment_intent_id is null and stripe_charge_id is null from payments where booking_id = %s and kind = 'deposit'", (bm,)))
check("marking it again is refused", err(rpc(nora, "payment_mark_received", bm, "deposit", None), "already_paid") or err(rpc(nora, "payment_mark_received", bm, "deposit", None), "payment_not_due"))
check("the balance isn't due until the client has their files", err(rpc(nora, "payment_mark_received", bm, "balance", None), "balance_not_due"))
a.execute("update bookings set delivered_at = now(), receipt_confirmed_at = now() where id = %s", (bm,))
res = rpc(nora, "payment_mark_received", bm, "balance", None)
check("once they do, the balance can be marked and the booking is completed", isinstance(res, dict) and res["action"] == "completed" and status_of(bm) == "completed", res)
check("the balance is the rest of the price", pay_rows(bm, "balance")[0][3] == 70000, pay_rows(bm, "balance"))
check("a completed booking has nothing more to mark", err(rpc(nora, "payment_mark_received", bm, "balance", None), "balance_not_due"))

# =============================================================================
print("\n[marking by a company, by role]")
bo = booking(ORG, alice, assigned=cal)
check("a Viewer can't", err(rpc(vee, "payment_mark_received", bo, "deposit", None), "not_found"))
check("an Admin can", isinstance(rpc(dee, "payment_mark_received", bo, "deposit", "cash"), dict) and status_of(bo) == "confirmed")
bo2 = booking(ORG, bea, assigned=cal)
check("the member the booking is assigned to can", isinstance(rpc(cal, "payment_mark_received", bo2, "deposit", None), dict) and status_of(bo2) == "confirmed")
bo3 = booking(ORG, alice, assigned=olivia)
check("a member can't mark someone else's booking", err(rpc(cal, "payment_mark_received", bo3, "deposit", None), "not_found"))

# =============================================================================
print("\n[a hold that ran out]")
be = booking(nora, alice, status="expired")
check("a deposit can be marked after the hold lapsed, while the time is free", isinstance(rpc(nora, "payment_mark_received", be, "deposit", None), dict)
      and status_of(be) == "confirmed", status_of(be))
bx = booking(nora, alice, status="expired")
day_x = one("select (extract(day from (start_at - now())))::int from bookings where id = %s", (bx,))
a.execute("select start_at from bookings where id = %s", (bx,))
start_x = a.fetchone()[0]
a.execute("alter table bookings disable trigger user")
a.execute(
    """insert into bookings (creator_id, client_id, creator_name, package_name, start_at, end_at, blocked_until, time_zone, currency_code,
                             total_cents, deposit_cents, status, assigned_to)
       select creator_id, %s, 'Test Creator', 'Other', start_at, end_at, blocked_until, time_zone, 'USD', 100000, 0, 'confirmed', assigned_to
         from bookings where id = %s""", (bea, bx))
a.execute("alter table bookings enable trigger user")
res = rpc(nora, "payment_mark_received", bx, "deposit", None)
check("but not once someone else has the time", err(res, "time_taken"), res)
check("and then nothing was recorded", pay_rows(bx) == [] and status_of(bx) == "expired", (pay_rows(bx), status_of(bx)))

# =============================================================================
print("\n[Apple Pay and a manual payment for the same thing]")
bd = booking(carol, alice)
pd = svc("payment_prepare", alice, bd, "deposit", 0)
svc("payment_attach_intent", pd["payment_id"], "pi_race")
res = rpc(carol, "payment_mark_received", bd, "deposit", "paid by check")
check("the creator marks it received while an Apple Pay attempt is open", isinstance(res, dict) and status_of(bd) == "confirmed", res)
check("the open attempt is closed", one("select status from payments where id = %s", (pd["payment_id"],)) == "canceled")
late = svc("payment_record_success", "pi_race", 30000, "ch_race", "apple_pay", "acct_" + carol[:8])
check("if the client finishes it anyway, the money is queued to go back", late["action"] == "refund_required", late)
todo = rows("select amount_cents, stripe_account_id, payment_intent_id from refunds_to_process(%s)", (bd,))
check("the refund is made on the same connected account", todo == [(30000, "acct_" + carol[:8], "pi_race")], todo)
check("the booking is still confirmed and the manual payment stands", status_of(bd) == "confirmed"
      and pay_rows(bd, "deposit")[-1][2] in ("manual", "apple_pay") and sum(1 for r in pay_rows(bd, "deposit") if r[1] == "succeeded") == 1, pay_rows(bd))

# =============================================================================
print("\n[refunds of a manual payment]")
bc = booking(nora, alice)
rpc(nora, "payment_mark_received", bc, "deposit", None)
cancelled = rpc(nora, "cancel_booking", bc)
refunds = rows("select id::text, amount_cents, status, method from payments where booking_id = %s and kind = 'refund'", (bc,))
check("cancelling makes a refund row, marked manual and pending", len(refunds) == 1 and refunds[0][2] == "pending" and refunds[0][3] == "manual", (cancelled, refunds))
check("Stripe has nothing to send for it", rows("select * from refunds_to_process(%s)", (bc,)) == [])
if refunds:
    rid = refunds[0][0]
    check("the client can't say it was sent", err(rpc(alice, "refund_mark_sent", rid), "not_found"))
    check("a stranger can't", err(rpc(stranger, "refund_mark_sent", rid), "not_found"))
    check("the creator can", rpc(nora, "refund_mark_sent", rid) is None
          and rows("select status, marked_by::text from payments where id = %s", (rid,)) == [("succeeded", nora)])
    check("saying it twice changes nothing", rpc(nora, "refund_mark_sent", rid) is None)
# A refund Stripe owes can't be marked by hand.
bs = booking(carol, alice, deposit_paid=True, status="confirmed")
cancelled = rpc(carol, "cancel_booking", bs)
srefund = rows("select id::text, method from payments where booking_id = %s and kind = 'refund'", (bs,))
check("a refund of an Apple Pay payment is Stripe's to send", len(srefund) == 1 and srefund[0][1] == "apple_pay"
      and len(rows("select * from refunds_to_process(%s)", (bs,))) == 1, (cancelled, srefund))
if srefund:
    check("and can't be marked sent by hand", err(rpc(carol, "refund_mark_sent", srefund[0][0]), "invalid_kind"))
check("the refund is to be made on the creator's account", rows("select stripe_account_id from refunds_to_process(%s)", (bs,)) == [("acct_" + carol[:8],)])

# =============================================================================
print("\n[the ledger]")
try:
    a.execute("insert into payments (booking_id, kind, amount_cents, currency_code, status, method, stripe_payment_intent_id)"
              " values (%s, 'balance', 1, 'USD', 'pending', 'manual', 'pi_sneaky')", (bm,))
    check("the database refuses a manual payment with a Stripe id", False)
except psycopg2.Error:
    check("the database refuses a manual payment with a Stripe id", True)

print()
if failures:
    print(f"{len(failures)} failed:", *failures, sep="\n  ")
    sys.exit(1)
print("all passed")
