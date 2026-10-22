"""Applies the migrations to a throwaway Postgres and tries to break the company booking rules: who may edit a
company's services, who a booking is assigned to, that nobody is in two places, that a contract is made in the
company's name and countersigned by the person it authorised, who can see and act on a booking, and the upgrade from
a person to a company and back.

    PGPORT=5432 python3 ios/supabase/tests/company_rules.py

Companion to booking_rules.py (one creator) and team_rules.py (roles, invites, seats).
"""
import json
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
DB = "slate_company"
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
    print("applied", f.name)
# These suites are about roles and bookings, not about paying for seats (billing_rules.py is).
a.execute("update app_settings set value = value || '{\"required\": false}'::jsonb where key = 'billing'")


# ---- helpers ----------------------------------------------------------------
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


def rows(uid, fn, *args, role="authenticated"):
    res = sql_as(uid, f"select * from {fn}({', '.join(['%s'] * len(args))})", args, role)
    return res if isinstance(res, str) else res[0]


def svc(fn, *args):
    return rpc(None, fn, *args, role="service_role")


def one(query, args=None):
    a.execute(query, args)
    r = a.fetchone()
    return r[0] if r else None


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


def raw(sql, args=None):
    """A statement as the database owner with the booking notification triggers off (for setting up past bookings)."""
    a.execute("alter table bookings disable trigger user")
    try:
        a.execute(sql, args)
    finally:
        a.execute("alter table bookings enable trigger user")


a.execute("select (date_trunc('week', now() at time zone %s) + interval '2 weeks')::date", (TZ,))
monday = a.fetchone()[0]


def at(day_offset, hh, mm=0):
    a.execute("select ((%s::date + %s) + make_time(%s,%s,0)) at time zone %s", (monday, day_offset, hh, mm, TZ))
    return a.fetchone()[0]


MON, TUE, WED, THU, FRI = 0, 1, 2, 3, 4


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


def sig(name="Test Client"):
    return {"signedName": name, "method": "typed", "imagePng": None, "consentVersion": 1, "device": "test"}


def preview(uid, start, pkg, name="Test Client"):
    return rpc(uid, "preview_contract", pkg, [], start, name, "")


def book(uid, start, pkg, member=None, name="Test Client"):
    """Preview, sign the hash, book. Returns {'booking', 'contract'} or 'ERR:...'."""
    p = preview(uid, start, pkg, name)
    if isinstance(p, str):
        return p
    return rpc(uid, "create_booking", pkg, [], start, name, "", p["document_hash"], Json(sig(name)), member)


def booking(bid):
    a.execute("select status, assigned_to, requested_member, assignee_share_bps, creator_id from bookings where id = %s", (bid,))
    s, who, req, share, owner = a.fetchone()
    return dict(status=s, who=who, requested=req, share=share, owner=owner)


def pushes(booking_id, kind=None):
    if kind:
        a.execute("select user_id from push_outbox where booking_id = %s and kind = %s", (booking_id, kind))
    else:
        a.execute("select user_id from push_outbox where booking_id = %s", (booking_id,))
    return sorted(r[0] for r in a.fetchall())


def count(query, args=None):
    return one(query, args)


def call(uid, query, args=None):
    """One statement returning one value (None for void), or 'ERR:...'."""
    res = sql_as(uid, query, args)
    if isinstance(res, str):
        return res
    value = res[0][0][0]
    return None if value == "" else value


def set_members(uid, pkg, ids):
    return call(uid, "select package_set_members(%s, %s::uuid[])", (pkg, ids))


def set_hours(uid, org, weekly):
    return call(uid, "select member_set_hours(%s, %s::jsonb)", (org, Json(weekly)))


def team_cal(uid, org, start, end, ids=None):
    return call(uid, "select team_calendar(%s, %s, %s, %s::uuid[])", (org, start, end, ids))


def jb(uid, fn, *args):
    """A function that returns a table row (a booking, a review), as a dict."""
    res = sql_as(uid, f"select to_jsonb({fn}({', '.join(['%s'] * len(args))}))", args)
    return res if isinstance(res, str) else res[0][0][0]


# =============================================================================
print("\n[setting up a company]")
olivia = new_user("olivia-ng", "Olivia Ng")
add_signature(olivia, "Olivia Ng")
dee, mia, cal, kim, vee = new_user(), new_user("mia-k", "Mia K"), new_user("cal-r", "Cal R"), new_user("kim-t", "Kim T"), new_user("vee-t", "Vee T")
client_a, client_b, stranger = new_user(), new_user(), new_user("sam-s", "Sam S")

ORG = rpc(olivia, "org_create", "acme-films", "Acme Films", "Acme Films LLC", "1 Main St", "", ["weddings"], "Austin, TX")["organization_id"]
join(ORG, olivia, "admin", dee, "Dee Okafor")
join(ORG, olivia, "manager", mia)
join(ORG, olivia, "creator", cal)
join(ORG, olivia, "creator", kim)
join(ORG, olivia, "viewer", vee)
add_signature(dee, "Dee Okafor")
for u in (olivia, dee, mia):
    rpc(olivia, "member_update", ORG, u, None, None, False)  # leaders who don't shoot
check("the team is set up", one("select count(*) from memberships where organization_id = %s and removed_at is null", (ORG,)) == 6)
check("only Cal and Kim take bookings", sorted(r[0] for r in sql_as(None, "select user_id from org_public_team(%s)", (ORG,), role="anon")[0]) == sorted([cal, kim]))

print("\n[services, templates and hours belong to the company]")
res = sql_as(dee, "insert into availability_settings (creator_id, time_zone, weekly, min_notice_hours, max_advance_days, buffer_minutes, slot_interval_minutes) values (%s,%s,%s,2,180,30,30)",
             (ORG, TZ, json.dumps(WEEKLY)))
check("an Admin sets the company's hours", not isinstance(res, str), res)
check("a Manager can't", isinstance(sql_as(mia, "update availability_settings set buffer_minutes = 0 where creator_id = %s", (ORG,)), str)
      or sql_as(mia, "update availability_settings set buffer_minutes = 0 where creator_id = %s", (ORG,))[1] == 0)
