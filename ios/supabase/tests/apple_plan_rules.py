"""Applies the migrations to a throwaway Postgres and tries to break the rules for a company plan bought with Apple's
In-App Purchase: a plan is recorded only by the server (never by the app), it covers a number of people and a company
can't take more than that, a bigger or smaller step changes the limit without removing anyone, a late old message can't
undo a newer one, a failed payment gets a grace period and then makes the company read only, a recovery undoes that,
one Apple subscription belongs to one company, and storage follows the people the plan covers.

    PGPORT=5432 python3 ios/supabase/tests/apple_plan_rules.py
"""
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
DB = "slate_apple_plans"
TEAM5 = "com.slateproapp.app.company.team5"
TEAM10 = "com.slateproapp.app.company.team10"
TEAM25 = "com.slateproapp.app.company.team25"


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


def join(org, inviter, role, uid, name="Member"):
    inv = rpc(inviter, "invite_create", org, role, None)
    return inv if isinstance(inv, str) else rpc(uid, "accept_invite", inv["token"], name)


_tick = [0]


def at(days=0, seconds=0):
    return one("select now() + make_interval(days => %s, secs => %s)", (days, seconds))


def apple(org, product=TEAM5, status="active", original="1000000000000001", env="Production", period_days=30,
          trial_days=None, renews=True, grace_days=None, signed=None):
    """What apple-verify / apple-notifications do once Apple's signature has been checked."""
    if signed is None:
        _tick[0] += 1
        signed = at(seconds=_tick[0] * 10)
    return svc("apple_record_subscription", org, original, product, env, status,
               at(days=period_days), at(days=trial_days) if trial_days else None, renews,
               at(days=grace_days) if grace_days else None, signed)


def sub(org):
    a.execute("""select status, provider, seats_covered, apple_product_id, apple_environment, cancel_at_period_end,
                        grace_until is not null from org_subscriptions where organization_id = %s""", (org,))
    return a.fetchone()


def activity(org, action):
    return one("select count(*) from activity_log where organization_id = %s and action = %s", (org, action))


# =============================================================================
print("\n[the plans on offer]")
check("the shipped floor is 5 people", one("select app_seat_minimum()") == 5)
plans = rpc(None, "apple_plan_list", role="anon")
check("the app can read the plans, smallest first",
      [(p["product_id"], p["seats"]) for p in plans] == [(f"com.slateproapp.app.company.team{n}", n) for n in (5, 10, 15, 20, 25)], plans)
check("team_config carries them too", rpc(None, "team_config", role="anon")["apple_plans"] == plans)
check("the table itself is closed to the API", isinstance(sql_as(new_user(), "select * from apple_plans"), str))
a.execute("update apple_plans set active = false where product_id = 'com.slateproapp.app.company.team25'")
check("a step that is switched off is no longer offered", len(rpc(None, "apple_plan_list", role="anon")) == 4)
a.execute("update apple_plans set active = true where product_id = 'com.slateproapp.app.company.team25'")

# =============================================================================
print("\n[a company that hasn't bought]")
owner = new_user("olivia-ng", "Olivia Ng")
admin_u, creator_u, stranger = new_user(), new_user(), new_user("sam-s", "Sam S")
ORG = rpc(owner, "org_create", "acme-films", "Acme Films", "Acme Films LLC")["organization_id"]
check("it can't invite anyone yet", err(rpc(owner, "invite_create", ORG, "creator", None), "plan_inactive"))
ov = rpc(owner, "billing_overview", ORG)
check("the Owner sees no plan", ov["status"] == "none" and ov["seats_covered"] is None and ov["apple_product_id"] is None, ov)

# =============================================================================
print("\n[only the server can record a plan]")
for fn, args in (
    ("apple_record_subscription", (ORG, "1", TEAM5, "Production", "active", None, None, True, None, at())),
    ("apple_org_for_transaction", ("1",)),
    ("org_seat_cap", (ORG,)), ("org_storage_seats", (ORG,)), ("billing_sweep", ()),
):
    check(f"{fn} is closed to signed-in users", isinstance(rpc(owner, fn, *args), str), fn)
    check(f"{fn} is closed to anyone", isinstance(rpc(None, fn, *args, role="anon"), str), fn)
