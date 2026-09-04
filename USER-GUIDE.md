# Identity Service — User Guide

A centralized identity service for internal servers, built on **ThunderID**. Provides shared authentication for humans and AI agents with per-tenant RBAC, OAuth2/OIDC token issuance, and offline JWT verification.

---

## Table of Contents

1. [Overview](#overview)
2. [Why AI Agent Identity Matters](#why-ai-agent-identity-matters)
3. [Human Auth vs Agent Auth: A Deep Comparison](#human-auth-vs-agent-auth-a-deep-comparison)
4. [Architecture](#architecture)
5. [Quick Start](#quick-start)
6. [Initial Setup (Phase 1)](#initial-setup-phase-1)
7. [Bootstrap (Phase 2)](#bootstrap-phase-2)
8. [Managing Tenants](#managing-tenants)
9. [Managing Resource Servers and Scopes](#managing-resource-servers-and-scopes)
10. [Managing Roles](#managing-roles)
11. [Managing Users](#managing-users)
12. [AI Agent Identity](#ai-agent-identity)
13. [Token Flows](#token-flows)
14. [Integrating a Tenant Server](#integrating-a-tenant-server)
15. [The CallerIdentity Model](#the-calleridentity-model)
16. [CORS Configuration](#cors-configuration)
17. [Audit Logging](#audit-logging)
18. [Backup and Restore](#backup-and-restore)
19. [Operations Reference](#operations-reference)
20. [Configuration Reference](#configuration-reference)
21. [Security](#security)
22. [Upgrading ThunderID](#upgrading-thunderid)
23. [Project Structure](#project-structure)
24. [Troubleshooting](#troubleshooting)

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
| ------ | ------------- | ----------- | --------- |
| **Human** | People who log in via browser | Authorization code (email OTP, passkey) | `alice@company.com` logging into a dashboard |
| **Autonomous Agent** | AI agents with their own identity | Client credentials (`client_id` + `client_secret`) | A nightly cleanup bot |
| **Delegated Agent** | AI agents acting on behalf of a human | Authorization code + PKCE | An AI assistant investigating alerts for a user |

### Technology Stack

| Component | Technology | Purpose |
| ----------- | ----------- | --------- |
| Identity Provider | ThunderID v1.0.1 | OAuth2/OIDC, user/agent management, token issuance |
| Database | Embedded SQLite | Zero-config persistence (4 database files) |
| Email (dev) | MailSlurper | Captures OTP emails during development |
| Bootstrap | Python 3.12 + httpx | Automated tenant/role/agent provisioning |
| Tenant Auth | Python 3.12 + PyJWT | JWT verification middleware for FastAPI |
| Container Runtime | Docker Compose | Local deployment orchestration |

---

## Why AI Agent Identity Matters

### The Problem: Agents Without Identity

Most organizations today authenticate their AI agents using one of three broken patterns:

**1. Shared API Keys**
A static key is embedded in the agent's configuration. Every agent on the team uses the same key, or one key per service. There is no way to know *which* agent made a request. If the key leaks, every agent is compromised. There is no way to revoke one agent without rotating the key for all of them.

```text
# The dangerous status quo
MONITORING_API_KEY=sk-abc123...   # Who is using this? Which agent? When?
```

**2. Piggybacking on Human Credentials**
An engineer creates a "bot" user account and hardcodes its email and password. The agent authenticates as a human. Audit logs show a person who doesn't exist. The agent has whatever permissions that fake human has — often far too many — and there is no concept of delegation or accountability.

**3. No Authentication at All**
Internal services trust the network boundary. Any process on the internal network can call any API. An agent running in a container can access every service without restriction.

### Why This Is Unacceptable

As AI agents become more autonomous — making decisions, triggering deployments, modifying data, calling other agents — the lack of proper identity creates compounding risks:

| Risk | Description |
| ------ | ------------- |
| **No accountability** | When an agent deletes production data, audit logs show "api-key-1" or a fake bot user email. You cannot trace the action to a specific agent, its owner, or the model that generated the decision. |
| **No least privilege** | Shared keys grant blanket access. An agent that only needs `alerts:read` gets full admin access because that's what the key provides. |
| **No revocation** | If one agent is compromised, you must rotate the shared key, breaking every other agent that uses it. |
| **No delegation chain** | When Agent A asks Agent B to perform a sub-task, there is no cryptographic record of who authorized what. |
| **No distinction** | Downstream services cannot tell whether a request came from a human or an agent. This matters for rate limiting, audit compliance, and security policy. |
| **Credential sprawl** | API keys end up in environment variables, CI configs, chat messages, and git history. There is no lifecycle management. |

### The Solution: First-Class Agent Identity

This identity service treats AI agents as **first-class citizens** in the same identity system as humans. Every agent gets:

- Its own **unique ID** — not a repurposed user account
- Its own **OAuth2 credentials** — standard `client_id` + `client_secret`, managed by the identity provider
- Its own **roles and scopes** — the same RBAC system that governs human access
- Its own **audit trail** — every token issued to an agent is traceable to that specific agent
- Its own **lifecycle** — credentials can be rotated, revoked, or deleted independently
- **Attribution metadata** — which LLM model, provider, team, and function the agent represents

The result is that every API request — whether from a human in a browser or an LLM agent in a container — carries a cryptographically signed token that says exactly who is making the request, what they are allowed to do, and whether they are acting on their own or on behalf of someone else.

### What ThunderID Brings to the Table

ThunderID is not a general-purpose identity provider retrofitted for agents. It was built with **native agent identity** as a core feature:

| Capability | Traditional IdP (Keycloak, Auth0, Okta) | ThunderID |
| ------------ | ---------------------------------------- | ----------- |
| **Agent as first-class entity** | No. Agents are hacked in as "service accounts" or "machine-to-machine apps" with no agent-specific attributes. | Yes. Agents have a dedicated API (`/agents`), dedicated schema (model, provider, function, team), and are distinct from users and service accounts. |
| **Agent metadata** | None. A service account is just a client_id with a name. | Rich attributes: `model`, `modelProvider`, `function`, `team`, and custom fields. You know *what kind* of agent is calling. |
| **Delegated identity (act-on-behalf)** | Requires custom token exchange setup. Most IdPs don't support the `act` claim natively. | Built-in. Delegated agents use standard authorization code + PKCE. The `act` claim is populated automatically. |
| **Agent-to-agent delegation** | Not supported. | Supported via token exchange with nested `act` claims. Agent A can delegate to Agent B with automatic downscoping. |
| **Unified RBAC** | Separate permission models for humans and machines. | Same roles, same scopes, same resource servers. An agent with `monitoring-operator` gets exactly the same permissions as a human with that role. |
| **Deployment simplicity** | Keycloak: Java app + PostgreSQL + Redis. Auth0/Okta: SaaS with vendor lock-in. | Single Go binary with embedded SQLite. One container, zero external dependencies. |
| **Embedded admin UI** | Separate admin console deployment. | Built-in Console (admin) and Gate (login) at the same URL. |
| **MCP Authorization** | Not supported. | Native support for Model Context Protocol authorization (future phase). |

---

## Human Auth vs Agent Auth: A Deep Comparison

### Authentication: How Identity Is Proven

Human and agent authentication differ fundamentally in *who* is present and *how* they prove their identity.

#### Human Authentication Flow

A human authenticates interactively via a browser. The flow involves user interaction at every step:

```text
┌─────────┐                    ┌──────────────┐                  ┌───────────┐
│  Human  │                    │  ThunderID   │                  │  Email    │
│ (Browser)│                    │              │                  │  (SMTP)   │
└────┬────┘                    └──────┬───────┘                  └─────┬─────┘
     │                                │                                │
     │  1. Navigate to Gate           │                                │
     │  ─────────────────────────────►│                                │
     │                                │                                │
     │  2. Enter email address        │                                │
     │  ─────────────────────────────►│                                │
     │                                │  3. Send OTP code              │
     │                                │  ─────────────────────────────►│
     │                                │                                │
     │  4. Check email, copy code     │                                │
     │  ◄─────────────────────────────────────────────────────────────│
     │                                │                                │
     │  5. Submit OTP code            │                                │
     │  ─────────────────────────────►│                                │
     │                                │                                │
     │  6. Receive JWT + refresh token│                                │
     │  ◄─────────────────────────────│                                │
     │                                │                                │
```

**Key characteristics:**

- Requires a **browser** and **user interaction**
- Authentication involves **out-of-band verification** (email OTP, passkey, or social login)
- The OAuth2 grant type is **`authorization_code`**
- A **session** is created in ThunderID, enabling **refresh tokens**
- The user must **consent** to the scopes being requested
- The resulting token has `grant_type: "authorization_code"` and the `sub` claim is the user's UUID

**Human token example:**

```json
{
  "sub": "01a05cc2-1234-5678-9abc-def012345678",
  "aud": "https://monitoring-api.internal",
  "scope": "alerts:read alerts:write dashboards:read",
  "grant_type": "authorization_code",
  "client_id": "monitoring-app",
  "iss": "https://localhost:8090",
  "exp": 1788333291,
  "iat": 1788329691,
  "jti": "unique-token-id"
}
```

#### Autonomous Agent Authentication Flow

An autonomous agent authenticates **programmatically** with no human in the loop. It uses pre-provisioned credentials:

```text
┌───────────────────┐                    ┌──────────────┐
│  Autonomous Agent │                    │  ThunderID   │
│  (Background Job) │                    │              │
└────────┬──────────┘                    └──────┬───────┘
         │                                      │
         │  1. POST /oauth2/token               │
         │     grant_type=client_credentials    │
         │     client_id + client_secret        │
         │     resource=https://api.internal    │
         │     scope=alerts:read alerts:write   │
         │  ────────────────────────────────────►│
         │                                      │
         │                                      │  2. Validate credentials
         │                                      │  3. Check agent's roles & scopes
         │                                      │  4. Intersect requested with allowed
         │                                      │
         │  5. Return JWT access token          │
         │  ◄────────────────────────────────────│
         │                                      │
```

**Key characteristics:**

- **No browser, no human, no interaction** — purely machine-to-machine
- Authentication uses **client_id + client_secret** (pre-provisioned OAuth2 credentials)
- The OAuth2 grant type is **`client_credentials`**
- **No refresh token** — the agent simply requests a new access token when the current one expires
- **No consent screen** — the agent's allowed scopes are pre-configured during bootstrap
- Scopes are **automatically downscoped** — the token contains the intersection of requested scopes and the agent's configured roles
- The resulting token has `grant_type: "client_credentials"` and the `sub` claim is the agent's UUID

**Autonomous agent token example:**

```json
{
  "sub": "01a05bb5-becb-74ac-b5bd-7be2a7a34a60",
  "aud": "https://monitoring-api.internal",
  "scope": "alerts:read alerts:write",
  "grant_type": "client_credentials",
  "client_id": "ooxvbe9uMY2fRpqmifhogw",
  "iss": "https://localhost:8090",
  "exp": 1788333291,
  "iat": 1788329691,
  "jti": "unique-token-id"
}
```

#### Delegated Agent Authentication Flow

A delegated agent acts **on behalf of a human**. The human authorizes the agent, and the agent receives a token that carries both identities:

```text
┌─────────┐        ┌───────────────────┐        ┌──────────────┐
│  Human  │        │  Delegated Agent  │        │  ThunderID   │
│ (Browser)│        │  (AI Assistant)   │        │              │
└────┬────┘        └────────┬──────────┘        └──────┬───────┘
     │                      │                          │
     │  1. User triggers    │                          │
     │     agent action     │                          │
     │  ───────────────────►│                          │
     │                      │                          │
     │                      │  2. Redirect user to     │
     │                      │     /oauth2/authorize    │
     │  ◄───────────────────│     (PKCE challenge)     │
     │                      │                          │
     │  3. User logs in     │                          │
     │     and consents     │                          │
     │  ──────────────────────────────────────────────►│
     │                      │                          │
     │  4. Redirect with    │                          │
     │     auth code        │                          │
     │  ───────────────────►│                          │
     │                      │                          │
     │                      │  5. Exchange code for    │
     │                      │     token (PKCE verify)  │
     │                      │  ───────────────────────►│
     │                      │                          │
     │                      │  6. Receive JWT with     │
     │                      │     sub=user, act=agent  │
     │                      │  ◄───────────────────────│
     │                      │                          │
```

**Key characteristics:**

- **Combines both identities** — the human's identity is the subject, the agent is the actor
- Uses **authorization_code + PKCE** — the same flow as human login, but initiated by the agent
- PKCE (Proof Key for Code Exchange) prevents authorization code interception attacks
- The token's `sub` is the **user's ID**, and the `act` claim contains the **agent's ID**
- The agent can only access scopes the **user has consented to** and that the **agent is configured for** (intersection of both)
- The downstream API can see *who* authorized the action and *which agent* performed it

**Delegated agent token example:**

```json
{
  "sub": "01a05cc2-1234-5678-9abc-def012345678",
  "act": {
    "sub": "01a05bb5-becb-74ac-b5bd-7be2a7a34a60",
    "iss": "https://localhost:8090"
  },
  "aud": "https://monitoring-api.internal",
  "scope": "alerts:read dashboards:read",
  "grant_type": "authorization_code",
  "client_id": "monitoring-assistant-client-id",
  "iss": "https://localhost:8090",
  "exp": 1788333291,
  "iat": 1788329691,
  "jti": "unique-token-id"
}
```

### Side-by-Side Comparison

| Dimension | Human | Autonomous Agent | Delegated Agent |
| ----------- | ------- | ----------------- | ----------------- |
| **Who authenticates** | A person via browser | A machine process | An agent, authorized by a person |
| **OAuth2 grant** | `authorization_code` | `client_credentials` | `authorization_code` + PKCE |
| **Credentials** | Email + OTP / passkey | `client_id` + `client_secret` | `client_id` + `client_secret` + user consent |
| **Interaction** | Interactive (browser) | Non-interactive (API call) | Interactive (user consents), then non-interactive |
| **Session** | Yes (refresh token) | No (request new token on expiry) | Yes (refresh token, tied to user session) |
| **Token `sub`** | User UUID | Agent UUID | User UUID |
| **Token `act`** | *(absent)* | *(absent)* | `{sub: agent-uuid}` |
| **Token `grant_type`** | `authorization_code` | `client_credentials` | `authorization_code` |
| **subject_type** (inferred) | `"user"` | `"agent"` | `"user"` (with `act` claim) |
| **Scope source** | User's roles + consent | Agent's roles (automatic) | Intersection of user's roles, agent's config, and consent |
| **Consent** | Explicit (consent screen) | Implicit (pre-configured) | Explicit (user consents to agent's scope request) |
| **Credential rotation** | User changes password | Regenerate client_secret via API/console | Regenerate client_secret |
| **Revocation** | Revoke session/token | Delete agent or regenerate secret | Revoke user's consent or agent's credentials |
| **Typical lifetime** | Until user logs out | 1 hour (re-request on expiry) | Until user revokes consent |
| **Audit trail** | `sub=user-id` | `sub=agent-id, client_id=agent-client` | `sub=user-id, act.sub=agent-id` |

### How the Tenant Server Tells Them Apart

When a request arrives at a tenant server, the JWT middleware decodes the token and creates a `CallerIdentity` object. The server can then make decisions based on the caller type:

```python
@app.get("/alerts")
@require_scope("alerts:read")
async def get_alerts(request: Request):
    caller = request.state.caller

    if caller.is_agent and not caller.is_delegated:
        # Autonomous agent: maybe rate-limit more aggressively,
        # or return machine-optimized response format
        log.info(f"Agent {caller.subject} fetching alerts")
        return {"alerts": alerts, "format": "compact"}

    elif caller.is_delegated:
        # Agent acting on behalf of a human: record both identities,
        # apply the human's preferences
        log.info(f"Agent {caller.acting_agent} acting for user {caller.subject}")
        return {"alerts": alerts, "on_behalf_of": caller.subject}

    elif caller.is_human:
        # Regular human request: full response with UI metadata
        log.info(f"User {caller.subject} fetching alerts")
        return {"alerts": alerts, "format": "full", "dashboard_url": "..."}
```

### The Unified RBAC Model

A critical design decision: **humans and agents share the same RBAC system**. This means:

- A role like `monitoring-operator` grants the same scopes (`alerts:read`, `alerts:write`, `dashboards:read`) regardless of whether it's assigned to a person or an agent
- Roles are defined once per tenant and assigned to any identity type
- When you add a new scope to a role, every human and agent with that role automatically gets it
- There is no separate "machine permissions" system to maintain

```text
                    ┌──────────────────┐
                    │  monitoring-api  │  (Tenant)
                    └────────┬─────────┘
                             │
              ┌──────────────┼──────────────┐
              ▼              ▼              ▼
     ┌────────────┐  ┌──────────────┐  ┌──────────────┐
     │  monitoring │  │  monitoring  │  │  monitoring  │
     │  -admin     │  │  -operator   │  │  -viewer     │  (Roles)
     └──────┬─────┘  └──────┬───────┘  └──────┬───────┘
            │               │                 │
     ┌──────┴─────┐  ┌──────┴───────┐  ┌──────┴───────┐
     │  All 6     │  │  alerts:read │  │  alerts:read │
     │  scopes    │  │  alerts:write│  │  dashboards: │  (Scopes)
     │            │  │  dashboards: │  │  read        │
     │            │  │  read        │  │              │
     └────────────┘  └──────────────┘  └──────────────┘
            │               │                 │
     Assigned to:    Assigned to:      Assigned to:
     • sysadmin@...  • alice@...       • bob@...
                     • alert-cleanup
                       -agent
```

In this diagram, `alice@company.com` and `alert-cleanup-agent` have the exact same permissions. The difference is only in how they authenticate and how they are identified in tokens and audit logs.

### Security Implications

#### Principle of Least Privilege

With first-class agent identity, every agent gets **only the scopes it needs**:

```yaml
# The alert-cleanup-agent can ONLY read and write alerts.
# It cannot delete alerts, read dashboards, or manage settings.
agents:
  - name: "alert-cleanup-agent"
    scopes:
      - "alerts:read"    # Needed to find expired alerts
      - "alerts:write"   # Needed to update/archive them
      # alerts:delete — NOT granted
      # dashboards:read — NOT granted
      # settings:manage — NOT granted
```

Even if the agent requests broader scopes in its token request, ThunderID automatically **downscopes** the token to the intersection of requested and allowed scopes.

#### Credential Isolation

Each agent has **independent credentials**. Compromising one agent does not compromise others:

```text
Agent A: client_id=abc, client_secret=secret1 → Only monitoring scopes
Agent B: client_id=def, client_secret=secret2 → Only pipeline scopes
Agent C: client_id=ghi, client_secret=secret3 → Only deployment scopes

# Rotate Agent B's secret without touching A or C:
# → Agent B gets a new client_secret
# → Agents A and C are unaffected
```

#### Full Audit Trail

Every request is traceable to a specific identity:

```json
// Human request audit log
{"event": "auth_allowed", "subject": "01a05cc2-...", "subject_type": "user",
 "scopes": ["alerts:read"], "client_id": "monitoring-app"}

// Autonomous agent audit log
{"event": "auth_allowed", "subject": "01a05bb5-...", "subject_type": "agent",
 "scopes": ["alerts:read", "alerts:write"], "client_id": "ooxvbe9uMY2f..."}

// Delegated agent audit log
{"event": "auth_allowed", "subject": "01a05cc2-...", "subject_type": "user",
 "is_delegated": true, "acting_agent": "01a05bb5-...",
 "scopes": ["alerts:read"]}
```

#### Cross-Tenant Isolation

Tokens are audience-scoped to a single resource server. An agent with access to `monitoring-api` cannot use its token at `data-pipeline`:

```text
alert-cleanup-agent token:
  aud: "https://monitoring-api.internal"   ← Only valid here
  scope: "alerts:read alerts:write"

Pipeline API middleware:
  Expected audience: "https://data-pipeline.internal"
  → REJECT: audience mismatch (401)
```

This limits the blast radius if an agent token is compromised — it can only affect one tenant's API.

---

## Architecture

```text
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

```text
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

```text
NAME                     IMAGE                                  STATUS
auth-thunderid-1         ghcr.io/thunder-id/thunderid:1.0.1     Up 2 minutes (healthy)
auth-mailslurper-1       oryd/mailslurper:latest-smtps           Up 2 minutes

ThunderID is healthy
```

### Service Endpoints

| Service | URL | Purpose |
| --------- | ----- | --------- |
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

```text
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
| ------ | ------------- | ------------- |
| `*-admin` | All scopes | Service owners, SREs |
| `*-operator` | Read + write (no delete/manage) | Day-to-day operators |
| `*-viewer` | Read only | Auditors, stakeholders |

### Current Roles (9 total)

| Tenant | Admin | Operator | Viewer |
| -------- | ------- | ---------- | -------- |
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

AI agents are **first-class identities** in this system — not repurposed service accounts or hacked-in "bot users." Each agent has its own UUID, credentials, metadata, and audit trail. This section covers everything you need to register, configure, and operate agents.

### Agent Types

| Type | Grant Type | Use Case | Example |
| ------ | ----------- | ---------- | --------- |
| **Autonomous** | `client_credentials` | Agents that act on their own, with no human in the loop | Nightly cleanup bot, pipeline scheduler, data ingestion agent |
| **Delegated** | `authorization_code` + PKCE | Agents acting on behalf of a specific human user | AI assistant, copilot, human-in-the-loop workflow agent |

**When to use autonomous mode:**

- The agent runs unattended (cron jobs, event-driven triggers, background workers)
- The agent's actions are attributable to the agent itself, not to any particular user
- The agent needs a fixed set of permissions that don't change per-request

**When to use delegated mode:**

- The agent acts on behalf of a specific user (e.g., "investigate this alert for me")
- The agent should only have permissions the user has consented to
- Audit logs need to show both the user (who authorized) and the agent (who acted)
- The agent's scope should be bounded by the user's own scope (no privilege escalation)

### Agent Lifecycle

```text
1. REGISTER     bootstrap.py creates the agent in ThunderID
                 → Agent ID, Client ID, Client Secret generated
                 → Credentials saved to agent-secrets.json

2. CONFIGURE    Agent is assigned roles and scopes via bootstrap config
                 → Same RBAC as human users

3. AUTHENTICATE Agent requests tokens from ThunderID
                 → client_credentials for autonomous
                 → authorization_code + PKCE for delegated

4. OPERATE      Agent calls tenant APIs with JWT tokens
                 → Tokens are verified offline via JWKS
                 → Scopes are enforced per-endpoint

5. ROTATE       Regenerate client_secret via ThunderID API/Console
                 → Old secret is immediately invalidated
                 → Agent receives new secret, no other agents affected

6. REVOKE       Delete the agent or regenerate its secret
                 → All future token requests fail
                 → Existing tokens remain valid until expiry (JWKS trade-off)
```

### Agent Attributes (Metadata)

Every agent can carry structured metadata that describes what kind of agent it is:

```yaml
attributes:
  model: "gpt-4"              # Which LLM model powers this agent
  modelProvider: "openai"      # Which provider (openai, anthropic, etc.)
  function: "task-automation"  # What function the agent serves
  team: "platform"             # Which team owns this agent
```

This metadata is stored in ThunderID and queryable via the management API. It enables:
- **Inventory management** — know which agents exist, what models they use, who owns them
- **Policy decisions** — e.g., only allow `claude-*` models to access certain APIs
- **Incident response** — when something goes wrong, quickly identify the agent's model and owner

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

**Step 1.** Add an entry to `bootstrap/config/agents.yaml`:

```yaml
  - name: "my-new-agent"
    tenant: "monitoring-api"           # Which tenant this agent belongs to
    type: "default"
    mode: "autonomous"                 # or "delegated"
    description: "Does something useful"
    attributes:
      model: "gpt-4o"
      modelProvider: "openai"
      function: "data-analysis"
    roles:
      - "monitoring-viewer"            # Pre-existing role in this tenant
    scopes:
      - "alerts:read"                  # Must be a subset of the role's scopes
      - "dashboards:read"
```

**Step 2.** Run bootstrap (idempotent — existing agents are skipped):

```bash
ADMIN_PASSWORD=<pw> make bootstrap
```

**Step 3.** Retrieve the new agent's credentials from `agent-secrets.json`:

```bash
python3 -c "
import json
secrets = json.load(open('bootstrap/config/agent-secrets.json'))
agent = secrets['my-new-agent']
print(f'Agent ID:      {agent[\"agentId\"]}')
print(f'Client ID:     {agent[\"clientId\"]}')
print(f'Client Secret: {agent[\"clientSecret\"]}')
"
```

**Step 4.** Store the credentials securely in your agent's runtime environment (environment variable, secrets manager, etc.). Never commit them to git.

### Scope Enforcement and Downscoping

When an agent requests a token, ThunderID computes the **intersection** of three sets:

```text
Granted scopes = (Agent's role scopes) ∩ (Resource server scopes) ∩ (Requested scopes)
```

This means:
- An agent cannot request scopes beyond what its roles allow
- An agent cannot request scopes that the resource server doesn't define
- If the agent requests `alerts:delete` but its role only grants `alerts:read` and `alerts:write`, the resulting token will NOT contain `alerts:delete`

Example:

```text
Agent role: monitoring-operator
  → Grants: alerts:read, alerts:write, dashboards:read

Agent requests: scope=alerts:read alerts:write alerts:delete dashboards:read

Token receives: scope=alerts:read alerts:write dashboards:read
  → alerts:delete was silently removed (not in role)
```

This automatic downscoping is verified by test 3.8 in the test suite.

### Credential Rotation

To rotate an agent's client_secret without downtime:

1. Generate a new secret via ThunderID Console or API
2. Update the agent's runtime configuration with the new secret
3. The old secret is immediately invalidated
4. Other agents are unaffected

For a full re-provision, delete the `agent-secrets.json` and re-run `make bootstrap`. New credentials will be generated for any agents not found in the secrets file.

---

## Token Flows

This section details every token flow supported by the system, with full request/response examples.

### Flow 1: Autonomous Agent Token (Client Credentials)

```text
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

```text
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

### Flow 3: Delegated Agent Token (Authorization Code + PKCE)

This flow is used when an agent needs to act on behalf of a specific user. The user must consent.

```bash
# Step 1: Agent generates a PKCE code verifier and challenge
CODE_VERIFIER=$(python3 -c "import secrets; print(secrets.token_urlsafe(64))")
CODE_CHALLENGE=$(echo -n "$CODE_VERIFIER" | openssl dgst -sha256 -binary | base64 -w0 | tr '+/' '-_' | tr -d '=')

# Step 2: Agent redirects the user's browser to ThunderID's authorize endpoint
# The user will see a login screen and then a consent screen.
echo "Open this URL in a browser:"
echo "https://localhost:8090/oauth2/authorize?\
response_type=code&\
client_id=$CLIENT_ID&\
redirect_uri=http://localhost:3000/callback&\
scope=alerts:read dashboards:read&\
resource=https://monitoring-api.internal&\
code_challenge=$CODE_CHALLENGE&\
code_challenge_method=S256"

# Step 3: After the user logs in and consents, ThunderID redirects to the
# callback URL with an authorization code:
#   http://localhost:3000/callback?code=AUTH_CODE_HERE

# Step 4: Agent exchanges the authorization code for a token
curl -X POST https://localhost:8090/oauth2/token \
  -u "$CLIENT_ID:$CLIENT_SECRET" \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -d "grant_type=authorization_code" \
  -d "code=$AUTH_CODE" \
  -d "redirect_uri=http://localhost:3000/callback" \
  -d "code_verifier=$CODE_VERIFIER" \
  --insecure
```

The resulting token carries both identities:
```json
{
  "sub": "01a05cc2-...",
  "act": {"sub": "01a05bb5-...", "iss": "https://localhost:8090"},
  "aud": "https://monitoring-api.internal",
  "scope": "alerts:read dashboards:read",
  "grant_type": "authorization_code"
}
```

- `sub` = the **user** who authorized the action
- `act.sub` = the **agent** that is performing the action
- Downstream APIs can see both and make policy decisions accordingly

### Flow 4: Agent-to-Agent Delegation (Token Exchange)

When Agent A needs Agent B to perform a sub-task, it uses OAuth2 token exchange to create a delegation chain:

```bash
# Agent A has its own token and wants Agent B to act with downscoped permissions
curl -X POST https://localhost:8090/oauth2/token \
  -u "$AGENT_B_CLIENT_ID:$AGENT_B_CLIENT_SECRET" \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -d "grant_type=urn:ietf:params:oauth:grant-type:token-exchange" \
  -d "subject_token=$AGENT_A_TOKEN" \
  -d "subject_token_type=urn:ietf:params:oauth:token-type:access_token" \
  -d "scope=alerts:read" \
  --insecure
```

The resulting token has nested `act` claims:
```json
{
  "sub": "original-subject-id",
  "act": {
    "sub": "agent-b-id",
    "act": {
      "sub": "agent-a-id"
    }
  },
  "scope": "alerts:read"
}
```

Token exchange enforces **strict downscoping** — the new token can never have more scopes than the original. This prevents privilege escalation in agent delegation chains.

### Flow 5: Token Revocation

```bash
# Revoke a token
curl -X POST https://localhost:8090/oauth2/revoke \
  -u "$CLIENT_ID:$CLIENT_SECRET" \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -d "token=$ACCESS_TOKEN&token_type_hint=access_token" \
  --insecure
```

**Important:** Revoked tokens are immediately invalid for online checks (introspection) but remain cryptographically valid for offline JWKS verification until they expire. This is a known trade-off of offline JWT verification.

### Flow 6: Token Introspection

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

### Flow 7: Offline vs Online Verification (The Revocation Trade-Off)

A critical architectural decision in this system is **offline JWT verification via JWKS**. Understanding the trade-off is essential.

**Offline verification (what tenant servers do):**
```text
Tenant server fetches JWKS (public keys) once, caches them.
Every incoming JWT is verified locally using the cached keys.
No call to ThunderID is needed per-request.

Pros:  Zero latency added, no SPOF, works even if ThunderID is down
Cons:  Cannot detect token revocation until the token expires
```

**Online verification (introspection):**
```text
Tenant server calls ThunderID's /oauth2/introspect for each token.
ThunderID checks its revocation list and responds active/inactive.

Pros:  Detects revocation immediately
Cons:  Adds latency per-request, ThunderID becomes a SPOF
```

**This system uses offline verification by default.** If you need real-time revocation detection for sensitive operations, you can add an introspection check for specific endpoints:

```python
@app.delete("/critical-resource/{id}")
@require_scope("resource:delete")
async def delete_critical(request: Request, id: str):
    caller = request.state.caller
    # For destructive operations, verify the token is not revoked
    if not await introspect_token(request.headers["Authorization"][7:]):
        raise HTTPException(401, "Token has been revoked")
    return {"deleted": id}
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
| ---------- | ----------- | -------- |
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
| ------- | ------ | ------------ |
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
| ------- | ------ | ------------- |
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
| ------- | ------ | ------------- |
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
```text
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
| --------- | ------------- |
| `make setup` | Start ThunderID and MailSlurper from scratch |
| `make build-toolbox` | Build the toolbox container |
| `make get-secret` | Print the Direct Auth Secret |
| `ADMIN_PASSWORD=<pw> make bootstrap` | Create tenants, resource servers, roles, agents |
| `ADMIN_PASSWORD=<pw> make seed` | Create seed users and assign roles |
| `ADMIN_PASSWORD=<pw> make test` | Run Phases 1-5 test suite |
| `ADMIN_PASSWORD=<pw> make test-phase{N}` | Run a specific phase's tests |
| `make backup` | Create a backup |
| `make restore FILE=<path>` | Restore from a backup |
| `ADMIN_PASSWORD=<pw> make upgrade VERSION=X.Y.Z` | Upgrade ThunderID to a new version |
| `ADMIN_PASSWORD=<pw> make upgrade-check VERSION=X.Y.Z` | Pre-flight check (no changes) |
| `make upgrade-rollback` | Rollback the last upgrade |
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
| ---------- | --------- | ------------- |
| `ADMIN_USERNAME` | `admin` | ThunderID admin username |
| `ADMIN_PASSWORD` | *(required)* | ThunderID admin password (from setup) |

### Docker Compose Services

| Service | Image | Ports | Purpose |
| --------- | ------- | ------- | --------- |
| `thunderid-setup` | `thunderid:1.0.1` | *(none)* | One-shot: generates keys and secrets |
| `thunderid` | `thunderid:1.0.1` | `8090` | Identity provider (OAuth2/OIDC) |
| `mailslurper` | `oryd/mailslurper` | `4436`, `1025` | Dev email capture |
| `monitoring-api` | *(local build)* | `9100→9000` | Reference tenant server |
| `toolbox` | *(local build)* | *(none)* | Bootstrap scripts and tests |

### Tenant Server Environment Variables

| Variable | Default | Description |
| ---------- | --------- | ------------- |
| `THUNDERID_URL` | `https://localhost:8090` | ThunderID base URL |
| `RESOURCE_ID` | `https://monitoring-api.internal` | This server's resource identifier |
| `JWKS_URL` | `${THUNDERID_URL}/oauth2/jwks` | JWKS endpoint URL |
| `JWKS_VERIFY_SSL` | `true` | Set to `false` for self-signed certs |
| `SERVICE_NAME` | `monitoring-api` | Service name in audit logs |
| `CORS_ORIGINS` | `https://localhost:3000` | Comma-separated allowed CORS origins |

### ThunderID Data Storage

| Volume | Path in Container | Contents |
| -------- | ------------------ | ---------- |
| `thunderid-db` | `/opt/thunderid/database/` | 4 SQLite databases |
| `thunderid-certs` | `/opt/thunderid/config/certs/` | TLS certs, JWT signing keys, crypto key |
| `thunderid-secrets` | `/opt/thunderid/config/secrets/` | Direct Auth Secret |

---

## Security

### What's Protected

| Item | How | Where |
| ------ | ----- | ------- |
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
| ------ | -------------- | ------------ |
| TLS | Self-signed (auto-generated) | Proper CA-signed certificates |
| Email | MailSlurper | Real SMTP provider |
| Database | Embedded SQLite | PostgreSQL (see master-plan.md Section 18.3) |
| CORS | `https://localhost:3000` | Actual frontend origin(s) |
| Admin access | Open | Restrict via reverse proxy / VPN |
| Backups | Manual (`make backup`) | Automated daily cron job |
| Monitoring | None | Prometheus + Grafana |

---

## Upgrading ThunderID

This section covers how to upgrade ThunderID when a new version is released, what risks are involved, and how to roll back if something goes wrong.

### Automated Upgrade (Recommended)

The upgrade process is fully automated via `scripts/upgrade.sh`. It handles backup, image swap, health checks, bootstrap verification, test suite, and automatic rollback state.

**Quick reference:**

```bash
# Pre-flight check (read-only — no changes)
ADMIN_PASSWORD=<pw> make upgrade-check VERSION=1.1.0

# Full upgrade (backup → swap → verify → test)
ADMIN_PASSWORD=<pw> make upgrade VERSION=1.1.0

# Rollback if something goes wrong
make upgrade-rollback
```

**What the script does (8 steps):**

1. Pulls the new image (fails fast if version doesn't exist)
2. Creates a full backup (`scripts/backup-db.sh`)
3. Saves rollback state (old version + backup path)
4. Updates image tags in `docker-compose.yml` (2 lines)
5. Restarts ThunderID, waits for healthy
6. Verifies OIDC discovery and JWKS endpoints
7. Re-runs `bootstrap.py` and `seed_users.py` (tests management API compatibility)
8. Runs the full test suite (Phases 1-7)

If any step fails, the script stops and prints rollback instructions. Run `make upgrade-rollback` to revert to the previous version and restore the backup.

**Environment variables:**

| Variable | Required | Description |
| -------- | -------- | ----------- |
| `ADMIN_PASSWORD` | Yes | Admin password for bootstrap/test verification |
| `VERSION` | Yes | Target ThunderID version (e.g., `1.1.0`) |
| `SKIP_TESTS` | No | Set to `true` to skip the test suite after upgrade |

### Upgrade Difficulty: Low to Medium

The system is designed to make upgrades straightforward:

| Factor | Impact | Why |
| ------ | ------ | --- |
| **Docker image swap** | Trivial | Only 2 lines to change in `docker-compose.yml` |
| **OAuth2/OIDC endpoints** | Very low risk | These are industry standards (`/oauth2/token`, `/oauth2/jwks`, etc.) — unlikely to break between versions |
| **Management API** | Medium risk | ThunderID-specific endpoints (`/agents`, `/roles`, `/import`) could change — check release notes |
| **Config format** | Medium risk | `deployment.yaml` keys could be added or renamed |
| **Database schema** | Low risk | ThunderID handles its own migrations on startup |
| **Tenant server middleware** | No risk | Uses only standard JWKS/JWT — completely decoupled from ThunderID version |

### What Depends on the ThunderID Version

Understanding the coupling surface helps you assess upgrade risk:

**Standard OAuth2/OIDC (version-independent):**

These endpoints follow RFCs and will not break between ThunderID versions:

| Endpoint | Used By | Standard |
| -------- | ------- | -------- |
| `GET /.well-known/openid-configuration` | Test scripts, OIDC clients | RFC 8414 |
| `GET /oauth2/jwks` | `tenant-server/auth.py` (JWKS verification) | RFC 7517 |
| `POST /oauth2/token` | Agent token requests, bootstrap auth | RFC 6749 |
| `POST /oauth2/introspect` | Test scripts (online verification) | RFC 7662 |
| `POST /oauth2/revoke` | Test scripts (revocation) | RFC 7009 |
| `GET /oauth2/authorize` | `bootstrap/auth.py` (admin login flow) | RFC 6749 |

**ThunderID-specific APIs (check release notes on upgrade):**

These are proprietary to ThunderID and could change:

| Endpoint | Used By | Purpose |
| -------- | ------- | ------- |
| `POST /import` | `bootstrap/bootstrap.py`, `seed_users.py` | Bulk create tenants, resource servers, roles, users |
| `GET /agents`, `POST /agents` | `bootstrap/bootstrap.py` | List and create AI agents |
| `GET /roles` | `bootstrap/bootstrap.py`, `seed_users.py` | List roles for assignment |
| `POST /roles/{id}/assignments/add` | `bootstrap/bootstrap.py`, `seed_users.py` | Assign roles to agents/users |
| `GET /resource-servers/{id}/resources` | `bootstrap/bootstrap.py` | List resources under a resource server |
| `POST /resource-servers/{id}/resources/{rid}/actions` | `bootstrap/bootstrap.py` | Create scope actions |
| `GET /users`, `GET /users/{id}` | `seed_users.py`, test scripts | List and inspect users |
| `POST /oauth2/auth/callback` | `bootstrap/auth.py` | Exchange login assertion for auth code |

**Configuration files (review on upgrade):**

| File | Risk | What to check |
| ---- | ---- | ------------- |
| `thunderid/deployment.yaml` | Medium | New required config keys, renamed fields, deprecated options |
| `docker-compose.yml` (setup command) | Low | `./setup.sh --verbose` interface changes |
| Docker volume paths | Low | Database, cert, and secret directory locations |

### Step-by-Step Upgrade Procedure (Manual Reference)

> **Note:** The steps below are automated by `make upgrade VERSION=X.Y.Z`.
> This section is a reference for understanding what happens under the hood,
> or for cases where you need to perform a partial upgrade manually.

#### Pre-Upgrade

**Step 1. Read the release notes**

Before upgrading, check the ThunderID release notes for:

- Breaking API changes (especially `/import`, `/agents`, `/roles` endpoints)
- New required configuration keys in `deployment.yaml`
- Database migration notes
- Deprecated features

```bash
# Check the current version
docker inspect auth-thunderid-1 --format '{{.Config.Image}}'
# → ghcr.io/thunder-id/thunderid:1.0.1
```

**Step 2. Create a full backup**

Always backup before upgrading. This is your rollback safety net.

```bash
make backup
# → backups/thunderid_YYYYMMDD_HHMMSS.tar.gz

# Verify the backup is valid
ls -lh backups/thunderid_*.tar.gz | tail -1
```

**Step 3. Record the current state**

```bash
# Save current test results as a baseline
ADMIN_PASSWORD=<pw> make test 2>&1 | tee pre-upgrade-test-results.txt
ADMIN_PASSWORD=<pw> make test-phase6 2>&1 | tee -a pre-upgrade-test-results.txt
make test-phase7 2>&1 | tee -a pre-upgrade-test-results.txt
```

#### Performing the Upgrade

**Step 4. Update the image tag**

Edit `docker-compose.yml` and change both ThunderID image references:

```yaml
# Before
thunderid-setup:
  image: ghcr.io/thunder-id/thunderid:1.0.1   # ← old version

thunderid:
  image: ghcr.io/thunder-id/thunderid:1.0.1   # ← old version

# After
thunderid-setup:
  image: ghcr.io/thunder-id/thunderid:X.Y.Z   # ← new version

thunderid:
  image: ghcr.io/thunder-id/thunderid:X.Y.Z   # ← new version
```

Both lines must have the same version. There are exactly 2 lines to change.

**Step 5. Pull the new image**

```bash
docker compose pull thunderid-setup thunderid
```

**Step 6. Review deployment.yaml for new config keys**

Compare your `thunderid/deployment.yaml` against the new version's documentation. Add any new required keys. Our config is minimal (12 keys), so this is usually a quick check.

**Step 7. Restart ThunderID with the new version**

```bash
# Stop the old version
docker compose stop thunderid monitoring-api

# Start the new version (thunderid-setup runs first, handles any migrations)
docker compose up -d thunderid

# Wait for it to be healthy
make status
```

ThunderID's `setup.sh` runs automatically on start and handles database migrations. Watch the logs for migration output:

```bash
docker compose logs thunderid-setup | tail -20
docker compose logs thunderid | head -30
```

**Step 8. Verify basic functionality**

```bash
# Health check
curl -sf --insecure https://localhost:8090/.well-known/openid-configuration | python3 -m json.tool

# JWKS endpoint
curl -sf --insecure https://localhost:8090/oauth2/jwks | python3 -m json.tool
```

**Step 9. Re-run bootstrap (idempotent)**

This verifies the management API is still compatible:

```bash
ADMIN_PASSWORD=<pw> make bootstrap
ADMIN_PASSWORD=<pw> make seed
```

If bootstrap fails, the management API has changed. Check error messages against the release notes.

**Step 10. Start tenant servers and run the full test suite**

```bash
docker compose up -d monitoring-api

# Wait for health
sleep 5 && curl -sf http://localhost:9100/health

# Run all tests
ADMIN_PASSWORD=<pw> make test
ADMIN_PASSWORD=<pw> make test-phase6
make test-phase7
```

**Step 11. Update the version assertion in test-phase7.sh**

Test 7.11 checks that the image is pinned. Update it to the new version:

```bash
# In scripts/test-phase7.sh, find and update the version check:
sed -i "s/thunderid:1.0.1/thunderid:X.Y.Z/g" scripts/test-phase7.sh
```

#### Post-Upgrade

**Step 12. Commit the version bump**

```bash
git add docker-compose.yml scripts/test-phase7.sh
git commit -m "Upgrade ThunderID from v1.0.1 to vX.Y.Z"
```

### Rollback Procedure

If the upgrade fails at any step, the fastest way to roll back is:

```bash
make upgrade-rollback
```

This restores the old image tag, reverts the test assertion, and restores data from the pre-upgrade backup (if the database was modified).

**Manual rollback (if the automated rollback state is unavailable):**

```bash
# 1. Stop the new version
docker compose stop thunderid

# 2. Revert docker-compose.yml to the old image tag
#    (git checkout or manual edit)
git checkout docker-compose.yml

# 3. Start the old version
docker compose up -d thunderid

# 4. Wait for healthy
make status
```

**Full rollback (restore from backup):**

If the database schema was migrated and is no longer compatible with the old version:

```bash
# 1. Revert docker-compose.yml to the old image tag
git checkout docker-compose.yml

# 2. Restore the pre-upgrade backup
make restore FILE=backups/thunderid_YYYYMMDD_HHMMSS.tar.gz

# 3. Verify everything works
make status
ADMIN_PASSWORD=<pw> make test
```

### What Can Go Wrong

| Scenario | Symptom | Fix |
| -------- | ------- | --- |
| **Management API changed** | `bootstrap.py` fails with 400/404 errors | Check release notes, update API calls in `bootstrap.py` |
| **Config format changed** | ThunderID won't start, logs show config errors | Compare `deployment.yaml` against new docs, add/rename keys |
| **Database migration failed** | ThunderID crashes on startup | Restore from backup, report to ThunderID maintainers |
| **JWKS key format changed** | Tenant servers return 401 on all requests | Restart tenant servers to clear JWKS cache |
| **New required env vars** | Setup fails or ThunderID won't start | Check release notes, add to `.env` and `docker-compose.yml` |
| **OAuth2 endpoint behavior changed** | Tests 3.x or 4.x fail | Very unlikely (standards-based), but check release notes |

### Version Compatibility Notes

**Tenant servers are version-independent.** The monitoring-api (and any server you build following Section 14) uses only standard JWKS/JWT verification. It does not call any ThunderID-specific API. You can upgrade ThunderID without touching or restarting your tenant servers — they will continue to verify tokens using their cached JWKS keys.

**Bootstrap scripts are version-sensitive.** The `bootstrap.py` and `seed_users.py` scripts call ThunderID-specific management APIs. If ThunderID changes these APIs, you'll need to update the scripts. The test suite will catch this — if `make bootstrap` succeeds and all tests pass, you're good.

**The fallback plan.** If ThunderID makes a breaking change that requires significant rework, the previous Kratos-based architecture is preserved in `master-plan-kratos-v1.md`. Because the tenant server middleware uses standard JWKS, migrating to a different OIDC provider only requires changing the JWKS URL — no tenant server code changes needed.

---

## Project Structure

```text
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
│   ├── restore-db.sh             # Full restore from tarball
│   └── upgrade.sh                # Automated ThunderID version upgrade
│
├── backups/
│   └── .gitkeep                  # Backup tarballs stored here (gitignored)
│
├── DEVELOPER-GUIDE.md            # AI agent integration guide for developers
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
