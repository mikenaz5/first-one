"""Applies the migrations to a throwaway Postgres and tries to break the company-account rules: who can create a
company, invite, change roles, edit and see what, and that the database (not the app) says no.

Needs a Postgres server (16 recommended) and psycopg2, like booking_rules.py:

    PGPORT=5432 python3 ios/supabase/tests/team_rules.py
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
DB = "slate_team"
Json = psycopg2.extras.Json


def connect(db=DB):
    c = psycopg2.connect(dbname=db, **HOST)
    c.autocommit = True
    return c


# ---- fresh database ---------------------------------------------------------
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
    """One statement as a user. Returns (rows, rowcount) or 'ERR:...'."""
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
    """Call a function that returns one value (or void). Returns the value, or 'ERR:...'."""
    res = sql_as(uid, f"select {fn}({', '.join(['%s'] * len(args))})", args, role)
    if isinstance(res, str):
        return res
    value = res[0][0][0]
    return None if value == "" else value  # psycopg2 hands back '' for void


def rows(uid, fn, *args):
    """Call a set-returning function. Returns a list of tuples or 'ERR:...'."""
    res = sql_as(uid, f"select * from {fn}({', '.join(['%s'] * len(args))})", args)
    return res if isinstance(res, str) else res[0]


def new_user(handle=None, name="User"):
    uid = str(uuid.uuid4())
    a.execute("insert into auth.users (id, email) values (%s, %s)", (uid, f"{uid[:8]}@example.com"))
    if handle:
        a.execute("insert into creator_profiles (id, handle, display_name) values (%s,%s,%s)", (uid, handle, name))
    return uid


def add_signature(uid, name):
    a.execute("insert into creator_signatures (creator_id, signed_name, method) values (%s,%s,'typed')", (uid, name))


def one(query, args=None):
    a.execute(query, args)
    r = a.fetchone()
    return r[0] if r else None


def activity(org, action=None):
    if action:
        return one("select count(*) from activity_log where organization_id = %s and action = %s", (org, action))
    return one("select count(*) from activity_log where organization_id = %s", (org,))


def set_state(org, state):
    a.execute("update organizations set state = %s, closed_at = case when %s = 'closed' then now() end where id = %s",
              (state, state, org))


def join(org, inviter, role, uid, name=None):
    """The inviter makes an invite, the person accepts. Returns the accept result."""
    inv = rpc(inviter, "invite_create", org, role, None)
    if isinstance(inv, str):
        return inv
    return rpc(uid, "accept_invite", inv["token"], name)


# =============================================================================
print("\n[settings and the shared permission table]")
cfg = rpc(None, "team_config", role="anon")
check("team_config answers anyone with the defaults",
      cfg == dict(seat_minimum=10, seat_maximum=250, invite_expiry_days=7, grace_days=7), cfg)
check("the settings table is closed to the API", isinstance(sql_as(new_user(), "select * from app_settings"), str))
bad = None
try:
    a.execute("update app_settings set value = '{\"minimum\": 50, \"maximum\": 20}' where key = 'seats'")
except psycopg2.Error as e:
    bad = e
check("a seat maximum below the minimum is refused", bad is not None)
a.execute("update app_settings set value = '{\"minimum\": 4, \"maximum\": 6}' where key = 'seats'")
check("changing the setting changes the config the app reads", rpc(None, "team_config", role="anon")["seat_maximum"] == 6)
a.execute("update app_settings set value = '{\"minimum\": 10, \"maximum\": 250}' where key = 'seats'")

fx = json.loads((FIXTURES / "team_permissions.json").read_text())
wrong = []
for perm in fx["permissions"]:
    for role in fx["roles"]:
        if one("select org_role_allows(%s, %s)", (role, perm)) != (role in fx["permissions"][perm]):
            wrong.append((role, perm))
check(f"org_role_allows matches the fixture for all {len(fx['roles']) * len(fx['permissions'])} role/permission pairs", not wrong, wrong[:3])
check("an unknown permission is allowed to no one", not any(one("select org_role_allows(%s, 'nope')", (r,)) for r in fx["roles"]))
wrong = [c for c in fx["assign"] if one("select org_can_assign_role(%s,%s,%s)", (c["actor"], c["current"], c["new"])) != c["allowed"]]
check(f"org_can_assign_role matches the fixture for all {len(fx['assign'])} cases", not wrong, wrong[:2])
wrong = [c for c in fx["manage"] if one("select org_can_manage_role(%s,%s)", (c["actor"], c["target"])) != c["allowed"]]
check(f"org_can_manage_role matches the fixture for all {len(fx['manage'])} cases", not wrong, wrong[:2])

# =============================================================================
print("\n[profiles: a person or a company]")
olivia = new_user("olivia-ng", "Olivia Ng")
add_signature(olivia, "Olivia Ng")
check("an existing person profile is kind person and owned by its user",
      a.execute("select kind, user_id = id from creator_profiles where id = %s", (olivia,)) is None and a.fetchone() == ("person", True))
res = sql_as(olivia, "insert into creator_profiles (id, kind, handle, display_name) values (%s, 'company', 'sneaky-co', 'Sneaky')", (olivia,))
check("a person can't make themselves a company profile by inserting one", isinstance(res, str), res)
check("a person's profile can't change kind",
      sql_as(olivia, "update creator_profiles set kind = 'company' where id = %s", (olivia,))[1] == 1
      and one("select kind from creator_profiles where id = %s", (olivia,)) == "person")
res = None
try:
    a.execute("insert into creator_profiles (id, kind, user_id, handle, display_name) values (gen_random_uuid(), 'company', %s, 'bad-shape', 'Bad')", (olivia,))
except psycopg2.Error as e:
    res = e
check("a company profile can't claim a user id", res is not None)

# =============================================================================
print("\n[creating a company]")
ORG = rpc(olivia, "org_create", "acme-films", "Acme Films", "Acme Films LLC", "1 Main St", "We shoot weddings", ["weddings", "events"], "Austin, TX")
check("a person creates a company", isinstance(ORG, dict) and ORG["my_role"] == "owner" and ORG["name"] == "Acme Films", ORG)
ORG = ORG["organization_id"]
check("the company profile is kind company with no user", a.execute("select kind, user_id from creator_profiles where id = %s", (ORG,)) is None and a.fetchone() == ("company", None))
check("the creator is its only member, as Owner",
      a.execute("select role, user_id from memberships where organization_id = %s and removed_at is null", (ORG,)) is None
      and a.fetchall() == [("owner", olivia)])
check("creating a company is logged", activity(ORG, "org.created") == 1)
check("a taken handle is refused", err(rpc(olivia, "org_create", "acme-films", "Again", "Again LLC"), "handle_taken"))
check("a person's handle is taken too (one namespace)", err(rpc(olivia, "org_create", "olivia-ng", "Again", "Again LLC"), "handle_taken"))
check("a reserved handle is refused", err(rpc(olivia, "org_create", "admin", "Admin Co", "Admin Co LLC"), "invalid_input"))
check("a one-letter legal name is refused", err(rpc(olivia, "org_create", "tiny-co", "Tiny", "T"), "invalid_input") or
      err(rpc(olivia, "org_create", "tiny-co", "Tiny", "T"), "check"))
nobody = new_user()
check("someone with no profile must give a name to create a company", err(rpc(nobody, "org_create", "nobody-co", "Nobody Co", "Nobody Co LLC"), "profile_required"))
res = rpc(nobody, "org_create", "nobody-co", "Nobody Co", "Nobody Co LLC", "", "", [], None, "Nia Nobody")
check("...and gets a person profile made for them as the Owner's member profile",
      isinstance(res, dict) and one("select display_name from creator_profiles where id = %s and kind = 'person'", (nobody,)) == "Nia Nobody", res)
check("signed-out callers can't create a company", isinstance(rpc(None, "org_create", "x-co", "X", "X LLC", role="anon"), str))

accts = rpc(olivia, "my_accounts")
check("my_accounts lists the personal account and the company",
      accts["personal"]["has_profile"] and [c["name"] for c in accts["companies"]] == ["Acme Films"] and accts["companies"][0]["role"] == "owner", accts)
check("a stranger's accounts don't include it", rpc(new_user("zed", "Zed"), "my_accounts")["companies"] == [])

# =============================================================================
print("\n[invites and joining]")
admin_u = new_user()          # no profile: made at joining
manager_u = new_user("mia-k", "Mia K")
creator_u = new_user("cal-r", "Cal R")
viewer_u = new_user("vee-t", "Vee T")
stranger = new_user("sam-s", "Sam S")

check("the Owner can invite an Admin", isinstance(rpc(olivia, "invite_create", ORG, "admin", "dee@example.com"), dict))
check("the Owner can't invite an Owner", err(rpc(olivia, "invite_create", ORG, "owner", None), "invalid_role"))
check("an unknown role is refused", err(rpc(olivia, "invite_create", ORG, "boss", None), "invalid_role"))
check("a bad email is refused", err(rpc(olivia, "invite_create", ORG, "creator", "not-an-email"), "invalid_input"))
check("a stranger can't invite", err(rpc(stranger, "invite_create", ORG, "creator", None), "not_found"))

inv = rpc(olivia, "invite_create", ORG, "admin", "Dee@Example.com")
check("the invite returns a token once and stores only its hash",
      len(inv["token"]) >= 30 and one("select count(*) from invites where token_hash = %s", (inv["token"],)) == 0
      and one("select count(*) from invites where token_hash = invite_hash(%s)", (inv["token"],)) == 1)
check("the email is stored lowercased as a label", inv["invite"]["email"] == "dee@example.com")
check("the invites table is closed to the API", isinstance(sql_as(olivia, "select * from invites"), str))
check("invite_list shows pending invites to the Owner", len(rows(olivia, "invite_list", ORG)) == 2)

pv = rpc(admin_u, "invite_preview", inv["token"])
check("the link shows the company, role and inviter", pv["organization_name"] == "Acme Films" and pv["role"] == "admin" and pv["invited_by_name"] == "Olivia Ng" and pv["has_profile"] is False, pv)
check("a bad token is one generic error", err(rpc(admin_u, "invite_preview", "nope"), "invite_invalid"))
check("signed-out callers can't preview", isinstance(rpc(None, "invite_preview", inv["token"], role="anon"), str))
check("someone with no profile must give a name to join", err(rpc(admin_u, "accept_invite", inv["token"]), "profile_required"))
check("a failed join leaves the invite usable", one("select status from invites where id = %s", (inv["invite"]["id"],)) == "pending")
res = rpc(admin_u, "accept_invite", inv["token"], "Dee Okafor")
check("accepting joins as the invited role and makes a profile", isinstance(res, dict) and res["my_role"] == "admin"
      and one("select display_name from creator_profiles where id = %s", (admin_u,)) == "Dee Okafor", res)
check("the made handle is valid", one("select handle ~ '^[a-z0-9][a-z0-9_-]{1,28}[a-z0-9]$' from creator_profiles where id = %s", (admin_u,)))
check("an invite works once", err(rpc(stranger, "accept_invite", inv["token"]), "invite_invalid"))
check("joining is logged", activity(ORG, "member.joined") == 1)

check("an Admin can invite a Manager", isinstance(join(ORG, admin_u, "manager", manager_u), dict))
check("an Admin can't invite an Admin", err(rpc(admin_u, "invite_create", ORG, "admin", None), "not_allowed"))
check("the Owner invites a Creator", isinstance(join(ORG, olivia, "creator", creator_u), dict))
check("the Owner invites a Viewer", isinstance(join(ORG, olivia, "viewer", viewer_u), dict))
check("a Viewer joins as not bookable", one("select bookable from memberships where user_id = %s and removed_at is null", (viewer_u,)) is False)
check("a Manager can't invite", err(rpc(manager_u, "invite_create", ORG, "creator", None), "not_allowed"))
check("a Creator can't invite", err(rpc(creator_u, "invite_create", ORG, "creator", None), "not_allowed"))
check("a Viewer can't invite", err(rpc(viewer_u, "invite_create", ORG, "creator", None), "not_allowed"))
check("a Manager can't list invites", err(rows(manager_u, "invite_list", ORG), "not_allowed"))
check("an existing member can't use another invite", err(join(ORG, olivia, "creator", creator_u), "already_member"))

inv2 = rpc(olivia, "invite_create", ORG, "creator", None)
a.execute("update invites set expires_at = now() - interval '1 minute' where id = %s", (inv2["invite"]["id"],))
check("an expired invite is invalid", err(rpc(stranger, "accept_invite", inv2["token"]), "invite_invalid"))
check("...and is listed as expired", any(r[3] == "expired" for r in rows(olivia, "invite_list", ORG)))

inv3 = rpc(olivia, "invite_create", ORG, "creator", "later@example.com")
inv_admin = rpc(olivia, "invite_create", ORG, "admin", None)
check("an Admin can't revoke an Admin invite", err(rpc(admin_u, "invite_revoke", inv_admin["invite"]["id"]), "not_allowed"))
res = rpc(admin_u, "invite_revoke", inv3["invite"]["id"])
check("an Admin can revoke a Creator invite", res is None, res)
check("a revoked invite is invalid", err(rpc(stranger, "accept_invite", inv3["token"]), "invite_invalid"))
check("a revoked invite can't be revoked again", err(rpc(olivia, "invite_revoke", inv3["invite"]["id"]), "invite_invalid"))
check("revoking is logged", activity(ORG, "invite.revoked") == 1)

old = rpc(olivia, "invite_create", ORG, "viewer", "old@example.com")
new = rpc(olivia, "invite_resend", old["invite"]["id"])
check("resend revokes the old link and makes a new one",
      err(rpc(stranger, "invite_preview", old["token"]), "invite_invalid") and new["token"] != old["token"]
      and new["invite"]["role"] == "viewer" and new["invite"]["email"] == "old@example.com")
rpc(olivia, "invite_revoke", new["invite"]["id"])

# =============================================================================
print("\n[seats]")
a.execute("update invites set status = 'revoked' where organization_id = %s and status = 'pending'", (ORG,))
a.execute("update app_settings set value = jsonb_build_object('minimum', 2, 'maximum', %s) where key = 'seats'",
          (one("select count(*) + 1 from memberships where organization_id = %s and removed_at is null", (ORG,)),))
first = rpc(olivia, "invite_create", ORG, "creator", None)
check("an invite can take the last seat", isinstance(first, dict))
check("the pending invite counts toward the maximum", err(rpc(olivia, "invite_create", ORG, "creator", None), "seat_limit"))
seats = rpc(olivia, "org_seats", ORG)
check("seats report used, pending, billed and limits", seats["used"] == 5 and seats["pending"] == 1 and seats["billed"] == 5 and seats["maximum"] == 6, seats)
rpc(olivia, "invite_revoke", first["invite"]["id"])
a.execute("update app_settings set value = '{\"minimum\": 10, \"maximum\": 250}' where key = 'seats'")
seats = rpc(olivia, "org_seats", ORG)
check("billed seats never fall below the floor", seats["billed"] == 10 and seats["used"] == 5, seats)
check("a stranger can't read seats", err(rpc(stranger, "org_seats", ORG), "not_found"))

# =============================================================================
print("\n[roles]")
def role_of(u):
    return one("select role from memberships where organization_id = %s and user_id = %s and removed_at is null", (ORG, u))

check("the Owner promotes a Creator to Manager", rpc(olivia, "member_set_role", ORG, creator_u, "manager") is None and role_of(creator_u) == "manager")
check("role changes are logged", activity(ORG, "member.role_changed") == 1)
rpc(olivia, "member_set_role", ORG, creator_u, "creator")
check("an Admin can make a Creator a Viewer", rpc(admin_u, "member_set_role", ORG, creator_u, "viewer") is None and role_of(creator_u) == "viewer"
      and one("select bookable from memberships where user_id = %s and removed_at is null", (creator_u,)) is False)
rpc(admin_u, "member_set_role", ORG, creator_u, "creator")
check("an Admin can't make anyone an Admin", err(rpc(admin_u, "member_set_role", ORG, creator_u, "admin"), "not_allowed"))
check("an Admin can't change the Owner", err(rpc(admin_u, "member_set_role", ORG, olivia, "viewer"), "not_allowed"))
check("an Admin can't change themselves", err(rpc(admin_u, "member_set_role", ORG, admin_u, "viewer"), "not_allowed"))
check("the Owner can't change themselves", err(rpc(olivia, "member_set_role", ORG, olivia, "admin"), "not_allowed"))
check("nobody is made Owner by a role change", err(rpc(olivia, "member_set_role", ORG, creator_u, "owner"), "invalid_role"))
check("a Manager can't change roles", err(rpc(manager_u, "member_set_role", ORG, creator_u, "viewer"), "not_allowed"))
check("a Creator can't change roles", err(rpc(creator_u, "member_set_role", ORG, viewer_u, "creator"), "not_allowed"))
check("a stranger gets nothing", err(rpc(stranger, "member_set_role", ORG, creator_u, "viewer"), "not_found"))
check("the Owner promotes a Manager to Admin", rpc(olivia, "member_set_role", ORG, manager_u, "admin") is None and role_of(manager_u) == "admin")
check("an Admin can't demote an Admin", err(rpc(admin_u, "member_set_role", ORG, manager_u, "creator"), "not_allowed"))
check("the Owner demotes an Admin", rpc(olivia, "member_set_role", ORG, manager_u, "manager") is None and role_of(manager_u) == "manager")

team = rows(olivia, "member_list", ORG)
check("the Owner sees the team in role order", [r[1] for r in team] == ["owner", "admin", "manager", "creator", "viewer"], [r[1] for r in team])
check("a Viewer sees the team too", len(rows(viewer_u, "member_list", ORG)) == 5)
check("a stranger doesn't", err(rows(stranger, "member_list", ORG), "not_found"))
check("the table shows the roster to members", sql_as(creator_u, "select count(*) from memberships where organization_id = %s", (ORG,))[0][0][0] == 5)
check("the table hides shares from everyone", isinstance(sql_as(olivia, "select share_bps from memberships"), str))
check("...and the roster from outsiders", sql_as(stranger, "select count(*) from memberships where organization_id = %s", (ORG,))[0][0][0] == 0)

print("\n[team profiles and the split ledger]")
check("an Admin sets a title", rpc(admin_u, "member_update", ORG, creator_u, "Lead videographer", None, None) is None
      and one("select title from memberships where user_id = %s and removed_at is null", (creator_u,)) == "Lead videographer")
check("a Creator can't edit team profiles", err(rpc(creator_u, "member_update", ORG, creator_u, "Boss", None, None), "not_allowed"))
check("an Admin can't edit the Owner's profile", err(rpc(admin_u, "member_update", ORG, olivia, "Nope", None, None), "not_allowed"))
check("a Viewer can't be made bookable", err(rpc(admin_u, "member_update", ORG, viewer_u, None, None, True), "invalid_input"))
check("an Admin can't set shares", err(rpc(admin_u, "member_set_share", ORG, creator_u, 5000), "not_allowed"))
check("the Owner sets a share", rpc(olivia, "member_set_share", ORG, creator_u, 4000) is None)
check("a share above 100% is refused", err(rpc(olivia, "member_set_share", ORG, creator_u, 10001), "invalid_input"))
shares = {r[0]: r[5] for r in rows(olivia, "member_list", ORG)}
check("the Owner sees shares", shares[creator_u] == 4000, shares)
check("an Admin sees none", all(r[5] == 0 for r in rows(admin_u, "member_list", ORG)))
check("an Admin can't turn on the split ledger", err(rpc(admin_u, "org_set_split", ORG, True), "not_allowed"))
check("the Owner turns it on", rpc(olivia, "org_set_split", ORG, True)["split_enabled"] is True)

print("\n[company settings]")
res = rpc(admin_u, "org_update", ORG, "Acme Films Inc", "2 Main St", "manual", None)
check("an Admin edits the legal name and assignment mode", isinstance(res, dict) and res["assignment_mode"] == "manual"
      and one("select legal_name from organizations where id = %s", (ORG,)) == "Acme Films Inc", res)
check("an invalid assignment mode is refused", err(rpc(admin_u, "org_update", ORG, None, None, "random", None), "invalid_input"))
check("only the Owner changes who may sign", err(rpc(admin_u, "org_update", ORG, None, None, None, ["owner", "admin", "manager"]), "not_allowed"))
check("a Manager can't edit settings", err(rpc(manager_u, "org_update", ORG, "X Co", None, None, None), "not_allowed"))
check("signer roles must include the Owner", err(rpc(olivia, "org_update", ORG, None, None, None, ["admin"]), "invalid_input"))
rpc(admin_u, "org_update", ORG, None, None, "auto", None)
check("settings changes are logged", activity(ORG, "org.updated") >= 2)

print("\n[the designated signer]")
check("a signer needs a stored signature", err(rpc(admin_u, "org_designate_signer", ORG, admin_u, "Director"), "signature_required"))
add_signature(admin_u, "Dee Okafor")
check("a Manager isn't an allowed signer until the Owner says so", err(rpc(olivia, "org_designate_signer", ORG, manager_u, "Ops"), "signer_role_not_allowed"))
check("a Manager can't designate", err(rpc(manager_u, "org_designate_signer", ORG, olivia, ""), "not_allowed"))
res = rpc(admin_u, "org_designate_signer", ORG, admin_u, "Director")
check("an Admin can name a signer", res["signer_user_id"] == admin_u and res["signer_title"] == "Director", res)
check("designating is logged", activity(ORG, "signer.designated") == 1)
check("the authorisation is recorded", one("select signer_authorized_at is not null and signer_designated_by = %s from organizations where id = %s", (admin_u, ORG)))
rpc(olivia, "member_set_role", ORG, admin_u, "creator")
check("demoting the signer stops auto-countersign",
      one("select signer_user_id is null and signer_authorized_at is null from organizations where id = %s", (ORG,)) and activity(ORG, "signer.cleared") == 1)
rpc(olivia, "member_set_role", ORG, admin_u, "admin")
rpc(olivia, "org_designate_signer", ORG, admin_u, "Director")
check("widening the signer roles is the Owner's", rpc(olivia, "org_update", ORG, None, None, None, ["owner", "admin", "manager"])["signer_roles"] == ["owner", "admin", "manager"])
add_signature(manager_u, "Mia K")
check("...then a Manager can be named", rpc(olivia, "org_designate_signer", ORG, manager_u, "Ops lead")["signer_user_id"] == manager_u)
rpc(olivia, "org_update", ORG, None, None, None, ["owner", "admin"])
check("narrowing the roles clears a signer who no longer qualifies", one("select signer_user_id is null from organizations where id = %s", (ORG,)))
rpc(olivia, "org_designate_signer", ORG, admin_u, "Director")

# =============================================================================
print("\n[the database says no, whatever the app sends]")
def bio(uid, text="edited"):
    return sql_as(uid, "update creator_profiles set bio = %s where id = %s", (text, ORG))

check("an Admin edits the company profile", bio(admin_u, "Weddings and films")[1] == 1)
check("...and it is logged with who did it", one("select actor_name from activity_log where organization_id = %s and action = 'company.profile_updated' order by created_at desc limit 1", (ORG,)) == "Dee Okafor")
check("the Owner edits it", bio(olivia, "Weddings, films")[1] == 1)
for who, label in ((manager_u, "a Manager"), (creator_u, "a Creator"), (viewer_u, "a Viewer"), (stranger, "a stranger")):
    check(f"{label} can't edit the company profile", bio(who)[1] == 0)
check("the profile reads as public to anyone", sql_as(None, "select bio from creator_profiles where id = %s", (ORG,), role="anon")[0][0][0] == "Weddings, films")
check("nobody can delete the company profile", all(sql_as(u, "delete from creator_profiles where id = %s", (ORG,))[1] == 0 for u in (olivia, admin_u, stranger)))
check("a member can't rewrite another person's profile", sql_as(creator_u, "update creator_profiles set bio = 'x' where id = %s", (olivia,))[1] == 0)

def add_item(uid):
    return sql_as(uid, "insert into portfolio_items (creator_id, kind, image_path, thumbnail_path) values (%s,'photo','a.jpg','a_t.jpg')", (ORG,))

check("an Admin adds to the company portfolio", add_item(admin_u)[1] == 1)
check("a Creator can't", isinstance(add_item(creator_u), str))
check("a stranger can't", isinstance(add_item(stranger), str))
item = one("select id from portfolio_items where creator_id = %s", (ORG,))
check("a Creator can't delete company portfolio items", sql_as(creator_u, "delete from portfolio_items where id = %s", (item,))[1] == 0)
check("an Admin can", sql_as(admin_u, "delete from portfolio_items where id = %s", (item,))[1] == 1)

def upload(uid, bucket, folder):
    return sql_as(uid, "insert into storage.objects (bucket_id, name) values (%s, %s)", (bucket, f"{folder}/pic.jpg"))

check("an Admin uploads a logo to the company folder", upload(admin_u, "avatars", ORG)[1] == 1)
check("a Creator can't", isinstance(upload(creator_u, "avatars", ORG), str))
check("a Creator still uploads to their own folder", upload(creator_u, "portfolio", creator_u)[1] == 1)
check("nobody uploads to a folder that isn't an id of theirs", isinstance(upload(admin_u, "portfolio", "not-a-uuid"), str)
      and isinstance(upload(admin_u, "portfolio", str(uuid.uuid4())), str))

check("a Manager can't read the activity log table", sql_as(manager_u, "select count(*) from activity_log where organization_id = %s", (ORG,))[0][0][0] == 0)
check("...or call activity_list", err(rows(manager_u, "activity_list", ORG), "not_allowed"))
check("an Admin reads it", sql_as(admin_u, "select count(*) from activity_log where organization_id = %s", (ORG,))[0][0][0] > 5)
check("activity_list pages", len(rows(olivia, "activity_list", ORG, 3)) == 3
      and len(rows(olivia, "activity_list", ORG, 1000)) == activity(ORG))
check("nobody writes to the log through the table API", isinstance(sql_as(olivia, "insert into activity_log (organization_id, action, summary) values (%s, 'fake.entry', 'forged')", (ORG,)), str))
check("nobody forges an entry through the function", isinstance(rpc(olivia, "activity_add", ORG, "fake.entry", "x", None, "forged"), str))
bad = None
try:
    a.execute("update activity_log set summary = 'changed' where organization_id = %s", (ORG,))
except psycopg2.Error as e:
    bad = e
check("the log can't be edited, even by the database owner", bad is not None)
bad = None
try:
    a.execute("delete from activity_log where organization_id = %s", (ORG,))
except psycopg2.Error as e:
    bad = e
check("...or emptied", bad is not None)
check("an entry names its actor", one("select actor_name from activity_log where action = 'org.created' and organization_id = %s", (ORG,)) == "Olivia Ng")

print("\n[isolation between companies]")
rival_owner = new_user("rae-s", "Rae S")
RIVAL = rpc(rival_owner, "org_create", "rival-films", "Rival Films", "Rival Films LLC")["organization_id"]
check("a member of another company sees nothing here", err(rpc(rival_owner, "org_overview", ORG), "not_found") and err(rows(rival_owner, "member_list", ORG), "not_found"))
check("...can't invite here", err(rpc(rival_owner, "invite_create", ORG, "creator", None), "not_found"))
check("...can't read this activity", err(rows(rival_owner, "activity_list", ORG), "not_allowed"))
check("...can't edit this profile", sql_as(rival_owner, "update creator_profiles set bio = 'x' where id = %s", (ORG,))[1] == 0)
check("an Owner here is no one there", err(rpc(olivia, "org_overview", RIVAL), "not_found") and sql_as(olivia, "update creator_profiles set bio = 'x' where id = %s", (RIVAL,))[1] == 0)
check("acts_for follows the company, not the id",
      rpc(olivia, "acts_for", ORG, "company.edit") is True and rpc(olivia, "acts_for", RIVAL, "company.edit") is False
      and rpc(olivia, "acts_for", olivia, "company.edit") is True and rpc(stranger, "acts_for", olivia, "company.edit") is False)
check("signed out, acts_for is false", rpc(None, "acts_for", ORG, "team.view", role="anon") is False)
check("accounts only show a person's own companies", [c["name"] for c in rpc(rival_owner, "my_accounts")["companies"]] == ["Rival Films"])

print("\n[the public team]")
pub = sql_as(None, "select display_name from org_public_team(%s)", (ORG,), role="anon")[0]
names = [r[0] for r in pub]
check("the public team lists bookable, listed members and no Viewers", "Vee T" not in names and "Olivia Ng" in names and len(names) == 4, names)
rpc(admin_u, "member_update", ORG, creator_u, None, False, None)
check("an unlisted member is left off", "Cal R" not in [r[0] for r in sql_as(None, "select display_name from org_public_team(%s)", (ORG,), role="anon")[0]])
rpc(admin_u, "member_update", ORG, creator_u, None, True, None)

print("\n[removing, leaving, transferring]")
check("the Owner can't leave", err(rpc(olivia, "member_leave", ORG), "last_owner"))
check("the Owner can't be removed", err(rpc(admin_u, "member_remove", ORG, olivia), "last_owner"))
second_admin = new_user("ada-l", "Ada L")
join(ORG, olivia, "admin", second_admin)
check("an Admin can't remove another Admin", err(rpc(admin_u, "member_remove", ORG, second_admin), "not_allowed"))
check("an Admin can't remove themselves (they leave instead)", err(rpc(admin_u, "member_remove", ORG, admin_u), "not_allowed"))
check("a Manager can't remove anyone", err(rpc(manager_u, "member_remove", ORG, viewer_u), "not_allowed"))
check("an Admin removes a Viewer", rpc(admin_u, "member_remove", ORG, viewer_u) is None and role_of(viewer_u) is None)
check("a removed member is out at once", err(rpc(viewer_u, "org_overview", ORG), "not_found")
      and not rpc(viewer_u, "acts_for", ORG, "team.view") and isinstance(rows(viewer_u, "member_list", ORG), str))
check("removal keeps history", one("select removed_at is not null and removed_by = %s from memberships where user_id = %s", (admin_u, viewer_u)))
check("removal is logged", activity(ORG, "member.removed") == 1)
check("a removed member can be invited again", isinstance(join(ORG, olivia, "viewer", viewer_u), dict))
check("a Creator leaves", rpc(creator_u, "member_leave", ORG) is None and role_of(creator_u) is None and activity(ORG, "member.left") == 1)
check("a stranger can't leave", err(rpc(stranger, "member_leave", ORG), "not_found"))

check("only the Owner transfers ownership", err(rpc(admin_u, "org_transfer_ownership", ORG, admin_u), "not_allowed"))
check("...to a member", err(rpc(olivia, "org_transfer_ownership", ORG, stranger), "invalid_input"))
check("...who isn't themselves", err(rpc(olivia, "org_transfer_ownership", ORG, olivia), "invalid_input"))
check("the Owner transfers ownership", rpc(olivia, "org_transfer_ownership", ORG, admin_u) is None and role_of(admin_u) == "owner" and role_of(olivia) == "admin")
check("there is still exactly one Owner", one("select count(*) from memberships where organization_id = %s and role = 'owner' and removed_at is null", (ORG,)) == 1)
check("the old Owner can no longer close the company", err(rpc(olivia, "org_close", ORG), "not_allowed"))
rpc(admin_u, "org_transfer_ownership", ORG, olivia)

print("\n[a lapsed plan]")
set_state(ORG, "lapsed")
check("a lapsed company is still readable", rpc(olivia, "org_overview", ORG)["state"] == "lapsed" and len(rows(manager_u, "member_list", ORG)) >= 3)
check("...but read only", bio(admin_u)[1] == 0 and err(rpc(admin_u, "invite_create", ORG, "creator", None), "not_allowed"))
check("the Owner can still reach billing and closing",
      rpc(olivia, "acts_for", ORG, "billing.manage") is True and rpc(olivia, "acts_for", ORG, "company.delete") is True
      and rpc(olivia, "acts_for", ORG, "company.edit") is False)
lapsed_ok = [p for p in fx["permissions"] if rpc(olivia, "acts_for", ORG, p)]
check("a lapsed Owner holds exactly the read-only permissions plus billing and closing",
      sorted(lapsed_ok) == sorted(fx["readOnlyWhenLapsed"]), lapsed_ok)
set_state(ORG, "active")
check("when the plan comes back, so does editing", bio(admin_u, "back")[1] == 1)

print("\n[closing a company]")
# Raw rows: the notification triggers (rewired for companies in the next migration) are switched off for this insert.
a.execute("alter table bookings disable trigger user")
a.execute("""insert into bookings (creator_id, client_id, creator_name, package_name, start_at, end_at, blocked_until, time_zone,
                                  currency_code, total_cents, deposit_cents, status)
             values (%s, %s, 'Acme Films', 'Wedding', now() + interval '10 days', now() + interval '10 days 4 hours',
                     now() + interval '10 days 4 hours', 'America/Chicago', 'USD', 100000, 30000, 'confirmed') returning id""",
          (ORG, stranger))
upcoming = a.fetchone()[0]
a.execute("alter table bookings enable trigger user")
check("only the Owner may close", err(rpc(admin_u, "org_close", ORG), "not_allowed"))
check("a company with upcoming bookings can't be closed", err(rpc(olivia, "org_close", ORG), "has_upcoming_bookings"))
a.execute("alter table bookings disable trigger user")
a.execute("update bookings set status = 'cancelled', cancelled_at = now() where id = %s", (upcoming,))
a.execute("alter table bookings enable trigger user")
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
a.execute("insert into contract_templates (creator_id, title, kind, clauses) values (%s,'Wedding terms','photography',%s) returning id", (ORG, Json(CLAUSES)))
tmpl = a.fetchone()[0]
a.execute("insert into packages (creator_id, name, price_cents, duration_minutes, deposit_cents, is_published, contract_template_id) values (%s,'Wedding',100000,60,0,true,%s)", (ORG, tmpl))
open_invite = rpc(olivia, "invite_create", ORG, "creator", None)
check("the Owner closes the company", rpc(olivia, "org_close", ORG) is None and one("select state from organizations where id = %s", (ORG,)) == "closed")
check("everyone is out at once", err(rpc(admin_u, "org_overview", ORG), "not_found") and err(rpc(olivia, "org_overview", ORG), "not_found"))
check("its link stops working", one("select count(*) from packages where creator_id = %s and is_published", (ORG,)) == 0)
check("its open invites die", err(rpc(stranger, "accept_invite", open_invite["token"]), "invite_invalid"))
check("it leaves the account switcher", rpc(olivia, "my_accounts")["companies"] == [])
check("nothing is allowed on a closed company", not any(rpc(olivia, "acts_for", ORG, p) for p in fx["permissions"]))
check("its handle is free again", isinstance(rpc(olivia, "org_create", "acme-films", "Acme Again", "Acme Again LLC"), dict))
check("its profile row and activity log are kept for the contracts that name it",
      one("select count(*) from creator_profiles where id = %s", (ORG,)) == 1 and activity(ORG, "org.closed") == 1)
check("closing again is refused", err(rpc(olivia, "org_close", ORG), "not_found"))

print("\n" + ("ALL PASSED" if not failures else f"{len(failures)} FAILED: {failures}"))
sys.exit(1 if failures else 0)
