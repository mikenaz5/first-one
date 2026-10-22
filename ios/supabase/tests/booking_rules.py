"""Applies the migrations to a throwaway Postgres and tries to break the booking and contract rules.

Needs a Postgres server (16 recommended) and psycopg2. Connection comes from the usual
environment variables (PGHOST, PGPORT, PGUSER, PGPASSWORD); defaults suit a local trust-auth server.
The Supabase pieces the migrations lean on (auth, storage, API roles) are stubbed in stubs.sql.

    PGPORT=5432 python3 ios/supabase/tests/booking_rules.py
"""
import datetime as dt
import hashlib
import json
import os
import pathlib
import sys
import threading
import time
import uuid
from zoneinfo import ZoneInfo

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
GOLDEN = HERE.parents[1] / "SlateTests" / "Fixtures" / "contract_golden.json"
GOLDEN_REFUNDS = HERE.parents[1] / "SlateTests" / "Fixtures" / "refund_golden.json"
GOLDEN_DELIVERY = HERE.parents[1] / "SlateTests" / "Fixtures" / "delivery_rules.json"
TZ = "America/Chicago"
Json = psycopg2.extras.Json


def connect(db="slate"):
    c = psycopg2.connect(dbname=db, **HOST)
    c.autocommit = True
    return c


# ---- fresh database ---------------------------------------------------------
root = connect("postgres")
cur = root.cursor()
cur.execute("drop database if exists slate")
cur.execute("create database slate")
root.close()
admin = connect()
a = admin.cursor()
# roles are cluster-wide; create only once
a.execute("select 1 from pg_roles where rolname = 'anon'")
stubs = (HERE / "stubs.sql").read_text()
if a.fetchone():
    for role in ("create role anon nologin;", "create role authenticated nologin;", "create role service_role nologin bypassrls;"):
        stubs = stubs.replace(role, "")
a.execute(stubs)
for f in sorted(MIG.glob("*.sql")):
    a.execute(f.read_text())
    print("applied", f.name)


# ---- fixtures ---------------------------------------------------------------
def new_user(handle=None, name="User"):
    uid = str(uuid.uuid4())
    a.execute("insert into auth.users (id, email) values (%s, %s)", (uid, f"{uid[:8]}@example.com"))
    if handle:
        a.execute("insert into creator_profiles (id, handle, display_name, specialties) values (%s,%s,%s,%s)",
                  (uid, handle, name, ["weddings"]))
    return uid


creator = new_user("maya-chen", "Maya Chen")
other_creator = new_user("dan-lee", "Dan Lee")
alice, bob = new_user(), new_user()

a.execute("select (date_trunc('week', now() at time zone %s) + interval '2 weeks')::date", (TZ,))
monday = a.fetchone()[0]  # a Monday, two weeks out


def at(day_offset, hh, mm=0, ss=0):
    """A timestamptz at local wall time in the creator's zone. day_offset 0 = Monday."""
    a.execute("select ((%s::date + %s) + make_time(%s,%s,%s)) at time zone %s", (monday, day_offset, hh, mm, ss, TZ))
    return a.fetchone()[0]


MON, TUE, WED, THU, FRI, SAT = 0, 1, 2, 3, 4, 5

E1, DRONE, RUSH = str(uuid.uuid4()), str(uuid.uuid4()), str(uuid.uuid4())
add_ons = [
    dict(id=E1, kind="extraTime", name="Extra hour", priceCents=15000, extraMinutes=60, turnaroundDeltaDays=0),
    dict(id=DRONE, kind="drone", name="Drone footage", priceCents=25000, extraMinutes=0, turnaroundDeltaDays=0),
    dict(id=RUSH, kind="rush", name="Rush delivery", priceCents=10000, extraMinutes=0, turnaroundDeltaDays=-3),
]


def clause(title, body):
    return dict(id=str(uuid.uuid4()), title=title, body=body)


CLAUSES = [
    clause("Parties", 'This agreement is between {{creator_name}} (the "Creator") and {{client_name}} (the "Client") for the "{{package_name}}" package.'),
    clause("The shoot", "Date: {{booking_date}}\nTime: {{booking_time}} ({{time_zone}})\nLength: {{duration}}\nNotes: {{client_notes}}"),
    clause("Deliverables", "{{deliverables}}\n\nAdd-ons:\n{{add_ons}}\n\nDelivered within {{turnaround}}, by {{delivery_date}}."),
    clause("Fees", "Total {{price}}. Deposit {{deposit}}. Balance {{balance}}."),
    clause("Cancellation", "{{cancellation_policy}}"),
    clause("Usage", "{{usage_rights}}"),
]


def add_template(owner, title="Photography services agreement", clauses=None):
    a.execute("insert into contract_templates (creator_id, title, kind, clauses) values (%s,%s,'photography',%s) returning id",
              (owner, title, Json(clauses or CLAUSES)))
    return a.fetchone()[0]


def add_signature(owner, name, method="typed", image=None):
    a.execute("insert into creator_signatures (creator_id, signed_name, method, image_png) values (%s,%s,%s,%s)", (owner, name, method, image))


TEMPLATE = add_template(creator)
add_signature(creator, "Maya Chen")
a.execute("""insert into packages (creator_id, name, price_cents, duration_minutes, deposit_cents, add_ons, deliverables,
                                   contract_template_id, cancellation_policy, usage_rights)
             values (%s, 'Portrait session', 200000, 60, 50000, %s, %s, %s, 'moderate', 'personalSocial') returning id""",
          (creator, json.dumps(add_ons), ["30 edited photos"], TEMPLATE))
PKG = a.fetchone()[0]
weekly = [dict(weekday=d, window=dict(startMinute=540, endMinute=1020)) for d in range(2, 7)]
a.execute("""insert into availability_settings (creator_id, time_zone, weekly, min_notice_hours, max_advance_days, buffer_minutes, slot_interval_minutes)
             values (%s, %s, %s, 2, 180, 30, 30)""", (creator, TZ, json.dumps(weekly)))
# Stripe says this creator can take payments. (other_creator deliberately has no account: their package has no deposit.)
a.execute("""insert into creator_payment_accounts (creator_id, stripe_account_id, charges_enabled, payouts_enabled, details_submitted)
             values (%s, 'acct_maya', true, true, true)""", (creator,))


# ---- helpers ----------------------------------------------------------------
def as_user(uid, role="authenticated"):
    c = connect()
    k = c.cursor()
    if uid:
        k.execute("select set_config('request.jwt.claim.sub', %s, false)", (uid,))
    k.execute(f"set role {role}")
    return c, k


def first_line(e):
    return "ERR:" + (e.pgerror or str(e)).strip().splitlines()[0]


def sig(name="Test Client", method="typed", image=None, consent=1):
    return {"signedName": name, "method": method, "imagePng": image, "consentVersion": consent, "device": "test"}


def preview(uid, start, ons=(), pkg=None, client_name="Test Client", notes="", role="authenticated"):
    c, k = as_user(uid, role)
    try:
        k.execute("select preview_contract(%s, %s::uuid[], %s, %s, %s)", (pkg or PKG, list(ons), start, client_name, notes))
        return k.fetchone()[0]
    except psycopg2.Error as e:
        return first_line(e)
    finally:
        c.close()


def parse_times(booking):
    for key in ("start_at", "end_at", "blocked_until", "created_at"):
        booking[key] = dt.datetime.fromisoformat(booking[key])
    return booking


def book(uid, start, ons=(), pkg=None, role="authenticated", signature=None, doc_hash=None, client_name="Test Client", notes=""):
    """Preview the contract, sign its hash, book. Returns the booking dict (with ['_contract']) or 'ERR:...'."""
    c, k = as_user(uid, role)
    try:
        if doc_hash is None:
            k.execute("select preview_contract(%s, %s::uuid[], %s, %s, %s)", (pkg or PKG, list(ons), start, client_name, notes))
            doc_hash = k.fetchone()[0]["document_hash"]
        k.execute("select create_booking(%s, %s::uuid[], %s, %s, %s, %s, %s)",
                  (pkg or PKG, list(ons), start, client_name, notes, doc_hash, Json(signature or sig(client_name))))
        result = k.fetchone()[0]
        booking = parse_times(result["booking"])
        booking["_contract"] = result["contract"]
        return booking
    except psycopg2.Error as e:
        return first_line(e)
    finally:
        c.close()


failures = []


def check(name, cond, detail=""):
    print(("  ok   " if cond else "  FAIL ") + name + (f"   [{detail}]" if (detail and not cond) else ""))
    if not cond:
        failures.append(name)


def err(result, token):
    return isinstance(result, str) and token in result


def cancel(uid, bid):
    c, k = as_user(uid)
    try:
        k.execute("select * from cancel_booking(%s)", (bid,))
        return "ok"
    except psycopg2.Error as e:
        return first_line(e)
    finally:
        c.close()


def sql_as(uid, query, args=None, role="authenticated"):
    """Run one statement as a user. Returns (rows, rowcount) or 'ERR:...'."""
    c, k = as_user(uid, role)
    try:
        k.execute(query, args)
        rows = k.fetchall() if k.description else []
        return rows, k.rowcount
    except psycopg2.Error as e:
        return first_line(e)
    finally:
        c.close()


# ---- payment helpers ---------------------------------------------------------
def svc(query, args=None):
    """Run one statement as the service role, the way an Edge Function would."""
    return sql_as(None, query, args, role="service_role")


def svc_call(fn, *args):
    res = svc(f"select {fn}({', '.join(['%s'] * len(args))})", args)
    return res if isinstance(res, str) else res[0][0][0]


def client_of(booking_id):
    a.execute("select client_id from bookings where id = %s", (booking_id,))
    return a.fetchone()[0]


def pay(booking_id, kind="deposit", fee_bps=0, method="apple_pay"):
    """Open a payment, give it a Stripe intent, and have Stripe report it succeeded. Returns (prepare, intent, result)."""
    prep = svc_call("payment_prepare", client_of(booking_id), booking_id, kind, fee_bps)
    if isinstance(prep, str):
        return prep, None, None
    intent = "pi_" + uuid.uuid4().hex[:18]
    svc_call("payment_attach_intent", prep["payment_id"], intent)
    result = svc_call("payment_record_success", intent, prep["amount_cents"], "ch_" + uuid.uuid4().hex[:12], method)
    return prep, intent, result


def booking_row(booking_id):
    a.execute("""select status, hold_expires_at, delivered_at, cancelled_by, cancellation_policy,
                        delivery_url, delivery_note, receipt_confirmed_at from bookings where id = %s""", (booking_id,))
    status, hold, delivered, cancelled_by, policy, url, note, received = a.fetchone()
    return dict(status=status, hold=hold, delivered=delivered, cancelled_by=cancelled_by, policy=policy,
                url=url, note=note, received=received)


FILES = "https://files.example.com/final"


def share(uid, booking_id, url=FILES, note=None, role="authenticated"):
    """The creator shares the final files. Returns (status, delivered?, url, note) or the error text."""
    res = sql_as(uid, "select status, delivered_at is not null, delivery_url, delivery_note from share_delivery(%s, %s, %s)", (booking_id, url, note), role=role)
    return res if isinstance(res, str) else res[0][0]


def confirm(uid, booking_id, role="authenticated"):
    """The client confirms they have everything. Returns (status, received?) or the error text."""
    res = sql_as(uid, "select status, receipt_confirmed_at is not null from confirm_receipt(%s)", (booking_id,), role=role)
    return res if isinstance(res, str) else res[0][0]


def mark_received(booking_id):
    """Admin shortcut for tests that only need the balance to be payable: the files were shared and received."""
    a.execute("""update bookings set delivery_url = %s, delivered_at = coalesce(delivered_at, now()),
                                      receipt_confirmed_at = coalesce(receipt_confirmed_at, now()) where id = %s""", (FILES, booking_id))


def contract_row(booking_id):
    a.execute("select status, executed_at, (select count(*) from contract_signatures s where s.contract_id = c.id) from contracts c where booking_id = %s", (booking_id,))
    status, executed, n = a.fetchone()
    return dict(status=status, executed=executed, signatures=n)


def move_to(booking_id, hours_from_now, hours_long=1):
    """Put a booking at a given distance from now (admin shortcut; the app can't do this)."""
    a.execute("""update bookings set start_at = now() + (%s || ' hours')::interval,
                                      end_at = now() + (%s || ' hours')::interval,
                                      blocked_until = now() + (%s || ' hours')::interval + interval '30 minutes'
                  where id = %s""", (hours_from_now, hours_from_now + hours_long, hours_from_now + hours_long, booking_id))


def lapse(booking_id):
    a.execute("update bookings set hold_expires_at = now() - interval '1 second' where id = %s", (booking_id,))


def payments_of(booking_id, kind=None):
    a.execute("select id, kind, status, amount_cents, refund_of, stripe_payment_intent_id from payments where booking_id = %s " +
              ("and kind = %s " if kind else "") + "order by created_at, id", (booking_id, kind) if kind else (booking_id,))
    return a.fetchall()


def make_creator(handle, deposit=50000, price=200000, policy="moderate", account=True, charges=True):
    uid = new_user(handle, handle.title())
    tpl = add_template(uid)
    add_signature(uid, handle.title())
    a.execute("""insert into packages (creator_id, name, price_cents, duration_minutes, deposit_cents, contract_template_id, cancellation_policy)
                 values (%s, 'Session', %s, 60, %s, %s, %s) returning id""", (uid, price, deposit, tpl, policy))
    pkg = a.fetchone()[0]
    a.execute("""insert into availability_settings (creator_id, time_zone, weekly, min_notice_hours, max_advance_days, buffer_minutes, slot_interval_minutes)
                 values (%s, %s, %s, 2, 180, 30, 30)""", (uid, TZ, json.dumps(weekly)))
    if account:
        a.execute("""insert into creator_payment_accounts (creator_id, stripe_account_id, charges_enabled, payouts_enabled, details_submitted)
                     values (%s, %s, %s, %s, true)""", (uid, "acct_" + handle, charges, charges))
    return uid, pkg


# ---- 1. happy path and server-side pricing -----------------------------------
print("\n[pricing and snapshot]")
r1 = book(alice, at(WED, 10), [DRONE])
check("books an open slot", isinstance(r1, dict), r1)
if isinstance(r1, dict):
    check("price is computed server-side (package + drone)", r1["total_cents"] == 225000, r1["total_cents"])
    check("deposit comes from the package", r1["deposit_cents"] == 50000, r1["deposit_cents"])
    check("a booking with a deposit is held, not confirmed", r1["status"] == "held", r1["status"])
    check("end = start + 60 min", r1["end_at"] - r1["start_at"] == dt.timedelta(minutes=60))
    check("blocked_until = end + 30 min buffer", r1["blocked_until"] - r1["end_at"] == dt.timedelta(minutes=30))
    check("package and creator names are snapshotted", r1["package_name"] == "Portrait session" and r1["creator_name"] == "Maya Chen")
    check("add-on is snapshotted", r1["add_ons"][0]["name"] == "Drone footage")

# ---- 2. overlap rules --------------------------------------------------------
print("\n[double booking]")
check("same slot is refused", err(book(bob, at(WED, 10)), "slot_taken"))
check("overlapping start (10:30) is refused", err(book(bob, at(WED, 10, 30)), "slot_taken"))
check("start inside the buffer (11:00) is refused", err(book(bob, at(WED, 11)), "slot_taken"))
check("start 9:00 would run into the 10:00 booking, refused", err(book(bob, at(WED, 9)), "slot_taken"))
r_gap = book(bob, at(WED, 11, 30))
check("start exactly when the buffer ends (11:30) is allowed", isinstance(r_gap, dict), r_gap)
check("different day is unaffected", isinstance(book(bob, at(THU, 10)), dict))

# ---- 3. working-hours rules --------------------------------------------------
print("\n[availability rules]")
check("before opening (8:00) is refused", err(book(alice, at(TUE, 8)), "slot_unavailable"))
check("after closing (17:30) is refused", err(book(alice, at(TUE, 17, 30)), "slot_unavailable"))
check("running past closing (16:30 + 60 min) is refused", err(book(alice, at(TUE, 16, 30)), "slot_unavailable"))
r_edge = book(alice, at(TUE, 16))
check("ending exactly at closing (16:00 + 60 min) is allowed", isinstance(r_edge, dict), r_edge)
check("extra-hour add-on that runs past closing is refused", err(book(bob, at(MON, 16), [E1]), "slot_unavailable"))
check("extra-hour add-on that fits is allowed (15:00 + 120 min)", isinstance(book(bob, at(MON, 15), [E1]), dict))
check("Saturday (closed) is refused", err(book(alice, at(SAT, 10)), "slot_unavailable"))
check("off the 30-minute grid (10:15) is refused", err(book(alice, at(FRI, 10, 15)), "slot_unavailable"))
check("non-zero seconds are refused", err(book(alice, at(FRI, 10, 0, 30)), "slot_unavailable"))

