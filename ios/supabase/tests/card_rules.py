"""Applies the migrations to a throwaway Postgres and tries to break cards on file: what the app can read of a card
(never Stripe's reference), who may allow a creator and with what, who may charge a saved card and for how much (the
balance, once it is payable, nothing else), what stopping access and removing a card do, and that money is still
recorded only the way Stripe's webhook records it.

Needs a Postgres server (16 recommended) and psycopg2, like the other scripts here:

    PGPORT=5432 python3 ios/supabase/tests/card_rules.py

The expiry rule and the limits are shared with the app through SlateTests/Fixtures/card_rules.json.
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
FIXTURE = HERE.parents[1] / "SlateTests" / "Fixtures" / "card_rules.json"
DB = "slate_cards"
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
# These checks are about cards, not about paying for seats (billing_rules.py is).
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


def table(uid, fn, *args, role="authenticated"):
    res = sql_as(uid, f"select * from {fn}({', '.join(['%s'] * len(args))})", args, role)
    return res if isinstance(res, str) else res[0]


def svc(fn, *args):
    """Call a function the way an Edge Function does, with the service role."""
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


def connect_account(owner, charges=True):
    a.execute(
        "insert into creator_payment_accounts (creator_id, stripe_account_id, charges_enabled, payouts_enabled, details_submitted)"
        " values (%s, %s, %s, %s, %s)", (owner, "acct_" + owner[:8], charges, charges, charges))


days = [2]


def raw_booking(creator, client, assigned=None, total=120000, deposit=30000, status="confirmed", received=True, deposit_paid=True):
    """A booking as the database owner, with the notification triggers off (a past shoot, the way set-up needs it)."""
    days[0] += 1
    a.execute("alter table bookings disable trigger user")
    try:
        a.execute(
            """insert into bookings (creator_id, client_id, creator_name, package_name, start_at, end_at, blocked_until, time_zone,
                                     currency_code, total_cents, deposit_cents, status, assigned_to, delivered_at, receipt_confirmed_at)
               values (%s, %s, 'Test Creator', 'Wedding', now() - make_interval(days => %s),
                       now() - make_interval(days => %s) + interval '4 hours', now() - make_interval(days => %s) + interval '4 hours',
                       'America/Chicago', 'USD', %s, %s, %s, %s,
                       case when %s then now() - interval '1 day' end, case when %s then now() - interval '1 hour' end)
               returning id""",
            (creator, client, days[0], days[0], days[0], total, deposit, status, assigned or creator, received, received))
        bid = a.fetchone()[0]
    finally:
        a.execute("alter table bookings enable trigger user")
    if deposit_paid and deposit > 0:
        a.execute(
            "insert into payments (booking_id, kind, amount_cents, currency_code, status, method, stripe_payment_intent_id, paid_at)"
            " values (%s, 'deposit', %s, 'USD', 'succeeded', 'apple_pay', %s, now())", (bid, deposit, "pi_dep_" + uuid.uuid4().hex[:10]))
    return bid


def save_card(user, brand="visa", last4="4242", month=8, year=2099, pm=None):
    """What the webhook does when Stripe says a card was saved. Returns the card's id."""
    customer = svc("card_customer_for", user)
    if not customer:
        customer = "cus_" + uuid.uuid4().hex[:12]
        svc("card_customer_save", user, customer)
    return svc("card_record", customer, pm or "pm_" + uuid.uuid4().hex[:14], brand, last4, month, year)


def log_of(client):
    a.execute("select action, card_brand, card_last4, creator_id::text from card_grant_log where client_id = %s order by id", (client,))
    return a.fetchall()


# =============================================================================
print("\n[the rules the app shares]")
check("five cards at most", one("select app_card_limit()") == rules["maxCards"], one("select app_card_limit()"))
check("the agreement wording has a version", one("select card_consent_version()") == rules["consentVersion"])
for case in rules["expiry"]:
    got = one("select card_is_expired(%s, %s, %s::timestamptz)", (case["month"], case["year"], case["at"]))
    check(f"{case['month']}/{case['year']} at {case['at']}: {'expired' if case['expired'] else 'still good'}", got == case["expired"], got)

