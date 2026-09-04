# Testing Guide

Comprehensive testing guide for the Identity Service built on ThunderID.

**Total tests:** 83 across 7 phases, covering infrastructure, bootstrap, agent identity, token flows, tenant server integration, operations, and security.

---

## Table of Contents

1. [Quick Start](#quick-start)
2. [Test Architecture](#test-architecture)
3. [Running Tests](#running-tests)
4. [Phase 1: ThunderID Setup (6 tests)](#phase-1-thunderid-setup-6-tests)
5. [Phase 2: Bootstrap (17 tests)](#phase-2-bootstrap-17-tests)
6. [Phase 3: Agent Identity (11 tests)](#phase-3-agent-identity-11-tests)
7. [Phase 4: End-to-End Integration (13 tests)](#phase-4-end-to-end-integration-13-tests)
8. [Phase 5: Tenant Server Integration (12 tests)](#phase-5-tenant-server-integration-12-tests)
9. [Phase 6: Operations (9 tests)](#phase-6-operations-9-tests)
10. [Phase 7: Quality Audit (15 tests)](#phase-7-quality-audit-15-tests)
11. [Test Infrastructure Details](#test-infrastructure-details)
12. [Troubleshooting](#troubleshooting)

---

## Quick Start

```bash
# Prerequisites: Docker and Docker Compose must be installed.
# ThunderID must be running and bootstrapped.
# ADMIN_PASSWORD must be set in .env or as an environment variable.

# Run all tests (Phases 1-5 in toolbox container):
ADMIN_PASSWORD=<pw> make test

# Run host-only tests (Phases 6-7, need docker compose access):
ADMIN_PASSWORD=<pw> make test-phase6
make test-phase7

# Run a single phase:
ADMIN_PASSWORD=<pw> make test-phase3
```

---

## Test Architecture

### Execution Environments

Tests run in two environments:

| Environment | Phases | Why |
| ------------- | -------- | ----- |
| **Toolbox container** | 1, 2, 3, 4, 5 | Access to ThunderID internal network, Python dependencies pre-installed |
| **Host machine** | 6, 7 | Needs `docker compose` CLI for log inspection, backup/restore, and access to project files for static checks |

The **toolbox** is a Docker container (`bootstrap/Dockerfile`) with Python 3.12, `httpx`, `pyyaml`, `pyjwt[crypto]`, `curl`, `jq`, and `bash`. It connects to ThunderID via Docker's internal network (`https://thunderid:8090`) and to the monitoring-api via `http://monitoring-api:9000`.

### Test Runner

`scripts/test-all.sh` orchestrates all phases sequentially. Phases 6-7 are skipped when running inside the toolbox (no Docker CLI available) and must be run separately on the host.

### Test Pattern

Every test script follows the same pattern:

```bash
run_test "test_id  description" \
    bash -c "command_that_returns_0_on_success"
```

- Exit code 0 = PASS, non-zero = FAIL
- Results are tallied and printed at the end
- The script exits with code 1 if any test fails

---

## Running Tests

### Full Suite

```bash
# Inside toolbox (Phases 1-5):
ADMIN_PASSWORD=<pw> make test

# Host-only phases (run separately):
ADMIN_PASSWORD=<pw> make test-phase6
make test-phase7
```

### Individual Phases

```bash
make test-phase1                          # No password needed
ADMIN_PASSWORD=<pw> make test-phase2
ADMIN_PASSWORD=<pw> make test-phase3
ADMIN_PASSWORD=<pw> make test-phase4
ADMIN_PASSWORD=<pw> make test-phase5
ADMIN_PASSWORD=<pw> make test-phase6      # Runs on host
make test-phase7                          # Runs on host, no password needed
```

### Direct Script Execution

```bash
# Inside toolbox container:
docker compose run --rm toolbox bash scripts/test-phase3.sh

# On host:
bash scripts/test-phase6.sh
bash scripts/test-phase7.sh
```

### Prerequisites

Before running tests, ensure:

1. ThunderID is running and healthy: `make status`
2. Bootstrap has been run: `ADMIN_PASSWORD=<pw> make bootstrap`
3. Users have been seeded: `ADMIN_PASSWORD=<pw> make seed`
4. Monitoring-API is running: `docker compose up -d monitoring-api`
5. `ADMIN_PASSWORD` environment variable is set (for Phases 2-6)

---

## Phase 1: ThunderID Setup (6 tests)

**Script:** `scripts/test-phase1.sh`
**Environment:** Toolbox container
**Prerequisites:** ThunderID and MailSlurper running

Verifies that the core infrastructure is up and responding.

| Test | Description | What It Checks |
| ------ | ------------- | ---------------- |
| 1.1 | Server responds | OIDC discovery endpoint returns valid JSON |
| 1.2 | OIDC discovery available | Response contains `issuer`, `token_endpoint`, `jwks_uri` fields |
| 1.3 | JWKS endpoint returns keys | `/oauth2/jwks` returns at least 1 RSA signing key |
| 1.4 | Admin console loads | `https://localhost:8090/console` returns HTTP 200/3xx |
| 1.5 | Login gate loads | `https://localhost:8090/gate` returns HTTP 200/3xx |
| 1.6 | MailSlurper Web UI responds | `http://mailslurper:4436` returns HTTP 200 |

### Example Output

```text
=== Phase 1: ThunderID Setup Tests ===

  PASS  1.1 Server responds
  PASS  1.2 OIDC discovery available
  PASS  1.3 JWKS endpoint returns keys
  PASS  1.4 Admin console loads
  PASS  1.5 Login gate loads
  PASS  1.6 MailSlurper Web UI responds

--- Results: 6/6 passed, 0 failed ---
=== All Phase 1 tests passed! ===
```

---

## Phase 2: Bootstrap (17 tests)

**Script:** `scripts/test-phase2.sh`
**Environment:** Toolbox container
**Prerequisites:** Bootstrap and seed completed

Verifies that all tenants, resource servers, roles, and users were created correctly.

| Test | Description | What It Checks |
| ------ | ------------- | ---------------- |
| 2.1 | Tenant 'monitoring-api' exists | Organization unit with handle `monitoring-api` in ThunderID |
| 2.2 | Tenant 'data-pipeline' exists | Organization unit with handle `data-pipeline` |
| 2.3 | Tenant 'deploy-tool' exists | Organization unit with handle `deploy-tool` |
| 2.4 | RS 'monitoring-api.internal' exists | Resource server with identifier `https://monitoring-api.internal` |
| 2.5 | RS 'data-pipeline.internal' exists | Resource server with identifier `https://data-pipeline.internal` |
| 2.6 | RS 'deploy-tool.internal' exists | Resource server with identifier `https://deploy-tool.internal` |
| 2.7 | Monitoring API has alerts:read action | The `alerts` resource under monitoring-api has a `read` action |
| 2.8 | At least 14 actions across RSes | Total actions across all 3 resource servers >= 14 (actually 14 scopes defined) |
| 2.9 | Role 'monitoring-admin' exists | Role in `monitoring-api` tenant with full monitoring scopes |
| 2.10 | Role 'pipeline-admin' exists | Role in `data-pipeline` tenant with full pipeline scopes |
| 2.11 | Role 'deploy-admin' exists | Role in `deploy-tool` tenant with full deployment scopes |
| 2.12 | At least 9 custom roles exist | 3 monitoring + 3 pipeline + 3 deploy-tool roles |
| 2.13 | Seed user 'alice@company.com' | User exists with email attribute set |
| 2.14 | Seed user 'bob@company.com' | User exists with email attribute set |
| 2.15 | Seed user 'sysadmin@company.com' | User exists with email attribute set |
| 2.16 | Bootstrap is idempotent | Re-running `bootstrap.py` succeeds without errors |
| 2.17 | Seed is idempotent | Re-running `seed_users.py` succeeds without errors |

### What Gets Created

**3 Tenants** (Organization Units):
- `monitoring-api` — Internal monitoring and alerting
- `data-pipeline` — ETL and data processing
- `deploy-tool` — Deployment and release management

**3 Resource Servers** with 14 total scopes:
- `https://monitoring-api.internal` — `alerts:read`, `alerts:write`, `alerts:delete`, `dashboards:read`, `dashboards:write`, `settings:manage`
- `https://data-pipeline.internal` — `pipelines:read`, `pipelines:run`, `pipelines:manage`, `data:read`
- `https://deploy-tool.internal` — `deployments:read`, `deployments:trigger`, `deployments:rollback`, `configs:manage`

**9 Roles:**
- monitoring-api: `monitoring-admin`, `monitoring-operator`, `monitoring-viewer`
- data-pipeline: `pipeline-admin`, `pipeline-engineer`, `pipeline-readonly`
- deploy-tool: `deploy-admin`, `deploy-operator`, `deploy-viewer`

**3 Seed Users:**
- `sysadmin@company.com` — monitoring-admin, pipeline-admin, deploy-admin
- `alice@company.com` — monitoring-operator, pipeline-engineer
- `bob@company.com` — monitoring-viewer

---

## Phase 3: Agent Identity (11 tests)

**Script:** `scripts/test-phase3.sh`
**Environment:** Toolbox container
**Prerequisites:** Bootstrap completed (creates agents and writes `agent-secrets.json`)

Verifies AI agent creation, OAuth2 client credentials flow, scope enforcement, and cross-agent isolation.

| Test | Description | What It Checks |
| ------ | ------------- | ---------------- |
| 3.1 | Agent 'alert-cleanup-agent' exists | Agent registered in ThunderID |
| 3.2 | Agent 'pipeline-scheduler-agent' exists | Agent registered in ThunderID |
| 3.3 | Agent 'monitoring-assistant' is delegated | Has `authorization_code` grant type, PKCE required, redirect URI set |
| 3.4 | Agent secrets file exists with 3 agents | `agent-secrets.json` has clientId + clientSecret for all 3 agents |
| 3.5 | Autonomous agent gets token via client_credentials | Token endpoint returns access_token with correct scopes |
| 3.6 | Agent token has correct JWT claims | Decoded JWT has correct `sub`, `aud`, `grant_type`, `jti`, `exp`, `scope` |
| 3.7 | Agent with wrong secret gets 401 | Invalid client_secret is rejected |
| 3.8 | Agent requesting disallowed scope gets downscoped | `alerts:delete` is removed (agent only has `alerts:read`, `alerts:write`) |
| 3.9 | Pipeline agent gets token with correct scopes | `pipelines:read pipelines:run` granted correctly |
| 3.10 | Delegated agent can also use client_credentials | `monitoring-assistant` (delegated mode) can still use CC flow |
| 3.11 | Bootstrap is idempotent with agents | Re-running bootstrap doesn't create duplicate agents |

### Agent Configuration

**3 Agents** defined in `bootstrap/config/agents.yaml`:

| Agent | Mode | Tenant | Scopes | Role |
| ------- | ------ | -------- | -------- | ------ |
| `alert-cleanup-agent` | Autonomous | monitoring-api | `alerts:read`, `alerts:write` | monitoring-operator |
| `pipeline-scheduler-agent` | Autonomous | data-pipeline | `pipelines:read`, `pipelines:run` | pipeline-engineer |
| `monitoring-assistant` | Delegated | monitoring-api | `alerts:read`, `dashboards:read` | *(none — inherits user's scopes)* |

### Token Request Example (tested by 3.5)

```bash
curl -X POST https://localhost:8090/oauth2/token \
  -u "$CLIENT_ID:$CLIENT_SECRET" \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -d 'grant_type=client_credentials&resource=https://monitoring-api.internal&scope=alerts:read alerts:write'
```

Response:
```json
{
  "access_token": "eyJhbG...",
  "token_type": "bearer",
  "expires_in": 3600,
  "scope": "alerts:read alerts:write"
}
```

### Decoded JWT Claims (tested by 3.6)

```json
{
  "aud": "https://monitoring-api.internal",
  "client_id": "ooxvbe9uMY2fRpqmifhogw",
  "exp": 1788333291,
  "grant_type": "client_credentials",
  "iat": 1788329691,
  "iss": "https://localhost:8090",
  "jti": "01a060c1-8971-7d39-adea-47dbc8ffc585",
  "nbf": 1788329691,
  "scope": "alerts:read alerts:write",
  "sub": "01a05bb5-becb-74ac-b5bd-7be2a7a34a60"
}
```

---

## Phase 4: End-to-End Integration (13 tests)

**Script:** `scripts/test-phase4.sh`
**Environment:** Toolbox container
**Prerequisites:** Bootstrap completed

Verifies the complete OAuth2 token lifecycle: issuance, offline JWKS verification, introspection, revocation, audience isolation, and negative cases.

| Test | Description | What It Checks |
| ------ | ------------- | ---------------- |
| 4.1 | Token verified offline via JWKS (PyJWT) | Full JWKS flow: fetch signing key, decode JWT, validate claims |
| 4.2 | Token audience matches RS identifier | Pipeline agent token has `aud: https://data-pipeline.internal` |
| 4.3 | JWKS verification rejects wrong audience | Monitoring token fails validation against pipeline audience |
| 4.4 | Token introspection returns active=true | `POST /oauth2/introspect` confirms token is active |
| 4.5 | Revoked token introspects as inactive | After `POST /oauth2/revoke`, introspection returns `active: false` |
| 4.6 | Revoked token still valid offline | Offline JWKS check passes (known trade-off — JWT is cryptographically valid until expiry) |
| 4.7 | No auth on management endpoint → 401 | `GET /roles` without token returns 401 |
| 4.8 | Malformed Bearer token → 401 | Invalid JWT string returns 401 |
| 4.9 | OIDC discovery lists all grant types | `client_credentials`, `authorization_code`, `refresh_token`, `token-exchange` all present |
| 4.10 | Introspection rejects unauthenticated | `POST /oauth2/introspect` without client auth returns 400/401 |
| 4.11 | Revocation rejects unauthenticated | `POST /oauth2/revoke` without client auth returns 400/401 |
| 4.12 | Cross-RS token isolation | Monitoring token cannot be verified against pipeline audience |
| 4.13 | Pipeline agent cannot get monitoring scopes | Cross-tenant scope request returns empty/no matching scopes |

### Key Concepts Tested

**Offline vs Online Verification:**
- **Offline (JWKS):** Fast, no network call after initial key fetch. Cannot detect revocation.
- **Online (Introspection):** Real-time check against ThunderID. Detects revocation but adds latency.
- Tests 4.5 and 4.6 demonstrate this trade-off explicitly.

**Audience Isolation:**
- Each resource server has a unique identifier (e.g., `https://monitoring-api.internal`)
- Tokens are issued with `aud` matching the requested resource
- A token for one resource server cannot be used at another (tests 4.3, 4.12)

---

## Phase 5: Tenant Server Integration (12 tests)

**Script:** `scripts/test-phase5.sh`
**Environment:** Toolbox container
**Prerequisites:** Bootstrap completed, monitoring-api running

Verifies the reference tenant server (monitoring-api) correctly enforces JWT authentication, scope-based authorization, and returns proper caller identity information.

| Test | Description | What It Checks |
| ------ | ------------- | ---------------- |
| 5.1 | No JWT → 401 | Request without Authorization header returns 401 with "Missing Authorization header" |
| 5.2 | Malformed JWT → 401 | Invalid token string returns 401 |
| 5.3 | Valid JWT, wrong audience → 401 | Pipeline token (aud=data-pipeline) rejected by monitoring-api (aud=monitoring-api) |
| 5.4 | Correct aud, missing scope → 403 | `DELETE /alerts/x` with only `alerts:read` scope returns 403 with detail showing required vs actual scopes |
| 5.5 | Correct aud, correct scope → 200 | `GET /alerts` with `alerts:read` returns alert data |
| 5.6 | Expired/invalid JWT → 401 | Tampered JWT signature rejected |
| 5.7 | Agent token → subject_type=agent | `/whoami` returns `subject_type: "agent"` for client_credentials token |
| 5.8 | Agent /whoami returns full identity | Scopes, client_id, is_delegated, acting_agent all correct |
| 5.9 | /health bypasses auth | No JWT needed for health endpoint |
| 5.10 | POST /alerts with write scope → 200 | Write operation succeeds with `alerts:write` scope |
| 5.11 | Pipeline agent rejected by monitoring API | Cross-tenant isolation enforced at the API level |
| 5.12 | Revoked token passes offline check | Known trade-off: JWKS-only verification cannot detect revocation |

### Monitoring API Endpoints

| Endpoint | Method | Required Scope | Auth |
| ---------- | -------- | --------------- | ------ |
| `/health` | GET | *(none)* | Public |
| `/alerts` | GET | `alerts:read` | JWT required |
| `/alerts` | POST | `alerts:write` | JWT required |
| `/alerts/{id}` | DELETE | `alerts:delete` | JWT required |
| `/whoami` | GET | *(any valid JWT)* | JWT required |
| `/docs` | GET | *(none)* | Public |

### Example: /whoami Response (tested by 5.7, 5.8)

```json
{
  "subject": "01a05bb5-becb-74ac-b5bd-7be2a7a34a60",
  "subject_type": "agent",
  "scopes": ["alerts:read", "alerts:write"],
  "client_id": "ooxvbe9uMY2fRpqmifhogw",
  "grant_type": "client_credentials",
  "is_delegated": false,
  "acting_agent": null
}
```

### Example: 403 Scope Denied (tested by 5.4)

```bash
curl -X DELETE -H "Authorization: Bearer $TOKEN" http://localhost:9100/alerts/x
```

```json
{
  "detail": "Requires scope: alerts:delete. You have: alerts:read"
}
```

---

## Phase 6: Operations (9 tests)

**Script:** `scripts/test-phase6.sh`
**Environment:** Host machine (needs `docker compose` CLI)
**Prerequisites:** Bootstrap completed, monitoring-api running

Verifies structured audit logging, CORS configuration, and backup/restore functionality.

| Test | Description | What It Checks |
| ------ | ------------- | ---------------- |
| 6.1 | Audit log: auth_denied is structured JSON | Log entry has `event`, `timestamp`, `service`, `decision`, `request_id`, `endpoint`, `method` |
| 6.2 | Audit log: auth_allowed has identity + timing | Log entry has `subject`, `subject_type`, `scopes`, `verify_ms`, `client_id` |
| 6.3 | Audit log: scope_denied shows required vs actual | Log entry has `required_scopes`, `actual_scopes`, `reason: insufficient_scope` |
| 6.4 | CORS preflight from allowed origin → 200 | OPTIONS request with `Origin: https://localhost:3000` returns 200 |
| 6.5 | CORS headers present for allowed origin | Response includes `Access-Control-Allow-Origin` and `Access-Control-Allow-Credentials` |
| 6.6 | CORS no allow-origin for disallowed origin | Request with `Origin: https://evil.com` does not get CORS headers |
| 6.7 | Backup script creates valid tarball | `backup-db.sh` produces a `.tar.gz` in `backups/` |
| 6.8 | Backup contains databases, certs, and secrets | Tarball contains 4 SQLite DBs, signing keys, and direct_auth_secret |
| 6.9 | Backup/restore round-trip preserves data | After restore, ThunderID is healthy and agent tokens still work |

### Audit Log Format (tested by 6.1-6.3)

Each log entry is a single JSON line written to stdout:

**auth_denied** (no token or invalid token):
```json
{
  "timestamp": "2026-09-01T12:00:00.000Z",
  "level": "info",
  "service": "monitoring-api",
  "event": "auth_denied",
  "request_id": "a1b2c3d4",
  "endpoint": "/alerts",
  "method": "GET",
  "decision": "denied",
  "reason": "missing_authorization_header",
  "ip": "172.31.0.5"
}
```

**auth_allowed** (valid token):
```json
{
  "timestamp": "2026-09-01T12:00:01.000Z",
  "level": "info",
  "service": "monitoring-api",
  "event": "auth_allowed",
  "request_id": "e5f6g7h8",
  "endpoint": "/alerts",
  "method": "GET",
  "decision": "allowed",
  "subject": "01a05bb5-becb-74ac-b5bd-7be2a7a34a60",
  "subject_type": "agent",
  "scopes": ["alerts:read"],
  "client_id": "ooxvbe9uMY2fRpqmifhogw",
  "grant_type": "client_credentials",
  "is_delegated": false,
  "acting_agent": null,
  "verify_ms": 12.3,
  "ip": "172.31.0.5"
}
```

**scope_denied** (valid token, insufficient scopes):
```json
{
  "timestamp": "2026-09-01T12:00:02.000Z",
  "level": "info",
  "service": "monitoring-api",
  "event": "scope_denied",
  "request_id": "i9j0k1l2",
  "endpoint": "/alerts/x",
  "method": "DELETE",
  "decision": "denied",
  "reason": "insufficient_scope",
  "required_scopes": ["alerts:delete"],
  "actual_scopes": ["alerts:read"],
  "subject": "01a05bb5-becb-74ac-b5bd-7be2a7a34a60",
  "subject_type": "agent",
  "ip": "172.31.0.5"
}
```

### Backup Contents (tested by 6.8)

| File | Description |
| ------ | ------------- |
| `configdb.db` | ThunderID configuration (tenants, resource servers, roles) |
| `entitydb.db` | Users, agents, credentials |
| `runtime_persistent.db` | Persistent runtime data |
| `runtime_transient.db` | Transient runtime data (sessions, auth flows) |
| `certs/signing.key` | JWT signing private key (RS256) |
| `certs/signing.cert` | JWT signing certificate |
| `certs/server.key` | TLS server private key |
| `certs/server.cert` | TLS server certificate |
| `certs/crypto.key` | Encryption key for stored secrets |
| `secrets/direct_auth_secret` | Direct API authentication secret |

---

## Phase 7: Quality Audit (15 tests)

**Script:** `scripts/test-phase7.sh`
**Environment:** Host machine
**Prerequisites:** Bootstrap completed, monitoring-api running

Verifies bug fixes from the quality audit (CallerIdentity.is_agent/is_human), subject_type consistency, and security checklist items.

| Test | Description | What It Checks |
| ------ | ------------- | ---------------- |
| 7.1 | Agent token → subject_type is 'agent' | `/whoami` returns `subject_type: "agent"` (inferred from grant_type) |
| 7.2 | JWT has no sub_type claim | ThunderID omits `sub_type` — our inference logic handles this |
| 7.3 | Agent token sub matches registered agentId | `sub` claim equals the agent's ID from `agent-secrets.json` |
| 7.4 | GET /alerts caller.subject_type == 'agent' | Consistency check across endpoint |
| 7.5 | POST /alerts caller.subject_type == 'agent' | Consistency check across endpoint |
| 7.6 | /whoami returns both grant_type and subject_type | Both fields present and correct |
| 7.7 | Explicit sub_type claim takes precedence | Unit test: 4 scenarios for CallerIdentity inference logic |
| 7.8 | .env is in .gitignore | Secrets not committed to git |
| 7.9 | setup-output.txt is in .gitignore | Admin password not committed |
| 7.10 | agent-secrets.json is in .gitignore | Client secrets not committed |
| 7.11 | ThunderID image pinned to specific version | No `latest` tag used — update this test after version upgrades |
| 7.12 | JWKS cache TTL configured | `cache_jwk_set=True`, `lifespan=3600` |
| 7.13 | CORS uses explicit origins, not wildcard | No `*` in allow_origins |
| 7.14 | Docker restart policies set | At least 3 services have restart policies |
| 7.15 | .env.example exists | Environment template for new developers |

### CallerIdentity Inference Logic (tested by 7.7)

Since ThunderID does not include a `sub_type` claim in JWTs, the `CallerIdentity` class infers the caller type:

```python
# Priority: explicit sub_type claim > grant_type inference > default "user"
explicit = claims.get("sub_type")
if explicit:
    self.subject_type = explicit          # Future-proof: honour if present
elif self.grant_type == "client_credentials":
    self.subject_type = "agent"           # Machine identity
else:
    self.subject_type = "user"            # Human identity
```

Test 7.7 validates all 4 scenarios as a unit test:

| Scenario | grant_type | sub_type | Result |
| ---------- | ----------- | ---------- | -------- |
| Agent (inferred) | `client_credentials` | *(absent)* | `"agent"` |
| User (inferred) | `authorization_code` | *(absent)* | `"user"` |
| Explicit override | `client_credentials` | `"service"` | `"service"` |
| Delegated agent | `authorization_code` | `"agent"` | `"agent"` |

---

## Test Infrastructure Details

### File Locations

```text
scripts/
├── test-all.sh          # Full suite runner (orchestrates phases 1-7)
├── test-phase1.sh       # ThunderID infrastructure
├── test-phase2.sh       # Bootstrap verification
├── test-phase3.sh       # Agent identity
├── test-phase4.sh       # End-to-end token flows
├── test-phase5.sh       # Tenant server integration
├── test-phase6.sh       # Operations (logging, CORS, backup)
├── test-phase7.sh       # Quality audit & security
├── test-api.sh          # Legacy smoke test (not called by test-all.sh)
├── backup-db.sh         # SQLite hot backup to tarball
├── restore-db.sh        # Full restore from backup tarball
└── upgrade.sh           # Automated ThunderID version upgrade & rollback
```

### Environment Variables

| Variable | Used By | Default | Description |
| ---------- | --------- | --------- | ------------- |
| `THUNDERID_URL` | Phases 1-7 | `https://localhost:8090` (toolbox: `https://thunderid:8090`) | ThunderID base URL |
| `THUNDERID_PUBLIC_URL` | Phases 2-3 | `https://localhost:8090` | Externally-registered origin |
| `MONITORING_API_URL` | Phases 5-7 | Varies by environment | Monitoring API base URL |
| `ADMIN_PASSWORD` | Phases 2-6 | *(required)* | Admin password from setup |

### Dependencies

**Toolbox container** (for Phases 1-5):
- Python 3.12: `httpx`, `pyyaml`, `pyjwt[crypto]`
- System: `curl`, `jq`, `bash`

**Host machine** (for Phases 6-7):
- Docker and Docker Compose
- Python 3 with `pyjwt[crypto]`
- `curl`, `bash`

---

## Troubleshooting

### Common Issues

**"ERROR: agent-secrets.json not found"**
Run bootstrap first: `ADMIN_PASSWORD=<pw> make bootstrap`

**Phase 6 tests skipped inside toolbox**
This is expected. Phases 6-7 require host access. Run them separately:
```bash
ADMIN_PASSWORD=<pw> make test-phase6
make test-phase7
```

**"monitoring-api not reachable"**
Start the monitoring API:
```bash
docker compose up -d monitoring-api
```
Wait for it to be healthy:
```bash
curl -sf http://localhost:9100/health
```

**Test 6.9 (backup/restore) is slow**
This test does a full backup, restore, and health check. It stops ThunderID, restores from backup, and waits up to 100 seconds for it to become healthy again. This is expected.

**"Error: set ADMIN_PASSWORD"**
Either set it as an environment variable or use `.env`:
```bash
export ADMIN_PASSWORD=<password_from_setup_output>
# or
echo "ADMIN_PASSWORD=<pw>" >> .env
```

### Clean-Slate Testing

To verify everything works from scratch:

```bash
make clean                                  # Remove all volumes and secrets
make setup                                  # Fresh ThunderID setup
# Note the admin password from setup-output.txt
echo "ADMIN_PASSWORD=<pw>" > .env

make build-toolbox                          # Build toolbox container
ADMIN_PASSWORD=<pw> make bootstrap          # Create tenants, roles, agents
ADMIN_PASSWORD=<pw> make seed               # Create seed users
docker compose up -d monitoring-api         # Start reference tenant server

ADMIN_PASSWORD=<pw> make test               # Run Phases 1-5
ADMIN_PASSWORD=<pw> make test-phase6        # Run Phase 6
make test-phase7                            # Run Phase 7
```
