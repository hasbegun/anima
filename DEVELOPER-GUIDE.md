# Aegis ID — AI Agent Integration Guide

How to wire your AI agent into Aegis ID so it can authenticate, get tokens, and call protected APIs. Aegis ID uses ThunderID as its underlying identity provider.

## Table of Contents

1. [Overview](#overview)
2. [Prerequisites](#prerequisites)
3. [Concepts](#concepts)
4. [Step 1: Register Your Agent](#step-1-register-your-agent)
5. [Step 2: Get a Token](#step-2-get-a-token)
6. [Step 3: Call a Protected API](#step-3-call-a-protected-api)
7. [Step 4: Verify Tokens in Your API](#step-4-verify-tokens-in-your-api)
8. [API Reference](#api-reference)
9. [End-to-End Examples](#end-to-end-examples)
10. [Advanced: Delegated Agents](#advanced-delegated-agents)
11. [Advanced: Token Introspection and Revocation](#advanced-token-introspection-and-revocation)
12. [Troubleshooting](#troubleshooting)
13. [Quick Reference Card](#quick-reference-card)

---

## Overview

```text
┌──────────────┐     ① Register agent      ┌──────────────────┐
│  You (admin) │ ──────────────────────────→│    ThunderID      │
└──────────────┘                            │  (Identity Svc)   │
                                            │                   │
┌──────────────┐     ② Get token            │  POST /oauth2/    │
│  Your Agent  │ ──────────────────────────→│       token       │
│  (code)      │ ←──────────────────────────│                   │
│              │     ← JWT access token     │  GET /oauth2/jwks │
│              │                            └─────────┬─────────┘
│              │     ③ Call API with JWT               │
│              │ ──────────────────────────→┌──────────┴─────────┐
│              │ ←──────────────────────────│  Your API Server   │
└──────────────┘     ← Response             │  (verifies JWT     │
                                            │   via JWKS)        │
                                            └────────────────────┘
```

Your agent gets an OAuth2 `client_id` and `client_secret`, uses them to get a JWT access token from ThunderID, and sends that token in the `Authorization` header when calling your API. Your API server verifies the token using ThunderID's public keys (JWKS).

---

## Prerequisites

- ThunderID is running and bootstrapped (`make setup && make bootstrap`)
- You have the admin password (from `setup-output.txt` or `.env`)
- You know which API (resource server) your agent needs to call
- You know which scopes (permissions) your agent needs

### Key URLs

| Endpoint | URL | Purpose |
| -------- | --- | ------- |
| OIDC Discovery | `https://localhost:8090/.well-known/openid-configuration` | Auto-discover all endpoints |
| Token | `https://localhost:8090/oauth2/token` | Get access tokens |
| JWKS | `https://localhost:8090/oauth2/jwks` | Public keys for JWT verification |
| Introspection | `https://localhost:8090/oauth2/introspect` | Check if a token is active (online) |
| Revocation | `https://localhost:8090/oauth2/revoke` | Revoke a token |
| Agents API | `https://localhost:8090/agents` | Register and list agents (admin) |

---

## Concepts

### Identity Types

| Type | Grant Type | Use Case |
| ---- | ---------- | -------- |
| **Autonomous** | `client_credentials` | Agent acts on its own (cron jobs, background tasks, pipelines) |
| **Delegated** | `authorization_code` + PKCE | Agent acts on behalf of a user (assistants, chatbots) |

Most agents are **autonomous**. Use delegated only if your agent needs to perform actions as a specific user.

### Scopes

Scopes are permissions like `alerts:read`, `pipelines:run`, `deployments:trigger`. An agent can only get tokens with scopes it was registered with. If it requests more, ThunderID **downscopes** the token automatically — no error, just fewer permissions.

### Resource Servers (Audiences)

Each API has a unique identifier (e.g., `https://monitoring-api.internal`). When your agent requests a token, it specifies which API the token is for via the `resource` parameter. The resulting JWT has an `aud` (audience) claim set to that identifier. Your API server rejects tokens with the wrong audience.

---

## Step 1: Register Your Agent

There are two ways to register an agent: via config file (recommended) or via API.

### Option A: Config File (Recommended)

Add your agent to `bootstrap/config/agents.yaml`:

```yaml
agents:
  # ... existing agents ...

  - name: "my-cleanup-agent"
    tenant: "monitoring-api"             # Which tenant this agent belongs to
    type: "default"
    mode: "autonomous"                   # or "delegated"
    description: "Cleans up stale monitoring data"
    attributes:                          # Optional metadata
      model: "gpt-4"
      modelProvider: "openai"
      function: "task-automation"
    roles:
      - "monitoring-operator"            # Role to assign (defines max permissions)
    scopes:
      - "alerts:read"                    # Scopes this agent can request
      - "alerts:write"
```

Then run bootstrap:

```bash
ADMIN_PASSWORD=<pw> make bootstrap
```

The agent's `clientId` and `clientSecret` are written to `bootstrap/config/agent-secrets.json`:

```json
{
  "my-cleanup-agent": {
    "agentId": "01a060de-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
    "clientId": "zF_t7BWXhOUI_KFO27ETIA",
    "clientSecret": "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
    "mode": "autonomous"
  }
}
```

> **Important:** This file is gitignored. Store these credentials securely (vault, environment variables, etc.).

### Option B: API (Programmatic)

Register an agent directly via the management API:

```bash
# First, get an admin token (see auth.py for the full PKCE flow)
ADMIN_TOKEN="<your_admin_token>"

# Register the agent
curl -sf --insecure -X POST 'https://localhost:8090/agents' \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{
    "name": "my-cleanup-agent",
    "type": "default",
    "description": "Cleans up stale monitoring data",
    "ouId": "<organization_unit_id>",
    "inboundAuthConfig": [{
      "type": "oauth2",
      "config": {
        "grantTypes": ["client_credentials"],
        "tokenEndpointAuthMethod": "client_secret_basic",
        "scopes": ["alerts:read", "alerts:write"]
      }
    }]
  }'
```

Response:

```json
{
  "id": "01a060de-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
  "name": "my-cleanup-agent",
  "inboundAuthConfig": [{
    "type": "oauth2",
    "config": {
      "clientId": "zF_t7BWXhOUI_KFO27ETIA",
      "clientSecret": "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
      "grantTypes": ["client_credentials"],
      "scopes": ["alerts:read", "alerts:write"]
    }
  }]
}
```

Save the `clientId` and `clientSecret` from the response. These are only returned at creation time.

Then assign a role:

```bash
# Look up the role ID
ROLE_ID=$(curl -sf --insecure -H "Authorization: Bearer $ADMIN_TOKEN" \
  'https://localhost:8090/roles' | python3 -c "
import sys, json
roles = json.load(sys.stdin)['roles']
for r in roles:
    if r['name'] == 'monitoring-operator':
        print(r['id'])
        break
")

# Assign role to agent
curl -sf --insecure -X POST "https://localhost:8090/roles/$ROLE_ID/assignments/add" \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H 'Content-Type: application/json' \
  -d "{\"assignments\": [{\"type\": \"agent\", \"id\": \"$AGENT_ID\"}]}"
```

---

## Step 2: Get a Token

Your agent requests a token using its `clientId` and `clientSecret`:

### curl

```bash
curl -sf --insecure -X POST 'https://localhost:8090/oauth2/token' \
  -u "$CLIENT_ID:$CLIENT_SECRET" \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -d 'grant_type=client_credentials&resource=https://monitoring-api.internal&scope=alerts:read alerts:write'
```

### Python

```python
import httpx

THUNDERID_URL = "https://localhost:8090"
CLIENT_ID = "zF_t7BWXhOUI_KFO27ETIA"
CLIENT_SECRET = "your-client-secret"

client = httpx.Client(verify=False)  # verify=True with proper certs in production
response = client.post(
    f"{THUNDERID_URL}/oauth2/token",
    auth=(CLIENT_ID, CLIENT_SECRET),
    headers={"Content-Type": "application/x-www-form-urlencoded"},
    data={
        "grant_type": "client_credentials",
        "resource": "https://monitoring-api.internal",
        "scope": "alerts:read alerts:write",
    },
)
token_data = response.json()
access_token = token_data["access_token"]
```

### Node.js

```javascript
const response = await fetch("https://localhost:8090/oauth2/token", {
  method: "POST",
  headers: {
    "Content-Type": "application/x-www-form-urlencoded",
    "Authorization": "Basic " + btoa(`${CLIENT_ID}:${CLIENT_SECRET}`),
  },
  body: new URLSearchParams({
    grant_type: "client_credentials",
    resource: "https://monitoring-api.internal",
    scope: "alerts:read alerts:write",
  }),
});
const { access_token } = await response.json();
```

### Go

```go
import (
    "encoding/base64"
    "net/http"
    "net/url"
    "strings"
)

data := url.Values{
    "grant_type": {"client_credentials"},
    "resource":   {"https://monitoring-api.internal"},
    "scope":      {"alerts:read alerts:write"},
}

req, _ := http.NewRequest("POST", "https://localhost:8090/oauth2/token",
    strings.NewReader(data.Encode()))
req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
req.SetBasicAuth(clientID, clientSecret)

resp, err := http.DefaultClient.Do(req)
```

### Token Response

```json
{
  "access_token": "eyJhbGciOiJSUzI1NiIs...",
  "token_type": "Bearer",
  "expires_in": 3600,
  "scope": "alerts:read alerts:write"
}
```

### Token Request Parameters

| Parameter | Required | Value | Description |
| --------- | -------- | ----- | ----------- |
| `grant_type` | Yes | `client_credentials` | OAuth2 grant type |
| `resource` | Yes | e.g., `https://monitoring-api.internal` | Target API identifier (becomes `aud` claim) |
| `scope` | Yes | e.g., `alerts:read alerts:write` | Space-separated list of requested permissions |

### Authentication

The `clientId` and `clientSecret` are sent via HTTP Basic Auth:

```text
Authorization: Basic base64(clientId:clientSecret)
```

### What's in the JWT

Decode the access token to see its claims:

```json
{
  "aud": "https://monitoring-api.internal",
  "client_id": "zF_t7BWXhOUI_KFO27ETIA",
  "exp": 1788506121,
  "grant_type": "client_credentials",
  "iat": 1788502521,
  "iss": "https://localhost:8090",
  "jti": "01a06b0e-b4ca-702b-b370-5839a5f3a682",
  "nbf": 1788502521,
  "scope": "alerts:read alerts:write",
  "sub": "01a060de-9a9f-7f86-adf9-a4520e15b65e"
}
```

| Claim | Description |
| ----- | ----------- |
| `sub` | Agent's unique ID (the `agentId` from registration) |
| `aud` | Target API identifier — your API must verify this matches |
| `scope` | Granted permissions (may be downscoped from what you requested) |
| `grant_type` | `client_credentials` for autonomous agents |
| `client_id` | Agent's OAuth2 client ID |
| `iss` | ThunderID issuer URL |
| `iat` | Issued-at time (Unix timestamp) |
| `nbf` | Not-before time (Unix timestamp, same as `iat`) |
| `exp` | Expiration time (Unix timestamp, default: 1 hour from `iat`) |
| `jti` | Unique token ID |

---

## Step 3: Call a Protected API

Send the token in the `Authorization` header:

### curl

```bash
curl -sf http://localhost:9100/alerts \
  -H "Authorization: Bearer $ACCESS_TOKEN"
```

### Python

```python
response = httpx.get(
    "http://localhost:9100/alerts",
    headers={"Authorization": f"Bearer {access_token}"},
)
print(response.json())
```

### Node.js

```javascript
const response = await fetch("http://localhost:9100/alerts", {
  headers: { "Authorization": `Bearer ${access_token}` },
});
const data = await response.json();
```

### Go

```go
req, _ := http.NewRequest("GET", "http://localhost:9100/alerts", nil)
req.Header.Set("Authorization", "Bearer "+accessToken)
resp, err := http.DefaultClient.Do(req)
```

### Response Codes

| Code | Meaning | Common Cause |
| ---- | ------- | ------------ |
| **200** | Success | Token valid, scopes sufficient |
| **401** | Unauthorized | Missing/expired/malformed token, or wrong audience |
| **403** | Forbidden | Token valid but missing required scope |

### 401 Response (no token)

```json
{ "detail": "Missing Authorization header" }
```

### 401 Response (wrong audience)

```json
{ "detail": "Invalid audience" }
```

### 403 Response (missing scope)

```json
{
  "detail": "Requires scope: alerts:delete. You have: alerts:read, alerts:write"
}
```

---

## Step 4: Verify Tokens in Your API

If you're building an API server that agents (or users) will call, here's how to verify the JWT tokens.

The approach is **offline verification** — your server fetches ThunderID's public keys (JWKS) and verifies the JWT signature locally. No per-request call to ThunderID.

### Python (FastAPI)

This is a simplified version of the middleware used by the reference `monitoring-api` in this project. For the full version with `CallerIdentity`, audit logging, and request-ID tracking, copy `tenant-server/auth.py` as your starting point.

**Dependencies:**

```text
fastapi>=0.115,<1
uvicorn>=0.32,<1
pyjwt[crypto]>=2.8,<3
```

**Middleware setup:**

```python
import os
import ssl
import jwt
from jwt import PyJWKClient
from fastapi import FastAPI, HTTPException, Request
from starlette.middleware.base import BaseHTTPMiddleware

# Configuration — set via environment variables
JWKS_URL = os.getenv("JWKS_URL", "https://thunderid:8090/oauth2/jwks")
RESOURCE_ID = os.getenv("RESOURCE_ID", "https://your-api.internal")

# JWKS client — fetches and caches ThunderID's public keys
ssl_ctx = ssl.create_default_context()
if os.getenv("JWKS_VERIFY_SSL", "true").lower() != "true":
    ssl_ctx.check_hostname = False
    ssl_ctx.verify_mode = ssl.CERT_NONE

jwks_client = PyJWKClient(JWKS_URL, cache_jwk_set=True, lifespan=3600, ssl_context=ssl_ctx)


def verify_token(token: str) -> dict:
    """Verify JWT and return decoded claims."""
    signing_key = jwks_client.get_signing_key_from_jwt(token)
    claims = jwt.decode(
        token,
        signing_key.key,
        algorithms=["RS256"],
        audience=RESOURCE_ID,  # Reject tokens meant for other APIs
    )
    return claims


class JWTAuthMiddleware(BaseHTTPMiddleware):
    """Reject requests without a valid JWT (except public paths)."""
    PUBLIC_PATHS = {"/health", "/docs", "/openapi.json", "/redoc"}

    async def dispatch(self, request, call_next):
        if request.url.path in self.PUBLIC_PATHS:
            return await call_next(request)

        auth = request.headers.get("Authorization", "")
        if not auth.startswith("Bearer "):
            return JSONResponse(status_code=401,
                                content={"detail": "Missing Authorization header"})

        try:
            claims = verify_token(auth[7:])
            request.state.caller = claims
        except jwt.ExpiredSignatureError:
            return JSONResponse(status_code=401, content={"detail": "Token expired"})
        except jwt.InvalidAudienceError:
            return JSONResponse(status_code=401, content={"detail": "Invalid audience"})
        except Exception as e:
            return JSONResponse(status_code=401, content={"detail": f"Invalid token: {e}"})

        return await call_next(request)


# Use it
app = FastAPI()
app.add_middleware(JWTAuthMiddleware)

@app.get("/health")
async def health():
    return {"status": "ok"}

@app.get("/data")
async def get_data(request: Request):
    claims = request.state.caller
    # Check scopes
    scopes = claims.get("scope", "").split()
    if "data:read" not in scopes:
        raise HTTPException(403, "Requires scope: data:read")
    return {"data": [...], "caller_sub": claims["sub"]}
```

### Node.js (Express)

**Dependencies:**

```bash
npm install jwks-rsa jsonwebtoken
```

**Middleware:**

```javascript
const jwt = require("jsonwebtoken");
const jwksClient = require("jwks-rsa");

const JWKS_URL = process.env.JWKS_URL || "https://thunderid:8090/oauth2/jwks";
const RESOURCE_ID = process.env.RESOURCE_ID || "https://your-api.internal";

const client = jwksClient({
  jwksUri: JWKS_URL,
  cache: true,
  cacheMaxAge: 3600000, // 1 hour
});

function getKey(header, callback) {
  client.getSigningKey(header.kid, (err, key) => {
    if (err) return callback(err);
    callback(null, key.getPublicKey());
  });
}

function authMiddleware(req, res, next) {
  // Skip public paths
  if (req.path === "/health") return next();

  const auth = req.headers.authorization;
  if (!auth || !auth.startsWith("Bearer ")) {
    return res.status(401).json({ detail: "Missing Authorization header" });
  }

  const token = auth.slice(7);
  jwt.verify(token, getKey, { algorithms: ["RS256"], audience: RESOURCE_ID },
    (err, decoded) => {
      if (err) {
        const message = err.name === "TokenExpiredError" ? "Token expired"
                      : err.name === "JsonWebTokenError" ? "Invalid token"
                      : `Invalid token: ${err.message}`;
        return res.status(401).json({ detail: message });
      }
      req.caller = decoded;
      next();
    }
  );
}

// Scope-checking helper
function requireScope(...scopes) {
  return (req, res, next) => {
    const callerScopes = (req.caller.scope || "").split(" ");
    if (!scopes.some(s => callerScopes.includes(s))) {
      return res.status(403).json({
        detail: `Requires scope: ${scopes.join(", ")}. You have: ${callerScopes.join(", ")}`,
      });
    }
    next();
  };
}

// Use it
const express = require("express");
const app = express();
app.use(authMiddleware);

app.get("/health", (req, res) => res.json({ status: "ok" }));

app.get("/data", requireScope("data:read"), (req, res) => {
  res.json({ data: [...], caller_sub: req.caller.sub });
});

app.listen(9000);
```

### Go (net/http)

**Dependencies:**

```bash
go get github.com/golang-jwt/jwt/v5
go get github.com/MicahParks/keyfunc/v3
```

**Middleware:**

```go
package main

import (
    "context"
    "encoding/json"
    "net/http"
    "os"
    "strings"
    "time"

    "github.com/MicahParks/keyfunc/v3"
    "github.com/golang-jwt/jwt/v5"
)

var (
    jwksURL    = envOrDefault("JWKS_URL", "https://thunderid:8090/oauth2/jwks")
    resourceID = envOrDefault("RESOURCE_ID", "https://your-api.internal")
)

type contextKey string
const claimsKey contextKey = "claims"

func authMiddleware(next http.Handler) http.Handler {
    // Set up JWKS key function with caching
    k, _ := keyfunc.NewDefault([]string{jwksURL}, keyfunc.NewDefaultOptions{
        RefreshInterval: time.Hour,
    })

    return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        // Skip public paths
        if r.URL.Path == "/health" {
            next.ServeHTTP(w, r)
            return
        }

        auth := r.Header.Get("Authorization")
        if !strings.HasPrefix(auth, "Bearer ") {
            writeJSON(w, 401, map[string]string{"detail": "Missing Authorization header"})
            return
        }

        tokenStr := auth[7:]
        token, err := jwt.Parse(tokenStr, k.KeyFunc,
            jwt.WithValidMethods([]string{"RS256"}),
            jwt.WithAudience(resourceID),
        )
        if err != nil || !token.Valid {
            writeJSON(w, 401, map[string]string{"detail": "Invalid token"})
            return
        }

        claims, _ := token.Claims.(jwt.MapClaims)
        ctx := context.WithValue(r.Context(), claimsKey, claims)
        next.ServeHTTP(w, r.WithContext(ctx))
    })
}

func requireScope(scope string, next http.HandlerFunc) http.HandlerFunc {
    return func(w http.ResponseWriter, r *http.Request) {
        claims := r.Context().Value(claimsKey).(jwt.MapClaims)
        scopeStr, _ := claims["scope"].(string)
        for _, s := range strings.Split(scopeStr, " ") {
            if s == scope {
                next(w, r)
                return
            }
        }
        writeJSON(w, 403, map[string]string{
            "detail": "Requires scope: " + scope,
        })
    }
}

func main() {
    mux := http.NewServeMux()
    mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
        writeJSON(w, 200, map[string]string{"status": "ok"})
    })
    mux.HandleFunc("/data", requireScope("data:read", func(w http.ResponseWriter, r *http.Request) {
        claims := r.Context().Value(claimsKey).(jwt.MapClaims)
        writeJSON(w, 200, map[string]any{"caller_sub": claims["sub"]})
    }))
    http.ListenAndServe(":9000", authMiddleware(mux))
}

func envOrDefault(key, def string) string {
    if v := os.Getenv(key); v != "" { return v }
    return def
}

func writeJSON(w http.ResponseWriter, code int, data any) {
    w.Header().Set("Content-Type", "application/json")
    w.WriteHeader(code)
    json.NewEncoder(w).Encode(data)
}
```

### Key Points for All Languages

1. **Fetch JWKS once, cache it.** Don't fetch keys on every request. Cache for ~1 hour.
2. **Verify `aud` (audience).** Always check that the token's audience matches your API's resource identifier. This prevents tokens meant for other APIs from being used on yours.
3. **Check `scope` on each route.** The middleware verifies the token is valid; individual routes check if the caller has the right permissions.
4. **Never hardcode the public key.** Always fetch from the JWKS endpoint — keys rotate.

---

## API Reference

### Standard OAuth2/OIDC Endpoints

These endpoints follow industry standards and are stable across ThunderID versions.

#### POST /oauth2/token — Get an Access Token

**Agent authentication (autonomous):**

```http
POST /oauth2/token HTTP/1.1
Host: localhost:8090
Authorization: Basic base64(clientId:clientSecret)
Content-Type: application/x-www-form-urlencoded

grant_type=client_credentials&resource=https://monitoring-api.internal&scope=alerts:read alerts:write
```

**Response (200):**

```json
{
  "access_token": "eyJhbGciOiJSUzI1NiIs...",
  "token_type": "Bearer",
  "expires_in": 3600,
  "scope": "alerts:read alerts:write"
}
```

**Error (401 — bad credentials):**

```json
{
  "error": "invalid_client",
  "error_description": "Client authentication failed"
}
```

---

#### GET /oauth2/jwks — Public Keys for JWT Verification

```http
GET /oauth2/jwks HTTP/1.1
Host: localhost:8090
```

**Response (200):**

```json
{
  "keys": [
    {
      "kty": "RSA",
      "kid": "...",
      "use": "sig",
      "alg": "RS256",
      "n": "...",
      "e": "AQAB"
    }
  ]
}
```

Your API server uses these keys to verify JWT signatures **offline** (no call to ThunderID per request).

---

#### POST /oauth2/introspect — Check Token Status (Online)

```http
POST /oauth2/introspect HTTP/1.1
Host: localhost:8090
Authorization: Basic base64(clientId:clientSecret)
Content-Type: application/x-www-form-urlencoded

token=eyJhbGciOiJSUzI1NiIs...
```

**Response (active token):**

```json
{
  "active": true,
  "sub": "01a060de-9a9f-7f86-adf9-a4520e15b65e",
  "client_id": "zF_t7BWXhOUI_KFO27ETIA",
  "scope": "alerts:read alerts:write",
  "aud": "https://monitoring-api.internal",
  "exp": 1788506121,
  "iss": "https://localhost:8090",
  "token_type": "Bearer"
}
```

**Response (revoked or expired token):**

```json
{ "active": false }
```

---

#### POST /oauth2/revoke — Revoke a Token

```http
POST /oauth2/revoke HTTP/1.1
Host: localhost:8090
Authorization: Basic base64(clientId:clientSecret)
Content-Type: application/x-www-form-urlencoded

token=eyJhbGciOiJSUzI1NiIs...&token_type_hint=access_token
```

**Response:** `200 OK` (always, per RFC 7009)

> **Note:** Revoked tokens are still valid for **offline** (JWKS) verification until they expire. Use introspection for real-time revocation checking.

---

#### GET /.well-known/openid-configuration — OIDC Discovery

```http
GET /.well-known/openid-configuration HTTP/1.1
Host: localhost:8090
```

Returns all endpoints, supported grant types, algorithms, etc. Use this to auto-configure your OAuth2 client library instead of hardcoding URLs.

**Key fields:**

```json
{
  "issuer": "https://localhost:8090",
  "token_endpoint": "https://localhost:8090/oauth2/token",
  "jwks_uri": "https://localhost:8090/oauth2/jwks",
  "introspection_endpoint": "https://localhost:8090/oauth2/introspect",
  "revocation_endpoint": "https://localhost:8090/oauth2/revoke",
  "grant_types_supported": [
    "client_credentials",
    "authorization_code",
    "refresh_token",
    "urn:ietf:params:oauth:grant-type:token-exchange"
  ],
  "token_endpoint_auth_methods_supported": [
    "client_secret_basic",
    "client_secret_post",
    "private_key_jwt"
  ],
  "code_challenge_methods_supported": ["S256"]
}
```

---

### ThunderID Management Endpoints (Admin Only)

These require an admin access token (with `system` scope).

#### POST /agents — Register an Agent

```http
POST /agents HTTP/1.1
Host: localhost:8090
Authorization: Bearer <admin_token>
Content-Type: application/json

{
  "name": "my-agent",
  "type": "default",
  "description": "My AI agent",
  "ouId": "<organization_unit_id>",
  "inboundAuthConfig": [{
    "type": "oauth2",
    "config": {
      "grantTypes": ["client_credentials"],
      "tokenEndpointAuthMethod": "client_secret_basic",
      "scopes": ["alerts:read", "alerts:write"]
    }
  }]
}
```

**Response (201):**

```json
{
  "id": "01a060de-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
  "name": "my-agent",
  "inboundAuthConfig": [{
    "config": {
      "clientId": "...",
      "clientSecret": "..."
    }
  }]
}
```

---

#### GET /agents — List All Agents

```http
GET /agents HTTP/1.1
Host: localhost:8090
Authorization: Bearer <admin_token>
```

---

#### GET /agents/{id} — Get Agent Details

```http
GET /agents/01a060de-xxxx HTTP/1.1
Host: localhost:8090
Authorization: Bearer <admin_token>
```

---

#### POST /roles/{roleId}/assignments/add — Assign Role to Agent

```http
POST /roles/<role_id>/assignments/add HTTP/1.1
Host: localhost:8090
Authorization: Bearer <admin_token>
Content-Type: application/json

{
  "assignments": [{"type": "agent", "id": "<agent_id>"}]
}
```

**Response:** `204 No Content`

---

#### GET /roles — List All Roles

```http
GET /roles HTTP/1.1
Host: localhost:8090
Authorization: Bearer <admin_token>
```

---

#### POST /import — Bulk Import Resources

Used by `bootstrap.py` to create tenants, resource servers, and roles in bulk.

```http
POST /import HTTP/1.1
Host: localhost:8090
Authorization: Bearer <admin_token>
Content-Type: application/json

{
  "content": "<yaml_string>",
  "dryRun": false,
  "options": {
    "upsert": true,
    "continueOnError": true,
    "target": "runtime"
  }
}
```

---

## End-to-End Examples

### Example 1: Python Agent That Cleans Up Alerts

Complete standalone script — copy and run:

```python
#!/usr/bin/env python3
"""Agent that reads alerts and deletes resolved ones."""
import json
import os
import httpx

# ── Configuration ──
THUNDERID_URL = os.getenv("THUNDERID_URL", "https://localhost:8090")
API_URL = os.getenv("MONITORING_API_URL", "http://localhost:9100")
SECRETS_FILE = os.getenv("SECRETS_FILE", "bootstrap/config/agent-secrets.json")
AGENT_NAME = "alert-cleanup-agent"

# ── Load credentials ──
with open(SECRETS_FILE) as f:
    creds = json.load(f)[AGENT_NAME]
client_id = creds["clientId"]
client_secret = creds["clientSecret"]

# ── Step 1: Get token ──
token_response = httpx.post(
    f"{THUNDERID_URL}/oauth2/token",
    auth=(client_id, client_secret),
    headers={"Content-Type": "application/x-www-form-urlencoded"},
    data={
        "grant_type": "client_credentials",
        "resource": "https://monitoring-api.internal",
        "scope": "alerts:read alerts:write alerts:delete",
    },
    verify=False,
)
token_data = token_response.json()
access_token = token_data["access_token"]
print(f"Got token (scopes: {token_data['scope']})")

# Note: we requested alerts:delete but agent only has alerts:read + alerts:write.
# ThunderID automatically downscoped — no error, just fewer permissions.

# ── Step 2: Call API ──
headers = {"Authorization": f"Bearer {access_token}"}

# Read alerts
alerts = httpx.get(f"{API_URL}/alerts", headers=headers).json()
print(f"Found {len(alerts['alerts'])} alerts")

# Check who we are
whoami = httpx.get(f"{API_URL}/whoami", headers=headers).json()
print(f"I am: {whoami['subject']} (type: {whoami['subject_type']})")
print(f"My scopes: {whoami['scopes']}")
```

**Output:**

```text
Got token (scopes: alerts:read alerts:write)
Found 2 alerts
I am: 01a060de-9a9f-7f86-adf9-a4520e15b65e (type: agent)
My scopes: ['alerts:read', 'alerts:write']
```

### Example 2: Node.js Agent That Reads Pipeline Data

```javascript
#!/usr/bin/env node
const fs = require("fs");

const THUNDERID_URL = process.env.THUNDERID_URL || "https://localhost:8090";
const API_URL = process.env.PIPELINE_API_URL || "http://localhost:9200";
const SECRETS_FILE = process.env.SECRETS_FILE || "bootstrap/config/agent-secrets.json";

async function main() {
  // Load credentials
  const secrets = JSON.parse(fs.readFileSync(SECRETS_FILE, "utf-8"));
  const { clientId, clientSecret } = secrets["pipeline-scheduler-agent"];

  // Get token
  const tokenRes = await fetch(`${THUNDERID_URL}/oauth2/token`, {
    method: "POST",
    headers: {
      "Content-Type": "application/x-www-form-urlencoded",
      "Authorization": "Basic " + btoa(`${clientId}:${clientSecret}`),
    },
    body: new URLSearchParams({
      grant_type: "client_credentials",
      resource: "https://data-pipeline.internal",
      scope: "pipelines:read pipelines:run",
    }),
  });
  const { access_token, scope } = await tokenRes.json();
  console.log(`Got token (scopes: ${scope})`);

  // Call API
  const res = await fetch(`${API_URL}/pipelines`, {
    headers: { "Authorization": `Bearer ${access_token}` },
  });
  console.log(`Status: ${res.status}`);
  console.log(await res.json());
}

main().catch(console.error);
```

### Example 3: curl One-Liner

Useful for testing or CI scripts:

```bash
# Get token + call API in one pipeline
ACCESS_TOKEN=$(curl -sf --insecure -X POST 'https://localhost:8090/oauth2/token' \
  -u "$CLIENT_ID:$CLIENT_SECRET" \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -d 'grant_type=client_credentials&resource=https://monitoring-api.internal&scope=alerts:read' \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

curl -sf http://localhost:9100/alerts \
  -H "Authorization: Bearer $ACCESS_TOKEN" | python3 -m json.tool
```

---

## Advanced: Delegated Agents

Delegated agents act **on behalf of a user**. Instead of `client_credentials`, they use `authorization_code` + PKCE. The user logs in, consents, and the agent gets a token scoped to that user's permissions.

### When to Use

- AI assistants that help users investigate issues
- Chatbots that take actions as the user
- Any agent where the action should be attributed to the user, not the agent

### Registration

```yaml
# In agents.yaml
- name: "my-assistant"
  tenant: "monitoring-api"
  mode: "delegated"                       # ← key difference
  description: "AI assistant for users"
  redirect_uris:
    - "http://localhost:3000/callback"     # Where user is redirected after login
  scopes:
    - "alerts:read"
    - "dashboards:read"
```

### Token Flow

```text
┌──────────┐     ① Start auth       ┌──────────────────┐
│  User's  │ ←─────────────────────→│    ThunderID      │
│  Browser │  ← Login + consent     │                   │
│          │  → Auth code            │                   │
└─────┬────┘                        └────────┬──────────┘
      │ ② Auth code                          │
      │ (via redirect to callback)           │
      ↓                                      │
┌──────────┐     ③ Exchange code     ┌───────┴──────────┐
│  Your    │ ──────────────────────→│  POST /oauth2/    │
│  Agent   │ ←──────────────────────│       token       │
│          │     ← Token (user's    │                   │
│          │       identity + agent  │                   │
│          │       scopes)          └────────────────────┘
└──────────┘
```

### Token Exchange

```bash
# After receiving the auth code from the callback:
curl -sf --insecure -X POST 'https://localhost:8090/oauth2/token' \
  -u "$CLIENT_ID:$CLIENT_SECRET" \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -d "grant_type=authorization_code&code=$AUTH_CODE&redirect_uri=http://localhost:3000/callback&code_verifier=$CODE_VERIFIER"
```

### Detecting Delegation in Your API

The JWT from a delegated agent includes an `act` (actor) claim:

```json
{
  "sub": "user-uuid",
  "act": { "sub": "agent-uuid" },
  "scope": "alerts:read dashboards:read",
  "grant_type": "authorization_code"
}
```

Your API server can check:

```python
caller = request.state.caller

if caller.is_delegated:
    print(f"Agent {caller.acting_agent} acting on behalf of user {caller.subject}")
else:
    print(f"Direct call from {caller.subject} (type: {caller.subject_type})")
```

> **Note:** Delegated agents can also use `client_credentials` to get tokens for their own identity (e.g., for background tasks that don't need user context).

---

## Advanced: Token Introspection and Revocation

### Offline vs Online Verification

| Method | Latency | Revocation-Aware | Use When |
| ------ | ------- | ---------------- | -------- |
| **JWKS (offline)** | ~0ms (cached keys) | No — revoked tokens pass until expiry | Default for most API servers |
| **Introspection (online)** | ~5-10ms per request | Yes — revoked tokens rejected immediately | High-security actions (payments, deletions) |

### Using Introspection for High-Security Actions

```python
import httpx

def is_token_active(token: str, client_id: str, client_secret: str) -> bool:
    """Online check — asks ThunderID if the token is still valid."""
    r = httpx.post(
        f"{THUNDERID_URL}/oauth2/introspect",
        auth=(client_id, client_secret),
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        data={"token": token},
        verify=False,
    )
    return r.json().get("active", False)

# Use in a route handler:
@app.delete("/critical-resource/{id}")
@require_scope("resource:delete")
async def delete_critical(request: Request, id: str):
    token = request.headers["Authorization"][7:]
    if not is_token_active(token, INTROSPECT_CLIENT_ID, INTROSPECT_CLIENT_SECRET):
        raise HTTPException(401, "Token has been revoked")
    # ... proceed with deletion
```

### Revoking a Token

Useful when an agent is compromised or a task is complete:

```python
httpx.post(
    f"{THUNDERID_URL}/oauth2/revoke",
    auth=(client_id, client_secret),
    headers={"Content-Type": "application/x-www-form-urlencoded"},
    data={"token": access_token, "token_type_hint": "access_token"},
    verify=False,
)
```

---

## Troubleshooting

### "invalid_client" when requesting a token

**Cause:** Wrong `clientId` or `clientSecret`.

```json
{ "error": "invalid_client", "error_description": "Client authentication failed" }
```

**Fix:** Check `bootstrap/config/agent-secrets.json` for the correct credentials. Re-run `make bootstrap` if secrets were lost.

### Token has fewer scopes than requested

**Cause:** ThunderID downscoped the token. The agent can only get scopes it was registered with in `agents.yaml`.

**Example:** Agent registered with `["alerts:read", "alerts:write"]` requests `alerts:read alerts:delete`. Token comes back with just `alerts:read` (the only overlapping scope).

**Fix:** Add the missing scope to the agent's `scopes` list in `agents.yaml` and re-run `make bootstrap`. Note: the agent also needs a role that grants the scope.

### 401 "Invalid audience" from your API

**Cause:** The `resource` in your token request doesn't match the `RESOURCE_ID` your API server checks.

```bash
# Token was requested for:
resource=https://data-pipeline.internal

# But your API verifies:
RESOURCE_ID=https://monitoring-api.internal
```

**Fix:** Make sure the `resource` parameter in your token request matches the `RESOURCE_ID` (or `audience`) configured in your API server.

### 403 "Requires scope: X. You have: Y"

**Cause:** The token is valid but doesn't include the required scope for this route.

**Fix:**
1. Check if you requested the scope in the token request (`scope=...`)
2. Check if the agent is registered with the scope in `agents.yaml`
3. Check if the agent's role includes the scope in `roles.yaml`

### JWKS fetch fails in your API server

**Cause:** Your API server can't reach ThunderID to fetch public keys.

**Fix:**
- Inside Docker: use `https://thunderid:8090/oauth2/jwks`
- Outside Docker: use `https://localhost:8090/oauth2/jwks`
- For self-signed certs: set `JWKS_VERIFY_SSL=false` (dev only)

### Token works but `subject_type` shows "user" instead of "agent"

**Cause:** ThunderID doesn't set a `sub_type` claim. The middleware infers type from `grant_type`:

- `client_credentials` → `agent`
- `authorization_code` → `user`

If you're using `authorization_code` (delegated mode), the `subject_type` will be `user` because the agent is acting on behalf of a user. Check `is_delegated` and `acting_agent` instead.

---

## Quick Reference Card

### Register Agent

```yaml
# bootstrap/config/agents.yaml
- name: "my-agent"
  tenant: "monitoring-api"
  mode: "autonomous"
  scopes: ["alerts:read", "alerts:write"]
  roles: ["monitoring-operator"]
```

```bash
ADMIN_PASSWORD=<pw> make bootstrap
```

### Get Token

```bash
curl -sf --insecure -X POST 'https://localhost:8090/oauth2/token' \
  -u "$CLIENT_ID:$CLIENT_SECRET" \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -d 'grant_type=client_credentials&resource=https://monitoring-api.internal&scope=alerts:read'
```

### Call API

```bash
curl -sf http://localhost:9100/alerts -H "Authorization: Bearer $TOKEN"
```

### Verify Token (in your API)

```python
# pip install pyjwt[crypto]
from jwt import PyJWKClient
import jwt

jwks = PyJWKClient("https://thunderid:8090/oauth2/jwks", cache_jwk_set=True, lifespan=3600)
key = jwks.get_signing_key_from_jwt(token)
claims = jwt.decode(token, key.key, algorithms=["RS256"], audience="https://your-api.internal")
```

### Environment Variables for Your API Server

```bash
JWKS_URL=https://thunderid:8090/oauth2/jwks        # Where to fetch public keys
RESOURCE_ID=https://your-api.internal               # Your API's audience identifier
JWKS_VERIFY_SSL=false                               # Set true in production
```