check("the hours are public", sql_as(None, "select count(*) from availability_settings where creator_id = %s", (ORG,), role="anon")[0][0][0] == 1)

res = sql_as(dee, "insert into contract_templates (creator_id, title, kind, clauses) values (%s,'Wedding terms','photography',%s) returning id", (ORG, Json(CLAUSES)))
check("an Admin adds a contract template", not isinstance(res, str), res)
TMPL = res[0][0][0]
check("a Manager can't add one", isinstance(sql_as(mia, "insert into contract_templates (creator_id, title, kind, clauses) values (%s,'x','photography',%s)", (ORG, Json(CLAUSES))), str))
check("a Creator can read the templates", sql_as(cal, "select count(*) from contract_templates where creator_id = %s", (ORG,))[0][0][0] == 1)
check("a stranger can't", sql_as(stranger, "select count(*) from contract_templates where creator_id = %s", (ORG,))[0][0][0] == 0)


def add_package(who, name, deposit=0, published=True, price=200000, creator=ORG):
    return sql_as(who, """insert into packages (creator_id, name, price_cents, duration_minutes, deposit_cents, is_published, contract_template_id)
                          values (%s,%s,%s,60,%s,%s,%s) returning id""", (creator, name, price, deposit, published, TMPL))


res = add_package(dee, "Wedding film")
check("an Admin adds a service", not isinstance(res, str), res)
PKG = res[0][0][0]
for who, label in ((mia, "a Manager"), (cal, "a Creator"), (vee, "a Viewer"), (stranger, "a stranger")):
    check(f"{label} can't add a service", isinstance(add_package(who, "Nope"), str))
PKG_DRAFT = add_package(dee, "Draft package", published=False)[0][0][0]
check("a Creator can read an unpublished company service", sql_as(cal, "select count(*) from packages where id = %s", (PKG_DRAFT,))[0][0][0] == 1)
check("a stranger can't", sql_as(stranger, "select count(*) from packages where id = %s", (PKG_DRAFT,))[0][0][0] == 0)
check("a published service is public", sql_as(None, "select count(*) from packages where id = %s", (PKG,), role="anon")[0][0][0] == 1)
check("an Admin changes a price", sql_as(dee, "update packages set price_cents = 220000 where id = %s", (PKG,))[1] == 1)
price_line = one("select summary from activity_log where organization_id = %s and action = 'package.price_changed'", (ORG,))
check("...and it is logged with the old and new price", price_line == "Changed the price of Wedding film from $2,000 to $2,200", price_line)
check("a Creator can't change one", sql_as(cal, "update packages set price_cents = 1000 where id = %s", (PKG,))[1] == 0)
check("a Manager can't delete one", sql_as(mia, "delete from packages where id = %s", (PKG_DRAFT,))[1] == 0)
check("an Admin can", sql_as(dee, "delete from packages where id = %s", (PKG_DRAFT,))[1] == 1)
check("template changes are logged", one("select count(*) from activity_log where organization_id = %s and action = 'template.created'", (ORG,)) == 1)

print("\n[a company needs a signer before it takes a booking]")
t0 = at(MON + 14, 10)
check("with no designated signer a booking can't be previewed", err(preview(client_a, t0, PKG), "creator_not_ready"))
rpc(dee, "org_designate_signer", ORG, dee, "Director")
p = preview(client_a, t0, PKG)
check("the contract is in the company's legal name", isinstance(p, dict) and "Acme Films LLC" in p["sections"][0]["body"] and "Acme Films (" not in p["sections"][0]["body"], p)
check("members can't book their own company", err(preview(cal, t0, PKG), "cannot_book_yourself") and err(preview(vee, t0, PKG), "cannot_book_yourself"))
check("the company owner can't either", err(preview(olivia, t0, PKG), "cannot_book_yourself"))

print("\n[booking the company: automatic assignment]")
b1 = book(client_a, t0, PKG, name="Alex Client")
check("the first booking is assigned to one of the shooters", isinstance(b1, dict) and booking(b1["booking"]["id"])["who"] in (cal, kim), b1)
first = booking(b1["booking"]["id"])["who"]
check("it belongs to the company", booking(b1["booking"]["id"])["owner"] == ORG)
check("it is confirmed with no deposit and the contract is executed", b1["booking"]["status"] == "confirmed" and b1["contract"]["status"] == "executed")
sigs = {s["role"]: s for s in b1["contract"]["signatures"]}
check("the countersignature is the designated signer's, on behalf of the company",
      sigs["creator"]["user_id"] == dee and sigs["creator"]["signed_name"] == "Dee Okafor" and sigs["creator"]["on_behalf_of"] == "Acme Films LLC"
      and sigs["creator"]["signer_title"] == "Director", sigs.get("creator"))
check("the contract records the signer and the legal name",
      b1["contract"]["countersigner_id"] == dee and b1["contract"]["provider_legal_name"] == "Acme Films LLC" and b1["contract"]["creator_id"] == ORG)
check("the booking shows the company's name", b1["booking"]["creator_name"] == "Acme Films")
check("only the assignee heard about it", pushes(b1["booking"]["id"], "new_booking") == [first], pushes(b1["booking"]["id"], "new_booking"))
check("the log says who it went to", "with " in one("select summary from activity_log where organization_id = %s and action = 'booking.created'", (ORG,)))
check("the signed contract is logged with the countersigner", "countersigned by Dee Okafor (Director)" in one("select summary from activity_log where organization_id = %s and action = 'contract.executed'", (ORG,)))

b2 = book(client_b, t0, PKG, name="Blake Client")
second = booking(b2["booking"]["id"])["who"] if isinstance(b2, dict) else None
check("a second booking at the same time goes to the other shooter", second in (cal, kim) and second != first, b2)
check("a third has nobody left", err(book(stranger, t0, PKG), "slot_taken"))
check("nobody is double booked", count("""select count(*) from bookings x join bookings y on x.assigned_to = y.assigned_to and x.id < y.id
                                           where x.status in ('held','confirmed') and y.status in ('held','confirmed')
                                           and tstzrange(x.start_at, x.blocked_until) && tstzrange(y.start_at, y.blocked_until)""") == 0)

