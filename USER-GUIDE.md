# Identity Service — User Guide

A centralized identity service for internal servers, built on **ThunderID**. Provides shared authentication for humans and AI agents with per-tenant RBAC, OAuth2/OIDC token issuance, and offline JWT verification.

---

## Table of Contents

1. [Overview](#overview)
2. [Architecture](#architecture)
3. [Quick Start](#quick-start)
4. [Initial Setup (Phase 1)](#initial-setup-phase-1)
5. [Bootstrap (Phase 2)](#bootstrap-phase-2)
6. [Managing Tenants](#managing-tenants)
7. [Managing Resource Servers and Scopes](#managing-resource-servers-and-scopes)
8. [Managing Roles](#managing-roles)
9. [Managing Users](#managing-users)
10. [AI Agent Identity](#ai-agent-identity)
11. [Token Flows](#token-flows)
12. [Integrating a Tenant Server](#integrating-a-tenant-server)
13. [The CallerIdentity Model](#the-calleridentity-model)
14. [CORS Configuration](#cors-configuration)
15. [Audit Logging](#audit-logging)
16. [Backup and Restore](#backup-and-restore)
17. [Operations Reference](#operations-reference)
18. [Configuration Reference](#configuration-reference)
19. [Security](#security)
20. [Project Structure](#project-structure)
21. [Troubleshooting](#troubleshooting)

---

## Overview

### What This Service Does

- Provides a **single identity provider** for 5-15+ internal REST API servers
- Supports **three identity types**: humans, autonomous AI agents, and delegated AI agents
- Issues **OAuth2 JWT access tokens** that tenant servers verify **offline** via JWKS
- Manages **multi-tenant RBAC** — users and agents can belong to multiple tenants with different roles
- Handles **token lifecycle** — issuance, refresh, revocation, introspection

### Identity Types

| Type | Description | Auth Flow | Example |
|------|-------------|-----------|---------|
| **Human** | People who log in via browser | Authorization code (email OTP, passkey) | `alice@company.com` logging into a dashboard |
| **Autonomous Agent** | AI agents with their own identity | Client credentials (`client_id` + `client_secret`) | A nightly cleanup bot |
| **Delegated Agent** | AI agents acting on behalf of a human | Authorization code + PKCE | An AI assistant investigating alerts for a user |

### Technology Stack

| Component | Technology | Purpose |
|-----------|-----------|---------|
| Identity Provider | ThunderID v1.0.1 | OAuth2/OIDC, user/agent management, token issuance |
| Database | Embedded SQLite | Zero-config persistence (4 database files) |
| Email (dev) | MailSlurper | Captures OTP emails during development |
| Bootstrap | Python 3.12 + httpx | Automated tenant/role/agent provisioning |
| Tenant Auth | Python 3.12 + PyJWT | JWT verification middleware for FastAPI |
| Container Runtime | Docker Compose | Local deployment orchestration |

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Docker Compose Network                     │
│                                                              │
│  ┌──────────────┐    ┌──────────────┐    ┌───────────────┐  │
│  │  ThunderID    │    │ Monitoring   │    │  MailSlurper   │  │
│  │  :8090 (TLS)  │    │ API :9000    │    │  :4436 (UI)   │  │
│  │              │    │              │    │  :1025 (SMTP)  │  │
│  │ - OAuth2/OIDC│◄───│ - JWKS verify│    │               │  │
│  │ - User mgmt  │    │ - Scope check│    │  (dev only)   │  │
│  │ - Agent mgmt │    │ - Audit log  │    │               │  │
│  │ - RBAC       │    │              │    │               │  │
│  └──────────────┘    └──────────────┘    └───────────────┘  │
│         ▲                                                    │
│         │                                                    │
│  ┌──────┴───────┐                                           │
│  │   Toolbox     │  (runs bootstrap, tests)                  │
│  │   (Python)    │                                           │
│  └──────────────┘                                           │
└─────────────────────────────────────────────────────────────┘
         │
    Host: https://localhost:8090 (ThunderID)
           http://localhost:9100 (Monitoring API)
           http://localhost:4436 (MailSlurper)
```

### Request Flow

```
Client (human or agent)
  │
  ├─1─► ThunderID /oauth2/token  →  get JWT access token
  │
  └─2─► Tenant Server /api/...   →  request with "Authorization: Bearer <JWT>"
          │
          ├── Middleware: verify JWT signature via JWKS (offline, cached)
          ├── Middleware: check audience matches this server
          ├── Decorator: check caller has required scope
          └── Handler: read caller identity from request.state.caller
```

---

## Quick Start

```bash
# 1. Start ThunderID
make setup
# Note the admin password from setup-output.txt

# 2. Configure
echo "ADMIN_PASSWORD=<password>" > .env
echo "ADMIN_USERNAME=admin" >> .env

# 3. Build toolbox and bootstrap
make build-toolbox
ADMIN_PASSWORD=<pw> make bootstrap
ADMIN_PASSWORD=<pw> make seed

# 4. Start the reference tenant server
docker compose up -d monitoring-api

# 5. Verify everything works
ADMIN_PASSWORD=<pw> make test
```

**After setup, you have:**
- ThunderID running at `https://localhost:8090`
- Admin console at `https://localhost:8090/console`
- User login at `https://localhost:8090/gate`
- Monitoring API at `http://localhost:9100`
- 3 tenants, 9 roles, 3 agents, 3 seed users

---

## Initial Setup (Phase 1)

### Starting Services

```bash
make setup
```

This command:
1. Runs `thunderid-setup` to generate TLS certificates, JWT signing keys, crypto keys, and the Direct Auth Secret
2. Starts ThunderID on port 8090 (HTTPS)
3. Starts MailSlurper on ports 4436 (Web UI) and 1025 (SMTP)
4. Waits for ThunderID's health check to pass
5. Prints the admin console and gate URLs

### Setup Output

The setup generates critical secrets saved to `setup-output.txt`:
- **Admin password** — used for all management operations
- **Direct Auth Secret** — used for Direct API access (not used in this implementation; we use OAuth2 admin flow instead)

**Important:** Save the admin password. You will need it for all subsequent operations.

### Verifying Setup

```bash
make status
```

```
NAME                     IMAGE                                  STATUS
auth-thunderid-1         ghcr.io/thunder-id/thunderid:1.0.1     Up 2 minutes (healthy)
auth-mailslurper-1       oryd/mailslurper:latest-smtps           Up 2 minutes

ThunderID is healthy
```

### Service Endpoints

| Service | URL | Purpose |
|---------|-----|---------|
| ThunderID API | `https://localhost:8090` | OAuth2/OIDC endpoints |
| Admin Console | `https://localhost:8090/console` | Web-based admin UI |
| User Login Gate | `https://localhost:8090/gate` | User registration and login |
| OIDC Discovery | `https://localhost:8090/.well-known/openid-configuration` | Standard OIDC metadata |
| JWKS | `https://localhost:8090/oauth2/jwks` | Public signing keys |
| MailSlurper | `http://localhost:4436` | Dev email capture UI |

---

## Bootstrap (Phase 2)

Bootstrap creates all tenants, resource servers, roles, agents, and seed users.

### Running Bootstrap

```bash
# Create tenants, resource servers, roles, and agents
ADMIN_PASSWORD=<pw> make bootstrap

# Seed test users
ADMIN_PASSWORD=<pw> make seed
```

### What Gets Created

Bootstrap reads YAML config files from `bootstrap/config/` and uses the ThunderID management API to create:

**Tenants → Resource Servers → Scopes → Roles → Agents → User Assignments**

The bootstrap script (`bootstrap/bootstrap.py`) authenticates as the admin user via the full OAuth2 authorization code + PKCE flow, then calls the management APIs.

### Idempotency

Both `bootstrap.py` and `seed_users.py` are **idempotent** — running them multiple times is safe. Existing resources are skipped, new resources are created.

---

## Managing Tenants

Tenants are ThunderID Organization Units. Each tenant represents a service or team boundary.

### Configuration

**File:** `bootstrap/config/tenants.yaml`

```yaml
tenants:
  - handle: "monitoring-api"
    name: "Monitoring API"
    description: "Internal monitoring and alerting service"

  - handle: "data-pipeline"
    name: "Data Pipeline"
    description: "ETL and data processing service"

  - handle: "deploy-tool"
    name: "Deployment Tool"
    description: "Internal deployment and release management"
```

### Adding a New Tenant

1. Add an entry to `bootstrap/config/tenants.yaml`
2. Run `ADMIN_PASSWORD=<pw> make bootstrap`
3. The new tenant will be created (existing tenants are skipped)

### Tenant Hierarchy

```
default (root)
├── monitoring-api
├── data-pipeline
└── deploy-tool
```

All users and agents are created in the `default` organization unit but assigned roles in specific tenants.

---

## Managing Resource Servers and Scopes

Resource servers represent your APIs. Each has a unique identifier (URI) and a set of scopes (permissions).

### Configuration

**File:** `bootstrap/config/resource-servers.yaml`

```yaml
resource_servers:
  - identifier: "https://monitoring-api.internal"
    tenant: "monitoring-api"
    name: "Monitoring API"
    scopes:
      - name: "alerts:read"
        description: "View alerts"
      - name: "alerts:write"
        description: "Create and update alerts"
      - name: "alerts:delete"
        description: "Delete alerts"
      - name: "dashboards:read"
        description: "View dashboards"
      - name: "dashboards:write"
        description: "Create and update dashboards"
      - name: "settings:manage"
        description: "Manage service settings"

  - identifier: "https://data-pipeline.internal"
    tenant: "data-pipeline"
    name: "Data Pipeline API"
    scopes:
      - name: "pipelines:read"
        description: "View pipeline status"
      - name: "pipelines:run"
        description: "Trigger pipeline execution"
      - name: "pipelines:manage"
        description: "Create, update, delete pipelines"
      - name: "data:read"
        description: "Read processed data"

  - identifier: "https://deploy-tool.internal"
    tenant: "deploy-tool"
    name: "Deployment Tool API"
    scopes:
      - name: "deployments:read"
        description: "View deployment history"
      - name: "deployments:trigger"
        description: "Trigger deployments"
      - name: "deployments:rollback"
        description: "Rollback deployments"
      - name: "configs:manage"
        description: "Manage deployment configurations"
```

### Scope Naming Convention

Scopes follow the pattern `resource:action`:
- `alerts:read` — read access to alerts
- `pipelines:manage` — full CRUD on pipelines
- `settings:manage` — admin-level configuration

### Adding a New Resource Server

1. Add a resource server entry to `bootstrap/config/resource-servers.yaml`
2. Create a tenant for it in `tenants.yaml` (if new)
3. Run `ADMIN_PASSWORD=<pw> make bootstrap`

---

## Managing Roles

Roles bundle scopes together for assignment to users and agents.

### Configuration

**File:** `bootstrap/config/roles.yaml`

```yaml
roles:
  # Monitoring API roles
  - name: "monitoring-admin"
    tenant: "monitoring-api"
    resource_server: "https://monitoring-api.internal"
    scopes:
      - "alerts:read"
      - "alerts:write"
      - "alerts:delete"
      - "dashboards:read"
      - "dashboards:write"
      - "settings:manage"

  - name: "monitoring-operator"
    tenant: "monitoring-api"
    resource_server: "https://monitoring-api.internal"
    scopes:
      - "alerts:read"
      - "alerts:write"
      - "dashboards:read"

  - name: "monitoring-viewer"
    tenant: "monitoring-api"
    resource_server: "https://monitoring-api.internal"
    scopes:
      - "alerts:read"
      - "dashboards:read"
```

### Role Hierarchy Pattern

Each tenant follows the **admin > operator > viewer** pattern:

| Role | Access Level | Typical Use |
|------|-------------|-------------|
| `*-admin` | All scopes | Service owners, SREs |
| `*-operator` | Read + write (no delete/manage) | Day-to-day operators |
| `*-viewer` | Read only | Auditors, stakeholders |

### Current Roles (9 total)

| Tenant | Admin | Operator | Viewer |
|--------|-------|----------|--------|
| monitoring-api | monitoring-admin | monitoring-operator | monitoring-viewer |
| data-pipeline | pipeline-admin | pipeline-engineer | pipeline-readonly |
| deploy-tool | deploy-admin | deploy-operator | deploy-viewer |

---

## Managing Users

### Seed Users

**File:** `bootstrap/config/users.yaml`

```yaml
user_assignments:
  - email: "sysadmin@company.com"
    tenants:
      - tenant: "monitoring-api"
        roles: ["monitoring-admin"]
      - tenant: "data-pipeline"
        roles: ["pipeline-admin"]
      - tenant: "deploy-tool"
        roles: ["deploy-admin"]

  - email: "alice@company.com"
    tenants:
      - tenant: "monitoring-api"
        roles: ["monitoring-operator"]
      - tenant: "data-pipeline"
        roles: ["pipeline-engineer"]

  - email: "bob@company.com"
    tenants:
      - tenant: "monitoring-api"
        roles: ["monitoring-viewer"]
```

### User Registration

Users register themselves via the ThunderID Gate:
1. Navigate to `https://localhost:8090/gate`
2. Click "Register"
3. Enter email, username, and password
4. Verify email via the OTP sent to MailSlurper (`http://localhost:4436`)

### Assigning Roles to Users

1. Add the user's email and role assignments to `bootstrap/config/users.yaml`
2. Run `ADMIN_PASSWORD=<pw> make seed`
3. Existing users get new roles; existing assignments are skipped

### User Management via Console

The ThunderID admin console (`https://localhost:8090/console`) provides a web UI for:
- Viewing all users
- Viewing user details and attributes
- Managing user credentials
- Viewing role assignments

---

## AI Agent Identity

### Agent Types

| Type | Grant Type | Use Case | Example |
|------|-----------|----------|---------|
| **Autonomous** | `client_credentials` | Agents that act on their own | Nightly cleanup bot, pipeline scheduler |
| **Delegated** | `authorization_code` + PKCE | Agents acting on behalf of a user | AI assistant, copilot |

### Agent Configuration

**File:** `bootstrap/config/agents.yaml`

```yaml
agents:
  # Autonomous agent
  - name: "alert-cleanup-agent"
    tenant: "monitoring-api"
    type: "default"
    mode: "autonomous"
    description: "Cleans up expired alerts nightly"
    attributes:
      model: "gpt-4"
      modelProvider: "openai"
      function: "task-automation"
    roles:
      - "monitoring-operator"
    scopes:
      - "alerts:read"
      - "alerts:write"

  # Delegated agent
  - name: "monitoring-assistant"
    tenant: "monitoring-api"
    type: "default"
    mode: "delegated"
    description: "AI assistant that helps users investigate alerts"
    attributes:
      model: "gpt-4"
      modelProvider: "openai"
      function: "assistant"
    redirect_uris:
      - "http://localhost:3000/callback"
    scopes:
      - "alerts:read"
      - "dashboards:read"
```

### Agent Secrets

When agents are created, their OAuth2 credentials are saved to `bootstrap/config/agent-secrets.json` (gitignored):

```json
{
  "alert-cleanup-agent": {
    "agentId": "01a05bb5-becb-74ac-b5bd-7be2a7a34a60",
    "clientId": "ooxvbe9uMY2fRpqmifhogw",
    "clientSecret": "HkJb3...",
    "mode": "autonomous"
  },
  "pipeline-scheduler-agent": { ... },
  "monitoring-assistant": { ... }
}
```

### Getting an Agent Token

```bash
# Read credentials
CLIENT_ID=$(python3 -c "import json; print(json.load(open('bootstrap/config/agent-secrets.json'))['alert-cleanup-agent']['clientId'])")
CLIENT_SECRET=$(python3 -c "import json; print(json.load(open('bootstrap/config/agent-secrets.json'))['alert-cleanup-agent']['clientSecret'])")

# Request token
curl -X POST https://localhost:8090/oauth2/token \
  -u "$CLIENT_ID:$CLIENT_SECRET" \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -d 'grant_type=client_credentials&resource=https://monitoring-api.internal&scope=alerts:read alerts:write' \
  --insecure
```

Response:
```json
{
  "access_token": "eyJhbGciOiJSUzI1NiIs...",
  "token_type": "bearer",
  "expires_in": 3600,
  "scope": "alerts:read alerts:write"
}
```

### Adding a New Agent

1. Add an entry to `bootstrap/config/agents.yaml`
2. Run `ADMIN_PASSWORD=<pw> make bootstrap`
3. New agent credentials appear in `agent-secrets.json`

---

## Token Flows

### Flow 1: Autonomous Agent Token (Client Credentials)

```
Agent                          ThunderID
  │                               │
  ├──POST /oauth2/token──────────►│
  │  grant_type=client_credentials│
  │  client_id + client_secret    │
  │  resource=https://api.internal│
  │  scope=alerts:read            │
  │                               │
  │◄──── access_token ────────────│
  │      (JWT, 1 hour TTL)        │
```

### Flow 2: Use Token at Tenant Server

```
Agent                     Tenant Server              ThunderID
  │                            │                         │
  ├──GET /alerts──────────────►│                         │
  │  Authorization: Bearer JWT │                         │
  │                            │                         │
  │                            ├──GET /oauth2/jwks──────►│  (cached, first call only)
  │                            │◄──── public keys ───────│
  │                            │                         │
  │                            ├── Verify JWT signature  │
  │                            ├── Check audience        │
  │                            ├── Check scopes          │
  │                            │                         │
  │◄──── 200 + alert data ────│                         │
```

### Flow 3: Token Revocation

```bash
# Revoke a token
curl -X POST https://localhost:8090/oauth2/revoke \
  -u "$CLIENT_ID:$CLIENT_SECRET" \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -d "token=$ACCESS_TOKEN&token_type_hint=access_token" \
  --insecure
```

**Important:** Revoked tokens are immediately invalid for online checks (introspection) but remain cryptographically valid for offline JWKS verification until they expire. This is a known trade-off of offline JWT verification.

### Flow 4: Token Introspection

```bash
# Check if a token is still active
curl -X POST https://localhost:8090/oauth2/introspect \
  -u "$CLIENT_ID:$CLIENT_SECRET" \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -d "token=$ACCESS_TOKEN" \
  --insecure
```

Response:
```json
{
  "active": true,
  "sub": "01a05bb5-becb-74ac-b5bd-7be2a7a34a60",
  "client_id": "ooxvbe9uMY2fRpqmifhogw",
  "scope": "alerts:read alerts:write",
  "exp": 1788333291
}
```

---

## Integrating a Tenant Server

This section shows how to add JWT authentication to your own API server using the provided middleware.

### Step 1: Install Dependencies

```bash
pip install 'fastapi>=0.115,<1' 'uvicorn>=0.32,<1' 'pyjwt[crypto]>=2.8,<3'
```

### Step 2: Copy the Auth Module

Copy `tenant-server/auth.py` into your project. This provides:
- `CallerIdentity` — parsed identity from JWT claims
- `verify_token()` — offline JWT verification via JWKS
- `JWTAuthMiddleware` — FastAPI middleware that verifies every request
- `require_scope()` — decorator for route-level scope enforcement

### Step 3: Configure Environment Variables

```bash
THUNDERID_URL=https://thunderid:8090        # ThunderID base URL
RESOURCE_ID=https://your-api.internal       # Your resource server identifier
JWKS_URL=https://thunderid:8090/oauth2/jwks # JWKS endpoint
JWKS_VERIFY_SSL=false                       # Set to "true" in production
SERVICE_NAME=your-api                       # For audit log entries
CORS_ORIGINS=https://localhost:3000         # Comma-separated allowed origins
```

### Step 4: Wire Middleware into Your App

```python
# main.py
import os
from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from auth import JWTAuthMiddleware, require_scope

app = FastAPI(title="Your API")

# Add middleware (order matters: CORS must be added AFTER JWT
# because FastAPI processes middleware in reverse addition order)
app.add_middleware(JWTAuthMiddleware)
app.add_middleware(
    CORSMiddleware,
    allow_origins=os.getenv("CORS_ORIGINS", "https://localhost:3000").split(","),
    allow_credentials=True,
    allow_methods=["GET", "POST", "PUT", "DELETE", "OPTIONS"],
    allow_headers=["Authorization", "Content-Type"],
)
```

### Step 5: Protect Routes

```python
@app.get("/health")
async def health():
    """Public endpoint — no auth required."""
    return {"status": "ok"}

@app.get("/data")
@require_scope("data:read")
async def get_data(request: Request):
    """Protected endpoint — requires data:read scope."""
    caller = request.state.caller
    return {
        "data": [...],
        "caller": {
            "subject": caller.subject,
            "subject_type": caller.subject_type,
            "is_agent": caller.is_agent,
        }
    }

@app.post("/data")
@require_scope("data:write")
async def create_data(request: Request):
    """Protected endpoint — requires data:write scope."""
    caller = request.state.caller
    # Use caller.subject for audit trail
    return {"created": True}

@app.delete("/data/{id}")
@require_scope("data:delete", "data:admin")
async def delete_data(request: Request, id: str):
    """Protected endpoint — requires data:delete OR data:admin scope."""
    return {"deleted": id}
```

### Step 6: Register Your Resource Server

Add to `bootstrap/config/resource-servers.yaml`:

```yaml
  - identifier: "https://your-api.internal"
    tenant: "your-tenant"
    name: "Your API"
    scopes:
      - name: "data:read"
        description: "Read data"
      - name: "data:write"
        description: "Write data"
      - name: "data:delete"
        description: "Delete data"
```

Then run `ADMIN_PASSWORD=<pw> make bootstrap`.

### Public Paths

The middleware skips authentication for these paths:
- `/health` — health check
- `/docs` — Swagger UI
- `/openapi.json` — OpenAPI spec
- `/redoc` — ReDoc UI

---

## The CallerIdentity Model

Every authenticated request has a `CallerIdentity` object at `request.state.caller`:

```python
class CallerIdentity:
    subject: str           # Unique ID (user ID or agent ID)
    subject_type: str      # "user", "agent", or custom
    scopes: list[str]      # Granted scopes (e.g., ["alerts:read", "alerts:write"])
    client_id: str         # OAuth2 client ID
    grant_type: str        # "client_credentials", "authorization_code", etc.
    raw_claims: dict       # Full decoded JWT claims
    acting_agent: str|None # For delegated tokens: the agent's subject ID
    is_delegated: bool     # True if this is a delegated token (act claim present)

    # Properties
    is_agent: bool         # True if subject_type == "agent"
    is_human: bool         # True if subject_type == "user"

    # Methods
    has_scope(scope: str) -> bool
    has_any_scope(scopes: list[str]) -> bool
```

### Subject Type Inference

ThunderID does not include a `sub_type` claim in JWTs. The middleware infers the caller type:

| Priority | Condition | Result |
|----------|-----------|--------|
| 1 | Explicit `sub_type` claim present | Use that value directly |
| 2 | `grant_type == "client_credentials"` | `"agent"` |
| 3 | Default | `"user"` |

### Usage Examples

```python
@app.get("/data")
@require_scope("data:read")
async def get_data(request: Request):
    caller = request.state.caller

    # Check identity type
    if caller.is_agent:
        print(f"Agent {caller.subject} accessed data")
    elif caller.is_human:
        print(f"User {caller.subject} accessed data")

    # Check specific scopes
    if caller.has_scope("data:admin"):
        return {"data": all_data, "admin_view": True}
    else:
        return {"data": filtered_data}

    # Check delegation
    if caller.is_delegated:
        print(f"Agent {caller.acting_agent} acting on behalf of {caller.subject}")
```

---

## CORS Configuration

The monitoring API includes CORS middleware for browser-based clients.

### Default Configuration

```python
allow_origins=os.getenv("CORS_ORIGINS", "https://localhost:3000").split(",")
allow_credentials=True
allow_methods=["GET", "POST", "PUT", "DELETE", "OPTIONS"]
allow_headers=["Authorization", "Content-Type"]
```

### Configuring Origins

Set the `CORS_ORIGINS` environment variable (comma-separated):

```yaml
# docker-compose.yml
environment:
  CORS_ORIGINS: "https://app.example.com,https://admin.example.com"
```

### Middleware Order

CORS middleware must be added **after** JWT middleware in the code because FastAPI processes middleware in **reverse** addition order. This ensures CORS preflight (OPTIONS) requests are handled before the JWT check:

```python
app.add_middleware(JWTAuthMiddleware)   # Added first, runs second
app.add_middleware(CORSMiddleware, ...) # Added second, runs first
```

---

## Audit Logging

The tenant server produces structured JSON audit logs for every authentication decision.

### Event Types

| Event | When | Key Fields |
|-------|------|------------|
| `auth_denied` | No token, invalid token, expired token | `reason`, `ip`, `endpoint` |
| `auth_allowed` | Valid token accepted | `subject`, `subject_type`, `scopes`, `verify_ms` |
| `scope_denied` | Valid token but insufficient scopes | `required_scopes`, `actual_scopes` |

### Viewing Logs

```bash
# Follow monitoring-api logs
docker compose logs -f monitoring-api

# Filter for auth events
docker compose logs monitoring-api | grep '"event"'

# Filter for denied events
docker compose logs monitoring-api | grep 'auth_denied\|scope_denied'
```

### Log Fields Reference

Every log entry contains:

| Field | Type | Description |
|-------|------|-------------|
| `timestamp` | string | ISO 8601 timestamp |
| `level` | string | Always `"info"` for auth events |
| `service` | string | Service name (e.g., `"monitoring-api"`) |
| `event` | string | `auth_denied`, `auth_allowed`, or `scope_denied` |
| `request_id` | string | 8-char UUID for request correlation |
| `endpoint` | string | Request path (e.g., `/alerts`) |
| `method` | string | HTTP method (e.g., `GET`) |
| `decision` | string | `allowed` or `denied` |
| `ip` | string | Client IP address |

Additional fields for `auth_allowed`:

| Field | Type | Description |
|-------|------|-------------|
| `subject` | string | User or agent ID |
| `subject_type` | string | `"user"` or `"agent"` |
| `scopes` | array | Granted scopes |
| `client_id` | string | OAuth2 client ID |
| `grant_type` | string | OAuth2 grant type |
| `is_delegated` | bool | Whether this is a delegated token |
| `acting_agent` | string | Agent subject for delegated tokens |
| `verify_ms` | float | JWT verification time in milliseconds |

---

## Backup and Restore

### Creating a Backup

```bash
make backup
# or
bash scripts/backup-db.sh
```

This creates a timestamped tarball in `backups/`:
```
backups/thunderid_20260901_120000.tar.gz
```

**What's backed up:**
- 4 SQLite databases (config, entities, runtime persistent, runtime transient)
- TLS and JWT signing certificates/keys
- Direct Auth Secret

The backup uses SQLite's `.backup` command for WAL-safe hot backup (no downtime needed). The last 30 backups are retained automatically.

### Restoring from Backup

```bash
make restore FILE=backups/thunderid_20260901_120000.tar.gz
# or
CONFIRM=yes bash scripts/restore-db.sh backups/thunderid_20260901_120000.tar.gz
```

This will:
1. Stop ThunderID
2. Replace all databases, certificates, and secrets from the backup
3. Fix file ownership (ThunderID runs as uid 10001)
4. Remove WAL files to prevent corruption
5. Start ThunderID
6. Wait for it to become healthy

### Listing Backups

```bash
ls -lh backups/thunderid_*.tar.gz
```

### Automated Backups

Add to cron for daily backups:
```bash
0 2 * * * cd /path/to/auth && bash scripts/backup-db.sh >> /var/log/thunderid-backup.log 2>&1
```

---

## Operations Reference

### Makefile Commands

| Command | Description |
|---------|-------------|
| `make setup` | Start ThunderID and MailSlurper from scratch |
| `make build-toolbox` | Build the toolbox container |
| `make get-secret` | Print the Direct Auth Secret |
| `ADMIN_PASSWORD=<pw> make bootstrap` | Create tenants, resource servers, roles, agents |
| `ADMIN_PASSWORD=<pw> make seed` | Create seed users and assign roles |
| `ADMIN_PASSWORD=<pw> make test` | Run Phases 1-5 test suite |
| `ADMIN_PASSWORD=<pw> make test-phase{N}` | Run a specific phase's tests |
| `make backup` | Create a backup |
| `make restore FILE=<path>` | Restore from a backup |
| `make logs` | Follow ThunderID logs |
| `make logs-all` | Follow all service logs |
| `make status` | Show running services and health |
| `make stop` | Stop all services (preserves data) |
| `make down` | Stop and remove containers (preserves volumes) |
| `make clean` | Remove everything including volumes |
| `make all` | Full setup: start, build, bootstrap, seed |

### Service Management

```bash
# Start everything
docker compose up -d

# Start specific service
docker compose up -d monitoring-api

# Restart a service
docker compose restart monitoring-api

# View logs
docker compose logs -f monitoring-api --tail 50

# Check health
curl -sf http://localhost:9100/health | python3 -m json.tool
curl -sf --insecure https://localhost:8090/.well-known/openid-configuration | python3 -m json.tool
```

---

## Configuration Reference

### Environment Variables (.env)

| Variable | Default | Description |
|----------|---------|-------------|
| `ADMIN_USERNAME` | `admin` | ThunderID admin username |
| `ADMIN_PASSWORD` | *(required)* | ThunderID admin password (from setup) |

### Docker Compose Services

| Service | Image | Ports | Purpose |
|---------|-------|-------|---------|
| `thunderid-setup` | `thunderid:1.0.1` | *(none)* | One-shot: generates keys and secrets |
| `thunderid` | `thunderid:1.0.1` | `8090` | Identity provider (OAuth2/OIDC) |
| `mailslurper` | `oryd/mailslurper` | `4436`, `1025` | Dev email capture |
| `monitoring-api` | *(local build)* | `9100→9000` | Reference tenant server |
| `toolbox` | *(local build)* | *(none)* | Bootstrap scripts and tests |

### Tenant Server Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `THUNDERID_URL` | `https://localhost:8090` | ThunderID base URL |
| `RESOURCE_ID` | `https://monitoring-api.internal` | This server's resource identifier |
| `JWKS_URL` | `${THUNDERID_URL}/oauth2/jwks` | JWKS endpoint URL |
| `JWKS_VERIFY_SSL` | `true` | Set to `false` for self-signed certs |
| `SERVICE_NAME` | `monitoring-api` | Service name in audit logs |
| `CORS_ORIGINS` | `https://localhost:3000` | Comma-separated allowed CORS origins |

### ThunderID Data Storage

| Volume | Path in Container | Contents |
|--------|------------------|----------|
| `thunderid-db` | `/opt/thunderid/database/` | 4 SQLite databases |
| `thunderid-certs` | `/opt/thunderid/config/certs/` | TLS certs, JWT signing keys, crypto key |
| `thunderid-secrets` | `/opt/thunderid/config/secrets/` | Direct Auth Secret |

---

## Security

### What's Protected

| Item | How | Where |
|------|-----|-------|
| Admin password | `.env` in `.gitignore` | `.env` file |
| Setup output | `setup-output.txt` in `.gitignore` | Project root |
| Agent secrets | `agent-secrets.json` in `.gitignore` | `bootstrap/config/` |
| Direct Auth Secret | Docker volume (not in filesystem) | `thunderid-secrets` volume |
| JWT signing keys | Docker volume (not in filesystem) | `thunderid-certs` volume |

### Security Checklist

- [x] `.env` excluded from git
- [x] `setup-output.txt` excluded from git
- [x] `agent-secrets.json` excluded from git
- [x] ThunderID image pinned to v1.0.1 (not `latest`)
- [x] JWKS cache configured with 1-hour TTL
- [x] CORS origins explicitly configured (no wildcard)
- [x] Docker restart policies set on all services
- [x] `.env.example` provided for new developers
- [x] TLS enabled (self-signed for dev; use proper certs in production)

### Production Recommendations

| Area | Dev (current) | Production |
|------|--------------|------------|
| TLS | Self-signed (auto-generated) | Proper CA-signed certificates |
| Email | MailSlurper | Real SMTP provider |
| Database | Embedded SQLite | PostgreSQL (see master-plan.md Section 18.3) |
| CORS | `https://localhost:3000` | Actual frontend origin(s) |
| Admin access | Open | Restrict via reverse proxy / VPN |
| Backups | Manual (`make backup`) | Automated daily cron job |
| Monitoring | None | Prometheus + Grafana |

---

## Project Structure

```
auth/
├── .env                          # Secrets (gitignored)
├── .env.example                  # Environment template
├── .gitignore                    # Security: excludes secrets
├── Makefile                      # All operations entry point
├── docker-compose.yml            # Service definitions
├── master-plan.md                # Full architecture plan
│
├── thunderid/
│   └── deployment.yaml           # ThunderID configuration
│
├── bootstrap/
│   ├── Dockerfile                # Toolbox container (Python + deps)
│   ├── requirements.txt          # httpx, pyyaml, pyjwt
│   ├── auth.py                   # OAuth2 admin auth flow (PKCE)
│   ├── bootstrap.py              # Create tenants, RS, roles, agents
│   ├── seed_users.py             # Create users, assign roles
│   └── config/
│       ├── tenants.yaml          # Tenant definitions
│       ├── resource-servers.yaml # Resource servers and scopes
│       ├── roles.yaml            # Role definitions with scopes
│       ├── agents.yaml           # AI agent definitions
│       ├── users.yaml            # User-to-role assignments
│       └── agent-secrets.json    # Generated agent credentials (gitignored)
│
├── tenant-server/
│   ├── Dockerfile                # Monitoring API container
│   ├── requirements.txt          # fastapi, uvicorn, pyjwt
│   ├── auth.py                   # JWT middleware, CallerIdentity, audit logging
│   └── main.py                   # FastAPI app with protected routes
│
├── scripts/
│   ├── test-all.sh               # Full test suite runner
│   ├── test-phase1.sh            # ThunderID infrastructure tests (6)
│   ├── test-phase2.sh            # Bootstrap verification tests (17)
│   ├── test-phase3.sh            # Agent identity tests (11)
│   ├── test-phase4.sh            # End-to-end integration tests (13)
│   ├── test-phase5.sh            # Tenant server integration tests (12)
│   ├── test-phase6.sh            # Operations tests (9)
│   ├── test-phase7.sh            # Quality audit tests (15)
│   ├── test-api.sh               # Legacy smoke test
│   ├── backup-db.sh              # SQLite hot backup
│   └── restore-db.sh             # Full restore from tarball
│
├── backups/
│   └── .gitkeep                  # Backup tarballs stored here (gitignored)
│
├── TESTING.md                    # Comprehensive testing guide
└── USER-GUIDE.md                 # This file
```

---

## Troubleshooting

### ThunderID won't start

```bash
# Check logs
docker compose logs thunderid

# Verify setup completed
docker compose logs thunderid-setup

# Start fresh
make clean && make setup
```

### "Error: set ADMIN_PASSWORD"

The admin password is required for bootstrap, seed, and most test commands:

```bash
# Set in .env (persistent)
echo "ADMIN_PASSWORD=<password>" >> .env

# Or set inline (one-time)
ADMIN_PASSWORD=<pw> make bootstrap
```

### Agent token request fails

```bash
# Verify agent exists
curl -sf --insecure -H "Authorization: Bearer $ADMIN_TOKEN" \
  https://localhost:8090/agents | python3 -m json.tool

# Check agent-secrets.json has correct credentials
cat bootstrap/config/agent-secrets.json | python3 -m json.tool

# Re-run bootstrap (idempotent)
ADMIN_PASSWORD=<pw> make bootstrap
```

### Monitoring API returns 401

1. Check the token's audience: `jwt.io` or decode manually
2. Verify the resource identifier matches: `RESOURCE_ID=https://monitoring-api.internal`
3. Check the JWKS URL is reachable from the container
4. Look at audit logs: `docker compose logs monitoring-api | grep auth_denied`

### Monitoring API returns 403

The token is valid but lacks the required scope:
```bash
# Check what scopes the token has
curl -sf -H "Authorization: Bearer $TOKEN" http://localhost:9100/whoami | python3 -m json.tool
```

### Certificate warnings

ThunderID uses self-signed certificates in development. This is expected:
- `curl`: use `--insecure` or `-k`
- Python: set `verify=False` on HTTP clients
- Browser: accept the self-signed certificate warning

In production, use proper CA-signed certificates.

### Clean-slate reset

```bash
make clean                              # Remove everything
make setup                              # Fresh start
# Note password from setup-output.txt
echo "ADMIN_PASSWORD=<pw>" > .env
make build-toolbox
ADMIN_PASSWORD=<pw> make bootstrap
ADMIN_PASSWORD=<pw> make seed
docker compose up -d monitoring-api
ADMIN_PASSWORD=<pw> make test
```
