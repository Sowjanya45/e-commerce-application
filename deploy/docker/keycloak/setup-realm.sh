#!/usr/bin/env bash
# Imports the ecom-app Keycloak realm and provisions the admin user that
# user-service uses (via KeyCloakAdminService) to call Keycloak's Admin
# REST API on new-user registration.
#
# Run this after `docker compose up keycloak` (or the full stack).
# Safe to re-run - every step checks whether it's already done first.
#
# Config via env vars (all optional, shown with their defaults):
#   KEYCLOAK_URL, BOOTSTRAP_ADMIN_USER, BOOTSTRAP_ADMIN_PASSWORD,
#   REALM_NAME, APP_ADMIN_USERNAME, APP_ADMIN_PASSWORD, REALM_EXPORT_FILE
#
# Requires: curl, python3 (used only for tiny JSON field extraction).

set -euo pipefail

KEYCLOAK_URL="${KEYCLOAK_URL:-http://localhost:8443}"
BOOTSTRAP_ADMIN_USER="${BOOTSTRAP_ADMIN_USER:-admin}"
BOOTSTRAP_ADMIN_PASSWORD="${BOOTSTRAP_ADMIN_PASSWORD:-admin}"
REALM_NAME="${REALM_NAME:-ecom-app}"
APP_ADMIN_USERNAME="${APP_ADMIN_USERNAME:-user}"
APP_ADMIN_PASSWORD="${APP_ADMIN_PASSWORD:-user}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REALM_EXPORT_FILE="${REALM_EXPORT_FILE:-$SCRIPT_DIR/realm-export-ecom-app.json}"

json_get() {
  # $1 = json text, $2 = python expression evaluated with it bound to `d`
  python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(eval(sys.argv[2]))" "$1" "$2"
}

echo "Waiting for Keycloak at $KEYCLOAK_URL ..."
ready=false
for _ in $(seq 1 60); do
  if curl -sf "$KEYCLOAK_URL/realms/master" >/dev/null 2>&1; then
    ready=true
    break
  fi
  sleep 2
done
if [ "$ready" != true ]; then
  echo "Keycloak did not become ready in time at $KEYCLOAK_URL" >&2
  exit 1
fi

echo "Authenticating as bootstrap admin ($BOOTSTRAP_ADMIN_USER)..."
TOKEN_RESPONSE=$(curl -sf -X POST "$KEYCLOAK_URL/realms/master/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "client_id=admin-cli" \
  -d "username=$BOOTSTRAP_ADMIN_USER" \
  -d "password=$BOOTSTRAP_ADMIN_PASSWORD" \
  -d "grant_type=password")
ADMIN_TOKEN=$(json_get "$TOKEN_RESPONSE" "d['access_token']")
AUTH_HEADER="Authorization: Bearer $ADMIN_TOKEN"

echo "Checking whether realm '$REALM_NAME' already exists..."
REALM_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -H "$AUTH_HEADER" \
  "$KEYCLOAK_URL/admin/realms/$REALM_NAME")

if [ "$REALM_STATUS" = "200" ]; then
  echo "Realm '$REALM_NAME' already exists - skipping import."
else
  echo "Importing realm from $REALM_EXPORT_FILE ..."
  curl -sf -X POST "$KEYCLOAK_URL/admin/realms" \
    -H "$AUTH_HEADER" -H "Content-Type: application/json" \
    -d @"$REALM_EXPORT_FILE" >/dev/null
  echo "Realm imported."
fi

echo "Checking whether user '$APP_ADMIN_USERNAME' already exists..."
EXISTING_USERS=$(curl -sf -H "$AUTH_HEADER" \
  "$KEYCLOAK_URL/admin/realms/$REALM_NAME/users?username=$APP_ADMIN_USERNAME&exact=true")
USER_COUNT=$(json_get "$EXISTING_USERS" "len(d)")

if [ "$USER_COUNT" -gt 0 ]; then
  USER_ID=$(json_get "$EXISTING_USERS" "d[0]['id']")
  echo "User already exists (id=$USER_ID) - skipping creation."
else
  echo "Creating user '$APP_ADMIN_USERNAME'..."
  curl -sf -X POST "$KEYCLOAK_URL/admin/realms/$REALM_NAME/users" \
    -H "$AUTH_HEADER" -H "Content-Type: application/json" \
    -d "{\"username\":\"$APP_ADMIN_USERNAME\",\"enabled\":true}" >/dev/null

  USER_LOOKUP=$(curl -sf -H "$AUTH_HEADER" \
    "$KEYCLOAK_URL/admin/realms/$REALM_NAME/users?username=$APP_ADMIN_USERNAME&exact=true")
  USER_ID=$(json_get "$USER_LOOKUP" "d[0]['id']")

  echo "Setting password..."
  curl -sf -X PUT "$KEYCLOAK_URL/admin/realms/$REALM_NAME/users/$USER_ID/reset-password" \
    -H "$AUTH_HEADER" -H "Content-Type: application/json" \
    -d "{\"type\":\"password\",\"value\":\"$APP_ADMIN_PASSWORD\",\"temporary\":false}" >/dev/null
fi

echo "Looking up the 'realm-management' client..."
RM_CLIENTS=$(curl -sf -H "$AUTH_HEADER" \
  "$KEYCLOAK_URL/admin/realms/$REALM_NAME/clients?clientId=realm-management")
RM_CLIENT_ID=$(json_get "$RM_CLIENTS" "d[0]['id']")

echo "Granting manage-users, view-users and view-clients permissions..."
ROLE_PAYLOAD="["
first=true
for ROLE_NAME in manage-users view-users view-clients; do
  ROLE_REP=$(curl -sf -H "$AUTH_HEADER" \
    "$KEYCLOAK_URL/admin/realms/$REALM_NAME/clients/$RM_CLIENT_ID/roles/$ROLE_NAME")
  if [ "$first" = true ]; then first=false; else ROLE_PAYLOAD="$ROLE_PAYLOAD,"; fi
  ROLE_PAYLOAD="$ROLE_PAYLOAD$ROLE_REP"
done
ROLE_PAYLOAD="$ROLE_PAYLOAD]"

curl -sf -X POST "$KEYCLOAK_URL/admin/realms/$REALM_NAME/users/$USER_ID/role-mappings/clients/$RM_CLIENT_ID" \
  -H "$AUTH_HEADER" -H "Content-Type: application/json" \
  -d "$ROLE_PAYLOAD" >/dev/null

cat <<SUMMARY

Done.
  Realm:      $REALM_NAME
  Admin user: $APP_ADMIN_USERNAME (matches keycloak.admin.username/password
              in configserver/src/main/resources/config/user-service.yml)

user-service can now call the Keycloak Admin REST API to create users and
assign roles. Log in to the Keycloak console at $KEYCLOAK_URL to inspect
the realm, or start the rest of the stack if you haven't already.
SUMMARY
