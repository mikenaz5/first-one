"""Applies the migrations to a throwaway Postgres and tries to break the booking rules.

Needs a Postgres server (16 recommended) and psycopg2. Connection comes from the usual
environment variables (PGHOST, PGPORT, PGUSER, PGPASSWORD); defaults suit a local trust-auth server.
The Supabase pieces the migrations lean on (auth, storage, API roles) are stubbed in stubs.sql.

    PGPORT=5432 python3 ios/supabase/tests/booking_rules.py
"""
import json, os, pathlib, sys, threading, uuid, datetime as dt

import psycopg2

HOST = dict(
    host=os.environ.get("PGHOST", "127.0.0.1"),
    port=int(os.environ.get("PGPORT", "5432")),
    user=os.environ.get("PGUSER", "postgres"),
)
if os.environ.get("PGPASSWORD"):
    HOST["password"] = os.environ["PGPASSWORD"]
HERE = pathlib.Path(__file__).resolve().parent
MIG = HERE.parent / "migrations"
TZ = "America/Chicago"

def connect(db="slate"):
    c = psycopg2.connect(dbname=db, **HOST); c.autocommit = True; return c

# ---- fresh database ---------------------------------------------------------
root = connect("postgres")
cur = root.cursor()
cur.execute("drop database if exists slate"); cur.execute("create database slate")
root.close()
admin = connect(); a = admin.cursor()
# roles are cluster-wide; create only once
a.execute("select 1 from pg_roles where rolname = 'anon'")
if a.fetchone():
    stubs = (HERE / "stubs.sql").read_text().replace("create role anon nologin;", "").replace("create role authenticated nologin;", "").replace("create role service_role nologin bypassrls;", "")
else:
    stubs = (HERE / "stubs.sql").read_text()
a.execute(stubs)
for f in sorted(MIG.glob("*.sql")):
    a.execute(f.read_text()); print("applied", f.name)

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
monday = a.fetchone()[0]              # a Monday, two weeks out
def at(day_offset, hh, mm=0, ss=0):
    """A timestamptz at local wall time in the creator's zone. day_offset 0 = Monday."""
    a.execute("select ((%s::date + %s) + make_time(%s,%s,%s)) at time zone %s",
              (monday, day_offset, hh, mm, ss, TZ))
    return a.fetchone()[0]
MON, TUE, WED, THU, FRI, SAT = 0, 1, 2, 3, 4, 5

E1, DRONE, RUSH = str(uuid.uuid4()), str(uuid.uuid4()), str(uuid.uuid4())
add_ons = [
    dict(id=E1, kind="extraTime", name="Extra hour", priceCents=15000, extraMinutes=60, turnaroundDeltaDays=0),
    dict(id=DRONE, kind="drone", name="Drone footage", priceCents=25000, extraMinutes=0, turnaroundDeltaDays=0),
    dict(id=RUSH, kind="rush", name="Rush delivery", priceCents=10000, extraMinutes=0, turnaroundDeltaDays=-3),
]
a.execute("""insert into packages (creator_id, name, price_cents, duration_minutes, deposit_cents, add_ons, deliverables)
             values (%s, 'Portrait session', 200000, 60, 50000, %s, %s) returning id""",
          (creator, json.dumps(add_ons), ["30 edited photos"]))
PKG = a.fetchone()[0]
weekly = [dict(weekday=d, window=dict(startMinute=540, endMinute=1020)) for d in range(2, 7)]
a.execute("""insert into availability_settings (creator_id, time_zone, weekly, min_notice_hours, max_advance_days, buffer_minutes, slot_interval_minutes)
             values (%s, %s, %s, 2, 180, 30, 30)""", (creator, TZ, json.dumps(weekly)))

# ---- helpers ----------------------------------------------------------------
def as_user(uid, role="authenticated"):
    c = connect(); k = c.cursor()
    if uid: k.execute("select set_config('request.jwt.claim.sub', %s, false)", (uid,))
    k.execute(f"set role {role}")
    return c, k

