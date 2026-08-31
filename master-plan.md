# Identity Service - Master Plan

A centralized identity service for internal servers, built with **ThunderID** in Docker. Provides shared authentication for **humans and AI agents** with per-tenant RBAC, OAuth2/OIDC token issuance, agent delegation, and offline JWT verification for 5-15 existing REST API servers.

**Previous version:** This plan replaces the Kratos-based architecture (preserved in `master-plan-kratos-v1.md`). The pivot to ThunderID eliminates the need for both Ory Kratos and the custom FastAPI middleware, consolidating everything into a single system that natively supports agent identity.

---

## Table of Contents

1. [Problem Statement](#1-problem-statement)
2. [Architecture Overview](#2-architecture-overview)
3. [Core Concepts](#3-core-concepts)
4. [Technology Stack](#4-technology-stack)
5. [Project Structure](#5-project-structure)
6. [Phase 1: ThunderID Setup](#6-phase-1-thunderid-setup)
7. [Phase 2: Tenant & Resource Server Bootstrap](#7-phase-2-tenant--resource-server-bootstrap)
8. [Phase 3: Agent Identity Setup](#8-phase-3-agent-identity-setup)
9. [Token Lifecycle: Refresh & Revocation](#9-token-lifecycle-refresh--revocation)
10. [Phase 4: Integration & Testing](#10-phase-4-integration--testing)
11. [Integrating Existing Servers](#11-integrating-existing-servers)
12. [REST API Reference](#12-rest-api-reference)
13. [Configuration Reference](#13-configuration-reference)
14. [Logging & Audit Trail](#14-logging--audit-trail)
15. [Backup & Restore](#15-backup--restore)
16. [Security, Resilience & Failure Modes](#16-security-resilience--failure-modes)
17. [Makefile & Scripts](#17-makefile--scripts)
18. [Scope & Future Enhancements](#18-scope--future-enhancements)
19. [Implementation Order Summary](#19-implementation-order-summary)

---

## 1. Problem Statement

- You have **5-15 internal REST API servers** with **no authentication or RBAC**
- Each server belongs to a **tenant** (e.g., monitoring-api, data-pipeline, deployment-tool) — a cross-functional organizational unit, not necessarily a single software project
- A user or agent can belong to **multiple tenants** with different roles in each
- You need a **single identity service** that all tenants can use
- You need to support **three identity types**:
  - **Humans** — people who log in via browser (email OTP, passkey, social login)
  - **Autonomous agents** — AI agents with their own identity, credentials, and roles (LLM agents, autonomous workflows, tool-using agents)
  - **Delegated agents** — AI agents that act **on behalf of a human user** with scoped-down permissions
- Tenant servers authenticate requests using **standard OAuth2 JWT tokens** verified **offline** via JWKS

---

## 2. Architecture Overview

```text
┌──────────────────────────────────────────────────────────────────┐
│                     Internal Network                             │
│                                                                  │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐           │
│  │ Tenant A     │  │ Tenant B     │  │ Tenant C     │  ...      │
│  │ (REST API)   │  │ (REST API)   │  │ (REST API)   │           │
│  │ monitoring   │  │ data-pipeline│  │ deploy-tool  │           │
│  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘           │
│         │                 │                 │                    │
│         │  Verify JWT     │  Verify JWT     │  Verify JWT       │
│         │  via JWKS       │  via JWKS       │  via JWKS         │
│         │  (offline)      │  (offline)      │  (offline)        │
│         │                 │                 │                    │
│         └────────────┬────┴────────┬────────┘                    │
│                      │             │                             │
│                      ▼             ▼                             │
│  ┌─────────────────────────────────────────────┐                │
│  │           ThunderID (Go binary)              │                │
│  │              Port 8090                       │                │
│  │                                              │                │
│  │  • Human login/registration (OTP, passkey,   │                │
│  │    social login, SAML, magic link)           │                │
│  │  • AI agent identity (autonomous + delegated)│                │
│  │  • OAuth 2.1 / OIDC token issuance           │                │
│  │  • Organization units (tenants)              │                │
│  │  • RBAC (roles, groups, scopes)              │                │
│  │  • Agent-to-agent delegation (token exchange)│                │
│  │  • Admin console UI                          │                │
│  │  • Login gate UI                             │                │
│  │  • JWKS endpoint for offline verification    │                │
│  │  • MCP authorization server                  │                │
│  │  • Embedded SQLite databases (4 DBs)         │                │
│  │    - config, entity, runtime_transient,      │                │
│  │      runtime_persistent                      │                │
│  └─────────────────────────────────────────────┘                │
│                                                                  │
│  ┌─────────────────────────────────────────────┐                │
│  │           Bootstrap Service (Python)         │                │
│  │           Runs on host, not a container      │                │
│  │                                              │                │
│  │  • Calls ThunderID API via Direct-Auth-Secret│                │
│  │  • Registers tenants as organization units   │                │
│  │  • Registers tenant servers as resource      │                │
│  │    servers with scopes                       │                │
│  │  • Creates initial agents                    │                │
│  │  • Seeds initial user-tenant assignments     │                │
│  └─────────────────────────────────────────────┘                │
│                                                                  │
│  ┌─────────────┐                                                │
│  │ MailSlurper │  (dev only — captures emails)                  │
│  │ SMTP: 1025  │                                                │
│  │ Web:  4436  │                                                │
│  └─────────────┘                                                │
└──────────────────────────────────────────────────────────────────┘
```

### What Changed from the Kratos Architecture

| Concern | Kratos Plan | ThunderID Plan |
| --- | --- | --- |
| Identity server | Ory Kratos (identity only, no OAuth2) | ThunderID (identity + OAuth2 + agent identity) |
| Token issuance | Custom FastAPI middleware (PyJWT RS256) | ThunderID's built-in OAuth 2.1 server |
| Tenant/RBAC management | Custom FastAPI middleware (own PostgreSQL) | ThunderID's organization units + roles + groups |
| Agent identity | Not supported | Native first-class agent identity |
| Admin UI | Custom Next.js app | ThunderID's built-in console |
| Login UI | Custom Next.js app | ThunderID's built-in gate |
| JWT verification | Custom RS256 public key distribution | Standard JWKS endpoint (RFC 7517) |
| Custom code to write | ~50 files (middleware + UI + SDK) | ~10 files (bootstrap scripts + SDK) |
| Moving parts | 6 containers (Postgres, Kratos, middleware, UI, mailslurper, migrate) | 2 containers (ThunderID, MailSlurper) |

### Verified Findings from ThunderID v1.0.1

The following was confirmed by inspecting `ghcr.io/thunder-id/thunderid:latest` (v1.0.1):

| Finding | Detail |
| --- | --- |
| **Database** | SQLite by default (4 databases: config, entity, runtime_transient, runtime_persistent). No external PostgreSQL required. |
| **Setup** | `./setup.sh` generates TLS certs, JWT signing keys (RSA + ECDSA), crypto key, admin user, and Direct Auth Secret. One-shot, runs before `./start.sh`. |
| **Start** | `./start.sh` starts the server. Also supports `--bootstrap-and-serve` to combine setup + start in one step. |
| **Admin auth** | Admin credentials set via `ADMIN_USERNAME`/`ADMIN_PASSWORD` env vars (auto-generated if not set, shown once). |
| **Direct Auth** | `Direct-Auth-Secret` header (not Bearer token) authenticates Direct API calls. Secret stored in `config/secrets/direct_auth_secret`. |
| **Config format** | `deployment.yaml` at `/opt/thunderid/deployment.yaml`. Supports 4 separate database sections (`config`, `entity`, `runtime_transient`, `runtime_persistent`). |
| **Default resources** | Bootstrap creates: default OU, Person user type, default agent type (with modelProvider/model/function schema), system resource server, default auth flow. |
| **Email config** | `email.smtp` block in `deployment.yaml` (host, port, username, password, from_address, enable_start_tls, enable_authentication). |
| **Working directory** | `/opt/thunderid` |
| **Exposed port** | `8090/tcp` |
| **Volumes needed** | `config/certs`, `config/secrets`, `database/` (all under `/opt/thunderid`) |
| **MailSlurper ports** | SMTP: `1025` (SSL), Web UI: `4436`, API: `4437` (for `oryd/mailslurper:latest-smtps`) |
| **Token revocation** | Built-in, DB-backed, with configurable sync interval (default 60s). |
| **OAuth defaults** | Refresh token validity: 86400s (24h), authorization code validity: 600s, refresh token rotation enabled with revoke-on-renew. |

### Key Flows

#### Flow 1: Human Login and Token Issuance

```text
1. User → ThunderID Gate (or API)   : Enter email
2. ThunderID                        : Execute login flow (OTP code via email)
3. User → ThunderID                 : Submit code
4. ThunderID                        : Session created, consent evaluated
5. ThunderID → User                 : Return OAuth2 access_token (JWT) + refresh_token
                                      Token scoped to requested resource server (tenant)
```

#### Flow 2: Autonomous Agent Gets Token

```text
1. Agent → ThunderID    : POST /oauth2/token (client_credentials grant)
                          with client_id + client_secret
2. ThunderID            : Validates credentials, checks agent's roles/scopes
3. ThunderID → Agent    : Return access_token (JWT) with sub=agent-id,
                          sub_type=agent, scopes from agent's roles
```

#### Flow 3: Agent Acts on Behalf of User

```text
1. Agent → ThunderID    : Redirect user to /oauth2/authorize (authorization_code + PKCE)
2. User → ThunderID     : Logs in, consents
3. ThunderID → Agent    : Returns auth code
4. Agent → ThunderID    : POST /oauth2/token (exchange code for tokens)
5. ThunderID → Agent    : Return access_token with sub=user-id, act={sub: agent-id}
```

#### Flow 4: Agent-to-Agent Delegation

```text
1. Agent A → ThunderID  : POST /oauth2/token (token_exchange grant)
                          subject_token=<user_or_agent_token>
                          actor_token=<agent_a_token>
                          scope=<downscoped>
2. ThunderID            : Validates, enforces downscoping
3. ThunderID → Agent A  : Return access_token with nested act claims
                          {sub: original-subject, act: {sub: agent-a, act: {sub: agent-b}}}
```

#### Flow 5: Tenant Server Validates a Request

```text
1. Client → Tenant Server    : API request + Authorization: Bearer <JWT>
2. Tenant Server             : Fetch JWKS from ThunderID (cached)
3. Tenant Server             : Verify JWT signature via JWKS
4. Tenant Server             : Check iss, aud, exp, scope claims
5. Tenant Server             : Identify caller type: sub_type=user|agent
6. Tenant Server → Client    : Response (200 or 403)
```

---

## 3. Core Concepts

### 3.1 Tenant

A **tenant** represents an organizational unit in ThunderID. Each tenant:

- Maps to a ThunderID **Organization Unit (OU)**
- Has a unique handle (e.g., `monitoring-api`, `data-pipeline`)
- Contains its own users, agents, roles, groups, and resource servers
- Is cross-functional — a user or agent can belong to multiple tenants
- Is isolated — configuration in one tenant doesn't leak to another

### 3.2 User (Human Identity)

A **user** is a person who can access one or more tenants. Users are:

- Stored in ThunderID as human identities
- Authenticated via configurable flows (email OTP, passkey, social login, SAML, magic link)
- Assigned to tenants via organization unit membership
- Given **roles and groups** per tenant that determine their scopes

### 3.3 Agent (AI Agent Identity)

An **agent** is a non-human autonomous actor. In ThunderID, agents are **first-class identities**, not repurposed service accounts. Each agent has:

- Its own **Agent ID** (distinct from user IDs)
- An **owner** (the human accountable for it)
- **Attributes** from the agent schema (model, provider, function, team, etc.)
- Its own **OAuth2 client credentials** (client_id + client_secret)
- **Roles and groups** that determine its scopes (same RBAC as users)
- A **sub_type** of `agent` in tokens (so downstream services can distinguish)

**Two operating modes:**

| Mode | Grant Type | Token Claims | Use Case |
| --- | --- | --- | --- |
| **Autonomous** | `client_credentials` | `sub=agent-id, sub_type=agent` | Agent acts on its own: cron jobs, autonomous workflows, background processing |
| **Delegated** | `authorization_code` + PKCE, or `token_exchange` | `sub=user-id, act={sub: agent-id}` | Agent acts on behalf of a user: LLM assistants, copilots, user-facing AI tools |

### 3.4 Tenant Membership

A **membership** links a user or agent to a tenant with specific roles. In ThunderID terms:

- A user is added to an **Organization Unit** (the tenant)
- The user is assigned to **groups** and **roles** within that OU
- Roles grant **scopes** on specific **resource servers**

```text
Example:
  User "john@company.com"
    └── Tenant "monitoring-api" (OU)
          ├── Role: "operator"  → scopes: alerts:read, alerts:write, dashboards:read
          └── Role: "viewer"    → scopes: alerts:read, dashboards:read

  Agent "alert-cleanup-agent"
    └── Tenant "monitoring-api" (OU)
          └── Role: "operator"  → scopes: alerts:read, alerts:write
```

### 3.5 Resource Server

Each tenant registers its API as a **Resource Server** in ThunderID. This defines:

- The **audience** (`aud` claim in tokens)
- The available **scopes** (e.g., `alerts:read`, `alerts:write`, `pipelines:run`)
- The token lifetime for this resource

Tokens are always scoped to a specific resource server. A token for `monitoring-api` cannot be used against `data-pipeline`.

### 3.6 OAuth2 Access Token (JWT)

After authentication, ThunderID issues standard **OAuth2 access tokens** as signed JWTs (`typ: at+jwt`):

**Human token:**

```json
{
  "sub": "user-uuid",
  "sub_type": "user",
  "iss": "https://identity.internal:8090",
  "aud": "https://monitoring-api.internal",
  "scope": "alerts:read alerts:write dashboards:read",
  "exp": 1724547600,
  "iat": 1724544000,
  "jti": "unique-token-id",
  "client_id": "monitoring-app",
  "grant_type": "authorization_code"
}
```

**Autonomous agent token:**

```json
{
  "sub": "agent-uuid",
  "sub_type": "agent",
  "iss": "https://identity.internal:8090",
  "aud": "https://monitoring-api.internal",
  "scope": "alerts:read alerts:write",
  "exp": 1724547600,
  "iat": 1724544000,
  "jti": "unique-token-id",
  "client_id": "alert-cleanup-agent",
  "grant_type": "client_credentials"
}
```

**Delegated agent token (agent acting for user):**

```json
{
  "sub": "user-uuid",
  "sub_type": "user",
  "act": {
    "sub": "agent-uuid",
    "iss": "https://identity.internal:8090"
  },
  "iss": "https://identity.internal:8090",
  "aud": "https://monitoring-api.internal",
  "scope": "alerts:read",
  "exp": 1724547600,
  "iat": 1724544000,
  "jti": "unique-token-id",
  "client_id": "user-assistant-agent",
  "grant_type": "authorization_code"
}
```

**Design decisions:**

- **Standard OAuth2 JWT** — uses JWKS for verification, not custom key distribution
- **Resource-scoped** — each token targets one resource server (tenant API). If a token leaks, blast radius is one tenant.
- **`sub_type` claim** — lets tenant servers distinguish humans from agents with a single check
- **`act` claim** — records which agent is acting for which user, nested for delegation chains
- **Offline verification** — tenant servers fetch JWKS once and cache it. No callback to ThunderID needed per request.

### 3.7 Service Account vs Agent

The previous plan had "service accounts" with static API keys. In the ThunderID architecture:

| Old Concept | New Equivalent | Why |
| --- | --- | --- |
| Service account (static API key, bcrypt-hashed) | **Agent** with `client_credentials` grant | Proper OAuth2 credentials, JWKS-based verification, built-in rotation, audit trail, RBAC |
| Service account JWT | Standard OAuth2 access token with `sub_type=agent` | Standard format, standard verification |
| API key rotation | Client secret regeneration via ThunderID API/console | Built-in, audited |

Agents are strictly better: they have identity, attribution, audit trails, delegation capability, and standard OAuth2 credentials — all things that raw API keys lack.

---

## 4. Technology Stack

| Component | Technology | Version | Purpose |
| --- | --- | --- | --- |
| Identity + Auth + Agents | ThunderID | v1.0.1 (pin in production) | Human auth, agent identity, OAuth 2.1/OIDC, RBAC, admin console, login gate |
| Database | SQLite (embedded) | — | ThunderID data (identities, agents, OAuth clients, sessions, roles). 4 databases: config, entity, runtime_transient, runtime_persistent. No external DB required. |
| Email (dev) | MailSlurper | latest-smtps | Capture OTP/verification emails in dev |
| Bootstrap Service | Python 3.12 | — | One-shot scripts to register tenants, resource servers, agents |
| JWT Verification SDK | Python / Node.js / Go | — | Lightweight library for tenant servers to verify OAuth2 JWTs via JWKS |
| Containerization | Docker Compose | v5.x | Service orchestration |

> **Note:** ThunderID uses embedded SQLite by default, which is sufficient for the target scale (5-15 internal servers, moderate user base). For high-availability production deployments with multiple ThunderID replicas, the database sections in `deployment.yaml` can be switched to PostgreSQL. This is deferred to Phase 7 (Production Hardening).

---

## 5. Project Structure

```text
/home/ichoi2/work/kratos/
├── master-plan.md                          # This plan
├── master-plan-kratos-v1.md                # Previous Kratos-based plan (archived)
├── Makefile                                # Single entry point for all operations
├── docker-compose.yml                      # ThunderID + MailSlurper
├── .env                                    # Environment variables (not committed)
├── .env.example                            # Template with placeholder values
├── .gitignore
│
├── thunderid/                              # ThunderID configuration
│   └── deployment.yaml                     # Server config overrides (incl. CORS)
│
├── bootstrap/                              # Tenant & agent setup scripts
│   ├── requirements.txt                    # httpx, pyyaml
│   ├── bootstrap.py                        # Main bootstrap script
│   ├── seed_users.py                       # Assign users to tenants with roles
│   ├── config/
│   │   ├── tenants.yaml                    # Tenant definitions (OUs)
│   │   ├── resource-servers.yaml           # Resource server + scope definitions
│   │   ├── roles.yaml                      # Role → scope mappings per tenant
│   │   ├── agents.yaml                     # Agent definitions (autonomous + delegated)
│   │   └── users.yaml                      # User → tenant → role assignments
│
├── sdk/                                    # JWT verification libraries for tenant servers
│   ├── python/
│   │   ├── identity_sdk/
│   │   │   ├── __init__.py
│   │   │   ├── jwt_validator.py            # JWKS-based JWT verification
│   │   │   ├── decorators.py               # @require_scope("alerts:read")
│   │   │   └── middleware.py               # FastAPI/Flask middleware
│   │   ├── setup.py
│   │   └── README.md
│   ├── node/
│   │   ├── src/
│   │   │   ├── jwt-validator.ts            # JWKS-based JWT verification
│   │   │   └── middleware.ts               # Express middleware
│   │   ├── package.json
│   │   └── README.md
│   └── go/
│       ├── auth/
│       │   ├── middleware.go               # HTTP middleware
│       │   └── jwks.go                     # JWKS client + cache
│       ├── go.mod
│       └── README.md
│
├── scripts/
│   ├── test-all.sh                         # Full test suite runner
│   ├── test-phase1.sh                      # Phase 1: ThunderID setup tests
│   ├── test-phase2.sh                      # Phase 2: Bootstrap tests
│   ├── test-phase3.sh                      # Phase 3: Agent identity tests
│   ├── test-phase4.sh                      # Phase 4: End-to-end flow tests
│   ├── test-api.sh                         # API smoke tests (legacy)
│   ├── test-agent-flows.sh                 # Agent auth flow tests
│   ├── backup-db.sh                        # SQLite database backup
│   └── restore-db.sh                       # SQLite database restore
│
└── backups/                                # Database backups (not committed)
    └── .gitkeep
```

---

## 6. Phase 1: ThunderID Setup

### 6.1 Docker Compose — ThunderID + MailSlurper

**File: `docker-compose.yml`**

Services to define:

- `mailslurper` — Dev email server for OTP codes (SMTP: 1025, Web UI: 4436)
- `thunderid-setup` — One-shot container: generates TLS certs, JWT signing keys, crypto key, admin user, Direct Auth Secret. Runs `./setup.sh`, then exits.
- `thunderid` — Main ThunderID server on port 8090. Uses embedded SQLite (no external DB). Runs `./start.sh`.

> **No PostgreSQL container needed.** ThunderID uses embedded SQLite by default (4 databases stored in a Docker volume). This is sufficient for the target scale of 5-15 internal servers.

```yaml
services:
  mailslurper:
    image: oryd/mailslurper:latest-smtps
    ports:
      - "4436:4436"   # Web UI (dev only)
      - "1025:1025"   # SMTP (SSL)
    restart: unless-stopped

  thunderid-setup:
    image: ghcr.io/thunder-id/thunderid:latest
    command: ./setup.sh --verbose
    environment:
      ADMIN_USERNAME: ${ADMIN_USERNAME:-admin}
      ADMIN_PASSWORD: ${ADMIN_PASSWORD:-}
    volumes:
      - ./thunderid/deployment.yaml:/opt/thunderid/deployment.yaml
      - thunderid-certs:/opt/thunderid/config/certs
      - thunderid-secrets:/opt/thunderid/config/secrets
      - thunderid-db:/opt/thunderid/database
    restart: "no"

  thunderid:
    image: ghcr.io/thunder-id/thunderid:latest
    depends_on:
      thunderid-setup:
        condition: service_completed_successfully
    ports:
      - "8090:8090"
    volumes:
      - ./thunderid/deployment.yaml:/opt/thunderid/deployment.yaml
      - thunderid-certs:/opt/thunderid/config/certs
      - thunderid-secrets:/opt/thunderid/config/secrets
      - thunderid-db:/opt/thunderid/database
    healthcheck:
      test: ["CMD", "wget", "--no-verbose", "--tries=1",
             "--spider", "--no-check-certificate",
             "https://localhost:8090/health"]
      interval: 15s
      timeout: 5s
      retries: 5
      start_period: 30s
    restart: unless-stopped

volumes:
  thunderid-certs:     # TLS certs + JWT signing keys + crypto key
  thunderid-secrets:   # Direct Auth Secret
  thunderid-db:        # SQLite databases (config, entity, runtime_transient, runtime_persistent)
```

**Volume strategy:** Three named volumes separate concerns: `thunderid-certs` (TLS + signing keys), `thunderid-secrets` (Direct Auth Secret), `thunderid-db` (SQLite databases). This enables finer-grained backup and restore.

### 6.2 ThunderID Configuration (`deployment.yaml`)

This file overrides ThunderID's defaults. Only values that differ from the built-in `config/default.json` need to be specified.

```yaml
server:
  hostname: "0.0.0.0"
  public_url: "https://localhost:8090"
  port: 8090
  security:
    direct_auth_secret: "file://config/secrets/direct_auth_secret"

tls:
  min_version: "1.3"
  cert_file: "config/certs/server.cert"
  key_file: "config/certs/server.key"

# Database: uses embedded SQLite (default). No changes needed.
# To switch to PostgreSQL for production, see Section 18.3 (Phase 7).

email:
  smtp:
    host: "mailslurper"
    port: 1025
    username: "dev"
    password: "dev"
    from_address: "identity@internal.dev"
    enable_start_tls: false
    enable_authentication: false

passkey:
  allowed_origins:
    - "https://localhost:8090"

# Crypto, JWT, and key config use ThunderID's defaults.
# setup.sh generates all necessary keys into config/certs/ and config/secrets/.
```

### 6.3 Environment Variables (`.env`)

```bash
# Identity Service - Environment Variables
# This file is NOT committed to git. See .env.example for template.

# ThunderID admin credentials (auto-generated by setup if left blank)
ADMIN_USERNAME=admin
ADMIN_PASSWORD=

# ThunderID public URL (used in tokens, redirects)
THUNDERID_PUBLIC_URL=https://localhost:8090
```

**`.env.example`:**

```bash
# Copy to .env and fill in values
ADMIN_USERNAME=admin
ADMIN_PASSWORD=
THUNDERID_PUBLIC_URL=https://localhost:8090
```

### 6.4 How Setup Works

When `docker compose up` runs for the first time:

1. **`thunderid-setup`** runs `./setup.sh --verbose`:
   - Generates self-signed TLS cert + key (`config/certs/server.cert`, `server.key`)
   - Generates JWT signing keys: RSA (`signing.cert`, `signing.key`) + ECDSA (`ecdsa-signing.cert`, `ecdsa-signing.key`)
   - Generates AES encryption key (`config/certs/crypto.key`)
   - Generates Direct Auth Secret (`config/secrets/direct_auth_secret`)
   - Creates admin user with provided or auto-generated password
   - Creates default resources (default OU, user types, agent types, auth flows)
   - Prints admin credentials and Direct Auth Secret to stdout
   - Exits successfully
2. **`thunderid`** starts only after setup completes (`service_completed_successfully`)
3. **`mailslurper`** starts independently

**On subsequent runs:** Setup detects existing certs/keys and skips generation. Only missing resources are created. Setup is idempotent.

**Important:** On first run, capture the setup output to save:
- Admin password (if auto-generated)
- Direct Auth Secret (needed for bootstrap scripts in Phase 2)

```bash
# First run — capture credentials
docker compose up thunderid-setup 2>&1 | tee setup-output.txt

# Then start the server
docker compose up -d thunderid mailslurper
```

### 6.5 Implementation Steps

| # | Task | Files |
| --- | --- | --- |
| 1 | Create `.env` with admin credentials | `.env` |
| 2 | Create `.env.example` with placeholder values | `.env.example` |
| 3 | Create `docker-compose.yml` with thunderid-setup, thunderid, mailslurper | `docker-compose.yml` |
| 4 | Create `thunderid/deployment.yaml` with SMTP + server config | `thunderid/deployment.yaml` |
| 5 | Create `.gitignore` (exclude `.env`, `setup-output.txt`, `backups/`) | `.gitignore` |
| 6 | Run setup: `docker compose up thunderid-setup` — capture credentials | — |
| 7 | Start services: `docker compose up -d` | — |
| 8 | Verify health: `curl -k https://localhost:8090/health` | — |
| 9 | Access admin console: `https://localhost:8090/console` (login with admin creds) | — |
| 10 | Access login gate: `https://localhost:8090/gate` | — |
| 11 | Verify JWKS: `curl -k https://localhost:8090/oauth2/jwks` | — |
| 12 | Verify MailSlurper: `http://localhost:4436` | — |

---

## 7. Phase 2: Tenant & Resource Server Bootstrap

### 7.1 Purpose

After ThunderID is running, we need to configure it with our tenants, resource servers, roles, and scopes. This is done via ThunderID's REST API using a Python bootstrap script.

### 7.2 Tenant Configuration (`bootstrap/config/tenants.yaml`)

Each tenant maps to a ThunderID Organization Unit:

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

### 7.3 Resource Server Configuration (`bootstrap/config/resource-servers.yaml`)

Each tenant's API is registered as a resource server with its scopes:

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

### 7.4 Role Configuration (`bootstrap/config/roles.yaml`)

```yaml
roles:
  # Monitoring API roles
  - name: "monitoring-admin"
    tenant: "monitoring-api"
    scopes:
      - "alerts:read"
      - "alerts:write"
      - "alerts:delete"
      - "dashboards:read"
      - "dashboards:write"
      - "settings:manage"

  - name: "monitoring-operator"
    tenant: "monitoring-api"
    scopes:
      - "alerts:read"
      - "alerts:write"
      - "dashboards:read"

  - name: "monitoring-viewer"
    tenant: "monitoring-api"
    scopes:
      - "alerts:read"
      - "dashboards:read"

  # Data Pipeline roles
  - name: "pipeline-admin"
    tenant: "data-pipeline"
    scopes:
      - "pipelines:read"
      - "pipelines:run"
      - "pipelines:manage"
      - "data:read"

  - name: "pipeline-engineer"
    tenant: "data-pipeline"
    scopes:
      - "pipelines:read"
      - "pipelines:run"
      - "data:read"

  - name: "pipeline-readonly"
    tenant: "data-pipeline"
    scopes:
      - "pipelines:read"
      - "data:read"
```

### 7.5 Bootstrap Script (`bootstrap/bootstrap.py`)

```python
#!/usr/bin/env python3
"""
Bootstrap ThunderID with tenants, resource servers, roles, and agents.
Run once after ThunderID is up: python bootstrap/bootstrap.py

Authentication: Uses ThunderID's Direct Auth Secret, passed via the
'Direct-Auth-Secret' header. The secret is generated during setup
and stored in config/secrets/direct_auth_secret.

Set DIRECT_AUTH_SECRET env var or pass it as an argument.
"""
import httpx
import yaml
import sys
import os

THUNDERID_URL = os.getenv("THUNDERID_URL", "https://localhost:8090")
DIRECT_AUTH_SECRET = os.getenv("DIRECT_AUTH_SECRET", "")

def headers():
    """Headers for Direct API authentication."""
    return {
        "Direct-Auth-Secret": DIRECT_AUTH_SECRET,
        "Content-Type": "application/json",
    }

def create_tenants():
    """Register tenants as Organization Units."""
    with open("config/tenants.yaml") as f:
        config = yaml.safe_load(f)

    for tenant in config["tenants"]:
        print(f"Creating tenant: {tenant['handle']}")
        resp = httpx.post(
            f"{THUNDERID_URL}/organization-units",
            json={
                "handle": tenant["handle"],
                "name": tenant["name"],
                "description": tenant.get("description", ""),
            },
            headers=headers(),
            verify=False,
        )
        if resp.status_code in (200, 201):
            print(f"  ✓ Created: {tenant['handle']}")
        elif resp.status_code == 409:
            print(f"  - Already exists: {tenant['handle']}")
        else:
            print(f"  ✗ Error: {resp.status_code} {resp.text}")

def create_resource_servers():
    """Register resource servers with scopes."""
    with open("config/resource-servers.yaml") as f:
        config = yaml.safe_load(f)

    for rs in config["resource_servers"]:
        print(f"Creating resource server: {rs['identifier']}")
        resp = httpx.post(
            f"{THUNDERID_URL}/resource-servers",
            json={
                "identifier": rs["identifier"],
                "name": rs["name"],
                "scopes": [
                    {"name": s["name"], "description": s["description"]}
                    for s in rs["scopes"]
                ],
            },
            headers=headers(),
            verify=False,
        )
        if resp.status_code in (200, 201):
            print(f"  ✓ Created: {rs['identifier']}")
        else:
            print(f"  ✗ Error: {resp.status_code} {resp.text}")

def create_roles():
    """Create roles with scope assignments."""
    with open("config/roles.yaml") as f:
        config = yaml.safe_load(f)

    for role in config["roles"]:
        print(f"Creating role: {role['name']} for {role['tenant']}")
        resp = httpx.post(
            f"{THUNDERID_URL}/roles",
            json={
                "name": role["name"],
                "scopes": role["scopes"],
            },
            headers=headers(),
            verify=False,
        )
        if resp.status_code in (200, 201):
            print(f"  ✓ Created: {role['name']}")
        else:
            print(f"  ✗ Error: {resp.status_code} {resp.text}")

if __name__ == "__main__":
    if not DIRECT_AUTH_SECRET:
        print("Error: Set DIRECT_AUTH_SECRET environment variable")
        print("  Find it in setup-output.txt or run:")
        print("  docker compose exec thunderid cat config/secrets/direct_auth_secret")
        sys.exit(1)
    print("=== ThunderID Bootstrap ===")
    print(f"  URL: {THUNDERID_URL}")
    create_tenants()
    create_resource_servers()
    create_roles()
    print("\n=== Bootstrap complete ===")
```

### 7.6 User Seeding (`bootstrap/seed_users.py`)

After tenants and roles exist, assign initial users to tenants with roles. Users must already have accounts in ThunderID (created via Gate or API).

```python
#!/usr/bin/env python3
"""
Seed users into tenants with role assignments.
Run after bootstrap.py: python bootstrap/seed_users.py
"""
import httpx
import yaml
import sys
import os

THUNDERID_URL = os.getenv("THUNDERID_URL", "https://localhost:8090")
DIRECT_AUTH_SECRET = os.getenv("DIRECT_AUTH_SECRET", "")

def headers():
    return {"Direct-Auth-Secret": DIRECT_AUTH_SECRET, "Content-Type": "application/json"}

def get_user_by_email(email: str) -> dict | None:
    """Look up a user by email."""
    resp = httpx.get(
        f"{THUNDERID_URL}/users",
        params={"email": email},
        headers=headers(),
        verify=False,
    )
    if resp.status_code == 200:
        users = resp.json()
        return users[0] if users else None
    return None

def get_ou_by_handle(handle: str) -> dict | None:
    """Look up an Organization Unit by handle."""
    resp = httpx.get(
        f"{THUNDERID_URL}/organization-units",
        params={"handle": handle},
        headers=headers(),
        verify=False,
    )
    if resp.status_code == 200:
        ous = resp.json()
        for ou in ous:
            if ou.get("handle") == handle:
                return ou
    return None

def seed_users():
    """Assign users to tenants with roles."""
    with open("config/users.yaml") as f:
        config = yaml.safe_load(f)

    for assignment in config["user_assignments"]:
        email = assignment["email"]
        user = get_user_by_email(email)
        if not user:
            print(f"  ✗ User not found: {email} (must register via Gate first)")
            continue

        for membership in assignment["tenants"]:
            tenant_handle = membership["tenant"]
            roles = membership["roles"]
            ou = get_ou_by_handle(tenant_handle)
            if not ou:
                print(f"  ✗ Tenant not found: {tenant_handle}")
                continue

            print(f"Assigning {email} → {tenant_handle} with roles {roles}")
            resp = httpx.post(
                f"{THUNDERID_URL}/organization-units/{ou['id']}/members",
                json={"userId": user["id"], "roles": roles},
                headers=headers(),
                verify=False,
            )
            if resp.status_code in (200, 201):
                print(f"  ✓ Assigned: {email} → {tenant_handle}")
            elif resp.status_code == 409:
                print(f"  - Already assigned: {email} → {tenant_handle}")
            else:
                print(f"  ✗ Error: {resp.status_code} {resp.text}")

if __name__ == "__main__":
    if not DIRECT_AUTH_SECRET:
        print("Error: Set DIRECT_AUTH_SECRET environment variable")
        sys.exit(1)
    print("=== Seeding Users ===")
    seed_users()
    print("\n=== User seeding complete ===")
```

**User seed configuration (`bootstrap/config/users.yaml`):**

```yaml
user_assignments:
  # Assign users to tenants with roles
  # Users must already exist in ThunderID (registered via Gate)
  - email: "admin@company.com"
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

### 7.7 Implementation Steps

| # | Task | Files |
| --- | --- | --- |
| 1 | Create `bootstrap/config/tenants.yaml` | `bootstrap/config/tenants.yaml` |
| 2 | Create `bootstrap/config/resource-servers.yaml` | `bootstrap/config/resource-servers.yaml` |
| 3 | Create `bootstrap/config/roles.yaml` | `bootstrap/config/roles.yaml` |
| 4 | Create `bootstrap/config/users.yaml` | `bootstrap/config/users.yaml` |
| 5 | Create `bootstrap/bootstrap.py` | `bootstrap/bootstrap.py` |
| 6 | Create `bootstrap/seed_users.py` | `bootstrap/seed_users.py` |
| 7 | Create `bootstrap/requirements.txt` (httpx, pyyaml) | `bootstrap/requirements.txt` |
| 8 | Run bootstrap: `python bootstrap/bootstrap.py` | — |
| 9 | Register test users via Gate, then run: `python bootstrap/seed_users.py` | — |
| 10 | Verify via ThunderID console: check OUs, resource servers, roles, memberships | — |

---

## 8. Phase 3: Agent Identity Setup

### 8.1 Purpose

Register AI agents as first-class identities in ThunderID. Each agent gets its own credentials, roles, and audit trail.

### 8.2 Agent Configuration (`bootstrap/config/agents.yaml`)

```yaml
agents:
  # Autonomous agents (act on their own, no user involved)
  - name: "alert-cleanup-agent"
    tenant: "monitoring-api"
    type: "default"
    mode: "autonomous"      # client_credentials only
    description: "Cleans up expired alerts nightly"
    attributes:
      model: "gpt-4"
      modelProvider: "openai"
      function: "alert-cleanup"
      team: "platform"
    roles:
      - "monitoring-operator"
    scopes:
      - "alerts:read"
      - "alerts:write"

  - name: "pipeline-scheduler-agent"
    tenant: "data-pipeline"
    type: "default"
    mode: "autonomous"
    description: "Schedules and triggers data pipeline runs"
    attributes:
      model: "claude-3-5-sonnet"
      modelProvider: "anthropic"
      function: "pipeline-scheduler"
      team: "data-engineering"
    roles:
      - "pipeline-engineer"
    scopes:
      - "pipelines:read"
      - "pipelines:run"

  # Delegated agents (act on behalf of users)
  - name: "monitoring-assistant"
    tenant: "monitoring-api"
    type: "default"
    mode: "delegated"       # authorization_code + PKCE, can also use client_credentials
    description: "AI assistant that helps users investigate alerts"
    attributes:
      model: "gpt-4"
      modelProvider: "openai"
      function: "user-assistant"
      team: "platform"
    redirect_uris:
      - "http://localhost:3000/callback"
    scopes:
      - "alerts:read"
      - "dashboards:read"
```

### 8.3 Agent Bootstrap Logic

```python
def create_agents():
    """Register AI agents in ThunderID."""
    with open("config/agents.yaml") as f:
        config = yaml.safe_load(f)

    for agent in config["agents"]:
        print(f"Creating agent: {agent['name']}")

        # Build the request based on mode
        body = {
            "name": agent["name"],
            "type": agent["type"],
            "description": agent.get("description", ""),
            "attributes": agent.get("attributes", {}),
        }

        # Inbound auth config for OAuth2
        if agent["mode"] == "autonomous":
            body["inboundAuthConfig"] = [{
                "type": "oauth2",
                "config": {
                    "grantTypes": ["client_credentials"],
                    "tokenEndpointAuthMethod": "client_secret_basic",
                    "scopes": agent.get("scopes", []),
                },
            }]
        elif agent["mode"] == "delegated":
            body["inboundAuthConfig"] = [{
                "type": "oauth2",
                "config": {
                    "grantTypes": ["client_credentials", "authorization_code"],
                    "tokenEndpointAuthMethod": "client_secret_basic",
                    "scopes": agent.get("scopes", []),
                    "redirectUris": agent.get("redirect_uris", []),
                    "pkceRequired": True,
                },
            }]

        resp = httpx.post(
            f"{THUNDERID_URL}/agents",
            json=body,
            headers=headers(),
            verify=False,
        )

        if resp.status_code in (200, 201):
            data = resp.json()
            print(f"  ✓ Created: {agent['name']}")
            print(f"    Agent ID:      {data['id']}")
            print(f"    Client ID:     {data.get('clientId', 'N/A')}")
            if "clientSecret" in data:
                print(f"    Client Secret: {data['clientSecret']}")
                print(f"    ⚠ SAVE THIS SECRET — it is shown only once!")
        else:
            print(f"  ✗ Error: {resp.status_code} {resp.text}")
```

### 8.4 Agent Token Examples

**Autonomous agent getting its own token:**

```bash
# alert-cleanup-agent authenticates with client_credentials
curl -X POST https://localhost:8090/oauth2/token \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -u '<AGENT_CLIENT_ID>:<AGENT_CLIENT_SECRET>' \
  -d 'grant_type=client_credentials' \
  -d 'resource=https://monitoring-api.internal' \
  -d 'scope=alerts:read alerts:write'

# Response:
# {
#   "access_token": "eyJ...",
#   "token_type": "Bearer",
#   "expires_in": 3600,
#   "scope": "alerts:read alerts:write"
# }
#
# Decoded token:
# {
#   "sub": "<agent-uuid>",
#   "sub_type": "agent",
#   "aud": "https://monitoring-api.internal",
#   "scope": "alerts:read alerts:write",
#   "client_id": "<agent-client-id>",
#   "grant_type": "client_credentials",
#   ...
# }
```

**Delegated agent acting for a user:**

```bash
# Step 1: Agent redirects user to authorize
# GET https://localhost:8090/oauth2/authorize?
#   response_type=code&
#   client_id=<AGENT_CLIENT_ID>&
#   redirect_uri=http://localhost:3000/callback&
#   scope=alerts:read dashboards:read&
#   resource=https://monitoring-api.internal&
#   code_challenge=<PKCE_CHALLENGE>&
#   code_challenge_method=S256

# Step 2: User logs in via ThunderID gate, consents
# ThunderID redirects to: http://localhost:3000/callback?code=<AUTH_CODE>

# Step 3: Agent exchanges code for token
curl -X POST https://localhost:8090/oauth2/token \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -u '<AGENT_CLIENT_ID>:<AGENT_CLIENT_SECRET>' \
  -d 'grant_type=authorization_code' \
  -d 'code=<AUTH_CODE>' \
  -d 'redirect_uri=http://localhost:3000/callback' \
  -d 'code_verifier=<PKCE_VERIFIER>'

# Decoded token:
# {
#   "sub": "<user-uuid>",         ← user is the subject
#   "act": {"sub": "<agent-uuid>"}, ← agent is the actor
#   "aud": "https://monitoring-api.internal",
#   "scope": "alerts:read dashboards:read",
#   ...
# }
```

### 8.5 Implementation Steps

| # | Task | Files |
| --- | --- | --- |
| 1 | Create `bootstrap/config/agents.yaml` | `bootstrap/config/agents.yaml` |
| 2 | Add `create_agents()` to `bootstrap/bootstrap.py` | `bootstrap/bootstrap.py` |
| 3 | Run bootstrap with agents: `python bootstrap/bootstrap.py` | — |
| 4 | Save agent client secrets securely | — |
| 5 | Test autonomous agent token: `client_credentials` grant | — |
| 6 | Test delegated agent flow: `authorization_code` + PKCE | — |
| 7 | Verify agent tokens in JWKS-based validation | — |

---

## 9. Token Lifecycle: Refresh & Revocation

### 9.1 Token Refresh Flow

Access tokens expire (default: 1 hour). Clients use refresh tokens to get new access tokens without re-authenticating.

**When refresh tokens are issued:**

- `authorization_code` grant (human login, delegated agents) — refresh token included in response
- `client_credentials` grant (autonomous agents) — **no refresh token** (agent re-authenticates with its credentials)

**Refresh flow:**

```text
1. Client detects access_token is expired (or near expiry)
2. Client → ThunderID:  POST /oauth2/token
                         grant_type=refresh_token
                         refresh_token=<REFRESH_TOKEN>
                         client_id=<CLIENT_ID>
                         client_secret=<CLIENT_SECRET>  (confidential clients only)
3. ThunderID            : Validates refresh token (not expired, not revoked)
4. ThunderID → Client   : New access_token + new refresh_token
                          Old refresh_token is invalidated (rotation)
```

**Example:**

```bash
curl -X POST https://localhost:8090/oauth2/token \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -d 'grant_type=refresh_token' \
  -d 'refresh_token=<REFRESH_TOKEN>' \
  -d 'client_id=<CLIENT_ID>' \
  -d 'client_secret=<CLIENT_SECRET>'

# Response:
# {
#   "access_token": "eyJ...(new)...",
#   "token_type": "Bearer",
#   "expires_in": 3600,
#   "refresh_token": "new-refresh-token",
#   "scope": "alerts:read alerts:write"
# }
```

**Refresh token behavior:**

| Behavior | Description |
| --- | --- |
| Rotation | Each refresh issues a new refresh token; old one is invalidated |
| Reuse detection | If a rotated-out refresh token is used again, ThunderID revokes the entire token family (indicates theft) |
| Expiry | Refresh tokens expire after a configurable period (default: 30 days) |
| Scope | Refresh cannot expand scopes beyond the original grant |

**Client-side handling (pseudocode):**

```python
async def authenticated_request(url, method="GET", **kwargs):
    """Make a request, refreshing the token if expired."""
    resp = await client.request(method, url, headers=auth_headers(), **kwargs)

    if resp.status_code == 401:
        # Token expired — attempt refresh
        new_tokens = await refresh_access_token()
        if new_tokens:
            save_tokens(new_tokens)
            resp = await client.request(method, url, headers=auth_headers(), **kwargs)
        else:
            # Refresh failed — re-authenticate
            raise AuthenticationRequired()

    return resp
```

### 9.2 Token Revocation

Tokens can be revoked before they expire. This is used when:

- A user logs out
- An agent is compromised
- An admin removes a user from a tenant
- Agent credentials are rotated

**Revocation endpoint:**

```bash
# Revoke a refresh token (recommended — also prevents future access tokens)
curl -X POST https://localhost:8090/oauth2/revoke \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -u '<CLIENT_ID>:<CLIENT_SECRET>' \
  -d 'token=<REFRESH_TOKEN>' \
  -d 'token_type_hint=refresh_token'

# Revoke an access token
curl -X POST https://localhost:8090/oauth2/revoke \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -u '<CLIENT_ID>:<CLIENT_SECRET>' \
  -d 'token=<ACCESS_TOKEN>' \
  -d 'token_type_hint=access_token'
```

**Agent-specific revocation:**

```bash
# Option 1: Regenerate agent's client secret (invalidates all future tokens)
curl -X POST https://localhost:8090/agents/<AGENT_ID>/regenerate-secret \
  -H "Direct-Auth-Secret: $DIRECT_AUTH_SECRET"

# Option 2: Delete the agent entirely
curl -X DELETE https://localhost:8090/agents/<AGENT_ID> \
  -H "Direct-Auth-Secret: $DIRECT_AUTH_SECRET"
```

### 9.3 Offline Verification Trade-Off

**Important:** Tenant servers verify JWTs offline using cached JWKS keys. This means:

> **A revoked access token remains valid at tenant servers until it expires (default: 1 hour).** This is an accepted trade-off for the performance benefit of offline verification (~1ms per request vs ~50-100ms for introspection).

| Approach | Latency | Revocation Propagation | When to Use |
| --- | --- | --- | --- |
| **Offline (JWKS)** — default | ~1ms | Token must expire (up to 1 hour) | Most API requests |
| **Online (introspection)** | ~50-100ms | Immediate | High-security operations (e.g., money transfer, admin actions) |

**For operations requiring immediate revocation checks**, use token introspection:

```python
def verify_token_online(token: str) -> dict:
    """Verify token via introspection (immediate revocation check)."""
    resp = httpx.post(
        f"{THUNDERID_URL}/oauth2/introspect",
        data={"token": token},
        auth=(CLIENT_ID, CLIENT_SECRET),
        verify=False,
    )
    data = resp.json()
    if not data.get("active"):
        raise HTTPException(401, "Token is not active (expired or revoked)")
    return data
```

**Mitigation strategies for the offline gap:**

1. **Short token lifetimes** — Reduce access token TTL to 15 minutes for sensitive resource servers
2. **Hybrid approach** — Use offline verification for reads, introspection for writes/deletes
3. **JWKS refresh on revocation event** — If ThunderID supports webhooks, trigger JWKS cache refresh on revocation events (future enhancement)

---

## 10. Phase 4: Integration & Testing

### 10.1 End-to-End Flow Test

1. **Start all services:**

   ```bash
   docker compose up -d
   ```

2. **Run bootstrap:**

   ```bash
   cd bootstrap && python bootstrap.py
   ```

3. **Register a user (via ThunderID gate):**

   Navigate to `https://localhost:8090/gate` → register with email → check MailSlurper at `http://localhost:4436` for code → complete registration.

4. **Assign user to a tenant (via console or API):**

   Navigate to `https://localhost:8090/console` → Organization Units → select tenant → add user → assign roles.

   Or via API:

   ```bash
   curl -X POST https://localhost:8090/organization-units/<OU_ID>/members \
     -H "Direct-Auth-Secret: $DIRECT_AUTH_SECRET" \
     -H "Content-Type: application/json" \
     -d '{"userId": "<user-id>", "roles": ["monitoring-operator"]}'
   ```

5. **Get user token for a tenant:**

   ```bash
   # After user login, exchange session for token scoped to monitoring-api
   curl -X POST https://localhost:8090/oauth2/token \
     -H 'Content-Type: application/x-www-form-urlencoded' \
     -d 'grant_type=authorization_code' \
     -d 'code=<AUTH_CODE>' \
     -d 'resource=https://monitoring-api.internal' \
     -d 'scope=alerts:read alerts:write'
   ```

6. **Get autonomous agent token:**

   ```bash
   curl -X POST https://localhost:8090/oauth2/token \
     -u '<AGENT_CLIENT_ID>:<AGENT_CLIENT_SECRET>' \
     -d 'grant_type=client_credentials' \
     -d 'resource=https://monitoring-api.internal' \
     -d 'scope=alerts:read alerts:write'
   ```

7. **Verify token offline (as a tenant server would):**

   ```bash
   # Get JWKS
   curl -s https://localhost:8090/oauth2/jwks | python3 -m json.tool

   # Verify token with the JWKS
   python3 -c "
   import jwt, httpx, json
   from jwt import PyJWKClient

   jwks_client = PyJWKClient('https://localhost:8090/oauth2/jwks')
   token = '<ACCESS_TOKEN>'
   signing_key = jwks_client.get_signing_key_from_jwt(token)
   claims = jwt.decode(token, signing_key.key, algorithms=['RS256'],
                        audience='https://monitoring-api.internal')
   print(json.dumps(claims, indent=2))
   "
   ```

8. **Test agent-to-agent delegation:**

   ```bash
   curl -X POST https://localhost:8090/oauth2/token \
     -u '<WORKER_CLIENT_ID>:<WORKER_CLIENT_SECRET>' \
     -d 'grant_type=urn:ietf:params:oauth:grant-type:token-exchange' \
     -d "subject_token=<SUBJECT_TOKEN>" \
     -d 'subject_token_type=urn:ietf:params:oauth:token-type:jwt' \
     -d "actor_token=<CALLING_AGENT_TOKEN>" \
     -d 'actor_token_type=urn:ietf:params:oauth:token-type:jwt' \
     -d 'scope=alerts:read'
   ```

### 10.2 Smoke Test Script (`scripts/test-api.sh`)

```bash
#!/bin/bash
set -e

BASE_URL="https://localhost:8090"
VERIFY="--insecure"  # dev only

echo "=== ThunderID Health ==="
curl -sf $VERIFY "$BASE_URL/health" | python3 -m json.tool

echo "=== OIDC Discovery ==="
curl -sf $VERIFY "$BASE_URL/.well-known/openid-configuration" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(f'Issuer:   {d[\"issuer\"]}')
print(f'Token:    {d[\"token_endpoint\"]}')
print(f'JWKS:     {d[\"jwks_uri\"]}')
print(f'Grants:   {d.get(\"grant_types_supported\", [])}')
"

echo "=== JWKS ==="
curl -sf $VERIFY "$BASE_URL/oauth2/jwks" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(f'Keys: {len(d[\"keys\"])}')
for k in d['keys']:
    print(f'  kid={k[\"kid\"]} alg={k[\"alg\"]} kty={k[\"kty\"]}')
"

echo "=== All smoke tests passed! ==="
```

### 10.3 Comprehensive Test Plan

#### Phase 1 Tests: ThunderID Setup

| # | Test Case | Command / Action | Expected Result | Type |
| --- | --- | --- | --- | --- |
| 1.1 | Health endpoint responds | `curl https://localhost:8090/health` | `200 OK` with JSON body | Smoke |
| 1.2 | OIDC discovery available | `curl https://localhost:8090/.well-known/openid-configuration` | Valid JSON with `issuer`, `token_endpoint`, `jwks_uri` | Smoke |
| 1.3 | JWKS endpoint returns keys | `curl https://localhost:8090/oauth2/jwks` | JSON with `keys` array, at least 1 RS256 key | Smoke |
| 1.4 | Admin console loads | Browser → `https://localhost:8090/console` | Login page renders | Smoke |
| 1.5 | Login gate loads | Browser → `https://localhost:8090/gate` | Registration/login page renders | Smoke |
| 1.6 | MailSlurper receives test email | Register via Gate, check `http://localhost:4436` | OTP email visible in MailSlurper | Smoke |
| 1.7 | No database port exposed | Verify no DB ports bound to host | SQLite is embedded, no external DB ports | Security |

**Script:** `scripts/test-phase1.sh`

#### Phase 2 Tests: Bootstrap

| # | Test Case | Command / Action | Expected Result | Type |
| --- | --- | --- | --- | --- |
| 2.1 | Bootstrap creates tenants | Run `bootstrap.py` | All tenants created (check console) | Integration |
| 2.2 | Bootstrap creates resource servers | Run `bootstrap.py` | Resource servers visible with correct scopes | Integration |
| 2.3 | Bootstrap creates roles | Run `bootstrap.py` | Roles visible with correct scope assignments | Integration |
| 2.4 | Bootstrap is idempotent | Run `bootstrap.py` twice | Second run shows "Already exists" for all, no errors | Integration |
| 2.5 | User seeding works | Run `seed_users.py` | Users assigned to tenants with correct roles | Integration |
| 2.6 | User seeding is idempotent | Run `seed_users.py` twice | Second run shows "Already assigned", no errors | Integration |
| 2.7 | Invalid tenant handle | Add bad handle to config | Clear error message, other tenants still created | Negative |

**Script:** `scripts/test-phase2.sh`

#### Phase 3 Tests: Agent Identity

| # | Test Case | Command / Action | Expected Result | Type |
| --- | --- | --- | --- | --- |
| 3.1 | Autonomous agent created | Run bootstrap with agents | Agent created, client_id + client_secret returned | Integration |
| 3.2 | Delegated agent created | Run bootstrap with agents | Agent created with redirect URIs and PKCE required | Integration |
| 3.3 | Agent `client_credentials` token | `POST /oauth2/token` with agent creds | JWT with `sub_type=agent`, correct scopes | Integration |
| 3.4 | Agent wrong secret | `POST /oauth2/token` with bad secret | `401 Unauthorized` | Negative |
| 3.5 | Agent requests disallowed scope | Request scope not granted to agent | Token issued with only granted scopes (downscoped) | Negative |
| 3.6 | Agent token has correct claims | Decode JWT from 3.3 | `sub`, `sub_type`, `aud`, `scope`, `jti`, `exp` all present | Validation |

**Script:** `scripts/test-phase3.sh`

#### Phase 4 Tests: End-to-End Flows

| # | Test Case | Command / Action | Expected Result | Type |
| --- | --- | --- | --- | --- |
| 4.1 | Human login → token | Register + login via Gate, get token | JWT with `sub_type=user`, correct scopes | E2E |
| 4.2 | Token has correct audience | Decode JWT from 4.1 | `aud` matches resource server identifier | Validation |
| 4.3 | Token verified via JWKS | Verify token using `PyJWKClient` | Claims decoded successfully | E2E |
| 4.4 | Expired token rejected | Use a token past its `exp` | `401` from tenant server | Negative |
| 4.5 | Wrong audience rejected | Use monitoring token against pipeline server | `401` (audience mismatch) | Negative |
| 4.6 | Missing scope → 403 | Token with `alerts:read` hits `alerts:delete` endpoint | `403 Forbidden` with scope error | Negative |
| 4.7 | Valid scope → 200 | Token with `alerts:read` hits `GET /alerts` | `200 OK` with caller identity | E2E |
| 4.8 | Delegated agent token | Agent authorization_code flow | JWT with `sub=user`, `act.sub=agent` | E2E |
| 4.9 | Agent-to-agent delegation | Token exchange flow | JWT with nested `act` claims | E2E |
| 4.10 | Token refresh | `grant_type=refresh_token` | New access_token + new refresh_token | E2E |
| 4.11 | Refresh token rotation | Use old refresh token after rotation | `401` (reuse detection) | Negative |
| 4.12 | Token revocation | Revoke refresh token, try to use it | `401` | E2E |
| 4.13 | Revoked access token (online) | Revoke access token, introspect it | `active: false` | E2E |
| 4.14 | Revoked access token (offline) | Revoke access token, verify via JWKS | Still valid until expiry (expected) | Known behavior |
| 4.15 | JWKS cache resilience | Stop ThunderID, verify cached token | Verification succeeds with cached keys | Resilience |
| 4.16 | No auth header → 401 | Request without `Authorization` header | `401 Missing Authorization header` | Negative |

**Script:** `scripts/test-phase4.sh`

#### Integration Tests Per Tenant Server

| # | Test Case | Expected Result | Type |
| --- | --- | --- | --- |
| I.1 | No JWT → 401 | `401` with clear error | Negative |
| I.2 | Malformed JWT → 401 | `401` with "Invalid token" | Negative |
| I.3 | Valid JWT, wrong audience → 401 | `401` (audience mismatch) | Negative |
| I.4 | Valid JWT, correct aud, missing scope → 403 | `403` with required vs actual scopes | Negative |
| I.5 | Valid JWT, correct aud, correct scope → 200 | `200` with response | Positive |
| I.6 | Expired JWT → 401 | `401 Token expired` | Negative |
| I.7 | Human token → caller type is user | `sub_type=user` in response | Positive |
| I.8 | Agent token → caller type is agent | `sub_type=agent` in response | Positive |
| I.9 | Delegated token → `act` claim accessible | `acting_agent` field populated | Positive |
| I.10 | `/health` bypasses auth | `200` without any JWT | Positive |

### 10.4 Test Script Runner (`scripts/test-all.sh`)

```bash
#!/bin/bash
set -e

echo "========================================="
echo "  Identity Service — Full Test Suite"
echo "========================================="

echo ""
echo "--- Phase 1: ThunderID Setup ---"
bash scripts/test-phase1.sh

echo ""
echo "--- Phase 2: Bootstrap ---"
bash scripts/test-phase2.sh

echo ""
echo "--- Phase 3: Agent Identity ---"
bash scripts/test-phase3.sh

echo ""
echo "--- Phase 4: End-to-End Flows ---"
bash scripts/test-phase4.sh

echo ""
echo "========================================="
echo "  All tests passed!"
echo "========================================="
```

### 10.5 Implementation Steps

| # | Task | Files |
| --- | --- | --- |
| 1 | Run end-to-end flow tests (manual, Section 10.1) | — |
| 2 | Create Phase 1 test script | `scripts/test-phase1.sh` |
| 3 | Create Phase 2 test script | `scripts/test-phase2.sh` |
| 4 | Create Phase 3 test script | `scripts/test-phase3.sh` |
| 5 | Create Phase 4 test script | `scripts/test-phase4.sh` |
| 6 | Create test runner | `scripts/test-all.sh` |
| 7 | Run full test suite: `bash scripts/test-all.sh` | — |

---

## 11. Integrating Existing Servers

This section shows how to integrate an existing auth-free REST API server with the identity service.

### 11.1 Before vs After

#### Before (no auth)

```text
┌────────────┐         ┌───────────────────────────┐
│  Client /  │────────▶│  Monitoring API             │
│  Browser   │◀────────│  Port 9000                 │
│            │         │                            │
│            │         │  GET /alerts      → anyone │
│            │         │  POST /alerts     → anyone │
│            │         │  DELETE /alerts   → anyone │
└────────────┘         └───────────────────────────┘
```

#### After (auth via ThunderID)

```text
┌────────────┐         ┌───────────────────────────────────────────┐
│  Client /  │         │  Monitoring API — Port 9000                │
│  Browser   │         │                                           │
│  or Agent  │         │  GET  /alerts      → scope: alerts:read   │
│            │         │  POST /alerts      → scope: alerts:write  │
│            │         │  DELETE /alerts    → scope: alerts:delete  │
│            │         │                                           │
│            │         │  • No user tables                         │
│            │         │  • No login endpoints                     │
│            │         │  • No session storage                     │
│            │         │  • Verifies JWT via JWKS (offline, ~1ms)  │
│            │         │  • Reads scopes + sub_type from claims    │
│            │         │  • Knows if caller is human or agent      │
└─────┬──────┘         └───────────────────┬───────────────────────┘
      │                                     │
      │  1. Login (human) or               │  Startup: fetch JWKS
      │     client_credentials (agent)      │
      ▼                                     ▼
┌──────────────────────────────────────────────────────────────────┐
│              ThunderID Identity Service                           │
│              https://identity.internal:8090                       │
│                                                                  │
│  /gate                      → Human login (OTP, passkey, etc.)  │
│  /oauth2/authorize          → OAuth2 authorize (human + agent)  │
│  /oauth2/token              → Token issuance (all grant types)  │
│  /oauth2/jwks               → JWKS for offline verification    │
│  /agents                    → Agent management                  │
│  /organization-units        → Tenant management                 │
│  /console                   → Admin UI                          │
└──────────────────────────────────────────────────────────────────┘
```

### 11.2 Step-by-Step Integration

#### Step 1: Register the Tenant's API as a Resource Server

```bash
curl -X POST https://identity.internal:8090/resource-servers \
  -H "Direct-Auth-Secret: $DIRECT_AUTH_SECRET" \
  -H "Content-Type: application/json" \
  -d '{
    "identifier": "https://monitoring-api.internal",
    "name": "Monitoring API",
    "scopes": [
      {"name": "alerts:read", "description": "View alerts"},
      {"name": "alerts:write", "description": "Create/update alerts"},
      {"name": "alerts:delete", "description": "Delete alerts"},
      {"name": "dashboards:read", "description": "View dashboards"}
    ]
  }'
```

#### Step 2: Create Roles and Assign Users/Agents

```bash
# Via ThunderID console (https://identity.internal:8090/console):
# 1. Go to the tenant's Organization Unit
# 2. Create roles with appropriate scopes
# 3. Add users and agents, assign roles
```

#### Step 3: Add JWT Auth Middleware to the Server

**Python / FastAPI — Full Implementation:**

```python
# tenant_server/auth.py
import httpx
from jwt import PyJWKClient
import jwt
from fastapi import Request, HTTPException
from starlette.middleware.base import BaseHTTPMiddleware
from functools import wraps
from typing import Optional
import os

# ──────────────────────────────────────────────
# Configuration
# ──────────────────────────────────────────────
THUNDERID_URL = os.getenv("THUNDERID_URL", "https://identity.internal:8090")
RESOURCE_ID = os.getenv("RESOURCE_ID", "https://monitoring-api.internal")
JWKS_URL = os.getenv("JWKS_URL", f"{THUNDERID_URL}/oauth2/jwks")

# ──────────────────────────────────────────────
# JWKS Client (cached, auto-refreshing)
# ──────────────────────────────────────────────
_jwks_client = PyJWKClient(JWKS_URL, cache_jwk_set=True, lifespan=3600)

# ──────────────────────────────────────────────
# Parsed identity from token
# ──────────────────────────────────────────────
class CallerIdentity:
    """Parsed caller identity from OAuth2 JWT claims."""
    def __init__(self, claims: dict):
        self.subject: str = claims["sub"]
        self.subject_type: str = claims.get("sub_type", "user")  # "user" or "agent"
        self.scopes: list[str] = claims.get("scope", "").split()
        self.client_id: str = claims.get("client_id", "")
        self.grant_type: str = claims.get("grant_type", "")
        self.raw_claims: dict = claims

        # Delegation: who is acting?
        act = claims.get("act")
        self.acting_agent: Optional[str] = act["sub"] if act else None
        self.is_delegated: bool = act is not None

    @property
    def is_agent(self) -> bool:
        return self.subject_type == "agent"

    @property
    def is_human(self) -> bool:
        return self.subject_type == "user"

    def has_scope(self, scope: str) -> bool:
        return scope in self.scopes

    def has_any_scope(self, scopes: list[str]) -> bool:
        return any(s in self.scopes for s in scopes)

def verify_token(token: str) -> CallerIdentity:
    """Verify JWT via JWKS and return CallerIdentity."""
    try:
        signing_key = _jwks_client.get_signing_key_from_jwt(token)
        claims = jwt.decode(
            token,
            signing_key.key,
            algorithms=["RS256"],
            audience=RESOURCE_ID,
        )
    except jwt.ExpiredSignatureError:
        raise HTTPException(401, "Token expired")
    except jwt.InvalidTokenError as e:
        raise HTTPException(401, f"Invalid token: {e}")

    return CallerIdentity(claims)

# ──────────────────────────────────────────────
# FastAPI Middleware
# ──────────────────────────────────────────────
PUBLIC_PATHS = {"/health", "/docs", "/openapi.json", "/redoc"}

class JWTAuthMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request: Request, call_next):
        if request.url.path in PUBLIC_PATHS:
            return await call_next(request)

        auth_header = request.headers.get("Authorization", "")
        if not auth_header.startswith("Bearer "):
            raise HTTPException(401, "Missing Authorization header")

        token = auth_header[7:]
        request.state.caller = verify_token(token)
        return await call_next(request)

# ──────────────────────────────────────────────
# Scope-checking Decorator
# ──────────────────────────────────────────────
def require_scope(*scopes: str):
    """Decorator: caller must have at least one of the given scopes."""
    def decorator(func):
        @wraps(func)
        async def wrapper(request: Request, *args, **kwargs):
            caller: CallerIdentity = request.state.caller
            if not caller.has_any_scope(list(scopes)):
                raise HTTPException(
                    403,
                    f"Requires scope: {', '.join(scopes)}. "
                    f"You have: {', '.join(caller.scopes)}"
                )
            return await func(request, *args, **kwargs)
        return wrapper
    return decorator
```

#### Step 4: Wire Middleware into App

```python
# tenant_server/main.py
from fastapi import FastAPI
from .auth import JWTAuthMiddleware

app = FastAPI(title="Monitoring API")
app.add_middleware(JWTAuthMiddleware)

@app.on_event("startup")
async def startup():
    print("JWT auth middleware active — verifying tokens via JWKS")
```

#### Step 5: Protect Routes with Scope Checks

```python
# tenant_server/routes/alerts.py
from fastapi import APIRouter, Request
from ..auth import require_scope

router = APIRouter(prefix="/alerts", tags=["Alerts"])

@router.get("/")
async def list_alerts(request: Request):
    """Any authenticated caller with alerts:read scope."""
    caller = request.state.caller
    return {
        "alerts": [...],
        "requested_by": caller.subject,
        "caller_type": caller.subject_type,  # "user" or "agent"
        "is_delegated": caller.is_delegated,
        "acting_agent": caller.acting_agent,
    }

@router.post("/")
@require_scope("alerts:write")
async def create_alert(request: Request):
    """Requires alerts:write scope — humans with operator role, or authorized agents."""
    caller = request.state.caller
    return {"created_by": caller.subject, "via_agent": caller.acting_agent}

@router.delete("/{alert_id}")
@require_scope("alerts:delete")
async def delete_alert(request: Request, alert_id: str):
    """Requires alerts:delete scope — admin only."""
    return {"deleted": alert_id}
```

### 11.3 Node.js / Express Integration

```javascript
// tenant_server/auth.js
const jwt = require("jsonwebtoken");
const jwksClient = require("jwks-rsa");

const RESOURCE_ID = process.env.RESOURCE_ID || "https://monitoring-api.internal";
const JWKS_URI = process.env.JWKS_URL || "https://identity.internal:8090/oauth2/jwks";

const client = jwksClient({ jwksUri: JWKS_URI, cache: true, rateLimit: true });

function getKey(header, callback) {
  client.getSigningKey(header.kid, (err, key) => {
    callback(err, key ? key.getPublicKey() : null);
  });
}

function authMiddleware(req, res, next) {
  if (["/health", "/docs"].includes(req.path)) return next();

  const header = req.headers.authorization || "";
  if (!header.startsWith("Bearer ")) {
    return res.status(401).json({ error: "Missing Authorization header" });
  }

  const token = header.slice(7);
  jwt.verify(token, getKey, { algorithms: ["RS256"], audience: RESOURCE_ID }, (err, claims) => {
    if (err) {
      const status = err.name === "TokenExpiredError" ? 401 : 401;
      return res.status(status).json({ error: err.message });
    }

    req.caller = {
      subject: claims.sub,
      subjectType: claims.sub_type || "user",
      scopes: (claims.scope || "").split(" "),
      clientId: claims.client_id,
      actingAgent: claims.act ? claims.act.sub : null,
      isDelegated: !!claims.act,
      isAgent: claims.sub_type === "agent",
    };
    next();
  });
}

function requireScope(...scopes) {
  return (req, res, next) => {
    if (scopes.some(s => req.caller.scopes.includes(s))) {
      next();
    } else {
      res.status(403).json({
        error: `Requires scope: ${scopes.join(" or ")}. You have: ${req.caller.scopes.join(", ")}`,
      });
    }
  };
}

module.exports = { authMiddleware, requireScope };
```

### 11.4 Go Integration

```go
// tenant_server/auth/middleware.go
package auth

import (
    "context"
    "fmt"
    "net/http"
    "os"
    "strings"

    "github.com/MicahParks/keyfunc/v3"
    "github.com/golang-jwt/jwt/v5"
)

type Caller struct {
    Subject     string   `json:"sub"`
    SubjectType string   `json:"sub_type"`
    Scopes      []string `json:"scopes"`
    ClientID    string   `json:"client_id"`
    ActingAgent string   `json:"acting_agent"`
    IsDelegated bool     `json:"is_delegated"`
}

type contextKey string
const CallerKey contextKey = "caller"

var (
    jwks       *keyfunc.Keyfunc
    resourceID = os.Getenv("RESOURCE_ID")
)

func InitJWKS(jwksURL string) error {
    var err error
    jwks, err = keyfunc.NewDefault([]string{jwksURL})
    return err
}

func AuthMiddleware(next http.Handler) http.Handler {
    return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        if r.URL.Path == "/health" {
            next.ServeHTTP(w, r)
            return
        }

        header := r.Header.Get("Authorization")
        if !strings.HasPrefix(header, "Bearer ") {
            http.Error(w, `{"error":"Missing Authorization header"}`, 401)
            return
        }

        tokenStr := strings.TrimPrefix(header, "Bearer ")
        token, err := jwt.Parse(tokenStr, jwks.Keyfunc,
            jwt.WithAudience(resourceID),
            jwt.WithValidMethods([]string{"RS256"}),
        )
        if err != nil || !token.Valid {
            http.Error(w, `{"error":"Invalid token"}`, 401)
            return
        }

        claims := token.Claims.(jwt.MapClaims)
        caller := Caller{
            Subject:     claimStr(claims, "sub"),
            SubjectType: claimStr(claims, "sub_type"),
            Scopes:      strings.Split(claimStr(claims, "scope"), " "),
            ClientID:    claimStr(claims, "client_id"),
        }
        if act, ok := claims["act"].(map[string]interface{}); ok {
            caller.ActingAgent = act["sub"].(string)
            caller.IsDelegated = true
        }

        ctx := context.WithValue(r.Context(), CallerKey, &caller)
        next.ServeHTTP(w, r.WithContext(ctx))
    })
}

func GetCaller(r *http.Request) *Caller {
    return r.Context().Value(CallerKey).(*Caller)
}

func RequireScope(scopes ...string) func(http.Handler) http.Handler {
    return func(next http.Handler) http.Handler {
        return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
            caller := GetCaller(r)
            for _, required := range scopes {
                for _, has := range caller.Scopes {
                    if required == has {
                        next.ServeHTTP(w, r)
                        return
                    }
                }
            }
            http.Error(w, fmt.Sprintf(`{"error":"Requires scope: %s"}`, strings.Join(scopes, " or ")), 403)
        })
    }
}

func claimStr(c jwt.MapClaims, key string) string {
    v, _ := c[key].(string)
    return v
}
```

### 11.5 Integration Checklist Per Tenant Server

**One-time setup (ThunderID side):**

- [ ] Register resource server: `POST /resource-servers` with identifier and scopes
- [ ] Create roles with appropriate scope assignments
- [ ] Assign users to tenant OU with roles
- [ ] Create agents (if needed) with appropriate scopes
- [ ] Save agent client secrets securely

**Code changes (tenant server side):**

- [ ] Add env vars: `THUNDERID_URL`, `RESOURCE_ID`, `JWKS_URL`
- [ ] Add auth file: `auth.py` / `auth.js` / `auth.go` (~80-120 lines)
- [ ] Add JWKS dependency: `PyJWKClient` (Python), `jwks-rsa` (Node), `keyfunc` (Go)
- [ ] Wire auth middleware into app startup
- [ ] Add `@require_scope(...)` to protected endpoints
- [ ] Add `/health` to the public (skip-auth) path list
- [ ] Handle `sub_type` to distinguish human vs agent callers (if needed)
- [ ] Handle `act` claim for delegated agent calls (if needed)
- [ ] Remove any existing auth code

**Testing:**

- [ ] Request without JWT → `401`
- [ ] Request with valid JWT but wrong audience → `401`
- [ ] Request with valid JWT, correct audience, missing scope → `403`
- [ ] Request with valid JWT, correct audience, correct scope → `200`
- [ ] Request with expired JWT → `401`
- [ ] Autonomous agent token → works with correct scopes
- [ ] Delegated agent token → `act` claim accessible in handler
- [ ] JWKS cache works (kill ThunderID, verify cached keys still work)

---

## 12. REST API Reference

ThunderID provides a comprehensive REST API. Key endpoints used by this system:

### OAuth2 / OIDC Endpoints

| Method | Path | Description |
| --- | --- | --- |
| `GET` | `/.well-known/openid-configuration` | OIDC discovery document |
| `GET` | `/.well-known/oauth-authorization-server` | OAuth2 authorization server metadata |
| `GET` | `/oauth2/jwks` | JWKS (public keys for JWT verification) |
| `GET` | `/oauth2/authorize` | OAuth2 authorize (human login + consent) |
| `POST` | `/oauth2/token` | Token issuance (all grant types) |
| `POST` | `/oauth2/introspect` | Token introspection |
| `POST` | `/oauth2/revoke` | Token revocation |
| `GET` | `/oauth2/userinfo` | OIDC UserInfo |

### Agent Management

| Method | Path | Description |
| --- | --- | --- |
| `GET` | `/agents` | List agents |
| `POST` | `/agents` | Create agent (returns client_secret once) |
| `GET` | `/agents/{id}` | Get agent details |
| `PUT` | `/agents/{id}` | Update agent |
| `DELETE` | `/agents/{id}` | Delete agent |

### Organization Units (Tenants)

| Method | Path | Description |
| --- | --- | --- |
| `GET` | `/organization-units` | List OUs |
| `POST` | `/organization-units` | Create OU |
| `GET` | `/organization-units/{id}` | Get OU details |
| `PUT` | `/organization-units/{id}` | Update OU |
| `DELETE` | `/organization-units/{id}` | Delete OU |

### Users & Roles

| Method | Path | Description |
| --- | --- | --- |
| `GET` | `/users` | List users |
| `GET` | `/users/{id}` | Get user details |
| `GET` | `/roles` | List roles |
| `POST` | `/roles` | Create role |
| `GET` | `/groups` | List groups |
| `POST` | `/groups` | Create group |

### Resource Servers

| Method | Path | Description |
| --- | --- | --- |
| `GET` | `/resource-servers` | List resource servers |
| `POST` | `/resource-servers` | Create resource server with scopes |
| `GET` | `/resource-servers/{id}` | Get resource server details |
| `PUT` | `/resource-servers/{id}` | Update resource server |

### Authentication Flows

| Method | Path | Description |
| --- | --- | --- |
| `POST` | `/flow/execute` | Execute authentication flow step |

### Health

| Method | Path | Description |
| --- | --- | --- |
| `GET` | `/health` | Health check |

---

## 13. Configuration Reference

### Environment Variables (`.env`)

```bash
# ThunderID admin credentials (auto-generated by setup if left blank)
ADMIN_USERNAME=admin
ADMIN_PASSWORD=

# ThunderID public URL (used in tokens, redirects)
THUNDERID_PUBLIC_URL=https://localhost:8090

# Direct Auth Secret (generated by setup, stored in config/secrets/direct_auth_secret)
# Set this for bootstrap scripts:
# DIRECT_AUTH_SECRET=<from setup output or: docker compose exec thunderid cat config/secrets/direct_auth_secret>
```

### Docker Compose Service Summary

| Service | Image | Ports | Exposed Externally | Depends On |
| --- | --- | --- | --- | --- |
| `mailslurper` | `oryd/mailslurper:latest-smtps` | `4436:4436` (web UI), `1025:1025` (SMTP) | Dev only | — |
| `thunderid-setup` | `ghcr.io/thunder-id/thunderid:latest` | None | No | — |
| `thunderid` | `ghcr.io/thunder-id/thunderid:latest` | `8090:8090` | Yes (via reverse proxy in prod) | thunderid-setup |

### ThunderID Data Storage

| Data | Location (in container) | Storage | Volume |
| --- | --- | --- | --- |
| Config database | `/opt/thunderid/database/configdb.db` | SQLite | `thunderid-db` |
| Entity database | `/opt/thunderid/database/entitydb.db` | SQLite | `thunderid-db` |
| Runtime transient DB | `/opt/thunderid/database/runtime_transient.db` | SQLite | `thunderid-db` |
| Runtime persistent DB | `/opt/thunderid/database/runtime_persistent.db` | SQLite | `thunderid-db` |
| TLS certificates | `/opt/thunderid/config/certs/` | Files | `thunderid-certs` |
| JWT signing keys | `/opt/thunderid/config/certs/signing.*` | Files | `thunderid-certs` |
| Direct Auth Secret | `/opt/thunderid/config/secrets/direct_auth_secret` | File | `thunderid-secrets` |

### Bootstrap Script Environment Variables

```bash
# Required for bootstrap/bootstrap.py and bootstrap/seed_users.py
THUNDERID_URL=https://localhost:8090
DIRECT_AUTH_SECRET=<from setup output>
```

### Tenant Server Environment Variables

```bash
# Required for every tenant server
THUNDERID_URL=https://identity.internal:8090
RESOURCE_ID=https://monitoring-api.internal
JWKS_URL=https://identity.internal:8090/oauth2/jwks

# For autonomous agents (stored as secrets)
AGENT_CLIENT_ID=<from bootstrap>
AGENT_CLIENT_SECRET=<from bootstrap, shown once>
```

---

## 14. Logging & Audit Trail

### 14.1 What Gets Logged

| Event Category | Events | Source |
| --- | --- | --- |
| Authentication | Login success/failure, registration, OTP sent/verified, session created/destroyed | ThunderID |
| Token lifecycle | Token issued (access + refresh), token refreshed, token revoked, token introspected | ThunderID |
| Agent activity | Agent created, agent secret regenerated, agent deleted, agent token issued | ThunderID |
| Authorization | Scope check passed/failed, audience mismatch, expired token rejected | Tenant servers |
| Admin actions | Tenant created, role created, user assigned to tenant, resource server registered | ThunderID / bootstrap scripts |

### 14.2 Log Format

All logs use structured JSON for machine parsing. Fields:

```json
{
  "timestamp": "2025-01-15T10:30:00.000Z",
  "level": "info",
  "event": "token_issued",
  "service": "thunderid",
  "subject": "user-uuid-or-agent-uuid",
  "subject_type": "user",
  "client_id": "monitoring-app",
  "grant_type": "authorization_code",
  "resource": "https://monitoring-api.internal",
  "scopes": ["alerts:read", "alerts:write"],
  "ip": "10.0.1.50",
  "request_id": "req-uuid"
}
```

### 14.3 Dev vs Production Logging

| Setting | Dev | Production |
| --- | --- | --- |
| Output | Console (stdout) | Structured JSON → log aggregator |
| Level | `debug` | `info` |
| Retention | None (ephemeral) | 90 days minimum |
| Aggregator | None | ELK, Loki, CloudWatch, or Datadog |
| Alerting | None | Alert on: auth failures > threshold, agent creation, admin actions |

### 14.4 Tenant Server Logging

Tenant servers should log authorization decisions:

```python
import logging
import json

logger = logging.getLogger("auth")

def log_auth_decision(request, caller, endpoint, decision, reason=""):
    logger.info(json.dumps({
        "event": "auth_decision",
        "endpoint": endpoint,
        "method": request.method,
        "subject": caller.subject,
        "subject_type": caller.subject_type,
        "scopes": caller.scopes,
        "acting_agent": caller.acting_agent,
        "decision": decision,  # "allowed" or "denied"
        "reason": reason,
        "ip": request.client.host,
    }))
```

---

## 15. Backup & Restore

### 15.1 What to Back Up

All ThunderID state lives in three Docker volumes (`thunderid-db`, `thunderid-certs`, `thunderid-secrets`):

| Data | Path in Container | Contents |
| --- | --- | --- |
| SQLite databases (4) | `/opt/thunderid/database/*.db` | Identities, agents, OAuth clients, sessions, roles, OUs |
| TLS certificates | `/opt/thunderid/config/certs/` | Server cert, JWT signing keys (RSA + ECDSA), crypto key |
| Direct Auth Secret | `/opt/thunderid/config/secrets/` | Secret for Direct API access |
| Bootstrap configuration | `bootstrap/config/*.yaml` (host) | Tenant, role, agent definitions (in git) |
| Environment variables | `.env` (host) | Admin credentials (in secure vault) |

### 15.2 Backup Script (`scripts/backup-db.sh`)

Since ThunderID uses SQLite, backup is a file copy. SQLite's WAL mode is safe for hot backup using `.backup` command.

```bash
#!/bin/bash
set -e

BACKUP_DIR="${BACKUP_DIR:-./backups}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_FILE="$BACKUP_DIR/thunderid_${TIMESTAMP}.tar.gz"

mkdir -p "$BACKUP_DIR"

echo "Backing up ThunderID data..."

# Create a temp directory for consistent snapshot
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

# Copy SQLite databases using sqlite3 .backup for consistency
for db in configdb entitydb runtime_transient runtime_persistent; do
  docker compose exec -T thunderid sqlite3 \
    "database/${db}.db" ".backup '/tmp/${db}.db'" 2>/dev/null
  docker compose cp "thunderid:/tmp/${db}.db" "$TMPDIR/${db}.db"
done

# Copy certs and secrets
docker compose cp "thunderid:/opt/thunderid/config/certs" "$TMPDIR/certs"
docker compose cp "thunderid:/opt/thunderid/config/secrets" "$TMPDIR/secrets"

# Create tarball
tar -czf "$BACKUP_FILE" -C "$TMPDIR" .

echo "Backup created: $BACKUP_FILE ($(du -h "$BACKUP_FILE" | cut -f1))"

# Keep only last 30 backups
ls -t "$BACKUP_DIR"/thunderid_*.tar.gz 2>/dev/null | tail -n +31 | xargs -r rm
echo "Old backups cleaned (keeping last 30)"
```

### 15.3 Restore Script (`scripts/restore-db.sh`)

```bash
#!/bin/bash
set -e

if [ -z "$1" ]; then
  echo "Usage: $0 <backup_file.tar.gz>"
  echo "Available backups:"
  ls -lh backups/thunderid_*.tar.gz 2>/dev/null || echo "  No backups found"
  exit 1
fi

BACKUP_FILE="$1"

echo "WARNING: This will overwrite all ThunderID data."
read -p "Continue? [y/N] " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
  echo "Aborted."
  exit 1
fi

echo "Stopping ThunderID..."
docker compose stop thunderid

# Extract backup
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT
tar -xzf "$BACKUP_FILE" -C "$TMPDIR"

# Restore databases
for db in configdb entitydb runtime_transient runtime_persistent; do
  if [ -f "$TMPDIR/${db}.db" ]; then
    docker compose cp "$TMPDIR/${db}.db" "thunderid:/opt/thunderid/database/${db}.db"
  fi
done

# Restore certs and secrets
if [ -d "$TMPDIR/certs" ]; then
  docker compose cp "$TMPDIR/certs/." "thunderid:/opt/thunderid/config/certs/"
fi
if [ -d "$TMPDIR/secrets" ]; then
  docker compose cp "$TMPDIR/secrets/." "thunderid:/opt/thunderid/config/secrets/"
fi

echo "Starting ThunderID..."
docker compose start thunderid

echo "Restore complete. Verify via: curl -k https://localhost:8090/health"
```

### 15.4 Automated Daily Backup (cron)

```bash
# Add to crontab: crontab -e
# Daily at 2 AM
0 2 * * * cd /home/ichoi2/work/kratos && bash scripts/backup-db.sh >> /var/log/thunderid-backup.log 2>&1
```

### 15.5 Disaster Recovery Checklist

1. Restore from latest backup: `bash scripts/restore-db.sh backups/thunderid_YYYYMMDD.tar.gz`
2. If volume is lost entirely: re-run `docker compose up thunderid-setup` to regenerate keys — but **all existing tokens become invalid** and users/agents must re-authenticate
3. Verify health: `curl -k https://localhost:8090/health`
4. Verify JWKS: `curl -k https://localhost:8090/oauth2/jwks`
5. Run smoke tests: `bash scripts/test-phase1.sh`

---

## 16. Security, Resilience & Failure Modes

### 16.1 Security Architecture

#### Network Segmentation

```text
┌─────────────────────────────────────────────────────────────────┐
│                     EXTERNAL NETWORK                             │
└──────────────┬──────────────────────────────────────────────────┘
               │ HTTPS only (TLS terminated at reverse proxy)
┌──────────────▼──────────────────────────────────────────────────┐
│                 DMZ / REVERSE PROXY (Nginx / Traefik)            │
│  • TLS termination  • Rate limiting  • Security headers          │
└──────────────┬──────────────────────────────────────────────────┘
               │ :8090 (ThunderID)
┌──────────────▼──────────────────────────────────────────────────┐
│                 INTERNAL NETWORK (Docker)                         │
│                                                                  │
│  ┌──────────────────┐  ┌──────────────┐                         │
│  │    ThunderID      │  │ Tenant A-N   │                         │
│  │    :8090         │  │  :9000-9015  │                         │
│  │  (SQLite inside) │  └──────────────┘                         │
│  └──────────────────┘                                            │
└─────────────────────────────────────────────────────────────────┘
```

**Rules:**

- ThunderID — behind reverse proxy in production. TLS termination at proxy. SQLite databases are embedded (no network-accessible DB port).
- Tenant servers — also behind reverse proxy. Validate JWTs offline.
- Docker volumes (`thunderid-db`, `thunderid-certs`, `thunderid-secrets`) — contain all persistent state. Must be backed up.

#### Token Security

| Concern | Implementation |
| --- | --- |
| Token format | Standard OAuth2 JWT (`at+jwt`), signed by ThunderID |
| Signing | RS256 (asymmetric). Keys generated by ThunderID setup, stored in Docker volume. |
| Verification | JWKS endpoint. Tenant servers cache keys. |
| Token lifetime | Configurable per resource server. Default 1 hour. |
| Refresh tokens | OAuth2 refresh tokens, server-side, revocable. |
| Token scope | Always scoped to one resource server (audience). |
| Token ID (`jti`) | Every JWT gets a unique `jti` for audit and revocation. |
| Key rotation | ThunderID manages key rotation. JWKS endpoint always has current keys. |
| Agent vs user | `sub_type` claim distinguishes identity types. `act` claim tracks delegation. |

#### Agent Security

| Concern | Implementation |
| --- | --- |
| Agent credentials | OAuth2 `client_id` + `client_secret` (ThunderID-managed) |
| Credential rotation | Regenerate secret via ThunderID API/console. Old secret immediately invalid. |
| Scope enforcement | Agent token scopes are intersection of: requested scopes, granted scopes (via roles), resource server scopes |
| Downscoping | Token exchange enforces strict downscoping — worker agents never gain more than the subject had |
| Audit trail | Every agent token has `sub=agent-id`, `sub_type=agent`. Delegation chains recorded in nested `act` claims. |
| Owner accountability | Every agent has a human `owner` field |
| Agent revocation | Delete agent or regenerate secret → all future tokens denied |

#### CORS Configuration

Cross-Origin Resource Sharing must be configured for browser-based clients that call tenant APIs or ThunderID directly.

**ThunderID CORS (`deployment.yaml`):**

```yaml
server:
  cors:
    allowed_origins:
      - "https://localhost:3000"       # Dev frontend
      # Add production frontend origins here
    allowed_methods:
      - "GET"
      - "POST"
      - "OPTIONS"
    allowed_headers:
      - "Authorization"
      - "Content-Type"
    exposed_headers:
      - "X-Request-Id"
    allow_credentials: true
    max_age: 3600
```

**Tenant server CORS (per-server):**

Each tenant server must configure CORS independently. Example for FastAPI:

```python
from fastapi.middleware.cors import CORSMiddleware

app.add_middleware(
    CORSMiddleware,
    allow_origins=os.getenv("CORS_ORIGINS", "https://localhost:3000").split(","),
    allow_credentials=True,
    allow_methods=["GET", "POST", "PUT", "DELETE", "OPTIONS"],
    allow_headers=["Authorization", "Content-Type"],
)
```

| Environment | `allowed_origins` |
| --- | --- |
| Dev | `https://localhost:3000`, `https://localhost:*` |
| Production | Explicit allowlist of frontend domains only |

### 16.2 SPOF Analysis

| Component | SPOF Risk | Mitigation |
| --- | --- | --- |
| **ThunderID + SQLite** | If ThunderID goes down, no new logins or tokens. SQLite data is on disk in the Docker volume. | Docker restart policy (`unless-stopped`), health checks, daily backups. No separate DB to manage. |
| **Docker volume** | If volume is lost, all identity data is gone | Daily backups via `scripts/backup-db.sh`. Volume snapshots for certs/keys. |
| **JWT Verification** | If ThunderID is down, can existing tokens still be validated? | **YES** — JWKS is cached by tenant servers. Existing tokens work until they expire. |
| **MailSlurper** | If email is down, no OTP codes | Replace with reliable SMTP in production (SES, SendGrid). |

**Key resilience feature: JWKS-based offline verification.** Even if ThunderID is completely down, all tenant servers continue working with cached JWKS keys for the lifetime of existing tokens (default 1 hour). Only new logins fail.

### 16.3 Failure Scenarios

| Scenario | Impact | Recovery |
| --- | --- | --- |
| **ThunderID crashes** | No new logins/tokens. All tenant servers continue with cached JWKS. | Docker auto-restarts. SQLite WAL recovery is automatic. Recovery: < 10s. |
| **Docker volume lost** | All identity data gone. Existing JWTs still work until they expire. | Restore from backup: `bash scripts/restore-db.sh`. If no backup, re-run setup (regenerates keys, all tokens invalidated). |
| **Agent secret compromised** | Attacker can get tokens for that one agent's scopes | Regenerate secret via API. Delete agent if needed. Blast radius: one agent's scopes on one resource. |
| **JWT signing key compromised** | Attacker can forge tokens | Rotate keys in ThunderID. All existing tokens invalidated. Users/agents must re-authenticate. |
| **Full identity service outage** | No new logins. Tenant servers work until JWTs expire. | Restart Docker Compose. Full recovery < 1 min. |
| **SQLite corruption** | ThunderID fails to start or returns errors | Restore from backup. SQLite WAL mode reduces corruption risk. |

### 16.4 ThunderID Maturity Risk

ThunderID is young (~15 months, 565 stars, Apache 2.0). Mitigations:

- **Fallback plan:** The previous Kratos architecture is preserved in `master-plan-kratos-v1.md`. If ThunderID doesn't work out, we can fall back.
- **Standard protocols:** ThunderID uses standard OAuth 2.1 / OIDC. Tenant server integration code (JWKS verification) works with any OIDC provider — switching later only requires changing the JWKS URL.
- **Data portability:** User identities and configurations can be exported from ThunderID's SQLite databases.
- **Pin version:** Never use `latest` in production. Pin to a tested release tag (currently v1.0.1).

### 16.5 Dev vs Production Security Matrix

| Setting | Dev | Production |
| --- | --- | --- |
| TLS | Self-signed (ThunderID setup generates) | Real certs via reverse proxy |
| Database | Embedded SQLite (Docker volume) | Embedded SQLite (backed up daily) or PostgreSQL |
| Email provider | MailSlurper | Production SMTP (SES, etc.) |
| Token lifetime | 1 hour | 1 hour (configurable) |
| Rate limiting | None | Nginx rate limiting |
| Audit logging | Console | Structured JSON → log aggregator |
| DB backup | None | Daily automated backup (`scripts/backup-db.sh`) |
| Secrets | `.env` file | Docker secrets / vault |
| CORS | `localhost:*` | Explicit allowlist |
| Image tag | `latest` | Pinned release tag (v1.0.1) |
| Direct Auth Secret | In setup output / file | Stored in vault, not in `.env` |
| `.env` in git | Allowed (dev values) | **Never. `.gitignore` enforced.** |

### 16.6 Security Checklist

- [ ] `.env` added to `.gitignore`
- [ ] `.env.example` with placeholder values
- [ ] `setup-output.txt` added to `.gitignore`
- [ ] ThunderID behind reverse proxy in production
- [ ] TLS certificates properly configured
- [ ] SMTP provider configured (not MailSlurper) in production
- [ ] Agent client secrets stored securely (not in code or git)
- [ ] Direct Auth Secret stored securely (not in code or git)
- [ ] ThunderID image pinned to specific version (v1.0.1)
- [ ] JWKS cache configured with reasonable TTL in tenant servers
- [ ] Rate limiting configured at reverse proxy
- [ ] Backup strategy documented and tested (`scripts/backup-db.sh`)
- [ ] Docker volume backed up regularly
- [ ] Admin console access restricted to authorized users
- [ ] CORS origins explicitly configured (not wildcard) in production
- [ ] CORS configured on all tenant servers

---

## 17. Makefile & Scripts

### 17.1 Makefile

A single entry point for all common operations:

```makefile
.PHONY: setup bootstrap seed test clean backup restore logs

# ──────────────────────────────────────────────
# Phase 1: Start services
# ──────────────────────────────────────────────
setup:
	docker compose up thunderid-setup 2>&1 | tee setup-output.txt
	docker compose up -d thunderid mailslurper
	@echo "Waiting for ThunderID to be healthy..."
	@until curl -sf --insecure https://localhost:8090/health > /dev/null 2>&1; do \
		sleep 2; echo "  waiting..."; \
	done
	@echo ""
	@echo "ThunderID is ready!"
	@echo "  Console: https://localhost:8090/console"
	@echo "  Gate:    https://localhost:8090/gate"
	@echo "  Mail:    http://localhost:4436"
	@echo ""
	@echo "IMPORTANT: Check setup-output.txt for admin password and Direct Auth Secret"

# ──────────────────────────────────────────────
# Retrieve Direct Auth Secret (needed for bootstrap)
# ──────────────────────────────────────────────
get-secret:
	@docker compose exec thunderid cat config/secrets/direct_auth_secret

# ──────────────────────────────────────────────
# Phase 2: Bootstrap tenants, resource servers, roles
# ──────────────────────────────────────────────
bootstrap:
	$(eval DIRECT_AUTH_SECRET ?= $(shell docker compose exec thunderid cat config/secrets/direct_auth_secret 2>/dev/null))
	cd bootstrap && pip install -r requirements.txt -q && \
		DIRECT_AUTH_SECRET="$(DIRECT_AUTH_SECRET)" python bootstrap.py

# ──────────────────────────────────────────────
# Phase 2b: Seed users into tenants
# ──────────────────────────────────────────────
seed:
	$(eval DIRECT_AUTH_SECRET ?= $(shell docker compose exec thunderid cat config/secrets/direct_auth_secret 2>/dev/null))
	cd bootstrap && \
		DIRECT_AUTH_SECRET="$(DIRECT_AUTH_SECRET)" python seed_users.py

# ──────────────────────────────────────────────
# Phase 4: Run all tests
# ──────────────────────────────────────────────
test:
	bash scripts/test-all.sh

test-phase1:
	bash scripts/test-phase1.sh

test-phase2:
	bash scripts/test-phase2.sh

test-phase3:
	bash scripts/test-phase3.sh

test-phase4:
	bash scripts/test-phase4.sh

# ──────────────────────────────────────────────
# Operations
# ──────────────────────────────────────────────
backup:
	bash scripts/backup-db.sh

restore:
	@echo "Usage: make restore FILE=backups/thunderid_YYYYMMDD.tar.gz"
	bash scripts/restore-db.sh $(FILE)

logs:
	docker compose logs -f thunderid

logs-all:
	docker compose logs -f

status:
	docker compose ps
	@echo ""
	@curl -sf --insecure https://localhost:8090/health | python3 -m json.tool 2>/dev/null \
		|| echo "ThunderID is not responding"

# ──────────────────────────────────────────────
# Lifecycle
# ──────────────────────────────────────────────
stop:
	docker compose stop

down:
	docker compose down

clean:
	docker compose down -v
	rm -f setup-output.txt
	@echo "All volumes removed. Run 'make setup' to start fresh."

# ──────────────────────────────────────────────
# Full setup (all phases)
# ──────────────────────────────────────────────
all: setup bootstrap
	@echo ""
	@echo "Identity service is ready!"
	@echo "Next steps:"
	@echo "  1. Register users via Gate: https://localhost:8090/gate"
	@echo "  2. Seed users: make seed"
	@echo "  3. Run tests: make test"
```

### 17.2 Project Structure Update

Add these files to the project structure (Section 5):

```text
├── Makefile                                # Single entry point for all operations
├── scripts/
│   ├── test-api.sh                         # API smoke tests (legacy)
│   ├── test-phase1.sh                      # Phase 1 verification tests
│   ├── test-phase2.sh                      # Phase 2 bootstrap tests
│   ├── test-phase3.sh                      # Phase 3 agent tests
│   ├── test-phase4.sh                      # Phase 4 end-to-end tests
│   ├── test-all.sh                         # Full test suite runner
│   ├── test-agent-flows.sh                 # Agent auth flow tests
│   ├── backup-db.sh                        # SQLite database backup
│   └── restore-db.sh                       # SQLite database restore
```

---

## 18. Scope & Future Enhancements

### 18.1 In-Scope (This Plan)

Everything in Phases 1-4 plus integration guides:

| Area | Details |
| --- | --- |
| **Infrastructure** | Docker Compose deployment (ThunderID with embedded SQLite, MailSlurper), `.env` management, TLS (self-signed for dev) |
| **Human authentication** | Registration, login (email OTP), session management via ThunderID Gate |
| **AI agent identity** | Autonomous agents (`client_credentials`), delegated agents (`authorization_code` + PKCE) |
| **Multi-tenancy** | Tenants as ThunderID Organization Units, per-tenant roles and scopes |
| **OAuth2/OIDC** | Token issuance (access + refresh), JWKS endpoint, OIDC discovery |
| **Token lifecycle** | Token refresh (rotation), token revocation, offline verification via JWKS |
| **Agent delegation** | Agent acting on behalf of user (`act` claim), agent-to-agent token exchange |
| **RBAC** | Roles with scope assignments, per-tenant membership, scope enforcement at tenant servers |
| **Bootstrap automation** | Python scripts to register tenants, resource servers, roles, agents, and seed users |
| **Integration SDKs** | JWT verification middleware for Python/FastAPI, Node.js/Express, Go |
| **Testing** | Structured test plan per phase, smoke tests, negative tests, resilience tests |
| **Operations** | Makefile entry points, backup/restore scripts, logging strategy |
| **Security** | Network segmentation, token security, agent credential management, CORS, SPOF analysis |
| **UI** | ThunderID built-in Gate (login) + Console (admin) — no custom UI |

### 18.2 Out of Scope (Explicit Exclusions)

These items are intentionally not addressed in this plan:

| Item | Reason |
| --- | --- |
| **Custom login UI** | ThunderID Gate is sufficient; custom branding can be added later |
| **Custom admin dashboard** | ThunderID Console covers all admin operations |
| **Kubernetes deployment** | Docker Compose is sufficient for the current scale (5-15 servers) |
| **Horizontal scaling** | Single ThunderID instance handles the expected load |
| **Monitoring / alerting (Prometheus, Grafana)** | Deferred to production hardening phase |
| **Log aggregation (ELK, Loki)** | Strategy defined, but aggregator deployment is out of scope |
| **Social login / SSO (Google, GitHub, SAML)** | ThunderID supports it, but email OTP is sufficient for now |
| **Passkey / WebAuthn** | ThunderID supports it, can be enabled when needed |
| **MFA step-up** | Not required for current internal services |
| **MCP authorization** | ThunderID supports it, deferred until MCP integration is needed |
| **Agent budget / rate limiting policies** | No current requirement for per-agent rate limiting |
| **Verifiable Credentials (OpenID4VCI)** | Advanced identity feature, not needed now |
| **CI/CD pipeline integration** | Test scripts exist but CI/CD pipeline definition is out of scope |
| **Multi-region deployment** | Single-region Docker Compose deployment only |
| **User self-service (profile management)** | Users managed by admins via Console for now |

### 18.3 Future Work

#### Phase 5: Advanced Agent Patterns

- Agent-to-agent delegation chains for complex multi-agent workflows
- CIBA (Client Initiated Backchannel Authentication) for agent approval flows
- Agent budget policies (max tokens per time window)
- Agent anomaly detection (unusual scope requests, unusual hours)

#### Phase 6: MCP Authorization

- ThunderID's built-in MCP authorization server for securing Model Context Protocol interactions
- Agents as MCP clients with proper OAuth2 authorization

#### Phase 7: Production Hardening

- Kubernetes deployment (ThunderID + external PostgreSQL)
- Horizontal scaling (multiple ThunderID replicas, shared PostgreSQL for state)
- Monitoring and alerting (Prometheus + Grafana)
- Log aggregation (structured audit logs → ELK/Loki)
- Database connection pooling (PgBouncer)

#### Phase 8: Advanced Identity

- Verifiable Credentials issuance (ThunderID supports OpenID4VCI)
- Social login / enterprise SSO (Google, GitHub, SAML — ThunderID supports these)
- Passkey / WebAuthn authentication
- Multi-factor authentication step-up for sensitive operations

#### Phase 9: Developer Experience

- CLI tool for managing tenants, agents, and roles
- Auto-generated SDK clients
- OpenAPI spec from ThunderID
- Integration test harness for tenant servers

---

## 19. Implementation Order Summary

```text
Phase 1 (Core):         docker-compose.yml + deployment.yaml + .env
                         ↓ make setup
Phase 2 (Bootstrap):     Register tenants, resource servers, roles, seed users
                         ↓ make bootstrap && make seed
Phase 3 (Agents):        Register AI agents (autonomous + delegated)
                         ↓ (included in make bootstrap)
Phase 4 (Test):          Smoke tests, E2E flows, negative tests, resilience tests
                         ↓ make test
Integrate:               Add JWKS auth middleware to each tenant server
                         ↓ (per-server, follow Section 11)
Operate:                 Backup, monitor, iterate
                         ↓ make backup, make logs
```

**Estimated files to create:** ~25 files
**Key technologies:** Docker Compose, ThunderID v1.0.1 (Go, embedded SQLite), Python (bootstrap scripts), JWKS/OAuth2 JWT verification SDKs (Python/Node/Go)

### Comparison to Previous Architecture

| Metric | Kratos Plan | ThunderID Plan |
| --- | --- | --- |
| Files to create | ~50 | ~25 |
| Docker containers | 6 | 3 (2 in steady-state) |
| External database | PostgreSQL (separate container) | None (embedded SQLite) |
| Custom middleware code | ~3000 lines (FastAPI) | ~200 lines (bootstrap scripts) |
| Custom UI code | ~2000 lines (Next.js) | 0 (ThunderID has built-in gate + console) |
| Agent identity | Not supported | Native first-class |
| Token standard | Custom RS256 JWT | Standard OAuth2 JWT + JWKS |
| Token verification | Custom public key distribution | Standard JWKS (works with any OIDC provider) |
| Delegation | Not supported | OAuth2 token exchange with nested `act` claims |
| MCP support | Not supported | Built-in MCP authorization server |
| System maturity | Kratos: 7+ years, CNCF | ThunderID: ~15 months, 565 stars, v1.0.1 |