check("nobody writes to the table directly", isinstance(sql_as(owner, "update org_subscriptions set status = 'active'"), str)
      or sql_as(owner, "update org_subscriptions set status = 'active'")[1] == 0)

print("\n[what is refused before it is recorded]")
check("an unknown company", err(svc("apple_record_subscription", str(uuid.uuid4()), "1", TEAM5, "Production", "active", None, None, True, None, at()), "not_found"))
check("an unknown product", err(apple(ORG, product="com.example.other"), "unknown_product"))
check("an unknown status", err(apple(ORG, status="paused"), "invalid_input"))
check("an unknown environment", err(apple(ORG, env="Xcode"), "invalid_input"))
check("an empty subscription id", err(apple(ORG, original=""), "invalid_input"))
check("a missing signing time", err(svc("apple_record_subscription", ORG, "1", TEAM5, "Production", "active", None, None, True, None, None), "invalid_input"))
check("nothing was recorded by any of that", sub(ORG) is None)

# =============================================================================
print("\n[the first plan: up to 5 people, with a free week]")
out = apple(ORG, TEAM5, "trialing", trial_days=7)
check("the trial opens the company", out["state"] == "active" and out["status"] == "trialing" and out["seats"] == 5, out)
check("the plan is ok and says who it is with", rpc(owner, "org_overview", ORG)["plan"]["ok"] is True
      and rpc(owner, "org_overview", ORG)["plan"]["provider"] == "apple" and rpc(owner, "org_overview", ORG)["plan"]["seats_covered"] == 5)
check("the row records Apple's facts", sub(ORG) == ("trialing", "apple", 5, TEAM5, "Production", False, False), sub(ORG))
check("the start is logged", activity(ORG, "plan.trialing") == 1)
check("the limit is the plan's, not 250", rpc(owner, "org_seats", ORG)["maximum"] == 5)
for role, uid in (("admin", admin_u), ("creator", creator_u)):
    check(f"a {role} joins", isinstance(join(ORG, owner, role, uid), dict))
filler = [new_user() for _ in range(2)]
for f in filler:
    join(ORG, owner, "creator", f)
check("five people are on the team", rpc(owner, "org_seats", ORG)["used"] == 5)
check("a sixth can't be invited", err(rpc(owner, "invite_create", ORG, "creator", None), "seat_limit"))

print("\n[repeating the same message]")
before = (activity(ORG, "plan.trialing"), sub(ORG))
out = apple(ORG, TEAM5, "trialing", trial_days=7)
check("recording the same facts again changes nothing", (activity(ORG, "plan.trialing"), sub(ORG)) == before and out["status"] == "trialing")

print("\n[moving up a step]")
out = apple(ORG, TEAM10, "active")
check("the next step covers 10 and the free week is over", out["status"] == "active" and out["seats"] == 10, out)
check("the limit follows at once", rpc(owner, "org_seats", ORG)["maximum"] == 10)
check("the change is logged", activity(ORG, "plan.active") == 1)
inv = rpc(owner, "invite_create", ORG, "creator", None)
check("a sixth can now be invited", isinstance(inv, dict))
rpc(owner, "invite_revoke", inv["invite"]["id"])

print("\n[a late, older message can't undo a newer one]")
out = apple(ORG, TEAM5, "trialing", signed=at(days=-1))
check("it is ignored as stale", out.get("ignored") == "stale" and sub(ORG)[0] == "active" and sub(ORG)[2] == 10, out)

print("\n[what the Owner and Admins see]")
ov = rpc(owner, "billing_overview", ORG)
check("the Owner sees the plan", ov["status"] == "active" and ov["provider"] == "apple" and ov["seats_covered"] == 10
      and ov["apple_product_id"] == TEAM10 and ov["seats_billed_by_stripe"] == 0, ov)
check("an Admin doesn't see billing", err(rpc(admin_u, "billing_overview", ORG), "not_allowed"))
check("a stranger doesn't", err(rpc(stranger, "billing_overview", ORG), "not_found"))
check("the table is the Owner's alone", sql_as(owner, "select count(*) from org_subscriptions")[0][0][0] == 1
      and sql_as(admin_u, "select count(*) from org_subscriptions")[0][0][0] == 0)
