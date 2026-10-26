"""Applies the migrations to a throwaway Postgres and tries to break Slate Files (hosted delivery): the rules the phone
shares (caps, allowance, thirty days, who can open what, reminders), who may reserve, finish, deliver and remove a file,
who may read which bytes (the storage policies, as each kind of person), that the previews come before payment and the
originals only after it, how a delivery ends, and that deleting things leaves their bytes to be purged.

Needs a Postgres server (16 recommended) and psycopg2, like the other scripts here:

    PGPORT=5432 python3 ios/supabase/tests/file_rules.py

The numbers and cases are shared with the app through SlateTests/Fixtures/file_rules.json. What the app decodes
(file_rows.json) is checked against what the database really returns; run with --dump to rewrite it after changing a shape.
"""
import json
import os
import pathlib
import re
import sys
import threading
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
FIXTURE = HERE.parents[1] / "SlateTests" / "Fixtures" / "file_rules.json"
ROWS = HERE.parents[1] / "SlateTests" / "Fixtures" / "file_rows.json"
DB = "slate_files"
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
# These checks are about files, not about paying for seats (billing_rules.py is).
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
    """Call a function the way an Edge Function does, with the service role."""
    return rpc(None, fn, *args, role="service_role")


def one(query, args=None):
    a.execute(query, args)
    r = a.fetchone()
    return r[0] if r else None


def rows(query, args=None):
    a.execute(query, args)
    return a.fetchall()


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


def connect_account(owner):
    a.execute(
        "insert into creator_payment_accounts (creator_id, stripe_account_id, charges_enabled, payouts_enabled, details_submitted)"
        " values (%s, %s, true, true, true)", (owner, "acct_" + owner[:8]))


days = [2]


def raw_booking(creator, client, assigned=None, total=120000, deposit=30000, status="confirmed", started=True, deposit_paid=True,
                delivery_url=None):
    """A booking as the database owner, with the notification triggers off (a past shoot, the way set-up needs it).
    Nothing delivered yet and nothing confirmed."""
    days[0] += 1
    a.execute("alter table bookings disable trigger user")
    try:
        a.execute(
            """insert into bookings (creator_id, client_id, creator_name, client_name, package_name, start_at, end_at, blocked_until,
                                     time_zone, currency_code, total_cents, deposit_cents, status, assigned_to, delivery_url, delivered_at)
               values (%s, %s, 'Test Creator', 'Sam Client', 'Wedding',
                       case when %s then now() - make_interval(days => %s) else now() + make_interval(days => %s) end,
                       case when %s then now() - make_interval(days => %s) else now() + make_interval(days => %s) end + interval '4 hours',
                       case when %s then now() - make_interval(days => %s) else now() + make_interval(days => %s) end + interval '4 hours',
                       'America/Chicago', 'USD', %s, %s, %s, %s, %s, case when %s::text is null then null else now() - interval '1 hour' end)
               returning id""",
            (creator, client, started, days[0], days[0], started, days[0], days[0], started, days[0], days[0],
             total, deposit, status, assigned or creator, delivery_url, delivery_url))
        bid = a.fetchone()[0]
    finally:
        a.execute("alter table bookings enable trigger user")
    if deposit_paid and deposit > 0:
        a.execute(
            "insert into payments (booking_id, kind, amount_cents, currency_code, status, method, stripe_payment_intent_id, paid_at)"
            " values (%s, 'deposit', %s, 'USD', 'succeeded', 'apple_pay', %s, now())", (bid, deposit, "pi_dep_" + uuid.uuid4().hex[:10]))
    return bid


def pay_balance(booking, client):
    """The balance, the real way: the database works the amount out and Stripe's webhook records it."""
    prep = svc("payment_prepare", client, booking, "balance", 0)
    if isinstance(prep, str):
        return prep
    intent = "pi_" + uuid.uuid4().hex[:18]
    svc("payment_attach_intent", prep["payment_id"], intent)
    return svc("payment_record_success", intent, prep["amount_cents"], "ch_" + uuid.uuid4().hex[:10], "apple_pay")


def put(uid, path, size):
    """The creator's phone sends the bytes to storage: a row in storage.objects, as that person."""
    return sql_as(uid, "insert into storage.objects (bucket_id, name, metadata) values ('deliveries', %s, %s)",
                  (path, json.dumps({"size": size})))


def can_see(uid, path):
    res = sql_as(uid, "select count(*) from storage.objects where bucket_id = 'deliveries' and name = %s", (path,))
    return (not isinstance(res, str)) and res[0][0][0] == 1


def status_of(file_id):
    return one("select status from delivery_files where id = %s", (file_id,))


def make_file(user, booking, name="IMG_0001.HEIC", kind="photo", ctype="image/heic", original=12_000_000, preview=800_000,
              upload=True):
    """Reserve, send the bytes, finish. Returns the reservation (with the outcome under 'finalized')."""
    res = rpc(user, "files_reserve", booking, kind, name, ctype, 4000, 3000, 12.5 if kind == "video" else None, original, preview)
    if isinstance(res, str) or not upload:
        return res
    put(user, res["original_path"], original)
    put(user, res["preview_path"], preview)
    res["finalized"] = rpc(user, "files_finalize", res["file_id"])
    return res


def counts(booking, event):
    return one("select count(*) from messages where booking_id = %s and event = %s", (booking, event))


def pushes(user, kind, booking=None):
    if booking:
        return one("select count(*) from push_outbox where user_id = %s and kind = %s and booking_id = %s", (user, kind, booking))
    return one("select count(*) from push_outbox where user_id = %s and kind = %s", (user, kind))


