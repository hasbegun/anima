#!/usr/bin/env python3
"""
Seed test users into ThunderID and assign roles.

Run after bootstrap.py:

    python bootstrap/seed_users.py

Users are created in the default organization unit via the import
API (which correctly populates attributes and credentials), then
assigned cross-OU roles as defined in ``config/users.yaml``.

Environment variables
---------------------
THUNDERID_URL       ThunderID base URL  (default: https://localhost:8090)
ADMIN_USERNAME      Admin username      (default: admin)
ADMIN_PASSWORD      Admin password      (required)
DEFAULT_PASSWORD    Password for seed users (default: SeedPass123!)
"""
from __future__ import annotations

import os
import sys
from pathlib import Path

import httpx
import yaml

from auth import get_admin_token

CONFIG_DIR = Path(__file__).resolve().parent / "config"
THUNDERID_URL = os.getenv("THUNDERID_URL", "https://localhost:8090")
THUNDERID_PUBLIC_URL = os.getenv("THUNDERID_PUBLIC_URL", "https://localhost:8090")
ADMIN_USERNAME = os.getenv("ADMIN_USERNAME", "admin")
ADMIN_PASSWORD = os.getenv("ADMIN_PASSWORD", "")
DEFAULT_PASSWORD = os.getenv("DEFAULT_PASSWORD", "SeedPass123!")


def _load_yaml(name: str) -> dict:
    with open(CONFIG_DIR / name) as f:
        return yaml.safe_load(f)


def _get_existing_users(client: httpx.Client, headers: dict) -> dict[str, str]:
    """Return {email: user_id} for all users that have an email attribute."""
    result: dict[str, str] = {}
    r = client.get(f"{THUNDERID_URL}/users", headers=headers)
    for u in r.json().get("users", []):
        uid = u["id"]
        # List endpoint may not include attributes; fetch details
        r2 = client.get(f"{THUNDERID_URL}/users/{uid}", headers=headers)
        email = (r2.json().get("attributes") or {}).get("email", "")
        if email:
            result[email] = uid
    return result


def main() -> int:
    if not ADMIN_PASSWORD:
        print("Error: Set ADMIN_PASSWORD environment variable")
        return 1

    print("=== Seed Users ===")
    print(f"  URL: {THUNDERID_URL}")
    print()

    token = get_admin_token(THUNDERID_URL, ADMIN_USERNAME, ADMIN_PASSWORD,
                            public_url=THUNDERID_PUBLIC_URL)
    client = httpx.Client(verify=False, timeout=30)
    headers = {"Authorization": f"Bearer {token}"}
    ok = True

    # Build role lookup: (ou_handle, role_name) -> role_id
    r = client.get(f"{THUNDERID_URL}/roles", headers=headers)
    roles_by_key: dict[tuple[str, str], str] = {}
    for role in r.json().get("roles", []):
        roles_by_key[(role.get("ouHandle", ""), role["name"])] = role["id"]

    # Get existing users
    existing = _get_existing_users(client, headers)

    config = _load_yaml("users.yaml")

    for assignment in config["user_assignments"]:
        email = assignment["email"]
        username = email.split("@")[0]

        # Create user via import API if not exists
        if email in existing:
            user_id = existing[email]
            print(f"  - user: {email} (exists)")
        else:
            yaml_content = yaml.dump({
                "resource_type": "user",
                "ouHandle": "default",
                "type": "Person",
                "attributes": {
                    "username": username,
                    "email": email,
                    "given_name": username.capitalize(),
                    "family_name": "User",
                },
                "credentials": {"password": DEFAULT_PASSWORD},
            }, default_flow_style=False, sort_keys=False)

            r = client.post(
                f"{THUNDERID_URL}/import",
                headers=headers,
                json={
                    "content": yaml_content,
                    "dryRun": False,
                    "options": {"upsert": True, "continueOnError": True, "target": "runtime"},
                },
            )
            data = r.json()
            result = (data.get("results") or [{}])[0]
            if result.get("status") == "success":
                user_id = result.get("resourceId", "")
                print(f"  + user: {email} (created)")
            elif result.get("code") in ("USR-1014", "USR-1015"):
                # Attribute conflict = user already exists with this email/username
                print(f"  - user: {email} (exists, conflict on import)")
                # Re-check existing users to find the ID
                existing = _get_existing_users(client, headers)
                user_id = existing.get(email, "")
                if not user_id:
                    print(f"    ! could not find existing user by email")
                    ok = False
                    continue
            else:
                code = result.get("code", "")
                msg = result.get("message", "")
                print(f"  ! user: {email} FAILED [{code}] {msg}")
                ok = False
                continue

        # Assign roles
        for tenant_cfg in assignment.get("tenants", []):
            tenant = tenant_cfg["tenant"]
            for role_name in tenant_cfg.get("roles", []):
                role_id = roles_by_key.get((tenant, role_name))
                if not role_id:
                    print(f"    ! role '{role_name}' in '{tenant}' not found")
                    ok = False
                    continue

                r = client.post(
                    f"{THUNDERID_URL}/roles/{role_id}/assignments/add",
                    headers=headers,
                    json={"assignments": [{"type": "user", "id": user_id}]},
                )
                if r.status_code == 204:
                    print(f"    + role: {role_name} @ {tenant}")
                elif r.status_code == 409 or "already" in r.text.lower():
                    print(f"    - role: {role_name} @ {tenant} (exists)")
                else:
                    msg = r.json().get("message", r.text[:100])
                    print(f"    ! role: {role_name} @ {tenant} FAILED {msg}")
                    ok = False

    client.close()
    print()
    if ok:
        print("=== Seed complete ===")
        return 0
    else:
        print("=== Seed completed with errors ===")
        return 1


if __name__ == "__main__":
    sys.exit(main())
