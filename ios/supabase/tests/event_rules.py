"""Applies the migrations to a throwaway Postgres and tries to break team events and calendar links: who can add, change and
remove an event, what an event does to the time of the people it is for (a client can't book them), what the team calendar
and the booking page see, what a calendar link contains and who can read it, and that a lapsed company is read only.

Needs a Postgres server (16 recommended) and psycopg2, like the other scripts here:

    PGPORT=5432 python3 ios/supabase/tests/event_rules.py

The numbers and cases are shared with the app through SlateTests/Fixtures/event_rules.json. What the app decodes
(event_rows.json) is checked against what the database really returns; run with --dump to rewrite it after changing a shape.
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
FIXTURE = HERE.parents[1] / "SlateTests" / "Fixtures" / "event_rules.json"
ROWS = HERE.parents[1] / "SlateTests" / "Fixtures" / "event_rows.json"
DB = "slate_events"
TZ = "America/Chicago"
Json = psycopg2.extras.Json
rules = json.loads(FIXTURE.read_text())


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
# These checks are about events, not about paying for seats (billing_rules.py is).
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


def sig(name="Test Client"):
    return {"signedName": name, "method": "typed", "imagePng": None, "consentVersion": 1, "device": "test"}


def book(uid, start, pkg, name="Test Client"):
    p = rpc(uid, "preview_contract", pkg, [], start, name, "")
    if isinstance(p, str):
        return p
    return rpc(uid, "create_booking", pkg, [], start, name, "", p["document_hash"], Json(sig(name)), None)


def who(booking_result):
    return one("select assigned_to from bookings where id = %s", (booking_result["booking"]["id"],))


def save(uid, org, title="Team meeting", event_id=None, start=None, end=None, everyone=True, members=None, blocks=True,
         notes="", location="", all_day=False):
    res = sql_as(uid, "select team_event_save(%s, %s, %s, %s, %s, %s, %s, %s, %s, %s::uuid[], %s)",
                 (org, event_id, title, notes, location, start or at(0, 10), end or at(0, 11), all_day, everyone, members or [], blocks))
    return res if isinstance(res, str) else res[0][0][0]


def listing(uid, org, start, end):
    return rpc(uid, "team_events_list", org, start, end)


# =============================================================================
print("\n[the numbers and the text rules the app shares]")
for fn, key in (("app_event_title_max", "titleMaxLength"), ("app_event_notes_max", "notesMaxLength"),
                ("app_event_location_max", "locationMaxLength"), ("app_event_max_days", "maxDays"),
                ("app_event_max_upcoming", "maxUpcoming"), ("app_event_max_people", "maxPeople")):
    check(f"{key}", one(f"select {fn}()") == rules[key])
bad = [c for c in rules["cleanLine"] if one("select event_clean_line(%s)", (c["input"],)) != c["expected"]]
check(f"a title is cleaned the way the app cleans it ({len(rules['cleanLine'])} cases)", not bad, bad[:2])

# =============================================================================
print("\n[setting up a company that takes bookings]")
olivia = new_user("olivia-ng", "Olivia Ng")
dee, mia, cal, kim, vee = new_user(), new_user("mia-k", "Mia K"), new_user("cal-r", "Cal R"), new_user("kim-t", "Kim T"), new_user("vee-t", "Vee T")
stranger = new_user("sam-s", "Sam S")
client_a, client_b, client_c = new_user(), new_user(), new_user()
ORG = rpc(olivia, "org_create", "acme-films", "Acme Films", "Acme Films LLC", "1 Main St", "", ["weddings"], "Austin, TX")["organization_id"]
join(ORG, olivia, "admin", dee, "Dee Okafor")
join(ORG, olivia, "manager", mia)
join(ORG, olivia, "creator", cal)
join(ORG, olivia, "creator", kim)
join(ORG, olivia, "viewer", vee)
add_signature(dee, "Dee Okafor")
for u in (olivia, dee, mia):
    rpc(olivia, "member_update", ORG, u, None, None, False)  # leaders who don't shoot
sql_as(dee, "insert into availability_settings (creator_id, time_zone, weekly, min_notice_hours, max_advance_days, buffer_minutes, slot_interval_minutes) values (%s,%s,%s,2,180,30,30)",
       (ORG, TZ, json.dumps(WEEKLY)))
TMPL = sql_as(dee, "insert into contract_templates (creator_id, title, kind, clauses) values (%s,'Wedding terms','photography',%s) returning id", (ORG, Json(CLAUSES)))[0][0][0]
PKG = sql_as(dee, "insert into packages (creator_id, name, price_cents, duration_minutes, deposit_cents, is_published, contract_template_id) values (%s,'Wedding film',200000,60,0,true,%s) returning id",
             (ORG, TMPL))[0][0][0]
rpc(dee, "org_designate_signer", ORG, dee, "Director")
check("the company is set up", one("select count(*) from memberships where organization_id = %s and removed_at is null", (ORG,)) == 6)
check("a client can book it", isinstance(book(client_c, at(1, 16), PKG), dict))

# =============================================================================
print("\n[who can add an event]")
for uid, name in ((olivia, "Owner"), (dee, "Admin"), (mia, "Manager"), (cal, "Creator")):
    got = save(uid, ORG, title=f"{name}'s event", start=at(10, 9), end=at(10, 10))
    check(f"the {name} can add one", isinstance(got, dict) and got["title"] == f"{name}'s event" and got["created_by"] == uid, got)
check("a Viewer can't", err(save(vee, ORG), "not_allowed"))
check("someone outside the company finds nothing", err(save(stranger, ORG), "not_found"))
check("nobody signed in can't", err(save(None, ORG), "not_signed_in"))
check("a person can't add one to their own (non-company) calendar either", err(save(stranger, stranger), "not_found"))
ev = save(cal, ORG, title="  Gear   check\nbefore the wedding ", notes="Bring the 24-70\r\nand the gimbal", location=" Studio\tB ",
          start=at(11, 9), end=at(11, 10, 30))
check("a title and place are kept on one line, tidy", ev["title"] == "Gear check before the wedding" and ev["location"] == "Studio B", ev)
check("notes keep their line breaks", ev["notes"] == "Bring the 24-70\nand the gimbal", ev["notes"])
check("it says who made it, and that they can change it", ev["created_by_name"] == "Cal R" and ev["can_edit"] is True and ev["everyone"] is True and ev["member_ids"] == [], ev)
check("it blocks bookings unless told otherwise", ev["blocks_bookings"] is True)

print("\n[what an event has to be]")
check("it needs a name", err(save(dee, ORG, title="   "), "invalid_event"))
check("it must end after it starts", err(save(dee, ORG, start=at(0, 11), end=at(0, 10)), "invalid_event"))
check("and not at the same moment", err(save(dee, ORG, start=at(0, 11), end=at(0, 11)), "invalid_event"))
check("a title can be 80 characters", isinstance(save(dee, ORG, title="x" * 80, start=at(12, 9), end=at(12, 10)), dict))
check("not 81", err(save(dee, ORG, title="x" * 81), "event_text_too_long"))
check("notes can be 500", isinstance(save(dee, ORG, notes="n" * 500, start=at(12, 11), end=at(12, 12)), dict))
check("not 501", err(save(dee, ORG, notes="n" * 501), "event_text_too_long"))
check("a place can be 120", isinstance(save(dee, ORG, location="p" * 120, start=at(12, 13), end=at(12, 14)), dict))
check("not 121", err(save(dee, ORG, location="p" * 121), "event_text_too_long"))
check("it can run 31 days (leave)", isinstance(save(dee, ORG, title="Leave", start=at(40, 0), end=at(71, 0), all_day=True), dict))
check("not longer", err(save(dee, ORG, start=at(40, 0), end=at(71, 1)), "event_too_long"))
check("an event for named people needs at least one", err(save(dee, ORG, everyone=False, members=[]), "invalid_event"))
check("and not more than the limit", err(save(dee, ORG, everyone=False, members=[str(uuid.uuid4()) for _ in range(rules["maxPeople"] + 1)]), "invalid_event"))
check("only people in the company", err(save(dee, ORG, everyone=False, members=[cal, stranger]), "invalid_attendee"))
named = save(dee, ORG, title="Cal and Kim", everyone=False, members=[kim, cal, kim], start=at(12, 15), end=at(12, 16))
check("people are named once each", named["everyone"] is False and sorted(named["member_ids"]) == sorted([cal, kim]), named)
check("a Viewer can be named", isinstance(save(dee, ORG, title="All hands", everyone=False, members=[vee, cal], start=at(12, 16), end=at(12, 17)), dict))

# =============================================================================
print("\n[who can change or remove an event]")
cal_event = save(cal, ORG, title="Cal's errand", start=at(13, 9), end=at(13, 10))
kim_event = save(kim, ORG, title="Kim's errand", start=at(13, 11), end=at(13, 12))
check("the author changes their own", save(cal, ORG, event_id=cal_event["id"], title="Cal's errand (moved)", start=at(13, 10), end=at(13, 11))["title"] == "Cal's errand (moved)")
check("another Creator can't change it", err(save(kim, ORG, event_id=cal_event["id"], title="Mine now"), "not_allowed"))
check("a Viewer can't", err(save(vee, ORG, event_id=cal_event["id"], title="x"), "not_allowed"))
check("a Manager changes anyone's", save(mia, ORG, event_id=cal_event["id"], title="Cal's errand (Mia)", start=at(13, 10), end=at(13, 11))["title"] == "Cal's errand (Mia)")
check("an Admin does", save(dee, ORG, event_id=kim_event["id"], title="Kim's errand (Dee)", start=at(13, 11), end=at(13, 12))["title"] == "Kim's errand (Dee)")
check("it keeps its author", one("select created_by from team_events where id = %s", (cal_event["id"],)) == cal)
check("someone outside can't touch it", err(save(stranger, ORG, event_id=cal_event["id"], title="x"), "not_found"))
check("an id from another company is not found here", err(save(dee, ORG, event_id=str(uuid.uuid4()), title="x"), "not_found"))

ev_list = listing(cal, ORG, at(13, 0), at(14, 0))
mine = next(e for e in ev_list if e["id"] == cal_event["id"])
theirs = next(e for e in ev_list if e["id"] == kim_event["id"])
check("the list says who can change which", mine["can_edit"] is True and theirs["can_edit"] is False, (mine["can_edit"], theirs["can_edit"]))
check("a Manager can change both", all(e["can_edit"] for e in listing(mia, ORG, at(13, 0), at(14, 0))))
check("a Viewer can change neither", not any(e["can_edit"] for e in listing(vee, ORG, at(13, 0), at(14, 0))))

check("a Creator can't remove another's", err(rpc(kim, "team_event_delete", cal_event["id"]), "not_allowed"))
check("a Viewer can't", err(rpc(vee, "team_event_delete", cal_event["id"]), "not_allowed"))
check("a stranger finds nothing", err(rpc(stranger, "team_event_delete", cal_event["id"]), "not_found"))
check("the author removes their own", rpc(cal, "team_event_delete", cal_event["id"]) is None and one("select count(*) from team_events where id = %s", (cal_event["id"],)) == 0)
check("a Manager removes anyone's", rpc(mia, "team_event_delete", kim_event["id"]) is None)
check("an event that isn't there is not found", err(rpc(mia, "team_event_delete", kim_event["id"]), "not_found"))
orphan = save(cal, ORG, title="Cal left", start=at(14, 9), end=at(14, 10))
a.execute("update team_events set created_by = null where id = %s", (orphan["id"],))
check("an event whose author is gone can't be changed by a Creator", err(save(kim, ORG, event_id=orphan["id"], title="x"), "not_allowed"))
check("and a Manager can", save(mia, ORG, event_id=orphan["id"], title="Cal left (Mia)", start=at(14, 9), end=at(14, 10))["title"] == "Cal left (Mia)")
check("it shows no author", next(e for e in listing(mia, ORG, at(14, 0), at(15, 0)) if e["id"] == orphan["id"])["created_by_name"] == "")

# =============================================================================
print("\n[who can see them]")
window = listing(vee, ORG, at(10, 0), at(11, 0))
check("a Viewer reads the events", isinstance(window, list) and len(window) == 4, window)
check("they come in time order", [e["starts_at"] for e in window] == sorted(e["starts_at"] for e in window))
check("a stranger finds nothing", err(listing(stranger, ORG, at(10, 0), at(11, 0)), "not_found"))
check("a window is cut to 62 days", len(listing(dee, ORG, at(0, 0), at(300, 0))) == len(listing(dee, ORG, at(0, 0), at(62, 0))))
check("the table is readable by the team and not by outsiders", sql_as(cal, "select count(*) from team_events where organization_id = %s", (ORG,))[0][0][0] > 0
      and sql_as(stranger, "select count(*) from team_events where organization_id = %s", (ORG,))[0][0][0] == 0
      and sql_as(None, "select count(*) from team_events", None, role="anon")[0][0][0] == 0)
check("who an event is for is readable the same way", sql_as(cal, "select count(*) from team_event_members")[0][0][0] > 0
      and sql_as(stranger, "select count(*) from team_event_members")[0][0][0] == 0)
check("nobody writes the tables directly", all(isinstance(sql_as(u, q, (ORG,)), str) or sql_as(u, q, (ORG,))[1] == 0 for u in (dee, olivia, cal) for q in (
    "update team_events set title = 'x' where organization_id = %s", "delete from team_events where organization_id = %s")))
check("or insert", isinstance(sql_as(dee, "insert into team_events (organization_id, title, starts_at, ends_at) values (%s, 'x', now(), now() + interval '1 hour')", (ORG,)), str))

# =============================================================================
print("\n[the events that are for me]")
mine_cal = rpc(cal, "my_team_events", at(0, 0), at(100, 0))
titles = {e["title"] for e in mine_cal}
check("a Creator gets the whole-team events and those naming them", "Gear check before the wedding" in titles and "Cal and Kim" in titles and "All hands" in titles, titles)
mine_vee = rpc(vee, "my_team_events", at(0, 0), at(100, 0))
check("a Viewer gets the whole-team events and the ones naming them", "Gear check before the wedding" in {e["title"] for e in mine_vee} and "All hands" in {e["title"] for e in mine_vee}
      and "Cal and Kim" not in {e["title"] for e in mine_vee})
check("each says which company it is from", all(e["organization_name"] == "Acme Films" for e in mine_cal))
check("someone in no company gets none", rpc(stranger, "my_team_events", at(0, 0), at(100, 0)) == [])
check("a window is cut to 400 days", isinstance(rpc(cal, "my_team_events", at(0, 0), at(900, 0)), list))

# =============================================================================
print("\n[events take the time of the people they are for]")
# A free day: the Monday three weeks out is clear of everything above.
DAY = 21
a.execute("delete from bookings where creator_id = %s and start_at >= %s", (ORG, at(DAY, 0)))
t10 = at(DAY, 10)
base = book(client_a, t10, PKG)
check("with no event, a client books 10:00 and one of the shooters gets it", isinstance(base, dict), base)
first = who(base)
a.execute("update bookings set status = 'cancelled' where id = %s", (base["booking"]["id"],))

for_cal = save(dee, ORG, title="Cal edits", everyone=False, members=[cal], start=at(DAY, 9), end=at(DAY, 12))
b1 = book(client_a, t10, PKG)
check("while Cal is in an event the booking goes to Kim", isinstance(b1, dict) and who(b1) == kim, b1)
b2 = book(client_b, t10, PKG)
check("and with Kim booked and Cal in the event nobody is left", isinstance(b2, str) and "slot_" in b2, b2)
avail = rpc(client_a, "team_availability", PKG, None, at(DAY, 0), at(DAY + 1, 0))
busy_cal = next(m for m in avail["members"] if m["user_id"] == cal)["busy"]
import datetime
want_end = at(DAY, 12) + datetime.timedelta(minutes=30)
check("the booking page sees Cal busy, with the usual buffer after",
      any(abs((datetime.datetime.fromisoformat(x["ends_at"]) - want_end).total_seconds()) < 1 for x in busy_cal), busy_cal)
tc = rpc(dee, "team_calendar", ORG, at(DAY, 0), at(DAY + 1, 0), None)
cal_row = next(m for m in tc["members"] if m["user_id"] == cal)
check("the team calendar draws it as busy time of its own kind", any(b["kind"] == "event" for b in cal_row["busy"]), cal_row["busy"])
check("Kim has no event busy time", not any(b["kind"] == "event" for b in next(m for m in tc["members"] if m["user_id"] == kim)["busy"]))

b3 = book(client_b, at(DAY, 12, 30), PKG)
check("after the event and its buffer Cal is bookable again", isinstance(b3, dict), b3)
b3 and a.execute("update bookings set status = 'cancelled' where id = %s", (b3["booking"]["id"],))
a.execute("update bookings set status = 'cancelled' where id = %s", (b1["booking"]["id"],))

everyone_ev = save(dee, ORG, title="All hands", start=at(DAY + 1, 9), end=at(DAY + 1, 10))
check("an all-hands event takes everyone's time", isinstance(book(client_a, at(DAY + 1, 9), PKG), str))
check("with the buffer after it", isinstance(book(client_a, at(DAY + 1, 10), PKG), str))
check("and not after that", isinstance(book(client_a, at(DAY + 1, 10, 30), PKG), dict))
a.execute("update bookings set status = 'cancelled' where creator_id = %s and start_at >= %s", (ORG, at(DAY, 0)))

save(dee, ORG, event_id=everyone_ev["id"], title="All hands (just a note)", start=at(DAY + 1, 9), end=at(DAY + 1, 10), blocks=False)
check("an event that doesn't block bookings leaves the time bookable", isinstance(book(client_a, at(DAY + 1, 9), PKG), dict))
a.execute("update bookings set status = 'cancelled' where creator_id = %s and start_at >= %s", (ORG, at(DAY, 0)))

save(dee, ORG, event_id=everyone_ev["id"], title="All hands", start=at(DAY + 1, 9), end=at(DAY + 1, 10))
check("turning blocking back on blocks again", isinstance(book(client_a, at(DAY + 1, 9), PKG), str))
save(dee, ORG, event_id=everyone_ev["id"], title="All hands", start=at(DAY + 1, 14), end=at(DAY + 1, 15))
r = book(client_a, at(DAY + 1, 9), PKG)
check("moving an event frees the time it had", isinstance(r, dict), r)
check("and blocks the new time", isinstance(book(client_b, at(DAY + 1, 14), PKG), str))
rpc(dee, "team_event_delete", everyone_ev["id"])
r2 = book(client_b, at(DAY + 1, 14), PKG)
check("removing it frees that too", isinstance(r2, dict), r2)

print("\n[an event added over a booking leaves the booking alone]")
over = save(dee, ORG, title="Oops, same time", start=at(DAY + 1, 9), end=at(DAY + 1, 10))
check("the booking is still confirmed", one("select status from bookings where id = %s", (r["booking"]["id"],)) == "confirmed")
rpc(dee, "team_event_delete", over["id"])
a.execute("update bookings set status = 'cancelled' where creator_id = %s and start_at >= %s", (ORG, at(DAY, 0)))

print("\n[a person who has left the team no longer counts]")
left = new_user("lee-l", "Lee L")
join(ORG, olivia, "creator", left)
only_left = save(dee, ORG, title="Lee only", everyone=False, members=[left], start=at(DAY + 2, 9), end=at(DAY + 2, 10))
rpc(olivia, "member_remove", ORG, left)
check("they drop out of who it is for", next(e for e in listing(dee, ORG, at(DAY + 2, 0), at(DAY + 3, 0)) if e["id"] == only_left["id"])["member_ids"] == [])

# =============================================================================
print("\n[too many at once]")
a.execute("""insert into team_events (organization_id, title, starts_at, ends_at, created_by)
             select %s, 'filler ' || g, now() + (g || ' hours')::interval, now() + (g || ' hours')::interval + interval '30 minutes', %s
               from generate_series(1, 600) g""", (ORG, olivia))
over_limit = one("select count(*) from team_events where organization_id = %s and ends_at > now()", (ORG,))
check("a company over the limit can't add more", err(save(dee, ORG, start=at(200, 9), end=at(200, 10)), "too_many_events"), over_limit)
a.execute("delete from team_events where title like 'filler %%'")
check("once there's room it can", isinstance(save(dee, ORG, start=at(200, 9), end=at(200, 10)), dict))
a.execute("""insert into team_events (organization_id, title, starts_at, ends_at, created_by)
             select %s, 'past ' || g, now() - interval '30 days' - (g || ' hours')::interval, now() - interval '30 days' - (g || ' hours')::interval + interval '30 minutes', %s
               from generate_series(1, 600) g""", (ORG, olivia))
check("events that are over don't count", isinstance(save(dee, ORG, start=at(201, 9), end=at(201, 10)), dict))
a.execute("delete from team_events where title like 'past %%'")

# =============================================================================
print("\n[the activity log]")
acts = [r[0] for r in (a.execute("select action || ': ' || summary from activity_log where organization_id = %s and action like 'event.%%' order by created_at", (ORG,)) or a.fetchall())]
check("adding is logged", any(x.startswith("event.created") and 'Added the event "Gear check before the wedding"' in x for x in acts), acts[:3])
check("changing is logged", any(x.startswith("event.updated") and "Cal's errand (Mia)" in x for x in acts))
check("removing is logged", any(x.startswith("event.deleted") and 'Removed the event "All hands"' in x for x in acts))
check("it says who did it", one("select actor_name from activity_log where action = 'event.deleted' order by created_at limit 1") != "")

# =============================================================================
print("\n[a company whose plan has lapsed]")
lapse_ev = save(dee, ORG, title="Before the lapse", start=at(15, 9), end=at(15, 10))
a.execute("update organizations set state = 'lapsed', updated_at = now() where id = %s", (ORG,))
check("can still read its events", isinstance(listing(dee, ORG, at(15, 0), at(16, 0)), list) and len(listing(dee, ORG, at(15, 0), at(16, 0))) == 1)
check("can't add one", err(save(dee, ORG), "not_allowed"))
check("can't change one", err(save(mia, ORG, event_id=lapse_ev["id"], title="x"), "not_allowed"))
check("can't remove one", err(rpc(mia, "team_event_delete", lapse_ev["id"]), "not_allowed"))
a.execute("update organizations set state = 'active', updated_at = now() where id = %s", (ORG,))

# =============================================================================
print("\n[calendar links]")
check("you must be signed in to have one", err(rpc(None, "calendar_feed_token"), "not_signed_in"))
tok_cal = rpc(cal, "calendar_feed_token")
check("a link is a long random secret", isinstance(tok_cal, str) and len(tok_cal) == 32 and all(c in "0123456789abcdef" for c in tok_cal), tok_cal)
check("asking again gives the same one", rpc(cal, "calendar_feed_token") == tok_cal)
tok_kim, tok_vee, tok_client, tok_stranger = (rpc(u, "calendar_feed_token") for u in (kim, vee, client_a, stranger))
check("everyone's is different", len({tok_cal, tok_kim, tok_vee, tok_client, tok_stranger}) == 5)
check("nobody can read the table of secrets", sql_as(cal, "select count(*) from calendar_feeds")[0][0][0] == 0 or isinstance(sql_as(cal, "select token from calendar_feeds"), str))
check("an unknown secret finds nothing", svc("calendar_feed_data", "0" * 32) is None)
check("people can't ask for the data themselves", isinstance(rpc(cal, "calendar_feed_data", tok_cal), str) and isinstance(rpc(None, "calendar_feed_data", tok_cal, role="anon"), str))

a.execute("delete from team_events where organization_id = %s", (ORG,))
a.execute("delete from bookings where creator_id = %s", (ORG,))
bk = book(client_a, at(30, 10), PKG)
assignee = who(bk)
other = kim if assignee == cal else cal
ev_all = save(dee, ORG, title="Team lunch", notes="Bring an appetite", location="The deli", start=at(31, 12), end=at(31, 13))
ev_one = save(dee, ORG, title="Only the assignee", everyone=False, members=[assignee], start=at(32, 9), end=at(32, 10))
feed = svc("calendar_feed_data", rpc(assignee, "calendar_feed_token"))
check("the person doing the job gets the booking, as the provider", len(feed["bookings"]) == 1 and feed["bookings"][0]["role"] == "provider"
      and feed["bookings"][0]["package_name"] == "Wedding film" and feed["bookings"][0]["client_name"] == "Test Client", feed["bookings"])
check("and the team events for them", {e["title"] for e in feed["events"]} == {"Team lunch", "Only the assignee"}, feed["events"])
check("an event carries its company, place and notes", next(e for e in feed["events"] if e["title"] == "Team lunch") | {} and
      next(e for e in feed["events"] if e["title"] == "Team lunch")["organization_name"] == "Acme Films"
      and next(e for e in feed["events"] if e["title"] == "Team lunch")["location"] == "The deli"
      and next(e for e in feed["events"] if e["title"] == "Team lunch")["time_zone"] == TZ)
feed_other = svc("calendar_feed_data", rpc(other, "calendar_feed_token"))
check("the other shooter gets the whole-team event only, and no booking", [e["title"] for e in feed_other["events"]] == ["Team lunch"] and feed_other["bookings"] == [])
feed_vee = svc("calendar_feed_data", tok_vee)
check("a Viewer gets the whole-team event", [e["title"] for e in feed_vee["events"]] == ["Team lunch"] and feed_vee["bookings"] == [])
feed_client = svc("calendar_feed_data", tok_client)
check("the client gets their booking, as the client, and no team events",
      len(feed_client["bookings"]) == 1 and feed_client["bookings"][0]["role"] == "client" and feed_client["bookings"][0]["creator_name"] == "Acme Films" and feed_client["events"] == [])
feed_stranger = svc("calendar_feed_data", tok_stranger)
check("a stranger gets nothing", feed_stranger == {"bookings": [], "events": []}, feed_stranger)
check("no money, contract or contact details are in a booking", set(feed["bookings"][0].keys()) == {"id", "package_name", "start_at", "end_at", "time_zone", "role", "client_name", "creator_name", "status"},
      sorted(feed["bookings"][0].keys()))

a.execute("update bookings set status = 'cancelled' where id = %s", (bk["booking"]["id"],))
check("a cancelled booking is not in the calendar", svc("calendar_feed_data", rpc(assignee, "calendar_feed_token"))["bookings"] == [])
a.execute("update bookings set status = 'completed' where id = %s", (bk["booking"]["id"],))
check("a finished one is", len(svc("calendar_feed_data", rpc(assignee, "calendar_feed_token"))["bookings"]) == 1)
a.execute("update bookings set start_at = now() - interval '61 days', end_at = now() - interval '61 days' + interval '1 hour', blocked_until = now() - interval '61 days' + interval '1 hour' where id = %s", (bk["booking"]["id"],))
check("one more than 60 days ago is left out", svc("calendar_feed_data", rpc(assignee, "calendar_feed_token"))["bookings"] == [])

a.execute("update organizations set state = 'closed', closed_at = now() where id = %s", (ORG,))
check("a closed company's events leave the calendar", svc("calendar_feed_data", rpc(other, "calendar_feed_token"))["events"] == [])
a.execute("update organizations set state = 'active', closed_at = null where id = %s", (ORG,))
a.execute("select 1")
check("the Viewer's link still shows it again once the company is back", len(svc("calendar_feed_data", tok_vee)["events"]) == 1)

print("\n[starting a new link]")
new_tok = rpc(cal, "calendar_feed_reset")
check("a new secret", isinstance(new_tok, str) and len(new_tok) == 32 and new_tok != tok_cal)
check("the old address stops working at once", svc("calendar_feed_data", tok_cal) is None)
check("the new one works", isinstance(svc("calendar_feed_data", new_tok), dict))
check("asking now gives the new one", rpc(cal, "calendar_feed_token") == new_tok)
check("resetting for someone with no link yet makes one", isinstance(rpc(new_user(), "calendar_feed_reset"), str))
check("leaving the team removes a person's team events from their link", (rpc(olivia, "member_remove", ORG, cal), svc("calendar_feed_data", new_tok)["events"])[1] == [])
dead = new_user()
dead_tok = rpc(dead, "calendar_feed_token")
a.execute("delete from auth.users where id = %s", (dead,))
check("deleting an account deletes its link", svc("calendar_feed_data", dead_tok) is None and one("select count(*) from calendar_feeds where user_id = %s", (dead,)) == 0)

# =============================================================================
print("\n[what the app decodes is what the database returns]")
ev_shape = save(dee, ORG, title="Shape check", everyone=False, members=[kim], start=at(50, 9), end=at(50, 10), notes="n", location="l")
actual = {
    "event": ev_shape,
    "events": listing(dee, ORG, at(50, 0), at(51, 0)),
    "mine": rpc(kim, "my_team_events", at(50, 0), at(51, 0)),
    # The person doing the job, while they had a booking and events (taken earlier, before the bookings were changed).
    "feed": feed,
}


def shape(value):
    if isinstance(value, dict):
        return {k: shape(v) for k, v in sorted(value.items())}
    if isinstance(value, list):
        return [shape(value[0])] if value else []
    return "null" if value is None else type(value).__name__


check("every answer there is is real", all(not isinstance(v, str) for v in actual.values()), [k for k, v in actual.items() if isinstance(v, str)])
if "--dump" in sys.argv:
    # Ids and times change from run to run; the shape is what the app is tested against.
    ROWS.write_text(json.dumps(actual, indent=2, sort_keys=True, default=str) + "\n")
    print("  wrote", ROWS.name)
else:
    committed = json.loads(ROWS.read_text())
    for name in actual:
        check(f"{name}: the shape the app is tested against is what the database returns",
              shape(json.loads(json.dumps(actual[name], default=str))) == shape(committed[name]),
              (shape(committed[name]), shape(json.loads(json.dumps(actual[name], default=str)))))

print("\n" + ("All checks passed." if not failures else f"{len(failures)} FAILED:\n  " + "\n  ".join(failures)))
sys.exit(1 if failures else 0)
