"""Applies the migrations to a throwaway Postgres and tries to break the seat-billing rules: a company can't take
members or bookings until its plan is good, seats follow the team (never below the floor, never above the maximum),
a failed payment gets a grace period and then makes the company read only, a recovery undoes that, and nothing the
app can call can say a plan is paid.

    PGPORT=5432 python3 ios/supabase/tests/billing_rules.py
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
FIXTURES = HERE.parents[1] / "SlateTests" / "Fixtures"
DB = "slate_billing"
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


def rows(uid, fn, *args):
    res = sql_as(uid, f"select * from {fn}({', '.join(['%s'] * len(args))})", args)
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


def join(org, inviter, role, uid, name="Member"):
    inv = rpc(inviter, "invite_create", org, role, None)
    return inv if isinstance(inv, str) else rpc(uid, "accept_invite", inv["token"], name)


def subscribe(org, status="active", quantity=10, customer="cus_1", sub="sub_1", period_days=30, trial_days=None, cancel=False):
    return svc("billing_record_subscription", org, customer, sub, status, quantity,
               one("select now() + make_interval(days => %s)", (period_days,)),
               one("select now() + make_interval(days => %s)", (trial_days,)) if trial_days else None, cancel)


def sub_row(org):
    a.execute("""select status, seats_billed, seats_wanted, grace_until is not null, cancel_at_period_end
                   from org_subscriptions where organization_id = %s""", (org,))
    return a.fetchone()


# =============================================================================
print("\n[the seat rule, against the shared fixture]")
fx = json.loads((FIXTURES / "seat_rules.json").read_text())
wrong = []
for c in fx["cases"]:
    got = one("select seat_plan(%s, %s, %s, %s)", (c["used"], c["delta"], c["min"], c["max"]))
    want = dict(used=c["used"], used_after=c["usedAfter"], billed_now=c["billedNow"], billed_after=c["billedAfter"],
                allowed=c["allowed"], change=c["change"])
    if got != want:
        wrong.append((c, got))
check(f"seat_plan matches the fixture for all {len(fx['cases'])} cases", not wrong, wrong[:1])

# =============================================================================
print("\n[a company that hasn't paid]")
owner = new_user("olivia-ng", "Olivia Ng")
admin_u, creator_u, stranger = new_user(), new_user(), new_user("sam-s", "Sam S")
ORG = rpc(owner, "org_create", "acme-films", "Acme Films", "Acme Films LLC")["organization_id"]
check("billing is required by default", one("select app_billing_required()") is True)
check("the plan starts as 'none' and not ok", rpc(owner, "org_overview", ORG)["plan"]["status"] == "none"
      and rpc(owner, "org_overview", ORG)["plan"]["ok"] is False)
check("it can't invite anyone yet", err(rpc(owner, "invite_create", ORG, "creator", None), "plan_inactive"))

print("\n[starting a plan]")
check("only the Owner can open billing", svc("billing_authorize", owner, ORG) is True and svc("billing_authorize", stranger, ORG) is False)
prep = svc("billing_prepare", owner, ORG)
check("preparing gives the Stripe session what it needs", prep["seats_wanted"] == 10 and prep["trial_eligible"] is True
      and prep["status"] == "none" and prep["customer_id"] is None, prep)
check("a stranger gets nothing", err(svc("billing_prepare", stranger, ORG), "not_found"))
svc("billing_save_customer", ORG, "cus_1")
svc("billing_save_customer", ORG, "cus_other")
check("the customer is saved once", one("select stripe_customer_id from org_subscriptions where organization_id = %s", (ORG,)) == "cus_1")
check("...and found again from Stripe's side", svc("billing_org_for_customer", "cus_1") == ORG and svc("billing_org_for_customer", "cus_nope") is None)
out = subscribe(org=ORG, status="trialing", quantity=10, trial_days=14)
check("a trial opens the company", out["state"] == "active" and rpc(owner, "org_overview", ORG)["plan"]["ok"] is True, out)
check("the plan start is logged", one("select count(*) from activity_log where organization_id = %s and action = 'plan.trialing'", (ORG,)) == 1)
check("an unknown status is refused", err(svc("billing_record_subscription", ORG, "cus_1", "sub_1", "paused", 10, None, None, False), "invalid_status"))
check("so is an unknown company", err(svc("billing_record_subscription", str(uuid.uuid4()), "cus_x", "sub_x", "active", 1, None, None, False), "not_found"))

print("\n[members and seats]")
check("now it can invite", isinstance(rpc(owner, "invite_create", ORG, "admin", None), dict))
a.execute("update invites set status = 'revoked' where organization_id = %s and status = 'pending'", (ORG,))
check("a joined Admin and Creator", isinstance(join(ORG, owner, "admin", admin_u), dict) and isinstance(join(ORG, owner, "creator", creator_u), dict))
check("the team is under the floor, so seats wanted stay at the floor", sub_row(ORG)[2] == 10)
members = [new_user() for _ in range(9)]
for m in members:
    join(ORG, owner, "creator", m)
check("with 12 people 12 seats are wanted", sub_row(ORG)[2] == 12 and rpc(owner, "org_seats", ORG)["billed"] == 12, sub_row(ORG))
check("the sync job notices Stripe is behind", [(r["organization_id"], r["seats_wanted"], r["seats_billed"]) for r in svc("billing_sync_due")] == [(ORG, 12, 10)])
svc("billing_sync_done", ORG, 12)
check("...and stops asking once it is told", svc("billing_sync_due") == [])
rpc(owner, "member_remove", ORG, members[0])
check("removing a person lowers what is wanted", sub_row(ORG)[2] == 11)
for m in members[1:6]:
    rpc(owner, "member_remove", ORG, m)
check("...but never below the floor", sub_row(ORG)[2] == 10, sub_row(ORG))
check("the sync job sees the decrease", [(r["seats_wanted"], r["seats_billed"]) for r in svc("billing_sync_due")] == [(10, 12)])
out = subscribe(ORG, "active", 10)
check("Stripe confirming the lower number records it", sub_row(ORG)[1] == 10 and svc("billing_sync_due") == [])
check("seat changes in the webhook are logged", one("select count(*) from activity_log where organization_id = %s and action = 'plan.active'", (ORG,)) == 1)

print("\n[what the Owner and Admins see]")
ov = rpc(owner, "billing_overview", ORG)
check("the Owner sees the plan", ov["status"] == "active" and ov["seats"]["used"] == 6 and ov["seats"]["billed"] == 10 and ov["seats_billed_by_stripe"] == 10, ov)
check("an Admin doesn't see invoices", err(rpc(admin_u, "billing_overview", ORG), "not_allowed"))
check("a Creator doesn't", err(rpc(creator_u, "billing_overview", ORG), "not_allowed"))
check("a stranger doesn't", err(rpc(stranger, "billing_overview", ORG), "not_found"))
check("the table is the Owner's alone", sql_as(owner, "select count(*) from org_subscriptions")[0][0][0] == 1
      and sql_as(admin_u, "select count(*) from org_subscriptions")[0][0][0] == 0)
pv = rpc(admin_u, "billing_preview", ORG, -1)
check("an Admin can preview a removal: no change under the floor", pv["change"] == "none" and pv["effective"] == "none", pv)
pv = rpc(owner, "billing_preview", ORG, 6)
check("...and an addition: charged now", pv["change"] == "increase" and pv["effective"] == "now" and pv["billed_after"] == 12 and pv["allowed"] is True, pv)
check("a Creator can't preview", err(rpc(creator_u, "billing_preview", ORG, 1), "not_allowed"))
check("the overview tells every member whether the plan is ok", rpc(creator_u, "org_overview", ORG)["plan"]["ok"] is True)

print("\n[the maximum]")
a.execute("update app_settings set value = jsonb_build_object('minimum', 2, 'maximum', 7) where key = 'seats'")
first = rpc(owner, "invite_create", ORG, "creator", None)
check("one more fits", isinstance(first, dict))
check("and the invite counts toward the maximum", err(rpc(owner, "invite_create", ORG, "creator", None), "seat_limit"))
rpc(owner, "invite_revoke", first["invite"]["id"])
a.execute("update app_settings set value = '{\"minimum\": 10, \"maximum\": 250}' where key = 'seats'")

print("\n[a payment fails]")
out = subscribe(ORG, "past_due", 10)
row = sub_row(ORG)
check("a failed payment starts a grace period", row[0] == "past_due" and row[3] is True, row)
check("the company still works inside it", rpc(owner, "org_overview", ORG)["plan"]["ok"] is True and isinstance(rpc(owner, "invite_create", ORG, "viewer", None), dict))
a.execute("update invites set status = 'revoked' where organization_id = %s and status = 'pending'", (ORG,))
check("the failure is logged", one("select count(*) from activity_log where organization_id = %s and action = 'plan.past_due'", (ORG,)) == 1)
subscribe(ORG, "past_due", 10)
check("a second failure doesn't restart the clock", one("select grace_until from org_subscriptions where organization_id = %s", (ORG,)) is not None
      and sub_row(ORG)[3] is True)
a.execute("update org_subscriptions set grace_until = now() - interval '1 minute' where organization_id = %s", (ORG,))
check("past the grace period the plan is no longer ok", rpc(owner, "org_overview", ORG)["plan"]["ok"] is False)
check("the sweep makes the company read only", svc("billing_sweep") == 1 and one("select state from organizations where id = %s", (ORG,)) == "lapsed")
check("the sweep is repeatable", svc("billing_sweep") == 0)
check("lapsing is logged", one("select count(*) from activity_log where organization_id = %s and action = 'plan.lapsed'", (ORG,)) == 1)
check("a lapsed company is still readable", rpc(creator_u, "org_overview", ORG)["state"] == "lapsed" and len(rows(creator_u, "member_list", ORG)) > 3)
check("...but can't invite", err(rpc(owner, "invite_create", ORG, "creator", None), "not_allowed") or err(rpc(owner, "invite_create", ORG, "creator", None), "plan_inactive"))
check("...and the Owner can still reach billing", rpc(owner, "billing_overview", ORG)["state"] == "lapsed")

print("\n[recovering]")
out = subscribe(ORG, "active", 10)
check("a successful payment brings the company back", out["state"] == "active" and sub_row(ORG)[3] is False, out)
check("recovery is logged", one("select count(*) from activity_log where organization_id = %s and action = 'plan.recovered'", (ORG,)) == 1)

print("\n[cancelling]")
out = subscribe(ORG, "active", 10, cancel=True)
check("cancelling at the end of the period changes nothing yet", out["state"] == "active" and sub_row(ORG)[4] is True)
check("the Owner can see it is ending", rpc(owner, "billing_overview", ORG)["cancel_at_period_end"] is True)
out = subscribe(ORG, "canceled", 10)
check("when it ends, the company is read only", out["state"] == "lapsed", out)
check("a lapsed company can't take bookings", one("select org_billing_ok(%s)", (ORG,)) is False)
out = subscribe(ORG, "active", 10, sub="sub_2")
check("signing up again brings it back, with the new subscription", out["state"] == "active" and one("select stripe_subscription_id from org_subscriptions where organization_id = %s", (ORG,)) == "sub_2")

print("\n[closing a company ends its plan]")
other_owner = new_user("rae-s", "Rae S")
CLOSE = rpc(other_owner, "org_create", "close-co", "Close Co", "Close Co LLC")["organization_id"]
subscribe(CLOSE, "active", 10, customer="cus_c", sub="sub_c")
check("a live plan with nothing to change isn't due", svc("billing_sync_due") == [])
rpc(other_owner, "org_close", CLOSE)
due = svc("billing_sync_due")
check("closing makes its subscription due to be cancelled", [(r["organization_id"], r["closed"], r["subscription_id"]) for r in due] == [(CLOSE, True, "sub_c")], due)
svc("billing_sync_done", CLOSE, 0, True)
check("once cancelled it is no longer due", svc("billing_sync_due") == [] and sub_row(CLOSE)[0] == "canceled")
check("a closed company stays closed whatever Stripe says", subscribe(CLOSE, "active", 10, customer="cus_c", sub="sub_c")["state"] == "closed")

print("\n[the app can't say a plan is paid]")
for fn, args in (
    ("billing_record_subscription", (ORG, "cus_x", "sub_x", "active", 99, None, None, False)),
    ("billing_sweep", ()), ("billing_sync_done", (ORG, 5, False)), ("billing_prepare", (owner, ORG)),
    ("billing_authorize", (owner, ORG)), ("billing_save_customer", (ORG, "cus_evil")), ("billing_sync_due", ()),
    ("org_apply_billing", (ORG,)), ("org_billing_ok", (ORG,)),
):
    check(f"{fn} is closed to signed-in users", isinstance(rpc(owner, fn, *args), str), fn)
check("nobody writes to the table directly", isinstance(sql_as(owner, "update org_subscriptions set status = 'active'"), str)
      or sql_as(owner, "update org_subscriptions set status = 'active'")[1] == 0)
check("or inserts", isinstance(sql_as(owner, "insert into org_subscriptions (organization_id, status) values (%s, 'active')", (ORG,)), str))

print("\n[turned off for development]")
a.execute("update app_settings set value = value || '{\"required\": false}'::jsonb where key = 'billing'")
DEV = rpc(new_user("dev-d", "Dev D"), "org_create", "dev-co", "Dev Co", "Dev Co LLC")["organization_id"]
check("with billing off a company needs no plan", one("select org_billing_ok(%s)", (DEV,)) is True)
a.execute("update app_settings set value = value || '{\"required\": true}'::jsonb where key = 'billing'")
check("...and with it on again it does", one("select org_billing_ok(%s)", (DEV,)) is False)

print("\n" + ("ALL PASSED" if not failures else f"{len(failures)} FAILED: {failures}"))
sys.exit(1 if failures else 0)