# =============================================================================
print("\n[setting up people and bookings]")
olivia = new_user("olivia-ng", "Olivia Ng")
add_signature(olivia, "Olivia Ng")
dee, mia, cal, kim, vee = new_user(), new_user("mia-k", "Mia K"), new_user("cal-r", "Cal R"), new_user("kim-t", "Kim T"), new_user("vee-t", "Vee T")
carol = new_user("carol-c", "Carol Chen")
stranger = new_user("sam-s", "Sam S")
alice, bea = new_user(), new_user()
ORG = rpc(olivia, "org_create", "acme-films", "Acme Films", "Acme Films LLC", "1 Main St", "", ["weddings"], "Austin, TX")["organization_id"]
join(ORG, olivia, "admin", dee, "Dee Okafor")
join(ORG, olivia, "manager", mia)
join(ORG, olivia, "creator", cal)
join(ORG, olivia, "creator", kim)
join(ORG, olivia, "viewer", vee)
connect_account(carol)
connect_account(ORG)
check("the company is set up", one("select count(*) from memberships where organization_id = %s and removed_at is null", (ORG,)) == 6,
      one("select string_agg(role, ',') from memberships where organization_id = %s and removed_at is null", (ORG,)))

b_carol = raw_booking(carol, alice)
b_carol_bea = raw_booking(carol, bea)
b_acme = raw_booking(ORG, alice, assigned=cal)
check("a shoot to be paid for", one("select receipt_confirmed_at is not null from bookings where id = %s", (b_carol,)))

# =============================================================================
print("\n[keeping a card at Stripe: what the server records]")
check("a new person has no customer yet", svc("card_prepare", alice)["customer_id"] is None)
svc("card_customer_save", alice, "cus_alice")
svc("card_customer_save", alice, "cus_other")
check("the first customer stays", svc("card_customer_for", alice) == "cus_alice")
check("two people can't share a customer", isinstance(sql_as(None, "select card_customer_save(%s, 'cus_alice')", (bea,), role="service_role"), str))
svc("card_customer_save", bea, "cus_bea")
check("a card for an unknown customer is refused", err(svc("card_record", "cus_nobody", "pm_x", "visa", "4242", 8, 2099), "unknown_customer"))

visa = svc("card_record", "cus_alice", "pm_alice_visa", "Visa", "4242", 8, 2099)
check("a card is recorded", visa is not None and one("select count(*) from client_cards where user_id = %s", (alice,)) == 1)
check("the brand is kept in lower case", one("select brand from client_cards where id = %s", (visa,)) == "visa")
again = svc("card_record", "cus_alice", "pm_alice_visa", "visa", "4242", 9, 2100)
check("telling it again changes the card, not the count", again == visa and one("select count(*) from client_cards where user_id = %s", (alice,)) == 1
      and one("select exp_year from client_cards where id = %s", (visa,)) == 2100)
svc("card_record", "cus_alice", "pm_alice_visa", "visa", "4242", 8, 2099)
check("another person can't take over someone's card",
      svc("card_record", "cus_bea", "pm_alice_visa", "mastercard", "9999", 1, 2099) is None
      and one("select user_id::text from client_cards where stripe_payment_method_id = 'pm_alice_visa'") == alice
      and one("select last4 from client_cards where id = %s", (visa,)) == "4242")
check("a card number is four digits and nothing else", isinstance(sql_as(None, "select card_record('cus_alice','pm_bad','visa','42ab',8,2099)", role="service_role"), str))
check("a month is 1 to 12", isinstance(sql_as(None, "select card_record('cus_alice','pm_bad','visa','4242',13,2099)", role="service_role"), str))
check("a brand is a word", isinstance(sql_as(None, "select card_record('cus_alice','pm_bad','vi sa;','4242',8,2099)", role="service_role"), str))

