"""Applies the migrations to a throwaway Postgres and checks the featured creators on a client's Home: who is a
candidate, the order they come in (shared with the app through SlateTests/Fixtures/featured_rules.json), what each
tile is given, the limit, and who may ask.

Needs a Postgres server (16 recommended) and psycopg2, like the other scripts here:

    PGPORT=5432 python3 ios/supabase/tests/featured_rules.py
"""
import json
import os
import pathlib
import sys
import uuid

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
FIXTURE = HERE.parents[1] / "SlateTests" / "Fixtures" / "featured_rules.json"
DB = "slate_featured"


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

# These checks are about featuring, not about contracts (the other scripts cover those), so let a package be published
# without one.
a.execute("alter table packages drop constraint published_needs_contract")

rules = json.loads(FIXTURE.read_text())
failures = []


def check(name, cond, detail=""):
    print(("  ok   " if cond else "  FAIL ") + name + (f"   [{detail}]" if (detail and not cond) else ""))
    if not cond:
        failures.append(name)


def featured(specialty=None, limit="default", role="authenticated", columns="handle"):
    """What a signed-in person is shown, in order, or 'ERR:...'."""
    c = connect()
    k = c.cursor()
    try:
        k.execute("select set_config('request.jwt.claim.sub', %s, false)", (str(uuid.uuid4()),))
        k.execute(f"set role {role}")
        if limit == "default":
            k.execute(f"select {columns} from featured_creators(%s)", (specialty,))
        else:
            k.execute(f"select {columns} from featured_creators(%s, %s)", (specialty, limit))
        rows = k.fetchall()
        return [r[0] for r in rows] if "," not in columns else rows
    except psycopg2.Error as e:
        return "ERR:" + (e.pgerror or str(e)).strip().splitlines()[0]
    finally:
        c.close()


def make_creator(handle, specialties=(), uid=None, created="2026-03-01", packages=(), pieces=0, ratings=()):
    uid = uid or str(uuid.uuid4())
    a.execute("insert into auth.users (id, email) values (%s, %s)", (uid, f"{uid[:8]}@example.com"))
    a.execute(
        "insert into creator_profiles (id, handle, display_name, specialties, created_at) values (%s,%s,%s,%s,%s)",
        (uid, handle, handle.replace("-", " ").title(), list(specialties), f"{created}T12:00:00Z"),
    )
    for i, p in enumerate(packages):
        a.execute(
            "insert into packages (creator_id, name, price_cents, duration_minutes, is_published, position) values (%s,%s,%s,%s,%s,%s)",
            (uid, f"Package {i + 1}", p["cents"], 60, p["published"], i),
        )
    for i in range(pieces):
        a.execute(
            "insert into portfolio_items (creator_id, kind, position, image_path, thumbnail_path) values (%s,'photo',%s,%s,%s)",
            (uid, i, f"{handle}/{i}.jpg", f"{handle}/{i}-thumb.jpg"),
        )
    if ratings:
        # Reviews hang off real bookings; these checks are about ordering, so skip the booking rows they point at.
        a.execute("set session_replication_role = replica")
        for rating in ratings:
            a.execute(
                "insert into reviews (booking_id, creator_id, reviewer_name, rating) values (%s,%s,'Alex R.',%s)",
                (str(uuid.uuid4()), uid, rating),
            )
        a.execute("set session_replication_role = origin")
    return uid


print("\n[the order, shared with the app]")
for c in rules["creators"]:
    make_creator(c["handle"], c["specialties"], uid=c["id"], created=c["created"], packages=c["packages"],
                 pieces=c["portfolio"], ratings=c["ratings"])
# Never candidates, however good they look: nothing a client could book.
make_creator("draft-only", ["weddings"], packages=[{"cents": 50000, "published": False}], pieces=9, ratings=[5] * 30)
make_creator("no-packages", ["weddings"], packages=[], pieces=9, ratings=[5] * 30)

got = featured()
check("everyone with a published package comes in the shared order", got == rules["order"], got)
check("asking twice gives the same order", featured() == got)
check("a creator with only hidden packages is never shown", "draft-only" not in got, got)
check("a creator with no packages is never shown", "no-packages" not in got, got)
check("a few good reviews can't beat having work to show", got.index("stars-no-work") == len(got) - 1, got)

print("\n[by what they shoot]")
for specialty, expected in rules["bySpecialty"].items():
    found = featured(specialty)
    check(f"{specialty}: only creators who shoot it, in the same order", found == expected, found)
check("a specialty with nobody shows nothing", featured("aerial") == [])
check("text that isn't a specialty shows nothing", featured("x'; drop table packages; --") == [])
check("the table is still there afterwards", (a.execute("select count(*) from packages") or a.fetchone()[0]) > 0)

print("\n[what each tile is given]")
tiles = {r[0]: r for r in featured(columns="handle, cover_path, starting_price_cents, currency_code, review_count, rating_sum, display_name, kind")}
for c in rules["creators"]:
    row = tiles[c["handle"]]
    cheapest = min(p["cents"] for p in c["packages"] if p["published"])
    check(f"{c['handle']}: the first piece is the cover", row[1] == (f"{c['handle']}/0-thumb.jpg" if c["portfolio"] else None), row[1])
    check(f"{c['handle']}: the lowest published price", row[2] == cheapest, row[2])
    check(f"{c['handle']}: the review totals", (row[4], row[5]) == (len(c["ratings"]), sum(c["ratings"])), (row[4], row[5]))
c = connect()
k = c.cursor()
k.execute("select * from featured_creators(null)")
check("the columns are the ones the app reads", [d.name for d in k.description] == rules["rowColumns"], [d.name for d in k.description])
c.close()
check("the currency comes with the price", all(r[3] == "USD" for r in tiles.values()))
check("the profile comes with it", tiles["ivy-ten-fives"][6] == "Ivy Ten Fives" and tiles["ivy-ten-fives"][7] == "person",
      (tiles["ivy-ten-fives"][6], tiles["ivy-ten-fives"][7]))

print("\n[the limit]")
for i in range(20):
    make_creator(f"bulk-{i:02d}", ["food"], created="2026-01-15", packages=[{"cents": 10000, "published": True}], pieces=1)
check("the default is 12", len(featured()) == rules["defaultLimit"], len(featured()))
check("a limit of nothing means the default", len(featured(limit=None)) == rules["defaultLimit"], len(featured(limit=None)))
for case in rules["limits"]:
    got_n = len(featured(limit=case["asked"]))
    check(f"asking for {case['asked']} gives {case['clamped']}", got_n == case["clamped"], got_n)
check("the best come first when the list is cut short", featured(limit=3) == rules["order"][:3], featured(limit=3))

print("\n[who may ask]")
check("a signed-in person can", isinstance(featured(), list))
anon = featured(role="anon")
check("someone who isn't signed in can't", isinstance(anon, str) and "permission denied" in anon, anon)

print()
if failures:
    print(f"{len(failures)} FAILED:")
    for f in failures:
        print("  -", f)
    sys.exit(1)
print("all featured-creator checks passed")