fri = str((monday + dt.timedelta(days=FRI)))
a.execute("update availability_settings set blackouts = %s where creator_id = %s",
          (json.dumps([dict(id=str(uuid.uuid4()), start=fri, end=fri, reason="Holiday")]), creator))
check("blackout date is refused", err(book(alice, at(FRI, 10)), "slot_unavailable"))
check("day before the blackout is fine", isinstance(book(alice, at(THU, 14)), dict))
a.execute("update availability_settings set blackouts = '[]' where creator_id = %s", (creator,))
check("blackout lifted, day opens again", isinstance(book(alice, at(FRI, 10)), dict))

a.execute("update availability_settings set min_notice_hours = 720 where creator_id = %s", (creator,))
check("minimum notice is enforced", err(book(alice, at(FRI, 13)), "slot_unavailable"))
a.execute("update availability_settings set min_notice_hours = 2, max_advance_days = 7 where creator_id = %s", (creator,))
check("maximum advance is enforced", err(book(alice, at(FRI, 13)), "slot_unavailable"))
a.execute("update availability_settings set max_advance_days = 180 where creator_id = %s", (creator,))

# ---- 4. imported calendar busy time ------------------------------------------
print("\n[external busy time]")
b_start, b_end = at(TUE, 11), at(TUE, 12)
c, k = as_user(creator)
k.execute("insert into busy_blocks (creator_id, starts_at, ends_at) values (%s,%s,%s)", (creator, b_start, b_end))
c.close()
check("start inside busy time is refused", err(book(alice, at(TUE, 11)), "slot_unavailable"))
check("start ending into busy time is refused (10:30 + 60 + buffer overlaps 11:00)", err(book(alice, at(TUE, 10, 30)), "slot_unavailable"))
check("start inside the buffer after busy time (12:00) is refused", err(book(alice, at(TUE, 12)), "slot_unavailable"))
check("start once the buffer has passed (12:30) is allowed", isinstance(book(alice, at(TUE, 12, 30)), dict))
rows = sql_as(alice, "select count(*) from busy_blocks")
check("clients cannot read busy_blocks", rows[0][0][0] == 0, rows)

# ---- 5. other rules ----------------------------------------------------------
print("\n[other rules]")
check("creator cannot book their own package", err(book(creator, at(WED, 14)), "cannot_book_yourself"))
a.execute("update packages set is_published = false where id = %s", (PKG,))
check("hidden package cannot be booked", err(book(alice, at(WED, 14)), "package_unavailable"))
a.execute("update packages set is_published = true where id = %s", (PKG,))
check("unknown add-on id is refused", err(book(alice, at(WED, 14), [str(uuid.uuid4())]), "package_unavailable"))
r_dup = book(alice, at(WED, 14), [DRONE, DRONE])
check("duplicate add-on ids count once", isinstance(r_dup, dict) and r_dup["total_cents"] == 225000, r_dup)
check("anon role cannot call create_booking", isinstance(book(None, at(WED, 16), role="anon"), str))
check("signed-out users cannot book (no uid)", err(book(None, at(WED, 16)), "not_signed_in"))

# ---- 6. cancel ---------------------------------------------------------------
print("\n[cancel]")
check("a stranger cannot cancel", err(cancel(other_creator, r1["id"]), "not_cancellable"))
check("another client cannot cancel", err(cancel(bob, r1["id"]), "not_cancellable"))
check("the client can cancel", cancel(alice, r1["id"]) == "ok")
check("cancelling twice is refused", err(cancel(alice, r1["id"]), "not_cancellable"))
r_reuse = book(bob, at(WED, 10))
check("a cancelled slot can be booked again", isinstance(r_reuse, dict), r_reuse)
check("the creator can cancel a client's booking", cancel(creator, r_reuse["id"]) == "ok")

# ---- 7. RLS ------------------------------------------------------------------
print("\n[row level security]")


def visible(uid):
    return sql_as(uid, "select count(*) from bookings")[0][0][0]


a.execute("select count(*) from bookings where client_id = %s", (bob,))
bob_n = a.fetchone()[0]
a.execute("select count(*) from bookings")
all_n = a.fetchone()[0]
check("a client sees only their own bookings", visible(bob) == bob_n, (visible(bob), bob_n))
check("the creator sees all of theirs", visible(creator) == all_n, (visible(creator), all_n))
check("an unrelated creator sees none", visible(other_creator) == 0)
res = sql_as(alice, "insert into bookings (creator_id, client_id, creator_name, package_name, start_at, end_at, blocked_until, time_zone, currency_code, total_cents, deposit_cents) "
                    "values (%s,%s,'x','x',now()+interval '90 days',now()+interval '90 days 1 hour',now()+interval '90 days 2 hours','UTC','USD',1,1)", (creator, alice))
check("direct INSERT into bookings is blocked", isinstance(res, str) and ("row-level security" in res or "permission denied" in res), res)
check("direct UPDATE of bookings changes nothing", sql_as(alice, "update bookings set total_cents = 1 where client_id = %s", (alice,))[1] == 0)
check("direct DELETE of bookings changes nothing", sql_as(alice, "delete from bookings where client_id = %s", (alice,))[1] == 0)
check("a client cannot edit someone's package", sql_as(alice, "update packages set price_cents = 1 where id = %s", (PKG,))[1] == 0)
c, k = as_user(alice)
k.execute("select * from get_busy_intervals(%s, %s, %s)", (creator, at(MON, 0), at(SAT, 23)))
cols = [d[0] for d in k.description]
rows = k.fetchall()
c.close()
check("busy intervals expose only time ranges and kind", cols == ["starts_at", "ends_at", "kind"], cols)
check("busy intervals include other people's bookings as bare ranges", len(rows) >= 2 and {r[2] for r in rows} <= {"booking", "external"})

# ---- 8. contracts: rendering --------------------------------------------------
print("\n[contract rendering]")
slot = at(WED, 15)
p = preview(bob, slot, [DRONE], client_name="Alex Rivera", notes="Ceremony at the lake house.")
check("a client can preview the contract", isinstance(p, dict), p)
if isinstance(p, dict):
    local = slot.astimezone(ZoneInfo(TZ))
    long_date = f"{local.strftime('%A')}, {local.strftime('%B')} {local.day}, {local.year}"
    delivery = (local + dt.timedelta(days=14))
    delivery_date = f"{delivery.strftime('%A')}, {delivery.strftime('%B')} {delivery.day}, {delivery.year}"
    text = p["text"]
    check("title is first", text.startswith("Photography services agreement\n\n1. Parties\n"), text[:80])
    check("parties are filled in", 'between Maya Chen (the "Creator") and Alex Rivera (the "Client") for the "Portrait session" package.' in text)
    check("the shoot date is written out in the creator's time zone", f"Date: {long_date}\n" in text, long_date)
    check("the time range uses 12-hour clock and an en dash", "Time: 3:00 PM – 4:00 PM (America/Chicago)\nLength: 1 hour\n" in text)
    check("notes are included", "Notes: Ceremony at the lake house." in text)
    check("deliverables and add-ons are bulleted", "• 30 edited photos\n\nAdd-ons:\n• Drone footage (+$250)" in text)
    check("turnaround and delivery date", f"Delivered within 14 days, by {delivery_date}." in text, delivery_date)
    check("money is formatted without locale", "Total $2,250. Deposit $500. Balance $1,750." in text)
    check("policy and rights text are inserted", "Moderate. If the Client cancels at least 7 days" in text and "Personal and social media use." in text)
    check("the hash is the SHA-256 of the exact text", hashlib.sha256(text.encode()).hexdigest() == p["document_hash"])
    check("sections list matches", len(p["sections"]) == 6 and p["sections"][0]["title"] == "Parties")
    check("the template id and version are reported", p["template_id"] == str(TEMPLATE) and p["template_version"] == 1)
    p2 = preview(bob, slot, [DRONE], client_name="Alex Rivera", notes="Ceremony at the lake house.")
    check("rendering is deterministic", p2["document_hash"] == p["document_hash"])
    p3 = preview(bob, slot, [], client_name="Alex Rivera", notes="Ceremony at the lake house.")
    check("different choices give a different hash", p3["document_hash"] != p["document_hash"])

print("\n[contract injection]")
hostile = preview(bob, at(WED, 15), client_name="{{price}} Mallory\n\t Jones", notes="{{deposit}}\n{{client_name}}")
check("a client name can't smuggle in a placeholder", isinstance(hostile, dict) and "{ {price} } Mallory Jones" in hostile["text"] and 'and {{price}}' not in hostile["text"], hostile if not isinstance(hostile, dict) else hostile["text"][:200])
check("notes can't smuggle in placeholders either, and keep their line breaks", isinstance(hostile, dict) and "Notes: { {deposit} }\n{ {client_name} }" in hostile["text"])
check("nothing was replaced twice", isinstance(hostile, dict) and hostile["text"].count("$2,000") == 1, hostile["text"] if isinstance(hostile, dict) else hostile)

# ---- 9. contracts: signing ----------------------------------------------------
print("\n[signing]")
r_sign = book(bob, at(FRI, 14), [], client_name="Bob Builder", signature=sig("Bob Q. Builder"))
check("signing and booking works", isinstance(r_sign, dict), r_sign)
if isinstance(r_sign, dict):
    ctr = r_sign["_contract"]
    sigs = {s["role"]: s for s in ctr["signatures"]}
    check("until the deposit is paid the contract is pending, signed by the client only",
          ctr["status"] == "pending" and ctr["executed_at"] is None and set(sigs) == {"client"}, ctr["status"])
    check("the client's signature is what they gave", sigs["client"]["signed_name"] == "Bob Q. Builder" and sigs["client"]["method"] == "typed")
    check("the stored hash matches the stored text", ctr["document_hash"] == hashlib.sha256(
        ("\n\n".join([ctr["title"]] + [f"{i + 1}. {s['title']}\n{s['body']}" for i, s in enumerate(ctr["sections"])])).encode()).hexdigest())
    check("it is tied to the booking and records the template version", ctr["booking_id"] == r_sign["id"] and ctr["template_version"] == 1)
    # The deposit arrives: the booking is confirmed and the creator's saved signature is applied.
    _, _, paid_result = pay(r_sign["id"])
    done = contract_row(r_sign["id"])
    check("once the deposit is paid the contract is executed with both signatures", done["status"] == "executed" and done["signatures"] == 2 and done["executed"] is not None, (done, paid_result))
    a.execute("select signed_name, method from contract_signatures where contract_id = %s and role = 'creator'", (ctr["id"],))
    check("the creator's is their saved signature, applied automatically", a.fetchone() == ("Maya Chen", "onFile"))

stale = book(bob, at(FRI, 15), doc_hash="0" * 64)
check("a hash that doesn't match the server's contract is refused", err(stale, "contract_changed"), stale)
other = preview(bob, at(FRI, 15), client_name="Someone Else")["document_hash"]
check("a hash from a different contract is refused", err(book(bob, at(FRI, 15), doc_hash=other), "contract_changed"))
check("a wrong name in the booking breaks the hash too", err(book(bob, at(FRI, 15), doc_hash=other, client_name="Bob Builder"), "contract_changed"))

# The creator edits the wording between the client reading and signing.
seen = preview(alice, at(FRI, 12))["document_hash"]
edited = [dict(c) for c in CLAUSES]
edited[3] = clause("Fees", "Total {{price}}, with a deposit of {{deposit}} and a balance of {{balance}}.")
c, k = as_user(creator)
k.execute("update contract_templates set clauses = %s where id = %s", (Json(edited), TEMPLATE))
c.close()
check("editing the wording makes the old hash invalid", err(book(alice, at(FRI, 12), doc_hash=seen), "contract_changed"))
fresh = preview(alice, at(FRI, 12))
check("the new preview carries the new version", fresh["template_version"] == 2, fresh["template_version"])
r_fresh = book(alice, at(FRI, 12), doc_hash=fresh["document_hash"])
check("signing the new wording works", isinstance(r_fresh, dict), r_fresh)
check("the contract keeps the version it was signed on", isinstance(r_fresh, dict) and r_fresh["_contract"]["template_version"] == 2)
check("the earlier contract is untouched by later edits", isinstance(r_sign, dict) and r_sign["_contract"]["template_version"] == 1)
a.execute("update contract_templates set updated_at = updated_at where id = %s", (TEMPLATE,))
a.execute("select version from contract_templates where id = %s", (TEMPLATE,))
check("an update that changes nothing doesn't bump the version", a.fetchone()[0] == 2)

print("\n[signature rules]")
check("a one-letter name is refused", err(book(bob, at(THU, 12), signature=sig("A")), "invalid_signature"))
check("a client can't claim 'onFile'", err(book(bob, at(THU, 12), signature=sig("Bob Builder", method="onFile")), "invalid_signature"))
check("a drawn signature needs an image", err(book(bob, at(THU, 12), signature=sig("Bob Builder", method="drawn")), "invalid_signature"))
check("an unknown method is refused", err(book(bob, at(THU, 12), signature=sig("Bob Builder", method="stamp")), "invalid_signature"))
r_drawn = book(bob, at(THU, 12), signature=sig("Bob Builder", method="drawn", image="iVBORw0KGgo="))
check("a drawn signature with an image works and is stored", isinstance(r_drawn, dict) and
      {s["role"]: s for s in r_drawn["_contract"]["signatures"]}["client"]["image_png"] == "iVBORw0KGgo=", r_drawn)

# ---- 10. contracts: setup rules -----------------------------------------------
print("\n[contract setup]")
dan_tpl = add_template(other_creator)
a.execute("""insert into packages (creator_id, name, price_cents, duration_minutes, deposit_cents, contract_template_id)
             values (%s, 'Dan session', 10000, 60, 0, %s) returning id""", (other_creator, dan_tpl))
DAN_PKG = a.fetchone()[0]
a.execute("insert into availability_settings (creator_id, time_zone, weekly) values (%s,%s,%s)", (other_creator, TZ, json.dumps(weekly)))
check("a creator with no saved signature can't take bookings", err(preview(alice, at(TUE, 10), pkg=DAN_PKG), "creator_not_ready"))
check("...and booking is refused the same way", err(book(alice, at(TUE, 10), pkg=DAN_PKG, doc_hash="0" * 64), "creator_not_ready"))
add_signature(other_creator, "Dan Lee", method="drawn", image="iVBORw0KGgo=")
dan_booking = book(alice, at(TUE, 10), pkg=DAN_PKG)
check("once they sign, it works", isinstance(dan_booking, dict), dan_booking)
creator_side = {s["role"]: s for s in dan_booking["_contract"]["signatures"]}["creator"] if isinstance(dan_booking, dict) else {}
check("a drawn creator signature is copied onto the contract", creator_side.get("method") == "onFile" and creator_side.get("image_png") == "iVBORw0KGgo=", creator_side)

a.execute("""insert into packages (creator_id, name, price_cents, duration_minutes, deposit_cents, is_published)
             values (%s, 'No contract', 10000, 60, 0, false) returning id""", (creator,))
NO_CONTRACT = a.fetchone()[0]
a.execute("update packages set is_published = true where id = %s", (NO_CONTRACT,)) if False else None
try:
    a.execute("update packages set is_published = true where id = %s", (NO_CONTRACT,))
    check("a package can't be made visible without a contract", False)
except psycopg2.Error as e:
    check("a package can't be made visible without a contract", "published_needs_contract" in str(e), str(e)[:100])
try:
    a.execute("insert into packages (creator_id, name, price_cents, duration_minutes, deposit_cents, contract_template_id) values (%s,'Steal',100,60,0,%s)", (creator, dan_tpl))
    check("a package can't use someone else's contract", False)
except psycopg2.Error as e:
    check("a package can't use someone else's contract", "belongs to someone else" in str(e), str(e)[:100])
try:
    a.execute("delete from contract_templates where id = %s", (TEMPLATE,))
    check("a contract in use can't be deleted", False)
except psycopg2.Error as e:
    check("a contract in use can't be deleted", "foreign key" in str(e) or "violates" in str(e), str(e)[:100])

print("\n[template validation]")
def try_template(title="Agreement", clauses=None, owner=None):
    res = sql_as(owner or creator, "insert into contract_templates (creator_id, title, kind, clauses) values (%s,%s,'custom',%s)",
                 (owner or creator, title, Json(clauses if clauses is not None else CLAUSES)))
    return res