def set_files_setting(**fields):
    a.execute("update app_settings set value = value || %s::jsonb where key = 'files'", (json.dumps(fields),))


def usage(owner):
    return one("select files_owner_used_bytes(%s)", (owner,))


# =============================================================================
print("\n[the rules the app shares]")
cfg = one("select files_config()")
snake = {"retentionDays": "retention_days", "draftDays": "draft_days", "warnDays": "warn_days", "quotaGBIndividual": "quota_gb_individual",
         "quotaGBPerSeat": "quota_gb_per_seat", "maxPhotoMB": "max_photo_mb", "maxVideoGB": "max_video_gb", "maxFiles": "max_files",
         "previewPhotoMaxMB": "preview_photo_max_mb", "previewVideoMaxMB": "preview_video_max_mb", "urlMinutes": "url_minutes",
         "reservationHours": "reservation_hours"}
for key, column in snake.items():
    check(f"setting {column} is {rules['config'][key]}", cfg[column] == rules["config"][key], cfg[column])
check("the server answers to nothing but the agreed settings", set(cfg) == set(snake.values()), sorted(set(cfg) ^ set(snake.values())))
check("anyone can ask for the numbers", not isinstance(sql_as(None, "select files_config()", role="anon"), str))
try:
    a.execute("update app_settings set value = value || '{\"retention_days\": 0}'::jsonb where key = 'files'")
    check("a thirty-day rule can't become zero", False)
except psycopg2.Error:
    check("a thirty-day rule can't become zero", True)

for case in rules["caps"]:
    got = one("select files_check_caps(%s, %s, %s, %s, %s, %s)", (case["kind"], case["originalBytes"], case["previewBytes"], case["filesInDelivery"],
                                                                  case["usedBytes"], case["allowanceBytes"]))
    check(f"caps: {case['name']}", got == case["refusal"], got)
for case in rules["allowance"]:
    got = one("select files_allowance_bytes(%s, %s)", (case["individual"], case["billedSeats"]))
    check(f"allowance: {case['name']}", got == case["bytes"], got)
for case in rules["expiry"]:
    got = one("select files_expires_at(%s::timestamptz) = %s::timestamptz", (case["deliveredAt"], case["expiresAt"]))
    check(f"thirty days: {case['name']}", got, one("select files_expires_at(%s::timestamptz)", (case["deliveredAt"],)))
for case in rules["expiredAt"]:
    got = one("select %s::timestamptz <= %s::timestamptz", (case["expiresAt"], rules["now"]))
    check(f"over at the moment it is up: {case['name']}", got == case["expired"], got)
for case in rules["open"]:
    got = one("select files_can_open(%s, %s, %s, %s, %s::timestamptz, %s, %s::timestamptz)",
              (case["part"], case["viewer"], case["deliveryKind"], case["state"], case["expiresAt"], case["owedCents"], rules["now"]))
    check(f"who can open: {case['name']}", got == case["open"], got)
for case in rules["reminders"]:
    got = one("select files_reminder_day(%s::timestamptz, %s::timestamptz)", (case["expiresAt"], rules["now"]))
    check(f"reminder: {case['name']}", got == case["day"], got)
for case in rules["titles"]:
    check(f"title for revision {case['sequence']}", one("select files_revision_title(%s)", (case["sequence"],)) == case["title"])
for case in rules["names"]:
    got = one("select files_clean_name(%s)", (case["input"],))
    check(f"file name: {case['name']}", got == case["clean"], got)
for case in rules["contentTypes"]:
    got = one("select files_kind_for(%s)", (case["type"],))
    check(f"content type {case['type']!r}", got == case["kind"], got)
for case in rules["firstDeliveryLocked"]:
    got = one("select files_first_delivery_locked(%s, %s, %s)", (case["hasFilesDelivery"], case["linkDelivered"], case["balancePaid"]))
    check(f"first delivery lock: {case['name']}", got == case["locked"], got)
for case in rules["revisionAllowed"]:
    first = None if case["firstState"] == "none" else case["firstState"]
    got = one("select files_revision_allowed(%s, %s)", (first, case["owedCents"]))
    check(f"revision: {case['name']}", got == case["allowed"], got)

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
check("the company is set up", one("select count(*) from memberships where organization_id = %s and removed_at is null", (ORG,)) == 6)

b1 = raw_booking(carol, alice)
check("a shoot that has happened, nothing delivered", one("select delivered_at is null and receipt_confirmed_at is null from bookings where id = %s", (b1,)))

# =============================================================================
print("\n[who may start putting files in]")
args = ("photo", "IMG_0001.HEIC", "image/heic", 4000, 3000, None, 12_000_000, 800_000)
check("you have to be signed in", err(sql_as(None, "select files_reserve(%s,'photo','a.heic','image/heic',1,1,null,1000,100)", (b1,)), "not_signed_in"))
check("someone who isn't signed in at all is turned away",
      err(sql_as(None, "select files_reserve(%s,'photo','a.heic','image/heic',1,1,null,1000,100)", (b1,), role="anon"), "permission denied"))