t1 = at(MON + 14, 14)
b3 = book(client_a, t1, PKG)
check("with equal loads, whoever joined first is chosen", isinstance(b3, dict) and booking(b3["booking"]["id"])["who"] == cal, b3)
b3b = book(client_b, at(MON + 14, 12), PKG)
check("then the one with fewer bookings is", isinstance(b3b, dict) and booking(b3b["booking"]["id"])["who"] == kim, b3b)
loads = {u: count("select count(*) from bookings where assigned_to = %s and status = 'confirmed'", (u,)) for u in (cal, kim)}
check("...so the load stays level", loads[cal] == 2 and loads[kim] == 2, loads)

print("\n[booking a person]")
t2 = at(MON + 14, 16)
d1 = book(client_a, t2, PKG, member=cal)
check("a client books Cal directly", isinstance(d1, dict) and booking(d1["booking"]["id"])["who"] == cal and booking(d1["booking"]["id"])["requested"], d1)
check("a second booking of Cal at that time is taken", err(book(client_b, t2, PKG, member=cal), "slot_taken"))
check("...though the company can still use Kim", isinstance(book(client_b, t2, PKG), dict))
check("a Viewer can't be booked", err(book(client_b, at(MON + 15, 10), PKG, member=vee), "member_unavailable"))
check("neither can someone who isn't on the team", err(book(client_b, at(MON + 15, 10), PKG, member=stranger), "member_unavailable"))
check("neither can a leader who doesn't shoot", err(book(client_b, at(MON + 15, 10), PKG, member=dee), "member_unavailable"))

print("\n[services offered by chosen people]")
PKG_KIM = add_package(dee, "Kim's portrait session", price=90000)[0][0][0]
r1 = set_members(cal, PKG_KIM, [kim])
check("a Creator can't choose who offers a service", err(r1, "not_allowed"), r1)
r2 = set_members(dee, PKG_KIM, [vee])
check("a Viewer can't be chosen", err(r2, "invalid_assignee"), r2)
r3 = set_members(dee, PKG_KIM, [kim])
check("an Admin chooses Kim", r3 is None, r3)
check("the choice is public", sql_as(None, "select count(*) from package_members where package_id = %s", (PKG_KIM,), role="anon")[0][0][0] == 1)
t3 = at(MON + 15, 11)
k1 = book(client_a, t3, PKG_KIM)
check("it always goes to Kim", isinstance(k1, dict) and booking(k1["booking"]["id"])["who"] == kim, k1)
check("when Kim is busy it is taken, not given to Cal", err(book(client_b, t3, PKG_KIM), "slot_taken"))
check("Cal can't be booked for it directly", err(book(client_b, at(MON + 15, 13), PKG_KIM, member=cal), "member_unavailable"))

print("\n[hours: the company's, narrowed by a person's own]")
check("a Viewer has no hours to set", err(set_hours(vee, ORG, []), "not_allowed"))
check("hours are validated", err(set_hours(kim, ORG, [dict(weekday=2, window=dict(startMinute=700, endMinute=600))]), "invalid_input"))
check("Kim narrows her hours to 10:00 to 14:00 on weekdays",
      set_hours(kim, ORG, [dict(weekday=d, window=dict(startMinute=600, endMinute=840)) for d in range(2, 7)]) is None)
t4 = at(MON + 16, 9)
c1 = book(client_a, t4, PKG)
check("before Kim's hours a booking goes to Cal", isinstance(c1, dict) and booking(c1["booking"]["id"])["who"] == cal, c1)
check("Kim can't be booked directly outside her hours", err(book(client_b, at(MON + 16, 15), PKG, member=kim), "slot_unavailable"))
check("nor outside the company's", err(book(client_b, at(MON + 16, 18), PKG, member=cal), "slot_unavailable"))
c2 = book(client_b, at(MON + 16, 10), PKG, member=kim)
check("within her hours she can be", isinstance(c2, dict) and booking(c2["booking"]["id"])["who"] == kim, c2)
ta = rpc(client_a, "team_availability", PKG, None, at(MON + 14, 0), at(MON + 21, 0))
w = {m["user_id"]: m["weekly"] for m in ta["members"]}
check("the client's view gives each person's effective hours", w[kim][0]["window"] == {"startMinute": 600, "endMinute": 840}
      and w[cal][0]["window"] == {"startMinute": 540, "endMinute": 1020}, w)
check("...and when each is busy, without saying why", all(set(b) == {"starts_at", "ends_at"} for m in ta["members"] for b in m["busy"])
      and any(m["busy"] for m in ta["members"]))
check("a company that isn't taking bookings has no availability", err(rpc(client_a, "team_availability", add_package(dee, "Hidden", published=False)[0][0][0]), "package_unavailable"))

print("\n[nobody is in two places]")
a.execute("insert into availability_settings (creator_id, time_zone, weekly, min_notice_hours, max_advance_days, buffer_minutes, slot_interval_minutes) values (%s,%s,%s,2,180,30,30)",
          (kim, TZ, json.dumps(WEEKLY)))
a.execute("insert into creator_signatures (creator_id, signed_name, method) values (%s,'Kim T','typed')", (kim,))
a.execute("insert into contract_templates (creator_id, title, kind, clauses) values (%s,'Kim terms','photography',%s) returning id", (kim, Json(CLAUSES)))
ktmpl = a.fetchone()[0]
a.execute("""insert into packages (creator_id, name, price_cents, duration_minutes, deposit_cents, contract_template_id)
             values (%s,'Kim solo shoot',50000,60,0,%s) returning id""", (kim, ktmpl))
KIM_PKG = a.fetchone()[0]
t5 = at(MON + 17, 12)
personal = book(client_a, t5, KIM_PKG)
check("Kim also sells on her own", isinstance(personal, dict) and booking(personal["booking"]["id"])["who"] == kim and booking(personal["booking"]["id"])["owner"] == kim, personal)
check("the company won't give her a booking over it", err(book(client_b, t5, PKG, member=kim), "slot_taken") or err(book(client_b, t5, PKG, member=kim), "slot_unavailable"))
other = book(client_b, t5, PKG)
check("...it goes to Cal instead", isinstance(other, dict) and booking(other["booking"]["id"])["who"] == cal, other)
t6 = at(MON + 17, 10)
mine = book(client_b, t6, PKG, member=kim)
blocked = book(client_a, t6, KIM_PKG)
check("a company booking for Kim blocks her personal calendar", isinstance(mine, dict) and err(blocked, "slot_taken"), (mine if isinstance(mine, str) else None, blocked if isinstance(blocked, str) else "booked"))
a.execute("insert into busy_blocks (creator_id, starts_at, ends_at) values (%s,%s,%s)", (cal, at(MON + 18, 9), at(MON + 18, 12)))
check("Cal's own calendar blocks company bookings for him", err(book(client_a, at(MON + 18, 10), PKG, member=cal), "slot_unavailable"))

