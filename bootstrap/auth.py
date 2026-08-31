"""
Authenticate as the admin user and obtain an OAuth2 access token
with ``system`` scope.

ThunderID does not expose a simple password-grant endpoint.  Instead,
we drive the full authorization-code + PKCE flow programmatically:

  1. ``GET  /oauth2/authorize`` -> redirect to the Gate sign-in page
  2. ``POST /flow/execute``     -> submit credentials, get an assertion JWT
  3. ``POST /oauth2/auth/callback`` -> exchange assertion for an auth code
  4. ``POST /oauth2/token``     -> exchange code + PKCE verifier for tokens

The returned access token carries the ``system`` scope, which is
required by the ``POST /import`` management endpoint.
"""

from __future__ import annotations

import hashlib
import base64
import secrets
import urllib.parse

import httpx


# The built-in CONSOLE application registered by ThunderID setup.
_CLIENT_ID = "CONSOLE"
_RESOURCE = "{base}/mcp"
_REDIRECT = "{base}/console"
_SCOPES = "openid system"


class AuthError(Exception):
    """Raised when any step of the authentication flow fails."""


def _pkce_pair() -> tuple[str, str]:
    """Return (code_verifier, code_challenge) for S256 PKCE."""
    verifier = secrets.token_urlsafe(32)
    digest = hashlib.sha256(verifier.encode()).digest()
    challenge = base64.urlsafe_b64encode(digest).rstrip(b"=").decode()
    return verifier, challenge


def get_admin_token(
    base_url: str,
    username: str,
    password: str,
) -> str:
    """Run the full OAuth2 flow and return an access token string.

    Parameters
    ----------
    base_url:
        ThunderID origin, e.g. ``https://localhost:8090``.
    username:
        Admin username.
    password:
        Admin password.

    Returns
    -------
    str
        Bearer access token with ``system`` scope.

    Raises
    ------
    AuthError
        If any step of the flow fails.
    """
    base = base_url.rstrip("/")
    redirect_uri = _REDIRECT.format(base=base)
    resource = _RESOURCE.format(base=base)
    verifier, challenge = _pkce_pair()

    client = httpx.Client(verify=False, follow_redirects=False, timeout=30)

    # -- Step 1: authorize ------------------------------------------------
    authorize_url = (
        f"{base}/oauth2/authorize?"
        + urllib.parse.urlencode({
            "client_id": _CLIENT_ID,
            "response_type": "code",
            "redirect_uri": redirect_uri,
            "scope": _SCOPES,
            "code_challenge": challenge,
            "code_challenge_method": "S256",
            "state": "bootstrap",
            "resource": resource,
        })
    )
    r = client.get(authorize_url)
    if r.status_code not in (302, 303):
        raise AuthError(f"authorize: expected redirect, got {r.status_code}")

    location = r.headers["location"]
    gate_params = dict(urllib.parse.parse_qsl(
        urllib.parse.urlparse(location).query
    ))
    auth_id = gate_params.get("authId", "")
    exec_id = gate_params.get("executionId", "")
    if not auth_id or not exec_id:
        raise AuthError(f"authorize: missing authId/executionId in {location}")

    # -- Step 2: execute the authentication flow --------------------------
    flow_payload = {
        "authId": auth_id,
        "executionId": exec_id,
        "action": "action_001",
        "inputs": {"username": username, "password": password},
    }
    r = client.post(f"{base}/flow/execute", json=flow_payload)
    flow = r.json()

    # First call may return INCOMPLETE with a challengeToken.
    if flow.get("flowStatus") == "INCOMPLETE":
        flow_payload["challengeToken"] = flow["challengeToken"]
        r = client.post(f"{base}/flow/execute", json=flow_payload)
        flow = r.json()

    if flow.get("flowStatus") != "COMPLETE":
        raise AuthError(
            f"flow: expected COMPLETE, got {flow.get('flowStatus')}: "
            f"{flow.get('code', '')} {flow.get('message', '')}"
        )

    assertion = flow.get("assertion", "")
    if not assertion:
        raise AuthError("flow: COMPLETE but no assertion returned")

    # -- Step 3: auth callback -------------------------------------------
    r = client.post(
        f"{base}/oauth2/auth/callback",
        json={"authId": auth_id, "assertion": assertion},
    )
    cb = r.json()
    cb_uri = cb.get("redirect_uri", "")
    if not cb_uri:
        raise AuthError(f"callback: no redirect_uri in response: {cb}")

    cb_params = dict(urllib.parse.parse_qsl(
        urllib.parse.urlparse(cb_uri).query
    ))
    if "error" in cb_params:
        raise AuthError(
            f"callback: {cb_params['error']}: "
            f"{cb_params.get('error_description', '')}"
        )
    code = cb_params.get("code", "")
    if not code:
        raise AuthError(f"callback: no code in redirect: {cb_uri}")

    # -- Step 4: exchange code for token ----------------------------------
    r = client.post(
        f"{base}/oauth2/token",
        data={
            "grant_type": "authorization_code",
            "client_id": _CLIENT_ID,
            "code": code,
            "redirect_uri": redirect_uri,
            "code_verifier": verifier,
        },
        headers={"Content-Type": "application/x-www-form-urlencoded"},
    )
    token_data = r.json()
    if "access_token" not in token_data:
        raise AuthError(f"token: {token_data}")

    client.close()
    return token_data["access_token"]