print("\n[what the app can see of a card]")
mine = sql_as(alice, "select id, brand, last4, exp_month, exp_year from client_cards order by created_at")
check("a person sees their own card: brand, last four, expiry", not isinstance(mine, str) and mine[0] == [(visa, "visa", "4242", 8, 2099)], mine)
check("nobody else's", sql_as(bea, "select id from client_cards")[0] == [])
check("not Stripe's reference", err(sql_as(alice, "select stripe_payment_method_id from client_cards"), "permission denied"))
check("not by asking for every column", err(sql_as(alice, "select * from client_cards"), "permission denied"))
check("the app can't add a card", err(sql_as(alice, "insert into client_cards (user_id, stripe_payment_method_id, brand, last4, exp_month, exp_year) values (%s,'pm_x','visa','1111',1,2099)", (alice,)), "permission denied"))
check("or change one", err(sql_as(alice, "update client_cards set exp_year = 2150 where id = %s", (visa,)), "permission denied"))
check("or delete one", err(sql_as(alice, "delete from client_cards where id = %s", (visa,)), "permission denied"))
check("someone who isn't signed in sees nothing", err(sql_as(None, "select id from client_cards", role="anon"), "permission denied"))
check("the customer list is closed to the app", err(sql_as(alice, "select * from client_stripe_customers"), "permission denied"))
for fn, args in [("card_record", "('cus_alice','pm_z','visa','1111',1,2099)"), ("card_prepare", f"('{alice}')"), ("card_lookup", f"('{alice}','{visa}')"),
                 ("card_forget", f"('{alice}','{visa}')"), ("card_prune", f"('{alice}','{{}}')"), ("card_customer_for", f"('{alice}')"),
                 ("payment_prepare_saved", f"('{carol}','{b_carol}',0)")]:
    check(f"{fn} is for the server only", err(sql_as(alice, f"select {fn}{args}"), "permission denied") and err(sql_as(None, f"select {fn}{args}", role="anon"), "permission denied"))

print("\n[the limit]")
for n in range(rules["maxCards"] - 2):
    save_card(alice, last4=f"11{n:02d}")
check("with room, setting up is fine", svc("card_prepare", alice)["card_count"] == rules["maxCards"] - 1)
save_card(alice, last4="9999")
check("at the limit, setting up is refused", err(svc("card_prepare", alice), "too_many_cards"))
check("but nobody else is held back", svc("card_prepare", bea)["card_count"] == 0)
a.execute("delete from client_cards where user_id = %s and id <> %s", (alice, visa))
check("room again once cards are gone", svc("card_prepare", alice)["card_count"] == 1)

# =============================================================================
print("\n[allowing a creator]")
check("you have to be signed in", err(sql_as(None, "select card_grant(%s,%s,%s)", (carol, visa, 1)), "not_signed_in"))
check("someone who isn't signed in at all is turned away", err(sql_as(None, "select card_grant(%s,%s,%s)", (carol, visa, 1), role="anon"), "permission denied"))
check("only with the wording the app showed", err(rpc(alice, "card_grant", carol, visa, 0), "consent_outdated")
      and err(rpc(alice, "card_grant", carol, visa, rules["consentVersion"] + 1), "consent_outdated"))
check("a creator the person hasn't booked can't be allowed", err(rpc(alice, "card_grant", stranger, visa, 1), "no_booking_with_creator"))
bea_card = save_card(bea, brand="mastercard", last4="5454")
check("only your own card", err(rpc(alice, "card_grant", carol, bea_card, 1), "card_not_found"))
check("a card that doesn't exist", err(rpc(alice, "card_grant", carol, str(uuid.uuid4()), 1), "card_not_found"))
old = save_card(alice, brand="amex", last4="0005", month=1, year=2020)
check("an expired card can't be used", err(rpc(alice, "card_grant", carol, old, 1), "card_expired"))
a.execute("delete from client_cards where id = %s", (old,))