print("\n[assignment by hand]")
rpc(dee, "org_update", ORG, None, None, "manual", None)
t7 = at(MON + 21, 10)
m1 = book(client_a, t7, PKG)
check("in manual mode a booking waits for someone", isinstance(m1, dict) and booking(m1["booking"]["id"])["who"] is None, m1)
check("everyone who can assign hears about it, and nobody else",
      pushes(m1["booking"]["id"], "new_booking") == sorted([olivia, dee, mia]), pushes(m1["booking"]["id"], "new_booking"))
m2 = book(client_b, t7, PKG)
check("a second can wait at the same time (two people are free)", isinstance(m2, dict) and booking(m2["booking"]["id"])["who"] is None, m2)
check("a third can't, because there is nobody left to take it", err(book(stranger, t7, PKG), "slot_taken"))
check("a booking for a named person is assigned straight away, even in manual mode",
      booking(book(client_a, at(MON + 21, 15), PKG, member=cal)["booking"]["id"])["who"] == cal)
q = rows(mia, "assignment_queue", ORG)
check("a Manager sees the queue", len(q) == 2)
check("a Creator doesn't", err(rows(cal, "assignment_queue", ORG), "not_allowed"))
check("a Viewer doesn't", err(rows(vee, "assignment_queue", ORG), "not_allowed"))
opts = rows(mia, "assignment_options", m1["booking"]["id"])
check("the Manager sees who is free", {r[0]: r[2] for r in opts} == {cal: True, kim: True}, opts)
check("a Creator can't assign", err(jb(cal, "assign_booking", m1["booking"]["id"], cal), "not_allowed"))
check("a Viewer can't be assigned", err(jb(mia, "assign_booking", m1["booking"]["id"], vee), "invalid_assignee"))
check("a stranger can't be assigned", err(jb(mia, "assign_booking", m1["booking"]["id"], stranger), "invalid_assignee"))
res = jb(mia, "assign_booking", m1["booking"]["id"], cal)
check("a Manager assigns Cal", isinstance(res, dict) and res["assigned_to"] == cal and res["assigned_at"] is not None, res)
check("Cal is told", pushes(m1["booking"]["id"], "new_booking").count(cal) == 1)
check("the assignment is logged", one("select count(*) from activity_log where organization_id = %s and action = 'booking.assigned'", (ORG,)) >= 1)
check("assigning the same person again changes nothing", jb(mia, "assign_booking", m1["booking"]["id"], cal)["assigned_to"] == cal)
check("Cal can't also take the other booking at that time", err(jb(mia, "assign_booking", m2["booking"]["id"], cal), "slot_taken"))
opts = {r[0]: r for r in rows(mia, "assignment_options", m2["booking"]["id"])}
check("the options say why not", opts[cal][2] is False and opts[cal][3] == "Already booked" and opts[kim][2] is True, opts)
res = jb(dee, "assign_booking", m2["booking"]["id"], kim)
check("an Admin assigns Kim", isinstance(res, dict) and res["assigned_to"] == kim)
res = jb(olivia, "assign_booking", m1["booking"]["id"], kim)
check("reassigning to someone busy is refused", err(res, "slot_taken"))
rpc(dee, "org_update", ORG, None, None, "auto", None)

print("\n[who can see and do what with a booking]")
bid = b1["booking"]["id"]
owner_of_b1 = booking(bid)["who"]
other_shooter = kim if owner_of_b1 == cal else cal
def sees(uid, table="bookings", key="id", val=None):
    return sql_as(uid, f"select count(*) from {table} where {key} = %s", (val or bid,))[0][0][0] == 1
check("the client sees their booking", sees(client_a))
check("the person it is assigned to sees it", sees(owner_of_b1))
check("another Creator doesn't", not sees(other_shooter))
check("the Manager, Admin, Owner and Viewer do", all(sees(u) for u in (mia, dee, olivia, vee)))
check("a stranger and another client don't", not sees(stranger) and not sees(client_b))
cid = b1["contract"]["id"]
check("the contract follows the booking", sees(owner_of_b1, "contracts", "id", cid) and not sees(other_shooter, "contracts", "id", cid)
      and sees(vee, "contracts", "id", cid) and sees(client_a, "contracts", "id", cid))
check("so do its signatures", sql_as(owner_of_b1, "select count(*) from contract_signatures where contract_id = %s", (cid,))[0][0][0] == 2
      and sql_as(other_shooter, "select count(*) from contract_signatures where contract_id = %s", (cid,))[0][0][0] == 0)
check("and its conversation", sql_as(owner_of_b1, "select count(*) from messages where booking_id = %s", (bid,))[0][0][0] > 0
      and sql_as(other_shooter, "select count(*) from messages where booking_id = %s", (bid,))[0][0][0] == 0)
check("the conversation list shows it to the assignee, not to another Creator",
      bid in [str(r[0]) for r in rows(owner_of_b1, "list_conversations")] and bid not in [str(r[0]) for r in rows(other_shooter, "list_conversations")])

check("the assignee can write in the conversation", not isinstance(jb(owner_of_b1, "send_message", bid, "See you there", None), str))
check("a Manager can too", not isinstance(jb(mia, "send_message", bid, "Any questions? Ask us", None), str))
check("a Viewer can read but not write", sees(vee) and err(jb(vee, "send_message", bid, "hello", None), "not_found"))
check("another Creator can neither", err(jb(other_shooter, "send_message", bid, "hello", None), "not_found"))
check("the client's reply reaches the assignee, and not the rest of the team",
      (not isinstance(jb(client_a, "send_message", bid, "Thanks!", None), str)) and
      sorted(r[0] for r in sql_as(None, "select user_id from push_outbox where booking_id = %s and kind = 'message' and data ->> 'role' = 'creator'", (bid,), role="service_role")[0]) == [owner_of_b1])

