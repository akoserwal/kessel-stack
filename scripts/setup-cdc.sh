#!/usr/bin/env bash
# setup-cdc.sh — Register Debezium connectors matching the stage two-stage outbox pipeline
#
# Stage 1 (HBI → kessel-inventory-api):
#   postgres-inventory hbi.outbox → hbi-outbox-connector → outbox.event.hbi.hosts
#   → inventory-consumer → kessel-inventory-api gRPC :9000
#
# Stage 2 (kessel-inventory-api → Relations API → SpiceDB):
#   postgres-kessel-inventory public.outbox_events → kessel-inventory-api-connector
#   → outbox.event.kessel.tuples → kessel-inventory-api internal consumer → Relations API

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

CONNECT_URL="${KAFKA_CONNECT_URL:-http://localhost:8084}"

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Setting up CDC Pipeline (two-stage outbox — stage arch)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo

# Wait for Kafka Connect to be ready
log_info "Waiting for Kafka Connect to be ready at ${CONNECT_URL}..."
max_attempts=30
attempt=0
until curl -sf "${CONNECT_URL}/" > /dev/null 2>&1; do
    attempt=$((attempt + 1))
    if [[ $attempt -ge $max_attempts ]]; then
        log_error "Kafka Connect not ready after ${max_attempts} attempts — is kafka-connect running?"
        exit 1
    fi
    sleep 2
done
log_success "Kafka Connect is ready"
echo

register_connector() {
    local name="$1"
    local config_file="$2"

    log_info "Registering connector: ${name}"

    # Delete existing connector if present (idempotent re-run)
    if curl -sf "${CONNECT_URL}/connectors/${name}" > /dev/null 2>&1; then
        log_warn "Connector '${name}' already exists — deleting and re-creating"
        curl -sf -X DELETE "${CONNECT_URL}/connectors/${name}" > /dev/null
        sleep 2
    fi

    # Register connector
    local http_code
    http_code=$(curl -sf -o /dev/null -w "%{http_code}" \
        -X POST "${CONNECT_URL}/connectors" \
        -H "Content-Type: application/json" \
        -d @"${config_file}")

    if [[ "$http_code" != "201" ]]; then
        log_error "Failed to register '${name}' (HTTP ${http_code})"
        log_error "Response from Kafka Connect:"
        curl -sf -X POST "${CONNECT_URL}/connectors" \
            -H "Content-Type: application/json" \
            -d @"${config_file}" || true
        return 1
    fi

    sleep 3

    # Check connector state
    local state
    state=$(curl -sf "${CONNECT_URL}/connectors/${name}/status" \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['connector']['state'])" 2>/dev/null || echo "UNKNOWN")

    if [[ "$state" == "RUNNING" ]]; then
        log_success "Connector '${name}' is RUNNING"
    else
        log_warn "Connector '${name}' state: ${state} (may still be starting)"
        curl -sf "${CONNECT_URL}/connectors/${name}/status" | python3 -m json.tool 2>/dev/null || true
    fi
    echo
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEBEZIUM_DIR="${SCRIPT_DIR}/../config/debezium"

# Pre-create CDC topics with compression.type=uncompressed.
# The Kafka broker may default to snappy (KAFKA_COMPRESSION_TYPE=snappy), which
# the Python rbac-kafka-consumer cannot decode (no python-snappy in the image).
# Pre-creating topics with explicit uncompressed config prevents auto-creation
# with the broker default.
ensure_topic_uncompressed() {
    local topic="$1"
    local partitions="${2:-3}"

    # Check if topic exists
    if docker exec kessel-kafka kafka-topics \
           --bootstrap-server localhost:9092 --list 2>/dev/null \
         | grep -qx "$topic"; then
        # Topic exists — alter compression.type to uncompressed
        docker exec kessel-kafka kafka-configs \
            --bootstrap-server localhost:9092 \
            --alter --entity-type topics --entity-name "$topic" \
            --add-config "compression.type=uncompressed" > /dev/null 2>&1
        log_info "Topic '${topic}' compression.type set to uncompressed"
    else
        # Create topic with explicit uncompressed config
        docker exec kessel-kafka kafka-topics \
            --bootstrap-server localhost:9092 \
            --create --if-not-exists \
            --topic "$topic" \
            --partitions "$partitions" \
            --replication-factor 1 \
            --config "compression.type=uncompressed" > /dev/null 2>&1
        log_info "Topic '${topic}' created with compression.type=uncompressed"
    fi
}

log_info "Pre-creating CDC topics with compression.type=uncompressed..."
ensure_topic_uncompressed "outbox.event.relations-replication-event"
echo

# RBAC: management_outbox → outbox.event.relations-replication-event
register_connector "rbac-postgres-connector" "${DEBEZIUM_DIR}/rbac-connector.json"

# Stage 1: HBI outbox → outbox.event.hbi.hosts
register_connector "hbi-outbox-connector" "${DEBEZIUM_DIR}/hbi-outbox-connector.json"

# Stage 2: kessel-inventory-api outbox → outbox.event.kessel.tuples / outbox.event.kessel.resources
register_connector "kessel-inventory-api-connector" "${DEBEZIUM_DIR}/kessel-inventory-api-connector.json"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_success "CDC pipeline setup complete!"
echo
echo "  Connectors registered:"
echo "    rbac-postgres-connector        → outbox.event.relations-replication-event"
echo "    hbi-outbox-connector           → outbox.event.hbi.hosts"
echo "    kessel-inventory-api-connector → outbox.event.kessel.tuples"
echo "                                    outbox.event.kessel.resources"
echo
echo "  Check connector status:"
echo "    curl ${CONNECT_URL}/connectors/rbac-postgres-connector/status"
echo "    curl ${CONNECT_URL}/connectors/hbi-outbox-connector/status"
echo "    curl ${CONNECT_URL}/connectors/kessel-inventory-api-connector/status"
echo
echo "  List all connectors:"
echo "    curl ${CONNECT_URL}/connectors | python3 -m json.tool"
echo
echo "  Monitor Kafka topics:"
echo "    docker exec kessel-kafka kafka-console-consumer \\"
echo "      --bootstrap-server localhost:9092 \\"
echo "      --topic outbox.event.relations-replication-event --from-beginning"
echo "    docker exec kessel-kafka kafka-console-consumer \\"
echo "      --bootstrap-server localhost:9092 \\"
echo "      --topic outbox.event.hbi.hosts --from-beginning"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
