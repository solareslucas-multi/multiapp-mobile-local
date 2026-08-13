#!/usr/bin/env bash
# =============================================================================
# seed-growthbook.sh — one-time + idempotent provisioning for local GrowthBook
#
#   - Waits until the GrowthBook API is up
#   - On a fresh install: creates the admin account + organization + default
#     project via POST /api/auth/firsttime (first user becomes superAdmin)
#   - On an existing install: falls back to POST /api/auth/login
#   - Upserts every flag in growthbook/flags/*.json via the REST API
#   - Ensures the mobile SDK connection exists and prints its SDK key
#
# Re-runs are safe: existing flags are updated, new ones are created.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

# Load .env if present (values there override the defaults below)
if [[ -f "$REPO_ROOT/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$REPO_ROOT/.env"
  set +a
fi

GB_API="${GB_API_URL:-http://localhost:3100}"
GB_UI="${GB_UI_URL:-http://localhost:3000}"
ADMIN_NAME="${GB_ADMIN_NAME:-MultiApp Admin}"
ADMIN_EMAIL="${GB_ADMIN_EMAIL:-admin@multiapp.local}"
ADMIN_PASSWORD="${GB_ADMIN_PASSWORD:-multiapp-local-2026}"
ORG_NAME="${GB_ORG_NAME:-MultiApp}"
SDK_NAME="${GB_SDK_NAME:-Multiapp Mobile}"
SDK_LANGUAGE="${GB_SDK_LANGUAGE:-react}"
FLAGS_DIR="${GB_FLAGS_DIR:-$REPO_ROOT/growthbook/flags}"
ENV_NAME="${GB_ENV_NAME:-production}"

if ! command -v curl >/dev/null 2>&1; then
  echo "error: curl is required" >&2
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "error: python3 is required" >&2
  exit 1
fi

# --- helpers -----------------------------------------------------------------

py() { python3 -c "$1" "${@:2}"; }

http_code() {
  curl -s -o /dev/null -w '%{http_code}' "$@"
}

# --- 1. wait for the API ------------------------------------------------------
echo "Waiting for GrowthBook API at $GB_API ..."
API_READY=0
for _ in $(seq 1 90); do
  # /api/v1/openapi.yaml is the one public/no-auth endpoint used for health
  if [[ "$(http_code "$GB_API/api/v1/openapi.yaml")" == "200" ]]; then
    API_READY=1
    break
  fi
  sleep 2
done
if [[ "$API_READY" != "1" ]]; then
  echo "error: GrowthBook API did not become ready at $GB_API (is it running? try: make up)" >&2
  exit 1
fi
echo "GrowthBook API is up."

# --- 2. authenticate (first install: create account+org; else: login) --------
post_json() { # $1=path $2=json
  curl -fsS -X POST "$GB_API$1" -H 'Content-Type: application/json' -d "$2"
}

TOKEN=""
FIRST_INSTALL=0
SIGNUP_BODY=$(py '
import json, sys
print(json.dumps({
  "email": sys.argv[1],
  "name": sys.argv[2],
  "password": sys.argv[3],
  "companyname": sys.argv[4],
}))' "$ADMIN_EMAIL" "$ADMIN_NAME" "$ADMIN_PASSWORD" "$ORG_NAME")

if RESP=$(post_json "/auth/firsttime" "$SIGNUP_BODY" 2>/dev/null); then
  TOKEN=$(py 'import json,sys; print(json.loads(sys.argv[1]).get("token",""))' "$RESP" || true)
  FIRST_INSTALL=1
fi

if [[ -z "$TOKEN" ]]; then
  LOGIN_BODY=$(py '
import json, sys
print(json.dumps({"email": sys.argv[1], "password": sys.argv[2]}))' "$ADMIN_EMAIL" "$ADMIN_PASSWORD")
  if RESP=$(post_json "/auth/login" "$LOGIN_BODY" 2>/dev/null); then
    TOKEN=$(py 'import json,sys; print(json.loads(sys.argv[1]).get("token",""))' "$RESP" || true)
  fi
fi

if [[ -z "$TOKEN" ]]; then
  echo "error: could not create or log into the admin account." >&2
  echo "       If the org already exists with different credentials, reset it:" >&2
  echo "         make reset && make setup" >&2
  exit 1
fi

# JWT bearer requests need the organization id via the X-Organization header
# (only static API keys carry the org implicitly). Resolve it from /user.
ORG_ID=$(curl -fsS -H "Authorization: Bearer $TOKEN" "$GB_API/user" 2>/dev/null |
  py 'import json,sys; d=json.load(sys.stdin)
o=(d.get("organizations") or d.get("orgs") or [])
print(o[0]["id"] if o else "")' || true)
if [[ -z "$ORG_ID" ]]; then
  echo "error: could not resolve the organization id for $ADMIN_EMAIL" >&2
  exit 1
fi

AUTH="Authorization: Bearer $TOKEN"
AUTH_ORG="X-Organization: $ORG_ID"

if [[ "$FIRST_INSTALL" == "1" ]]; then
  echo "Created admin account + organization '$ORG_NAME'."
else
  echo "Logged into existing installation as $ADMIN_EMAIL."
fi

# --- 3. upsert feature flags ---------------------------------------------------
CREATED=0
UPDATED=0
SKIPPED=0

for flag_file in "$FLAGS_DIR"/*.json; do
  [[ -e "$flag_file" ]] || continue

  KEY=$(py 'import json,sys; print(json.load(open(sys.argv[1]))["id"])' "$flag_file")
  if [[ -z "$KEY" ]]; then
    echo "skip: $(basename "$flag_file") — no \"id\" field" >&2
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  # inject the admin as owner if the file does not specify one
  BODY=$(py '
import json, sys
d = json.load(open(sys.argv[1]))
d.setdefault("owner", sys.argv[2])
print(json.dumps(d))' "$flag_file" "$ADMIN_EMAIL")

  EXISTING=$(http_code -H "$AUTH" -H "$AUTH_ORG" "$GB_API/api/v1/features/$KEY")
  if [[ "$EXISTING" == "200" ]]; then
    # partial update body: same file, minus keys the update schema rejects
    UPDATE_BODY=$(py '
import json, sys
d = json.load(open(sys.argv[1]))
allowed = [
  "description", "archived", "project", "targetingAllProjects",
  "targetingProjects", "owner", "defaultValue", "tags", "environments",
  "prerequisites", "jsonSchema", "customFields",
]
out = {k: d[k] for k in allowed if k in d}
print(json.dumps(out))' "$flag_file")
    if curl -fsS -X POST -H "$AUTH" -H "$AUTH_ORG" -H 'Content-Type: application/json' \
        -d "$UPDATE_BODY" "$GB_API/api/v1/features/$KEY" >/dev/null 2>&1; then
      echo "updated: $KEY"
      UPDATED=$((UPDATED + 1))
    else
      echo "error: failed to update $KEY" >&2
      exit 1
    fi
  else
    if curl -fsS -X POST -H "$AUTH" -H "$AUTH_ORG" -H 'Content-Type: application/json' \
        -d "$BODY" "$GB_API/api/v1/features" >/dev/null 2>&1; then
      echo "created: $KEY"
      CREATED=$((CREATED + 1))
    else
      echo "error: failed to create $KEY" >&2
      exit 1
    fi
  fi
done

echo "Flags: $CREATED created, $UPDATED updated, $SKIPPED skipped."

# --- 4. ensure the mobile SDK connection exists --------------------------------
SDK_KEY=""
CONNECTIONS=$(curl -fsS -H "$AUTH" -H "$AUTH_ORG" "$GB_API/api/v1/sdk-connections" 2>/dev/null || echo '{"connections": []}')
HAS_CONNECTION=$(py '
import json, sys
d = json.loads(sys.argv[1])
print(1 if any(c.get("name") == sys.argv[2] for c in d.get("connections", [])) else 0)' \
  "$CONNECTIONS" "$SDK_NAME" || echo "0")

if [[ "$HAS_CONNECTION" == "1" ]]; then
  SDK_KEY=$(py '
import json, sys
d = json.loads(sys.argv[1])
for c in d.get("connections", []):
    if c.get("name") == sys.argv[2]:
        print(c.get("key", ""))
        break' "$CONNECTIONS" "$SDK_NAME" || true)
  echo "sdk connection '$SDK_NAME' already exists."
else
  SDK_BODY=$(py '
import json, sys
print(json.dumps({
  "name": sys.argv[1],
  "environment": sys.argv[2],
  "language": sys.argv[3],
}))' "$SDK_NAME" "$ENV_NAME" "$SDK_LANGUAGE")
  if RESP=$(curl -fsS -X POST -H "$AUTH" -H "$AUTH_ORG" -H 'Content-Type: application/json' \
      -d "$SDK_BODY" "$GB_API/api/v1/sdk-connections" 2>/dev/null); then
    SDK_KEY=$(py 'import json,sys; print(json.loads(sys.argv[1])["sdkConnection"].get("key",""))' "$RESP" || true)
    echo "created sdk connection '$SDK_NAME'."
  else
    echo "warning: could not create SDK connection '$SDK_NAME' — create one in the UI if needed." >&2
  fi
fi

# --- 5. summary ------------------------------------------------------------------
echo
echo "======================================================================"
echo " GrowthBook is ready!"
echo "   UI       : $GB_UI"
echo "   Email    : $ADMIN_EMAIL"
echo "   Password : $ADMIN_PASSWORD"
if [[ -n "$SDK_KEY" ]]; then
  echo "   SDK key  : $SDK_KEY"
  echo "             (use in your app as GROWTHBOOK_SDK_KEY / GROWTHBOOK_API_HOST=$GB_API)"
fi
echo "======================================================================"