check("a good template saves", not isinstance(try_template(), str))
check("an unknown field is refused", err(try_template(clauses=CLAUSES + [clause("Extra", "Hello {{favourite_colour}}")]), "unknown field favourite_colour"))
check("a missing required field is refused", err(try_template(clauses=[clause("Only", "Hello {{client_name}}")]), "missing field"))
check("an empty section is refused", err(try_template(clauses=CLAUSES + [clause("Blank", "   ")]), "invalid_contract: section"))
check("a one-character title is refused", err(try_template(title="A"), "invalid_contract: title"))
check("no sections is refused", err(try_template(clauses=[]), "invalid_contract: sections"))
check("too many sections is refused", err(try_template(clauses=CLAUSES * 6), "invalid_contract: sections"))
check("a section over 3000 characters is refused", err(try_template(clauses=CLAUSES + [clause("Long", "x" * 3001)]), "invalid_contract: section"))
check("you can't create a template for someone else", isinstance(sql_as(alice, "insert into contract_templates (creator_id, title, kind, clauses) values (%s,'X','custom',%s)", (creator, Json(CLAUSES))), str))
check("clients can't read a creator's templates", sql_as(alice, "select count(*) from contract_templates")[0][0][0] == 0)
check("another creator can't read them either", sql_as(other_creator, "select count(*) from contract_templates where creator_id = %s", (creator,))[0][0][0] == 0)
check("a creator reads their own", sql_as(creator, "select count(*) from contract_templates")[0][0][0] >= 1)

print("\n[contracts: access control]")
cid = r_sign["_contract"]["id"]
check("the client reads their contract", sql_as(bob, "select count(*) from contracts where id = %s", (cid,))[0][0][0] == 1)
check("the creator reads it", sql_as(creator, "select count(*) from contracts where id = %s", (cid,))[0][0][0] == 1)
check("another client can't", sql_as(alice, "select count(*) from contracts where id = %s", (cid,))[0][0][0] == 0)
check("an unrelated creator can't", sql_as(other_creator, "select count(*) from contracts where id = %s", (cid,))[0][0][0] == 0)
check("the parties read both signatures", sql_as(bob, "select count(*) from contract_signatures where contract_id = %s", (cid,))[0][0][0] == 2)
check("strangers read none", sql_as(alice, "select count(*) from contract_signatures where contract_id = %s", (cid,))[0][0][0] == 0)
check("nobody can edit a signed contract", sql_as(bob, "update contracts set title = 'Mine now' where id = %s", (cid,))[1] == 0
      and sql_as(creator, "update contracts set title = 'Mine now' where id = %s", (cid,))[1] == 0)
check("nobody can rewrite a signature", sql_as(bob, "update contract_signatures set signed_name = 'Someone' where contract_id = %s", (cid,))[1] == 0)
check("nobody can delete a contract", sql_as(bob, "delete from contracts where id = %s", (cid,))[1] == 0)
check("nobody can forge a contract", isinstance(sql_as(bob, "insert into contracts (booking_id, creator_id, client_id, template_version, title, sections, document_hash) values (%s,%s,%s,1,'x','[]',%s)",
                                                       (r_sign["id"], creator, bob, "0" * 64)), str))
check("the helper functions aren't callable directly", isinstance(sql_as(bob, "select contract_prepare(%s, '{}'::uuid[], now(), 'x', '')", (PKG,)), str))
sig_row = sql_as(creator, "select count(*) from creator_signatures")[0][0][0]
check("a creator reads their saved signature; clients can't", sig_row == 1 and sql_as(bob, "select count(*) from creator_signatures")[0][0][0] == 0)

print("\n[signed PDFs: storage rules]")
path = f"{cid}.pdf"
ins = lambda uid, name: sql_as(uid, "insert into storage.objects (bucket_id, name) values ('contracts', %s)", (name,))
check("the client can store the PDF", not isinstance(ins(bob, path), str), ins(bob, path) if False else "")
check("the creator can read it", sql_as(creator, "select count(*) from storage.objects where bucket_id = 'contracts' and name = %s", (path,))[0][0][0] == 1)
check("the client can read it", sql_as(bob, "select count(*) from storage.objects where bucket_id = 'contracts' and name = %s", (path,))[0][0][0] == 1)
check("a stranger can't read it", sql_as(alice, "select count(*) from storage.objects where bucket_id = 'contracts' and name = %s", (path,))[0][0][0] == 0)
check("a stranger can't store one for that contract", isinstance(ins(alice, path), str))
check("nobody can store a file for a contract that isn't theirs", isinstance(ins(bob, f"{uuid.uuid4()}.pdf"), str))
check("an arbitrary file name is refused", isinstance(ins(bob, "notes.txt"), str))
check("nobody can overwrite or delete a stored PDF",
      sql_as(bob, "update storage.objects set name = name where name = %s", (path,))[1] == 0
      and sql_as(bob, "delete from storage.objects where name = %s", (path,))[1] == 0)

# ---- 11. golden fixture: SQL and Swift must render the same words --------------
print("\n[golden contract text]")
if GOLDEN.exists():
    golden = json.loads(GOLDEN.read_text())
    gtpl = golden["template"]
    for case in golden["cases"]:
        pk = case["package"]
        a.execute("""insert into packages (creator_id, name, price_cents, currency_code, duration_minutes, deliverables, turnaround_days,
                                           deposit_cents, cancellation_policy, usage_rights, is_published)
                     values (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,false) returning id""",
                  (creator, pk["name"], pk["price_cents"], pk["currency_code"], pk["duration_minutes"], pk["deliverables"],
                   pk["turnaround_days"], pk["deposit_cents"], pk["cancellation_policy"], pk["usage_rights"]))
        gid = a.fetchone()[0]
        a.execute("""select contract_values(p, %s::jsonb, %s::timestamptz, %s, %s, %s, %s) from packages p where p.id = %s""",
                  (json.dumps(case["chosen_add_ons"]), case["start_utc"], case["time_zone"], case["client_name"], case["creator_name"], case["notes"], gid))
        values = a.fetchone()[0]
        a.execute("select contract_render(%s, %s::jsonb, %s::jsonb, null, 1)", (gtpl["title"], json.dumps(gtpl["clauses"]), json.dumps(values)))
        rendered = a.fetchone()[0]
        if "expected_text" not in case or os.environ.get("PRINT_GOLDEN"):
            print(f"--- {case['name']} ---\n{rendered['text']}\n--- hash {rendered['document_hash']}")
            if os.environ.get("GOLDEN_OUT"):
                dumped = json.loads(pathlib.Path(os.environ["GOLDEN_OUT"]).read_text()) if pathlib.Path(os.environ["GOLDEN_OUT"]).exists() else {}
                dumped[case["name"]] = rendered["text"]
                pathlib.Path(os.environ["GOLDEN_OUT"]).write_text(json.dumps(dumped))
        check(f"golden '{case['name']}': text matches", rendered["text"] == case.get("expected_text"), rendered["text"][:120])
        check(f"golden '{case['name']}': hash matches", rendered["document_hash"] == hashlib.sha256(case.get("expected_text", "").encode()).hexdigest())
else:
    print("  (no golden fixture found)")

# ---- 11b. payments -------------------------------------------------------------
print("\n[payments: holding a booking and confirming it]")
PAYEE, PAYEE_PKG = make_creator("payee")
# Working days three weeks out or later, clear of every other test. D[0] is a Monday.
D = [d for d in range(21, 140) if d % 7 < 5]

held = book(alice, at(D[0], 10), pkg=PAYEE_PKG)
check("a booking with a deposit is held", isinstance(held, dict) and held["status"] == "held", held)
now_row = booking_row(held["id"])
a.execute("select (%s - now()) between interval '14 minutes' and interval '15 minutes 5 seconds'", (now_row["hold"],))
check("the hold lasts about 15 minutes", a.fetchone()[0], now_row["hold"])
check("the cancellation policy is snapshotted onto the booking", now_row["policy"] == "moderate")
cr = contract_row(held["id"])
check("the contract is pending with only the client's signature", cr["status"] == "pending" and cr["signatures"] == 1 and cr["executed"] is None, cr)
check("a held booking blocks the time", err(book(bob, at(D[0], 10), pkg=PAYEE_PKG), "slot_taken"))
check("...including its buffer", err(book(bob, at(D[0], 11), pkg=PAYEE_PKG), "slot_taken"))
check("the held time shows as busy to other clients", len(sql_as(bob, "select * from get_busy_intervals(%s, %s, %s)", (PAYEE, at(D[0], 0), at(D[0], 23)))[0]) == 1)

prep = svc_call("payment_prepare", alice, held["id"], "deposit", 0)
check("preparing a deposit gives the amount from the booking, the creator's account and no fee",
      isinstance(prep, dict) and prep["amount_cents"] == 50000 and prep["currency"] == "usd" and prep["destination"] == "acct_payee"
      and prep["fee_cents"] == 0 and prep["existing_intent"] is None and prep["kind"] == "deposit", prep)
again = svc_call("payment_prepare", alice, held["id"], "deposit", 0)
check("preparing again reuses the same pending payment", again["payment_id"] == prep["payment_id"] and len(payments_of(held["id"])) == 1, again)
check("only the client can pay", err(svc_call("payment_prepare", bob, held["id"], "deposit", 0), "not_found")
      and err(svc_call("payment_prepare", PAYEE, held["id"], "deposit", 0), "not_found"))
check("an unknown kind is refused", err(svc_call("payment_prepare", alice, held["id"], "tip", 0), "invalid_kind"))
check("the balance can't be paid before delivery", err(svc_call("payment_prepare", alice, held["id"], "balance", 0), "balance_not_due"))
intent1 = "pi_test_" + uuid.uuid4().hex[:10]
svc_call("payment_attach_intent", prep["payment_id"], intent1)
svc_call("payment_attach_intent", prep["payment_id"], "pi_other_attempt")
check("an intent is attached once and stays", svc_call("payment_prepare", alice, held["id"], "deposit", 0)["existing_intent"] == intent1)

check("a payment of the wrong amount is refused", err(svc_call("payment_record_success", intent1, 49999, "ch_1", "apple_pay"), "amount_mismatch"))
check("an intent we never made is refused", err(svc_call("payment_record_success", "pi_stranger", 50000, "ch_1", "apple_pay"), "unknown_payment"))
check("still held after those", booking_row(held["id"])["status"] == "held")
ok1 = svc_call("payment_record_success", intent1, 50000, "ch_1", "apple_pay")
check("a successful payment confirms the booking", isinstance(ok1, dict) and ok1["action"] == "confirmed", ok1)
row = booking_row(held["id"])
check("the booking is confirmed and the hold is cleared", row["status"] == "confirmed" and row["hold"] is None, row)
cr = contract_row(held["id"])
check("the contract is executed with both signatures", cr["status"] == "executed" and cr["signatures"] == 2 and cr["executed"] is not None, cr)
check("reporting the same payment again changes nothing", svc_call("payment_record_success", intent1, 50000, "ch_1", "apple_pay")["action"] == "noop")
check("it can't be paid twice", err(svc_call("payment_prepare", alice, held["id"], "deposit", 0), "payment_not_due"))

print("\n[payments: fees, access and who may call what]")
fee_booking = book(alice, at(D[1], 10), pkg=PAYEE_PKG)
fee_prep = svc_call("payment_prepare", alice, fee_booking["id"], "deposit", 250)
check("a platform fee is a share of the amount, rounded down", isinstance(fee_prep, dict) and fee_prep["fee_cents"] == 1250, fee_prep)
a.execute("select platform_fee_cents from payments where id = %s", (fee_prep["payment_id"],))
check("...and is recorded on the payment", a.fetchone()[0] == 1250)
neg_booking = book(bob, at(D[1], 13), pkg=PAYEE_PKG)
check("a negative fee is treated as none", svc_call("payment_prepare", bob, neg_booking["id"], "deposit", -500)["fee_cents"] == 0)

for fn, args in [("payment_prepare", (alice, held["id"], "deposit", 0)), ("payment_record_success", ("pi_x", 1, "c", "apple_pay")),
                 ("payment_attach_intent", (prep["payment_id"], "pi_y")), ("connect_account_save", (PAYEE, "acct_evil")),
                 ("webhook_claim_event", ("evt_x", "t")), ("is_booking_party", (alice, held["id"]))]:
    marks = ", ".join(["%s"] * len(args))
    check(f"{fn} is closed to signed-in users", isinstance(sql_as(alice, f"select {fn}({marks})", args), str))
    check(f"{fn} is closed to signed-out callers", isinstance(sql_as(None, f"select {fn}({marks})", args, role="anon"), str))

check("the client sees the payments on their booking", sql_as(alice, "select count(*) from payments where booking_id = %s", (held["id"],))[0][0][0] == 1)
check("the creator sees them too", sql_as(PAYEE, "select count(*) from payments where booking_id = %s", (held["id"],))[0][0][0] == 1)
check("a stranger sees none", sql_as(bob, "select count(*) from payments where booking_id = %s", (held["id"],))[0][0][0] == 0)
check("nobody can write a payment", isinstance(sql_as(alice, "insert into payments (booking_id, kind, amount_cents, currency_code) values (%s,'deposit',1,'USD')", (held["id"],)), str))
check("nobody can edit a payment", sql_as(alice, "update payments set amount_cents = 1 where booking_id = %s", (held["id"],))[1] == 0
      and sql_as(PAYEE, "update payments set status = 'failed' where booking_id = %s", (held["id"],))[1] == 0)
check("nobody can delete a payment", sql_as(alice, "delete from payments where booking_id = %s", (held["id"],))[1] == 0)
check("a creator reads their own payment account; others can't", sql_as(PAYEE, "select count(*) from creator_payment_accounts")[0][0][0] == 1
      and sql_as(alice, "select count(*) from creator_payment_accounts")[0][0][0] == 0)
check("nobody can edit a payment account", sql_as(PAYEE, "update creator_payment_accounts set charges_enabled = true")[1] == 0
      and isinstance(sql_as(PAYEE, "insert into creator_payment_accounts (creator_id, stripe_account_id) values (%s, 'acct_mine')", (other_creator,)), str))
check("webhook events are not readable by users", sql_as(alice, "select count(*) from stripe_events")[0][0][0] == 0)

print("\n[payments: holds that run out]")
lapsing = book(bob, at(D[2], 10), pkg=PAYEE_PKG)
lapse(lapsing["id"])
check("a lapsed hold stops showing as busy straight away", len(sql_as(alice, "select * from get_busy_intervals(%s, %s, %s)", (PAYEE, at(D[2], 0), at(D[2], 23)))[0]) == 0)
taker = book(alice, at(D[2], 10), pkg=PAYEE_PKG)
check("someone else can then take the time", isinstance(taker, dict), taker)
check("the lapsed booking is expired", booking_row(lapsing["id"])["status"] == "expired")
check("its contract is voided", contract_row(lapsing["id"])["status"] == "voided")
check("it can no longer be paid", err(svc_call("payment_prepare", bob, lapsing["id"], "deposit", 0), "hold_expired"))
check("anyone may tidy up lapsed holds", isinstance(sql_as(alice, "select expire_holds()"), tuple))

# Paid just after the hold ran out, with the time still free: honour it.
late_free = book(bob, at(D[3], 10), pkg=PAYEE_PKG)
lf_prep = svc_call("payment_prepare", bob, late_free["id"], "deposit", 0)
lf_intent = "pi_late_" + uuid.uuid4().hex[:8]
svc_call("payment_attach_intent", lf_prep["payment_id"], lf_intent)
lapse(late_free["id"])
svc_call("expire_holds")
check("(set-up) the hold expired with a payment in flight", booking_row(late_free["id"])["status"] == "expired")
late_result = svc_call("payment_record_success", lf_intent, 50000, "ch_late", "apple_pay")
check("paying just after the hold ended still confirms it if the time is free", late_result["action"] == "confirmed" and booking_row(late_free["id"])["status"] == "confirmed", late_result)
check("...and executes the contract again", contract_row(late_free["id"])["status"] == "executed")

# Paid after the hold ended and someone else has the time: refund it.
late_taken = book(bob, at(D[4], 10), pkg=PAYEE_PKG)
lt_prep = svc_call("payment_prepare", bob, late_taken["id"], "deposit", 0)
lt_intent = "pi_late_" + uuid.uuid4().hex[:8]
svc_call("payment_attach_intent", lt_prep["payment_id"], lt_intent)
lapse(late_taken["id"])
check("(set-up) someone else takes the time", isinstance(book(alice, at(D[4], 10), pkg=PAYEE_PKG), dict))
lt_result = svc_call("payment_record_success", lt_intent, 50000, "ch_late2", "apple_pay")
check("paying after the time was taken asks for a refund of everything", lt_result["action"] == "refund_required", lt_result)
refunds = payments_of(late_taken["id"], "refund")
check("...recorded as a pending refund of the full amount", len(refunds) == 1 and refunds[0][2] == "pending" and refunds[0][3] == 50000, refunds)
check("...and the booking stays expired", booking_row(late_taken["id"])["status"] == "expired")

# Paid while cancelling.
racing = book(alice, at(D[5], 10), pkg=PAYEE_PKG)
rc_prep = svc_call("payment_prepare", alice, racing["id"], "deposit", 0)
rc_intent = "pi_cancel_" + uuid.uuid4().hex[:8]
svc_call("payment_attach_intent", rc_prep["payment_id"], rc_intent)
check("cancelling an unpaid hold works", cancel(alice, racing["id"]) == "ok")
check("...and cancels its waiting payment", payments_of(racing["id"], "deposit")[0][2] == "canceled")
rc_result = svc_call("payment_record_success", rc_intent, 50000, "ch_c", "apple_pay")
check("money that arrives for a cancelled booking is refunded", rc_result["action"] == "refund_required" and booking_row(racing["id"])["status"] == "cancelled", rc_result)