check("the client can't", err(rpc(alice, "files_reserve", b1, *args), "not_found"))
check("a stranger can't", err(rpc(stranger, "files_reserve", b1, *args), "not_found"))
check("a booking that isn't there", err(rpc(carol, "files_reserve", str(uuid.uuid4()), *args), "not_found"))
b_future = raw_booking(carol, alice, started=False)
check("not before the shoot", err(rpc(carol, "files_reserve", b_future, *args), "files_not_allowed"))
b_cancelled = raw_booking(carol, alice, status="cancelled")
check("not for a cancelled booking", err(rpc(carol, "files_reserve", b_cancelled, *args), "files_not_allowed"))
check("only photos and videos", err(rpc(carol, "files_reserve", b1, "photo", "a.pdf", "application/pdf", 1, 1, None, 1000, 100), "unsupported_type"))
check("a video isn't a photo", err(rpc(carol, "files_reserve", b1, "video", "a.heic", "image/heic", 1, 1, None, 1000, 100), "unsupported_type"))
check("a kind has to be one of the two", err(rpc(carol, "files_reserve", b1, "audio", "a.mp4", "video/mp4", 1, 1, None, 1000, 100), "unsupported_type"))
check("nothing is recorded by the refusals", one("select count(*) from delivery_files") == 0 and one("select count(*) from deliveries") == 0)
check("empty files are refused", err(rpc(carol, "files_reserve", b1, "photo", "a.heic", "image/heic", 1, 1, None, 0, 100), "file_empty"))
check("a photo over the cap", err(rpc(carol, "files_reserve", b1, "photo", "a.heic", "image/heic", 1, 1, None, 100_000_001, 100), "file_too_large"))
check("a preview over the cap", err(rpc(carol, "files_reserve", b1, "photo", "a.heic", "image/heic", 1, 1, None, 1000, 5_000_001), "preview_too_large"))

res = rpc(carol, "files_reserve", b1, *args)
check("a reservation is made", isinstance(res, dict), res)
fid = res["file_id"]
check("the paths are lowercase ids: owner, booking, file", res["original_path"] == f"{carol}/{b1}/{fid}/original" and res["preview_path"] == f"{carol}/{b1}/{fid}/preview"
      and res["original_path"] == res["original_path"].lower(), res)
check("it is uploading, with the sizes reserved", rows("select status, original_bytes, preview_bytes, name from delivery_files where id = %s", (fid,)) == [("uploading", 12_000_000, 800_000, "IMG_0001.HEIC")])
check("a draft delivery holds it", one("select state || kind || sequence from deliveries where booking_id = %s", (b1,)) == "draftdelivery0")
check("the space is counted at once", usage(carol) == 12_800_000 and res["used_bytes"] == 12_800_000)
check("and the allowance is given", res["allowance_bytes"] == 25_000_000_000)
check("a name is tidied before it is kept", rpc(carol, "files_reserve", b1, "photo", "  ../a\u0001b.heic ", "IMAGE/HEIC", 1, 1, None, 1000, 100)["file_id"] is not None
      and one("select name || '|' || content_type from delivery_files order by created_at desc limit 1") == ".. a b.heic|image/heic")
a.execute("delete from delivery_files where name = '.. a b.heic'")

# =============================================================================
print("\n[the bytes: who may put in and take out]")
prev_path, orig_path = res["preview_path"], res["original_path"]
check("the creator can put in the original", not isinstance(put(carol, orig_path, 12_000_000), str))
check("and the preview", not isinstance(put(carol, prev_path, 800_000), str))
check("not a path nobody reserved", err(put(carol, f"{carol}/{b1}/{uuid.uuid4()}/original", 10), "row-level security"))
check("not under another name", err(put(carol, f"{carol}/{b1}/{fid}/extra", 10), "row-level security"))
check("the client can't put anything in", err(put(alice, f"{carol}/{b1}/{fid}/original", 10), "row-level security"))
check("a stranger can't", err(put(stranger, f"{carol}/{b1}/{fid}/original", 10), "row-level security"))
check("and not into another bucket", err(sql_as(carol, "insert into storage.objects (bucket_id, name, metadata) values ('other', %s, '{}')", (f"{carol}/{b1}/{fid}/original",)), "row-level security"))
anon_put = sql_as(None, "insert into storage.objects (bucket_id, name, metadata) values ('deliveries', %s, '{}')", (orig_path,), role="anon")
check("someone who isn't signed in can't", err(anon_put, "row-level security") or err(anon_put, "permission denied"), anon_put)
check("only the creator side sees a draft's bytes", can_see(carol, orig_path) and can_see(carol, prev_path)
      and not can_see(alice, prev_path) and not can_see(stranger, prev_path) and not can_see(bea, orig_path))
check("nobody can delete bytes through the API", sql_as(carol, "delete from storage.objects where name = %s", (orig_path,))[1] == 0 and sql_as(alice, "delete from storage.objects where name = %s", (orig_path,))[1] == 0
      and one("select count(*) from storage.objects where name = %s", (orig_path,)) == 1)

# =============================================================================
print("\n[finishing a file]")
check("only the creator side can finish", err(rpc(alice, "files_finalize", fid), "not_found") and err(rpc(stranger, "files_finalize", fid), "not_found"))
check("a file that isn't there", err(rpc(carol, "files_finalize", str(uuid.uuid4())), "not_found"))
res2 = rpc(carol, "files_reserve", b1, "photo", "IMG_0002.HEIC", "image/heic", 4000, 3000, None, 5_000_000, 500_000)
check("a file with no bytes in storage isn't finished", err(rpc(carol, "files_finalize", res2["file_id"]), "upload_incomplete"))
put(carol, res2["original_path"], 5_000_000)
check("half is not enough", err(rpc(carol, "files_finalize", res2["file_id"]), "upload_incomplete"))
put(carol, res2["preview_path"], 500_000)
done = rpc(carol, "files_finalize", fid)
check("the bytes are there: accepted", done == {"accepted": True, "refusal": None, "file_id": fid}, done)
check("it is ready, with the sizes storage holds", rows("select status, original_bytes, preview_bytes, ready_at is not null from delivery_files where id = %s", (fid,)) == [("ready", 12_000_000, 800_000, True)])
check("finishing twice changes nothing", rpc(carol, "files_finalize", fid)["accepted"] is True)
done2 = rpc(carol, "files_finalize", res2["file_id"])
check("a second file is accepted", done2["accepted"] is True)

