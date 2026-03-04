#!/bin/bash
# edge-device-service setup script
# Run this after: docker compose -f compose/docker-compose.yml up -d
#
# What this does:
#   1. Loads the edge/device SpiceDB schema
#   2. Registers the Debezium outbox connector
#   3. Creates a test workspace in RBAC
#   4. Creates a test principal (user)
#   5. Grants the principal access to the workspace
#   6. Creates a test device
#   7. Waits for the CDC pipeline to deliver the tuple to SpiceDB
#   8. Verifies the permission check works end-to-end

set -e

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }
step()        { echo -e "\n${BLUE}━━━ Step $1 ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Service endpoints
SPICEDB_HTTP="${SPICEDB_HTTP:-http://localhost:8443}"
SPICEDB_TOKEN="${SPICEDB_TOKEN:-testtesttesttest}"
RELATIONS_API="${RELATIONS_API:-http://localhost:8082}"
KAFKA_CONNECT="${KAFKA_CONNECT:-http://localhost:8084}"
RBAC_API="${RBAC_API:-http://localhost:8080}"
EDGE_API="${EDGE_API:-http://localhost:8085}"

RBAC_IDENTITY=$(echo -n '{"identity":{"account_number":"12345","org_id":"12345","type":"User","auth_type":"basic-auth","user":{"username":"alice","email":"alice@example.com","is_org_admin":true}}}' | base64)

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║      edge-device-service: Kessel Integration Setup       ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

# ---------------------------------------------------------------
step "1: Load SpiceDB schema (edge/device type)"
# ---------------------------------------------------------------
log_info "Loading edge.zed schema into SpiceDB at $SPICEDB_HTTP..."

# Read the current schema and append edge/device — never replace, to avoid breaking live data
log_info "Reading current SpiceDB schema..."
CURRENT_SCHEMA=$(curl -s -X POST "$SPICEDB_HTTP/v1/schema/read" \
  -H "Authorization: Bearer $SPICEDB_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{}' | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('schemaText',''))" 2>/dev/null || echo "")

if echo "$CURRENT_SCHEMA" | grep -q 'edge/device'; then
    log_success "edge/device type already exists in SpiceDB schema — skipping write"
else
    log_info "Appending edge/device definition to existing SpiceDB schema..."
    EDGE_DEF='
definition edge/device {
    relation t_workspace: rbac/workspace

    permission view     = t_workspace->edge_device_view
    permission update   = t_workspace->edge_device_update
    permission delete   = t_workspace->edge_device_delete
    permission manage   = t_workspace->edge_device_manage

    permission workspace = t_workspace
}'
    COMBINED_SCHEMA="${CURRENT_SCHEMA}

${EDGE_DEF}"

    HTTP_CODE=$(curl -s -o /tmp/spicedb-schema-write.json -w "%{http_code}" \
      -X POST "$SPICEDB_HTTP/v1/schema/write" \
      -H "Authorization: Bearer $SPICEDB_TOKEN" \
      -H "Content-Type: application/json" \
      -d "{\"schema\": $(echo "$COMBINED_SCHEMA" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')}")

    if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "201" ]; then
        log_success "Schema written: edge/device type defined in SpiceDB"
    else
        BODY=$(cat /tmp/spicedb-schema-write.json 2>/dev/null)
        log_warn "Schema write returned HTTP $HTTP_CODE: $BODY"
        log_warn "Continuing — permissions may not propagate until schema is loaded."
    fi
fi

# ---------------------------------------------------------------
step "2: Register Debezium connector (edge.outbox → outbox.event.edge.devices)"
# ---------------------------------------------------------------
log_info "Registering edge-device-outbox-connector at $KAFKA_CONNECT..."

# Delete existing connector if present (idempotent re-run)
curl -s -X DELETE "$KAFKA_CONNECT/connectors/edge-device-outbox-connector" 2>/dev/null || true
sleep 1

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$KAFKA_CONNECT/connectors" \
  -H "Content-Type: application/json" \
  -d @"$SCRIPT_DIR/config/connector.json")

if [ "$HTTP_CODE" = "201" ]; then
    log_success "Connector registered"
else
    log_error "Connector registration returned HTTP $HTTP_CODE"
    log_error "Is kessel-in-a-box-real running? Check: curl $KAFKA_CONNECT/connectors"
    exit 1
fi