cancelled_only = raw_booking(stranger, alice, status="cancelled", received=False, deposit_paid=False)
check("a cancelled booking doesn't count", err(rpc(alice, "card_grant", stranger, visa, 1), "no_booking_with_creator"))

grant = rpc(alice, "card_grant", carol, visa, 1)
check("a client who has booked a creator can allow them", isinstance(grant, str) and not grant.startswith("ERR"), grant)
check("it is recorded", one("select count(*) from card_grants where client_id = %s and creator_id = %s", (alice, carol)) == 1)
mastercard = save_card(alice, brand="mastercard", last4="4444")
rpc(alice, "card_grant", carol, mastercard, 1)
check("allowing again replaces the card; there is still one permission",
      one("select count(*) from card_grants where client_id = %s and creator_id = %s", (alice, carol)) == 1
      and one("select card_id::text from card_grants where client_id = %s and creator_id = %s", (alice, carol)) == mastercard)
check("both times are in the record", [r[0] for r in log_of(alice)] == ["allowed", "allowed"] and [r[2] for r in log_of(alice)] == ["4242", "4444"], log_of(alice))
rpc(alice, "card_grant", carol, visa, 1)

listed = table(alice, "my_card_grants")
check("the client sees who they have allowed, with the card", not isinstance(listed, str) and len(listed) == 1
      and listed[0][0] == carol and listed[0][1] == "Carol Chen" and listed[0][2] == "carol-c" and listed[0][5] == "visa" and listed[0][6] == "4242", listed)
check("nobody else sees it", table(bea, "my_card_grants") == [] and table(carol, "my_card_grants") == [])
check("the table itself is theirs alone", sql_as(carol, "select count(*) from card_grants")[0][0][0] == 0
      and sql_as(alice, "select count(*) from card_grants")[0][0][0] == 1)
check("the creator can't write to it", err(sql_as(carol, "insert into card_grants (client_id, creator_id, card_id, consent_version) values (%s,%s,%s,1)", (alice, carol, visa)), "permission denied"))
check("or edit it", err(sql_as(alice, "update card_grants set creator_id = %s", (stranger,)), "permission denied"))
check("the record is theirs to read, and only theirs",
      len(sql_as(alice, "select * from card_grant_log")[0]) == 3 and sql_as(carol, "select * from card_grant_log")[0] == [])
check("and nobody can rewrite it", err(sql_as(alice, "delete from card_grant_log"), "permission denied") and err(sql_as(alice, "update card_grant_log set action = 'stopped'"), "permission denied"))

# A company is allowed the same way: the permission is for the owner of the booking.
rpc(alice, "card_grant", ORG, visa, 1)
check("a company can be allowed too", one("select count(*) from card_grants where client_id = %s and creator_id = %s", (alice, ORG)) == 1)

# =============================================================================
print("\n[who may know what about a booking's permission]")
as_client = rpc(alice, "card_access_for_booking", b_carol)
check("the client sees the card they chose", as_client == {"allowed": True, "brand": "visa", "last4": "4242", "expired": False}, as_client)
as_creator = rpc(carol, "card_access_for_booking", b_carol)
check("the creator sees that a card is allowed, and its brand", as_creator["allowed"] is True and as_creator["brand"] == "visa" and as_creator["expired"] is False, as_creator)
check("but not its last four, and nothing from Stripe", as_creator["last4"] is None and "pm_" not in json.dumps(as_creator), as_creator)
check("a booking with no permission says so", rpc(carol, "card_access_for_booking", b_carol_bea) == {"allowed": False, "brand": None, "last4": None, "expired": False})
check("strangers can't ask", err(rpc(stranger, "card_access_for_booking", b_carol), "not_found") and err(rpc(bea, "card_access_for_booking", b_carol), "not_found"))
check("a booking that isn't there", err(rpc(alice, "card_access_for_booking", str(uuid.uuid4())), "not_found"))
check("you have to be signed in", err(sql_as(None, "select card_access_for_booking(%s)", (b_carol,)), "not_signed_in"))
check("someone on the company's side who can only look sees it, without the last four",
      rpc(vee, "card_access_for_booking", b_acme)["allowed"] is True and rpc(vee, "card_access_for_booking", b_acme)["last4"] is None)