check("every member can see whether the plan is ok", rpc(creator_u, "org_overview", ORG)["plan"]["ok"] is True)
pv = rpc(owner, "billing_preview", ORG, 5)
check("a preview of five more people uses the plan's limit", pv["allowed"] is True and rpc(owner, "billing_preview", ORG, 6)["allowed"] is False, pv)

print("\n[storage follows the people the plan covers]")
check("a plan for 10 carries 10 people's storage", one("select files_owner_allowance_bytes(%s)", (ORG,)) == 500_000_000_000)
apple(ORG, TEAM25, "active")
check("a plan for 25 carries 25 people's", one("select files_owner_allowance_bytes(%s)", (ORG,)) == 1_250_000_000_000)

print("\n[moving down a step with more people than it covers]")
extra = [new_user() for _ in range(3)]
apple(ORG, TEAM10, "active")
for e in extra:
    join(ORG, owner, "creator", e)
check("eight people on a plan for 10", rpc(owner, "org_seats", ORG)["used"] == 8)
out = apple(ORG, TEAM5, "active")
check("the smaller plan applies", out["seats"] == 5 and rpc(owner, "org_seats", ORG)["maximum"] == 5, out)
check("nobody is removed", rpc(owner, "org_seats", ORG)["used"] == 8)
check("but nobody new can be invited", err(rpc(owner, "invite_create", ORG, "creator", None), "seat_limit"))
check("and the company still works", rpc(owner, "org_overview", ORG)["plan"]["ok"] is True)
check("the change is logged", activity(ORG, "plan.seats_changed") >= 1)
apple(ORG, TEAM10, "active")

print("\n[turning renewal off]")
out = apple(ORG, TEAM10, "active", renews=False)
check("the company works until the period ends", out["state"] == "active" and sub(ORG)[5] is True)
check("the Owner can see it is ending", rpc(owner, "billing_overview", ORG)["cancel_at_period_end"] is True)
apple(ORG, TEAM10, "active", renews=True)
out = apple(ORG, TEAM10, "active", renews=False)
out = apple(ORG, TEAM10, "active", renews=None)
check("a message that doesn't say whether it renews leaves the flag as it was", sub(ORG)[5] is True, sub(ORG))
apple(ORG, TEAM10, "active", renews=True)

# =============================================================================
print("\n[a payment fails]")
out = apple(ORG, TEAM10, "past_due")
row = sub(ORG)
check("it starts a grace period", row[0] == "past_due" and row[6] is True, row)
check("the company still works inside it", rpc(owner, "org_overview", ORG)["plan"]["ok"] is True and rpc(owner, "org_seats", ORG)["maximum"] == 10)
check("the failure is logged", activity(ORG, "plan.past_due") == 1)
first_grace = one("select grace_until from org_subscriptions where organization_id = %s", (ORG,))
apple(ORG, TEAM10, "past_due")
check("a second failure doesn't restart the clock", one("select grace_until from org_subscriptions where organization_id = %s", (ORG,)) == first_grace)
apple(ORG, TEAM10, "past_due", grace_days=20)
check("a later date from Apple extends it", one("select grace_until > %s from org_subscriptions where organization_id = %s", (first_grace, ORG)) is True)
a.execute("update org_subscriptions set grace_until = now() - interval '1 minute' where organization_id = %s", (ORG,))
check("past the grace period the plan is no longer ok", rpc(owner, "org_overview", ORG)["plan"]["ok"] is False)
check("the sweep makes the company read only", svc("billing_sweep") == 1 and one("select state from organizations where id = %s", (ORG,)) == "lapsed")
check("the sweep is repeatable", svc("billing_sweep") == 0)
check("lapsing is logged", activity(ORG, "plan.lapsed") == 1)
check("a lapsed company can't invite", isinstance(rpc(owner, "invite_create", ORG, "creator", None), str))
check("the Owner can still reach billing", rpc(owner, "billing_overview", ORG)["state"] == "lapsed")

print("\n[recovering]")
out = apple(ORG, TEAM10, "active")
check("a successful payment brings the company back", out["state"] == "active" and sub(ORG)[6] is False, out)
check("recovery is logged", activity(ORG, "plan.recovered") == 1)

