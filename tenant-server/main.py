"""
Reference Monitoring API — tenant server protected by ThunderID.

Demonstrates JWT auth middleware integration:
  - /health           → public (no JWT required)
  - GET  /alerts      → requires alerts:read
  - POST /alerts      → requires alerts:write
  - DELETE /alerts/id → requires alerts:delete
  - GET  /whoami      → returns parsed caller identity
"""

import os

from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from auth import JWTAuthMiddleware, require_scope

app = FastAPI(title="Monitoring API", version="1.0.0")

# Middleware runs in reverse addition order: CORS processes first, then JWT.
app.add_middleware(JWTAuthMiddleware)
app.add_middleware(
    CORSMiddleware,
    allow_origins=os.getenv("CORS_ORIGINS", "https://localhost:3000").split(","),
    allow_credentials=True,
    allow_methods=["GET", "POST", "PUT", "DELETE", "OPTIONS"],
    allow_headers=["Authorization", "Content-Type"],
)


# ──────────────────────────────────────────────
# Public
# ──────────────────────────────────────────────
@app.get("/health")
async def health():
    return {"status": "ok", "service": "monitoring-api"}


# ──────────────────────────────────────────────
# Protected routes
# ──────────────────────────────────────────────
@app.get("/alerts")
@require_scope("alerts:read")
async def list_alerts(request: Request):
    caller = request.state.caller
    return {
        "alerts": [
            {"id": "a1", "severity": "critical", "message": "CPU > 90%"},
            {"id": "a2", "severity": "warning", "message": "Disk > 80%"},
        ],
        "caller": {
            "subject": caller.subject,
            "subject_type": "agent" if caller.is_agent else "user",
            "scopes": caller.scopes,
            "is_delegated": caller.is_delegated,
            "acting_agent": caller.acting_agent,
        },
    }


@app.post("/alerts")
@require_scope("alerts:write")
async def create_alert(request: Request):
    caller = request.state.caller
    return {
        "created": True,
        "caller": {
            "subject": caller.subject,
            "subject_type": "agent" if caller.is_agent else "user",
        },
    }


@app.delete("/alerts/{alert_id}")
@require_scope("alerts:delete")
async def delete_alert(request: Request, alert_id: str):
    caller = request.state.caller
    return {
        "deleted": alert_id,
        "caller": {
            "subject": caller.subject,
            "subject_type": "agent" if caller.is_agent else "user",
        },
    }


# ──────────────────────────────────────────────
# Identity endpoint (for testing caller info)
# ──────────────────────────────────────────────
@app.get("/whoami")
async def whoami(request: Request):
    """Return full parsed caller identity — useful for debugging."""
    caller = request.state.caller
    return {
        "subject": caller.subject,
        "subject_type": "agent" if caller.is_agent else "user",
        "scopes": caller.scopes,
        "client_id": caller.client_id,
        "grant_type": caller.grant_type,
        "is_delegated": caller.is_delegated,
        "acting_agent": caller.acting_agent,
    }