# A file bigger than was reserved is refused after the fact, and its bytes go.
res3 = rpc(carol, "files_reserve", b1, "photo", "big.heic", "image/heic", 1, 1, None, 1_000_000, 100_000)
put(carol, res3["original_path"], 9_000_000)
put(carol, res3["preview_path"], 90_000)
liar = rpc(carol, "files_finalize", res3["file_id"])
check("bigger than reserved: refused", liar == {"accepted": False, "refusal": "file_too_large", "file_id": res3["file_id"]}, liar)
check("it is removed and its bytes queued for deletion", status_of(res3["file_id"]) == "removed"
      and rows("select path from storage_purge where path in (%s, %s) order by path", (res3["original_path"], res3["preview_path"])) == sorted([(res3["original_path"],), (res3["preview_path"],)]))
check("its space is free again", usage(carol) == 12_800_000 + 5_500_000)
res4 = rpc(carol, "files_reserve", b1, "photo", "fat-preview.heic", "image/heic", 1, 1, None, 1_000_000, 100_000)
put(carol, res4["original_path"], 900_000)
put(carol, res4["preview_path"], 200_000)
check("a preview bigger than reserved: refused", rpc(carol, "files_finalize", res4["file_id"])["refusal"] == "preview_too_large")
res5 = rpc(carol, "files_reserve", b1, "photo", "fat-preview2.heic", "image/heic", 1, 1, None, 1_000_000, 4_999_000)
put(carol, res5["original_path"], 900_000)
put(carol, res5["preview_path"], 5_000_001)
check("a preview over the cap, whatever was reserved: refused", rpc(carol, "files_finalize", res5["file_id"])["refusal"] == "preview_too_large")

# =============================================================================
print("\n[what each person sees while it is a draft]")
as_creator = rpc(carol, "list_booking_files", b1)
d0 = as_creator["deliveries"][0]
check("the creator sees the draft, its files and where they are", len(as_creator["deliveries"]) == 1 and d0["state"] == "draft" and len(d0["files"]) == 2
      and all(f["original_path"] and f["preview_path"] for f in d0["files"]), as_creator)
check("and the space used", as_creator["used_bytes"] == 18_300_000 and as_creator["allowance_bytes"] == 25_000_000_000, as_creator)
check("and that the files can be delivered", as_creator["can_deliver_files"] is True and as_creator["can_send_revision"] is False)
as_client = rpc(alice, "list_booking_files", b1)
check("the client sees nothing yet", as_client["deliveries"] == [] and as_client["used_bytes"] is None and as_client["can_deliver_files"] is False, as_client)
check("a stranger can't ask", err(rpc(stranger, "list_booking_files", b1), "not_found"))
check("you have to be signed in", err(sql_as(None, "select list_booking_files(%s)", (b1,)), "not_signed_in"))
check("tables are not open to the app", err(sql_as(carol, "select * from deliveries"), "permission denied") and err(sql_as(alice, "select * from delivery_files"), "permission denied")
      and err(sql_as(carol, "select * from storage_purge"), "permission denied") and err(sql_as(alice, "select * from file_reports"), "permission denied"))

# =============================================================================
print("\n[delivering]")
check("only the creator side can deliver", err(rpc(alice, "files_deliver", b1), "not_found") and err(rpc(stranger, "files_deliver", b1), "not_found"))
check("nothing to deliver on another booking", err(rpc(carol, "files_deliver", raw_booking(carol, bea)), "nothing_to_deliver"))
res6 = rpc(carol, "files_reserve", b1, "photo", "late.heic", "image/heic", 1, 1, None, 1_000_000, 100_000)
check("a file still uploading holds the delivery back", err(rpc(carol, "files_deliver", b1), "files_not_ready"))
rpc(carol, "files_remove", res6["file_id"])
check("a note can't be too long", err(rpc(carol, "files_deliver", b1, None, "x" * 501), "note_too_long"))

check("the booking is open", one("select status::text from bookings where id = %s", (b1,)) == "confirmed")
delivered = rpc(carol, "files_deliver", b1, None, "Enjoy!  The full set.")
check("delivered", isinstance(delivered, dict) and delivered["deliveries"][0]["state"] == "delivered", delivered)
dl = delivered["deliveries"][0]
check("thirty days start now", dl["expires_at"] is not None and one("select expires_at - delivered_at = interval '30 days' from deliveries where booking_id = %s", (b1,)))
check("the note is kept", dl["note"] == "Enjoy!  The full set." and dl["kind"] == "delivery" and dl["sequence"] == 0 and dl["title"] == "")
check("the booking is marked delivered and received: the balance is payable",
      one("select delivered_at is not null and receipt_confirmed_at is not null and delivery_url is null from bookings where id = %s", (b1,)))
check("with a balance owed it stays open", one("select status::text from bookings where id = %s", (b1,)) == "confirmed")
check("the conversation says so", counts(b1, "files_delivered") == 1)
check("the client is told", pushes(alice, "files_delivered", b1) == 1)
check("with the count of photos and what is owed",
      one("select data ->> 'photos' || '/' || (data ->> 'balanceCents') from push_outbox where user_id = %s and kind = 'files_delivered'", (alice,)) == "2/90000")