cb = book(client_b, at(MON + 22, 10), PKG)
cbid = cb["booking"]["id"]
cb_owner = booking(cbid)["who"]
cb_other = kim if cb_owner == cal else cal
check("a Creator can't cancel someone else's booking", err(rpc(cb_other, "cancel_booking", cbid), "not_cancellable"))
check("a Viewer can't cancel", err(rpc(vee, "cancel_booking", cbid), "not_cancellable"))
check("a stranger can't", err(rpc(stranger, "cancel_booking", cbid), "not_cancellable"))
check("a Viewer can't get a refund quote either", err(rpc(vee, "refund_quote", cbid), "not_cancellable"))
check("the assignee can quote and cancel (the client gets everything back)",
      rpc(cb_owner, "refund_quote", cbid)["by_creator"] is True and rpc(cb_owner, "cancel_booking", cbid)["booking"]["status"] == "cancelled")
check("cancelling tells the client", len(pushes(cbid, "booking_cancelled")) == 1 and pushes(cbid, "booking_cancelled")[0] == client_b)
cb2 = book(client_b, at(MON + 22, 11), PKG)
check("a Manager can cancel any booking", rpc(mia, "cancel_booking", cb2["booking"]["id"])["booking"]["status"] == "cancelled")
cb3 = book(client_b, at(MON + 22, 12), PKG)
check("the client's cancel is still the client's", rpc(client_b, "refund_quote", cb3["booking"]["id"])["by_creator"] is False)
check("...and tells the person on the job", pushes(cb3["booking"]["id"], "booking_cancelled") == [] and rpc(client_b, "cancel_booking", cb3["booking"]["id"]) is not None
      and pushes(cb3["booking"]["id"], "booking_cancelled") == [booking(cb3["booking"]["id"])["who"]])
check("cancelling is logged", one("select count(*) from activity_log where organization_id = %s and action = 'booking.cancelled'", (ORG,)) == 3)

print("\n[money goes to the company]")
a.execute("""insert into packages (creator_id, name, price_cents, duration_minutes, deposit_cents, contract_template_id)
             values (%s,'Brand film',300000,60,60000,%s) returning id""", (ORG, TMPL))
PAID = a.fetchone()[0]
check("with no Connect account a deposit can't be taken", err(preview(client_a, at(MON + 23, 10), PAID), "payments_not_ready"))
check("only the Owner may connect the company's account", svc("connect_authorize", olivia, ORG) is True and svc("connect_authorize", dee, ORG) is False
      and svc("connect_authorize", cal, ORG) is False and svc("connect_authorize", stranger, ORG) is False and svc("connect_authorize", olivia, olivia) is True)
svc("connect_account_save", ORG, "acct_acme")
svc("connect_account_update", "acct_acme", True, True, True)
check("an Admin can't read the company's payment account, the Owner can",
      sql_as(dee, "select count(*) from creator_payment_accounts where creator_id = %s", (ORG,))[0][0][0] == 0
      and sql_as(olivia, "select count(*) from creator_payment_accounts where creator_id = %s", (ORG,))[0][0][0] == 1)
pb = book(client_a, at(MON + 23, 10), PAID, name="Pat Client")
check("a booking with a deposit is held, with an open contract", isinstance(pb, dict) and pb["booking"]["status"] == "held" and pb["contract"]["status"] == "pending", pb)
pbid = pb["booking"]["id"]
check("the countersigner is fixed at that moment", pb["contract"]["countersigner_id"] == dee)
prep = svc("payment_prepare", client_a, pbid, "deposit", 0)
check("the payment goes to the company's account", isinstance(prep, dict) and prep["destination"] == "acct_acme", prep)
# The signer leaves the company before the deposit arrives.
rpc(olivia, "member_remove", ORG, dee)
check("removing the signer stops auto-countersign", one("select signer_user_id is null from organizations where id = %s", (ORG,)))
check("...and new bookings are refused until there is another", err(preview(client_b, at(MON + 23, 14), PAID), "creator_not_ready"))
intent = "pi_" + uuid.uuid4().hex[:18]
svc("payment_attach_intent", prep["payment_id"], intent)
out = svc("payment_record_success", intent, prep["amount_cents"], "ch_x", "apple_pay")
check("the deposit still confirms the booking the client signed", out["action"] == "confirmed", out)
a.execute("select s.user_id, s.signed_name, s.on_behalf_of, s.signer_title from contract_signatures s join contracts c on c.id = s.contract_id where c.booking_id = %s and s.role = 'creator'", (pbid,))
row = a.fetchone()
check("...countersigned by the person who was authorised when the client signed", row == (dee, "Dee Okafor", "Acme Films LLC", "Director"), row)
check("both sides are told it was paid", pushes(pbid, "payment_received") == sorted([client_a, booking(pbid)["who"]]), pushes(pbid, "payment_received"))
add_signature(mia, "Mia K")
rpc(olivia, "org_update", ORG, None, None, None, ["owner", "admin", "manager"])
check("a new signer can be named", rpc(olivia, "org_designate_signer", ORG, mia, "Operations")["signer_user_id"] == mia)

print("\n[the delivery and the review]")
db_ = book(client_a, at(MON + 22, 14), PKG)
dbid = db_["booking"]["id"]
dwho = booking(dbid)["who"]
dother = kim if dwho == cal else cal
raw("""update bookings set start_at = now() - interval '2 days', end_at = now() - interval '2 days' + interval '1 hour',
                         blocked_until = now() - interval '2 days' + interval '90 minutes' where id = %s""", (dbid,))
