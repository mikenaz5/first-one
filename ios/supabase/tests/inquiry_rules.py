"""Applies the migrations to a throwaway Postgres and tries to break messaging before a booking (inquiries): who can start
one and with whom, the limits that keep strangers from flooding a creator, who can read and answer (a person, each role at a
company, a stranger), what is read and unread, who is notified, and that bookings' conversations are untouched.

Needs a Postgres server (16 recommended) and psycopg2, like the other scripts here:

    PGPORT=5432 python3 ios/supabase/tests/inquiry_rules.py

The numbers are shared with the app through SlateTests/Fixtures/inquiry_rules.json. What the app decodes (inquiry_rows.json)
is checked against what the database really returns; run with --dump to rewrite it after changing a shape.
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
FIXTURE = HERE.parents[1] / "SlateTests" / "Fixtures" / "inquiry_rules.json"
ROWS = HERE.parents[1] / "SlateTests" / "Fixtures" / "inquiry_rows.json"
DB = "slate_inquiries"
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
# These checks are about conversations, not about paying for seats (billing_rules.py is).
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


def table(uid, fn, *args):
    """A function that returns rows, as the rows (dicts)."""
    c, k = as_user(uid)
    try:
        k.execute(f"select to_jsonb(t) from {fn}({', '.join(['%s'] * len(args))}) t", args)
        return [r[0] for r in k.fetchall()]
    except psycopg2.Error as e:
        return first_line(e)
    finally:
        c.close()


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


def join(org, inviter, role, uid, name=None):
    inv = rpc(inviter, "invite_create", org, role, None)
    return inv if isinstance(inv, str) else rpc(uid, "accept_invite", inv["token"], name)


days = [2]


def raw_booking(creator, client, assigned="creator"):
    """A booking as the database owner, with the notification triggers off (so its conversation starts empty)."""
    days[0] += 1
    a.execute("alter table bookings disable trigger user")
    try:
        a.execute(
            """insert into bookings (creator_id, client_id, creator_name, client_name, package_name, start_at, end_at, blocked_until,
                                     time_zone, currency_code, total_cents, deposit_cents, status, assigned_to)
               values (%s, %s, 'Test Creator', 'Sam Client', 'Wedding',
                       now() + make_interval(days => %s), now() + make_interval(days => %s) + interval '4 hours',
                       now() + make_interval(days => %s) + interval '4 hours', 'America/Chicago', 'USD', 120000, 30000, 'confirmed', %s)
               returning id""",
            (creator, client, days[0], days[0], days[0], creator if assigned == "creator" else assigned))
        return a.fetchone()[0]
    finally:
        a.execute("alter table bookings enable trigger user")


def send(uid, conv, body, client_id=None):
    """The stored message as a dict, or the error."""
    res = sql_as(uid, "select to_jsonb(send_message(%s, %s, %s))", (conv, body, client_id))
    return res if isinstance(res, str) else res[0][0][0]


def texts(uid, conv):
    got = table(uid, "list_messages", conv)
    return got if isinstance(got, str) else [m["body"] for m in got]


def convs(uid):
    got = table(uid, "list_conversations")
    return got if isinstance(got, str) else got


def conv_of(uid, conv):
    got = convs(uid)
    return None if isinstance(got, str) else next((c for c in got if c["booking_id"] == conv), None)


def unread(uid):
    return one("select unread_message_count(%s)", (uid,))


def pushes(user, kind="message", conv=None):
    if conv:
        return one("select count(*) from push_outbox where user_id = %s and kind = %s and data ->> 'bookingId' = %s", (user, kind, conv))
    return one("select count(*) from push_outbox where user_id = %s and kind = %s", (user, kind))


# =============================================================================
print("\n[the numbers the app shares]")
check("new conversations a client may start in a day", one("select app_inquiries_per_day()") == rules["inquiriesPerDay"])
check("messages in a row without an answer", one("select app_inquiry_unanswered_limit()") == rules["unansweredLimit"])
check("the longest message is the same as bookings'", one("select app_message_max_length()") == rules["maxMessageLength"])

# =============================================================================
print("\n[setting up people]")
carol = new_user("carol-c", "Carol Chen")
olivia = new_user("olivia-ng", "Olivia Ng")
dee, mia, cal, vee = new_user(), new_user(), new_user(), new_user()
alice, bea, stranger = new_user(), new_user(), new_user()
ORG = rpc(olivia, "org_create", "acme-films", "Acme Films", "Acme Films LLC", "1 Main St", "", ["weddings"], "Austin, TX")["organization_id"]
join(ORG, olivia, "admin", dee, "Dee Okafor")
join(ORG, olivia, "manager", mia, "Mia K")
join(ORG, olivia, "creator", cal, "Cal R")
join(ORG, olivia, "viewer", vee, "Vee T")
check("the company has five people", one("select count(*) from memberships where organization_id = %s and removed_at is null", (ORG,)) == 5)

# =============================================================================
print("\n[starting a conversation]")
check("you must be signed in", err(rpc(None, "start_inquiry", carol, "Nobody"), "not_signed_in"))
check("a creator that isn't there is not found", err(rpc(alice, "start_inquiry", str(uuid.uuid4()), "Alice"), "not_found"))
check("a person that isn't a creator is not found", err(rpc(alice, "start_inquiry", bea, "Alice"), "not_found"))
check("a creator can't message themselves", err(rpc(carol, "start_inquiry", carol, "Carol"), "cannot_message_yourself"))
for who, role in ((olivia, "owner"), (dee, "admin"), (mia, "manager"), (cal, "creator"), (vee, "viewer")):
    check(f"a company's {role} can't message their own company", err(rpc(who, "start_inquiry", ORG, "Me"), "cannot_message_yourself"))
check("the API never lets anyone make one directly",
      isinstance(sql_as(alice, "insert into inquiries (client_id, creator_id, creator_name) values (%s, %s, 'x')", (alice, carol)), str))
check("or a message straight into the table",
      isinstance(sql_as(alice, "insert into messages (inquiry_id, sender_id, kind, body) values (null, %s, 'text', 'hi')", (alice,)), str))

inq = rpc(alice, "start_inquiry", carol, "  Alice A  ")
check("starting returns the conversation's id", isinstance(inq, str) and len(inq) == 36, inq)
check("the name is kept trimmed, and the creator's as it was", one("select client_name || '|' || creator_name from inquiries where id = %s", (inq,)) == "Alice A|Carol Chen")
check("starting again returns the same one", rpc(alice, "start_inquiry", carol, "Alice A") == inq)
check("a new name replaces the old", (rpc(alice, "start_inquiry", carol, "Alice Adams") == inq) and one("select client_name from inquiries where id = %s", (inq,)) == "Alice Adams")
check("an empty name keeps the old one", (rpc(alice, "start_inquiry", carol, "") == inq) and one("select client_name from inquiries where id = %s", (inq,)) == "Alice Adams")
check("a name is cut to 80 characters", one("select char_length(client_name) from inquiries where id = %s", (rpc(bea, "start_inquiry", carol, "B" * 200),)) == 80)
check("each client gets their own", rpc(bea, "start_inquiry", carol, "Bea") != inq)
check("until a message is sent, nobody's list shows it", convs(alice) == [] and convs(carol) == [])
check("and nothing is unread", unread(carol) == 0 and unread(alice) == 0)
check("a stranger can't see the inquiry row", sql_as(stranger, "select count(*) from inquiries")[0][0][0] == 0)
check("the client can", sql_as(alice, "select count(*) from inquiries")[0][0][0] == 1)
check("so can the creator (both clients')", sql_as(carol, "select count(*) from inquiries")[0][0][0] == 2)

# =============================================================================
print("\n[how many a client may start in a day]")
spree = new_user()
targets = [new_user(f"spree-{i}", f"Spree {i}") for i in range(rules["inquiriesPerDay"] + 1)]
first_ids = [rpc(spree, "start_inquiry", t, "Spree") for t in targets[: rules["inquiriesPerDay"]]]
check(f"{rules['inquiriesPerDay']} in a day are fine", all(isinstance(i, str) and not i.startswith("ERR") for i in first_ids), first_ids)
check("one more is refused", err(rpc(spree, "start_inquiry", targets[-1], "Spree"), "too_many_inquiries"))
check("going back to one already started is still fine", rpc(spree, "start_inquiry", targets[0], "Spree") == first_ids[0])
a.execute("update inquiries set created_at = now() - interval '25 hours' where id = %s", (first_ids[0],))
later = rpc(spree, "start_inquiry", targets[-1], "Spree")
check("a day later there is room again", isinstance(later, str) and len(later) == 36, later)
check("someone else is not held back by it", isinstance(rpc(stranger, "start_inquiry", targets[0], "Sam"), str))

# =============================================================================
print("\n[a person's inquiry: writing, reading, reading receipts]")
m1 = send(alice, inq, "Are you free on the 14th?", str(uuid.uuid4()))
check("the first message is stored on the inquiry", isinstance(m1, dict) and m1["inquiry_id"] == inq and m1["booking_id"] is None
      and m1["kind"] == "text" and m1["sender_id"] == alice and m1["body"] == "Are you free on the 14th?", m1)
cid = str(uuid.uuid4())
m2 = send(alice, inq, "I need coverage for 6 hours.", cid)
again = send(alice, inq, "I need coverage for 6 hours.", cid)
check("sending again after a dropped connection returns the same message", isinstance(again, dict) and again["id"] == m2["id"])
check("and stores it once", one("select count(*) from messages where inquiry_id = %s", (inq,)) == 2)
check("the creator sees both, oldest first", texts(carol, inq) == ["Are you free on the 14th?", "I need coverage for 6 hours."], texts(carol, inq))
check("so does the client", texts(alice, inq) == texts(carol, inq))
check("another client of the same creator sees nothing", texts(bea, inq) == [])
check("a stranger sees nothing", texts(stranger, inq) == [])
check("nobody signed in sees nothing", texts(None, inq) == [])
check("a stranger can't read the table either", sql_as(stranger, "select count(*) from messages where inquiry_id = %s", (inq,))[0][0][0] == 0)
check("a stranger can't write to it", err(send(stranger, inq, "hello?"), "not_found"))
check("another client can't either", err(send(bea, inq, "hello?"), "not_found"))
check("nor can a stranger mark it read", err(rpc(stranger, "mark_conversation_read", inq), "not_found"))

row = conv_of(carol, inq)
check("the creator's list has it as an inquiry, from the client", row is not None and row["is_inquiry"] is True and row["i_am_client"] is False
      and row["counterpart_name"] == "Alice Adams" and row["creator_id"] == carol and row["last_body"] == "I need coverage for 6 hours."
      and row["last_kind"] == "text" and row["last_event"] is None, row)
check("with two unread", row["unread_count"] == 2, row)
row = conv_of(alice, inq)
check("the client's list names the creator and counts nothing unread", row is not None and row["counterpart_name"] == "Carol Chen"
      and row["i_am_client"] is True and row["unread_count"] == 0, row)
check("a stranger's list is empty", convs(stranger) == [] and convs(bea) == [])
check("the creator has two unread across everything", unread(carol) == 2 and unread(alice) == 0)

rpc(carol, "mark_conversation_read", inq)
check("reading clears them", conv_of(carol, inq)["unread_count"] == 0 and unread(carol) == 0)
r1 = send(carol, inq, "Yes, the 14th is open.")
check("the creator's reply is stored", isinstance(r1, dict) and r1["inquiry_id"] == inq and r1["sender_id"] == carol)
check("and is unread for the client only", conv_of(alice, inq)["unread_count"] == 1 and conv_of(carol, inq)["unread_count"] == 0 and unread(alice) == 1)
check("writing back counts as having read what came before", rpc(alice, "mark_conversation_read", inq) is None and unread(alice) == 0)
check("the list is newest first across conversations", [c["booking_id"] for c in convs(carol)][0] == inq)

print("\n[what a message may say]")
check("empty is refused", err(send(alice, inq, "   \n  "), "invalid_message"))
check("too long is refused", err(send(alice, inq, "x" * (rules["maxMessageLength"] + 1)), "message_too_long"))
check("exactly the longest is fine", isinstance(send(alice, inq, "y" * rules["maxMessageLength"]), dict))
check("control characters are cleaned the same way", send(alice, inq, "  hi\u0007 there \r\n")["body"] == "hi there")

# =============================================================================
print("\n[a client can't write forever without an answer]")
pat = new_user()
pinq = rpc(pat, "start_inquiry", carol, "Pat")
sent = [send(pat, pinq, f"message {i}") for i in range(rules["unansweredLimit"])]
check(f"{rules['unansweredLimit']} unanswered messages are fine", all(isinstance(s, dict) for s in sent), sent)
check("the next is held back until there's an answer", err(send(pat, pinq, "hello??"), "awaiting_reply"))
cid_dup = str(uuid.uuid4())
pat2 = new_user()
pinq2 = rpc(pat2, "start_inquiry", carol, "Pat Two")
for i in range(rules["unansweredLimit"] - 1):
    send(pat2, pinq2, f"m{i}")
last_ok = send(pat2, pinq2, "the last allowed", cid_dup)
check("the last allowed one goes through", isinstance(last_ok, dict))
check("sending it again (a dropped connection) returns it rather than failing",
      isinstance(send(pat2, pinq2, "the last allowed", cid_dup), dict) and send(pat2, pinq2, "the last allowed", cid_dup)["id"] == last_ok["id"])
check("the creator is never held back", all(isinstance(send(carol, pinq, f"reply {i}"), dict) for i in range(1, 4)))
check("after a reply the client can write again", isinstance(send(pat, pinq, "thanks!"), dict))

# =============================================================================
print("\n[the creator can't be rushed past the per-minute limit]")
fast = new_user("fast-f", "Fast F")
fast_client = new_user()
finq = rpc(fast_client, "start_inquiry", fast, "Fan")
send(fast_client, finq, "hi")
sent = [send(fast, finq, f"reply {i}") for i in range(20)]
check("20 in a minute are fine", all(isinstance(s, dict) for s in sent), [s for s in sent if not isinstance(s, dict)])
check("the 21st is refused", err(send(fast, finq, "one more"), "rate_limited"))

# =============================================================================
print("\n[who is told]")
check("the creator was told of each of the client's messages, once", pushes(carol, "message", inq) == 4, pushes(carol, "message", inq))
p = one("select to_jsonb(p) from push_outbox p where p.user_id = %s and p.data ->> 'bookingId' = %s order by created_at limit 1", (carol, inq))
check("the notice opens the inquiry (its id travels as bookingId; there is no booking)", p["booking_id"] is None and p["data"]["role"] == "creator"
      and p["data"]["senderName"] == "Alice Adams" and p["data"]["preview"] == "Are you free on the 14th?", p)
p = one("select to_jsonb(p) from push_outbox p where p.user_id = %s and p.data ->> 'bookingId' = %s order by created_at limit 1", (alice, inq))
check("the client is told of the reply, in the creator's name", p["booking_id"] is None and p["data"]["role"] == "client"
      and p["data"]["senderName"] == "Carol Chen" and p["data"]["preview"] == "Yes, the 14th is open.", p)
check("nobody is told of their own message", pushes(alice, "message", inq) == 1)
a.execute("insert into notification_preferences (user_id, messages) values (%s, false) on conflict (user_id) do update set messages = false", (carol,))
before = pushes(carol)
send(alice, inq, "A message while notifications are off")
check("a person who turned messages off isn't told", pushes(carol) == before)
a.execute("delete from notification_preferences where user_id = %s", (carol,))

# =============================================================================
print("\n[a company's inquiries]")
cinq = rpc(alice, "start_inquiry", ORG, "Alice Adams")
cm = send(alice, cinq, "Do you do corporate events?")
check("a client can write to a company", isinstance(cm, dict) and cm["inquiry_id"] == cinq)
check("the company's name is what the client sees", conv_of(alice, cinq)["counterpart_name"] == "Acme Films" and conv_of(alice, cinq)["creator_id"] == ORG)
for who, name, sees, answers in ((olivia, "Owner", True, True), (dee, "Admin", True, True), (mia, "Manager", True, True),
                                 (vee, "Viewer", True, False), (cal, "Creator", False, False), (stranger, "stranger", False, False)):
    got = texts(who, cinq)
    check(f"the {name} {'can' if sees else 'can not'} read it", (len(got) > 0 and got[0] == "Do you do corporate events?") if sees else got == [], got)
    check(f"the {name} {'has' if sees else 'does not have'} it in their list", (conv_of(who, cinq) is not None) == sees)
    check(f"the {name} {'is' if sees else 'is not'} counted as having it unread", (unread(who) >= 1) == sees, unread(who))
    got = rpc(who, "mark_conversation_read", cinq)
    check(f"the {name} {'can' if sees else 'can not'} mark it read", (got is None) if sees else err(got, "not_found"), got)
    got = send(who, cinq, f"{name} here")
    check(f"the {name} {'can' if answers else 'can not'} answer", isinstance(got, dict) if answers else err(got, "not_found"), got)
for who, name, told in ((olivia, "Owner", True), (dee, "Admin", True), (mia, "Manager", True), (vee, "Viewer", False), (cal, "Creator", False)):
    check(f"the {name} {'was' if told else 'was not'} told of the client's message", (pushes(who, "message", cinq) == 1) == told, pushes(who, "message", cinq))
check("the client is told of the answers in the company's name", one(
    "select count(*) from push_outbox where user_id = %s and data ->> 'bookingId' = %s and data ->> 'senderName' = 'Acme Films'", (alice, cinq)) == 3)
check("a read by one member doesn't clear it for another",
      (rpc(olivia, "mark_conversation_read", cinq) is None) and conv_of(vee, cinq) is not None)
vee_before = conv_of(vee, cinq)["unread_count"]
send(alice, cinq, "Thanks, one more question.")
check("a new message is unread for everyone who can see it again", conv_of(vee, cinq)["unread_count"] == vee_before + 1 and conv_of(olivia, cinq)["unread_count"] >= 1)
a.execute("update memberships set removed_at = now() where organization_id = %s and user_id = %s", (ORG, mia))
check("a member who is removed loses it", texts(mia, cinq) == [] and err(send(mia, cinq, "still here?"), "not_found"))
check("and the unread count for it", unread(mia) == 0)
a.execute("update memberships set removed_at = null where organization_id = %s and user_id = %s", (ORG, mia))

# =============================================================================
print("\n[bookings are untouched]")
b = raw_booking(carol, alice)
check("a booking conversation still takes messages from both sides", isinstance(send(alice, b, "About the booking"), dict) and isinstance(send(carol, b, "Got it"), dict))
bm = one("select to_jsonb(m) from messages m where booking_id = %s order by created_at limit 1", (b,))
check("booking messages have no inquiry", bm["inquiry_id"] is None and bm["booking_id"] == b)
check("a stranger still can't write to a booking", err(send(stranger, b, "hi"), "not_found"))
check("or read it", texts(stranger, b) == [])
check("the booking's conversation reads only its own lines", texts(alice, b) == ["About the booking", "Got it"], texts(alice, b))
check("the booking is in the list as a booking, with the counterpart named",
      (conv_of(alice, b) or {}).get("is_inquiry") is False and conv_of(alice, b)["counterpart_name"] == "Test Creator"
      and conv_of(alice, b)["i_am_client"] is True and conv_of(carol, b)["counterpart_name"] == "Sam Client" and conv_of(carol, b)["i_am_client"] is False)
check("the inquiry and the booking are two rows", len([c for c in convs(alice) if c["creator_id"] == carol]) == 2)
check("and are told apart", {c["booking_id"]: c["is_inquiry"] for c in convs(alice) if c["creator_id"] == carol} == {inq: True, b: False})
before = unread(alice)
send(carol, b, "A second line")
send(carol, inq, "A second line on the inquiry")
check("unread counts add up across both kinds", unread(alice) == before + 2, (before, unread(alice)))
rpc(alice, "mark_conversation_read", b)
check("reading one doesn't read the other", conv_of(alice, b)["unread_count"] == 0 and conv_of(alice, inq)["unread_count"] == 1)
check("the booking id doesn't read an inquiry's messages", texts(alice, b) == ["About the booking", "Got it", "A second line"])
check("an id that is neither is not found", err(send(alice, str(uuid.uuid4()), "hi"), "not_found") and err(rpc(alice, "mark_conversation_read", str(uuid.uuid4())), "not_found"))

# =============================================================================
print("\n[a company booking nobody is assigned to yet]")
ub = raw_booking(ORG, alice, assigned=None)
check("the people who can assign it can write to the client", isinstance(send(olivia, ub, "We'll find you someone"), dict) and isinstance(send(mia, ub, "On it"), dict))
check("a member who only works assigned jobs can not (nothing is assigned to them)", err(send(cal, ub, "I'll take it"), "not_found"))
check("a viewer can not", err(send(vee, ub, "hello"), "not_found"))
check("the client can", isinstance(send(alice, ub, "Thanks"), dict))
check("the Creator can't read it either", texts(cal, ub) == [] and conv_of(cal, ub) is None)
check("the Viewer can read it", texts(vee, ub) == ["We'll find you someone", "On it", "Thanks"])

# =============================================================================
print("\n[the table's own rules]")
try:
    a.execute("insert into messages (kind, body, sender_id) values ('text', 'orphan', %s)", (alice,))
    check("a message with no conversation is refused", False)
except psycopg2.Error:
    check("a message with no conversation is refused", True)
try:
    a.execute("insert into messages (booking_id, inquiry_id, kind, body, sender_id) values (%s, %s, 'text', 'both', %s)", (b, inq, alice))
    check("a message in two conversations is refused", False)
except psycopg2.Error:
    check("a message in two conversations is refused", True)
try:
    a.execute("insert into messages (inquiry_id, kind, event, data) values (%s, 'system', 'booked', '{}')", (inq,))
    check("an inquiry takes only typed text, not booking events", False)
except psycopg2.Error:
    check("an inquiry takes only typed text, not booking events", True)

# =============================================================================
print("\n[deleting an account]")
zed = new_user()
zinq = rpc(zed, "start_inquiry", carol, "Zed")
send(zed, zinq, "Hello")
a.execute("delete from auth.users where id = %s", (zed,))
check("a deleted client's inquiry and messages go with them", one("select count(*) from inquiries where id = %s", (zinq,)) == 0
      and one("select count(*) from messages where inquiry_id = %s", (zinq,)) == 0 and one("select count(*) from inquiry_reads where inquiry_id = %s", (zinq,)) == 0)
check("the creator's other conversations are untouched", conv_of(carol, inq) is not None)
gone = new_user("gone-g", "Gone G")
ginq = rpc(alice, "start_inquiry", gone, "Alice")
send(alice, ginq, "Hi")
a.execute("delete from auth.users where id = %s", (gone,))
check("a deleted creator's inquiries go with them", one("select count(*) from inquiries where id = %s", (ginq,)) == 0)
check("the client's list no longer shows it", conv_of(alice, ginq) is None)

# =============================================================================
print("\n[what the app decodes is what the database returns]")
alice_list = table(alice, "list_conversations")
inq_row = next(c for c in alice_list if c["booking_id"] == inq)
book_row = next(c for c in alice_list if c["booking_id"] == b)
actual = {
    "conversationInquiry": inq_row,
    "conversationBooking": book_row,
    "message": send(alice, inq, "Shape check", str(uuid.uuid4())),
    "messages": table(alice, "list_messages", inq),
}
actual["messageOfBooking"] = table(alice, "list_messages", b)[0]


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