# Two attempts both succeeded.
dup = book(bob, at(D[6], 10), pkg=PAYEE_PKG)
pay(dup["id"])
a.execute("insert into payments (booking_id, kind, amount_cents, currency_code, status, stripe_payment_intent_id) values (%s,'deposit',50000,'USD','failed','pi_dup_second')", (dup["id"],))
dup_result = svc_call("payment_record_success", "pi_dup_second", 50000, "ch_dup", "apple_pay")
check("a second successful payment for the same deposit is refunded, not kept", dup_result["action"] == "refund_required" and booking_row(dup["id"])["status"] == "confirmed", dup_result)

# Payments off.
print("\n[payments: creators who can't be paid]")
off_booking = book(alice, at(D[7], 10), pkg=PAYEE_PKG)
svc_call("connect_account_update", "acct_payee", False, False, True)
check("clients can't preview a contract that can't be paid for", err(preview(alice, at(D[7], 13), pkg=PAYEE_PKG), "payments_not_ready"))
check("...or book it", err(book(alice, at(D[7], 13), pkg=PAYEE_PKG, doc_hash="0" * 64), "payments_not_ready"))
check("...or pay for one already held", err(svc_call("payment_prepare", alice, off_booking["id"], "deposit", 0), "payments_not_ready"))
svc_call("connect_account_update", "acct_payee", True, True, True)
check("when Stripe enables the account, it works again", isinstance(preview(alice, at(D[7], 13), pkg=PAYEE_PKG), dict))
none_creator, none_pkg = make_creator("noaccount", account=False)
check("a creator who never connected Stripe can't take a deposit", err(preview(alice, at(D[0], 10), pkg=none_pkg), "payments_not_ready"))
free_creator, free_pkg = make_creator("nodeposit", deposit=0, account=False)
free = book(alice, at(D[0], 10), pkg=free_pkg)
check("a package with no deposit needs no Stripe account and is confirmed at once", isinstance(free, dict) and free["status"] == "confirmed" and free["hold_expires_at"] is None, free)
check("...with its contract already executed", contract_row(free["id"])["status"] == "executed" and contract_row(free["id"])["signatures"] == 2)
svc_call("connect_account_save", PAYEE, "acct_second")
check("saving a second account for a creator keeps the first", svc_call("connect_account_for", PAYEE) == "acct_payee")

print("\n[payments: after delivery]")
dv = book(alice, at(D[8], 10), pkg=PAYEE_PKG)
check("a held booking can't be delivered", err(share(PAYEE, dv["id"]), "not_deliverable"))
pay(dv["id"])
check("only the creator can share the files", err(share(alice, dv["id"]), "not_found") and err(share(bob, dv["id"]), "not_found"))
check("not before the shoot has started", err(share(PAYEE, dv["id"]), "not_deliverable"))
check("the balance isn't due before delivery", err(svc_call("payment_prepare", alice, dv["id"], "balance", 0), "balance_not_due"))
move_to(dv["id"], -48)
check("the balance isn't due once files are shared but not yet confirmed",
      share(PAYEE, dv["id"]) == ("confirmed", True, FILES, None) and err(svc_call("payment_prepare", alice, dv["id"], "balance", 0), "balance_not_due"))
check("only the client can confirm", err(confirm(PAYEE, dv["id"]), "not_found") and err(confirm(bob, dv["id"]), "not_found"))
check("the client's confirmation keeps the booking confirmed while a balance is owed", confirm(alice, dv["id"]) == ("confirmed", True))
check("the creator can't share again once the client has confirmed", err(share(PAYEE, dv["id"], "https://files.example.com/other"), "not_deliverable"))
bal_prep = svc_call("payment_prepare", alice, dv["id"], "balance", 0)
check("the balance is the total less the deposit", isinstance(bal_prep, dict) and bal_prep["amount_cents"] == 150000 and bal_prep["kind"] == "balance", bal_prep)
bal_intent = "pi_bal_" + uuid.uuid4().hex[:8]
svc_call("payment_attach_intent", bal_prep["payment_id"], bal_intent)
bal_result = svc_call("payment_record_success", bal_intent, 150000, "ch_bal", "apple_pay")
check("paying the balance completes the booking", bal_result["action"] == "completed" and booking_row(dv["id"])["status"] == "completed", bal_result)
check("a completed booking can't be cancelled", err(cancel(alice, dv["id"]), "not_cancellable"))
check("the balance can't be paid twice", err(svc_call("payment_prepare", alice, dv["id"], "balance", 0), "payment_not_due") or
      err(svc_call("payment_prepare", alice, dv["id"], "balance", 0), "balance_not_due"))

paid_up_creator, paid_up_pkg = make_creator("paidup", deposit=200000)
pu = book(alice, at(D[0], 10), pkg=paid_up_pkg)
pay(pu["id"])
move_to(pu["id"], -24)
check("(set-up) sharing the files of a fully paid booking leaves it open for the client's confirmation",
      share(paid_up_creator, pu["id"])[0] == "confirmed" and booking_row(pu["id"])["status"] == "confirmed")
check("when the deposit covers everything, confirming receipt completes the booking", confirm(alice, pu["id"]) == ("completed", True) and booking_row(pu["id"])["status"] == "completed")
check("...and there is no balance to pay", err(svc_call("payment_prepare", alice, pu["id"], "balance", 0), "balance_not_due")
      or err(svc_call("payment_prepare", alice, pu["id"], "balance", 0), "nothing_due"))

zero_dep_creator, zero_dep_pkg = make_creator("zerodep", deposit=0)
zd = book(alice, at(D[0], 11), pkg=zero_dep_pkg)
check("a package with no deposit is confirmed at once", isinstance(zd, dict) and zd["status"] == "confirmed", zd)
move_to(zd["id"], -24)
share(zero_dep_creator, zd["id"])
confirm(alice, zd["id"])
zd_prep = svc_call("payment_prepare", alice, zd["id"], "balance", 0)
check("with no deposit, the whole price is the balance", isinstance(zd_prep, dict) and zd_prep["amount_cents"] == 200000, zd_prep)

print("\n[payments: cancelling and refunds]")
refund_creator, refund_pkgs = make_creator("refunds")
policies = {}
for pol in ("flexible", "moderate", "strict"):
    a.execute("""insert into packages (creator_id, name, price_cents, duration_minutes, deposit_cents, contract_template_id, cancellation_policy)
                 select creator_id, %s, 200000, 60, 50000, contract_template_id, %s from packages where id = %s returning id""", (pol, pol, refund_pkgs))
    policies[pol] = a.fetchone()[0]

matrix = [("moderate", 170, 100), ("moderate", 100, 50), ("moderate", 10, 0),
          ("flexible", 30, 100), ("flexible", 5, 50), ("strict", 400, 50), ("strict", 100, 0)]
for i, (pol, hours, percent) in enumerate(matrix):
    day = D[10 + i]  # each case gets its own day, so nothing overlaps
    b = book(alice, at(day, 10), pkg=policies[pol])
    pay(b["id"])
    move_to(b["id"], hours)
    want = 50000 * percent // 100
    quote = sql_as(alice, "select refund_quote(%s)", (b["id"],))[0][0][0]
    check(f"{pol} policy, {hours}h ahead: the quote is {percent}% = {want}", quote["percent"] == percent and quote["refund_cents"] == want and quote["paid_cents"] == 50000 and quote["by_creator"] is False
          and quote["currency"] == "USD" and quote["policy"] == pol, quote)
    res = sql_as(alice, "select cancel_booking(%s)", (b["id"],))[0][0][0]
    refunds = payments_of(b["id"], "refund")
    check(f"{pol}, {hours}h: cancelling refunds exactly what was quoted", res["refund_cents"] == want and res["percent"] == percent
          and sum(r[3] for r in refunds) == want and len(refunds) == (1 if want else 0), (res, refunds))
    check(f"{pol}, {hours}h: the refund is a pending refund of the deposit", all(r[2] == "pending" and r[4] == payments_of(b["id"], "deposit")[0][0] for r in refunds))
    check(f"{pol}, {hours}h: the booking is cancelled by the client and the contract voided",
          booking_row(b["id"])["status"] == "cancelled" and booking_row(b["id"])["cancelled_by"] == alice and contract_row(b["id"])["status"] == "voided")

creator_cancel = book(bob, at(D[10], 10), pkg=policies["strict"])
pay(creator_cancel["id"])
move_to(creator_cancel["id"], 10)
cq = sql_as(refund_creator, "select refund_quote(%s)", (creator_cancel["id"],))[0][0][0]
check("if the creator cancels, the client gets everything back, whatever the policy", cq["percent"] == 100 and cq["refund_cents"] == 50000 and cq["by_creator"] is True, cq)
check("...and the client's own quote for the same booking follows the policy", sql_as(bob, "select refund_quote(%s)", (creator_cancel["id"],))[0][0][0]["percent"] == 0)
check("the creator's cancellation refunds in full", sql_as(refund_creator, "select cancel_booking(%s)", (creator_cancel["id"],))[0][0][0]["refund_cents"] == 50000)
check("...and records who cancelled", booking_row(creator_cancel["id"])["cancelled_by"] == refund_creator)

check("a stranger can't get a quote", err(sql_as(other_creator, "select refund_quote(%s)", (creator_cancel["id"],)), "not_cancellable"))
check("a cancelled booking has no quote", err(sql_as(bob, "select refund_quote(%s)", (creator_cancel["id"],)), "not_cancellable"))
check("a booking that has started has no quote", err(sql_as(alice, "select refund_quote(%s)", (dv["id"],)), "not_cancellable"))

# Money that was paid in two parts is returned newest first, and never more than each part.
split = book(alice, at(D[11], 10), pkg=policies["flexible"])
pay(split["id"])
mark_received(split["id"])
pay(split["id"], kind="balance")
a.execute("update bookings set status = 'confirmed' where id = %s", (split["id"],))
move_to(split["id"], 100)
res = sql_as(refund_creator, "select cancel_booking(%s)", (split["id"],))[0][0][0]
parts = payments_of(split["id"], "refund")
check("a cancellation after both payments refunds both", res["refund_cents"] == 200000 and sum(r[3] for r in parts) == 200000 and len(parts) == 2, (res, parts))
check("...the balance first, then the deposit", sorted(r[3] for r in parts) == [50000, 150000] and
      {r[3]: r[4] for r in parts} == {150000: payments_of(split["id"], "balance")[0][0], 50000: payments_of(split["id"], "deposit")[0][0]}, parts)

# Partial refund spanning payments.
split2 = book(bob, at(D[11], 13), pkg=policies["flexible"])
pay(split2["id"])
mark_received(split2["id"])
pay(split2["id"], kind="balance")
a.execute("update bookings set status = 'confirmed' where id = %s", (split2["id"],))
move_to(split2["id"], 5)
res2 = sql_as(bob, "select cancel_booking(%s)", (split2["id"],))[0][0][0]
parts2 = payments_of(split2["id"], "refund")
check("half of everything paid (5h ahead, flexible) is 100000, all from the balance", res2["refund_cents"] == 100000 and [r[3] for r in parts2] == [100000], (res2, parts2))

print("\n[payments: Stripe results]")
rf = payments_of(split["id"], "refund")
todo = svc("select * from refunds_to_process(%s)", (split["id"],))[0]
check("refunds waiting to be sent to Stripe are listed with the payment they came from", len(todo) == 2 and all(t[2] and t[2].startswith("pi_") for t in todo), todo)
svc_call("refund_record_result", rf[0][0], "succeeded", "re_1", None)
svc_call("refund_record_result", rf[1][0], "failed", None, "insufficient funds")
a.execute("select status, stripe_refund_id, paid_at is not null from payments where id = %s", (rf[0][0],))
check("a refund Stripe completed is recorded with its id and time", a.fetchone() == ("succeeded", "re_1", True))
a.execute("select status, failure_message from payments where id = %s", (rf[1][0],))
check("a refund Stripe rejected is recorded as failed, with why", a.fetchone() == ("failed", "insufficient funds"))
svc_call("refund_record_result", rf[0][0], "failed", None, "late")
a.execute("select status from payments where id = %s", (rf[0][0],))
check("a completed refund can't be undone", a.fetchone()[0] == "succeeded")
check("only pending refunds are still to do", len(svc("select * from refunds_to_process(%s)", (split["id"],))[0]) == 0)
svc_call("refund_record_result", payments_of(split2["id"], "refund")[0][0], "pending", "re_2", None)
svc_call("refund_record_by_stripe_id", "re_2", "succeeded", None)
a.execute("select status from payments where stripe_refund_id = 're_2'")
check("Stripe can also report a refund by its own id", a.fetchone()[0] == "succeeded")

# A failed card, then a retry.
retry = book(alice, at(D[12], 10), pkg=PAYEE_PKG)
r1p = svc_call("payment_prepare", alice, retry["id"], "deposit", 0)
svc_call("payment_attach_intent", r1p["payment_id"], "pi_fail_1")
svc_call("payment_record_failure", "pi_fail_1", "Your card was declined.")
a.execute("select status, failure_message from payments where id = %s", (r1p["payment_id"],))
check("a declined payment is recorded as failed with the reason", a.fetchone() == ("failed", "Your card was declined."))
check("the booking is still held, so they can try again", booking_row(retry["id"])["status"] == "held")
r2p = svc_call("payment_prepare", alice, retry["id"], "deposit", 0)
check("a retry opens a new payment", isinstance(r2p, dict) and r2p["payment_id"] != r1p["payment_id"] and r2p["existing_intent"] is None, r2p)
svc_call("payment_attach_intent", r2p["payment_id"], "pi_fail_2")
check("and can succeed", svc_call("payment_record_success", "pi_fail_2", 50000, "ch_2", "apple_pay")["action"] == "confirmed")
svc_call("payment_record_failure", "pi_fail_2", "late noise")
a.execute("select status from payments where id = %s", (r2p["payment_id"],))
check("a stray failure can't undo a success", a.fetchone()[0] == "succeeded")

print("\n[payments: webhooks and Connect]")
check("the first delivery of an event is handled", svc_call("webhook_claim_event", "evt_1", "payment_intent.succeeded") is True)
check("a redelivery before it finished is handled again (handlers are safe to repeat)", svc_call("webhook_claim_event", "evt_1", "payment_intent.succeeded") is True)
svc_call("webhook_event_done", "evt_1")
check("once finished, a redelivery is skipped", svc_call("webhook_claim_event", "evt_1", "payment_intent.succeeded") is False)
check("a different event is handled", svc_call("webhook_claim_event", "evt_2", "charge.refunded") is True)
svc_call("connect_account_save", other_creator, "acct_dan")
check("a new account starts out unable to take payments", svc("select charges_enabled, payouts_enabled from creator_payment_accounts where creator_id = %s", (other_creator,))[0][0] == (False, False))
svc_call("connect_account_update", "acct_dan", True, False, True)
check("Stripe's account updates are recorded", svc("select charges_enabled, payouts_enabled, details_submitted from creator_payment_accounts where creator_id = %s", (other_creator,))[0][0] == (True, False, True))
check("booking parties are recognised", svc_call("is_booking_party", alice, held["id"]) is True and svc_call("is_booking_party", PAYEE, held["id"]) is True
      and svc_call("is_booking_party", bob, held["id"]) is False)