check("another Creator can't share the files", err(jb(dother, "share_delivery", dbid, "https://files.example.com/x", None), "not_found"))
check("a Viewer can't", err(jb(vee, "share_delivery", dbid, "https://files.example.com/x", None), "not_found"))
res = jb(dwho, "share_delivery", dbid, "https://files.example.com/x", "Password: lake")
check("the assignee does", isinstance(res, dict) and res["delivery_url"] == "https://files.example.com/x", res)
check("the client is told", pushes(dbid, "delivery_shared") == [client_a])
check("it is logged", one("select count(*) from activity_log where organization_id = %s and action = 'booking.delivered'", (ORG,)) == 1)
check("a Manager can replace the link", isinstance(jb(mia, "share_delivery", dbid, "https://files.example.com/y", None), dict))
check("the client confirms; with a balance to pay the booking isn't complete yet", jb(client_a, "confirm_receipt", dbid)["status"] == "confirmed")
prepb = svc("payment_prepare", client_a, dbid, "balance", 0)
check("the balance goes to the company's account too", isinstance(prepb, dict) and prepb["destination"] == "acct_acme", prepb)
intent2 = "pi_" + uuid.uuid4().hex[:18]
svc("payment_attach_intent", prepb["payment_id"], intent2)
check("paying it completes the booking", svc("payment_record_success", intent2, prepb["amount_cents"], "ch_y", "apple_pay")["action"] == "completed")
check("the assignee hears the client has the files", pushes(dbid, "receipt_confirmed") == [dwho])
review = jb(client_a, "submit_review", dbid, 5, "Wonderful")
check("the client reviews the company", isinstance(review, dict) and review["creator_id"] == ORG, review)
check("the assignee is told", pushes(dbid, "review_received") == [dwho])
check("the review counts for the company", sql_as(None, "select review_count, rating_sum from creator_review_summary(%s)", (ORG,), role="anon")[0][0] == (1, 5))
check("the team can read it, a stranger can't", len(rows(dwho, "get_booking_review", dbid)) == 1 and len(rows(stranger, "get_booking_review", dbid)) == 0)

print("\n[calendars]")
cal_view = team_cal(vee, ORG, at(MON + 14, 0), at(MON + 24, 0))
byname = {m["user_id"]: m for m in cal_view["members"]}
check("a Viewer sees the team calendar", set(byname) == {olivia, mia, cal, kim}, set(byname))
check("...and, since a Viewer reads every booking, their names", any(b["client_name"] for m in cal_view["members"] for b in m["bookings"]))
mgr_view = {m["user_id"]: m for m in team_cal(mia, ORG, at(MON + 14, 0), at(MON + 24, 0))["members"]}
check("a Manager sees names and ids", any(b["client_name"] for b in mgr_view[cal]["bookings"] + mgr_view[kim]["bookings"]))
cal_self = {m["user_id"]: m for m in team_cal(cal, ORG, at(MON + 14, 0), at(MON + 24, 0))["members"]}
check("a Creator sees names only on their own bookings",
      all(b["client_name"] for b in cal_self[cal]["bookings"]) and all(b["client_name"] is None for b in cal_self[kim]["bookings"]))
check("a member's personal bookings show up as busy, without details",
      any(x["kind"] == "personal" and set(x) == {"starts_at", "ends_at", "kind"} for x in cal_self[kim]["busy"]))
check("a leader who doesn't shoot has no hours", mgr_view[olivia]["weekly"] == [] and mgr_view[cal]["weekly"] != [])
only = team_cal(mia, ORG, at(MON + 14, 0), at(MON + 24, 0), [cal])["members"]
check("it can be filtered to one person", [m["user_id"] for m in only] == [cal])
check("a stranger gets nothing", err(team_cal(stranger, ORG, at(MON + 14, 0), at(MON + 24, 0)), "not_found"))
check("the unassigned list is there", "unassigned" in cal_view)

print("\n[the split ledger]")
check("shares are off by default", booking(book(client_a, at(MON + 24, 10), PKG, member=cal)["booking"]["id"])["share"] is None)
rpc(olivia, "org_set_split", ORG, True)
rpc(olivia, "member_set_share", ORG, cal, 3000)
rpc(olivia, "member_set_share", ORG, kim, 5000)
sb = book(client_b, at(MON + 24, 12), PKG, member=cal)
check("a booking records the assignee's share when the ledger is on", booking(sb["booking"]["id"])["share"] == 3000)
res = jb(mia, "assign_booking", sb["booking"]["id"], kim)
check("reassigning updates it", res["assignee_share_bps"] == 5000, res)
rpc(olivia, "org_set_split", ORG, False)

print("\n[someone leaves]")
lb = book(client_a, at(MON + 25, 10), PKG, member=cal)
lbid = lb["booking"]["id"]
set_members(olivia, PKG_KIM, [kim, cal])
check("Cal has bookings coming up", count("select count(*) from bookings where assigned_to = %s and status in ('held','confirmed') and end_at > now()", (cal,)) > 0)
rpc(olivia, "member_remove", ORG, cal)
check("his upcoming bookings return to the queue", booking(lbid)["who"] is None and booking(lbid)["status"] == "confirmed")
check("...and the log says how many", "returned to the assignment queue" in one("select summary from activity_log where organization_id = %s and action = 'member.removed' order by created_at desc limit 1", (ORG,)))
check("his offers are withdrawn", count("select count(*) from package_members where user_id = %s", (cal,)) == 0)
check("he can't see the company's bookings any more", sql_as(cal, "select count(*) from bookings where creator_id = %s", (ORG,))[0][0][0] == 0)
check("the queue holds the booking", lbid in [str(r[0]) for r in rows(mia, "assignment_queue", ORG)])
check("a Manager gives it to Kim", jb(mia, "assign_booking", lbid, kim)["assigned_to"] == kim)

print("\n[a lapsed company]")
a.execute("update organizations set state = 'lapsed' where id = %s", (ORG,))
check("clients can't book a lapsed company", err(preview(client_a, at(MON + 28, 10), PKG), "package_unavailable"))
check("the team can't cancel", err(rpc(mia, "cancel_booking", lbid), "not_cancellable"))
check("the client still can", rpc(client_a, "cancel_booking", lbid)["booking"]["status"] == "cancelled")
a.execute("update organizations set state = 'active' where id = %s", (ORG,))

