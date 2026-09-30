#!/usr/bin/env python3
"""End-to-end test of the deployed `admin-users` Edge Function + Auth rules.

Creates throwaway users (prefixed `e2e_`), exercises every action through the
real HTTP APIs, and deletes everything it created, even on failure.

Keys come ONLY from environment variables (never hard-code or commit them):
  SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY, SUPABASE_SERVICE_ROLE_KEY

Convenient runner (fetches the keys with your CLI login, keeps them in memory):
  supabase/tests/e2e/run_admin_users_e2e.sh
"""

import json
import os
import secrets
import sys
import urllib.error
import urllib.request

URL = os.environ["SUPABASE_URL"].rstrip("/")
PUBLISHABLE = os.environ["SUPABASE_PUBLISHABLE_KEY"]
SERVICE = os.environ["SUPABASE_SERVICE_ROLE_KEY"]
DOMAIN = "users.hisaably.invalid"
RUN = secrets.token_hex(3)

created_ids: list[str] = []
passed = 0


def call(method, path, body=None, *, key=PUBLISHABLE, token=None, extra=None):
    headers = {"apikey": key, "Content-Type": "application/json"}
    headers["Authorization"] = f"Bearer {token or key}"
    headers.update(extra or {})
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(URL + path, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            raw = resp.read()
            return resp.status, (json.loads(raw) if raw else None)
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            return e.code, json.loads(raw)
        except ValueError:
            return e.code, raw.decode(errors="replace")


def check(name, condition, detail=""):
    global passed
    if not condition:
        raise AssertionError(f"FAIL {name} {detail}")
    passed += 1
    print(f"  ok  {name}")


def login(username, password):
    status, body = call(
        "POST", "/auth/v1/token?grant_type=password",
        {"email": f"{username}@{DOMAIN}", "password": password},
    )
    return status, (body or {}).get("access_token") if isinstance(body, dict) else None


def admin_fn(token, payload):
    return call("POST", "/functions/v1/admin-users", payload, token=token)


def main():
    sa_user, sa_pass = f"e2e_sa_{RUN}", secrets.token_urlsafe(16)
    u_user, u_pass = f"e2e_u_{RUN}", secrets.token_urlsafe(16)

    # Setup: a throwaway Super Admin (created with the service key, then promoted).
    status, body = call(
        "POST", "/auth/v1/admin/users",
        {"email": f"{sa_user}@{DOMAIN}", "password": sa_pass, "email_confirm": True,
         "user_metadata": {"username": sa_user, "name": "E2E Admin"}},
        key=SERVICE,
    )
    assert status == 200, f"setup create SA: {status} {body}"
    sa_id = body["id"]
    created_ids.append(sa_id)
    status, _ = call(
        "PATCH", f"/rest/v1/profiles?id=eq.{sa_id}", {"role": "SUPER_ADMIN"},
        key=SERVICE, extra={"Prefer": "return=minimal"},
    )
    assert status in (200, 204), f"setup promote SA: {status}"

    status, sa_token = login(sa_user, sa_pass)
    check("super admin can log in with username", status == 200 and sa_token)

    # Unauthenticated / anon callers are rejected.
    status, body = call("POST", "/functions/v1/admin-users", {"action": "create_user"})
    check("anon call rejected", status == 401, body)

    # create_user + validation + uniqueness
    status, body = admin_fn(sa_token, {"action": "create_user", "name": "E2E User",
                                       "username": u_user.upper(), "password": u_pass})
    check("create_user", status == 200 and body["user"]["username"] == u_user, body)
    u_id = body["user"]["id"]
    created_ids.append(u_id)
    check("new user is USER/ACTIVE", body["user"]["role"] == "USER" and body["user"]["status"] == "ACTIVE")

    status, body = admin_fn(sa_token, {"action": "create_user", "name": "Dup",
                                       "username": u_user, "password": u_pass})
    check("duplicate username rejected", status == 409 and body["error"]["code"] == "USERNAME_TAKEN", body)

    status, body = admin_fn(sa_token, {"action": "create_user", "name": "Bad",
                                       "username": "a b", "password": u_pass})
    check("invalid username rejected", status == 400, body)

    status, body = admin_fn(sa_token, {"action": "create_user", "name": "Short",
                                       "username": f"e2e_s_{RUN}", "password": "short"})
    check("short password rejected", status == 400, body)

    status, u_token = login(u_user, u_pass)
    check("new user can log in", status == 200 and u_token)

    # A normal user cannot use the admin function.
    status, body = admin_fn(u_token, {"action": "delete_user", "user_id": sa_id})
    check("non-admin forbidden", status == 403 and body["error"]["code"] == "FORBIDDEN", body)

    # A normal user cannot promote themselves through the Data API.
    status, body = call("PATCH", f"/rest/v1/profiles?id=eq.{u_id}", {"role": "SUPER_ADMIN"},
                        token=u_token, extra={"Prefer": "return=representation"})
    check("self-promotion via REST blocked", status in (401, 403), f"{status} {body}")

    # reset_password: old password stops working, new one works.
    new_pass = secrets.token_urlsafe(16)
    status, body = admin_fn(sa_token, {"action": "reset_password", "user_id": u_id, "password": new_pass})
    check("reset_password", status == 200, body)
    check("old password rejected", login(u_user, u_pass)[0] == 400)
    status, u_token = login(u_user, new_pass)
    check("new password works", status == 200 and u_token)

    # disable_user: login blocked, existing token can't read data.
    status, body = admin_fn(sa_token, {"action": "disable_user", "user_id": u_id})
    check("disable_user", status == 200, body)
    check("disabled user cannot log in", login(u_user, new_pass)[0] in (400, 403))
    status, body = call("POST", "/rest/v1/rpc/get_dashboard", {}, token=u_token)
    check("disabled user's old token blocked", status in (400, 401, 403), f"{status} {body}")

    status, body = admin_fn(sa_token, {"action": "enable_user", "user_id": u_id})
    check("enable_user", status == 200, body)
    check("re-enabled user can log in", login(u_user, new_pass)[0] == 200)

    # Self-protection.
    status, body = admin_fn(sa_token, {"action": "delete_user", "user_id": sa_id})
    check("cannot delete self", status == 403, body)
    status, body = admin_fn(sa_token, {"action": "disable_user", "user_id": sa_id})
    check("cannot disable self", status == 403, body)

    # delete_user: login fails afterwards; username becomes free again.
    status, body = admin_fn(sa_token, {"action": "delete_user", "user_id": u_id})
    check("delete_user", status == 200, body)
    created_ids.remove(u_id)
    check("deleted user cannot log in", login(u_user, new_pass)[0] == 400)
    status, body = admin_fn(sa_token, {"action": "delete_user", "user_id": u_id})
    check("deleting again -> 404", status == 404, body)


if __name__ == "__main__":
    ok = False
    try:
        main()
        ok = True
    except AssertionError as e:
        print(e)
    finally:
        for uid in created_ids:
            call("DELETE", f"/auth/v1/admin/users/{uid}", key=SERVICE)
        print(f"cleanup: deleted {len(created_ids)} test user(s)")
    print(f"{'E2E_OK' if ok else 'E2E_FAILED'}: {passed} checks passed")
    sys.exit(0 if ok else 1)
