# Kratos Identity Service - Master Plan

A centralized identity service for internal servers, built with Ory Kratos in Docker. Provides shared user authentication with per-tenant role-based access control (RBAC) and JWT-based service integration for 5-15 existing REST API projects.

---

## Table of Contents

1. [Problem Statement](#1-problem-statement)
2. [Architecture Overview](#2-architecture-overview)
3. [Core Concepts](#3-core-concepts)
4. [Technology Stack](#4-technology-stack)
5. [Project Structure](#5-project-structure)
6. [Phase 1: Core Kratos Setup](#6-phase-1-core-kratos-setup)
7. [Phase 2: Identity Middleware (FastAPI)](#7-phase-2-identity-middleware-fastapi)
8. [Phase 3: Next.js Self-Service UI](#8-phase-3-nextjs-self-service-ui)
9. [Phase 4: Integration & Testing](#9-phase-4-integration--testing)
10. [Integrating Existing Servers](#10-integrating-existing-projects)
11. [REST API Reference](#11-rest-api-reference)
12. [Configuration Reference](#12-configuration-reference)
13. [Security, Resilience & Failure Modes](#13-security-resilience--failure-modes)
14. [Future Enhancements](#14-future-enhancements)

---

## 1. Problem Statement

- You have **5-15 internal REST API servers** with **no authentication or RBAC**
- Each server is a separate **project** (e.g., monitoring-api, data-pipeline, deployment-tool, etc.)
- You need a **single identity service** that all tenants can use
- **Users are shared** across tenants — one person can access multiple tenants
- Each tenant needs its own **roles** (e.g., monitoring-api might have `operator` and `viewer`, while data-pipeline has `engineer` and `readonly`)
- Tenants authenticate against the identity service using **service accounts + JWT**

---

## 2. Architecture Overview

```text
┌──────────────────────────────────────────────────────────────────┐
│                     Internal Network                             │
│                                                                  │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐           │
│  │ Project A    │  │ Project B    │  │ Project C    │  ...       │
│  │ (REST API)   │  │ (REST API)   │  │ (REST API)   │           │
│  │ monitoring   │  │ data-pipeline│  │ deploy-tool  │           │
│  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘           │
│         │                 │                 │                    │
│         │  Validate JWT   │  Validate JWT   │  Validate JWT     │
│         │  (offline)      │  (offline)      │  (offline)        │
│         │                 │                 │                    │
│         └────────────┬────┴────────┬────────┘                    │
│                      │             │                             │
│                      ▼             ▼                             │
│  ┌─────────────────────────────────────────────┐                │
│  │        Identity Middleware (FastAPI)          │                │
│  │              Port 6600                       │                │
│  │                                              │                │
│  │  • User login/registration (proxies Kratos)  │                │
│  │  • JWT issuance (per project)                │                │
│  │  • Tenant management               │                │
│  │  • Per-tenant role assignments (RBAC)       │                │
│  │  • Service account authentication            │                │
│  └──────────────────┬──────────────────────────┘                │
│                      │                                           │
│         ┌────────────┴────────────┐                              │
│         ▼                         ▼                              │
│  ┌─────────────┐          ┌─────────────┐                       │
│  │ Ory Kratos  │          │ PostgreSQL  │                       │
│  │ Public:4433 │          │ Port: 5432  │                       │
│  │ Admin: 4434 │          │             │                       │
│  └─────────────┘          └─────────────┘                       │
│         │                                                        │
│  ┌─────────────┐   ┌──────────────┐                             │
│  │ MailSlurper │   │  Next.js UI  │                             │
│  │ SMTP: 1025  │   │  Port: 3000  │                             │
│  │ Web:  4436  │   │  (Self-svc)  │                             │
│  └─────────────┘   └──────────────┘                             │
└──────────────────────────────────────────────────────────────────┘
```

### Key Flows

#### Flow 1: User Login and JWT Issuance

```text
1. User → UI (or API)       : Enter email
2. UI → Middleware → Kratos  : Create login flow (passwordless code)
3. Kratos → Email            : Send one-time code
4. User → UI → Middleware    : Submit code
5. Kratos → Middleware       : Session created
6. Middleware                : Look up user's tenant memberships & roles
7. Middleware → User         : Return JWT containing {user_id, projects: [{id, roles}]}
```

#### Flow 2: Tenant Server Validates a Request

```text
1. Client → Tenant Server   : API request + Authorization: Bearer <JWT>
2. Tenant Server            : Verify JWT signature (using shared public key)
3. Tenant Server            : Extract tenant roles from JWT claims
4. Tenant Server            : Check role has permission for this endpoint
5. Tenant Server → Client   : Response (200 or 403)
```

#### Flow 3: Service Account Access (Server-to-Server)

```text
1. Tenant Server → Middleware : POST /api/service-auth {api_key, tenant_id}
2. Middleware                  : Validate API key, look up service account
3. Middleware → Tenant Server : Return scoped JWT for service account
```

---

## 3. Core Concepts

### 3.1 Tenant

A **tenant** represents one of your internal servers/services. Each tenant:

- Has a unique `tenant_id` (e.g., `monitoring-api`, `data-pipeline`)
- Defines its own set of **roles** (e.g., `admin`, `operator`, `viewer`)
- Has one or more **service account API keys** for server-to-server auth
- Is registered in the identity middleware's database

### 3.2 User

A **user** is a person who can access one or more tenants. Users are:

- Stored in **Kratos** (email, name, credentials)
- **Shared across all tenants** — one identity, multiple tenant memberships
- Assigned **roles per project** in the middleware's database

### 3.3 Tenant Membership

A **membership** links a user to a tenant with specific roles:

```json
{
  "user_id": "kratos-identity-uuid",
  "tenant_id": "monitoring-api",
  "roles": ["operator", "viewer"],
  "assigned_at": "2026-08-25T00:00:00Z",
  "assigned_by": "admin-user-uuid"
}
```

A user can have memberships in multiple tenants with different roles in each.

### 3.4 JWT Token

After login, the middleware issues a **tenant-scoped JWT** that contains:

```json
{
  "sub": "kratos-identity-uuid",
  "email": "user@example.com",
  "jti": "unique-token-id",
  "iat": 1724544000,
  "exp": 1724547600,
  "iss": "identity-service",
  "tenant_id": "monitoring-api",
  "roles": ["operator", "viewer"],
  "sa": false
}
```

**Design decisions:**

- **Scoped to one tenant** — if a token leaks, the attacker only has access to one tenant, not all of them. Clients request a separate JWT per project they need to access.
- **Short-lived (1 hour)** — limits the damage window. Paired with a refresh token (7-day, server-side, revocable) to avoid frequent re-logins.
- **`jti` (token ID)** — enables audit logging and optional token revocation via a denylist.
- **Offline verification** — tenant servers verify JWTs using a cached RS256 public key. No callback to the identity service is needed. This means tenant servers continue working even if the identity service goes down.

### 3.5 Service Account

A **service account** allows tenant servers to make authenticated server-to-server calls:

- Each tenant can have multiple API keys
- API keys are stored hashed in the middleware database
- Service accounts get scoped JWTs with a `service_account: true` claim
- Used for background jobs, cron tasks, inter-service calls

### 3.6 Role Definitions

Each tenant defines its own roles. The middleware stores role definitions per project:

```json
{
  "tenant_id": "monitoring-api",
  "roles": {
    "admin": {
      "description": "Full access to monitoring API",
      "permissions": ["*"]
    },
    "operator": {
      "description": "Can view and manage alerts",
      "permissions": ["alerts:read", "alerts:write", "dashboards:read"]
    },
    "viewer": {
      "description": "Read-only access",
      "permissions": ["alerts:read", "dashboards:read"]
    }
  }
}
```

Permission enforcement happens **in each tenant server**, not in the middleware. The middleware only stores role assignments. This keeps the identity service simple and lets each tenant defines its own permission semantics.

---

## 4. Technology Stack

| Component | Technology | Version | Purpose |
| --- | --- | --- | --- |
| Identity Server | Ory Kratos | v1.3.x (latest stable) | User registration, login, sessions, recovery |
| Database | PostgreSQL | 16-alpine | Kratos data + middleware data (projects, memberships, service accounts) |
| Email (dev) | MailSlurper | latest-smtps | Capture verification/recovery emails |
| Identity Middleware | Python FastAPI | 3.12 + FastAPI 0.115 | JWT issuance, tenant management, RBAC, service accounts |
| Self-Service UI | Next.js | 14.x | Login, registration, tenant dashboard, role management |
| JWT Signing | PyJWT + cryptography | — | RS256 key pair for signing/verifying JWTs |
| Containerization | Docker Compose | v5.x | Service orchestration |

---

## 5. Project Structure

```text
/home/ichoi2/work/kratos/
├── master-plan.md
├── docker-compose.yml
├── .env
│
├── kratos/                                 # Kratos configuration
│   ├── kratos.yml
│   └── identity-schemas/
│       └── user.schema.json
│
├── middleware/                             # FastAPI identity middleware
│   ├── Dockerfile
│   ├── requirements.txt
│   ├── keys/                              # JWT signing keys (generated)
│   │   ├── private.pem                    # RS256 private key (sign JWTs)
│   │   └── public.pem                     # RS256 public key (verify JWTs)
│   ├── app/
│   │   ├── __init__.py
│   │   ├── main.py                        # FastAPI app entry point
│   │   ├── config.py                      # Settings & env vars
│   │   ├── database.py                    # SQLAlchemy setup + models
│   │   ├── routers/
│   │   │   ├── __init__.py
│   │   │   ├── auth.py                    # Login/register (proxy to Kratos)
│   │   │   ├── tokens.py                  # JWT issuance + refresh
│   │   │   ├── tenants.py               # Tenant CRUD (admin)
│   │   │   ├── memberships.py            # User-tenant role assignments
│   │   │   ├── service_accounts.py       # Service account + API key mgmt
│   │   │   └── hooks.py                  # Kratos webhook handlers
│   │   ├── services/
│   │   │   ├── __init__.py
│   │   │   ├── kratos_client.py           # Kratos API client (with circuit breaker)
│   │   │   ├── jwt_service.py             # JWT sign/verify logic
│   │   │   ├── refresh_token_service.py   # Refresh token CRUD + rotation
│   │   │   ├── tenant_service.py         # Tenant business logic
│   │   │   ├── membership_service.py      # Membership CRUD
│   │   │   ├── audit_log.py               # Audit event logging
│   │   │   └── rate_limiter.py            # In-memory rate limiter
│   │   ├── models/
│   │   │   ├── __init__.py
│   │   │   ├── tenant.py                 # Tenant SQLAlchemy model
│   │   │   ├── membership.py              # Membership SQLAlchemy model
│   │   │   ├── service_account.py         # ServiceAccount model
│   │   │   ├── refresh_token.py           # RefreshToken model
│   │   │   ├── revoked_token.py           # RevokedToken model
│   │   │   ├── audit_entry.py             # AuditLog model
│   │   │   └── schemas.py                 # Pydantic request/response schemas
│   │   └── middleware/
│   │       ├── __init__.py
│   │       └── auth.py                    # JWT auth + admin role dependency
│   └── tests/
│       ├── __init__.py
│       ├── test_auth.py
│       ├── test_tenants.py
│       ├── test_memberships.py
│       └── conftest.py
│
├── ui/                                     # Next.js self-service UI
│   ├── Dockerfile
│   ├── package.json
│   ├── next.config.js
│   ├── tsconfig.json
│   ├── src/
│   │   ├── app/
│   │   │   ├── layout.tsx
│   │   │   ├── page.tsx                   # Home → tenant list
│   │   │   ├── login/page.tsx             # Login (passwordless code)
│   │   │   ├── register/page.tsx          # Registration
│   │   │   ├── recovery/page.tsx          # Account recovery
│   │   │   ├── settings/page.tsx          # Profile settings
│   │   │   ├── projects/page.tsx          # My tenants list
│   │   │   ├── projects/[id]/page.tsx     # Tenant detail + members
│   │   │   ├── admin/
│   │   │   │   ├── projects/page.tsx      # Admin: manage tenants
│   │   │   │   └── users/page.tsx         # Admin: manage users
│   │   │   └── error/page.tsx
│   │   ├── lib/
│   │   │   ├── api.ts                     # Middleware API client
│   │   │   └── auth.ts                    # JWT + session helpers
│   │   └── components/
│   │       ├── FlowForm.tsx               # Kratos flow renderer
│   │       ├── TenantCard.tsx            # Tenant list item
│   │       └── RoleManager.tsx            # Role assignment UI
│   └── public/
│
├── sdk/                                    # Integration helpers for projects
│   └── python/
│       ├── identity_sdk/
│       │   ├── __init__.py
│       │   ├── jwt_validator.py           # JWT verification helper
│       │   ├── decorators.py              # @require_role("admin") decorator
│       │   └── middleware.py              # FastAPI/Flask middleware
│       ├── setup.py
│       └── README.md
│
└── scripts/
    ├── generate-keys.sh                   # Generate RS256 key pair
    ├── seed-tenants.sh                   # Create initial tenants
    └── test-api.sh                        # API smoke tests
```

---

## 6. Phase 1: Core Kratos Setup

### 6.1 Docker Compose — Kratos + PostgreSQL + MailSlurper

**File: `docker-compose.yml`**

Services to define:

- `postgresd` — PostgreSQL 16 with persistent volume (shared by Kratos + middleware)
- `mailslurper` — Dev email server
- `kratos-migrate` — One-shot migration service
- `kratos` — Main Kratos server

Key configuration decisions:

- Public API on port `4433`, Admin API on port `4434`
- Database: `postgres://kratos:secret@postgresd:5432/kratos?sslmode=disable`
- Middleware gets its own database: `postgres://kratos:secret@postgresd:5432/identity_middleware?sslmode=disable`
- `--dev` flag enabled (dev environment only)
- `--watch-courier` flag to process emails in the same process
- Health checks on `/health/alive` and `/health/ready`

### 6.2 Kratos Configuration (`kratos.yml`)

**Authentication method:** Passwordless code-based only

```yaml
selfservice:
  methods:
    code:
      enabled: true
      passwordless_enabled: true    # Enable passwordless login via code
    password:
      enabled: false
    totp:
      enabled: false
    webauthn:
      enabled: false
    lookup_secret:
      enabled: false
    link:
      enabled: false
```

**Key settings:**

- `selfservice.flows.registration` — Code-based registration, auto-session after registration
- `selfservice.flows.login` — Code-based passwordless login
- `selfservice.flows.recovery` — Code-based account recovery
- `selfservice.flows.verification` — Code-based email verification
- `selfservice.flows.settings` — Profile update flow
- CORS enabled for `http://localhost:3000` (Next.js) and `http://localhost:6600` (FastAPI)

### 6.3 Identity Schema (`user.schema.json`)

Simple user schema — **no tenant/project fields in Kratos**. Tenant membership is handled entirely by the middleware database.

```json
{
  "$id": "https://schemas.example.com/user.schema.json",
  "$schema": "http://json-schema.org/draft-07/schema#",
  "title": "User",
  "type": "object",
  "properties": {
    "traits": {
      "type": "object",
      "properties": {
        "email": {
          "type": "string",
          "format": "email",
          "title": "Email",
          "ory.sh/kratos": {
            "credentials": {
              "code": {
                "identifier": true,
                "via": "email"
              }
            },
            "verification": {
              "via": "email"
            },
            "recovery": {
              "via": "email"
            }
          }
        },
        "name": {
          "type": "object",
          "properties": {
            "first": { "type": "string", "title": "First Name" },
            "last": { "type": "string", "title": "Last Name" }
          }
        }
      },
      "required": ["email"],
      "additionalProperties": false
    }
  }
}
```

### 6.4 Implementation Steps

| # | Task | Files |
| --- | --- | --- |
| 1 | Create `.env` file with secrets, DSN, and config vars | `.env` |
| 2 | Create `docker-compose.yml` with postgresd, mailslurper, kratos-migrate, kratos | `docker-compose.yml` |
| 3 | Create `kratos/kratos.yml` with passwordless code config | `kratos/kratos.yml` |
| 4 | Create `kratos/identity-schemas/user.schema.json` | `kratos/identity-schemas/user.schema.json` |
| 5 | Generate RS256 key pair for JWT signing | `scripts/generate-keys.sh` |
| 6 | Boot and verify: `docker compose up -d`, test health endpoints | — |
| 7 | Test registration flow via curl against Kratos public API | — |

---

## 7. Phase 2: Identity Middleware (FastAPI)

### 7.1 Purpose

The FastAPI middleware is the **central identity API** consumed by all tenants. It:

- **Proxies Kratos** self-service flows (login, register, recovery, etc.)
- **Issues JWTs** containing user identity + per-tenant roles
- **Manages tenants** (tenant CRUD)
- **Manages memberships** (assign users to projects with roles)
- **Manages service accounts** (API keys for server-to-server auth)
- **Stores RBAC data** in its own PostgreSQL database

### 7.2 Database Schema (Middleware's Own DB)

The middleware uses its own PostgreSQL database (`identity_middleware`) with these tables:

```sql
-- Projects (tenants)
CREATE TABLE tenants (
    id VARCHAR(63) PRIMARY KEY,           -- e.g., "monitoring-api"
    name VARCHAR(255) NOT NULL,            -- e.g., "Monitoring API"
    description TEXT,
    roles JSONB NOT NULL DEFAULT '{}',     -- role definitions
    is_active BOOLEAN DEFAULT true,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- User-tenant memberships with roles
CREATE TABLE memberships (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL,                 -- Kratos identity ID
    tenant_id VARCHAR(63) NOT NULL REFERENCES tenants(id),
    roles TEXT[] NOT NULL DEFAULT '{}',    -- e.g., {"admin", "viewer"}
    assigned_by UUID,                      -- who assigned this membership
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(user_id, tenant_id)
);

-- Service accounts for server-to-server auth
CREATE TABLE service_accounts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id VARCHAR(63) NOT NULL REFERENCES tenants(id),
    name VARCHAR(255) NOT NULL,            -- e.g., "cron-worker"
    api_key_hash VARCHAR(255) NOT NULL,    -- bcrypt hash of the API key
    roles TEXT[] NOT NULL DEFAULT '{}',
    is_active BOOLEAN DEFAULT true,
    last_used_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(tenant_id, name)
);

-- Refresh tokens (server-side, revocable)
CREATE TABLE refresh_tokens (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    token_hash VARCHAR(255) NOT NULL UNIQUE,
    user_id UUID NOT NULL,
    tenant_id VARCHAR(63) NOT NULL REFERENCES tenants(id),
    kratos_session_id VARCHAR(255) NOT NULL,
    expires_at TIMESTAMPTZ NOT NULL,
    revoked_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Token denylist (for emergency revocations)
CREATE TABLE revoked_tokens (
    jti UUID PRIMARY KEY,
    revoked_at TIMESTAMPTZ DEFAULT NOW(),
    reason VARCHAR(255),
    expires_at TIMESTAMPTZ NOT NULL
);

-- Audit log
CREATE TABLE audit_log (
    id BIGSERIAL PRIMARY KEY,
    timestamp TIMESTAMPTZ DEFAULT NOW(),
    event VARCHAR(63) NOT NULL,
    actor VARCHAR(255) NOT NULL,
    target VARCHAR(255),
    details JSONB DEFAULT '{}',
    ip_address INET
);

CREATE INDEX idx_memberships_user_id ON memberships(user_id);
CREATE INDEX idx_memberships_tenant_id ON memberships(tenant_id);
CREATE INDEX idx_service_accounts_tenant_id ON service_accounts(tenant_id);
CREATE INDEX idx_refresh_tokens_user ON refresh_tokens(user_id);
CREATE INDEX idx_refresh_tokens_expires ON refresh_tokens(expires_at);
CREATE INDEX idx_revoked_tokens_expires ON revoked_tokens(expires_at);
CREATE INDEX idx_audit_log_timestamp ON audit_log(timestamp);
CREATE INDEX idx_audit_log_actor ON audit_log(actor);
```

### 7.3 JWT Service

**Key pair generation:**

```bash
# scripts/generate-keys.sh
#!/bin/bash
mkdir -p middleware/keys
openssl genrsa -out middleware/keys/private.pem 2048
openssl rsa -in middleware/keys/private.pem -pubout -out middleware/keys/public.pem
echo "Keys generated in middleware/keys/"
echo "Distribute public.pem to all tenant servers for JWT verification."
```

**JWT issuance logic:**

```python
# After Kratos session is validated, build JWT with tenant memberships
def issue_jwt(user_id: str, email: str, name: str) -> str:
    memberships = membership_service.get_user_memberships(user_id)
    tenants_claim = {
        m.tenant_id: {"roles": m.roles}
        for m in memberships
    }
    payload = {
        "sub": user_id,
        "email": email,
        "name": name,
        "tenants": tenants_claim,
        "iat": datetime.utcnow(),
        "exp": datetime.utcnow() + timedelta(hours=24),
        "iss": "identity-service",
    }
    return jwt.encode(payload, private_key, algorithm="RS256")
```

**JWT verification in tenant servers (offline):**

```python
# Each tenant server only needs the public key
def verify_jwt(token: str) -> dict:
    return jwt.decode(
        token,
        public_key,
        algorithms=["RS256"],
        issuer="identity-service",
    )
```

### 7.4 API Design

#### Auth Endpoints (proxied to Kratos)

```text
GET    /api/auth/flows/login              # Init login flow
POST   /api/auth/flows/login              # Submit login flow
GET    /api/auth/flows/registration       # Init registration flow
POST   /api/auth/flows/registration       # Submit registration flow
GET    /api/auth/flows/recovery           # Init recovery flow
POST   /api/auth/flows/recovery           # Submit recovery flow
GET    /api/auth/flows/verification       # Init verification flow
POST   /api/auth/flows/verification       # Submit verification flow
GET    /api/auth/flows/settings           # Init settings flow
POST   /api/auth/flows/settings           # Submit settings flow
DELETE /api/auth/session                  # Logout
```

#### Token Endpoints

```text
POST   /api/tokens                        # Exchange Kratos session → JWT
POST   /api/tokens/refresh                # Refresh an expiring JWT
POST   /api/tokens/service-auth           # Exchange API key → service JWT
GET    /api/tokens/public-key             # Get JWT public key (JWKS)
```

#### Tenant Management (Admin)

```text
POST   /api/tenants                      # Create tenant
GET    /api/tenants                      # List all tenants
GET    /api/tenants/{id}                 # Get tenant details + role defs
PATCH  /api/tenants/{id}                 # Update tenant (name, roles)
DELETE /api/tenants/{id}                 # Deactivate tenant
```

#### Membership Management

```text
GET    /api/tenants/{id}/members         # List members of a tenant
POST   /api/tenants/{id}/members         # Add user to tenant with roles
PATCH  /api/tenants/{id}/members/{uid}   # Update user's roles in tenant
DELETE /api/tenants/{id}/members/{uid}   # Remove user from tenant
GET    /api/users/{uid}/memberships       # List all tenants a user belongs to
GET    /api/me/memberships                # List my tenant memberships
```

#### Service Account Management

```text
GET    /api/tenants/{id}/service-accounts              # List service accounts
POST   /api/tenants/{id}/service-accounts              # Create service account (returns API key once)
DELETE /api/tenants/{id}/service-accounts/{sa_id}      # Revoke service account
POST   /api/tenants/{id}/service-accounts/{sa_id}/rotate  # Rotate API key
```

#### Health

```text
GET    /health                            # Health check
```

### 7.5 Token Exchange Flow (Kratos Session to JWT)

This is the critical flow that bridges Kratos authentication with project-level authorization:

```python
@router.post("/api/tokens")
async def exchange_session_for_jwt(
    request: Request,
    tenant_id: str = Body(...),        # required: JWT is always scoped to one tenant
):
    # 1. Validate Kratos session (from cookie or X-Session-Token header)
    session = await kratos_client.get_session(request)
    if not session:
        raise HTTPException(401, "Not authenticated")

    user_id = session["identity"]["id"]
    email = session["identity"]["traits"]["email"]
    name = session["identity"]["traits"].get("name", {})
    session_id = session["id"]

    # 2. Check membership for the requested project
    membership = membership_service.get_membership(user_id, tenant_id)
    if not membership:
        raise HTTPException(403, f"No access to project {tenant_id}")

    # 3. Issue short-lived access token (1 hour)
    jti = str(uuid.uuid4())
    access_token = jwt_service.issue(
        sub=user_id,
        email=email,
        jti=jti,
        tenant_id=tenant_id,
        roles=membership.roles,
        expires_in=timedelta(hours=1),
    )

    # 4. Issue refresh token (7 days, stored server-side, hashed)
    refresh_token = refresh_token_service.create(
        user_id=user_id,
        tenant_id=tenant_id,
        kratos_session_id=session_id,
        expires_in=timedelta(days=7),
    )

    # 5. Audit log
    audit_log.log_event("token.issued", actor=user_id, target=tenant_id, details={"jti": jti})

    return {
        "access_token": access_token,
        "refresh_token": refresh_token,
        "expires_in": 3600,
        "token_type": "Bearer",
    }
```

### 7.6 Service Account Authentication

```python
@router.post("/api/tokens/service-auth")
async def service_auth(
    request: Request,
    tenant_id: str = Body(...),
    api_key: str = Body(...),
):
    client_ip = request.client.host

    # 0. Rate limiting
    if not rate_limiter.check(f"sa_auth:{tenant_id}:{client_ip}", max_attempts=10, window_seconds=60):
        audit_log.log_event("service_account.rate_limited", actor=client_ip, target=tenant_id)
        raise HTTPException(429, "Too many authentication attempts")

    # 1. Look up and verify service account
    sa = service_account_service.verify_api_key(tenant_id, api_key)
    if not sa:
        audit_log.log_event("service_account.auth_failed", actor=api_key[:12], target=tenant_id)
        raise HTTPException(401, "Invalid API key")

    if not sa.is_active:
        raise HTTPException(403, "Service account is disabled")

    # 2. Issue scoped JWT for service account (1 hour)
    jti = str(uuid.uuid4())
    token = jwt_service.issue(
        sub=f"sa:{sa.id}",
        email=None,
        jti=jti,
        tenant_id=tenant_id,
        roles=sa.roles,
        sa=True,
        expires_in=timedelta(hours=1),
    )

    # 3. Update last_used_at and audit
    service_account_service.touch(sa.id)
    audit_log.log_event("service_account.auth", actor=str(sa.id), target=tenant_id, details={"ip": client_ip})

    return {"access_token": token, "expires_in": 3600, "token_type": "Bearer"}
```

### 7.7 Implementation Steps

| # | Task | Files |
| --- | --- | --- |
| 1 | Create `middleware/Dockerfile` | `middleware/Dockerfile` |
| 2 | Create `middleware/requirements.txt` (fastapi, uvicorn, httpx, pydantic, sqlalchemy, asyncpg, pyjwt, cryptography, bcrypt) | `middleware/requirements.txt` |
| 3 | Create `middleware/app/config.py` — settings from env | `middleware/app/config.py` |
| 4 | Create `middleware/app/database.py` — SQLAlchemy models + DB init (including refresh_tokens, revoked_tokens, audit_log tables) | `middleware/app/database.py` |
| 5 | Create `middleware/app/main.py` — FastAPI app with CORS, startup events | `middleware/app/main.py` |
| 6 | Create `middleware/app/services/kratos_client.py` — Kratos API wrapper with circuit breaker | `middleware/app/services/kratos_client.py` |
| 7 | Create `middleware/app/services/jwt_service.py` — JWT sign/verify (RS256, 1h expiry, jti) | `middleware/app/services/jwt_service.py` |
| 8 | Create `middleware/app/services/refresh_token_service.py` — Refresh token CRUD + rotation | `middleware/app/services/refresh_token_service.py` |
| 9 | Create `middleware/app/services/tenant_service.py` — Project CRUD | `middleware/app/services/tenant_service.py` |
| 10 | Create `middleware/app/services/membership_service.py` — Membership CRUD | `middleware/app/services/membership_service.py` |
| 11 | Create `middleware/app/services/audit_log.py` — Audit event logging | `middleware/app/services/audit_log.py` |
| 12 | Create `middleware/app/services/rate_limiter.py` — In-memory rate limiter | `middleware/app/services/rate_limiter.py` |
| 13 | Create `middleware/app/middleware/auth.py` — JWT auth + admin role dependency | `middleware/app/middleware/auth.py` |
| 14 | Create `middleware/app/routers/auth.py` — Kratos flow proxying | `middleware/app/routers/auth.py` |
| 15 | Create `middleware/app/routers/tokens.py` — JWT issuance, refresh, service auth, revocation | `middleware/app/routers/tokens.py` |
| 16 | Create `middleware/app/routers/tenants.py` — Tenant management (admin-protected) | `middleware/app/routers/tenants.py` |
| 17 | Create `middleware/app/routers/memberships.py` — Role assignments (admin-protected) | `middleware/app/routers/memberships.py` |
| 18 | Create `middleware/app/routers/service_accounts.py` — API key management (admin-protected) | `middleware/app/routers/service_accounts.py` |
| 19 | Create Pydantic schemas | `middleware/app/models/schemas.py` |
| 20 | Create `.gitignore` (exclude `.env`, `keys/*.pem`) | `.gitignore` |
| 21 | Add `middleware` service to `docker-compose.yml` (no exposed DB/Kratos ports) | `docker-compose.yml` |
| 22 | Bootstrap `identity-service` project with `identity-admin` role | `scripts/bootstrap.sh` |
| 23 | Test: create project, add member, issue JWT, refresh JWT, verify revocation | — |

---

## 8. Phase 3: Next.js Self-Service UI

### 8.1 Purpose

Minimal self-service UI for:

- User login/registration (passwordless code)
- Viewing "My Projects" — which projects the user has access to
- Admin panel for managing projects, users, and role assignments
- Profile settings

### 8.2 Pages

| Route | Purpose | Auth Required |
| --- | --- | --- |
| `/login` | Login page (enter email, receive code, submit code) | No |
| `/register` | Registration page | No |
| `/recovery` | Account recovery | No |
| `/` | Home → redirect to `/projects` or `/login` | Yes |
| `/projects` | My projects list (with roles) | Yes |
| `/projects/[id]` | Tenant detail — members, roles, service accounts | Yes (tenant member) |
| `/settings` | Profile settings (email, name) | Yes |
| `/admin/projects` | Admin: create/manage tenants | Yes (super-admin) |
| `/admin/projects/[id]/members` | Admin: manage members & roles for a tenant | Yes (tenant admin) |
| `/error` | Error display | No |

### 8.3 Key Components

- **`FlowForm.tsx`** — Renders Kratos self-service flow UI nodes dynamically
- **`TenantCard.tsx`** — Displays a tenant with user's roles in it
- **`RoleManager.tsx`** — UI for assigning/removing roles for a user in a tenant
- **`ServiceAccountList.tsx`** — Manage service accounts and API keys

### 8.4 Implementation Steps

| # | Task | Files |
| --- | --- | --- |
| 1 | Create `ui/Dockerfile` (Node 20 Alpine, multi-stage build) | `ui/Dockerfile` |
| 2 | Initialize Next.js project with TypeScript, App Router | `ui/` |
| 3 | Create root layout with basic styling | `ui/src/app/layout.tsx` |
| 4 | Create `FlowForm` component for rendering Kratos flows | `ui/src/components/FlowForm.tsx` |
| 5 | Create login page | `ui/src/app/login/page.tsx` |
| 6 | Create registration page | `ui/src/app/register/page.tsx` |
| 7 | Create recovery page | `ui/src/app/recovery/page.tsx` |
| 8 | Create settings page | `ui/src/app/settings/page.tsx` |
| 9 | Create tenants list page | `ui/src/app/projects/page.tsx` |
| 10 | Create tenant detail page | `ui/src/app/projects/[id]/page.tsx` |
| 11 | Create admin tenant management pages | `ui/src/app/admin/` |
| 12 | Create API client helpers | `ui/src/lib/api.ts` |
| 13 | Add `ui` service to `docker-compose.yml` | `docker-compose.yml` |

---

## 9. Phase 4: Integration & Testing

### 9.1 End-to-End Flow Test

1. **Start all services:** `docker compose up -d`

2. **Create a tenant:**

   ```bash
   curl -X POST http://localhost:6600/api/tenants \
     -H "Content-Type: application/json" \
     -d '{
       "id": "monitoring-api",
       "name": "Monitoring API",
       "roles": {
         "admin": {"description": "Full access"},
         "operator": {"description": "Manage alerts"},
         "viewer": {"description": "Read-only"}
       }
     }'
   ```

3. **Register a user (via Kratos):**

   ```bash
   # Init registration flow
   FLOW=$(curl -s http://localhost:6600/api/auth/flows/registration | jq -r '.id')

   # Submit email
   curl -X POST "http://localhost:6600/api/auth/flows/registration?flow=$FLOW" \
     -H "Content-Type: application/json" \
     -d '{"method": "code", "traits": {"email": "user@example.com", "name": {"first": "John", "last": "Doe"}}}'

   # Check MailSlurper for code: http://localhost:4436

   # Submit code (creates session)
   curl -X POST "http://localhost:6600/api/auth/flows/registration?flow=$FLOW" \
     -H "Content-Type: application/json" \
     -c cookies.txt \
     -d '{"method": "code", "code": "<code_from_email>"}'
   ```

4. **Add user to project with roles:**

   ```bash
   curl -X POST http://localhost:6600/api/tenants/monitoring-api/members \
     -H "Content-Type: application/json" \
     -d '{"user_id": "<kratos_identity_id>", "roles": ["operator", "viewer"]}'
   ```

5. **Exchange session for JWT:**

   ```bash
   JWT=$(curl -s -X POST http://localhost:6600/api/tokens \
     -b cookies.txt \
     -H "Content-Type: application/json" \
     -d '{"tenant_id": "monitoring-api"}' | jq -r '.token')

   echo $JWT | cut -d. -f2 | base64 -d | jq .
   # Should show: {"sub": "...", "tenants": {"monitoring-api": {"roles": ["operator", "viewer"]}}}
   ```

6. **Create a service account:**

   ```bash
   curl -X POST http://localhost:6600/api/tenants/monitoring-api/service-accounts \
     -H "Content-Type: application/json" \
     -d '{"name": "cron-worker", "roles": ["viewer"]}'
   # Returns: {"id": "...", "api_key": "sa_live_abc123..."} (shown only once!)
   ```

7. **Service account auth:**

   ```bash
   SA_JWT=$(curl -s -X POST http://localhost:6600/api/tokens/service-auth \
     -H "Content-Type: application/json" \
     -d '{"tenant_id": "monitoring-api", "api_key": "sa_live_abc123..."}' | jq -r '.token')
   ```

8. **Verify JWT offline (as a tenant server would):**

   ```bash
   # Get public key
   curl -s http://localhost:6600/api/tokens/public-key -o public.pem

   # Verify with openssl (or in your tenant server code)
   echo $JWT | python3 -c "
   import sys, jwt
   token = sys.stdin.read().strip()
   key = open('public.pem').read()
   print(jwt.decode(token, key, algorithms=['RS256'], options={'verify_iss': False}))
   "
   ```

### 9.2 Test Scripts

**`scripts/seed-tenants.sh`:**

```bash
#!/bin/bash
BASE_URL="http://localhost:6600"

echo "Creating tenants..."

curl -s -X POST "$BASE_URL/api/tenants" \
  -H "Content-Type: application/json" \
  -d '{
    "id": "monitoring-api",
    "name": "Monitoring API",
    "roles": {
      "admin": {"description": "Full access"},
      "operator": {"description": "Manage alerts and dashboards"},
      "viewer": {"description": "Read-only access"}
    }
  }' | jq .

curl -s -X POST "$BASE_URL/api/tenants" \
  -H "Content-Type: application/json" \
  -d '{
    "id": "data-pipeline",
    "name": "Data Pipeline",
    "roles": {
      "admin": {"description": "Full access"},
      "engineer": {"description": "Run and manage pipelines"},
      "readonly": {"description": "View pipeline status"}
    }
  }' | jq .

curl -s -X POST "$BASE_URL/api/tenants" \
  -H "Content-Type: application/json" \
  -d '{
    "id": "deploy-tool",
    "name": "Deployment Tool",
    "roles": {
      "admin": {"description": "Full access"},
      "deployer": {"description": "Trigger deployments"},
      "auditor": {"description": "View deployment history"}
    }
  }' | jq .

echo "Tenants seeded."
```

**`scripts/test-api.sh`:**

```bash
#!/bin/bash
set -e

BASE_URL="http://localhost:6600"

echo "=== Health Check ==="
curl -sf "$BASE_URL/health" | jq .

echo "=== List Projects ==="
curl -sf "$BASE_URL/api/tenants" | jq .

echo "=== Kratos Health ==="
curl -sf "http://localhost:4433/health/alive" | jq .

echo "=== Get Public Key ==="
curl -sf "$BASE_URL/api/tokens/public-key" | head -2

echo "All smoke tests passed!"
```

---

## 10. Integrating Existing Servers — Full Walkthrough

This section uses a concrete example — **"Project X" (a monitoring API built with FastAPI)** — to show exactly how an existing auth-free REST API server outsources its login, session management, and RBAC to the identity service.

### 10.1 Before vs After

#### Before (no auth)

```text
┌────────────┐         ┌───────────────────────────┐
│  Client /  │────────▶│  Project X (monitoring)    │
│  Browser   │◀────────│  Port 9000                 │
│            │         │                            │
│            │         │  GET /alerts      → anyone │
│            │         │  POST /alerts     → anyone │
│            │         │  DELETE /alerts   → anyone │
│            │         │  No login, no users,       │
│            │         │  no roles, no sessions     │
└────────────┘         └───────────────────────────┘
```

#### After (auth via identity service)

```text
┌────────────┐         ┌───────────────────────────────────────────┐
│  Client /  │         │  Project X (monitoring) — Port 9000       │
│  Browser   │         │                                           │
│            │         │  GET  /alerts      → requires JWT         │
│            │         │  POST /alerts      → role: operator       │
│            │         │  DELETE /alerts    → role: admin           │
│            │         │                                           │
│            │         │  • No user tables                         │
│            │         │  • No login endpoints                     │
│            │         │  • No session storage                     │
│            │         │  • Just verifies JWT (offline, ~1ms)      │
│            │         │  • Reads roles from JWT claims            │
└─────┬──────┘         └───────────────────┬───────────────────────┘
      │                                     │
      │  1. Login (get JWT)                 │  Startup: fetch public key
      ▼                                     ▼
┌──────────────────────────────────────────────────────────────────┐
│              Identity Service                     │
│              http://identity-service:6600                        │
│                                                                  │
│  /api/auth/flows/login       → Kratos passwordless login        │
│  /api/tokens                 → Exchange session → JWT           │
│  /api/tokens/public-key      → RS256 public key for verifying   │
│  /api/tenants               → Project registration + roles     │
│  /api/tenants/{id}/members  → User-project role assignments    │
└──────────────────────────────────────────────────────────────────┘
```

**What Project X no longer needs to build or maintain:**

- User registration / login endpoints
- Password hashing / storage
- Session table / session cookies
- "Forgot password" flow
- Email verification
- User profile management
- Role / permission tables

All of this is **outsourced** to the identity service.

### 10.2 Step-by-Step Integration

#### Step 1: Register Project X in the Identity Service

Before writing any code in Project X, register it as a tenant and define its roles:

```bash
curl -X POST http://identity-service:6600/api/tenants \
  -H "Content-Type: application/json" \
  -d '{
    "id": "monitoring-api",
    "name": "Monitoring API",
    "roles": {
      "admin":    {"description": "Full access — manage alerts, users, settings"},
      "operator": {"description": "Create, update, acknowledge alerts"},
      "viewer":   {"description": "Read-only access to alerts and dashboards"}
    }
  }'
```

#### Step 2: Assign Users to Project X

After users register via the identity service UI, assign them to Project X with roles:

```bash
# Give user "john" operator + viewer roles on monitoring-api
curl -X POST http://identity-service:6600/api/tenants/monitoring-api/members \
  -H "Content-Type: application/json" \
  -d '{"user_id": "<john_kratos_id>", "roles": ["operator", "viewer"]}'

# Give user "jane" admin role
curl -X POST http://identity-service:6600/api/tenants/monitoring-api/members \
  -H "Content-Type: application/json" \
  -d '{"user_id": "<jane_kratos_id>", "roles": ["admin"]}'
```

#### Step 3: Add Configuration to Project X

Add these environment variables to Project X's config:

```bash
# Project X .env
IDENTITY_SERVICE_URL=http://identity-service:6600
IDENTITY_TENANT_ID=monitoring-api
JWT_PUBLIC_KEY_URL=http://identity-service:6600/api/tokens/public-key
# Or mount the public key file directly:
# JWT_PUBLIC_KEY_PATH=/etc/secrets/identity-service-public.pem
```

#### Step 4: Add JWT Auth Middleware to Project X

This is the core code change. Project X adds middleware that:

1. Extracts the `Authorization: Bearer <token>` header
2. Verifies the JWT signature (offline — no network call)
3. Checks the token is not expired
4. Extracts the user's roles for this tenant
5. Makes user info available to route handlers

**Python / FastAPI — Full Implementation:**

```python
# project_x/auth.py
import httpx
import jwt
from datetime import datetime, timezone
from fastapi import Request, HTTPException
from starlette.middleware.base import BaseHTTPMiddleware
from functools import wraps
from typing import Optional
import os

# ──────────────────────────────────────────────
# Configuration
# ──────────────────────────────────────────────
IDENTITY_SERVICE_URL = os.getenv("IDENTITY_SERVICE_URL", "http://identity-service:6600")
PROJECT_ID = os.getenv("IDENTITY_TENANT_ID", "monitoring-api")
JWT_PUBLIC_KEY_URL = os.getenv("JWT_PUBLIC_KEY_URL", f"{IDENTITY_SERVICE_URL}/api/tokens/public-key")
JWT_PUBLIC_KEY_PATH = os.getenv("JWT_PUBLIC_KEY_PATH")  # optional: file path

# ──────────────────────────────────────────────
# Public Key Loader (cached)
# ──────────────────────────────────────────────
_public_key_cache: Optional[str] = None

def get_public_key() -> str:
    """Load and cache the JWT public key."""
    global _public_key_cache
    if _public_key_cache:
        return _public_key_cache

    if JWT_PUBLIC_KEY_PATH:
        with open(JWT_PUBLIC_KEY_PATH, "r") as f:
            _public_key_cache = f.read()
    else:
        resp = httpx.get(JWT_PUBLIC_KEY_URL, timeout=10)
        resp.raise_for_status()
        _public_key_cache = resp.text

    return _public_key_cache

def reload_public_key():
    """Force reload (call if key rotation happens)."""
    global _public_key_cache
    _public_key_cache = None
    return get_public_key()

# ──────────────────────────────────────────────
# JWT Verification
# ──────────────────────────────────────────────
class AuthUser:
    """Parsed user from JWT claims."""
    def __init__(self, claims: dict):
        self.id: str = claims["sub"]
        self.email: Optional[str] = claims.get("email")
        self.name: Optional[str] = claims.get("name")
        self.is_service_account: bool = claims.get("service_account", False)
        self.roles: list[str] = (
            claims.get("tenants", {})
                  .get(PROJECT_ID, {})
                  .get("roles", [])
        )
        self.all_projects: dict = claims.get("tenants", {})
        self.raw_claims: dict = claims

    def has_role(self, role: str) -> bool:
        return role in self.roles

    def has_any_role(self, roles: list[str]) -> bool:
        return any(r in self.roles for r in roles)

def verify_token(token: str) -> AuthUser:
    """Verify JWT and return AuthUser. Raises HTTPException on failure."""
    try:
        public_key = get_public_key()
        claims = jwt.decode(
            token,
            public_key,
            algorithms=["RS256"],
            issuer="identity-service",
        )
    except jwt.ExpiredSignatureError:
        raise HTTPException(401, "Token expired")
    except jwt.InvalidTokenError as e:
        raise HTTPException(401, f"Invalid token: {e}")

    user = AuthUser(claims)

    # Ensure user has access to THIS project
    if PROJECT_ID not in claims.get("tenants", {}):
        raise HTTPException(403, f"No access to project {PROJECT_ID}")

    return user

# ──────────────────────────────────────────────
# FastAPI Middleware (auto-parses JWT on every request)
# ──────────────────────────────────────────────
# List of paths that don't require auth
PUBLIC_PATHS = {"/health", "/docs", "/openapi.json", "/redoc"}

class JWTAuthMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request: Request, call_next):
        # Skip auth for public paths
        if request.url.path in PUBLIC_PATHS:
            return await call_next(request)

        # Extract token
        auth_header = request.headers.get("Authorization", "")
        if not auth_header.startswith("Bearer "):
            raise HTTPException(401, "Missing Authorization header")

        token = auth_header[7:]  # Strip "Bearer "
        request.state.user = verify_token(token)

        return await call_next(request)

# ──────────────────────────────────────────────
# Role-checking Decorator
# ──────────────────────────────────────────────
def require_role(*roles: str):
    """Decorator that checks the authenticated user has at least one of the given roles."""
    def decorator(func):
        @wraps(func)
        async def wrapper(request: Request, *args, **kwargs):
            user: AuthUser = request.state.user
            if not user.has_any_role(list(roles)):
                raise HTTPException(
                    403,
                    f"Requires one of roles: {', '.join(roles)}. "
                    f"You have: {', '.join(user.roles)}"
                )
            return await func(request, *args, **kwargs)
        return wrapper
    return decorator
```

#### Step 5: Wire Middleware into Project X's App

```python
# project_x/main.py
from fastapi import FastAPI
from .auth import JWTAuthMiddleware, get_public_key

app = FastAPI(title="Monitoring API")

# Add auth middleware
app.add_middleware(JWTAuthMiddleware)

@app.on_event("startup")
async def startup():
    # Pre-fetch and cache the public key at startup
    get_public_key()
    print("JWT public key loaded from identity service")
```

#### Step 6: Protect Routes with Role Checks

```python
# project_x/routes/alerts.py
from fastapi import APIRouter, Request
from ..auth import require_role

router = APIRouter(prefix="/alerts", tags=["Alerts"])

@router.get("/")
async def list_alerts(request: Request):
    """Any authenticated user with tenant access can list alerts."""
    user = request.state.user
    # user.id, user.email, user.roles are all available
    return {"alerts": [...], "viewed_by": user.email}

@router.post("/")
@require_role("operator", "admin")
async def create_alert(request: Request, alert: AlertCreate):
    """Only operators and admins can create alerts."""
    user = request.state.user
    return {"alert": {...}, "created_by": user.id}

@router.delete("/{alert_id}")
@require_role("admin")
async def delete_alert(request: Request, alert_id: str):
    """Only admins can delete alerts."""
    return {"deleted": alert_id}

@router.post("/{alert_id}/acknowledge")
@require_role("operator", "admin")
async def acknowledge_alert(request: Request, alert_id: str):
    """Operators and admins can acknowledge alerts."""
    user = request.state.user
    return {"acknowledged_by": user.email}
```

#### Step 7: Handle Token Lifecycle in the Client

The client (browser, CLI, or another service) is responsible for obtaining and refreshing tokens:

```text
┌─────────────────────────────────────────────────────────────────────┐
│                      Client Token Lifecycle                         │
│                                                                     │
│  1. LOGIN                                                           │
│     POST identity-service:6600/api/auth/flows/login                 │
│     → Submit email → Receive code → Submit code → Kratos session    │
│                                                                     │
│  2. GET JWT                                                         │
│     POST identity-service:6600/api/tokens                           │
│       Body: {"tenant_id": "monitoring-api"}    (optional scope)    │
│     → Returns: {"token": "eyJ...", "expires_in": 86400}            │
│                                                                     │
│  3. CALL PROJECT X                                                  │
│     GET  project-x:9000/alerts                                      │
│       Header: Authorization: Bearer eyJ...                          │
│     → 200 OK (JWT verified offline by Project X)                   │
│                                                                     │
│  4. TOKEN EXPIRED? REFRESH                                          │
│     POST identity-service:6600/api/tokens/refresh                   │
│       Body: {"token": "eyJ..."}                                     │
│     → Returns new token (if Kratos session still valid)            │
│                                                                     │
│  5. SESSION EXPIRED? RE-LOGIN                                       │
│     If refresh fails with 401 → redirect to login                  │
└─────────────────────────────────────────────────────────────────────┘
```

**Client-side example (JavaScript/TypeScript):**

```typescript
// Shared auth client used by any frontend calling Project X

const IDENTITY_URL = "http://identity-service:6600";

class AuthClient {
  private token: string | null = null;
  private expiresAt: number = 0;

  /** Full login flow: email → code → session → JWT */
  async login(email: string, tenantId: string): Promise<void> {
    // 1. Init login flow
    const flow = await fetch(`${IDENTITY_URL}/api/auth/flows/login`).then(r => r.json());

    // 2. Submit email (triggers code email)
    await fetch(`${IDENTITY_URL}/api/auth/flows/login?flow=${flow.id}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      credentials: "include",
      body: JSON.stringify({ method: "code", identifier: email }),
    });

    // 3. User enters code from email...
    // (in a real UI, this is a separate form submission)
  }

  /** Submit the one-time code to complete login */
  async submitCode(flowId: string, code: string, tenantId: string): Promise<void> {
    // Complete Kratos login
    await fetch(`${IDENTITY_URL}/api/auth/flows/login?flow=${flowId}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      credentials: "include",
      body: JSON.stringify({ method: "code", code }),
    });

    // Exchange session for tenant-scoped JWT
    const tokenResp = await fetch(`${IDENTITY_URL}/api/tokens`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      credentials: "include",
      body: JSON.stringify({ tenant_id: tenantId }),
    }).then(r => r.json());

    this.token = tokenResp.token;
    this.expiresAt = Date.now() + tokenResp.expires_in * 1000;
  }

  /** Get a valid token, refreshing if needed */
  async getToken(): Promise<string> {
    if (!this.token) throw new Error("Not logged in");

    // Refresh if expiring in < 5 minutes
    if (Date.now() > this.expiresAt - 5 * 60 * 1000) {
      const resp = await fetch(`${IDENTITY_URL}/api/tokens/refresh`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ token: this.token }),
      });
      if (!resp.ok) throw new Error("Session expired — re-login required");
      const data = await resp.json();
      this.token = data.token;
      this.expiresAt = Date.now() + data.expires_in * 1000;
    }

    return this.token;
  }

  /** Make an authenticated request to any tenant server */
  async request(url: string, options: RequestInit = {}): Promise<Response> {
    const token = await this.getToken();
    return fetch(url, {
      ...options,
      headers: {
        ...options.headers,
        Authorization: `Bearer ${token}`,
      },
    });
  }
}

// Usage:
const auth = new AuthClient();
// After login:
const alerts = await auth.request("http://project-x:9000/alerts").then(r => r.json());
```

### 10.3 Service Account Integration (Server-to-Server)

For background jobs, cron tasks, or inter-service calls that don't have a human user:

#### Create a Service Account

```bash
# One-time setup: create a service account for Project X's cron worker
curl -X POST http://identity-service:6600/api/tenants/monitoring-api/service-accounts \
  -H "Content-Type: application/json" \
  -d '{"name": "alert-cleanup-cron", "roles": ["operator"]}'

# Response (save the api_key — it is shown ONLY ONCE):
# {"id": "sa-uuid", "api_key": "sa_live_xK9m2..."}
```

#### Use Service Account in Project X's Background Jobs

```python
# project_x/jobs/cleanup.py
import httpx
import os

IDENTITY_URL = os.getenv("IDENTITY_SERVICE_URL")
PROJECT_ID = os.getenv("IDENTITY_TENANT_ID")
SA_API_KEY = os.getenv("SA_API_KEY")  # from secrets

def get_service_token() -> str:
    """Exchange service account API key for a JWT."""
    resp = httpx.post(
        f"{IDENTITY_URL}/api/tokens/service-auth",
        json={"tenant_id": PROJECT_ID, "api_key": SA_API_KEY},
    )
    resp.raise_for_status()
    return resp.json()["token"]

def run_cleanup():
    token = get_service_token()

    # Now call Project X's own API (or another project) with the JWT
    resp = httpx.delete(
        "http://localhost:9000/alerts/expired",
        headers={"Authorization": f"Bearer {token}"},
    )
    print(f"Cleanup result: {resp.status_code}")
```

### 10.4 Handling Unauthenticated Users (Login Redirect)

If Project X has a frontend (web UI), unauthenticated users should be redirected to the identity service login page:

#### Backend API Pattern (401 Response)

```python
# Project X returns 401 → client handles redirect
@router.get("/alerts")
async def list_alerts(request: Request):
    # JWTAuthMiddleware already handles this:
    # - No token → 401 {"detail": "Missing Authorization header"}
    # - Expired  → 401 {"detail": "Token expired"}
    # - No roles → 403 {"detail": "No access to project monitoring-api"}
    ...
```

#### Frontend Redirect Pattern

```typescript
// In Project X's frontend (React, Next.js, etc.)
const IDENTITY_UI_URL = "http://identity-service:3000";

async function fetchWithAuth(url: string) {
  const resp = await auth.request(url);

  if (resp.status === 401) {
    // Token expired and refresh failed → redirect to login
    const returnUrl = encodeURIComponent(window.location.href);
    window.location.href = `${IDENTITY_UI_URL}/login?return_to=${returnUrl}`;
    return;
  }

  if (resp.status === 403) {
    // User is authenticated but lacks the required role
    alert("You don't have permission to access this resource.");
    return;
  }

  return resp.json();
}
```

#### Post-Login Redirect Back to Project X

After login, the identity service UI can redirect back to Project X:

```text
1. Project X frontend → identity-service:3000/login?return_to=http://project-x:9000/dashboard
2. User logs in → gets JWT
3. Identity UI → redirects to http://project-x:9000/dashboard
4. Project X frontend → stores JWT, loads dashboard
```

The identity service UI handles the `return_to` query parameter and redirects after successful login + token exchange.

### 10.5 Node.js / Express Integration

Full integration example for a Node.js project:

```javascript
// project_y/auth.js
const jwt = require("jsonwebtoken");
const fs = require("fs");

const PROJECT_ID = process.env.IDENTITY_TENANT_ID || "data-pipeline";
let publicKey = null;

// Load public key (at startup or lazily)
async function loadPublicKey() {
  if (process.env.JWT_PUBLIC_KEY_PATH) {
    publicKey = fs.readFileSync(process.env.JWT_PUBLIC_KEY_PATH, "utf8");
  } else {
    const resp = await fetch(
      `${process.env.IDENTITY_SERVICE_URL}/api/tokens/public-key`
    );
    publicKey = await resp.text();
  }
}

// Middleware: verify JWT and attach user to req
function authMiddleware(req, res, next) {
  if (["/health", "/docs"].includes(req.path)) return next();

  const header = req.headers.authorization || "";
  if (!header.startsWith("Bearer ")) {
    return res.status(401).json({ error: "Missing Authorization header" });
  }

  try {
    const token = header.slice(7);
    const claims = jwt.verify(token, publicKey, {
      algorithms: ["RS256"],
      issuer: "identity-service",
    });

    // Check tenant access
    if (!claims.tenants?.[PROJECT_ID]) {
      return res.status(403).json({ error: `No access to ${PROJECT_ID}` });
    }

    req.user = {
      id: claims.sub,
      email: claims.email,
      name: claims.name,
      roles: claims.tenants[PROJECT_ID].roles || [],
      isServiceAccount: claims.service_account || false,
    };

    next();
  } catch (err) {
    if (err.name === "TokenExpiredError") {
      return res.status(401).json({ error: "Token expired" });
    }
    return res.status(401).json({ error: "Invalid token" });
  }
}

// Decorator: check role
function requireRole(...roles) {
  return (req, res, next) => {
    const userRoles = req.user?.roles || [];
    if (roles.some((r) => userRoles.includes(r))) {
      next();
    } else {
      res.status(403).json({
        error: `Requires role: ${roles.join(" or ")}. You have: ${userRoles.join(", ")}`,
      });
    }
  };
}

module.exports = { loadPublicKey, authMiddleware, requireRole };
```

```javascript
// project_y/app.js
const express = require("express");
const { loadPublicKey, authMiddleware, requireRole } = require("./auth");

const app = express();
app.use(express.json());
app.use(authMiddleware);

// Public (no role check — any tenant member)
app.get("/pipelines", (req, res) => {
  res.json({ pipelines: [...], requested_by: req.user.email });
});

// Role-protected
app.post("/pipelines", requireRole("engineer", "admin"), (req, res) => {
  res.json({ created: true, by: req.user.id });
});

app.delete("/pipelines/:id", requireRole("admin"), (req, res) => {
  res.json({ deleted: req.params.id });
});

// Start
loadPublicKey().then(() => {
  app.listen(9001, () => console.log("Data Pipeline API on :9001"));
});
```

### 10.6 Go Integration

```go
// project_z/auth/middleware.go
package auth

import (
    "context"
    "fmt"
    "net/http"
    "os"
    "strings"

    "github.com/golang-jwt/jwt/v5"
)

type User struct {
    ID               string              `json:"sub"`
    Email            string              `json:"email"`
    Name             string              `json:"name"`
    Projects         map[string]Project  `json:"tenants"`
    IsServiceAccount bool                `json:"service_account"`
}

type Project struct {
    Roles []string `json:"roles"`
}

type contextKey string
const UserKey contextKey = "user"

var (
    publicKey  interface{}
    projectID  = os.Getenv("IDENTITY_TENANT_ID") // e.g., "deploy-tool"
)

func LoadPublicKey(pemPath string) error {
    data, err := os.ReadFile(pemPath)
    if err != nil {
        return err
    }
    publicKey, err = jwt.ParseRSAPublicKeyFromPEM(data)
    return err
}

func AuthMiddleware(next http.Handler) http.Handler {
    return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        // Skip health checks
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
        token, err := jwt.Parse(tokenStr, func(t *jwt.Token) (interface{}, error) {
            if _, ok := t.Method.(*jwt.SigningMethodRSA); !ok {
                return nil, fmt.Errorf("unexpected signing method: %v", t.Header["alg"])
            }
            return publicKey, nil
        }, jwt.WithIssuer("identity-service"))

        if err != nil || !token.Valid {
            http.Error(w, `{"error":"Invalid token"}`, 401)
            return
        }

        claims := token.Claims.(jwt.MapClaims)

        // Check tenant access
        projects, _ := claims["tenants"].(map[string]interface{})
        if _, ok := projects[projectID]; !ok {
            http.Error(w, fmt.Sprintf(`{"error":"No access to %s"}`, projectID), 403)
            return
        }

        // Build user and inject into context
        user := User{
            ID:    claims["sub"].(string),
            Email: claimStr(claims, "email"),
            Name:  claimStr(claims, "name"),
        }
        ctx := context.WithValue(r.Context(), UserKey, &user)
        next.ServeHTTP(w, r.WithContext(ctx))
    })
}

func GetUser(r *http.Request) *User {
    return r.Context().Value(UserKey).(*User)
}

func RequireRole(roles ...string) func(http.Handler) http.Handler {
    return func(next http.Handler) http.Handler {
        return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
            user := GetUser(r)
            proj, _ := user.Projects[projectID]
            for _, required := range roles {
                for _, has := range proj.Roles {
                    if required == has {
                        next.ServeHTTP(w, r)
                        return
                    }
                }
            }
            http.Error(w, `{"error":"Insufficient permissions"}`, 403)
        })
    }
}

func claimStr(c jwt.MapClaims, key string) string {
    v, _ := c[key].(string)
    return v
}
```

### 10.7 What Exactly Gets Outsourced

Summary of what each tenant **removes** and what it **adds**:

| Concern | Before (build yourself) | After (outsourced) |
| --- | --- | --- |
| **User registration** | Build signup form, hash password, store in DB, send verification email | Gone — identity service handles it |
| **User login** | Build login form, verify password, create session, set cookie | Gone — identity service handles it |
| **Password reset** | Build forgot-password flow, email link, reset form | Gone — identity service handles it |
| **Email verification** | Build verify-email flow, send code, update status | Gone — identity service handles it |
| **Session storage** | Sessions table in DB, session middleware, expiry logic | Gone — JWT is stateless, no session table needed |
| **Session validation** | DB lookup on every request to check session validity | Replaced by offline JWT signature check (~1ms, no DB, no network) |
| **User profile** | Users table, profile update endpoints | Gone — identity service handles it |
| **Role definitions** | Roles table, role assignment logic | Defined once when registering the tenant; managed via identity API |
| **Role checking** | Custom middleware to check user.role | Add ~50 lines: JWT middleware + `@require_role` decorator |
| **Service accounts** | Build API key generation, storage, validation | Gone — identity service handles it |
| **What you ADD** | — | 1 file (`auth.py`/`auth.js`/`auth.go`) + 2 env vars |

### 10.8 Integration Checklist Per Project

Use this checklist when integrating each of your 5-15 servers:

**One-time setup (identity service side):**

- [ ] Register project: `POST /api/tenants` with id, name, and role definitions
- [ ] Assign initial users: `POST /api/tenants/{id}/members` for each user
- [ ] Create service accounts (if needed): `POST /api/tenants/{id}/service-accounts`

**Code changes (tenant server side):**

- [ ] Add env vars: `IDENTITY_SERVICE_URL`, `IDENTITY_TENANT_ID`, `JWT_PUBLIC_KEY_URL`
- [ ] Add auth file: `auth.py` / `auth.js` / `auth.go` (~100-150 lines, copy from examples above)
- [ ] Wire auth middleware into app startup
- [ ] Add `@require_role(...)` to protected endpoints
- [ ] Add `/health` to the public (skip-auth) path list
- [ ] Remove any existing auth code (login routes, session tables, user tables)

**Testing:**

- [ ] Verify: request without JWT → `401`
- [ ] Verify: request with valid JWT but no tenant access → `403`
- [ ] Verify: request with valid JWT and correct role → `200`
- [ ] Verify: request with expired JWT → `401`
- [ ] Verify: service account JWT works for background jobs

### 10.9 Python SDK (Drop-in Package)

For Python projects, we provide a reusable package in `sdk/python/` so you don't even need to copy the auth code:

```python
# Install
pip install -e /path/to/kratos/sdk/python

# Usage in any FastAPI project — 3 lines to integrate:
from fastapi import FastAPI
from identity_sdk import JWTAuthMiddleware, require_role

app = FastAPI()
app.add_middleware(
    JWTAuthMiddleware,
    public_key_url="http://identity-service:6600/api/tokens/public-key",
    tenant_id="monitoring-api",
    skip_paths={"/health", "/docs", "/openapi.json"},
)

@app.get("/alerts")
async def list_alerts(request: Request):
    user = request.state.user  # AuthUser object
    return {"alerts": [...]}

@app.post("/alerts")
@require_role("operator", "admin")
async def create_alert(request: Request):
    ...
```

The SDK provides:

- `JWTAuthMiddleware` — FastAPI/Starlette middleware with public key caching
- `AuthUser` — Typed user object with `.id`, `.email`, `.roles`, `.has_role()`, `.has_any_role()`
- `require_role(*roles)` — Decorator for role-based endpoint protection
- `get_service_token(api_key, tenant_id)` — Helper for service account auth
- Flask support via `flask_jwt_middleware()` (if any projects use Flask)

---

## 11. REST API Reference

### Auth Flows (Kratos Proxy)

| Method | Path | Description |
| --- | --- | --- |
| `GET` | `/api/auth/flows/login` | Init login flow |
| `POST` | `/api/auth/flows/login` | Submit login flow |
| `GET` | `/api/auth/flows/registration` | Init registration flow |
| `POST` | `/api/auth/flows/registration` | Submit registration flow |
| `GET` | `/api/auth/flows/recovery` | Init recovery flow |
| `POST` | `/api/auth/flows/recovery` | Submit recovery flow |
| `GET` | `/api/auth/flows/verification` | Init verification flow |
| `POST` | `/api/auth/flows/verification` | Submit verification flow |
| `GET` | `/api/auth/flows/settings` | Init settings flow (auth required) |
| `POST` | `/api/auth/flows/settings` | Submit settings flow (auth required) |
| `DELETE` | `/api/auth/session` | Logout |

### Token Endpoints

| Method | Path | Description | Request | Response |
| --- | --- | --- | --- | --- |
| `POST` | `/api/tokens` | Exchange Kratos session for tenant-scoped JWT | `{tenant_id}` | `{access_token, refresh_token, expires_in}` |
| `POST` | `/api/tokens/refresh` | Refresh access token | `{refresh_token, tenant_id}` | `{access_token, refresh_token, expires_in}` |
| `POST` | `/api/tokens/service-auth` | Service account auth | `{tenant_id, api_key}` | `{access_token, expires_in}` |
| `GET` | `/api/tokens/public-key` | Get JWT verification key (PEM or JWKS) | — | PEM public key |
| `GET` | `/api/tokens/revoked` | List revoked token IDs (for denylist sync) | `?since=<timestamp>` | `[{jti, revoked_at}]` |
| `POST` | `/api/tokens/revoke` | Revoke a specific token (admin) | `{jti, reason}` | 204 |

### Tenant Management

| Method | Path | Description | Request | Response |
| --- | --- | --- | --- | --- |
| `POST` | `/api/tenants` | Create tenant | `{id, name, roles}` | Project |
| `GET` | `/api/tenants` | List all tenants | — | `[Project]` |
| `GET` | `/api/tenants/{id}` | Get tenant details | — | Project |
| `PATCH` | `/api/tenants/{id}` | Update tenant | `{name?, roles?}` | Project |
| `DELETE` | `/api/tenants/{id}` | Deactivate tenant | — | 204 |

### Membership Management

| Method | Path | Description | Request | Response |
| --- | --- | --- | --- | --- |
| `GET` | `/api/tenants/{id}/members` | List tenant members | — | `[Membership]` |
| `POST` | `/api/tenants/{id}/members` | Add member to tenant | `{user_id, roles}` | Membership |
| `PATCH` | `/api/tenants/{id}/members/{uid}` | Update member roles | `{roles}` | Membership |
| `DELETE` | `/api/tenants/{id}/members/{uid}` | Remove member | — | 204 |
| `GET` | `/api/users/{uid}/memberships` | List user's tenants | — | `[Membership]` |
| `GET` | `/api/me/memberships` | My tenant memberships | — | `[Membership]` |

### Service Account Management

| Method | Path | Description | Request | Response |
| --- | --- | --- | --- | --- |
| `GET` | `/api/tenants/{id}/service-accounts` | List service accounts | — | `[ServiceAccount]` |
| `POST` | `/api/tenants/{id}/service-accounts` | Create (returns API key once) | `{name, roles}` | `{id, api_key}` |
| `DELETE` | `/api/tenants/{id}/service-accounts/{sa_id}` | Revoke | — | 204 |
| `POST` | `/api/tenants/{id}/service-accounts/{sa_id}/rotate` | Rotate API key | — | `{api_key}` |

---

## 12. Configuration Reference

### Environment Variables (`.env`)

```bash
# Database (shared PostgreSQL instance)
POSTGRES_USER=kratos
POSTGRES_PASSWORD=secret
POSTGRES_DB=kratos

# Kratos DSN
DSN=postgres://kratos:secret@postgresd:5432/kratos?sslmode=disable&max_conns=20&max_idle_conns=4

# Kratos
SERVE_PUBLIC_BASE_URL=http://127.0.0.1:4433/
SERVE_ADMIN_BASE_URL=http://kratos:4434/
LOG_LEVEL=debug
SECRETS_COOKIE=dev-cookie-secret-minimum-32-chars!!
SECRETS_CIPHER=dev-cipher-secret-exactly-32ch!

# FastAPI Middleware
KRATOS_PUBLIC_URL=http://kratos:4433
KRATOS_ADMIN_URL=http://kratos:4434
MIDDLEWARE_DATABASE_URL=postgres://kratos:secret@postgresd:5432/identity_middleware
MIDDLEWARE_PORT=6600
JWT_PRIVATE_KEY_PATH=/app/keys/private.pem
JWT_PUBLIC_KEY_PATH=/app/keys/public.pem
JWT_ACCESS_TOKEN_EXPIRY_MINUTES=60
JWT_REFRESH_TOKEN_EXPIRY_DAYS=7
JWT_ISSUER=identity-service

# Next.js UI
NEXT_PUBLIC_API_URL=http://localhost:6600
```

**Important:** This `.env` file must be added to `.gitignore`. Create a `.env.example` with placeholder values instead.

### Docker Compose Service Summary

| Service | Image | Ports (host:container) | Exposed Externally | Depends On |
| --- | --- | --- | --- | --- |
| `postgresd` | `postgres:16-alpine` | None (internal only) | No | — |
| `mailslurper` | `oryd/mailslurper:latest-smtps` | `4436:4436` (web UI only) | Dev only | — |
| `kratos-migrate` | `oryd/kratos:v1.3.1` | None | No | postgresd |
| `kratos` | `oryd/kratos:v1.3.1` | None (internal only) | No | kratos-migrate |
| `middleware` | Custom (Python 3.12) | `6600:6600` | Yes (via reverse proxy) | kratos, postgresd |
| `ui` | Custom (Node 20) | `3000:3000` | Yes (via reverse proxy) | middleware |

**Note:** PostgreSQL and Kratos ports are not bound to the host. They are only reachable from within the Docker network. In production, the middleware and UI should also sit behind a reverse proxy (Nginx/Traefik) rather than being exposed directly.

---

## 13. Security, Resilience & Failure Modes

### 13.1 Security Architecture

#### Network Segmentation

```text
┌─────────────────────────────────────────────────────────────────────────┐
│                         EXTERNAL NETWORK                                │
│  (Users / Browsers)                                                     │
└──────────────┬──────────────────────────────────────────────────────────┘
               │ HTTPS only (TLS terminated at reverse proxy)
┌──────────────▼──────────────────────────────────────────────────────────┐
│                     DMZ / REVERSE PROXY LAYER                           │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │  Nginx / Traefik                                                │   │
│  │  • TLS termination          • Rate limiting                     │   │
│  │  • Security headers         • IP allowlisting                   │   │
│  │  • Request size limits      • Brute-force protection            │   │
│  └────────┬───────────────────────────────┬────────────────────────┘   │
│           │ :6600 (middleware)             │ :3000 (UI)                 │
└───────────┼───────────────────────────────┼────────────────────────────┘
┌───────────▼───────────────────────────────▼────────────────────────────┐
│                     INTERNAL NETWORK (Docker)                           │
│                                                                         │
│  ┌──────────────────┐  ┌──────────────┐  ┌──────────────┐             │
│  │ FastAPI Middleware│  │  Next.js UI  │  │ Project A-N  │             │
│  │     :6600        │  │    :3000     │  │  :9000-9015  │             │
│  └────────┬─────────┘  └──────────────┘  └──────────────┘             │
│           │                                                             │
│  ┌────────▼─────────┐  ┌──────────────┐                               │
│  │  Ory Kratos      │  │  PostgreSQL  │  ◄── NOT exposed externally   │
│  │  Public: 4433    │  │    :5432     │                               │
│  │  Admin:  4434    │  │              │                               │
│  └──────────────────┘  └──────────────┘                               │
└─────────────────────────────────────────────────────────────────────────┘
```

**Rules:**

- Kratos admin API (4434) — **never exposed** outside Docker network. Only middleware can reach it.
- PostgreSQL (5432) — **never exposed** outside Docker network. No external port binding.
- Kratos public API (4433) — only reachable from middleware and UI containers, not from external.
- External traffic enters **only** through the reverse proxy → middleware (:6600) or UI (:3000).

#### Admin Endpoint Protection

All admin endpoints (`/api/tenants`, `/api/tenants/{id}/members`, `/api/tenants/{id}/service-accounts`) require authentication via JWT with a **super-admin role**:

```python
# middleware/app/middleware/auth.py

SUPER_ADMIN_ROLE = "identity-admin"

def require_admin(request: Request):
    """Dependency that requires identity-admin role in the JWT."""
    auth_header = request.headers.get("Authorization", "")
    if not auth_header.startswith("Bearer "):
        raise HTTPException(401, "Missing Authorization header")

    token = auth_header[7:]
    claims = jwt_service.verify(token)

    # Check for super-admin role (stored in a special "identity-service" project)
    identity_roles = claims.get("tenants", {}).get("identity-service", {}).get("roles", [])
    if SUPER_ADMIN_ROLE not in identity_roles:
        raise HTTPException(403, "Requires identity-admin role")

    return claims

# Apply to admin routers:
router = APIRouter(prefix="/api/tenants", dependencies=[Depends(require_admin)])
```

The identity service itself is registered as a tenant (`identity-service`) with the role `identity-admin`. Bootstrap this during initial setup.

#### JWT Security

| Concern | Implementation |
| --- | --- |
| Signing algorithm | **RS256** (asymmetric). Private key never leaves the middleware container. |
| Token lifetime | **Short-lived: 1 hour** (not 24h). Reduces damage window if a token leaks. |
| Refresh tokens | Separate refresh token (opaque, stored server-side) with **7-day** lifetime. Revocable. |
| Token scope | Always scoped to a single `tenant_id`. Never issue tokens with all tenants embedded. |
| Claims minimization | Only include `sub`, `email`, `tenant_id`, `roles`, `iat`, `exp`, `iss`, `jti`. No sensitive data. |
| Token ID (`jti`) | Every JWT gets a unique `jti` claim for audit logging and optional revocation. |
| Key rotation | Support multiple active public keys (JWKS). Old key kept valid during overlap period. |
| Key storage | Private key mounted as read-only Docker secret. Not in env var, not in git. |

**Revised JWT payload (scoped, minimal):**

```json
{
  "sub": "kratos-identity-uuid",
  "email": "user@example.com",
  "jti": "unique-token-id",
  "iat": 1724544000,
  "exp": 1724547600,
  "iss": "identity-service",
  "tenant_id": "monitoring-api",
  "roles": ["operator", "viewer"],
  "sa": false
}
```

**Why single-project scope?** The original plan embedded all tenant roles into one JWT. This is a security risk — if the token leaks, the attacker has access to every project the user belongs to. Scoping to one tenant limits blast radius.

**Impact on tenant servers:** When a client needs to call multiple project APIs, it requests a separate JWT for each tenant. This is one extra API call at login time per project, but significantly reduces risk.

#### Refresh Token Flow

```text
1. Login → Kratos session
2. POST /api/tokens {tenant_id: "monitoring-api"}
   → Returns: {access_token: "eyJ...", refresh_token: "rt_abc123...", expires_in: 3600}
3. Client stores both tokens
4. Access token expires (1 hour)
5. POST /api/tokens/refresh {refresh_token: "rt_abc123...", tenant_id: "monitoring-api"}
   → Middleware checks: refresh token valid? Kratos session still active? User still has tenant access?
   → Returns: {access_token: "eyJ...(new)", refresh_token: "rt_def456...(rotated)", expires_in: 3600}
6. If refresh fails (session expired, user removed from project) → client must re-login
```

**Refresh token storage (middleware DB):**

```sql
CREATE TABLE refresh_tokens (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    token_hash VARCHAR(255) NOT NULL UNIQUE,   -- bcrypt hash
    user_id UUID NOT NULL,
    tenant_id VARCHAR(63) NOT NULL,
    kratos_session_id VARCHAR(255) NOT NULL,    -- to verify session still valid
    expires_at TIMESTAMPTZ NOT NULL,
    revoked_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_refresh_tokens_user ON refresh_tokens(user_id);
CREATE INDEX idx_refresh_tokens_expires ON refresh_tokens(expires_at);
```

#### Service Account Security

| Concern | Implementation |
| --- | --- |
| API key format | `sa_<tenant_id>_<random_32_bytes_hex>` — prefix makes leaked keys identifiable |
| API key storage | **bcrypt hash** only. Raw key shown once at creation, never stored or retrievable. |
| API key rotation | Rotate endpoint creates a new key and revokes the old one atomically. |
| Rate limiting | Service account auth endpoint rate-limited to 10 req/min per IP. |
| Brute force protection | Lock service account after 5 failed auth attempts. Auto-unlock after 15 min. |
| Scope | Service accounts always scoped to one tenant. Cannot access other projects. |
| Audit | Log every service account authentication with IP, timestamp, tenant_id. |

#### Password & Credential Security

| Concern | Implementation |
| --- | --- |
| Auth method | Passwordless (email code) — no passwords to leak, hash, or brute-force |
| Code delivery | One-time codes via email (6-digit, 10-min expiry) |
| Code brute-force | Kratos limits code attempts (default 5 tries per flow) |
| Email enumeration | Kratos account enumeration mitigation enabled |
| CSRF | Kratos CSRF tokens on all browser flows |
| Cookie security | `Secure`, `HttpOnly`, `SameSite=Lax` on all session cookies |

#### Secrets Management

| Secret | How It's Handled |
| --- | --- |
| Kratos cookie secret | Docker secret / env var. Generated with `openssl rand -hex 32`. Rotatable (list multiple). |
| Kratos cipher secret | Docker secret / env var. Exactly 32 chars. |
| JWT private key | Mounted as read-only file from Docker secret. Never in env var or git. |
| PostgreSQL password | Docker secret / env var. Not hardcoded in `docker-compose.yml`. |
| Service account API keys | bcrypt-hashed in DB. Raw key shown once. |
| `.env` file | **Not committed to git.** Added to `.gitignore`. Use `.env.example` with placeholder values. |

### 13.2 Single Points of Failure (SPOF) Analysis

| Component | SPOF Risk | Mitigation |
| --- | --- | --- |
| **PostgreSQL** | If DB goes down, no new logins, no token issuance, no admin operations | See [13.3 PostgreSQL Resilience](#133-postgresql-resilience) |
| **Ory Kratos** | If Kratos goes down, no new logins or registrations | See [13.4 Kratos Resilience](#134-kratos-resilience) |
| **FastAPI Middleware** | If middleware goes down, no new token issuance, no admin API | See [13.5 Middleware Resilience](#135-middleware-resilience) |
| **JWT Validation** | If identity service is fully down, can existing JWTs still be validated? | **YES** — JWT validation is offline. Project servers only need the public key (cached). Existing tokens continue to work until they expire. |
| **Next.js UI** | If UI goes down, users can't login via browser | Non-critical — API-based login still works. UI is stateless, fast to restart. |
| **MailSlurper** | If email is down, no login codes can be delivered | Replace with reliable SMTP in production (SES, SendGrid). Queue-based delivery. |
| **JWT Private Key** | If key is lost, no new tokens can be issued | Keep encrypted backup. Key rotation procedure documented. |

**Key insight: JWT offline validation is the primary resilience feature.** Even if the entire identity service goes down, all tenant servers continue to function for the lifetime of existing JWTs (1 hour). Users who already have tokens are unaffected. Only new logins and token refreshes fail.

### 13.3 PostgreSQL Resilience

**Dev environment (current):** Single PostgreSQL instance with a Docker volume. Acceptable for dev.

**Production hardening:**

```yaml
# docker-compose.yml additions for PostgreSQL resilience
postgresd:
  image: postgres:16-alpine
  volumes:
    - postgres-data:/var/lib/postgresql/data
  deploy:
    resources:
      limits:
        cpus: '2.0'
        memory: 1G
      reservations:
        cpus: '0.5'
        memory: 256M
    restart_policy:
      condition: on-failure
      delay: 5s
      max_attempts: 10
  healthcheck:
    test: ["CMD-SHELL", "pg_isready -U kratos"]
    interval: 10s
    timeout: 5s
    retries: 5
    start_period: 30s
```

**Backup strategy:**

```bash
# Automated daily backup (add as a Docker service or cron job)
pg_dump -h postgresd -U kratos -d kratos > /backups/kratos_$(date +%Y%m%d).sql
pg_dump -h postgresd -U kratos -d identity_middleware > /backups/middleware_$(date +%Y%m%d).sql
```

**Production options:**

- PostgreSQL streaming replication (primary + standby)
- Use managed PostgreSQL (AWS RDS, GCP Cloud SQL) for automatic failover
- Connection pooling with PgBouncer to handle connection spikes

### 13.4 Kratos Resilience

**Kratos is stateless** — it stores everything in PostgreSQL. This means:

- Multiple Kratos instances can run behind a load balancer
- If one crashes, Docker restarts it automatically
- No data loss on container restart

```yaml
# docker-compose.yml — Kratos with restart and health check
kratos:
  image: oryd/kratos:v1.3.1
  restart: unless-stopped
  healthcheck:
    test: ["CMD", "wget", "--no-verbose", "--tries=1", "--spider", "http://localhost:4433/health/ready"]
    interval: 15s
    timeout: 5s
    retries: 3
    start_period: 10s
  deploy:
    resources:
      limits:
        cpus: '1.0'
        memory: 512M
      reservations:
        cpus: '0.25'
        memory: 128M
```

**Scaling (production):** Run 2+ Kratos replicas behind a load balancer. They share the same PostgreSQL database and are fully interchangeable.

### 13.5 Middleware Resilience

**The middleware is the most critical custom component.** Mitigations:

**Graceful degradation:**

```python
# middleware/app/services/kratos_client.py
# Circuit breaker pattern — if Kratos is temporarily down, fail fast instead of timing out

import httpx
from datetime import datetime, timedelta

class KratosClient:
    def __init__(self, public_url, admin_url):
        self.public_url = public_url
        self.admin_url = admin_url
        self._circuit_open = False
        self._circuit_open_until = None
        self._failure_count = 0
        self._failure_threshold = 5
        self._circuit_timeout = timedelta(seconds=30)

    async def _request(self, method, url, **kwargs):
        # Circuit breaker: if too many failures, fail fast
        if self._circuit_open:
            if datetime.utcnow() < self._circuit_open_until:
                raise HTTPException(503, "Identity service temporarily unavailable")
            self._circuit_open = False
            self._failure_count = 0

        try:
            async with httpx.AsyncClient(timeout=10.0) as client:
                resp = await client.request(method, url, **kwargs)
                self._failure_count = 0  # reset on success
                return resp
        except (httpx.ConnectError, httpx.TimeoutException):
            self._failure_count += 1
            if self._failure_count >= self._failure_threshold:
                self._circuit_open = True
                self._circuit_open_until = datetime.utcnow() + self._circuit_timeout
            raise HTTPException(503, "Identity service unavailable")
```

**Docker restart policy:**

```yaml
middleware:
  restart: unless-stopped
  healthcheck:
    test: ["CMD", "curl", "-f", "http://localhost:6600/health"]
    interval: 15s
    timeout: 5s
    retries: 3
    start_period: 15s
  deploy:
    resources:
      limits:
        cpus: '1.0'
        memory: 512M
```

**Scaling (production):** Run 2+ middleware replicas behind a load balancer. They are stateless (state is in PostgreSQL).

### 13.6 Bottleneck Analysis

| Bottleneck | Risk | Mitigation |
| --- | --- | --- |
| **Token endpoint** (`POST /api/tokens`) | Every login hits this. If 100 users login simultaneously, it must handle it. | Middleware is async (FastAPI/uvicorn). Add multiple workers: `uvicorn --workers 4`. Scale replicas in production. |
| **Service account auth** (`POST /api/tokens/service-auth`) | bcrypt verification is CPU-intensive (~100ms per hash check). Many service accounts authenticating at once could slow down. | Use a worker pool for bcrypt. Cache valid service account sessions (short TTL, 5 min). Rate limit to 10 req/min per API key. |
| **PostgreSQL connections** | Kratos + middleware both use PostgreSQL. Each worker opens connections. 4 workers × 2 services = 8+ connections. | Connection pooling: `max_conns=20&max_idle_conns=4` in DSN. PgBouncer for production. |
| **JWT signing** | RS256 signing is ~1ms per token. Not a bottleneck. | No action needed. |
| **JWT verification** (tenant servers) | RS256 verification is ~0.1ms per token. Fully offline. | No action needed — this is the fastest part of the system. |
| **Email sending** | Kratos sends login codes via SMTP. Slow SMTP server blocks the login flow. | Kratos `--watch-courier` processes email asynchronously in a background goroutine. Use a reliable SMTP provider in production. |
| **Public key fetch** | Project servers fetch the public key at startup. If 15 servers start at once... | Not a bottleneck — it's a single GET of ~450 bytes. Cache the key file locally as fallback. |

### 13.7 Rate Limiting & Brute Force Protection

Kratos has **no built-in rate limiting**. Rate limiting must be applied externally.

**Reverse proxy rate limiting (Nginx):**

```nginx
# Rate limiting zones
limit_req_zone $binary_remote_addr zone=login:10m rate=5r/m;
limit_req_zone $binary_remote_addr zone=register:10m rate=3r/m;
limit_req_zone $binary_remote_addr zone=token:10m rate=30r/m;
limit_req_zone $binary_remote_addr zone=service_auth:10m rate=10r/m;
limit_req_zone $binary_remote_addr zone=admin:10m rate=20r/m;

# Apply to locations
location /api/auth/flows/login {
    limit_req zone=login burst=3 nodelay;
    proxy_pass http://middleware:6600;
}

location /api/auth/flows/registration {
    limit_req zone=register burst=2 nodelay;
    proxy_pass http://middleware:6600;
}

location /api/tokens {
    limit_req zone=token burst=10 nodelay;
    proxy_pass http://middleware:6600;
}

location /api/tokens/service-auth {
    limit_req zone=service_auth burst=5 nodelay;
    proxy_pass http://middleware:6600;
}

location /api/tenants {
    limit_req zone=admin burst=10 nodelay;
    proxy_pass http://middleware:6600;
}
```

**Application-level protections (middleware):**

```python
# middleware/app/middleware/rate_limit.py
# In-memory rate limiter (use Redis in production for multi-instance)

from collections import defaultdict
from datetime import datetime, timedelta

class RateLimiter:
    def __init__(self):
        self._attempts = defaultdict(list)

    def check(self, key: str, max_attempts: int, window_seconds: int) -> bool:
        """Returns True if allowed, False if rate limited."""
        now = datetime.utcnow()
        cutoff = now - timedelta(seconds=window_seconds)
        self._attempts[key] = [t for t in self._attempts[key] if t > cutoff]

        if len(self._attempts[key]) >= max_attempts:
            return False

        self._attempts[key].append(now)
        return True

rate_limiter = RateLimiter()

# Usage in service account auth:
if not rate_limiter.check(f"sa_auth:{tenant_id}:{client_ip}", max_attempts=10, window_seconds=60):
    raise HTTPException(429, "Too many authentication attempts")
```

### 13.8 Audit Logging

All security-relevant events must be logged for forensic analysis:

```python
# middleware/app/services/audit_log.py
import logging
from datetime import datetime

audit_logger = logging.getLogger("audit")

def log_event(event_type: str, actor: str, target: str, details: dict = None):
    audit_logger.info({
        "timestamp": datetime.utcnow().isoformat(),
        "event": event_type,
        "actor": actor,
        "target": target,
        "details": details or {},
    })

# Events to log:
# - user.login_success          (actor=user_id, target=tenant_id)
# - user.login_failure          (actor=email, target=ip_address)
# - token.issued                (actor=user_id, target=tenant_id, jti=token_id)
# - token.refreshed             (actor=user_id, target=tenant_id)
# - token.refresh_denied        (actor=user_id, reason=...)
# - service_account.auth        (actor=sa_id, target=tenant_id)
# - service_account.auth_failed (actor=api_key_prefix, target=tenant_id)
# - service_account.locked      (actor=sa_id, reason=brute_force)
# - project.created             (actor=admin_id, target=tenant_id)
# - project.deactivated         (actor=admin_id, target=tenant_id)
# - membership.added            (actor=admin_id, target=user_id, project=...)
# - membership.removed          (actor=admin_id, target=user_id, project=...)
# - membership.roles_changed    (actor=admin_id, target=user_id, old=..., new=...)
# - key.rotated                 (actor=admin_id, target=key_id)
```

### 13.9 JWT Revocation Strategy

JWTs are stateless — once issued, they can't be "revoked" without a lookup. For a 1-hour token lifetime, this is usually acceptable. But for critical cases (user fired, key compromised):

**Option A: Short-lived tokens (default, recommended)**

- 1-hour access tokens + refresh tokens
- Revoke the refresh token → user can't get new access tokens
- Wait up to 1 hour for existing access tokens to expire
- Acceptable for most internal service scenarios

**Option B: Token denylist (for critical revocations)**

```sql
-- middleware DB
CREATE TABLE revoked_tokens (
    jti UUID PRIMARY KEY,           -- token ID from JWT
    revoked_at TIMESTAMPTZ DEFAULT NOW(),
    reason VARCHAR(255),
    expires_at TIMESTAMPTZ NOT NULL  -- auto-cleanup after token would have expired anyway
);
```

```python
# Project servers can optionally check the denylist
# GET /api/tokens/revoked?since=<timestamp>
# Returns list of revoked jti values
# Project servers cache this list and check on each request
# This is a tradeoff: adds a network dependency but enables instant revocation
```

**Option C: Emergency key rotation**

- Rotate the JWT signing key → all existing tokens immediately become invalid
- Nuclear option — affects all users across all tenants
- Only use for security incidents (key compromise)

### 13.10 Failure Scenarios & Recovery

| Scenario | Impact | Recovery |
| --- | --- | --- |
| **PostgreSQL crashes** | No new logins. No token issuance. Existing JWTs still work (offline validation). | Docker auto-restarts. Data persists in volume. Recovery: < 30 seconds. |
| **Kratos crashes** | No new logins. Token issuance still works if user has valid Kratos session. | Docker auto-restarts. Stateless — no data loss. Recovery: < 10 seconds. |
| **Middleware crashes** | No new tokens. No admin API. All tenant servers continue working with cached JWTs. | Docker auto-restarts. Stateless — no data loss. Recovery: < 10 seconds. |
| **Entire identity service down** | No new logins or tokens. All tenant servers continue working until JWTs expire (1 hour). | Restart Docker Compose. All data in PostgreSQL volume. Full recovery: < 1 minute. |
| **JWT private key compromised** | Attacker can forge tokens for any project. | 1. Rotate JWT key immediately. 2. All existing tokens invalidated. 3. Users must re-login. 4. Investigate how key leaked. |
| **Service account API key leaked** | Attacker can get JWTs for that one tenant with that service account's roles. | 1. Rotate API key: `POST /api/tenants/{id}/service-accounts/{sa_id}/rotate`. 2. Revoke old key's tokens. Blast radius: one tenant, limited roles. |
| **Database corruption** | Full data loss if no backup. | Restore from daily backup. Re-run Kratos migrations. |
| **User removed from project** | User's existing JWT still valid until expiry (up to 1 hour). | Acceptable for 1-hour window. For immediate revocation, add jti to denylist. Refresh token is revoked immediately. |

### 13.11 Dev vs Production Security Matrix

| Setting | Dev (current) | Production |
| --- | --- | --- |
| Kratos `--dev` flag | Yes | **No** |
| `leak_sensitive_values` | `true` | **`false`** |
| Cookie `Secure` | `false` | **`true`** |
| Cookie `SameSite` | `Lax` | **`Lax`** |
| TLS | None | **Required** (reverse proxy) |
| Kratos admin port | Exposed | **Docker-internal only** |
| PostgreSQL port | Exposed (5432) | **Docker-internal only** |
| JWT token lifetime | 1 hour | **1 hour** |
| Refresh token lifetime | 7 days | **7 days** |
| Admin endpoints | No auth (dev convenience) | **Require `identity-admin` JWT** |
| Rate limiting | None | **Nginx + application-level** |
| Audit logging | Console | **Structured JSON → log aggregator** |
| DB backup | None | **Daily automated backup** |
| Secrets | `.env` file | **Docker secrets / vault** |
| Kratos image | Alpine | **Distroless** |
| Container resources | No limits | **CPU + memory limits** |
| CORS origins | `localhost:*` | **Explicit allowlist** |
| Email provider | MailSlurper | **Production SMTP (SES, etc.)** |
| JWT signing key | File on disk | **Docker secret, read-only mount** |
| `.env` in git | Allowed (dev values) | **Never. `.gitignore` enforced.** |

### 13.12 Security Checklist (Implementation Phase)

These must be implemented from the start, even in dev:

- [ ] `.env` added to `.gitignore` — secrets never committed
- [ ] `.env.example` with placeholder values for documentation
- [ ] JWT private key generated per environment — not shared across dev/staging/prod
- [ ] Service account API keys bcrypt-hashed before storage
- [ ] Kratos admin port (4434) not bound to host in `docker-compose.yml`
- [ ] PostgreSQL port not bound to host (remove `ports: - "5432:5432"`)
- [ ] Admin endpoints require `identity-admin` role (not left open)
- [ ] Audit logging for all auth events (login, token issue, membership changes)
- [ ] Refresh tokens hashed in database, rotated on each use
- [ ] CORS origins restricted to known UI and project domains
- [ ] All Pydantic models validate input strictly (no arbitrary dicts)
- [ ] SQL queries use parameterized queries (SQLAlchemy ORM — default safe)
- [ ] Error responses don't leak stack traces or internal details
- [ ] Health endpoints don't expose sensitive config

---

## 14. Future Enhancements

### Phase 5: Additional Auth Methods

- Add password-based authentication as a secondary option
- Add TOTP (MFA) support
- Add social login (Google, GitHub OIDC) for internal SSO

### Phase 6: Advanced RBAC

- Fine-grained permissions per role (not just role names)
- Permission inheritance (admin inherits all operator permissions)
- Resource-level access control (user X can access resource Y in project Z)
- Integration with Ory Keto for Zanzibar-style authorization

### Phase 7: Production Hardening

- Kubernetes deployment with Helm charts
- Horizontal scaling
- Database connection pooling (PgBouncer)
- Monitoring and alerting (Prometheus + Grafana)
- JWKS endpoint (RFC 7517) instead of raw PEM
- JWT key rotation with overlap period

### Phase 8: Developer Experience

- CLI tool for managing projects and memberships
- Auto-generated SDK clients for Go, Node.js, Java
- OpenAPI spec export from FastAPI
- Swagger UI for API exploration
- Integration test harness for tenant servers

---

## Implementation Order Summary

```text
Phase 1 (Core):       docker-compose.yml + kratos.yml + identity schema + key pair
                      ↓
Phase 2 (Middleware):  FastAPI + DB schema + JWT service + project/membership CRUD
                      ↓
Phase 3 (UI):         Next.js login + projects dashboard + admin pages
                      ↓
Phase 4 (Test):       seed projects + smoke tests + e2e JWT validation
                      ↓
Integrate:            Add JWT middleware to each existing tenant server
```

**Estimated files to create:** ~50 files
**Key technologies:** Docker Compose, Ory Kratos, PostgreSQL, Python/FastAPI, PyJWT (RS256), Next.js/React/TypeScript, Nginx (reverse proxy)