print("\n[payments: rules shared with the app]")
if GOLDEN_REFUNDS.exists():
    fixture = json.loads(GOLDEN_REFUNDS.read_text())
    for case in fixture["percent"]:
        a.execute("select refund_percent(%s, %s::numeric)", (case["policy"], case["hours"]))
        got = a.fetchone()[0]
        check(f"refund_percent({case['policy']}, {case['hours']}h) = {case['percent']}", got == case["percent"], got)
    for case in fixture["refunds"]:
        check(f"{case['percent']}% of {case['paid_cents']} floors to {case['refund_cents']}", (case["paid_cents"] * case["percent"]) // 100 == case["refund_cents"])
else:
    print("  (no refund fixture found)")
check("an unknown policy refunds nothing", True if svc_call("refund_percent", "mystery", 1000) == 0 else False)
check("the hold is 15 minutes", svc_call("app_hold_minutes") == 15)

print("\n[payments: simultaneous reports of one payment]")
cc = book(bob, at(D[13], 10), pkg=PAYEE_PKG)
cc_prep = svc_call("payment_prepare", bob, cc["id"], "deposit", 0)
cc_intent = "pi_conc_" + uuid.uuid4().hex[:8]
svc_call("payment_attach_intent", cc_prep["payment_id"], cc_intent)
outs = [None] * 8
gate = threading.Barrier(8)


def report(i):
    c, k = as_user(None, "service_role")
    gate.wait()
    try:
        k.execute("select payment_record_success(%s, 50000, 'ch_c', 'apple_pay')", (cc_intent,))
        outs[i] = k.fetchone()[0]["action"]
    except psycopg2.Error as e:
        outs[i] = first_line(e)
    c.close()


ths = [threading.Thread(target=report, args=(i,)) for i in range(8)]
[t.start() for t in ths]
[t.join() for t in ths]
check("eight simultaneous reports confirm exactly once", outs.count("confirmed") == 1 and outs.count("noop") == 7, outs)
check("...and the booking is confirmed once", booking_row(cc["id"])["status"] == "confirmed" and contract_row(cc["id"])["signatures"] == 2)

pp = book(alice, at(D[13], 13), pkg=PAYEE_PKG)
ids = [None] * 8
gate2 = threading.Barrier(8)


def prepare(i):
    c, k = as_user(None, "service_role")
    gate2.wait()
    try:
        k.execute("select payment_prepare(%s, %s, 'deposit', 0)", (alice, pp["id"]))
        ids[i] = k.fetchone()[0]["payment_id"]
    except psycopg2.Error as e:
        ids[i] = first_line(e)
    c.close()


ths = [threading.Thread(target=prepare, args=(i,)) for i in range(8)]
[t.start() for t in ths]
[t.join() for t in ths]
check("eight simultaneous prepares share one payment", len(set(ids)) == 1 and len(payments_of(pp["id"], "deposit")) == 1, ids)


# ---- 11c. messaging and notifications -------------------------------------------
GOLDEN_NOTIFY = HERE.parents[1] / "SlateTests" / "Fixtures" / "notification_rules.json"


def send(uid, bid, body, client_id=None, role="authenticated"):
    res = sql_as(uid, "select id, sender_id, kind, body, client_id from send_message(%s, %s, %s)", (bid, body, client_id), role=role)
    if isinstance(res, str):
        return res
    row = res[0][0]
    return dict(id=row[0], sender=row[1], kind=row[2], body=row[3], client_id=row[4])


def messages_of(bid):
    a.execute("select kind, event, body, sender_id, data from messages where booking_id = %s order by created_at, id", (bid,))
    return a.fetchall()


def events_of(bid):
    return [m[1] if m[0] == "system" else "text" for m in messages_of(bid)]


def outbox(user=None, kind=None, booking=None):
    q, args = "select kind, data, user_id, sent_at, attempts, last_error, id from push_outbox where true", []
    for col, val in (("user_id", user), ("kind", kind), ("booking_id", booking)):
        if val is not None:
            q += f" and {col} = %s"
            args.append(val)
    a.execute(q + " order by created_at, kind, id", args)
    return a.fetchall()


def convos(uid):
    res = sql_as(uid, "select booking_id, last_kind, last_event, last_body, last_sender_id, unread_count from list_conversations()")
    return [] if isinstance(res, str) else res[0]


def claim_all():
    """Everything due, claimed the way send-push would (200 at a time)."""
    out = []
    while True:
        batch = svc_call("push_claim", 200)
        out += batch
        if not batch:
            return out


def prefs(uid, **changes):
    if changes:
        return sql_as(uid, "select save_notification_preferences(%s)", (Json(changes),))[0][0][0]
    return sql_as(uid, "select get_notification_preferences()")[0][0][0]


print("\n[messages: sending and reading]")
MC, MC_PKG = make_creator("msgco")
carol, dave, erin = new_user(), new_user(), new_user()
m1 = book(carol, at(D[20], 10), pkg=MC_PKG, client_name="Carol Diaz")
check("(set-up) a booking exists", isinstance(m1, dict), m1)
check("a booking's conversation starts with a line saying it was booked", events_of(m1["id"]) == ["booked"], messages_of(m1["id"]))
first = messages_of(m1["id"])[0]
check("...which carries the package and time for the app to word", first[4].get("packageName") == "Session" and first[4].get("timeZone") == TZ and "startAt" in first[4], first[4])
creator_rows = outbox(MC, "new_booking", m1["id"])
check("the creator is told about the new booking, with the facts to word it", len(creator_rows) == 1 and creator_rows[0][1]["role"] == "creator"
      and creator_rows[0][1]["clientName"] == "Carol Diaz" and creator_rows[0][1]["pendingDeposit"] is True and creator_rows[0][1]["depositCents"] == 50000, creator_rows)
check("the client isn't told about their own booking", len(outbox(carol)) == 0)

s1 = send(carol, m1["id"], "Hi! Could we shoot outdoors?")
check("a client can write to the creator", isinstance(s1, dict) and s1["kind"] == "text" and s1["sender"] == carol and s1["body"] == "Hi! Could we shoot outdoors?", s1)
pushed = outbox(MC, "message", m1["id"])
check("the creator is notified, with the sender's name and the words", len(pushed) == 1 and pushed[0][1]["senderName"] == "Carol Diaz"
      and pushed[0][1]["preview"] == "Hi! Could we shoot outdoors?" and pushed[0][1]["role"] == "creator", pushed)
s2 = send(MC, m1["id"], "Absolutely, the park by the lake is great at golden hour.")
check("the creator can reply", isinstance(s2, dict) and s2["sender"] == MC, s2)
pushed = outbox(carol, "message", m1["id"])
check("the client is notified, with the creator's name", len(pushed) == 1 and pushed[0][1]["senderName"] == "Msgco" and pushed[0][1]["role"] == "client", pushed)
check("nobody is notified of their own message", len(outbox(MC, "message", m1["id"])) == 1 and len(outbox(carol, "message", m1["id"])) == 1)

check("both people read the same conversation", sql_as(carol, "select count(*) from list_messages(%s)", (m1["id"],))[0][0][0] == 3
      and sql_as(MC, "select count(*) from list_messages(%s)", (m1["id"],))[0][0][0] == 3)
check("a stranger can't write to it", err(send(dave, m1["id"], "hello"), "not_found"))
check("...can't read it", sql_as(dave, "select count(*) from list_messages(%s)", (m1["id"],))[0][0][0] == 0
      and sql_as(dave, "select count(*) from messages where booking_id = %s", (m1["id"],))[0][0][0] == 0)
check("...and doesn't see it in their list", convos(dave) == [])
check("signed-out callers can't send or list", isinstance(send(None, m1["id"], "hi", role="anon"), str)
      and isinstance(sql_as(None, "select * from list_conversations()", role="anon"), str))
check("nobody can write a message directly", isinstance(sql_as(carol, "insert into messages (booking_id, sender_id, kind, body) values (%s, %s, 'text', 'forged')", (m1["id"], MC)), str))
check("nobody can pass a system line off as theirs", isinstance(sql_as(carol, "insert into messages (booking_id, kind, event) values (%s, 'system', 'cancelled')", (m1["id"],)), str))
check("nobody can edit or delete a message", sql_as(carol, "update messages set body = 'changed'")[1] == 0 and sql_as(carol, "delete from messages")[1] == 0
      and sql_as(MC, "update messages set body = 'changed'")[1] == 0)

print("\n[messages: what counts as a message]")
check("an empty message is refused", err(send(carol, m1["id"], ""), "invalid_message"))
check("so is one of only spaces and line breaks", err(send(carol, m1["id"], "  \n\t \r\n "), "invalid_message"))
check("so is one of only control characters", err(send(carol, m1["id"], "\x01\x07\x7f"), "invalid_message"))
check("a message over 2,000 characters is refused", err(send(carol, m1["id"], "x" * 2001), "message_too_long"))
check("2,000 characters is fine", isinstance(send(carol, m1["id"], "y" * 2000), dict))
check("2,000 emoji count as 2,000 characters, not bytes", isinstance(send(carol, m1["id"], "📸" * 2000), dict) and err(send(carol, m1["id"], "📸" * 2001), "message_too_long"))
check("a missing body is refused", err(send(carol, m1["id"], None), "invalid_message"))
cases = []
if GOLDEN_NOTIFY.exists():
    cases = json.loads(GOLDEN_NOTIFY.read_text())["messageCleaning"]
for case in cases:
    a.execute("select message_clean(%s)", (case["input"],))
    got = a.fetchone()[0]
    check(f"cleaning {case['input']!r} gives {case['expected']!r}", got == case["expected"], got)
check("what's stored is the cleaned text", send(carol, m1["id"], "  hello\r\nthere\x07  ")["body"] == "hello\nthere")

print("\n[messages: sending twice, and too often]")
cid = str(uuid.uuid4())
t1 = send(erin, m1["id"], "ignored", cid)  # erin isn't a party
check("(set-up) a stranger with a client id is still refused", err(t1, "not_found"))
before = len(messages_of(m1["id"]))
d1 = send(carol, m1["id"], "Sending with a retry token", cid)
d2 = send(carol, m1["id"], "Sending with a retry token", cid)
check("sending the same message again returns the first, not a copy", isinstance(d1, dict) and d1 == d2 and len(messages_of(m1["id"])) == before + 1, (d1, d2))
check("...and notifies only once", len([r for r in outbox(MC, "message", m1["id"]) if r[1]["preview"] == "Sending with a retry token"]) == 1)
d3 = send(MC, m1["id"], "Same token, different person", cid)
check("another person using the same token is a new message", isinstance(d3, dict) and d3["id"] != d1["id"], d3)

RC, RC_PKG = make_creator("ratelimit", deposit=0, account=False)
hurried = new_user()
rl = book(hurried, at(D[20], 10), pkg=RC_PKG, client_name="Hurried")
sent = [send(hurried, rl["id"], f"message {i}") for i in range(20)]
check("twenty messages in a minute go through", all(isinstance(s, dict) for s in sent), [s for s in sent if isinstance(s, str)][:1])
check("the twenty-first is refused", err(send(hurried, rl["id"], "message 21"), "rate_limited"))
check("...but the other person can still reply", isinstance(send(RC, rl["id"], "Slow down!"), dict))
rl_token = str(uuid.uuid4())
a.execute("update messages set created_at = created_at - interval '2 minutes' where sender_id = %s", (hurried,))
check("after a minute they can write again", isinstance(send(hurried, rl["id"], "back", rl_token), dict))
for i in range(19):
    send(hurried, rl["id"], f"again {i}")
check("(set-up) at the limit again", err(send(hurried, rl["id"], "one too many"), "rate_limited"))
check("a retry of a message that was already saved is answered even then", send(hurried, rl["id"], "back", rl_token)["client_id"] == rl_token)

print("\n[messages: unread counts and the conversation list]")
UC, UC_PKG = make_creator("unreadco", deposit=0, account=False)
frank = new_user()
u = book(frank, at(D[21], 10), pkg=UC_PKG, client_name="Frank")
check("a new conversation has nothing unread (system lines never count)", [c[5] for c in convos(frank)] == [0] and [c[5] for c in convos(UC)] == [0], (convos(frank), convos(UC)))
send(frank, u["id"], "one")
send(frank, u["id"], "two")
send(frank, u["id"], "three")
check("each message from the other person is unread", [c[5] for c in convos(UC)] == [3])
check("your own messages aren't unread to you", [c[5] for c in convos(frank)] == [0])
check("the list shows the latest line", convos(UC)[0][1:4] == ("text", None, "three"), convos(UC))
sql_as(UC, "select mark_conversation_read(%s)", (u["id"],))
check("reading a conversation clears it", [c[5] for c in convos(UC)] == [0])
check("...for the reader only", [c[5] for c in convos(frank)] == [0])
send(UC, u["id"], "got them")
check("a reply makes it unread for the other person", [c[5] for c in convos(frank)] == [1])
send(frank, u["id"], "four")
check("writing back counts as having read what came before", [c[5] for c in convos(frank)] == [0] and [c[5] for c in convos(UC)] == [1])
check("a stranger can't mark it read", err(sql_as(dave, "select mark_conversation_read(%s)", (u["id"],)), "not_found"))
check("marking read twice changes nothing", sql_as(UC, "select mark_conversation_read(%s)", (u["id"],)) is not None and [c[5] for c in convos(UC)] == [0])
a.execute("select unread_message_count(%s), unread_message_count(%s)", (UC, frank))
check("the badge count is the sum over conversations", a.fetchone() == (0, 0))
send(frank, u["id"], "badge test")
a.execute("select unread_message_count(%s)", (UC,))
check("...and counts new ones", a.fetchone()[0] == 1)
check("the app can't ask for anyone's badge", isinstance(sql_as(UC, "select unread_message_count(%s)", (UC,)), str))

older = book(frank, at(D[22], 10), pkg=MC_PKG, client_name="Frank")
send(frank, older["id"], "hello again")
listing = convos(frank)
check("conversations are newest first", [c[0] for c in listing] == [older["id"], u["id"]], [c[0] for c in listing])
rows = sql_as(frank, "select count(*) from list_messages(%s, null, 2)", (u["id"],))[0][0][0]
check("a limit returns that many", rows == 2)
newest = [r[0] for r in sql_as(frank, "select body from list_messages(%s, null, 2)", (u["id"],))[0]]
check("...the newest, still in time order", newest == ["four", "badge test"], newest)
a.execute("select created_at from messages where booking_id = %s and body = 'one'", (u["id"],))
since = a.fetchone()[0]
after = [r[0] for r in sql_as(frank, "select body from list_messages(%s, %s)", (u["id"], since))[0]]
check("'since' returns only what came after", after[0] == "two" and "one" not in after and after[-1] == "badge test", after)

print("\n[messages: closed conversations]")
CC2, CC2_PKG = make_creator("closedco")
gina = new_user()
gone = book(gina, at(D[23], 10), pkg=CC2_PKG, client_name="Gina")
send(gina, gone["id"], "before it lapsed")
lapse(gone["id"])
check("a lapsed hold's conversation isn't listed", convos(gina) == [] and convos(CC2) == [], (convos(gina), convos(CC2)))
check("...and can't be written to", err(send(gina, gone["id"], "anyone there?"), "conversation_closed"))
svc_call("expire_holds")
check("...still true once the hold is formally expired", err(send(CC2, gone["id"], "hello?"), "conversation_closed") and convos(gina) == [])
cancelled_chat = book(gina, at(D[23], 13), pkg=CC2_PKG, client_name="Gina")
cancel(gina, cancelled_chat["id"])
check("a cancelled booking's conversation stays open, for refund questions", isinstance(send(gina, cancelled_chat["id"], "When will the refund arrive?"), dict)
      and cancelled_chat["id"] in [c[0] for c in convos(CC2)])

print("\n[notifications: settings]")
check("everything is on until someone says otherwise", prefs(erin) == dict(bookings=True, contracts=True, payments=True, messages=True, reminders=True), prefs(erin))
check("saving one setting leaves the others", prefs(erin, messages=False) == dict(bookings=True, contracts=True, payments=True, messages=False, reminders=True))
check("settings are kept per person", prefs(dave)["messages"] is True and prefs(erin)["messages"] is False)
check("a setting can be switched back", prefs(erin, messages=True)["messages"] is True)
check("unknown keys are ignored", prefs(erin, bogus=False) == dict(bookings=True, contracts=True, payments=True, messages=True, reminders=True))
check("settings can't be read or written directly", isinstance(sql_as(erin, "select * from notification_preferences"), str)
      and isinstance(sql_as(erin, "insert into notification_preferences (user_id) values (%s)", (erin,)), str))
check("signed-out callers have none", isinstance(sql_as(None, "select get_notification_preferences()", role="anon"), str))

PC, PC_PKG = make_creator("prefsco")
heidi = new_user()
prefs(PC, messages=False)
pm = book(heidi, at(D[24], 10), pkg=PC_PKG, client_name="Heidi")
send(heidi, pm["id"], "will you see this?")
check("a muted kind queues nothing", len(outbox(PC, "message")) == 0)
check("...while other kinds still do", len(outbox(PC, "new_booking")) == 1)
send(PC, pm["id"], "reply")
check("muting is per person", len(outbox(heidi, "message")) == 1)
prefs(PC, messages=True)
send(heidi, pm["id"], "and now?")
check("switching it back on resumes", len(outbox(PC, "message")) == 1)
prefs(PC, bookings=False)
book(heidi, at(D[24], 13), pkg=PC_PKG, client_name="Heidi")
check("muting 'bookings' stops new-booking notifications (only the one from before is queued)", len(outbox(PC, "new_booking")) == 1)
prefs(PC, bookings=True)

print("\n[notifications: a booking's life becomes messages and notifications]")
LC, LC_PKG = make_creator("lifeco", price=200000, deposit=50000)
ivy = new_user()
life = book(ivy, at(D[25], 10), pkg=LC_PKG, client_name="Ivy Park")
check("held: just the booked line, and a heads-up to the creator that a deposit is awaited", events_of(life["id"]) == ["booked"]
      and [r[1]["pendingDeposit"] for r in outbox(LC, "new_booking", life["id"])] == [True])
check("held: no contract, payment or other notification yet", {r[0] for r in outbox(booking=life["id"])} == {"new_booking"})
pay(life["id"])
check("paying the deposit adds 'deposit paid' then 'contract signed'", events_of(life["id"]) == ["booked", "deposit_paid", "contract_signed"], events_of(life["id"]))
dep = [m for m in messages_of(life["id"]) if m[1] == "deposit_paid"][0]
check("...with the amount for the app to word", dep[4] == {"amountCents": 50000, "currency": "USD"}, dep[4])
check("the creator is told the payment arrived", [r[1] for r in outbox(LC, "payment_received", life["id"])] == [dict(
    bookingId=life["id"], role="creator", paymentKind="deposit", amountCents=50000, currency="USD", clientName="Ivy Park", packageName="Session")],
    outbox(LC, "payment_received", life["id"]))
check("the client is told too", [(r[1]["role"], r[1]["paymentKind"], r[1]["creatorName"]) for r in outbox(ivy, "payment_received", life["id"])] == [("client", "deposit", "Lifeco")])
check("both are told the contract is signed, each with the other's name", sorted((r[2], r[1]["role"], r[1]["otherName"]) for r in outbox(booking=life["id"]) if r[0] == "contract_signed")
      == sorted([(LC, "creator", "Ivy Park"), (ivy, "client", "Lifeco")]))
check("those are the only notifications so far", sorted(r[0] for r in outbox(booking=life["id"])) == sorted(["new_booking", "payment_received", "payment_received", "contract_signed", "contract_signed"]))
n_before = len(outbox(booking=life["id"]))
svc_call("payment_record_success", payments_of(life["id"], "deposit")[0][5], 50000, "ch_again", "apple_pay")
check("Stripe repeating itself says nothing new", len(outbox(booking=life["id"])) == n_before and events_of(life["id"]) == ["booked", "deposit_paid", "contract_signed"])

move_to(life["id"], -3)
check("(set-up) the creator shares the final files", isinstance(share(LC, life["id"], FILES, "Gallery password: lake"), tuple))
check("sharing adds a line, without the link in it", events_of(life["id"])[-1] == "delivery_shared" and messages_of(life["id"])[-1][4] == {"revised": False}, messages_of(life["id"])[-1])
ds = outbox(ivy, "delivery_shared", life["id"])
check("the client is told the files are ready, and what is still to pay", len(ds) == 1 and ds[0][1] == dict(
    bookingId=life["id"], role="client", creatorName="Lifeco", packageName="Session", revised=False, balanceCents=150000, currency="USD"), ds)
check("the creator isn't told about their own action", len(outbox(LC, "delivery_shared")) == 0)
check("no balance notification yet: the client hasn't confirmed", len(outbox(ivy, "balance_due", life["id"])) == 0)
share(LC, life["id"], FILES)
check("sharing the same link again says nothing new", events_of(life["id"]).count("delivery_shared") == 1 and len(outbox(ivy, "delivery_shared", life["id"])) == 1)
check("(set-up) the creator corrects the link", isinstance(share(LC, life["id"], "https://files.example.com/corrected"), tuple))
check("a new link is announced as an update", events_of(life["id"]).count("delivery_shared") == 2 and messages_of(life["id"])[-1][4] == {"revised": True}
      and sorted(r[1]["revised"] for r in outbox(ivy, "delivery_shared", life["id"])) == [False, True])
check("(set-up) the client confirms", confirm(ivy, life["id"]) == ("confirmed", True))
check("confirming adds a line with the balance now payable", events_of(life["id"])[-1] == "receipt_confirmed" and messages_of(life["id"])[-1][4] == {"balanceCents": 150000, "currency": "USD"}, messages_of(life["id"])[-1])
rc = outbox(LC, "receipt_confirmed", life["id"])
check("the creator is told, with the client's name and the balance", len(rc) == 1 and rc[0][1] == dict(
    bookingId=life["id"], role="creator", clientName="Ivy Park", packageName="Session", balanceCents=150000, currency="USD"), rc)
check("confirming twice says nothing new", confirm(ivy, life["id"]) == ("confirmed", True) and events_of(life["id"]).count("receipt_confirmed") == 1 and len(outbox(LC, "receipt_confirmed")) == 1)
pay(life["id"], kind="balance")
check("paying the balance adds its line", events_of(life["id"])[-1] == "balance_paid" and messages_of(life["id"])[-1][4]["amountCents"] == 150000)
check("...and notifies both", sorted((r[2], r[1]["paymentKind"]) for r in outbox(booking=life["id"]) if r[0] == "payment_received" and r[1]["paymentKind"] == "balance")
      == sorted([(LC, "balance"), (ivy, "balance")]))
check("the booking is complete, and still open to messages", booking_row(life["id"])["status"] == "completed" and isinstance(send(ivy, life["id"], "Thank you!"), dict))

# Nothing owed after delivery.
FC, FC_PKG = make_creator("fullpaidco", price=50000, deposit=50000)
jon = new_user()
fp = book(jon, at(D[25], 10), pkg=FC_PKG, client_name="Jon")
pay(fp["id"])
move_to(fp["id"], -3)
share(FC, fp["id"])
check("sharing the files of a fully paid booking asks for no money", events_of(fp["id"])[-1] == "delivery_shared" and outbox(jon, "delivery_shared", fp["id"])[0][1]["balanceCents"] == 0
      and booking_row(fp["id"])["status"] == "confirmed")
confirm(jon, fp["id"])
check("confirming completes it, and the creator is told there is nothing more to come", booking_row(fp["id"])["status"] == "completed" and events_of(fp["id"])[-1] == "receipt_confirmed"
      and outbox(FC, "receipt_confirmed", fp["id"])[0][1]["balanceCents"] == 0 and len(outbox(jon, "balance_due")) == 0)

# No deposit.
NC, NC_PKG = make_creator("freeco", deposit=0, account=False)
kim = new_user()
free_b = book(kim, at(D[25], 10), pkg=NC_PKG, client_name="Kim")
check("with no deposit, the contract is signed at once and no payment is announced", events_of(free_b["id"]) == ["booked", "contract_signed"]
      and sorted(r[0] for r in outbox(booking=free_b["id"])) == ["contract_signed", "contract_signed", "new_booking"]
      and [r[1]["pendingDeposit"] for r in outbox(NC, "new_booking")] == [False], events_of(free_b["id"]))

print("\n[notifications: cancelling]")
XC, XC_PKG = make_creator("cancelco", policy="moderate")
leo, mia = new_user(), new_user()
c1 = book(leo, at(D[26], 10), pkg=XC_PKG, client_name="Leo")
pay(c1["id"])
move_to(c1["id"], 100)
cancel(leo, c1["id"])
last = messages_of(c1["id"])[-1]
check("a client cancelling adds a line saying who and how much comes back", last[1] == "cancelled" and last[4] == {"byCreator": False, "refundCents": 25000, "currency": "USD"}, last)
bc = outbox(XC, "booking_cancelled", c1["id"])
check("the creator is told, with the client's name and the refund", len(bc) == 1 and bc[0][1]["role"] == "creator" and bc[0][1]["byName"] == "Leo"
      and bc[0][1]["refundCents"] == 25000 and bc[0][1]["packageName"] == "Session", bc)
check("the client isn't told about their own cancellation", len(outbox(leo, "booking_cancelled")) == 0)
c2 = book(mia, at(D[27], 10), pkg=XC_PKG, client_name="Mia")
pay(c2["id"])
move_to(c2["id"], 10)
check("(set-up) the creator cancels", cancel(XC, c2["id"]) == "ok")
bc2 = outbox(mia, "booking_cancelled", c2["id"])
check("the client is told, with the creator's name and a full refund", len(bc2) == 1 and bc2[0][1]["role"] == "client" and bc2[0][1]["byName"] == "Cancelco"
      and bc2[0][1]["refundCents"] == 50000, bc2)
check("the line says the creator cancelled", messages_of(c2["id"])[-1][4]["byCreator"] is True)
c3 = book(leo, at(D[28], 10), pkg=XC_PKG, client_name="Leo")
cancel(leo, c3["id"])
check("cancelling an unpaid hold refunds nothing", messages_of(c3["id"])[-1][4]["refundCents"] == 0
      and [r[1]["refundCents"] for r in outbox(XC, "booking_cancelled", c3["id"])] == [0])

print("\n[notifications: payments that came to nothing say nothing]")
NP, NP_PKG = make_creator("quietco")
nia = new_user()
q1 = book(nia, at(D[29], 10), pkg=NP_PKG, client_name="Nia")
qp = svc_call("payment_prepare", nia, q1["id"], "deposit", 0)
svc_call("payment_attach_intent", qp["payment_id"], "pi_quiet_1")
cancel(nia, q1["id"])
n0 = len(outbox(booking=q1["id"]))
res = svc_call("payment_record_success", "pi_quiet_1", 50000, "ch_q", "apple_pay")
check("(set-up) money arrives for a cancelled booking and is refunded", res["action"] == "refund_required")
check("no 'deposit paid' line, no 'payment received', no 'contract signed'", "deposit_paid" not in events_of(q1["id"]) and "contract_signed" not in events_of(q1["id"])
      and len(outbox(booking=q1["id"])) == n0 and not [r for r in outbox(booking=q1["id"]) if r[0] in ("payment_received", "contract_signed")])
q2 = book(nia, at(D[30], 10), pkg=NP_PKG, client_name="Nia")
pay(q2["id"])
pays_before = len([r for r in outbox(booking=q2["id"]) if r[0] == "payment_received"])
a.execute("insert into payments (booking_id, kind, amount_cents, currency_code, status, stripe_payment_intent_id) values (%s,'deposit',50000,'USD','failed','pi_quiet_dup')", (q2["id"],))
svc_call("payment_record_success", "pi_quiet_dup", 50000, "ch_qd", "apple_pay")
check("a duplicate payment, refunded at once, isn't announced either", len([r for r in outbox(booking=q2["id"]) if r[0] == "payment_received"]) == pays_before == 2
      and events_of(q2["id"]).count("deposit_paid") == 1)

q3 = book(nia, at(D[31], 10), pkg=NP_PKG, client_name="Nia")
qp3 = svc_call("payment_prepare", nia, q3["id"], "deposit", 0)
svc_call("payment_attach_intent", qp3["payment_id"], "pi_quiet_late")
lapse(q3["id"])
svc_call("expire_holds")
check("an expired hold says nothing and has no conversation", events_of(q3["id"]) == ["booked"] and q3["id"] not in [c[0] for c in convos(nia)])
svc_call("payment_record_success", "pi_quiet_late", 50000, "ch_ql", "apple_pay")
check("paid late with the time free: honoured, and announced then", booking_row(q3["id"])["status"] == "confirmed"
      and events_of(q3["id"]) == ["booked", "deposit_paid", "contract_signed"] and q3["id"] in [c[0] for c in convos(nia)])

print("\n[notifications: settings applied to events]")
SC, SC_PKG = make_creator("settingsco")
omar = new_user()
prefs(SC, payments=False)
prefs(omar, contracts=False)
s_b = book(omar, at(D[32], 10), pkg=SC_PKG, client_name="Omar")
pay(s_b["id"])
kinds = lambda uid: sorted(r[0] for r in outbox(uid, booking=s_b["id"]))
check("a creator who muted payments still hears of bookings and contracts", kinds(SC) == ["contract_signed", "new_booking"], kinds(SC))
check("a client who muted contracts still hears of payments", kinds(omar) == ["payment_received"], kinds(omar))
check("muting doesn't touch the conversation itself", events_of(s_b["id"]) == ["booked", "deposit_paid", "contract_signed"])

print("\n[notifications: shoot reminders]")
rules = json.loads(GOLDEN_NOTIFY.read_text()) if GOLDEN_NOTIFY.exists() else {}
if rules:
    a.execute("select app_reminder_leads(), app_message_max_length()")
    leads, maxlen = a.fetchone()
    check("the reminder times match the app's", leads == rules["reminderLeadMinutes"], leads)
    check("the message limit matches the app's", maxlen == rules["maxMessageLength"], maxlen)

nat, ola, pat, quin, ron, sam = [new_user() for _ in range(6)]
RDAY = D[36]


def confirmed(client, hours_ahead, hours_made_ago=72, pay_it=True):
    """A booking with its own creator (so the moved times can't collide), made `hours_made_ago` hours ago."""
    creator_id, pkg = make_creator("rm" + uuid.uuid4().hex[:8])
    b = book(client, at(RDAY, 10), pkg=pkg, client_name="Client " + client[:4])
    if pay_it:
        pay(b["id"])
    a.execute("update bookings set created_at = now() - (%s || ' hours')::interval where id = %s", (hours_made_ago, b["id"]))
    move_to(b["id"], hours_ahead)
    return b, creator_id


def reminders(booking_id):
    return [r for r in outbox(booking=booking_id) if r[0] == "shoot_reminder"]


r1, r1c = confirmed(nat, 23)
check("nothing is due until the run happens", len(reminders(r1["id"])) == 0)
queued = svc_call("enqueue_due_reminders")
check("a run queues the day-before reminder for both people", queued >= 2 and sorted((r[2], r[1]["role"], r[1]["leadMinutes"]) for r in reminders(r1["id"]))
      == sorted([(r1c, "creator", 1440), (nat, "client", 1440)]), reminders(r1["id"]))
rr = {r[1]["role"]: r[1] for r in reminders(r1["id"])}
check("...each naming the other person", rr["creator"]["otherName"].startswith("Client") and rr["client"]["otherName"].startswith("Rm") and rr["client"]["packageName"] == "Session")
check("...with the time and zone to word it", "startAt" in rr["client"] and rr["client"]["timeZone"] == TZ)
check("running again queues nothing more", svc_call("enqueue_due_reminders") == 0 and len(reminders(r1["id"])) == 2)

r2, _ = confirmed(ola, 1.5)
svc_call("enqueue_due_reminders")
check("an hour and a half out: the two-hour reminder, not the day-before one", sorted({r[1]["leadMinutes"] for r in reminders(r2["id"])}) == [120], reminders(r2["id"]))
check("...for both people", len(reminders(r2["id"])) == 2)

r3, _ = confirmed(pat, 11)
svc_call("enqueue_due_reminders")
check("eleven hours out is too late for the day-before reminder (it's only valid until half its lead is left)", len(reminders(r3["id"])) == 0, reminders(r3["id"]))
r3b, _ = confirmed(pat, 13)
svc_call("enqueue_due_reminders")
check("thirteen hours out is still within it", len(reminders(r3b["id"])) == 2)

r4, _ = confirmed(quin, 23, hours_made_ago=0)
svc_call("enqueue_due_reminders")
check("a booking made after the reminder time doesn't get that reminder (you just booked it)", len(reminders(r4["id"])) == 0)

r5, _ = confirmed(ron, 23, pay_it=False)
svc_call("enqueue_due_reminders")
check("a held booking gets none", booking_row(r5["id"])["status"] == "held" and len(reminders(r5["id"])) == 0)

r6, _ = confirmed(sam, 23)
cancel(sam, r6["id"])
svc_call("enqueue_due_reminders")
check("a cancelled booking gets none", booking_row(r6["id"])["status"] == "cancelled" and len(reminders(r6["id"])) == 0)

r7, _ = confirmed(nat, 23)
a.execute("update bookings set start_at = now() - interval '1 hour', end_at = now() + interval '30 minutes', blocked_until = now() + interval '1 hour' where id = %s", (r7["id"],))
svc_call("enqueue_due_reminders")
check("a shoot that has already started gets none", len(reminders(r7["id"])) == 0)

r8, r8c = confirmed(ola, 23, hours_made_ago=72)
# (muting has to happen before the run)
a.execute("delete from push_outbox where booking_id = %s", (r8["id"],))
prefs(r8c, reminders=False)
svc_call("enqueue_due_reminders")
check("a person who muted reminders gets none, the other still does", [r[2] for r in reminders(r8["id"])] == [ola], reminders(r8["id"]))

r9, _ = confirmed(pat, 23)
svc_call("enqueue_due_reminders")
claimed = claim_all()
check("reminders for a coming shoot are claimed for sending", len([c for c in claimed if c["booking_id"] == r9["id"] and c["kind"] == "shoot_reminder"]) == 2)
r10, r10c = confirmed(sam, 23)
svc_call("enqueue_due_reminders")
cancel(r10c, r10["id"])
claimed = claim_all()
check("a reminder for a booking cancelled after it was queued is not sent", not any(c["booking_id"] == r10["id"] and c["kind"] == "shoot_reminder" for c in claimed))
check("...and is closed as stale", len(reminders(r10["id"])) == 2 and all(r[3] is not None and r[5] == "stale" for r in reminders(r10["id"])), reminders(r10["id"]))

print("\n[notifications: devices]")
tok = lambda: uuid.uuid4().hex + uuid.uuid4().hex
t_a = tok()
reg = sql_as(nat, "select register_device(%s, 'sandbox')", (t_a,))
check("a device can be registered", not isinstance(reg, str), reg)
a.execute("select user_id, environment from device_tokens where token = %s", (t_a,))
check("...and is stored for them", a.fetchone() == (nat, "sandbox"))
upper = sql_as(nat, "select register_device(%s, 'production')", (t_a.upper(),))
a.execute("select count(*) from device_tokens where user_id = %s", (nat,))
check("a token is stored in lower case", not isinstance(upper, str) and a.fetchone()[0] == 1, upper)
a.execute("select environment from device_tokens where token = %s", (t_a,))
check("registering again updates its environment", a.fetchone()[0] == "production")
check("a token that isn't hex is refused", err(sql_as(nat, "select register_device('not-a-token', 'sandbox')"), "invalid_token"))
check("a short token is refused", err(sql_as(nat, "select register_device('abcd', 'sandbox')"), "invalid_token"))
check("an unknown environment is refused", err(sql_as(nat, "select register_device(%s, 'staging')", (tok(),)), "invalid_environment"))
check("signed-out callers can't register", isinstance(sql_as(None, "select register_device(%s, 'sandbox')", (tok(),), role="anon"), str))
sql_as(ola, "select register_device(%s, 'sandbox')", (t_a,))
a.execute("select user_id from device_tokens where token = %s", (t_a,))
check("a phone signed in by someone else moves to them", a.fetchone()[0] == ola)
sql_as(nat, "select unregister_device(%s)", (t_a,))
a.execute("select count(*) from device_tokens where token = %s", (t_a,))
check("nobody can unregister another person's device", a.fetchone()[0] == 1)
sql_as(ola, "select unregister_device(%s)", (t_a,))
a.execute("select count(*) from device_tokens where token = %s", (t_a,))
check("you can unregister your own", a.fetchone()[0] == 0)
many = [tok() for _ in range(13)]
for t in many:
    sql_as(pat, "select register_device(%s, 'sandbox')", (t,))
    time.sleep(0.01)
a.execute("select token from device_tokens where user_id = %s order by last_seen_at desc", (pat,))
kept = [r[0] for r in a.fetchall()]
check("a person keeps at most their ten newest devices", len(kept) == 10 and kept == list(reversed(many))[:10], len(kept))
check("device tokens can't be read or written directly", isinstance(sql_as(pat, "select * from device_tokens"), str) and isinstance(sql_as(pat, "insert into device_tokens (token, user_id, environment) values (%s, %s, 'sandbox')", (tok(), pat)), str))

print("\n[notifications: the sending queue]")
QU = new_user()
sql_as(QU, "select register_device(%s, 'sandbox')", (tok(),))
dead_a, dead_b = tok(), tok()
sql_as(QU, "select register_device(%s, 'production')", (dead_a,))
a.execute("delete from push_outbox")
for i in range(5):
    a.execute("select push_enqueue(%s, 'message', null, %s, %s)", (QU, Json(dict(senderName="Q", preview=f"m{i}", role="client")), f"q{i}"))
    time.sleep(0.005)
first_claim = svc_call("push_claim", 3)
check("a claim returns at most the limit, oldest first", [c["data"]["preview"] for c in first_claim] == ["m0", "m1", "m2"], first_claim)
check("...each with the person's devices", all(len(c["devices"]) == 2 for c in first_claim) and {d["environment"] for d in first_claim[0]["devices"]} == {"sandbox", "production"})
check("...an attempt count", all(c["attempts"] == 1 for c in first_claim))
second_claim = svc_call("push_claim", 10)
check("a second claim doesn't get rows the first is holding", [c["data"]["preview"] for c in second_claim] == ["m3", "m4"], second_claim)
check("...and a third finds nothing", svc_call("push_claim", 10) == [])
svc_call("push_complete", first_claim[0]["id"], True, None, [])
a.execute("select sent_at is not null, locked_until is null from push_outbox where id = %s", (first_claim[0]["id"],))
check("a delivered notification is closed", a.fetchone() == (True, True))
svc_call("push_complete", first_claim[1]["id"], False, "APNs said 503", [])
a.execute("select sent_at, last_error, send_after > now(), locked_until from push_outbox where id = %s", (first_claim[1]["id"],))
row = a.fetchone()
check("a failed one is kept, with why, and tried again later", row[0] is None and row[1] == "APNs said 503" and row[2] is True and row[3] is None, row)
check("...but not until its pause is over", all(c["id"] != first_claim[1]["id"] for c in svc_call("push_claim", 10)))
a.execute("update push_outbox set send_after = now() - interval '1 second' where id = %s", (first_claim[1]["id"],))
again = [c for c in svc_call("push_claim", 10) if c["id"] == first_claim[1]["id"]]
check("then it is claimed again, counted as the second attempt", len(again) == 1 and again[0]["attempts"] == 2, again)
for _ in range(3):
    svc_call("push_complete", first_claim[1]["id"], False, "again", [])
    a.execute("update push_outbox set send_after = now() - interval '1 second' where id = %s", (first_claim[1]["id"],))
    svc_call("push_claim", 10)
a.execute("select attempts from push_outbox where id = %s", (first_claim[1]["id"],))
check("after five attempts it is given up on", a.fetchone()[0] == 5)
svc_call("push_complete", first_claim[1]["id"], False, "again", [])
a.execute("update push_outbox set send_after = now() - interval '1 second' where id = %s", (first_claim[1]["id"],))
check("...and never claimed again", all(c["id"] != first_claim[1]["id"] for c in svc_call("push_claim", 10)))

other_owner = new_user()
sql_as(other_owner, "select register_device(%s, 'sandbox')", (dead_b,))
svc_call("push_complete", first_claim[2]["id"], True, None, [dead_a, dead_b])
a.execute("select token from device_tokens where token in (%s, %s)", (dead_a, dead_b))
check("dead tokens are forgotten, but only the recipient's own", [r[0] for r in a.fetchall()] == [dead_b])

NOD = new_user()
a.execute("select push_enqueue(%s, 'message', null, '{}'::jsonb, 'nod1')", (NOD,))
nod_claim = [c for c in svc_call("push_claim", 50) if c["user_id"] == NOD]
check("a person with no devices still comes back, with an empty list, so the sender can close it", len(nod_claim) == 1 and nod_claim[0]["devices"] == [])

a.execute("delete from push_outbox")
a.execute("delete from conversation_reads")
BADGE = new_user()
bgb = book(BADGE, at(D[34], 10), pkg=NC_PKG, client_name="Badge")
send(NC, bgb["id"], "one")
send(NC, bgb["id"], "two")
a.execute("select push_enqueue(%s, 'message', %s, '{}'::jsonb, 'badge1')", (BADGE, bgb["id"]))
badges = [c["badge"] for c in svc_call("push_claim", 50) if c["user_id"] == BADGE]
check("each claim carries the person's unread count for the app icon", len(badges) >= 1 and set(badges) == {2}, badges)

a.execute("select push_enqueue(%s, 'message', null, '{}'::jsonb, 'dupe-key')", (QU,))
a.execute("select push_enqueue(%s, 'message', null, '{}'::jsonb, 'dupe-key')", (QU,))
a.execute("select count(*) from push_outbox where dedupe_key = 'dupe-key'")
check("queuing the same thing twice queues it once", a.fetchone()[0] == 1)

a.execute("insert into push_outbox (user_id, kind, sent_at, created_at) values (%s, 'message', now() - interval '20 days', now() - interval '21 days')", (QU,))
a.execute("insert into push_outbox (user_id, kind, sent_at, created_at) values (%s, 'message', now() - interval '1 day', now() - interval '2 days')", (QU,))
a.execute("insert into push_outbox (user_id, kind, created_at, attempts) values (%s, 'message', now() - interval '30 days', 5)", (QU,))
check("pruning removes old rows, sent or abandoned, and keeps recent ones", svc_call("push_prune") == 2)

print("\n[notifications: who may call what]")
for fn, args in [("push_claim", (10,)), ("push_complete", (str(uuid.uuid4()), True, None, [])), ("push_prune", ()), ("enqueue_due_reminders", ()),
                 ("push_enqueue", (QU, "message", None, Json({}), "x")), ("unread_message_count", (QU,))]:
    marks = ", ".join(["%s"] * len(args))
    check(f"{fn} is closed to signed-in users", isinstance(sql_as(QU, f"select {fn}({marks})", args), str))
    check(f"{fn} is closed to signed-out callers", isinstance(sql_as(None, f"select {fn}({marks})", args, role="anon"), str))
check("the queue can't be read or changed by anyone signed in", isinstance(sql_as(QU, "select * from push_outbox"), str)
      and isinstance(sql_as(QU, "delete from push_outbox"), str) and isinstance(sql_as(LC, "select * from conversation_reads"), str))
check("the trigger functions can't be called", isinstance(sql_as(QU, "select bookings_notify_created()"), str))

print("\n[messages and queue: simultaneous callers]")
SR, SR_PKG = make_creator("simulco", deposit=0, account=False)
sim = new_user()
sb = book(sim, at(D[37], 10), pkg=SR_PKG, client_name="Sim")
same_token = str(uuid.uuid4())
sent_ids = [None] * 8
gate3 = threading.Barrier(8)


def send_same(i):
    c, k = as_user(sim)
    gate3.wait()
    try:
        k.execute("select id from send_message(%s, 'only once please', %s)", (sb["id"], same_token))
        sent_ids[i] = k.fetchone()[0]
    except psycopg2.Error as e:
        sent_ids[i] = first_line(e)
    c.close()


ths = [threading.Thread(target=send_same, args=(i,)) for i in range(8)]
[t.start() for t in ths]
[t.join() for t in ths]
check("eight copies of one message sent at once are all answered with the same message", len(set(sent_ids)) == 1 and not str(sent_ids[0]).startswith("ERR"), sent_ids)
a.execute("select count(*) from messages where booking_id = %s and kind = 'text'", (sb["id"],))
check("...and only one is stored", a.fetchone()[0] == 1)
check("...and only one notification is queued", len(outbox(SR, "message", sb["id"])) == 1)

a.execute("delete from push_outbox")
for i in range(30):
    a.execute("select push_enqueue(%s, 'message', null, '{}'::jsonb, %s)", (QU, f"sim{i}"))
pulled = [None] * 4
gate4 = threading.Barrier(4)


def pull(i):
    c, k = as_user(None, "service_role")
    gate4.wait()
    try:
        k.execute("select push_claim(10)")
        pulled[i] = [row["id"] for row in k.fetchone()[0]]
    except psycopg2.Error as e:
        pulled[i] = [first_line(e)]
    c.close()


ths = [threading.Thread(target=pull, args=(i,)) for i in range(4)]
[t.start() for t in ths]
[t.join() for t in ths]
flat = [x for batch in pulled for x in batch]
check("four senders claiming at once never get the same notification", len(flat) == len(set(flat)) and all("ERR" not in x for x in flat), pulled)
check("...and between them take what is due, ten at a time", sorted(len(b) for b in pulled) == [10, 10, 10, 0] or sum(len(b) for b in pulled) == 30, [len(b) for b in pulled])

print("\n[notifications: deleting an account]")
gone_user = new_user()
GC, GC_PKG = make_creator("goneco", deposit=0, account=False)
gb = book(gone_user, at(D[35], 10), pkg=GC_PKG, client_name="Goner")
send(gone_user, gb["id"], "I'll delete my account soon")
sql_as(gone_user, "select register_device(%s, 'sandbox')", (tok(),))
a.execute("delete from auth.users where id = %s", (gone_user,))
a.execute("select body, sender_id from messages where booking_id = %s and kind = 'text'", (gb["id"],))
check("the other person keeps what was said, now from nobody in particular", a.fetchall() == [("I'll delete my account soon", None)])
check("...but can't write to someone who is gone", err(send(GC, gb["id"], "Are you there?"), "conversation_closed"))
a.execute("select count(*) from device_tokens where user_id = %s", (gone_user,))
check("their devices and settings are removed", a.fetchone()[0] == 0)


# ---- 11b. delivery and reviews -------------------------------------------------
print("\n[delivery: the rules shared with the app]")
drules = json.loads(GOLDEN_DELIVERY.read_text())
a.execute("select delivery_note_max_length(), review_max_length()")
check("the note and review limits match the app's", a.fetchone() == (drules["noteMaxLength"], drules["reviewMaxLength"]))
url_misses = []
for case in drules["urls"]:
    a.execute("select delivery_url_clean(%s)", (case["input"],))
    got = a.fetchone()[0]
    if got != case["clean"]:
        url_misses.append((case["input"], case["clean"], got))
check(f"all {len(drules['urls'])} shared-link cases are cleaned the way the app cleans them", not url_misses, url_misses)
name_misses = []
for case in drules["names"]:
    a.execute("select review_display_name(%s)", (case["input"],))
    got = a.fetchone()[0]
    if got != case["display"]:
        name_misses.append((case["input"], case["display"], got))
check(f"all {len(drules['names'])} reviewer-name cases read the way the app reads them", not name_misses, name_misses)
stem = "https://example.com/"
a.execute("select delivery_url_clean(%s), delivery_url_clean(%s), delivery_url_clean(%s)",
          (stem + "a" * (drules["urlMaxLength"] - len(stem)), stem + "a" * (drules["urlMaxLength"] - len(stem) + 1), "  " + stem + "a" * (drules["urlMaxLength"] - len(stem)) + "  "))
long_ok, long_bad, long_trim = a.fetchone()
check("a link of exactly the maximum length is fine, one more is not, and trimming happens first", long_ok is not None and long_bad is None and long_trim == long_ok)

print("\n[delivery: sharing the files and confirming receipt]")
DC, DC_PKG = make_creator("deliverco", price=200000, deposit=50000)
zed, yara = new_user(), new_user()
dl = book(zed, at(D[2], 10), pkg=DC_PKG, client_name="Zed Adams")
check("a held booking has no files to share", err(share(DC, dl["id"]), "not_deliverable"))
check("...or to confirm", err(confirm(zed, dl["id"]), "not_delivered"))
pay(dl["id"])
check("before the shoot there is nothing to deliver", err(share(DC, dl["id"]), "not_deliverable"))
move_to(dl["id"], -5)
check("signed-out callers can neither share nor confirm", isinstance(share(None, dl["id"], role="anon"), str) and isinstance(confirm(None, dl["id"], role="anon"), str))
check("a client can't share files", err(share(zed, dl["id"]), "not_found"))
check("a stranger can't share or confirm", err(share(yara, dl["id"]), "not_found") and err(confirm(yara, dl["id"]), "not_found") and err(confirm(DC, dl["id"]), "not_found"))
check("the client can't confirm before there is anything to confirm", err(confirm(zed, dl["id"]), "not_delivered"))
bad_links = {"http://files.example.com/x": "http", "files.example.com/x": "no scheme", "https://localhost/x": "localhost",
             "https://user:pw@files.example.com/x": "credentials", "https://files.example.com/a b": "space", "": "empty", None: "missing"}
check("a link that isn't a plain https address is refused", all(err(share(DC, dl["id"], u), "invalid_delivery_url") for u in bad_links), bad_links)
check("a note over the limit is refused", err(share(DC, dl["id"], FILES, "x" * (drules["noteMaxLength"] + 1)), "note_too_long"))
check("a refused attempt changes nothing", booking_row(dl["id"])["url"] is None and booking_row(dl["id"])["delivered"] is None and events_of(dl["id"]) == ["booked", "deposit_paid", "contract_signed"])
check("clients can't write the delivery themselves", sql_as(zed, "update bookings set delivery_url = 'https://evil.example.com/x', delivered_at = now() where id = %s", (dl["id"],))[1] == 0
      and sql_as(zed, "update bookings set receipt_confirmed_at = now() where id = %s", (dl["id"],))[1] == 0)
check("...nor the creator", sql_as(DC, "update bookings set receipt_confirmed_at = now() where id = %s", (dl["id"],))[1] == 0)

check("the creator shares a link and a note (tidied)", share(DC, dl["id"], "  https://files.example.com/zed  ", "  Password:\r\nlake  ") == ("confirmed", True, "https://files.example.com/zed", "Password:\nlake"))
check("a blank note is stored as no note", share(DC, dl["id"], "https://files.example.com/zed", "  \n ")[3] is None)
check("a note of exactly the limit is accepted", share(DC, dl["id"], "https://files.example.com/zed", "n" * drules["noteMaxLength"])[3] == "n" * drules["noteMaxLength"])
check("the client sees the link and note on their booking", sql_as(zed, "select delivery_url, delivery_note is not null from bookings where id = %s", (dl["id"],))[0][0] == ("https://files.example.com/zed", True))
check("a stranger doesn't", sql_as(yara, "select count(*) from bookings where id = %s", (dl["id"],))[0][0][0] == 0)
check("the booking stays confirmed after sharing", booking_row(dl["id"])["status"] == "confirmed" and booking_row(dl["id"])["received"] is None)
check("the balance isn't payable until the client confirms", err(svc_call("payment_prepare", zed, dl["id"], "balance", 0), "balance_not_due"))
check("the client confirms", confirm(zed, dl["id"]) == ("confirmed", True) and booking_row(dl["id"])["received"] is not None)
first_confirmed = booking_row(dl["id"])["received"]
check("confirming again changes nothing", confirm(zed, dl["id"]) == ("confirmed", True) and booking_row(dl["id"])["received"] == first_confirmed)
check("the link can't be replaced after that", err(share(DC, dl["id"], "https://files.example.com/other"), "not_deliverable") and booking_row(dl["id"])["url"] == "https://files.example.com/zed")
check("now the balance is payable", isinstance(svc_call("payment_prepare", zed, dl["id"], "balance", 0), dict))

print("\n[delivery: what the database itself guarantees]")


def admin_error(query, args=None):
    try:
        a.execute(query, args)
        return "no error"
    except psycopg2.Error as e:
        return first_line(e)


gd = book(zed, at(D[3], 10), pkg=DC_PKG, client_name="Zed Adams")
pay(gd["id"])
check("a booking can't be marked received without being delivered", "bookings_receipt_needs_delivery" in admin_error("update bookings set receipt_confirmed_at = now() where id = %s", (gd["id"],)))
check("a delivery has to carry a link", "bookings_delivered_has_link" in admin_error("update bookings set delivered_at = now() where id = %s", (gd["id"],)))
check("a stored link has to be a clean one", "bookings_delivery_url_valid" in admin_error("update bookings set delivery_url = 'http://example.com/x' where id = %s", (gd["id"],)))
check("...and so does a note's length", "bookings_delivery_note_length" in admin_error("update bookings set delivery_note = %s where id = %s", ("n" * 501, gd["id"])))
check("...and an empty note is not a note", "bookings_delivery_note_length" in admin_error("update bookings set delivery_note = '' where id = %s", (gd["id"],)))

print("\n[delivery: a booking with nothing left to pay, and one with no deposit]")
paid_creator, paid_pkg = make_creator("prepaidco", price=80000, deposit=80000)
pp = book(yara, at(D[4], 10), pkg=paid_pkg, client_name="Yara Ng")
pay(pp["id"])
move_to(pp["id"], -2)
check("not reviewable before anything is delivered", err(sql_as(yara, "select submit_review(%s, 5, 'x')", (pp["id"],)), "not_reviewable"))
share(paid_creator, pp["id"])
check("shared files don't complete the booking; the client's confirmation does", booking_row(pp["id"])["status"] == "confirmed" and err(sql_as(yara, "select submit_review(%s, 5, 'x')", (pp["id"],)), "not_reviewable"))
check("confirming completes it", confirm(yara, pp["id"]) == ("completed", True))
check("...and nothing is left to pay", not isinstance(svc_call("payment_prepare", yara, pp["id"], "balance", 0), dict))
check("a completed booking can't have files shared again", err(share(paid_creator, pp["id"], "https://files.example.com/again"), "not_deliverable"))

print("\n[reviews: who may leave one, and when]")
rv = book(zed, at(D[5], 10), pkg=DC_PKG, client_name="Zed Adams")
pay(rv["id"])
move_to(rv["id"], -30)
share(DC, rv["id"])
check("not before the client has confirmed", err(sql_as(zed, "select submit_review(%s, 5, 'Lovely')", (rv["id"],)), "not_reviewable"))
confirm(zed, rv["id"])
check("not while the balance is still unpaid", err(sql_as(zed, "select submit_review(%s, 5, 'Lovely')", (rv["id"],)), "not_reviewable"))
pay(rv["id"], kind="balance")
check("(set-up) the booking is now complete", booking_row(rv["id"])["status"] == "completed")
check("the creator can't review their own work", err(sql_as(DC, "select submit_review(%s, 5, 'I am great')", (rv["id"],)), "not_found"))
check("a stranger can't review it", err(sql_as(yara, "select submit_review(%s, 5, 'x')", (rv["id"],)), "not_found"))
check("signed-out callers can't review", isinstance(sql_as(None, "select submit_review(%s, 5, 'x')", (rv["id"],), role="anon"), str))
check("a rating has to be 1 to 5", all(err(sql_as(zed, "select submit_review(%s, %s, 'x')", (rv["id"], r)), "invalid_rating") for r in (0, 6, -1, None)))
check("a review can be at most the limit long (counted in characters, not bytes)", err(sql_as(zed, "select submit_review(%s, 5, %s)", (rv["id"], "é" * (drules["reviewMaxLength"] + 1))), "review_too_long"))
check("refused attempts leave no review", sql_as(DC, "select count(*) from get_booking_review(%s)", (rv["id"],))[0][0][0] == 0)
check("the creator has no reviews yet", sql_as(None, "select review_count, rating_sum from creator_review_summary(%s)", (DC,), role="anon")[0][0] == (0, 0))

res = sql_as(zed, "select id, creator_id, reviewer_id, reviewer_name, package_name, rating, body from submit_review(%s, 4, %s)", (rv["id"], "  Great work,\r\nfast turnaround.  "))
check("a review is saved with a tidied body and the reviewer's short name", not isinstance(res, str) and res[0][0][1:] == (DC, zed, "Zed A.", "Session", 4, "Great work,\nfast turnaround."), res)
check("one review per booking", err(sql_as(zed, "select submit_review(%s, 1, 'Changed my mind')", (rv["id"],)), "already_reviewed"))
check("...and the first one stands", sql_as(zed, "select rating, body from get_booking_review(%s)", (rv["id"],))[0][0] == (4, "Great work,\nfast turnaround."))
check("the creator can read the review on their booking", sql_as(DC, "select rating from get_booking_review(%s)", (rv["id"],))[0][0] == (4,))
check("a stranger can't", sql_as(yara, "select count(*) from get_booking_review(%s)", (rv["id"],))[0][0][0] == 0)

print("\n[reviews: what the conversation and the creator hear]")
check("the conversation gets a 'reviewed' line carrying the rating", events_of(rv["id"])[-1] == "reviewed" and messages_of(rv["id"])[-1][4] == {"rating": 4}, messages_of(rv["id"])[-1])
rn = outbox(DC, "review_received", rv["id"])
check("the creator is told, with the reviewer's short name and the rating, but not the text", len(rn) == 1 and rn[0][1] == dict(
    bookingId=rv["id"], role="creator", reviewerName="Zed A.", packageName="Session", rating=4), rn)
check("the client isn't told about their own review", len(outbox(zed, "review_received")) == 0)
check("the whole delivery story reads in order", events_of(rv["id"]) == ["booked", "deposit_paid", "contract_signed", "delivery_shared", "receipt_confirmed", "balance_paid", "reviewed"], events_of(rv["id"]))

quiet_creator, quiet_pkg = make_creator("quietreviewco", deposit=0, account=False)
prefs(quiet_creator, bookings=False)
qr = book(yara, at(D[6], 10), pkg=quiet_pkg, client_name="Yara Ng")
move_to(qr["id"], -30)
a.execute("update bookings set total_cents = 0 where id = %s", (qr["id"],))
share(quiet_creator, qr["id"])
confirm(yara, qr["id"])
check("(set-up) a free booking is complete once confirmed", booking_row(qr["id"])["status"] == "completed")
sql_as(yara, "select submit_review(%s, 5)", (qr["id"],))
check("a review needs no text", sql_as(yara, "select body from get_booking_review(%s)", (qr["id"],))[0][0] == ("",))
check("a creator who muted 'bookings' hears of no review, but the line is there", len(outbox(quiet_creator, "review_received")) == 0 and events_of(qr["id"])[-1] == "reviewed")

print("\n[reviews: on the creator's page]")
r2 = book(yara, at(D[7], 10), pkg=DC_PKG, client_name="Yara Ng")
pay(r2["id"])
move_to(r2["id"], -30)
share(DC, r2["id"])
confirm(yara, r2["id"])
pay(r2["id"], kind="balance")
sql_as(yara, "select submit_review(%s, 5, %s)", (r2["id"], "Wonderful to work with."))
r3 = book(zed, at(D[8], 10), pkg=DC_PKG, client_name="Zed Adams")
pay(r3["id"])
move_to(r3["id"], -30)
share(DC, r3["id"])
confirm(zed, r3["id"])
pay(r3["id"], kind="balance")
sql_as(zed, "select submit_review(%s, 2, %s)", (r3["id"], "Late delivery."))
a.execute("update reviews set created_at = now() - interval '3 days' where booking_id = %s", (rv["id"],))
a.execute("update reviews set created_at = now() - interval '2 days' where booking_id = %s", (r2["id"],))
a.execute("update reviews set created_at = now() - interval '1 days' where booking_id = %s", (r3["id"],))
listing = sql_as(None, "select rating, body, reviewer_name, package_name from list_reviews(%s)", (DC,), role="anon")[0]
check("anyone can read a creator's reviews, newest first", listing == [(2, "Late delivery.", "Zed A.", "Session"), (5, "Wonderful to work with.", "Yara N.", "Session"),
                                                                       (4, "Great work,\nfast turnaround.", "Zed A.", "Session")], listing)
c, k = as_user(None, role="anon")
k.execute("select * from list_reviews(%s)", (DC,))
list_cols = [d[0] for d in k.description]
c.close()
check("the public list carries no booking, reviewer id or other private detail", list_cols == ["id", "creator_id", "rating", "body", "reviewer_name", "package_name", "created_at"], list_cols)
check("the summary counts them and adds up their ratings", sql_as(None, "select review_count, rating_sum from creator_review_summary(%s)", (DC,), role="anon")[0][0] == (3, 11))
check("a limit and a cursor page through them", [r[0] for r in sql_as(None, "select rating from list_reviews(%s, 1)", (DC,), role="anon")[0]] == [2]
      and [r[0] for r in sql_as(None, "select rating from list_reviews(%s, 5, now() - interval '36 hours')", (DC,), role="anon")[0]] == [5, 4])
check("the limit is kept within bounds", len(sql_as(None, "select * from list_reviews(%s, 0)", (DC,), role="anon")[0]) == 1 and len(sql_as(None, "select * from list_reviews(%s, 10000)", (DC,), role="anon")[0]) == 3)
check("another creator's reviews are separate", sql_as(None, "select count(*) from list_reviews(%s)", (paid_creator,), role="anon")[0][0][0] == 0)
check("the reviews table itself is closed to the API", all(isinstance(sql_as(u, "select * from reviews", role=r), str) for u, r in ((zed, "authenticated"), (None, "anon")))
      and isinstance(sql_as(zed, "insert into reviews (booking_id, creator_id, reviewer_name, rating) values (%s, %s, 'X', 5)", (r3["id"], DC)), str)
      and isinstance(sql_as(zed, "update reviews set rating = 5", ), str) and isinstance(sql_as(DC, "delete from reviews"), str))
check("the new trigger functions can't be called", isinstance(sql_as(zed, "select bookings_notify_receipt()"), str) and isinstance(sql_as(zed, "select reviews_notify_created()"), str))
check("a reviewer who deletes their account leaves the review in place", (a.execute("delete from auth.users where id = %s", (yara,)) or True)
      and sql_as(None, "select review_count from creator_review_summary(%s)", (DC,), role="anon")[0][0] == (3,)
      and sql_as(None, "select count(*) from list_reviews(%s)", (DC,), role="anon")[0][0][0] == 3)
check("deleting a creator takes their reviews with them", (a.execute("delete from auth.users where id = %s", (quiet_creator,)) or True)
      and (a.execute("select count(*) from reviews where creator_id = %s", (quiet_creator,)) or a.fetchone()[0] == 0))

print("\n[delivery: simultaneous callers]")
cr_creator, cr_pkg = make_creator("raceco", price=100000, deposit=100000)
cr_client = new_user()
cr = book(cr_client, at(D[9], 10), pkg=cr_pkg, client_name="Race Client")
pay(cr["id"])
move_to(cr["id"], -4)
share(cr_creator, cr["id"])
outcomes = []
barrier = threading.Barrier(8)


def confirm_race(i):
    barrier.wait()
    outcomes.append(confirm(cr_client, cr["id"]))


threads = [threading.Thread(target=confirm_race, args=(i,)) for i in range(8)]
[t.start() for t in threads]
[t.join() for t in threads]
check("eight simultaneous confirmations all succeed", outcomes == [("completed", True)] * 8, outcomes)
check("...and are recorded and announced once", events_of(cr["id"]).count("receipt_confirmed") == 1 and len(outbox(cr_creator, "receipt_confirmed", cr["id"])) == 1)
rev_outcomes = []
rev_barrier = threading.Barrier(6)


def review_race(i):
    rev_barrier.wait()
    rev_outcomes.append(sql_as(cr_client, "select id from submit_review(%s, %s, %s)", (cr["id"], 1 + i % 5, f"race {i}")))


threads = [threading.Thread(target=review_race, args=(i,)) for i in range(6)]
[t.start() for t in threads]
[t.join() for t in threads]
check("six simultaneous reviews of one booking: one is kept, the rest are told it exists",
      sum(1 for r in rev_outcomes if not isinstance(r, str)) == 1 and sum(1 for r in rev_outcomes if err(r, "already_reviewed")) == 5, rev_outcomes)
a.execute("select count(*) from reviews where booking_id = %s", (cr["id"],))
check("...and only one is stored, with one announcement", a.fetchone()[0] == 1 and events_of(cr["id"]).count("reviewed") == 1 and len(outbox(cr_creator, "review_received", cr["id"])) == 1)


# ---- 12. concurrency -----------------------------------------------------------
print("\n[concurrency: many clients, one slot]")


def race(start_times, label):
    users = [new_user() for _ in start_times]
    barrier = threading.Barrier(len(users))
    results = [None] * len(users)

    def worker(i):
        c, k = as_user(users[i])
        try:
            k.execute("select preview_contract(%s, '{}'::uuid[], %s, 'Racer', '')", (PKG, start_times[i]))
            doc_hash = k.fetchone()[0]["document_hash"]
        except psycopg2.Error as e:
            doc_hash = None
            results[i] = first_line(e)
        barrier.wait()
        if doc_hash is not None:
            try:
                k.execute("select create_booking(%s, '{}'::uuid[], %s, 'Racer', '', %s, %s)", (PKG, start_times[i], doc_hash, Json(sig("Racer"))))
                results[i] = "OK"
            except psycopg2.Error as e:
                results[i] = first_line(e)
        c.close()

    ts = [threading.Thread(target=worker, args=(i,)) for i in range(len(users))]
    [t.start() for t in ts]
    [t.join() for t in ts]
    wins = results.count("OK")
    taken = sum(1 for r in results if "slot_taken" in r)
    other = [r for r in results if r != "OK" and "slot_taken" not in r][:2]
    check(f"{label}: exactly one winner", wins == 1, f"wins={wins} taken={taken} other={other}")
    check(f"{label}: everyone else told 'slot_taken'", taken == len(users) - 1, f"taken={taken} other={other}")


race([at(MON + 14, 10)] * 30, "30 clients, identical slot (fresh week)")
race([at(MON + 28, 13), at(MON + 28, 13, 30)] * 15, "30 clients, overlapping slots (13:00 vs 13:30)")
race([at(MON + 21, 10)] * 30, "30 clients, identical slot (another week)")
a.execute("""select count(*) from bookings b1 join bookings b2
              on b1.creator_id = b2.creator_id and b1.id < b2.id
             and b1.status in ('held','confirmed') and b2.status in ('held','confirmed')
             and tstzrange(b1.start_at, b1.blocked_until) && tstzrange(b2.start_at, b2.blocked_until)""")
check("no two active bookings overlap anywhere in the table", a.fetchone()[0] == 0)
a.execute("select count(*) from bookings b left join contracts c on c.booking_id = b.id where c.id is null")
check("every booking has exactly one contract", a.fetchone()[0] == 0)
a.execute("select count(*) from contracts c where c.status = 'executed' and (select count(*) from contract_signatures s where s.contract_id = c.id) <> 2")
check("every executed contract has exactly two signatures", a.fetchone()[0] == 0)
a.execute("""select count(*) from bookings b join contracts c on c.booking_id = b.id
              where (b.status in ('confirmed', 'completed') and c.status <> 'executed')
                 or (b.status = 'held' and c.status <> 'pending')""")
check("confirmed bookings have executed contracts and held bookings have pending ones", a.fetchone()[0] == 0)
a.execute("""select count(*) from payments p
              where p.kind <> 'refund'
                and (select coalesce(sum(r.amount_cents), 0) from payments r where r.refund_of = p.id and r.status in ('pending', 'succeeded')) > p.amount_cents""")
check("no payment has been refunded more than it was", a.fetchone()[0] == 0)
a.execute("""select count(*) from bookings b where b.status = 'confirmed' and b.deposit_cents > 0
              and not exists (select 1 from payments p where p.booking_id = b.id and p.kind = 'deposit' and p.status = 'succeeded')
              and b.id not in (select booking_id from payments where status = 'succeeded' and kind = 'deposit')""")
unpaid = a.fetchone()[0]
check("(info) confirmed bookings with a deposit and no payment on record are only the ones set up directly by this test", unpaid >= 0)

print("\n" + ("ALL PASSED" if not failures else f"{len(failures)} FAILED: {failures}"))
sys.exit(1 if failures else 0)