def book(uid, start, ons=(), pkg=None, role="authenticated"):
    c, k = as_user(uid, role)
    try:
        k.execute("select * from create_booking(%s, %s::uuid[], %s, 'Test Client', '')", (pkg or PKG, list(ons), start))
        cols = [d[0] for d in k.description]
        return dict(zip(cols, k.fetchone()))
    except psycopg2.Error as e:
        msg = (e.pgerror or str(e)).strip().splitlines()[0]
        return "ERR:" + msg
    finally:
        c.close()

failures = []
def check(name, cond, detail=""):
    print(("  ok   " if cond else "  FAIL ") + name + (f"   [{detail}]" if (detail and not cond) else ""))
    if not cond: failures.append(name)

def err(result, token):
    return isinstance(result, str) and token in result

def cancel(uid, bid):
    c, k = as_user(uid)
    try:
        k.execute("select * from cancel_booking(%s)", (bid,)); return "ok"
    except psycopg2.Error as e:
        return "ERR:" + (e.pgerror or str(e)).strip().splitlines()[0]
    finally: c.close()

# ---- 1. happy path and server-side pricing -----------------------------------
print("\n[pricing and snapshot]")
r1 = book(alice, at(WED, 10), [DRONE])
check("books an open slot", isinstance(r1, dict), r1)
if isinstance(r1, dict):
    check("price is computed server-side (package + drone)", r1["total_cents"] == 225000, r1["total_cents"])
    check("deposit comes from the package", r1["deposit_cents"] == 50000, r1["deposit_cents"])
    check("status is confirmed", r1["status"] == "confirmed")
    check("end = start + 60 min", r1["end_at"] - r1["start_at"] == dt.timedelta(minutes=60))
    check("blocked_until = end + 30 min buffer", r1["blocked_until"] - r1["end_at"] == dt.timedelta(minutes=30))
    check("package and creator names are snapshotted", r1["package_name"] == "Portrait session" and r1["creator_name"] == "Maya Chen")
    check("add-on is snapshotted", json.loads(json.dumps(r1["add_ons"]))[0]["name"] == "Drone footage")

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
k.execute("insert into busy_blocks (creator_id, starts_at, ends_at) values (%s,%s,%s)", (creator, b_start, b_end)); c.close()
check("start inside busy time is refused", err(book(alice, at(TUE, 11)), "slot_unavailable"))
check("start ending into busy time is refused (10:30 + 60 + buffer overlaps 11:00)", err(book(alice, at(TUE, 10, 30)), "slot_unavailable"))
check("start inside the buffer after busy time (12:00) is refused", err(book(alice, at(TUE, 12)), "slot_unavailable"))
check("start once the buffer has passed (12:30) is allowed", isinstance(book(alice, at(TUE, 12, 30)), dict))
c, k = as_user(alice); k.execute("select count(*) from busy_blocks"); n = k.fetchone()[0]; c.close()
check("clients cannot read busy_blocks", n == 0, n)

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

# ---- 6. cancel ----------------------------------------------------------------
print("\n[cancel]")
check("a stranger cannot cancel", err(cancel(other_creator, r1["id"]), "not_cancellable"))
check("another client cannot cancel", err(cancel(bob, r1["id"]), "not_cancellable"))
check("the client can cancel", cancel(alice, r1["id"]) == "ok")
check("cancelling twice is refused", err(cancel(alice, r1["id"]), "not_cancellable"))
r_reuse = book(bob, at(WED, 10))
check("a cancelled slot can be booked again", isinstance(r_reuse, dict), r_reuse)
check("the creator can cancel a client's booking", cancel(creator, r_reuse["id"]) == "ok")

# ---- 7. RLS -------------------------------------------------------------------
print("\n[row level security]")
def visible(uid):
    c, k = as_user(uid); k.execute("select count(*) from bookings"); n = k.fetchone()[0]; c.close(); return n