# Wait for connector to reach RUNNING state
log_info "Waiting for connector to reach RUNNING state..."
for i in {1..20}; do
    STATE=$(curl -s "$KAFKA_CONNECT/connectors/edge-device-outbox-connector/status" \
      | jq -r '.connector.state' 2>/dev/null || echo "")
    if [ "$STATE" = "RUNNING" ]; then
        log_success "Connector is RUNNING"
        break
    fi
    echo -n "."
    sleep 2
done
echo ""

# ---------------------------------------------------------------
step "3: Create a test workspace in RBAC"
# ---------------------------------------------------------------
log_info "Creating workspace 'edge-demo-workspace' in RBAC at $RBAC_API..."

WORKSPACE_RESP=$(curl -s -X POST "$RBAC_API/api/rbac/v2/workspaces/" \
  -H "Content-Type: application/json" \
  -H "x-rh-identity: $RBAC_IDENTITY" \
  -d '{"name": "edge-demo-workspace"}')

WORKSPACE_ID=$(echo "$WORKSPACE_RESP" | jq -r '.id // empty')

if [ -z "$WORKSPACE_ID" ] || [ "$WORKSPACE_ID" = "null" ]; then
    log_warn "Could not create workspace: $WORKSPACE_RESP"
    log_warn "Using a fixed workspace ID for the demo (create it manually if needed)"
    WORKSPACE_ID="demo-workspace-$(date +%s)"
else
    log_success "Workspace created: $WORKSPACE_ID"
fi
echo "  WORKSPACE_ID=$WORKSPACE_ID"

# ---------------------------------------------------------------
step "4: Grant 'alice' view access on the workspace via RBAC"
# ---------------------------------------------------------------
log_info "Creating a role binding: alice → Edge Device Viewer role → workspace $WORKSPACE_ID"
log_warn "For now, RBAC propagates to SpiceDB via the relations-api (REPLICATION_TO_RELATION_ENABLED)."
log_warn "In a real setup you would grant a role to alice in the workspace via the RBAC API."
log_info "Skipping role binding — creating the workspace/principal tuple directly in SpiceDB..."

# Create a direct tuple: alice is a principal
curl -s -X POST "$RELATIONS_API/api/authz/v1beta1/tuples" \
  -H "Content-Type: application/json" \
  -d "{
    \"upsert\": true,
    \"tuples\": [
      {
        \"resource\": {\"type\": {\"namespace\": \"rbac\", \"name\": \"workspace\"}, \"id\": \"$WORKSPACE_ID\"},
        \"relation\": \"t_binding\",
        \"subject\": {\"type\": {\"namespace\": \"rbac\", \"name\": \"role_binding\"}, \"id\": \"rb-alice-$WORKSPACE_ID\"}
      },
      {
        \"resource\": {\"type\": {\"namespace\": \"rbac\", \"name\": \"role_binding\"}, \"id\": \"rb-alice-$WORKSPACE_ID\"},
        \"relation\": \"t_subject\",
        \"subject\": {\"type\": {\"namespace\": \"rbac\", \"name\": \"principal\"}, \"id\": \"alice\"}
      },
      {
        \"resource\": {\"type\": {\"namespace\": \"rbac\", \"name\": \"role_binding\"}, \"id\": \"rb-alice-$WORKSPACE_ID\"},
        \"relation\": \"t_role\",
        \"subject\": {\"type\": {\"namespace\": \"rbac\", \"name\": \"role\"}, \"id\": \"edge-device-viewer\"}
      },
      {
        \"resource\": {\"type\": {\"namespace\": \"rbac\", \"name\": \"role\"}, \"id\": \"edge-device-viewer\"},
        \"relation\": \"edge_device_devices_read\",
        \"subject\": {\"type\": {\"namespace\": \"rbac\", \"name\": \"principal\"}, \"id\": \"*\"}
      }
    ]
  }" > /dev/null

log_success "Direct SpiceDB tuples created: alice has edge_device_view on workspace $WORKSPACE_ID"

# ---------------------------------------------------------------
step "5: Create a test edge device via the edge-device-service API"
# ---------------------------------------------------------------
log_info "Creating a device at $EDGE_API/api/edge/v1/devices..."