print("\n[from one person to a company, and back]")
pat = new_user("pat-lee", "Pat Lee")
add_signature(pat, "Pat Lee")
a.execute("insert into availability_settings (creator_id, time_zone, weekly, min_notice_hours, max_advance_days, buffer_minutes, slot_interval_minutes) values (%s,%s,%s,2,180,30,30)",
          (pat, TZ, json.dumps(WEEKLY)))
a.execute("insert into contract_templates (creator_id, title, kind, clauses) values (%s,'Pat terms','photography',%s) returning id", (pat, Json(CLAUSES)))
ptmpl = a.fetchone()[0]
a.execute("""insert into packages (creator_id, name, price_cents, duration_minutes, deposit_cents, contract_template_id)
             values (%s,'Pat portraits',80000,60,0,%s), (%s,'Pat events',150000,120,0,%s) returning id""", (pat, ptmpl, pat, ptmpl))
pat_pkgs = [r[0] for r in a.fetchall()]
old = book(client_a, at(MON + 14, 11), pat_pkgs[0], name="Old Client")
check("Pat has an executed contract as an individual", isinstance(old, dict) and old["contract"]["status"] == "executed" and old["contract"]["creator_id"] == pat, old)
check("a person can't upgrade without a profile", err(rpc(new_user(), "org_upgrade", "no-profile", "No Profile", "No Profile LLC"), "profile_required"))
a.execute("""insert into packages (creator_id, name, price_cents, duration_minutes, deposit_cents, contract_template_id)
             values (%s,'Deposit job',100000,60,20000,%s) returning id""", (pat, ptmpl))
dep_pkg = a.fetchone()[0]
a.execute("insert into creator_payment_accounts (creator_id, stripe_account_id, charges_enabled, payouts_enabled, details_submitted) values (%s,'acct_pat',true,true,true)", (pat,))
held = book(client_b, at(MON + 14, 14), dep_pkg)
check("a booking in its hold blocks the upgrade", err(rpc(pat, "org_upgrade", "pat-films", "Pat Films", "Pat Films LLC"), "bookings_in_hold"))
raw("update bookings set status = 'cancelled', cancelled_at = now(), hold_expires_at = null where id = %s", (held["booking"]["id"],))
check("a taken handle is refused", err(rpc(pat, "org_upgrade", "acme-films", "Pat Films", "Pat Films LLC"), "handle_taken"))
up = rpc(pat, "org_upgrade", "pat-films", "Pat Films", "Pat Films LLC", "5 Elm St")
check("Pat upgrades", isinstance(up, dict) and up["my_role"] == "owner" and up["legal_name"] == "Pat Films LLC", up)
PAT_ORG = up["organization_id"]
check("the services moved to the company", count("select count(*) from packages where creator_id = %s", (PAT_ORG,)) == 3 and count("select count(*) from packages where creator_id = %s", (pat,)) == 0)
check("so did the templates", count("select count(*) from contract_templates where creator_id = %s", (PAT_ORG,)) == 1 and count("select count(*) from contract_templates where creator_id = %s", (pat,)) == 0)
check("the signed work stayed", booking(old["booking"]["id"])["owner"] == pat and booking(old["booking"]["id"])["who"] == pat
      and one("select creator_id from contracts where id = %s", (old["contract"]["id"],)) == pat
      and one("select status from contracts where id = %s", (old["contract"]["id"],)) == "executed")
check("Pat's profile, signature and hours are still theirs", count("select count(*) from creator_profiles where id = %s and kind = 'person'", (pat,)) == 1
      and count("select count(*) from creator_signatures where creator_id = %s", (pat,)) == 1
      and count("select count(*) from availability_settings where creator_id = %s", (pat,)) == 1)
check("the company started with Pat's hours", count("select count(*) from availability_settings where creator_id = %s and weekly = %s::jsonb", (PAT_ORG, json.dumps(WEEKLY))) == 1)
check("the company page is prefilled from Pat's profile", count("select count(*) from creator_profiles where id = %s and kind = 'company'", (PAT_ORG,)) == 1)
check("the upgrade is logged once, with the numbers", one("select summary from activity_log where organization_id = %s and action = 'org.upgraded'", (PAT_ORG,)) ==
      "Upgraded from an individual account: moved 3 services and 1 contract template")
check("moving services wasn't logged as edits", count("select count(*) from activity_log where organization_id = %s and action like 'package.%%'", (PAT_ORG,)) == 0)
check("a signer is needed before clients can book", err(preview(client_b, at(MON + 15, 10), pat_pkgs[0]), "creator_not_ready"))
rpc(pat, "org_designate_signer", PAT_ORG, pat, "Founder")
nb = book(client_b, at(MON + 15, 10), pat_pkgs[0], name="New Client")
check("then clients book the company, and Pat is the only one who can take it", isinstance(nb, dict) and booking(nb["booking"]["id"])["who"] == pat
      and booking(nb["booking"]["id"])["owner"] == PAT_ORG, nb)
check("Pat's old contract still names Pat", "Pat Lee" in old["contract"]["sections"][0]["body"] and "Pat Films" not in old["contract"]["sections"][0]["body"])
check("downgrading is refused with a booking coming up", err(rpc(pat, "org_downgrade", PAT_ORG), "has_upcoming_bookings"))
rpc(pat, "cancel_booking", nb["booking"]["id"])
join(PAT_ORG, pat, "creator", client_a, "Ann A")
check("...or with a team", err(rpc(pat, "org_downgrade", PAT_ORG), "team_not_empty"))
rpc(pat, "member_remove", PAT_ORG, client_a)
check("only the Owner may downgrade", err(rpc(client_b, "org_downgrade", PAT_ORG), "not_found"))
res = rpc(pat, "org_downgrade", PAT_ORG)
check("Pat goes back to working alone", isinstance(res, dict) and res["companies"] == [], res)
check("the services came back", count("select count(*) from packages where creator_id = %s", (pat,)) == 3 and count("select count(*) from packages where creator_id = %s", (PAT_ORG,)) == 0)
check("the templates too", count("select count(*) from contract_templates where creator_id = %s", (pat,)) == 1)
check("the company is closed, and kept", one("select state from organizations where id = %s", (PAT_ORG,)) == "closed"
      and count("select count(*) from contracts where creator_id = %s", (PAT_ORG,)) == 1)

