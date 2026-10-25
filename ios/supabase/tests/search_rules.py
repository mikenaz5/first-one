"""Applies the migrations to a throwaway Postgres and checks creator search: what it finds, in what order, what it
never shows, and that odd characters in a search mean themselves.

Needs a Postgres server (16 recommended) and psycopg2, like the other scripts here:

    PGPORT=5432 python3 ios/supabase/tests/search_rules.py
"""
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
DB = "slate_search"


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

# These checks are about search, not about contracts (the other scripts cover those), so let a package be published
# without one.
a.execute("alter table packages drop constraint published_needs_contract")

failures = []


def check(name, cond, detail=""):
    print(("  ok   " if cond else "  FAIL ") + name + (f"   [{detail}]" if (detail and not cond) else ""))
    if not cond:
        failures.append(name)


def search(query, limit=None, role="authenticated"):
    """Handles of what a signed-in person finds, in order, or 'ERR:...'."""
    c = connect()
    k = c.cursor()
    try:
        k.execute("select set_config('request.jwt.claim.sub', %s, false)", (str(uuid.uuid4()),))
        k.execute(f"set role {role}")
        if limit is None:
            k.execute("select handle from search_creators(%s)", (query,))
        else:
            k.execute("select handle from search_creators(%s, %s)", (query, limit))
        return [r[0] for r in k.fetchall()]
    except psycopg2.Error as e:
        return "ERR:" + (e.pgerror or str(e)).strip().splitlines()[0]
    finally:
        c.close()


def creator(handle, name, specialties=(), packages=1, published=True, bio=""):
    uid = str(uuid.uuid4())
    a.execute("insert into auth.users (id, email) values (%s, %s)", (uid, f"{uid[:8]}@example.com"))
    a.execute("insert into creator_profiles (id, handle, display_name, specialties, bio) values (%s,%s,%s,%s,%s)",
              (uid, handle, name, list(specialties), bio))
    for i in range(packages):
        a.execute("insert into packages (creator_id, name, price_cents, duration_minutes, is_published) values (%s,%s,%s,%s,%s)",
                  (uid, f"Package {i + 1}", 100000, 60, published))
    return uid


print("\n[who is found]")
creator("mayachen", "Maya Chen", ["weddings", "portraits"])
creator("maya-films", "Northlight Films", ["commercial", "realEstate"])
creator("dana-lens", "Dana Lens", ["portraits"])
creator("draft-only", "Draft Dana", ["weddings"], published=False)
creator("no-packages", "Dana Nothing", ["weddings"], packages=0)
creator("percent_50", "Fifty% Studio", ["food"])

check("a name finds the creator", search("chen") == ["mayachen"], search("chen"))
check("case doesn't matter", search("MAYA CHEN") == ["mayachen"], search("MAYA CHEN"))
check("a link name finds the creator", search("dana-lens") == ["dana-lens"], search("dana-lens"))
check("spaces around the words are ignored", search("   chen   ") == ["mayachen"], search("   chen   "))
check("a specialty finds creators", sorted(search("wedding")) == ["mayachen"], search("wedding"))
check("a specialty written with a space finds the camel-case one", search("real estate") == ["maya-films"], search("real estate"))
check("two creators can share a word", sorted(search("portrait")) == ["dana-lens", "mayachen"], search("portrait"))

print("\n[who is never found]")
check("a creator with only hidden packages isn't found", "draft-only" not in search("dana") and "draft-only" not in search("weddings"),
      search("dana"))
check("a creator with no packages isn't found", "no-packages" not in search("dana"), search("dana"))
check("a one-letter search finds nothing", search("m") == [], search("m"))
check("an empty search finds nothing", search("") == [] and search("   ") == [], (search(""), search("   ")))
check("a very long search finds nothing", search("x" * 61) == [], search("x" * 61))

print("\n[odd characters mean themselves]")
check("a percent sign isn't a wildcard", search("%%") == [] and search("%a") == [], (search("%%"), search("%a")))
check("an underscore isn't a wildcard", search("m_ya") == [], search("m_ya"))
check("a literal percent in a name can be found", search("fifty%") == ["percent_50"], search("fifty%"))
check("a literal underscore in a handle can be found", search("percent_50") == ["percent_50"], search("percent_50"))
check("a backslash is just a character", search("\\") == [] and search("a\\") == [], (search("\\"), search("a\\")))
check("a quote can't break out", search("x'; drop table packages; --") == [], search("x'; drop table packages; --"))
check("the table is still there afterwards", (a.execute("select count(*) from packages") or a.fetchone()[0]) == 5)

print("\n[order and limit]")
check("an exact link name comes first", search("maya")[0] in ("mayachen", "maya-films") and len(search("maya")) == 2, search("maya"))
creator("maya", "Zed Quill", ["music"])
check("an exact link name beats names that merely contain it", search("maya")[0] == "maya", search("maya"))
check("then names that start with it, then the rest", search("maya") == ["maya", "mayachen", "maya-films"] or
      search("maya")[:2] == ["maya", "mayachen"], search("maya"))
for i in range(35):
    creator(f"bulk-{i:02d}", f"Bulk Creator {i:02d}", ["food"])
check("the default limit is 20", len(search("bulk")) == 20, len(search("bulk")))
check("a limit can be asked for", len(search("bulk", 5)) == 5, len(search("bulk", 5)))
check("but never more than 30", len(search("bulk", 500)) == 30, len(search("bulk", 500)))
check("and never less than one", len(search("bulk", 0)) == 1 and len(search("bulk", -4)) == 1, (len(search("bulk", 0)), len(search("bulk", -4))))
check("results are in a steady order", search("bulk", 5) == [f"bulk-{i:02d}" for i in range(5)], search("bulk", 5))

print("\n[who may search]")
check("a signed-in person can search", isinstance(search("chen"), list))
anon = search("chen", role="anon")
check("someone who isn't signed in can't", isinstance(anon, str) and "permission denied" in anon, anon)

print()
if failures:
    print(f"{len(failures)} FAILED:")
    for f in failures:
        print("  -", f)
    sys.exit(1)
print("all search checks passed")
