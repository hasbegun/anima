#!/usr/bin/env python3
"""
Bootstrap ThunderID with tenants, resource servers, and roles.

Run once after ThunderID is up:

    python bootstrap/bootstrap.py

The script authenticates as the admin user via the OAuth2 flow,
then uses the management APIs to create:

  1. Organization units (tenants)          -- via POST /import
  2. Resource servers with resources       -- via POST /import
  3. Actions on each resource (scopes)     -- via REST API
  4. Roles with permission assignments     -- via POST /import

Re-running is safe: imports use upsert, and actions/roles are
skipped when they already exist.

Environment variables
---------------------
THUNDERID_URL       ThunderID base URL  (default: https://localhost:8090)
ADMIN_USERNAME      Admin username      (default: admin)
ADMIN_PASSWORD      Admin password      (required)
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
ADMIN_USERNAME = os.getenv("ADMIN_USERNAME", "admin")
ADMIN_PASSWORD = os.getenv("ADMIN_PASSWORD", "")


def _load_yaml(name: str) -> dict:
    with open(CONFIG_DIR / name) as f:
        return yaml.safe_load(f)


_CONFLICT_CODES = {"OU-1004", "RES-1004", "ROL-1004"}


def _import_yaml(client: httpx.Client, token: str, content: str, label: str) -> bool:
    """POST YAML content to the import API.  Returns True on full success.

    Name-conflict errors (resources already exist) are treated as
    successful no-ops so the script stays idempotent.
    """
    r = client.post(
        f"{THUNDERID_URL}/import",
        headers={"Authorization": f"Bearer {token}"},
        json={
            "content": content,
            "dryRun": False,
            "options": {"upsert": True, "continueOnError": True, "target": "runtime"},
        },
    )
    data = r.json()
    ok = True
    for item in data.get("results", []):
        name = item.get("resourceName", "?")
        op = item.get("operation", "?")
        code = item.get("code", "")
        if item.get("status") == "success":
            print(f"  + {label}: {name} ({op})")
        elif code in _CONFLICT_CODES:
            print(f"  - {label}: {name} (exists)")
        else:
            print(f"  ! {label}: {name} FAILED [{code}] {item.get('message')}")
            ok = False
    return ok


# -- Helpers ----------------------------------------------------------------

def _get_map(client: httpx.Client, token: str, path: str, key_field: str, list_field: str) -> dict[str, dict]:
    """Fetch a paginated list and return a dict keyed by key_field."""
    r = client.get(f"{THUNDERID_URL}/{path}", headers={"Authorization": f"Bearer {token}"})
    return {item[key_field]: item for item in r.json().get(list_field, [])}


# -- Tenants ---------------------------------------------------------------

def create_tenants(client: httpx.Client, token: str) -> bool:
    config = _load_yaml("tenants.yaml")
    docs = []
    for t in config["tenants"]:
        docs.append(
            f"resource_type: organization_unit\n"
            f"handle: {t['handle']}\n"
            f"name: {t['name']}\n"
            f"description: {t.get('description', '')}\n"
        )
    return _import_yaml(client, token, "---\n".join(docs), "tenant")


# -- Resource Servers -------------------------------------------------------

def _parse_scopes(scopes: list[dict]) -> dict[str, list[dict]]:
    """Group scopes by resource: {group: [{action, description}, ...]}."""
    groups: dict[str, list[dict]] = {}
    for scope in scopes:
        parts = scope["name"].split(":", 1)
        group = parts[0]
        action = parts[1] if len(parts) > 1 else group
        groups.setdefault(group, []).append({
            "action": action,
            "description": scope.get("description", action),
        })
    return groups


def create_resource_servers(client: httpx.Client, token: str) -> bool:
    """Create resource servers, resources (groups), and actions (scopes)."""
    config = _load_yaml("resource-servers.yaml")
    headers = {"Authorization": f"Bearer {token}"}
    ok = True

    # Step 1: Import resource servers with their top-level resources
    docs = []
    for rs in config["resource_servers"]:
        groups = _parse_scopes(rs["scopes"])
        resources = [
            {"name": g.replace("_", " ").title(), "handle": g, "description": f"{g} resources"}
            for g in groups
        ]
        doc = {
            "resource_type": "resource_server",
            "name": rs["name"],
            "description": rs["name"],
            "identifier": rs["identifier"],
            "ouHandle": rs.get("tenant", "default"),
        }
        if resources:
            doc["resources"] = resources
        docs.append(yaml.dump(doc, default_flow_style=False, sort_keys=False))

    if not _import_yaml(client, token, "---\n".join(docs), "resource-server"):
        ok = False

    # Step 2: Create actions on each resource via REST API
    rs_map = _get_map(client, token, "resource-servers", "identifier", "resourceServers")

    for rs in config["resource_servers"]:
        rs_entry = rs_map.get(rs["identifier"])
        if not rs_entry:
            print(f"  ! resource server not found: {rs['identifier']}")
            ok = False
            continue

        rs_id = rs_entry["id"]
        groups = _parse_scopes(rs["scopes"])

        # Get existing resources to find their IDs
        r = client.get(f"{THUNDERID_URL}/resource-servers/{rs_id}/resources", headers=headers)
        resource_map = {res["handle"]: res["id"] for res in r.json().get("resources", [])}

        for group, actions in groups.items():
            resource_id = resource_map.get(group)
            if not resource_id:
                print(f"  ! resource '{group}' not found in {rs['name']}")
                ok = False
                continue

            # Get existing actions to skip duplicates
            r = client.get(
                f"{THUNDERID_URL}/resource-servers/{rs_id}/resources/{resource_id}/actions",
                headers=headers,
            )
            existing = {a["handle"] for a in r.json().get("actions", [])}

            for act in actions:
                if act["action"] in existing:
                    print(f"  - action: {group}:{act['action']} (exists)")
                    continue
                r = client.post(
                    f"{THUNDERID_URL}/resource-servers/{rs_id}/resources/{resource_id}/actions",
                    headers=headers,
                    json={"name": act["description"], "handle": act["action"], "description": act["description"]},
                )
                if r.status_code in (200, 201):
                    print(f"  + action: {group}:{act['action']}")
                else:
                    msg = r.json().get("message", r.text[:100])
                    print(f"  ! action: {group}:{act['action']} FAILED {msg}")
                    ok = False

    return ok


# -- Roles ------------------------------------------------------------------

def create_roles(client: httpx.Client, token: str) -> bool:
    """Create roles with permission assignments via the import API.

    The import YAML format for roles requires the resource server UUID
    (``resourceServerId``), so we must look it up first.
    """
    config = _load_yaml("roles.yaml")
    rs_map = _get_map(client, token, "resource-servers", "identifier", "resourceServers")
    ok = True

    docs = []
    for role_cfg in config["roles"]:
        rs_id = rs_map.get(role_cfg.get("resource_server", ""), {}).get("id")
        if not rs_id:
            print(f"  ! role {role_cfg['name']}: resource server '{role_cfg.get('resource_server')}' not found")
            ok = False
            continue

        doc = {
            "resource_type": "role",
            "name": role_cfg["name"],
            "ouHandle": role_cfg["tenant"],
            "permissions": [{
                "resourceServerId": rs_id,
                "permissions": role_cfg.get("scopes", []),
            }],
        }
        docs.append(yaml.dump(doc, default_flow_style=False, sort_keys=False))

    if docs:
        if not _import_yaml(client, token, "---\n".join(docs), "role"):
            ok = False

    return ok


# -- Main -------------------------------------------------------------------

def main() -> int:
    if not ADMIN_PASSWORD:
        print("Error: Set ADMIN_PASSWORD environment variable")
        return 1

    print("=== ThunderID Bootstrap ===")
    print(f"  URL: {THUNDERID_URL}")
    print(f"  User: {ADMIN_USERNAME}")
    print()

    token = get_admin_token(THUNDERID_URL, ADMIN_USERNAME, ADMIN_PASSWORD)
    client = httpx.Client(verify=False, timeout=30)
    all_ok = True

    print("--- Tenants ---")
    if not create_tenants(client, token):
        all_ok = False

    print("\n--- Resource Servers ---")
    if not create_resource_servers(client, token):
        all_ok = False

    print("\n--- Roles ---")
    if not create_roles(client, token):
        all_ok = False

    client.close()
    print()
    if all_ok:
        print("=== Bootstrap complete ===")
        return 0
    else:
        print("=== Bootstrap completed with errors ===")
        return 1


if __name__ == "__main__":
    sys.exit(main())