print("\n[deleting an account]")
check("an Owner can't delete their account while they own a company", [x["name"] for x in svc("account_blockers", olivia)] == ["Acme Films"])
check("anyone else can", svc("account_blockers", cal) == [] and svc("account_blockers", pat) == [])

print("\n[races: many clients, few people]")
import threading

r_owner, r_a, r_b, r_c = new_user("rhea-q", "Rhea Q"), new_user(), new_user(), new_user()
add_signature(r_owner, "Rhea Q")
RACE = rpc(r_owner, "org_create", "race-films", "Race Films", "Race Films LLC")["organization_id"]
join(RACE, r_owner, "creator", r_a, "Ray A")
join(RACE, r_owner, "creator", r_b, "Bea B")
join(RACE, r_owner, "creator", r_c, "Cy C")
rpc(r_owner, "member_update", RACE, r_owner, None, None, False)
a.execute("insert into availability_settings (creator_id, time_zone, weekly, min_notice_hours, max_advance_days, buffer_minutes, slot_interval_minutes) values (%s,%s,%s,2,180,30,30)",
          (RACE, TZ, json.dumps(WEEKLY)))
a.execute("insert into contract_templates (creator_id, title, kind, clauses) values (%s,'Race terms','photography',%s) returning id", (RACE, Json(CLAUSES)))
rt = a.fetchone()[0]
a.execute("insert into packages (creator_id, name, price_cents, duration_minutes, deposit_cents, contract_template_id) values (%s,'Race shoot',100000,60,0,%s) returning id", (RACE, rt))
RPKG = a.fetchone()[0]
rpc(r_owner, "org_designate_signer", RACE, r_owner, "Founder")
a.execute("insert into availability_settings (creator_id, time_zone, weekly, min_notice_hours, max_advance_days, buffer_minutes, slot_interval_minutes) values (%s,%s,%s,2,180,30,30)",
          (r_a, TZ, json.dumps(WEEKLY)))
a.execute("insert into contract_templates (creator_id, title, kind, clauses) values (%s,'Ray terms','photography',%s) returning id", (r_a, Json(CLAUSES)))
rat = a.fetchone()[0]
a.execute("insert into creator_signatures (creator_id, signed_name, method) values (%s,'Ray A','typed')", (r_a,))
a.execute("insert into packages (creator_id, name, price_cents, duration_minutes, deposit_cents, contract_template_id) values (%s,'Ray solo',50000,60,0,%s) returning id", (r_a, rat))
RAY_PKG = a.fetchone()[0]


def company_race(label, jobs, expect_wins):
    """jobs: [(package, start, member_or_None)], each by a different new client, released together."""
    users = [new_user() for _ in jobs]
    barrier = threading.Barrier(len(jobs))
    results = [None] * len(jobs)

    def worker(i):
        pkg, start, member = jobs[i]
        c, k = as_user(users[i])
        h = None
        try:
            k.execute("select preview_contract(%s, '{}'::uuid[], %s, 'Racer', '')", (pkg, start))
            h = k.fetchone()[0]["document_hash"]
        except psycopg2.Error as e:
            results[i] = first_line(e)
        barrier.wait()
        if h is not None:
            try:
                k.execute("select create_booking(%s, '{}'::uuid[], %s, 'Racer', '', %s, %s, %s)", (pkg, start, h, Json(sig("Racer")), member))
                results[i] = "OK"
            except psycopg2.Error as e:
                results[i] = first_line(e)
        c.close()

    ts = [threading.Thread(target=worker, args=(i,)) for i in range(len(jobs))]
    [t.start() for t in ts]
    [t.join() for t in ts]
    wins = results.count("OK")
    taken = sum(1 for r in results if "slot_taken" in r)
    other = [r for r in results if r != "OK" and "slot_taken" not in r][:2]
    check(f"{label}: exactly {expect_wins} won", wins == expect_wins, f"wins={wins} taken={taken} other={other}")
    check(f"{label}: everyone else was told 'slot_taken' (no deadlocks or other errors)", taken == len(jobs) - expect_wins, f"taken={taken} other={other}")


company_race("30 clients, one slot, three shooters", [(RPKG, at(MON + 35, 10), None)] * 30, 3)
company_race("30 clients, one named person", [(RPKG, at(MON + 35, 13), r_b)] * 30, 1)
company_race("20 clients for the company and 20 for the same person alone", [(RPKG, at(MON + 36, 10), r_a)] * 20 + [(RAY_PKG, at(MON + 36, 10), None)] * 20, 1)
company_race("overlapping times for one person", [(RPKG, at(MON + 37, 10), r_c), (RPKG, at(MON + 37, 10, 30), r_c)] * 10, 1)
rpc(r_owner, "org_update", RACE, None, None, "manual", None)
company_race("30 clients, manual assignment, three people free", [(RPKG, at(MON + 38, 10), None)] * 30, 3)
a.execute("""select count(*) from bookings x join bookings y on x.assigned_to = y.assigned_to and x.id < y.id
              where x.status in ('held','confirmed') and y.status in ('held','confirmed')
              and tstzrange(x.start_at, x.blocked_until) && tstzrange(y.start_at, y.blocked_until)""")
check("after all of that, nobody is in two places", a.fetchone()[0] == 0)
check("every one of those bookings has one executed contract", count("""select count(*) from bookings b left join contracts c on c.booking_id = b.id
                                                                           where b.creator_id = %s and (c.id is null or c.status <> 'executed')""", (RACE,)) == 0)

print("\n[nothing leaked to the API that shouldn't be]")
check("a client can't call the internals", all(isinstance(rpc(client_a, f, *args), str) for f, args in (
    ("provider_access", (client_a, ORG, None, "view")), ("provider_recipients", (ORG, None)),
    ("member_slot_state", ()), ("connect_authorize", (olivia, ORG)), ("account_blockers", (olivia,)), ("is_booking_party", (client_a, cbid)))))
check("a signed-out caller can't book", isinstance(rpc(None, "create_booking", PKG, [], at(MON + 30, 10), "x", "", "0" * 64, Json(sig()), None, role="anon"), str))

print("\n" + ("ALL PASSED" if not failures else f"{len(failures)} FAILED: {failures}"))
sys.exit(1 if failures else 0)
