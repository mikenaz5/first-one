"""Builds a small company in a throwaway Postgres and writes down exactly what each team RPC returns, as PostgREST would
send it, to SlateTests/Fixtures/team_rows.json. The Swift decoders for the Supabase backend are tested against that file,
so a renamed column or a changed shape fails a test instead of failing on someone's phone.

    PGPORT=5432 python3 ios/supabase/tests/dump_team_rows.py

Run it again after changing a team function's output, and commit the new file. `--check` (used by CI) writes nothing and
fails if the committed file no longer has the shape of what the functions return.
"""
import datetime
import json
import os
import pathlib
import sys
import uuid

import psycopg2
import psycopg2.extras

HOST = dict(host=os.environ.get("PGHOST", "127.0.0.1"), port=int(os.environ.get("PGPORT", "5432")), user=os.environ.get("PGUSER", "postgres"))
if os.environ.get("PGPASSWORD"):
    HOST["password"] = os.environ["PGPASSWORD"]
HERE = pathlib.Path(__file__).resolve().parent
MIG = HERE.parent / "migrations"
OUT = HERE.parent.parent / "SlateTests" / "Fixtures" / "team_rows.json"
DB = "slate_rows"
TZ = "America/Chicago"
Json = psycopg2.extras.Json


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
a.execute("update app_settings set value = value || '{\"required\": false}'::jsonb where key = 'billing'")


def sql_as(uid, query, args=None, role="authenticated"):
    c = connect()
    k = c.cursor()
    if uid:
        k.execute("select set_config('request.jwt.claim.sub', %s, false)", (uid,))
    k.execute(f"set role {role}")
    try:
        k.execute(query, args)
        return k.fetchall() if k.description else []
    finally:
        c.close()


def value(uid, query, args=None, role="authenticated"):
    """One jsonb value, the way PostgREST sends it."""
    return sql_as(uid, query, args, role)[0][0]


def rpc(uid, fn, *args, role="authenticated"):
    return value(uid, f"select to_jsonb({fn}({', '.join(['%s'] * len(args))}))", args, role)


def table(uid, fn, *args, role="authenticated"):
    """A function that returns rows, as a JSON array of objects."""
    return value(uid, f"select coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb) from {fn}({', '.join(['%s'] * len(args))}) t", args, role)


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
    return rpc(uid, "accept_invite", inv["token"], name)


a.execute("select (date_trunc('week', now() at time zone %s) + interval '2 weeks')::date", (TZ,))
monday = a.fetchone()[0]


def at(day_offset, hh, mm=0):
    a.execute("select ((%s::date + %s) + make_time(%s,%s,0)) at time zone %s", (monday, day_offset, hh, mm, TZ))
    return a.fetchone()[0]


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
WEEKLY = [dict(weekday=d, window=dict(startMinute=540, endMinute=1020)) for d in range(2, 7)]

out = {}

# ---- the company -------------------------------------------------------------
olivia = new_user("olivia-ng", "Olivia Ng")
add_signature(olivia, "Olivia Ng")
dee, mia, cal, kim, vee = new_user(), new_user("mia-k", "Mia K"), new_user("cal-r", "Cal R"), new_user("kim-t", "Kim T"), new_user("vee-t", "Vee T")
client, stranger = new_user(), new_user("sam-s", "Sam S")

out["team_config"] = rpc(None, "team_config", role="anon")
out["my_accounts_before"] = rpc(olivia, "my_accounts")
created = rpc(olivia, "org_create", "acme-films", "Acme Films", "Acme Films LLC", "1 Main St", "Weddings and film", ["weddings", "corporate"], "Austin, TX")
out["org_create"] = created
ORG = created["organization_id"]

# Invites: one is shown as it is created, one is resent, one expired, one accepted by a person with no profile.
first = rpc(olivia, "invite_create", ORG, "admin", "dee@example.com")
out["invite_create"] = first
out["invite_preview"] = rpc(dee, "invite_preview", first["token"])
out["accept_invite"] = rpc(dee, "accept_invite", first["token"], "Dee Okafor")
join(ORG, olivia, "manager", mia)
join(ORG, olivia, "creator", cal)
join(ORG, olivia, "creator", kim)
join(ORG, olivia, "viewer", vee)
add_signature(dee, "Dee Okafor")
for u in (olivia, dee, mia):
    sql_as(olivia, "select member_update(%s, %s, null, null, false)", (ORG, u))
pending = rpc(olivia, "invite_create", ORG, "creator", "new.hire@example.com")
resent = rpc(olivia, "invite_resend", pending["invite"]["id"])
out["invite_resend"] = resent
stale = rpc(olivia, "invite_create", ORG, "viewer", None)
a.execute("update invites set expires_at = now() - interval '1 day' where id = %s", (stale["invite"]["id"],))
out["invite_list"] = table(olivia, "invite_list", ORG)

out["org_overview_owner"] = rpc(olivia, "org_overview", ORG)
out["org_overview_creator"] = rpc(kim, "org_overview", ORG)
out["member_list_owner"] = table(olivia, "member_list", ORG)
out["member_list_admin"] = table(dee, "member_list", ORG)
out["org_public_team"] = table(None, "org_public_team", ORG, role="anon")
sql_as(kim, "select member_set_hours(%s, %s::jsonb)", (ORG, Json([dict(weekday=d, window=dict(startMinute=600, endMinute=840)) for d in range(2, 7)])))
out["org_overview_with_hours"] = rpc(kim, "org_overview", ORG)

