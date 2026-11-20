#!/usr/bin/env python3
"""Provision the 2 temporary Alpha admin test accounts (vinhadmin -> Vinh, thaiadmin -> Thái) on Supabase.

Reads credentials strictly from local .env (NEVER prints passwords or tokens).
Staging exception per Owner (2026-11-19): pre-confirmed test accounts for alpha verification only;
must be removed before commercial launch (production enforces 100% Gmail verification).
"""

from __future__ import annotations

import json
import pathlib
import sys
import urllib.error
import urllib.parse
import urllib.request

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
ENV_PATH = REPO_ROOT / ".env"

ALPHA_USERS = [
    {
        "username": "vinhadmin",
        "email": "vinhadmin@dr7-alpha.local",
        "display_name": "Vinh",
        "character_id": "drum",
        "env_password_key": "USER_1",
        "spawn_x": 560.0,
    },
    {
        "username": "thaiadmin",
        "email": "thaiadmin@dr7-alpha.local",
        "display_name": "Thái",
        "character_id": "drum",
        "env_password_key": "USER_2",
        "spawn_x": 760.0,
    },
]


def load_env(path: pathlib.Path) -> dict[str, str]:
    env: dict[str, str] = {}
    if not path.is_file():
        raise FileNotFoundError(f"Missing {path}")
    for line in path.read_text(encoding="utf-8").splitlines():
        s = line.strip()
        if not s or s.startswith("#") or "=" not in s:
            continue
        k, v = s.split("=", 1)
        env[k.strip()] = v.strip().strip('"').strip("'")
    return env


def supabase_base_url(raw_url: str) -> str:
    p = urllib.parse.urlparse(raw_url.strip())
    if not p.scheme or not p.netloc:
        raise ValueError("Invalid API_URL in .env")
    return f"{p.scheme}://{p.netloc}"


def http_json(method: str, url: str, headers: dict[str, str], body: dict | None = None) -> tuple[int, dict]:
    data = json.dumps(body).encode("utf-8") if body is not None else None
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            raw = resp.read().decode("utf-8", errors="replace")
            return resp.status, (json.loads(raw) if raw.strip() else {})
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode("utf-8", errors="replace")
        try:
            parsed = json.loads(raw)
        except Exception:
            parsed = {"raw": raw[:200]}
        return exc.code, parsed


def extract_user_password(raw_value: str, expected_username: str) -> str:
    """Support both '<username>_<password>' and plain '<password>' formats in local .env."""
    prefix = f"{expected_username}_"
    if raw_value.lower().startswith(prefix.lower()):
        return raw_value[len(prefix):]
    return raw_value


def main() -> int:
    env = load_env(ENV_PATH)
    base = supabase_base_url(env["API_URL"])
    sr = env["service_role"]
    anon = env["anon_public"]

    admin_headers = {
        "apikey": sr,
        "Authorization": f"Bearer {sr}",
        "Content-Type": "application/json",
    }
    anon_headers = {
        "apikey": anon,
        "Content-Type": "application/json",
    }

    st, listing = http_json("GET", f"{base}/auth/v1/admin/users?page=1&per_page=100", admin_headers)
    if st != 200:
        print(f"[FAIL] Cannot list Supabase users: HTTP {st}", file=sys.stderr)
        return 1
    by_email = {
        str(u.get("email", "")).lower(): u
        for u in (listing.get("users") or [])
        if isinstance(u, dict)
    }

    for spec in ALPHA_USERS:
        raw_env_val = env.get(spec["env_password_key"], "")
        pwd = extract_user_password(raw_env_val, spec["username"])
        if not pwd:
            print(f"[FAIL] Missing {spec['env_password_key']} in .env", file=sys.stderr)
            return 1
        meta = {
            "username": spec["username"],
            "display_name": spec["display_name"],
            "character_id": spec["character_id"],
            "spawn_x": spec["spawn_x"],
            "role": "alpha_admin_test",
            "alpha_staging_exception": True,
        }
        existing = by_email.get(spec["email"].lower())
        if existing:
            uid = existing["id"]
            st_u, resp_u = http_json(
                "PUT",
                f"{base}/auth/v1/admin/users/{uid}",
                admin_headers,
                {
                    "password": pwd,
                    "email_confirm": True,
                    "user_metadata": meta,
                },
            )
            if st_u not in (200, 201):
                print(f"[FAIL] Update {spec['username']} failed: HTTP {st_u} {resp_u.get('msg', '')}", file=sys.stderr)
                return 1
            print(f"[OK] Updated Supabase alpha user: username={spec['username']} display_name={spec['display_name']} id={uid}")
        else:
            st_c, resp_c = http_json(
                "POST",
                f"{base}/auth/v1/admin/users",
                admin_headers,
                {
                    "email": spec["email"],
                    "password": pwd,
                    "email_confirm": True,
                    "user_metadata": meta,
                },
            )
            if st_c not in (200, 201):
                print(f"[FAIL] Create {spec['username']} failed: HTTP {st_c} {resp_c.get('msg', '')}", file=sys.stderr)
                return 1
            uid = resp_c.get("id", "")
            print(f"[OK] Created Supabase alpha user: username={spec['username']} display_name={spec['display_name']} id={uid}")

        # Verify password login via Supabase GoTrue token endpoint
        st_l, resp_l = http_json(
            "POST",
            f"{base}/auth/v1/token?grant_type=password",
            anon_headers,
            {"email": spec["email"], "password": pwd},
        )
        if st_l != 200 or not resp_l.get("access_token"):
            print(f"[FAIL] Login verification failed for {spec['username']}: HTTP {st_l}", file=sys.stderr)
            return 1
        user_meta = (resp_l.get("user") or {}).get("user_metadata") or {}
        print(
            f"[OK] Verified Supabase password login: username={spec['username']} "
            f"display_name={user_meta.get('display_name')} character_id={user_meta.get('character_id')} jwt_present=True"
        )

    # Verify wrong password is strictly rejected
    st_bad, _ = http_json(
        "POST",
        f"{base}/auth/v1/token?grant_type=password",
        anon_headers,
        {"email": ALPHA_USERS[0]["email"], "password": "definitely-wrong-password-123"},
    )
    if st_bad == 200:
        print("[FAIL] Wrong password unexpectedly succeeded!", file=sys.stderr)
        return 1
    print(f"[OK] Verified wrong password rejected with HTTP {st_bad}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