check("a member with no share in the booking doesn't", err(rpc(kim, "card_access_for_booking", b_acme), "not_found") or rpc(kim, "card_access_for_booking", b_acme)["allowed"] is True)

# =============================================================================
print("\n[charging the balance]")
prep = svc("payment_prepare_saved", carol, b_carol, 0)
check("the creator can start a charge", isinstance(prep, dict), prep)
check("it is the balance, worked out by the database: total less deposit", prep["amount_cents"] == 90000 and prep["kind"] == "balance", prep)
check("it carries the card and customer to charge, and where the money goes",
      prep["customer"] == "cus_alice" and prep["payment_method"] == "pm_alice_visa" and prep["destination"] == "acct_" + carol[:8], prep)
check("it is marked a card payment from the start", one("select method from payments where id = %s", (prep["payment_id"],)) == "card")
check("it is a pending balance on that booking", one("select status::text || kind::text from payments where id = %s", (prep["payment_id"],)) == "pendingbalance")
check("asking again reuses the same payment", svc("payment_prepare_saved", carol, b_carol, 0)["payment_id"] == prep["payment_id"])
b_fee = raw_booking(carol, alice)
check("the platform fee is the database's too: a share of the balance, rounded down", svc("payment_prepare_saved", carol, b_fee, 250)["fee_cents"] == 2250)
check("nothing in this call can name an amount", "amount" not in one("select pg_get_function_arguments('payment_prepare_saved(uuid,uuid,integer)'::regprocedure)"))

print("\n[who may charge]")
check("a stranger can't", err(svc("payment_prepare_saved", stranger, b_carol, 0), "not_found"))
check("neither can the client", err(svc("payment_prepare_saved", alice, b_carol, 0), "not_found"))
check("a booking that isn't there", err(svc("payment_prepare_saved", carol, str(uuid.uuid4()), 0), "not_found"))
check("without a permission there is nothing to charge", err(svc("payment_prepare_saved", carol, b_carol_bea, 0), "no_card_access"))
check("the app can't ask for it", err(sql_as(carol, "select payment_prepare_saved(%s,%s,0)", (carol, b_carol)), "permission denied"))
for who, name, ok in [(olivia, "the Owner", True), (dee, "an Admin", True), (mia, "a Manager", True), (cal, "the Creator it is assigned to", True),
                      (kim, "a Creator it isn't assigned to", False), (vee, "a Viewer", False)]:
    got = svc("payment_prepare_saved", who, b_acme, 0)
    check(f"at a company, {name} {'can' if ok else 'can not'}", isinstance(got, dict) if ok else err(got, "not_found"), got)
check("the company's own account receives the money", svc("payment_prepare_saved", olivia, b_acme, 0)["destination"] == "acct_" + ORG[:8])

print("\n[when it is not yet time, or already done]")
b_early = raw_booking(carol, alice, received=False)
check("before the client confirms their files, the balance is not payable", err(svc("payment_prepare_saved", carol, b_early, 0), "balance_not_due"))
b_nobalance = raw_booking(carol, alice, total=30000, deposit=30000)
check("nothing left to pay", err(svc("payment_prepare_saved", carol, b_nobalance, 0), "nothing_due"))
b_nodeposit = raw_booking(carol, alice, deposit_paid=False)
check("the deposit comes first", err(svc("payment_prepare_saved", carol, b_nodeposit, 0), "balance_not_due"))
b_cancelled = raw_booking(carol, alice, status="cancelled", received=False)
check("a cancelled booking is not charged", err(svc("payment_prepare_saved", carol, b_cancelled, 0), "balance_not_due"))
connect_off = new_user("off-o", "Off Line")
b_off = raw_booking(connect_off, alice)
rpc(alice, "card_grant", connect_off, visa, 1)
check("a creator Stripe can't pay yet is refused", err(svc("payment_prepare_saved", connect_off, b_off, 0), "payments_not_ready"))