check("but the creator isn't told the client confirmed anything", counts(b1, "receipt_confirmed") == 0 and pushes(carol, "receipt_confirmed", b1) == 0)
check("nor is the client", pushes(alice, "receipt_confirmed", b1) == 0)
check("it is delivered once", err(rpc(carol, "files_deliver", b1), "nothing_to_deliver"))

print("\n[what the client can open, before and after paying]")
a_cl = rpc(alice, "list_booking_files", b1)
cd = a_cl["deliveries"][0]
check("the client sees the delivery", a_cl["owed_cents"] == 90000 and cd["state"] == "delivered" and len(cd["files"]) == 2, a_cl)
check("and every preview", all(f["preview_path"] for f in cd["files"]))
check("but no original while something is owed", cd["originals_open"] is False and all(f["original_path"] is None for f in cd["files"]))
check("and no space figures", a_cl["used_bytes"] is None and a_cl["allowance_bytes"] is None)
check("the previews open", can_see(alice, prev_path))
check("the originals don't", not can_see(alice, orig_path))
check("a stranger gets nothing", not can_see(stranger, prev_path) and not can_see(bea, prev_path))
anon_seen = sql_as(None, "select count(*) from storage.objects where bucket_id = 'deliveries'", role="anon")
check("someone who isn't signed in gets nothing", err(anon_seen, "permission denied") or anon_seen[0][0][0] == 0, anon_seen)
check("the creator can still open both", can_see(carol, orig_path) and can_see(carol, prev_path))
check("a client can't save an original yet", err(rpc(alice, "files_mark_saved", fid), "originals_locked"))
check("a stranger can't say it was saved", err(rpc(stranger, "files_mark_saved", fid), "not_found") and err(rpc(carol, "files_mark_saved", fid), "not_found"))
check("a revision is no way round paying", err(rpc(carol, "files_reserve", b1, *args), "revision_not_allowed"))
check("no revision offered", rpc(carol, "list_booking_files", b1)["can_send_revision"] is False)

paid = pay_balance(b1, alice)
check("Stripe says the balance was paid", isinstance(paid, dict) and paid["action"] == "completed", paid)
check("the originals now open for the client", can_see(alice, orig_path))
cd = rpc(alice, "list_booking_files", b1)["deliveries"][0]
check("and the list says so", cd["originals_open"] is True and all(f["original_path"] for f in cd["files"]))
check("the booking is complete", one("select status::text from bookings where id = %s", (b1,)) == "completed")
saved = rpc(alice, "files_mark_saved", fid)
check("saving counts one of two", saved == {"saved": 1, "total": 2}, saved)
first_saved = one("select saved_at from delivery_files where id = %s", (fid,))
check("saving again changes nothing", rpc(alice, "files_mark_saved", fid) == {"saved": 1, "total": 2} and one("select saved_at from delivery_files where id = %s", (fid,)) == first_saved)
check("a file that isn't there", err(rpc(alice, "files_mark_saved", str(uuid.uuid4())), "not_found"))

# =============================================================================
print("\n[a revision, free after payment]")
check("the creator can offer one now", rpc(carol, "list_booking_files", b1)["can_send_revision"] is True and rpc(carol, "list_booking_files", b1)["can_deliver_files"] is False)
rev = make_file(carol, b1, "IMG_0001-fixed.HEIC")
check("a new file goes into a new draft: a revision", isinstance(rev, dict) and rev["delivery_kind"] == "revision" and rev["finalized"]["accepted"], rev)
check("it is revision 1", one("select kind || sequence from deliveries where id = %s", (rev["delivery_id"],)) == "revision1")
check("a long title is refused", err(rpc(carol, "files_deliver", b1, "t" * 81, None), "title_too_long"))
sent = rpc(carol, "files_deliver", b1, None, None)
rd = [d for d in sent["deliveries"] if d["sequence"] == 1][0]
check("without a title it is named for its number", rd["title"] == "Revision 1" and rd["kind"] == "revision" and rd["state"] == "delivered", rd)
check("the booking didn't change", one("select status::text from bookings where id = %s", (b1,)) == "completed")
check("the client is told it is a revision", one("select data ->> 'revised' from push_outbox where user_id = %s and kind = 'files_delivered' order by created_at desc limit 1", (alice,)) == "true")
check("the conversation says so", counts(b1, "files_delivered") == 2)
check("the client opens a revision's original at once (nothing is owed)", can_see(alice, rev["original_path"]))
rev2 = make_file(carol, b1, "IMG_0009.HEIC")
sent2 = rpc(carol, "files_deliver", b1, "Final colour", "Re-graded")
check("a revision can have its own title", [d for d in sent2["deliveries"] if d["sequence"] == 2][0]["title"] == "Final colour")
check("the first delivery stays as it was", [d for d in sent2["deliveries"] if d["sequence"] == 0][0]["state"] == "delivered")
check("only one draft at a time", one("select count(*) from deliveries where booking_id = %s and state = 'draft'", (b1,)) == 0)

# =============================================================================
print("\n[removing a file]")
before = usage(carol)
check("the client can't remove one", err(rpc(alice, "files_remove", fid), "not_found") and err(rpc(stranger, "files_remove", fid), "not_found"))
check("someone who isn't signed in can't", err(sql_as(None, "select files_remove(%s)", (fid,), role="anon"), "permission denied"))
check("a file that isn't there", err(rpc(carol, "files_remove", str(uuid.uuid4())), "not_found"))
rpc(carol, "files_remove", rev2["file_id"])
check("the creator can, even after delivery", status_of(rev2["file_id"]) == "removed")
check("its space is free", usage(carol) == before - 12_000_000 - 800_000)
check("its bytes are queued for deletion", one("select count(*) from storage_purge where path in (%s,%s)", (rev2["original_path"], rev2["preview_path"])) == 2)
check("the client no longer sees it", rev2["file_id"] not in json.dumps(rpc(alice, "list_booking_files", b1)))
check("nor can they open it", not can_see(alice, rev2["original_path"]) and not can_see(alice, rev2["preview_path"]))
check("removing twice is refused", err(rpc(carol, "files_remove", rev2["file_id"]), "not_found"))