# ---- services, a signer, bookings --------------------------------------------
sql_as(dee, "insert into availability_settings (creator_id, time_zone, weekly, min_notice_hours, max_advance_days, buffer_minutes, slot_interval_minutes) values (%s,%s,%s,2,180,30,30)",
       (ORG, TZ, json.dumps(WEEKLY)))
TMPL = sql_as(dee, "insert into contract_templates (creator_id, title, kind, clauses) values (%s,'Wedding terms','photography',%s) returning id", (ORG, Json(CLAUSES)))[0][0]
PKG = sql_as(dee, "insert into packages (creator_id, name, price_cents, duration_minutes, deposit_cents, is_published, contract_template_id) values (%s,'Wedding film',200000,60,0,true,%s) returning id", (ORG, TMPL))[0][0]
rpc(dee, "org_designate_signer", ORG, dee, "Director")
sql_as(dee, "select package_set_members(%s, %s::uuid[])", (PKG, [cal, kim]))
out["package_members"] = value(client, "select coalesce(jsonb_agg(to_jsonb(m)), '[]'::jsonb) from package_members m where package_id = %s", (PKG,))
out["org_overview_with_signer"] = rpc(olivia, "org_overview", ORG)


def sig(name):
    return {"signedName": name, "method": "typed", "imagePng": None, "consentVersion": 1, "device": "test"}


def book(start, member=None, name="Alex Client"):
    p = sql_as(client, "select preview_contract(%s, %s::uuid[], %s, %s, %s)", (PKG, [], start, name, ""))[0][0]
    return rpc(client, "create_booking", PKG, [], start, name, "", p["document_hash"], Json(sig(name)), member)


t0 = at(14, 10)
out["team_availability"] = rpc(client, "team_availability", PKG, None, at(14, 0), at(21, 0))
out["create_booking"] = book(t0)
out["create_booking_named"] = book(at(14, 12), member=kim)
sql_as(olivia, "select org_update(%s, null, null, 'manual', null)", (ORG,))
waiting = book(at(14, 15))
out["create_booking_waiting"] = waiting
out["bookings_select"] = value(olivia, "select coalesce(jsonb_agg(to_jsonb(b) order by b.start_at), '[]'::jsonb) from bookings b where b.creator_id = %s", (ORG,))
out["assignment_queue"] = table(olivia, "assignment_queue", ORG)
out["assignment_options"] = table(olivia, "assignment_options", waiting["booking"]["id"])
out["assign_booking"] = rpc(mia, "assign_booking", waiting["booking"]["id"], cal)
out["team_availability_one"] = rpc(client, "team_availability", PKG, kim, at(14, 0), at(21, 0))
out["team_calendar_owner"] = sql_as(olivia, "select team_calendar(%s, %s, %s, %s::uuid[])", (ORG, at(14, 0), at(15, 0), None))[0][0]
out["team_calendar_creator"] = sql_as(cal, "select team_calendar(%s, %s, %s, %s::uuid[])", (ORG, at(14, 0), at(15, 0), None))[0][0]
out["activity_list"] = table(olivia, "activity_list", ORG, 50, None)

# ---- billing -----------------------------------------------------------------
a.execute("update app_settings set value = value || '{\"required\": true}'::jsonb where key = 'billing'")
out["billing_overview_none"] = rpc(olivia, "billing_overview", ORG)
out["org_overview_unpaid"] = rpc(olivia, "org_overview", ORG)
period_end = datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(days=20)
sql_as(None, "select billing_record_subscription(%s, 'cus_1', 'sub_1', 'active', 6, %s, null, false)", (ORG, period_end), role="service_role")
out["billing_overview_active"] = rpc(olivia, "billing_overview", ORG)
out["billing_preview"] = rpc(olivia, "billing_preview", ORG, 1)
out["org_overview_paid"] = rpc(olivia, "org_overview", ORG)
out["my_accounts_after"] = rpc(kim, "my_accounts")
out["_note"] = "Generated by supabase/tests/dump_team_rows.py from real Postgres. Do not edit by hand."

def paths(value, prefix=""):
    """Every key path in a JSON value (list items as `[]`), which is what has to match, not the ids and dates."""
    found = set()
    if isinstance(value, dict):
        for key, inner in value.items():
            found.add(f"{prefix}.{key}")
            found |= paths(inner, f"{prefix}.{key}")
    elif isinstance(value, list):
        for inner in value:
            found |= paths(inner, f"{prefix}[]")
    return found


if "--check" in sys.argv:
    # CI: the committed file must have the same shape as what the functions return now.
    committed = json.loads(OUT.read_text())
    mine, theirs = paths(out), paths(committed)
    missing, extra = sorted(theirs - mine), sorted(mine - theirs)
    if missing or extra:
        print("team_rows.json is out of date. Run dump_team_rows.py and commit the result.")
        print("  in the file but no longer returned:", missing[:20])
        print("  returned now but not in the file:  ", extra[:20])
        sys.exit(1)
    print("team_rows.json matches the functions:", len(mine), "key paths")
else:
    OUT.write_text(json.dumps(out, indent=1, sort_keys=True) + "\n")
    print("wrote", OUT, len(out), "entries")
