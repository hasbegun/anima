"""
JWT authentication middleware for tenant servers.

Verifies access tokens offline using JWKS (public keys from ThunderID).
Provides ``CallerIdentity`` with subject, scopes, and delegation info,
plus a ``require_scope`` decorator for route-level enforcement.
"""

from __future__ import annotations

import os
import ssl
from functools import wraps
from typing import Optional

import jwt
from fastapi import HTTPException, Request
from fastapi.responses import JSONResponse
from jwt import PyJWKClient
from jwt.exceptions import PyJWKClientError
from starlette.middleware.base import BaseHTTPMiddleware

# ──────────────────────────────────────────────
# Configuration
# ──────────────────────────────────────────────
THUNDERID_URL = os.getenv("THUNDERID_URL", "https://localhost:8090")
RESOURCE_ID = os.getenv("RESOURCE_ID", "https://monitoring-api.internal")
JWKS_URL = os.getenv("JWKS_URL", f"{THUNDERID_URL}/oauth2/jwks")

# ──────────────────────────────────────────────
# JWKS Client (cached, auto-refreshing)
# ──────────────────────────────────────────────
# Allow self-signed certs in dev; in production use proper TLS.
_ssl_ctx = ssl.create_default_context()
if os.getenv("JWKS_VERIFY_SSL", "true").lower() != "true":
    _ssl_ctx.check_hostname = False
    _ssl_ctx.verify_mode = ssl.CERT_NONE

_jwks_client = PyJWKClient(
    JWKS_URL,
    cache_jwk_set=True,
    lifespan=3600,
    ssl_context=_ssl_ctx,
)


# ──────────────────────────────────────────────
# Parsed identity from token
# ──────────────────────────────────────────────
class CallerIdentity:
    """Parsed caller identity from OAuth2 JWT claims."""

    def __init__(self, claims: dict):
        self.subject: str = claims["sub"]
        self.subject_type: str = claims.get("sub_type", "user")
        self.scopes: list[str] = claims.get("scope", "").split()
        self.client_id: str = claims.get("client_id", "")
        self.grant_type: str = claims.get("grant_type", "")
        self.raw_claims: dict = claims

        act = claims.get("act")
        self.acting_agent: Optional[str] = act["sub"] if act else None
        self.is_delegated: bool = act is not None

    @property
    def is_agent(self) -> bool:
        return self.grant_type == "client_credentials"

    @property
    def is_human(self) -> bool:
        return not self.is_agent

    def has_scope(self, scope: str) -> bool:
        return scope in self.scopes

    def has_any_scope(self, scopes: list[str]) -> bool:
        return any(s in self.scopes for s in scopes)


# ──────────────────────────────────────────────
# Token verification
# ──────────────────────────────────────────────
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
    except jwt.InvalidAudienceError:
        raise HTTPException(401, "Invalid audience")
    except PyJWKClientError as e:
        raise HTTPException(401, f"Invalid token: {e}")
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
            return JSONResponse(
                status_code=401,
                content={"detail": "Missing Authorization header"},
            )

        token = auth_header[7:]
        try:
            request.state.caller = verify_token(token)
        except HTTPException as exc:
            return JSONResponse(
                status_code=exc.status_code,
                content={"detail": exc.detail},
            )
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
                    f"You have: {', '.join(caller.scopes)}",
                )
            return await func(request, *args, **kwargs)
        return wrapper
    return decorator