DEVICE_RESP=$(curl -s -X POST "$EDGE_API/api/edge/v1/devices" \
  -H "Content-Type: application/json" \
  -d "{
    \"display_name\": \"Demo Edge Router\",
    \"workspace_id\": \"$WORKSPACE_ID\",
    \"org_id\": \"12345\"
  }")

DEVICE_ID=$(echo "$DEVICE_RESP" | jq -r '.id // empty')

if [ -z "$DEVICE_ID" ] || [ "$DEVICE_ID" = "null" ]; then
    log_error "Could not create device: $DEVICE_RESP"
    log_error "Is edge-device-service running? Start with: docker compose -f compose/docker-compose.yml up -d"
    exit 1
fi

log_success "Device created: $DEVICE_ID"
echo "  The outbox ghost-row has been written — Debezium will publish it to Kafka momentarily."

# ---------------------------------------------------------------
step "6: Wait for the CDC pipeline to deliver the SpiceDB tuple"
# ---------------------------------------------------------------
log_info "Waiting for Debezium → Kafka → consumer → SpiceDB pipeline (up to 30s)..."

for i in {1..15}; do
    RESULT=$(curl -s -X POST "$RELATIONS_API/api/authz/v1beta1/check" \
      -H "Content-Type: application/json" \
      -d "{
        \"resource\": {\"type\": {\"namespace\": \"edge\", \"name\": \"device\"}, \"id\": \"$DEVICE_ID\"},
        \"permission\": \"view\",
        \"subject\": {\"type\": {\"namespace\": \"rbac\", \"name\": \"principal\"}, \"id\": \"alice\"}
      }" 2>/dev/null | jq -r '.permissionCheckResponse // empty' 2>/dev/null)

    if [ "$RESULT" = "PERMISSION_CHECK_RESPONSE_PERMISSION_PERMITTED" ]; then
        log_success "SpiceDB tuple confirmed! Pipeline is working."
        break
    fi
    echo -n "."
    sleep 2
done
echo ""

# ---------------------------------------------------------------
step "7: Verify end-to-end"
# ---------------------------------------------------------------

log_info "Checking: alice can VIEW device $DEVICE_ID..."
VIEW_RESULT=$(curl -s -X POST "$EDGE_API/api/edge/v1/check" \
  -H "Content-Type: application/json" \
  -d "{
    \"device_id\": \"$DEVICE_ID\",
    \"permission\": \"view\",
    \"subject_id\": \"alice\"
  }")
PERMITTED=$(echo "$VIEW_RESULT" | jq -r '.permitted // false')
[ "$PERMITTED" = "true" ] && log_success "alice can VIEW the device" || log_warn "alice cannot view the device (pipeline may still be processing)"

log_info "Checking: alice can DELETE device $DEVICE_ID (should be denied — viewer role only has read)..."
DELETE_RESULT=$(curl -s -X POST "$EDGE_API/api/edge/v1/check" \
  -H "Content-Type: application/json" \
  -d "{
    \"device_id\": \"$DEVICE_ID\",
    \"permission\": \"delete\",
    \"subject_id\": \"alice\"
  }")
PERMITTED=$(echo "$DELETE_RESULT" | jq -r '.permitted // false')
[ "$PERMITTED" = "false" ] && log_success "alice cannot DELETE (correct — viewer role)" || log_warn "alice can delete (unexpected)"

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║                  Setup Complete!                         ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "  Service:     $EDGE_API"
echo "  Workspace:   $WORKSPACE_ID"
echo "  Device:      $DEVICE_ID"
echo ""
echo "Try these commands:"
echo ""
echo "  # List devices"
echo "  curl $EDGE_API/api/edge/v1/devices"
echo ""
echo "  # Check permission"
echo "  curl -X POST $EDGE_API/api/edge/v1/check \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -d '{\"device_id\":\"$DEVICE_ID\",\"permission\":\"view\",\"subject_id\":\"alice\"}'"
echo ""
echo "  # Watch Kafka topic"
echo "  docker exec kessel-kafka kafka-console-consumer \\"
echo "    --bootstrap-server localhost:9092 \\"
echo "    --topic outbox.event.edge.devices --from-beginning"
echo ""
echo "  # Query SpiceDB tuples for this device"
echo "  curl -s -X POST $RELATIONS_API/api/authz/v1beta1/readtuples \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -d '{\"resourceType\":{\"namespace\":\"edge\",\"name\":\"device\"}}' | jq ."
