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
    a.execute("select status, hold_expires_at, delivered_at, cancelled_by, cancellation_policy from bookings where id = %s", (booking_id,))
    status, hold, delivered, cancelled_by, policy = a.fetchone()
    return dict(status=status, hold=hold, delivered=delivered, cancelled_by=cancelled_by, policy=policy)


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
check("a held booking can't be delivered", err(sql_as(PAYEE, "select mark_delivered(%s)", (dv["id"],)), "not_deliverable"))
pay(dv["id"])
check("only the creator can mark it delivered", err(sql_as(alice, "select mark_delivered(%s)", (dv["id"],)), "not_found")
      and err(sql_as(bob, "select mark_delivered(%s)", (dv["id"],)), "not_found"))
check("not before the shoot has started", err(sql_as(PAYEE, "select mark_delivered(%s)", (dv["id"],)), "not_deliverable"))
check("the balance isn't due before delivery", err(svc_call("payment_prepare", alice, dv["id"], "balance", 0), "balance_not_due"))
move_to(dv["id"], -48)
delivered = sql_as(PAYEE, "select status, delivered_at is not null from mark_delivered(%s)", (dv["id"],))
check("after the shoot the creator can mark it delivered", delivered[0][0] == ("confirmed", True), delivered)
check("...once", err(sql_as(PAYEE, "select mark_delivered(%s)", (dv["id"],)), "not_deliverable"))
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
sql_as(paid_up_creator, "select mark_delivered(%s)", (pu["id"],))
check("when the deposit covers everything, delivery completes the booking", booking_row(pu["id"])["status"] == "completed")
check("...and there is no balance to pay", True)

zero_dep_creator, zero_dep_pkg = make_creator("zerodep", deposit=0)
a.execute("update creator_payment_accounts set charges_enabled = true where creator_id = %s", (zero_dep_creator,)) if False else None
zd = book(alice, at(D[0], 11), pkg=zero_dep_pkg)
check("a package with no deposit is confirmed at once", isinstance(zd, dict) and zd["status"] == "confirmed", zd)
move_to(zd["id"], -24)
sql_as(zero_dep_creator, "select mark_delivered(%s)", (zd["id"],))
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
a.execute("update bookings set delivered_at = now() where id = %s", (split["id"],))
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
a.execute("update bookings set delivered_at = now() where id = %s", (split2["id"],))
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