print("\n[Stripe's webhook is still the only thing that records money]")
intent = "pi_" + uuid.uuid4().hex[:18]
svc("payment_attach_intent", prep["payment_id"], intent)
check("attaching the intent keeps it a card payment", one("select method from payments where id = %s", (prep["payment_id"],)) == "card")
check("an amount other than the balance is refused", err(svc("payment_record_success", intent, 100, "ch_x", "card"), "amount_mismatch"))
check("so far the booking is as it was", one("select status::text from bookings where id = %s", (b_carol,)) == "confirmed"
      and one("select status::text from payments where id = %s", (prep["payment_id"],)) == "pending")
done = svc("payment_record_success", intent, 90000, "ch_" + uuid.uuid4().hex[:10], "card")
check("when Stripe says it went through, the booking is complete", done["action"] == "completed", done)
check("the payment is recorded as a card payment", one("select status::text || method from payments where id = %s", (prep["payment_id"],)) == "succeededcard")
check("the client hears about it", one("select count(*) from push_outbox where booking_id = %s and kind = 'payment_received' and user_id = %s", (b_carol, alice)) == 1)
check("so does the creator", one("select count(*) from push_outbox where booking_id = %s and kind = 'payment_received' and user_id = %s", (b_carol, carol)) == 1)
check("the conversation says so", one("select count(*) from messages where booking_id = %s and event = 'balance_paid'", (b_carol,)) == 1)
check("a second charge is refused: it is paid", err(svc("payment_prepare_saved", carol, b_carol, 0), "already_paid") or err(svc("payment_prepare_saved", carol, b_carol, 0), "balance_not_due"))
check("telling it twice changes nothing", svc("payment_record_success", intent, 90000, "ch_again", "card")["action"] == "noop")

# =============================================================================
print("\n[stopping access]")
b_second = raw_booking(carol, alice)
check("while it is allowed, a new booking can be charged too", isinstance(svc("payment_prepare_saved", carol, b_second, 0), dict))
check("the client stops it", rpc(alice, "card_revoke", carol) is True)
check("it is gone", one("select count(*) from card_grants where client_id = %s and creator_id = %s", (alice, carol)) == 0)
check("the creator can't charge any more", err(svc("payment_prepare_saved", carol, b_second, 0), "no_card_access"))
check("the creator sees nothing allowed", rpc(carol, "card_access_for_booking", b_second)["allowed"] is False)
check("it is in the record", log_of(alice)[-1][0] == "stopped" and log_of(alice)[-1][2] == "4242", log_of(alice)[-1])
check("stopping again is harmless", rpc(alice, "card_revoke", carol) is False)
check("you can only stop your own", rpc(bea, "card_revoke", ORG) is False and one("select count(*) from card_grants where creator_id = %s", (ORG,)) == 1)
check("you have to be signed in to stop one", err(sql_as(None, "select card_revoke(%s)", (carol,)), "not_signed_in"))
rpc(alice, "card_grant", carol, visa, 1)
check("it can be allowed again", isinstance(svc("payment_prepare_saved", carol, b_second, 0), dict))

print("\n[an expired card]")
expiring = save_card(alice, brand="discover", last4="1117", month=8, year=2099)
b_third = raw_booking(carol, alice)
rpc(alice, "card_grant", carol, expiring, 1)
a.execute("update client_cards set exp_month = 1, exp_year = 2020 where id = %s", (expiring,))
check("the creator is told the card has expired", err(svc("payment_prepare_saved", carol, b_third, 0), "card_expired"))
check("and sees it as expired", rpc(carol, "card_access_for_booking", b_third)["expired"] is True)
check("the client sees it too", rpc(alice, "card_access_for_booking", b_third)["expired"] is True)
a.execute("update client_cards set exp_month = 8, exp_year = 2099 where id = %s", (expiring,))