# =============================================================================
print("\n[reports]")
check("the client can report a file", rpc(alice, "files_report", fid, "  This isn't my wedding\n") is None
      and one("select reason from file_reports where file_id = %s", (fid,)) == "This isn't my wedding")
check("so can the creator", rpc(carol, "files_report", fid, "") is None and one("select count(*) from file_reports where file_id = %s", (fid,)) == 2)
check("a stranger can't", err(rpc(stranger, "files_report", fid, "spam"), "not_found"))
check("a removed file can't be reported", err(rpc(carol, "files_report", rev2["file_id"], "x"), "not_found"))
check("reports are closed to the app", err(sql_as(alice, "select * from file_reports"), "permission denied"))

# =============================================================================
print("\n[the first delivery: files or a link, not both]")
b_link = raw_booking(carol, bea, delivery_url="https://files.example.com/final")
check("after a link is shared, files can't be the first delivery", err(rpc(carol, "files_reserve", b_link, *args), "delivery_locked"))
b_paid = raw_booking(carol, bea)
a.execute("insert into payments (booking_id, kind, amount_cents, currency_code, status, method, stripe_payment_intent_id, paid_at) values (%s,'balance',90000,'USD','succeeded','apple_pay',%s,now())",
          (b_paid, "pi_b_" + uuid.uuid4().hex[:10]))
check("nor after the client has paid", err(rpc(carol, "files_reserve", b_paid, *args), "delivery_locked"))
b_race = raw_booking(carol, bea)
make_file(carol, b_race, "x.heic", original=1_000_000, preview=100_000)
rpc(carol, "files_deliver", b_race)
check("sharing a link after files were delivered is refused (the client is already received)",
      err(rpc(carol, "share_delivery", b_race, "https://files.example.com/y"), "not_deliverable"))

b_free = raw_booking(carol, bea, total=30000, deposit=30000)
make_file(carol, b_free, "free.heic", original=1_000_000, preview=100_000)
rpc(carol, "files_deliver", b_free)
check("a booking with nothing left to pay is complete on delivery", one("select status::text from bookings where id = %s", (b_free,)) == "completed")
check("its balance was never needed", one("select count(*) from payments where booking_id = %s and kind = 'balance'", (b_free,)) == 0)
check("its originals are open at once", can_see(bea, f"{carol}/{b_free}/" + one("select id::text from delivery_files where booking_id = %s", (b_free,)) + "/original"))

# =============================================================================
print("\n[the limits]")
b_lim = raw_booking(carol, alice)
set_files_setting(max_files=2)
x1 = make_file(carol, b_lim, "1.heic", original=1_000, preview=100)
x2 = make_file(carol, b_lim, "2.heic", original=1_000, preview=100)
check("a delivery holds as many as allowed", x1["finalized"]["accepted"] and x2["finalized"]["accepted"])
check("then it is full", err(rpc(carol, "files_reserve", b_lim, "photo", "3.heic", "image/heic", 1, 1, None, 1_000, 100), "too_many_files"))
rpc(carol, "files_remove", x2["file_id"])
check("a removed file makes room", isinstance(rpc(carol, "files_reserve", b_lim, "photo", "3.heic", "image/heic", 1, 1, None, 1_000, 100), dict))
set_files_setting(max_files=1000)

# A tiny allowance, to see "full": 1 GB, and one photo that nearly fills it.
b_full = raw_booking(carol, bea)
base = usage(carol)
set_files_setting(quota_gb_individual=1, max_photo_mb=1000)
room = 1_000_000_000 - base
r_ok = rpc(carol, "files_reserve", b_full, "photo", "huge.heic", "image/heic", 1, 1, None, room - 5_000_000 - 1_000_000, 1_000_000)
check("with room, a big file is reserved", isinstance(r_ok, dict), r_ok)
check("the next one doesn't fit", err(rpc(carol, "files_reserve", b_full, "photo", "more.heic", "image/heic", 1, 1, None, 6_000_000, 1_000_000), "storage_full"))
check("a smaller one does", isinstance(rpc(carol, "files_reserve", b_full, "photo", "small.heic", "image/heic", 1, 1, None, 1_000_000, 100_000), dict))
check("someone else's space is their own", isinstance(rpc(olivia, "files_reserve", raw_booking(olivia, bea), "photo", "o.heic", "image/heic", 1, 1, None, 1_000, 100), dict))
rpc(carol, "files_remove", r_ok["file_id"])
check("removing the big one gives the room back", isinstance(rpc(carol, "files_reserve", b_full, "photo", "again.heic", "image/heic", 1, 1, None, 6_000_000, 1_000_000), dict))

# Four phones at once, room for one.
racer = new_user("racer-r", "Racer")
b_two = raw_booking(racer, alice)
set_files_setting(quota_gb_individual=1, max_photo_mb=1000)
outs = []


def worker(n):
    outs.append(rpc(racer, "files_reserve", b_two, "photo", f"race{n}.heic", "image/heic", 1, 1, None, 600_000_000, 1_000_000))


threads = [threading.Thread(target=worker, args=(n,)) for n in range(4)]
for t_ in threads:
    t_.start()
