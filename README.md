# Anima

Centralized identity and authorization gateway for internal servers. Built on [ThunderID](https://github.com/thunder-id/thunderid), Anima provides shared authentication for **humans and AI agents** with per-tenant RBAC, OAuth2/OIDC token issuance, agent delegation, and offline JWT verification.

## Architecture

```text
┌─────────────────────────────────────────────────────────────┐
│                    Internal Network                          │
│                                                             │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐      │
│  │ monitoring   │  │ data-pipeline│  │ deploy-tool  │ ...  │
│  │ (REST API)   │  │ (REST API)   │  │ (REST API)   │      │
│  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘      │
│         │  Verify JWT      │  Verify JWT     │  Verify JWT  │
│         │  via JWKS        │  via JWKS       │  via JWKS    │
│         │  (offline)       │  (offline)      │  (offline)   │
│         └────────────┬─────┴────────┬────────┘              │
│                      ▼              ▼                       │
│  ┌──────────────────────────────────────────────┐           │
│  │           ThunderID  (port 8090)              │           │
│  │                                               │           │
│  │  OAuth 2.1 / OIDC  ·  JWKS  ·  RBAC          │           │
│  │  Human login (OTP, passkey, social)           │           │
│  │  AI agent identity (autonomous + delegated)   │           │
│  │  Organization units (tenants)                 │           │
│  │  Admin console + Login gate                   │           │
│  └──────────────────────────────────────────────┘           │
└─────────────────────────────────────────────────────────────┘
```

Tenant servers verify JWTs **offline** via the JWKS endpoint (~1 ms per request). No runtime dependency on the identity server for request authorization.

## Prerequisites

- Docker and Docker Compose v2
- Make
- (Optional) `curl` and `jq` for manual API testing

## Quick Start

```bash
# 1. Create environment file
cp .env.example .env
#    Optionally set ADMIN_PASSWORD; if left blank it is auto-generated.

# 2. Start ThunderID + MailSlurper
make setup
#    Note the admin password from setup-output.txt

# 3. Build the toolbox container
make build-toolbox

# 4. Bootstrap tenants, resource servers, roles, and agents
ADMIN_PASSWORD=<pw> make bootstrap

# 5. Seed test users
ADMIN_PASSWORD=<pw> make seed

# 6. Run all tests (83 tests across 7 phases)
ADMIN_PASSWORD=<pw> make test
```

Steps 2-5 combined:

```bash
ADMIN_PASSWORD=<pw> make all
```

## Project Structure

```
anima/
├── docker-compose.yml          # ThunderID, MailSlurper, monitoring-api, toolbox
├── Makefile                    # Operational entry points
├── thunderid/
│   └── deployment.yaml         # ThunderID server configuration
├── bootstrap/
│   ├── auth.py                 # OAuth2 authorization-code + PKCE flow
│   ├── bootstrap.py            # Provision tenants, resource servers, roles, agents
│   ├── seed_users.py           # Create test users and assign roles
│   ├── Dockerfile              # Toolbox image (Python 3.12 + curl/jq)
│   └── config/
│       ├── tenants.yaml        # Organization units
│       ├── resource-servers.yaml  # APIs with scopes
│       ├── roles.yaml          # Roles with permission assignments
│       ├── agents.yaml         # AI agent definitions
│       └── users.yaml          # User-to-tenant role assignments
├── tenant-server/
│   ├── main.py                 # Reference FastAPI server (monitoring-api)
│   ├── auth.py                 # JWT middleware, CallerIdentity, require_scope
│   └── Dockerfile
├── scripts/
│   ├── test-all.sh             # Run all test phases
│   ├── test-phase[1-7].sh      # Individual test phases
│   ├── backup-db.sh            # WAL-safe SQLite hot backup
│   ├── restore-db.sh           # Restore from backup tarball
│   └── upgrade.sh              # Automated ThunderID upgrades
├── USER-GUIDE.md               # Setup and operations guide
├── DEVELOPER-GUIDE.md          # AI agent integration guide
└── TESTING.md                  # Test suite documentation
```

## Tenants and Identity Types

### Tenants

| Tenant | Identifier | Description |
|---|---|---|
| monitoring-api | `https://monitoring-api.internal` | Internal monitoring and alerting |
| data-pipeline | `https://data-pipeline.internal` | ETL and data processing |
| deploy-tool | `https://deploy-tool.internal` | Deployment and release management |

### Three Identity Types

| Type | Auth Flow | Example |
|---|---|---|
| **Human** | Authorization code + PKCE (OTP/passkey/social) | `sysadmin@company.com` |
| **Autonomous agent** | `client_credentials` grant | `alert-cleanup-agent` |
| **Delegated agent** | `authorization_code` + PKCE (acts on behalf of a user) | `monitoring-assistant` |

## Integrating a Tenant Server

The reference implementation in `tenant-server/` shows how to protect any FastAPI service with Anima. The key components:

1. **JWTAuthMiddleware** - Verifies Bearer tokens offline via JWKS
2. **CallerIdentity** - Parsed identity with subject, type, scopes, delegation info
3. **require_scope** - Decorator for route-level scope enforcement

```python
from auth import JWTAuthMiddleware, require_scope

app.add_middleware(JWTAuthMiddleware)

@app.get("/alerts")
@require_scope("alerts:read")
async def list_alerts(request: Request):
    caller = request.state.caller
    # caller.subject, caller.subject_type, caller.scopes, ...
```

Set these environment variables on the tenant server:

| Variable | Description |
|---|---|
| `JWKS_URL` | `https://<thunderid>:8090/oauth2/jwks` |
| `RESOURCE_ID` | The resource server identifier (e.g. `https://monitoring-api.internal`) |
| `JWKS_VERIFY_SSL` | `false` for self-signed certs in dev |

See [DEVELOPER-GUIDE.md](DEVELOPER-GUIDE.md) for the full integration walkthrough.

## Makefile Reference

| Target | Description |
|---|---|
| `make setup` | Start ThunderID + MailSlurper |
| `make build-toolbox` | Build the toolbox container |
| `make bootstrap` | Provision tenants, resource servers, roles, agents |
| `make seed` | Seed test users |
| `make test` | Run all 83 tests |
| `make test-phase[1-7]` | Run a specific test phase |
| `make backup` | Hot backup of all ThunderID databases |
| `make restore FILE=<path>` | Restore from a backup tarball |
| `make upgrade VERSION=X.Y.Z` | Automated ThunderID upgrade |
| `make logs` | Tail ThunderID logs |
| `make status` | Show service status and health |
| `make stop` / `make down` | Stop / stop and remove containers |
| `make clean` | Remove containers and all volumes (fresh start) |

## Services

| Service | Port | Description |
|---|---|---|
| ThunderID | 8090 | Identity server (console, gate, OAuth2, JWKS) |
| MailSlurper | 4436 | Dev email capture UI |
| monitoring-api | 9100 | Reference tenant server |

## Documentation

- [USER-GUIDE.md](USER-GUIDE.md) - Setup, operations, and configuration reference
- [DEVELOPER-GUIDE.md](DEVELOPER-GUIDE.md) - AI agent integration guide
- [TESTING.md](TESTING.md) - Test suite documentation (83 tests, 7 phases)

## License

Internal use only.
