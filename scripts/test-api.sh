#!/bin/bash
# Quick API smoke test for ThunderID.
# Verifies OIDC discovery and JWKS endpoints.
set -e

BASE_URL="https://localhost:8090"
VERIFY="--insecure"

echo "=== OIDC Discovery ==="
curl -sf $VERIFY "$BASE_URL/.well-known/openid-configuration" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(f'Issuer:   {d[\"issuer\"]}')
print(f'Token:    {d[\"token_endpoint\"]}')
print(f'JWKS:     {d[\"jwks_uri\"]}')
print(f'Grants:   {d.get(\"grant_types_supported\", [])}')
"

echo ""
echo "=== JWKS ==="
curl -sf $VERIFY "$BASE_URL/oauth2/jwks" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(f'Keys: {len(d[\"keys\"])}')
for k in d['keys']:
    print(f'  kid={k[\"kid\"]} alg={k[\"alg\"]} kty={k[\"kty\"]}')
"

echo ""
echo "=== All smoke tests passed! ==="