for t_ in threads:
    t_.join()
check("four at once, room for one: exactly one gets it", sum(isinstance(o, dict) for o in outs) == 1 and sum(err(o, "storage_full") for o in outs) == 3, outs)
check("and the space is counted once", usage(racer) == 601_000_000)
set_files_setting(quota_gb_individual=25, max_photo_mb=100)

# =============================================================================
print("\n[a company's files]")
b_acme = raw_booking(ORG, alice, assigned=cal)
for who, name, ok in [(olivia, "the Owner", True), (dee, "an Admin", True), (mia, "a Manager", True), (cal, "the Creator it is assigned to", True),
                      (kim, "a Creator it isn't assigned to", False), (vee, "a Viewer", False), (stranger, "a stranger", False)]:
    got = rpc(who, "files_reserve", b_acme, "photo", "co.heic", "image/heic", 1, 1, None, 1_000, 100)
    check(f"at a company, {name} {'can' if ok else 'can not'} add files", isinstance(got, dict) if ok else err(got, "not_found"), got)
check("a company's files count against the company, not the person", usage(ORG) == 4 * 1_100 and usage(cal) == 0)
check("the company's allowance is per billed seat", one("select files_owner_allowance_bytes(%s)", (ORG,)) == 250_000_000_000)
a.execute("delete from delivery_files where booking_id = %s", (b_acme,))
check("who can see the company's figures", rpc(olivia, "files_storage_usage", ORG)["allowance_bytes"] == 250_000_000_000
      and rpc(dee, "files_storage_usage", ORG)["used_bytes"] is not None)
check("not a stranger", err(rpc(stranger, "files_storage_usage", ORG), "not_found"))
check("a person sees their own", rpc(carol, "files_storage_usage", carol)["allowance_bytes"] == 25_000_000_000)
check("but not someone else's", err(rpc(carol, "files_storage_usage", olivia), "not_found"))
fa = make_file(cal, b_acme, "co2.heic", original=2_000, preview=200)
check("the assigned creator finishes and delivers", fa["finalized"]["accepted"] and isinstance(rpc(cal, "files_deliver", b_acme), dict))
check("it shows in the company's activity log", one("select count(*) from activity_log where organization_id = %s and action = 'files.delivered'", (ORG,)) == 1)
check("a viewer can't see client work", err(rpc(vee, "list_booking_files", b_acme), "not_found"))
check("or open its bytes", not can_see(vee, fa["preview_path"]) and not can_see(kim, fa["preview_path"]))
check("the booking's client can see the preview", can_see(alice, fa["preview_path"]) and not can_see(alice, fa["original_path"]))
check("a manager can open it", can_see(mia, fa["original_path"]))

# =============================================================================
print("\n[when it ends]")
dlv0 = one("select id from deliveries where booking_id = %s and sequence = 0", (b1,))
check("service only", err(sql_as(carol, "select files_expire_due()"), "permission denied") and err(sql_as(None, "select files_expire_due()", role="anon"), "permission denied"))
check("nothing is due yet", svc("files_expire_due")["expired"] == 0)
a.execute("update deliveries set expires_at = now() + interval '6 days' where id = %s", (dlv0,))
w1 = svc("files_expire_due")
check("a week out, a warning goes to the client who has unsaved files", w1["warned"] >= 1 and pushes(alice, "files_expiring", b1) == 1, w1)
check("it says how many days, and how many are unsaved", rows("select data ->> 'days', data ->> 'unsaved', data ->> 'total', data ->> 'balanceCents' from push_outbox where user_id = %s and kind = 'files_expiring' and booking_id = %s", (alice, b1)) == [("7", "1", "2", "0")])
svc("files_expire_due")
check("the same warning isn't sent twice", pushes(alice, "files_expiring", b1) == 1)
a.execute("update deliveries set expires_at = now() + interval '20 hours' where id = %s", (dlv0,))
svc("files_expire_due")
check("a day out, another", pushes(alice, "files_expiring", b1) == 2)
rpc(alice, "files_mark_saved", res2["file_id"])
a.execute("update deliveries set expires_at = now() + interval '3 hours' where id = %s", (dlv0,))
check("with everything saved, no more warnings", (svc("files_expire_due"), pushes(alice, "files_expiring", b1))[1] == 2)

a.execute("update deliveries set expires_at = now() - interval '1 minute' where id = %s", (dlv0,))
space_before = usage(carol)
ex = svc("files_expire_due")
check("the time is up: it ends", ex["expired"] >= 1 and one("select state from deliveries where id = %s", (dlv0,)) == "expired")
check("its files are expired and their bytes queued", rows("select status from delivery_files where delivery_id = %s and status <> 'removed' order by position", (dlv0,)) == [("expired",), ("expired",)]
      and one("select count(*) from storage_purge where path in (%s,%s)", (orig_path, prev_path)) == 2)
check("their space is free", usage(carol) == space_before - 12_800_000 - 5_500_000, (space_before, usage(carol)))
check("the conversation says so", counts(b1, "files_expired") == 1)
check("the creator is told, with how many were saved", rows("select data ->> 'saved', data ->> 'total' from push_outbox where user_id = %s and kind = 'files_expired' and booking_id = %s", (carol, b1)) == [("2", "2")])
check("the client isn't sent the creator's note", pushes(alice, "files_expired", b1) == 0)
check("running it again does nothing", svc("files_expire_due")["expired"] == 0 and counts(b1, "files_expired") == 1)
check("the client can no longer open them", not can_see(alice, prev_path) and not can_see(alice, orig_path))
check("nor can the creator", not can_see(carol, orig_path))
cl = rpc(alice, "list_booking_files", b1)["deliveries"]
d_exp = [d for d in cl if d["sequence"] == 0][0]
check("the client's list says it ended, with no paths", d_exp["state"] == "expired" and d_exp["originals_open"] is False
      and all(f["original_path"] is None for f in d_exp["files"]) and all(f["status"] == "expired" for f in d_exp["files"]), d_exp)