# =============================================================================
print("\n[removing a card]")
check("only your own card can be looked up", err(svc("card_lookup", bea, visa), "card_not_found") and svc("card_lookup", alice, visa) == "pm_alice_visa")
rpc(alice, "card_grant", carol, visa, 1)
before = len(log_of(alice))
svc("card_forget", alice, visa)
check("the card is gone", one("select count(*) from client_cards where id = %s", (visa,)) == 0)
check("and so is every permission that used it", one("select count(*) from card_grants where card_id = %s", (visa,)) == 0
      and one("select count(*) from card_grants where client_id = %s and creator_id = %s", (alice, carol)) == 0)
removed = [r for r in log_of(alice)[before:] if r[0] == "card_removed"]
check("the record says which creators lost it", sorted(r[3] for r in removed) == sorted([carol, ORG, connect_off]) and all(r[1:3] == ("visa", "4242") for r in removed), removed)
check("another person's card is left alone", one("select count(*) from client_cards where id = %s", (bea_card,)) == 1)
check("forgetting a card that is gone does nothing", svc("card_forget", alice, visa) is None)
check("the creator can no longer charge", err(svc("payment_prepare_saved", carol, b_third, 0), "no_card_access"))

print("\n[a card removed on Stripe's side]")
side = save_card(alice, pm="pm_side", last4="2468")
rpc(alice, "card_grant", ORG, side, 1)
svc("card_forget_method", "pm_side")
check("it is forgotten here too, with its permissions", one("select count(*) from client_cards where id = %s", (side,)) == 0
      and one("select count(*) from card_grants where card_id = %s", (side,)) == 0)
check("a card we never had changes nothing", svc("card_forget_method", "pm_never_had") is None)
check("the app can't do it", err(sql_as(alice, "select card_forget_method('pm_x')"), "permission denied"))

print("\n[comparing with Stripe's list]")
keep_a = save_card(alice, pm="pm_keep_a", last4="1001")
drop_a = save_card(alice, pm="pm_drop_a", last4="1002")
rpc(alice, "card_grant", carol, drop_a, 1)
others = one("select count(*) from client_cards where user_id = %s", (alice,))
pruned = svc("card_prune", alice, ["pm_keep_a", "pm_alice_unknown"])
check("cards Stripe no longer has are forgotten, and counted", pruned == others - 1, pruned)
check("the others stay", one("select id::text from client_cards where user_id = %s", (alice,)) == keep_a)
check("and their permissions go", one("select count(*) from card_grants where client_id = %s", (alice,)) == 0)
check("nothing changes for anyone else", one("select count(*) from client_cards where user_id = %s", (bea,)) == 1)
check("an empty list from Stripe clears the person", svc("card_prune", alice, []) == 1 and one("select count(*) from client_cards where user_id = %s", (alice,)) == 0)

print("\n[leaving]")
gone_card = save_card(bea, pm="pm_gone_card", last4="3333")
rpc(bea, "card_grant", carol, gone_card, 1)
a.execute("delete from auth.users where id = %s", (bea,))
check("deleting an account removes its cards, permissions, record and customer",
      one("select count(*) from client_cards where user_id = %s", (bea,)) == 0
      and one("select count(*) from card_grants where client_id = %s", (bea,)) == 0
      and one("select count(*) from card_grant_log where client_id = %s", (bea,)) == 0
      and one("select count(*) from client_stripe_customers where user_id = %s", (bea,)) == 0)
carol_card = save_card(alice, pm="pm_carol_card", last4="7777")
rpc(alice, "card_grant", carol, carol_card, 1)
a.execute("delete from creator_profiles where id = %s", (carol,))
check("a creator leaving ends the permissions given to them", one("select count(*) from card_grants where creator_id = %s", (carol,)) == 0)
check("the client keeps the card", one("select count(*) from client_cards where id = %s", (carol_card,)) == 1)

print()
if failures:
    print(f"{len(failures)} FAILED:")
    for f in failures:
        print("  -", f)
    sys.exit(1)
print("all card checks passed")