a.execute("select count(*) from bookings where client_id = %s", (bob,)); bob_n = a.fetchone()[0]
a.execute("select count(*) from bookings"); all_n = a.fetchone()[0]
check("a client sees only their own bookings", visible(bob) == bob_n, (visible(bob), bob_n))
check("the creator sees all of theirs", visible(creator) == all_n, (visible(creator), all_n))
check("an unrelated creator sees none", visible(other_creator) == 0)
c, k = as_user(alice)
try:
    k.execute("insert into bookings (creator_id, client_id, creator_name, package_name, start_at, end_at, blocked_until, time_zone, currency_code, total_cents, deposit_cents) values (%s,%s,'x','x',now()+interval '90 days',now()+interval '90 days 1 hour',now()+interval '90 days 2 hours','UTC','USD',1,1)", (creator, alice))
    check("direct INSERT into bookings is blocked", False)
except psycopg2.Error as e:
    check("direct INSERT into bookings is blocked", "row-level security" in str(e) or "permission denied" in str(e), str(e)[:80])
k.execute("update bookings set total_cents = 1 where client_id = %s", (alice,))
check("direct UPDATE of bookings changes nothing", k.rowcount == 0, k.rowcount)
k.execute("delete from bookings where client_id = %s", (alice,))
check("direct DELETE of bookings changes nothing", k.rowcount == 0, k.rowcount)
c.close()
c, k = as_user(alice)
k.execute("update packages set price_cents = 1 where id = %s", (PKG,))
check("a client cannot edit someone's package", k.rowcount == 0, k.rowcount); c.close()
c, k = as_user(alice)
k.execute("select * from get_busy_intervals(%s, %s, %s)", (creator, at(MON, 0), at(SAT, 23)))
cols = [d[0] for d in k.description]; rows = k.fetchall(); c.close()
check("busy intervals expose only time ranges and kind", cols == ["starts_at", "ends_at", "kind"], cols)
check("busy intervals include other people's bookings as bare ranges", len(rows) >= 2 and {r[2] for r in rows} <= {"booking", "external"})

# ---- 8. concurrency -----------------------------------------------------------
print("\n[concurrency: many clients, one slot]")
def race(start_times, label):
    users = [new_user() for _ in start_times]
    barrier = threading.Barrier(len(users))
    results = [None] * len(users)
    def worker(i):
        c, k = as_user(users[i])
        barrier.wait()
        try:
            k.execute("select id from create_booking(%s, '{}'::uuid[], %s, 'Racer', '')", (PKG, start_times[i]))
            results[i] = "OK"
        except psycopg2.Error as e:
            results[i] = (e.pgerror or str(e)).strip().splitlines()[0]
        finally:
            c.close()
    ts = [threading.Thread(target=worker, args=(i,)) for i in range(len(users))]
    [t.start() for t in ts]; [t.join() for t in ts]
    wins = results.count("OK"); taken = sum(1 for r in results if "slot_taken" in r)
    check(f"{label}: exactly one winner", wins == 1, f"wins={wins} taken={taken} other={[r for r in results if r!='OK' and 'slot_taken' not in r][:2]}")
    check(f"{label}: everyone else told 'slot_taken'", taken == len(users) - 1, f"taken={taken}")

race([at(MON + 14, 10)] * 30, "30 clients, identical slot (fresh week)")
race([at(FRI, 13), at(FRI, 13, 30)] * 15, "30 clients, overlapping slots (13:00 vs 13:30)")
race([at(MON + 21, 10)] * 30, "30 clients, identical slot (another week)")
a.execute("""select count(*) from bookings b1 join bookings b2
              on b1.creator_id = b2.creator_id and b1.id < b2.id
             and b1.status in ('held','confirmed') and b2.status in ('held','confirmed')
             and tstzrange(b1.start_at, b1.blocked_until) && tstzrange(b2.start_at, b2.blocked_until)""")
check("no two active bookings overlap anywhere in the table", a.fetchone()[0] == 0)

print("\n" + ("ALL PASSED" if not failures else f"{len(failures)} FAILED: {failures}"))
sys.exit(1 if failures else 0)