check("saving after the end is refused", err(rpc(alice, "files_mark_saved", fid), "originals_locked") or err(rpc(alice, "files_mark_saved", fid), "not_found"))
check("a revision after the end is still possible (nothing is owed)", rpc(carol, "list_booking_files", b1)["can_send_revision"] is True)
check("the other deliveries are not touched", one("select state from deliveries where booking_id = %s and sequence = 1", (b1,)) == "delivered")

print("\n[tidying up]")
b_old = raw_booking(carol, bea)
old = make_file(carol, b_old, "old.heic", original=1_000_000, preview=100_000)
a.execute("update deliveries set created_at = now() - interval '8 days' where booking_id = %s", (b_old,))
tidy = svc("files_expire_due")
check("a draft nobody delivered is removed after a week", tidy["drafts_removed"] >= 1 and one("select count(*) from deliveries where booking_id = %s", (b_old,)) == 0)
check("its files' bytes are queued for deletion", one("select count(*) from storage_purge where path in (%s,%s)", (old["original_path"], old["preview_path"])) == 2)
b_up = raw_booking(carol, bea)
stuck = rpc(carol, "files_reserve", b_up, "photo", "stuck.heic", "image/heic", 1, 1, None, 1_000_000, 100_000)
a.execute("update delivery_files set created_at = now() - interval '25 hours' where id = %s", (stuck["file_id"],))
check("an upload that never finished gives its space back after a day", svc("files_expire_due")["uploads_lapsed"] >= 1 and status_of(stuck["file_id"]) == "removed")
check("and its objects are queued", one("select count(*) from storage_purge where path = %s", (stuck["original_path"],)) == 1)

print("\n[purging bytes]")
pending = svc("files_purge_pending", 1000)
check("the job is told what to delete", isinstance(pending, list) and orig_path in pending and prev_path in pending, pending)
check("a limit is respected", len(svc("files_purge_pending", 3)) == 3)
check("only the server can ask", err(sql_as(carol, "select files_purge_pending(10)"), "permission denied") and err(sql_as(carol, "select files_purge_done(%s)", ([orig_path],)), "permission denied"))
n_before = one("select count(*) from storage_purge")
check("done paths are forgotten", svc("files_purge_done", [orig_path, prev_path]) == 2 and one("select count(*) from storage_purge") == n_before - 2)
check("done twice is harmless", svc("files_purge_done", [orig_path]) == 0)

print("\n[deleting things leaves bytes to purge]")
b_del = raw_booking(carol, bea)
dd = make_file(carol, b_del, "gone.heic", original=1_000_000, preview=100_000)
a.execute("delete from bookings where id = %s", (b_del,))
check("deleting a booking queues its files' bytes", one("select count(*) from storage_purge where path in (%s,%s)", (dd["original_path"], dd["preview_path"])) == 2
      and one("select count(*) from delivery_files where booking_id = %s", (b_del,)) == 0)
leaver = new_user("leaver-x", "Leaver")
connect_account(leaver)
b_lv = raw_booking(leaver, bea)
lv = make_file(leaver, b_lv, "lv.heic", original=1_000_000, preview=100_000)
a.execute("delete from bookings where creator_id = %s", (leaver,))
a.execute("delete from creator_profiles where id = %s", (leaver,))
check("so does deleting a profile", one("select count(*) from storage_purge where path in (%s,%s)", (lv["original_path"], lv["preview_path"])) == 2)

print("\n[the notification wording, and the old receipt note still works]")
check("the new kinds are in the push categories", [one("select push_category(%s)", (k,)) for k in ("files_delivered", "files_expiring", "files_expired")] == ["bookings"] * 3)
b_cl = raw_booking(carol, bea, delivery_url="https://files.example.com/final")
a.execute("update bookings set receipt_confirmed_at = now() where id = %s", (b_cl,))
check("a link delivery still tells the creator when it is confirmed", pushes(carol, "receipt_confirmed", b_cl) == 1)

# =============================================================================
print("\n[what the app decodes]")
b_rows = raw_booking(carol, alice)
rr = make_file(carol, b_rows, "shape.heic", original=2_000_000, preview=200_000)
vid = make_file(carol, b_rows, "clip.mov", kind="video", ctype="video/quicktime", original=40_000_000, preview=9_000_000)
rpc(carol, "files_deliver", b_rows)
rpc(alice, "list_booking_files", b_rows)
pay_balance(b_rows, alice)
rpc(alice, "files_mark_saved", rr["file_id"])
rev_shape = make_file(carol, b_rows, "fix.heic", original=1_000_000, preview=100_000)
reserve_shape = rpc(carol, "files_reserve", b_rows, "photo", "next.heic", "image/heic", 10, 10, None, 1_000, 100)
actual = {
    "config": one("select files_config()"),
    "reserve": reserve_shape,
    "finalize": rev_shape["finalized"],
    "refusal": liar,
    "creator_list": rpc(carol, "list_booking_files", b_rows),
    "client_list": rpc(alice, "list_booking_files", b_rows),
    "usage": rpc(carol, "files_storage_usage", carol),
    "saved": rpc(alice, "files_mark_saved", vid["file_id"]),
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