# =============================================================================
print("\n[the plan ends]")
out = apple(ORG, TEAM10, "canceled", period_days=-1)
check("an ended plan makes the company read only", out["state"] == "lapsed", out)
check("and it can't take bookings", one("select org_billing_ok(%s)", (ORG,)) is False)
check("an ended plan no longer limits the team", rpc(owner, "org_seats", ORG)["maximum"] == 250)
out = apple(ORG, TEAM5, "active", original="2000000000000002")
check("buying again, with another Apple subscription, brings it back", out["state"] == "active" and sub(ORG)[2] == 5)

print("\n[one subscription, one company]")
rae = new_user("rae-s", "Rae S")
OTHER = rpc(rae, "org_create", "other-co", "Other Co", "Other Co LLC")["organization_id"]
check("another company can't claim the same Apple subscription", err(apple(OTHER, TEAM5, original="2000000000000002"), "transaction_in_use"))
check("a company with a running plan can't take a second one", err(apple(ORG, TEAM10, original="3000000000000003"), "plan_exists"))
check("the first company's plan is untouched", sub(ORG)[0] == "active" and sub(OTHER) is None)
check("the owning company is found from Apple's id", svc("apple_org_for_transaction", "2000000000000002") == ORG and svc("apple_org_for_transaction", "nope") is None)

print("\n[a sandbox purchase is recorded as one]")
sandbox_owner = new_user("sandy-b", "Sandy B")
SB = rpc(sandbox_owner, "org_create", "sandbox-co", "Sandbox Co", "Sandbox Co LLC")["organization_id"]
apple(SB, TEAM5, "trialing", original="4000000000000004", env="Sandbox", trial_days=7)
check("the environment is kept", sub(SB)[4] == "Sandbox" and rpc(sandbox_owner, "billing_overview", SB)["apple_environment"] == "Sandbox")

# =============================================================================
print("\n[a plan nobody renewed]")
quiet_owner = new_user("quin-d", "Quin D")
QUIET = rpc(quiet_owner, "org_create", "quiet-co", "Quiet Co", "Quiet Co LLC")["organization_id"]
apple(QUIET, TEAM5, "active", original="5000000000000005", period_days=-1)
check("a period that ended a day ago is within the slack: still fine", svc("billing_sweep") == 0 and sub(QUIET)[0] == "active")
a.execute("update org_subscriptions set current_period_end = now() - interval '4 days' where organization_id = %s", (QUIET,))
check("four days with no renewal and no message: the sweep ends it", svc("billing_sweep") == 1 and sub(QUIET)[0] == "canceled")
check("...and the company becomes read only", one("select state from organizations where id = %s", (QUIET,)) == "lapsed")
check("the reason is logged", activity(QUIET, "plan.canceled") == 1)
out = apple(QUIET, TEAM5, "active", original="5000000000000005", period_days=30)
check("a renewal that turns up late brings it back", out["state"] == "active")

print("\n[closing a company]")
close_owner = new_user("cleo-m", "Cleo M")
CLOSE = rpc(close_owner, "org_create", "close-co", "Close Co", "Close Co LLC")["organization_id"]
apple(CLOSE, TEAM5, "active", original="6000000000000006")
rpc(close_owner, "org_close", CLOSE)
out = apple(CLOSE, TEAM5, "active", original="6000000000000006")
check("a closed company stays closed whatever Apple says", out.get("ignored") == "closed" and one("select state from organizations where id = %s", (CLOSE,)) == "closed", out)

print("\n[the older Stripe plan still works beside it]")
stripe_owner = new_user("stu-p", "Stu P")
ST = rpc(stripe_owner, "org_create", "stripe-co", "Stripe Co", "Stripe Co LLC")["organization_id"]
svc("billing_record_subscription", ST, "cus_1", "sub_1", "active", 8, at(days=30), None, False)
check("a Stripe plan is recorded as before", sub(ST)[:2] == ("active", "stripe") and rpc(stripe_owner, "org_seats", ST)["maximum"] == 250)
check("an Apple plan can't be stacked on a running Stripe one", err(apple(ST, TEAM5, original="7000000000000007"), "plan_exists"))

print("\n" + ("ALL PASSED" if not failures else f"{len(failures)} FAILED: {failures}"))
sys.exit(1 if failures else 0)
