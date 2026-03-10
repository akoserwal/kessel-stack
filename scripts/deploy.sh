#!/bin/bash
# Kessel Stack: Master Deployment Script
# Fully automated deployment from scratch

set -e

# Color codes
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Logging functions
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

# Detect container runtime and set DOCKER_HOST_IP for extra_hosts
# Podman doesn't support "host-gateway", so resolve the host IP explicitly
if [ -z "${DOCKER_HOST_IP:-}" ]; then
    if command -v podman &>/dev/null || docker info 2>/dev/null | grep -qi podman; then
        DOCKER_HOST_IP=$(podman run --rm alpine sh -c 'getent hosts host.containers.internal | cut -d" " -f1' 2>/dev/null || echo "")
        if [ -z "$DOCKER_HOST_IP" ]; then
            DOCKER_HOST_IP="192.168.127.254"  # Podman default on macOS
        fi
        export DOCKER_HOST_IP
    fi
fi

# Banner
cat << "EOF"
╔════════════════════════════════════════════════════════════╗
║                                                            ║
║           Kessel Stack Deployment Script                ║
║                                                            ║
║  Automated deployment of complete Kessel stack             ║
║                                                            ║
╚════════════════════════════════════════════════════════════╝
EOF

echo ""

# Check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."

    # Check Docker
    if ! command -v docker &> /dev/null; then
        log_error "Docker is not installed"
        echo "Install Docker from: https://docs.docker.com/get-docker/"
        exit 1
    fi

    # Check Docker Compose
    if ! docker compose version &> /dev/null; then
        log_error "Docker Compose V2 is not installed"
        echo "Install Docker Compose from: https://docs.docker.com/compose/install/"
        exit 1
    fi

    # Check jq
    if ! command -v jq &> /dev/null; then
        log_warn "jq is not installed (optional but recommended)"
        echo "Install: brew install jq (macOS) or apt-get install jq (Linux)"
    fi

    # Check Docker daemon
    if ! docker ps &> /dev/null; then
        log_error "Docker daemon is not running"
        echo "Start Docker Desktop or Docker daemon"
        exit 1
    fi

    log_success "All prerequisites met"
}

# Clean up existing deployment
cleanup_existing() {
    log_info "Cleaning up any existing deployment..."

    # Stop and remove containers
    docker compose -f "$PROJECT_ROOT/compose/docker-compose.yml" \
                   -f "$PROJECT_ROOT/compose/docker-compose.kessel.yml" \
                   -f "$PROJECT_ROOT/compose/docker-compose.kafka.yml" \
                   -f "$PROJECT_ROOT/compose/docker-compose.insights.yml" \
                   down --remove-orphans 2>/dev/null || true

    # Remove volumes (optional - prompt user)
    if [ "${CLEAN_VOLUMES:-false}" = "true" ]; then
        log_warn "Removing all data volumes..."
        docker volume rm kessel-postgres-rbac-data 2>/dev/null || true
        docker volume rm kessel-postgres-inventory-data 2>/dev/null || true
        docker volume rm kessel-postgres-kessel-inventory-data 2>/dev/null || true
        docker volume rm kessel-postgres-spicedb-data 2>/dev/null || true
        docker volume rm zookeeper-data 2>/dev/null || true
        docker volume rm zookeeper-logs 2>/dev/null || true
        docker volume rm kafka-data 2>/dev/null || true
    fi

    # Also clean up observability containers if requested
    if [ "${WITH_OBSERVABILITY:-false}" = "true" ]; then
        docker compose -f "$PROJECT_ROOT/compose/docker-compose.yml" \
                       -f "$PROJECT_ROOT/compose/docker-compose.observability.yml" \
                       down --remove-orphans 2>/dev/null || true
    fi

    # Kill processes on conflicting ports
    for port in 2181 5432 5433 5434 5435 8080 8081 8082 8083 8084 8086 9001 9002 9092 9101 50051 8443 9090; do
        pid=$(lsof -ti:$port 2>/dev/null || true)
        if [ -n "$pid" ]; then
            log_warn "Killing process on port $port (PID: $pid)"
            kill -9 $pid 2>/dev/null || true
        fi
    done

    log_success "Cleanup complete"
}

# Create Docker network
create_network() {
    log_info "Creating Docker network..."

    if docker network inspect kessel-network &> /dev/null; then
        log_info "Network kessel-network already exists"
    else
        docker network create kessel-network
        log_success "Network created: kessel-network"
    fi
}

# Deploy Phase 5: Kessel Services
deploy_phase5() {
    log_info "=========================================="
    log_info "Phase 5: Deploying Kessel Services"
    log_info "=========================================="

    cd "$PROJECT_ROOT"

    # Start PostgreSQL databases (4 instances: rbac, hbi, kessel-inventory, spicedb)
    log_info "Starting PostgreSQL instances..."
    docker compose -f compose/docker-compose.yml up -d \
        postgres-rbac postgres-inventory postgres-kessel-inventory postgres-spicedb

    # Wait for databases
    log_info "Waiting for databases to be ready..."
    for i in {1..30}; do
        if docker exec kessel-postgres-rbac pg_isready -U rbac &>/dev/null && \
           docker exec kessel-postgres-inventory pg_isready -U inventory &>/dev/null && \
           docker exec kessel-postgres-kessel-inventory pg_isready -U inventory &>/dev/null && \
           docker exec kessel-postgres-spicedb pg_isready -U spicedb &>/dev/null; then
            log_success "All databases ready"
            break
        fi
        echo -n "."
        sleep 2
    done
    echo ""
    if ! docker exec kessel-postgres-rbac pg_isready -U rbac &>/dev/null; then
        log_error "Databases did not become ready in time — aborting"
        exit 1
    fi

    # Run SpiceDB migration
    log_info "Running SpiceDB migration..."
    docker compose -f compose/docker-compose.yml up spicedb-migrate
    sleep 2

    # Start SpiceDB
    log_info "Starting SpiceDB..."
    docker compose -f compose/docker-compose.yml up -d spicedb

    # Wait for SpiceDB
    log_info "Waiting for SpiceDB to be ready..."
    for i in {1..60}; do
        if curl -sf http://localhost:8443/healthz &>/dev/null; then
            log_success "SpiceDB ready"
            break
        fi
        echo -n "."
        sleep 2
    done
    echo ""

    # Build and start Kessel Relations API
    if [ "${SKIP_RELATIONS_API:-false}" = "true" ]; then
        log_warn "SKIP_RELATIONS_API=true — Skipping kessel-relations-api"
        log_warn "  Run it locally on port 8000 (mapped to host port 8082)"
        log_warn "  Other containers will route to host.docker.internal"
    else
        log_info "Starting Kessel Relations API..."
        docker compose -f compose/docker-compose.yml \
                       -f compose/docker-compose.kessel.yml \
                       up -d kessel-relations-api

        # Wait for Relations API — use POST (endpoint is write-only); drop -f so any
        # HTTP response (including 400) means the server is up.
        log_info "Waiting for Relations API to be ready..."
        for i in {1..60}; do
            if curl -s -o /dev/null -X POST \
                    -H 'Content-Type: application/json' \
                    -d '{"tuples":[]}' \
                    http://localhost:${RELATIONS_GRPC_PORT:-8082}/api/authz/v1beta1/tuples 2>/dev/null; then
                log_success "Relations API ready"
                break
            fi
            echo -n "."
            sleep 2
        done
        echo ""
    fi

    # Build and start Kessel Inventory API
    if [ "${SKIP_INVENTORY_API:-false}" = "true" ]; then
        log_warn "SKIP_INVENTORY_API=true — Skipping kessel-inventory-api"
        log_warn "  Run it locally on port 8000 (mapped to host port 8083)"
        log_warn "  Other containers will route to host.docker.internal"
    else
        log_info "Starting Kessel Inventory API..."
        # --no-deps: skip the compose-level service_healthy check on kessel-relations-api.
        # We already waited for it above; this prevents a false failure when its Docker
        # healthcheck disagrees with our explicit wait (e.g. stale SpiceDB data).
        docker compose -f compose/docker-compose.yml \
                       -f compose/docker-compose.kessel.yml \
                       up -d --no-deps kessel-inventory-api

        # Wait for Inventory API
        log_info "Waiting for Inventory API to be ready..."
        for i in {1..60}; do
            if curl -sf http://localhost:${KESSEL_INVENTORY_PORT:-8083}/api/kessel/v1/livez &>/dev/null; then
                log_success "Inventory API ready"
                break
            fi
            echo -n "."
            sleep 2
        done
        echo ""
    fi

    log_success "Phase 5 deployment complete!"
}

# Deploy Phase 6: CDC Infrastructure (Kafka, Debezium, Consumers)
deploy_phase6() {
    log_info "=========================================="
    log_info "Phase 6: Deploying CDC Infrastructure"
    log_info "=========================================="

    cd "$PROJECT_ROOT"

    # Start Zookeeper
    log_info "Starting Zookeeper..."
    docker compose -f compose/docker-compose.yml \
                   -f compose/docker-compose.kessel.yml \
                   -f compose/docker-compose.kafka.yml \
                   up -d zookeeper

    # Wait for Zookeeper — use cub zk-ready (available in confluentinc images,
    # avoids nc/ruok 4lw whitelist issues)
    log_info "Waiting for Zookeeper to be ready..."
    for i in {1..30}; do
        if docker exec kessel-zookeeper bash -c "cub zk-ready localhost:2181 5 2>/dev/null"; then
            log_success "Zookeeper ready"
            break
        fi
        echo -n "."
        sleep 2
    done
    echo ""

    # Start Kafka
    log_info "Starting Kafka..."
    docker compose -f compose/docker-compose.yml \
                   -f compose/docker-compose.kessel.yml \
                   -f compose/docker-compose.kafka.yml \
                   up -d kafka

    # Wait for Kafka
    log_info "Waiting for Kafka to be ready..."
    for i in {1..60}; do
        if docker exec kessel-kafka kafka-broker-api-versions --bootstrap-server localhost:9092 &>/dev/null; then
            log_success "Kafka ready"
            break
        fi
        echo -n "."
        sleep 2
    done
    echo ""

    # Start Kafka Connect (Debezium)
    log_info "Starting Kafka Connect (Debezium)..."
    docker compose -f compose/docker-compose.yml \
                   -f compose/docker-compose.kessel.yml \
                   -f compose/docker-compose.kafka.yml \
                   up -d kafka-connect

    # Wait for Kafka Connect
    log_info "Waiting for Kafka Connect to be ready..."
    for i in {1..60}; do
        if curl -sf http://localhost:8084/connectors &>/dev/null; then
            log_success "Kafka Connect ready"
            break
        fi
        echo -n "."
        sleep 2
    done
    echo ""

    # Register Debezium connectors (two-stage outbox pipeline matching stage architecture)
    log_info "Registering Debezium CDC connectors..."
    "$SCRIPT_DIR/setup-cdc.sh" || log_warn "CDC connector registration failed — run scripts/setup-cdc.sh manually"

    # Start CDC Consumers (they depend on kessel-relations-api and kessel-inventory-api)
    # Use --no-deps when the API dependency is skipped (running locally)
    log_info "Starting CDC consumers..."
    if [ "${SKIP_RELATIONS_API:-false}" = "true" ]; then
        log_info "Starting rbac-consumer with --no-deps (relations-api is local)..."
        docker compose -f compose/docker-compose.yml \
                       -f compose/docker-compose.kessel.yml \
                       -f compose/docker-compose.kafka.yml \
                       up -d --no-deps rbac-consumer
    else
        docker compose -f compose/docker-compose.yml \
                       -f compose/docker-compose.kessel.yml \
                       -f compose/docker-compose.kafka.yml \
                       up -d rbac-consumer
    fi

    if [ "${SKIP_INVENTORY_API:-false}" = "true" ]; then
        log_info "Starting inventory-consumer with --no-deps (inventory-api is local)..."
        docker compose -f compose/docker-compose.yml \
                       -f compose/docker-compose.kessel.yml \
                       -f compose/docker-compose.kafka.yml \
                       up -d --no-deps inventory-consumer
    else
        docker compose -f compose/docker-compose.yml \
                       -f compose/docker-compose.kessel.yml \
                       -f compose/docker-compose.kafka.yml \
                       up -d inventory-consumer
    fi

    log_info "Waiting for CDC consumers to be ready..."
    sleep 5

    # Start Kafka UI (optional)
    log_info "Starting Kafka UI..."
    docker compose -f compose/docker-compose.yml \
                   -f compose/docker-compose.kessel.yml \
                   -f compose/docker-compose.kafka.yml \
                   up -d kafka-ui 2>/dev/null || log_warn "Kafka UI not available (optional)"

    log_success "Phase 6 deployment complete!"
}

# Deploy Phase 7: Insights Services
deploy_phase7() {
    log_info "=========================================="
    log_info "Phase 7: Deploying Insights Services"
    log_info "=========================================="

    cd "$PROJECT_ROOT"

    # Start insights-rbac (real image: quay.io/cloudservices/rbac)
    if [ "${SKIP_INSIGHTS_RBAC:-false}" = "true" ]; then
        log_warn "SKIP_INSIGHTS_RBAC=true — Skipping insights-rbac"
        log_warn "  Run it locally on port 8080"
    else
        log_info "Starting insights-rbac..."
        docker compose -f compose/docker-compose.yml \
                       -f compose/docker-compose.kessel.yml \
                       -f compose/docker-compose.kafka.yml \
                       -f compose/docker-compose.insights.yml \
                       up -d insights-rbac

        # Wait for insights-rbac
        log_info "Waiting for insights-rbac to be ready..."
        for i in {1..60}; do
            if curl -sf http://localhost:8080/api/rbac/v1/status/ &>/dev/null; then
                log_success "insights-rbac ready"
                break
            fi
            echo -n "."
            sleep 2
        done
        echo ""
    fi

    # Start insights-host-inventory (real image: quay.io/cloudservices/insights-inventory)
    if [ "${SKIP_INSIGHTS_HOST_INVENTORY:-false}" = "true" ]; then
        log_warn "SKIP_INSIGHTS_HOST_INVENTORY=true — Skipping insights-host-inventory"
        log_warn "  Run it locally on port 8081"
    else
        # Use --no-deps if inventory-api is skipped (running locally)
        local nodeps_flag=""
        if [ "${SKIP_INVENTORY_API:-false}" = "true" ]; then
            nodeps_flag="--no-deps"
            log_info "Using --no-deps for insights-host-inventory (inventory-api is local)"
        fi

        log_info "Starting insights-host-inventory..."
        docker compose -f compose/docker-compose.yml \
                       -f compose/docker-compose.kessel.yml \
                       -f compose/docker-compose.kafka.yml \
                       -f compose/docker-compose.insights.yml \
                       up -d $nodeps_flag insights-host-inventory

        # Wait for insights-host-inventory
        log_info "Waiting for insights-host-inventory to be ready..."
        for i in {1..60}; do
            if curl -sf http://localhost:8081/health &>/dev/null; then
                log_success "insights-host-inventory ready"
                break
            fi
            echo -n "."
            sleep 2
        done
        echo ""
    fi

    log_success "Phase 7 deployment complete!"
}

# Deploy Observability stack (Prometheus, Grafana, Alertmanager)
deploy_observability() {
    log_info "=========================================="
    log_info "Deploying Observability Stack"
    log_info "=========================================="

    cd "$PROJECT_ROOT"

    # Start Prometheus
    log_info "Starting Prometheus..."
    docker compose -f compose/docker-compose.yml \
                   -f compose/docker-compose.observability.yml \
                   up -d prometheus

    # Wait for Prometheus
    log_info "Waiting for Prometheus to be ready..."
    for i in {1..30}; do
        if curl -sf http://localhost:${PROMETHEUS_PORT:-9091}/-/healthy &>/dev/null; then
            log_success "Prometheus ready"
            break
        fi
        echo -n "."
        sleep 2
    done
    echo ""

    # Start Grafana (depends on Prometheus)
    log_info "Starting Grafana..."
    docker compose -f compose/docker-compose.yml \
                   -f compose/docker-compose.observability.yml \
                   up -d grafana

    # Wait for Grafana
    log_info "Waiting for Grafana to be ready..."
    for i in {1..30}; do
        if curl -sf http://localhost:${GRAFANA_PORT:-3000}/api/health &>/dev/null; then
            log_success "Grafana ready"
            break
        fi
        echo -n "."
        sleep 2
    done
    echo ""

    # Start Alertmanager
    log_info "Starting Alertmanager..."
    docker compose -f compose/docker-compose.yml \
                   -f compose/docker-compose.observability.yml \
                   up -d alertmanager

    # Start Node Exporter
    log_info "Starting Node Exporter..."
    docker compose -f compose/docker-compose.yml \
                   -f compose/docker-compose.observability.yml \
                   up -d node-exporter 2>/dev/null || log_warn "Node Exporter failed (optional, may not work on macOS)"

    # Build and start Health Exporter
    log_info "Starting Health Exporter..."
    docker compose -f compose/docker-compose.yml \
                   -f compose/docker-compose.observability.yml \
                   up -d health-exporter 2>/dev/null || log_warn "Health Exporter failed to start (optional)"

    log_success "Observability stack deployment complete!"
}

# Verify deployment
verify_deployment() {
    log_info "=========================================="
    log_info "Verifying Deployment"
    log_info "=========================================="

    local all_healthy=true

    # Check containers
    log_info "Checking containers..."
    local expected_containers=(
        "kessel-postgres-rbac"
        "kessel-postgres-inventory"
        "kessel-postgres-kessel-inventory"
        "kessel-postgres-spicedb"
        "kessel-spicedb"
        "kessel-zookeeper"
        "kessel-kafka"
        "kessel-kafka-connect"
        "kessel-rbac-consumer"
        "kessel-inventory-consumer"
    )

    # Conditionally add skippable services
    [ "${SKIP_RELATIONS_API:-false}" != "true" ] && expected_containers+=("kessel-relations-api")
    [ "${SKIP_INVENTORY_API:-false}" != "true" ] && expected_containers+=("kessel-inventory-api")
    [ "${SKIP_INSIGHTS_RBAC:-false}" != "true" ] && expected_containers+=("insights-rbac")
    [ "${SKIP_INSIGHTS_HOST_INVENTORY:-false}" != "true" ] && expected_containers+=("insights-host-inventory")

    # Add observability containers if enabled
    if [ "${WITH_OBSERVABILITY:-false}" = "true" ]; then
        expected_containers+=("kessel-prometheus" "kessel-grafana" "kessel-alertmanager")
    fi

    for container in "${expected_containers[@]}"; do
        if docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
            echo -e "  ✓ ${container}"
        else
            echo -e "  ${RED}✗${NC} ${container} (not running)"
            all_healthy=false
        fi
    done

    echo ""
    log_info "Checking service health..."

    # Check services
    if curl -sf http://localhost:8443/healthz | grep -q "SERVING"; then
        echo "  ✓ SpiceDB: SERVING"
    else
        echo -e "  ${RED}✗${NC} SpiceDB: NOT RESPONDING"
        all_healthy=false
    fi

    if [ "${SKIP_RELATIONS_API:-false}" = "true" ]; then
        echo "  - Kessel Relations API: SKIPPED (local dev mode)"
    elif curl -s -o /dev/null -X POST \
              -H 'Content-Type: application/json' \
              -d '{"tuples":[]}' \
              http://localhost:${RELATIONS_GRPC_PORT:-8082}/api/authz/v1beta1/tuples 2>/dev/null; then
        echo "  ✓ Kessel Relations API: SERVING"
    else
        echo -e "  ${RED}✗${NC} Kessel Relations API: NOT RESPONDING"
        all_healthy=false
    fi

    if [ "${SKIP_INVENTORY_API:-false}" = "true" ]; then
        echo "  - Kessel Inventory API: SKIPPED (local dev mode)"
    elif curl -sf http://localhost:${KESSEL_INVENTORY_PORT:-8083}/api/kessel/v1/livez &>/dev/null; then
        echo "  ✓ Kessel Inventory API: SERVING"
    else
        echo -e "  ${RED}✗${NC} Kessel Inventory API: NOT RESPONDING"
        all_healthy=false
    fi

    if [ "${SKIP_INSIGHTS_RBAC:-false}" = "true" ]; then
        echo "  - Insights RBAC: SKIPPED (local dev mode)"
    elif curl -sf http://localhost:8080/api/rbac/v1/status/ &>/dev/null; then
        echo "  ✓ Insights RBAC: healthy"
    else
        echo -e "  ${RED}✗${NC} Insights RBAC: NOT RESPONDING"
        all_healthy=false
    fi

    if [ "${SKIP_INSIGHTS_HOST_INVENTORY:-false}" = "true" ]; then
        echo "  - Insights Host Inventory: SKIPPED (local dev mode)"
    elif curl -sf http://localhost:8081/health; then
        echo "  ✓ Insights Host Inventory: healthy"
    else
        echo -e "  ${RED}✗${NC} Insights Host Inventory: NOT RESPONDING"
        all_healthy=false
    fi

    if [ "${WITH_OBSERVABILITY:-false}" = "true" ]; then
        echo ""
        log_info "Checking observability services..."

        if curl -sf http://localhost:${PROMETHEUS_PORT:-9091}/-/healthy &>/dev/null; then
            echo "  ✓ Prometheus: healthy"
        else
            echo -e "  ${RED}✗${NC} Prometheus: NOT RESPONDING"
            all_healthy=false
        fi

        if curl -sf http://localhost:${GRAFANA_PORT:-3000}/api/health &>/dev/null; then
            echo "  ✓ Grafana: healthy"
        else
            echo -e "  ${RED}✗${NC} Grafana: NOT RESPONDING"
            all_healthy=false
        fi

        if curl -sf http://localhost:${ALERTMANAGER_PORT:-9093}/-/healthy &>/dev/null; then
            echo "  ✓ Alertmanager: healthy"
        else
            echo -e "  ${RED}✗${NC} Alertmanager: NOT RESPONDING"
            all_healthy=false
        fi
    fi

    echo ""

    if [ "$all_healthy" = true ]; then
        log_success "All services are healthy!"
        return 0
    else
        log_error "Some services are not healthy"
        return 1
    fi
}

# Show deployment info
show_deployment_info() {
    cat << EOF

╔════════════════════════════════════════════════════════════╗
║                                                            ║
║           🎉 Deployment Complete! 🎉                       ║
║                                                            ║
╚════════════════════════════════════════════════════════════╝

📊 Service URLs:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Insights RBAC:           http://localhost:8080
  Insights Host Inventory: http://localhost:8081
  Kessel Relations API:    http://localhost:8082
  Kessel Inventory API:    http://localhost:8083
  SpiceDB HTTP:            http://localhost:8443
  SpiceDB gRPC:            localhost:50051
  SpiceDB Metrics:         http://localhost:9090

🔄 CDC Infrastructure:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Kafka:                   localhost:9092
  Kafka Connect:           http://localhost:8084 (Debezium)
  Kafka UI:                http://localhost:8086
  Zookeeper:               localhost:2181
  Relations Sink:          CDC consumer for RBAC
  Inventory Consumer:      CDC consumer for Inventory

EOF

    if [ "${WITH_OBSERVABILITY:-false}" = "true" ]; then
        cat << EOF
📈 Observability Stack:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Prometheus:          http://localhost:${PROMETHEUS_PORT:-9091}
  Grafana:             http://localhost:${GRAFANA_PORT:-3000} (admin/admin)
  Alertmanager:        http://localhost:${ALERTMANAGER_PORT:-9093}

EOF
    fi

    cat << EOF
📦 Databases:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  RBAC Database:              localhost:5432 (user: rbac)
  HBI Inventory Database:     localhost:5433 (user: inventory)  ← hbi.outbox (Stage 1 CDC)
  Kessel Inventory Database:  localhost:5435 (user: inventory)  ← public.outbox_events (Stage 2 CDC)
  SpiceDB Database:           localhost:5434 (user: spicedb)

🧪 Quick Test:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  # Create a workspace (x-rh-identity header is required by RBAC)
  RBAC_IDENTITY=\$(echo -n '{"identity":{"org_id":"11111","type":"User","user":{"username":"user_dev","is_org_admin":true},"internal":{"org_id":"11111"}}}' | base64)
  curl -X POST http://localhost:8080/api/rbac/v2/workspaces/ \\
    -H "Content-Type: application/json" \\
    -H "x-rh-identity: \$RBAC_IDENTITY" \\
    -d '{"name":"my-workspace","description":"Test workspace"}'

  # Create a host (requires x-rh-identity header)
  IDENTITY=\$(echo -n '{"identity":{"account_number":"12345","org_id":"12345","type":"User","auth_type":"basic-auth","user":{"username":"test_user","email":"test@example.com","is_org_admin":true}}}' | base64)
  curl -X POST http://localhost:8081/api/inventory/v1/hosts \\
    -H "Content-Type: application/json" \\
    -H "x-rh-identity: \$IDENTITY" \\
    -d '[{"display_name":"my-host","fqdn":"host.local","account":"12345","org_id":"12345","stale_timestamp":"2030-01-01T00:00:00.000Z","reporter":"test"}]'

  # Run automated tests
  ./scripts/run-all-tests.sh

📚 Next Steps:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  1. Run tests:        ./scripts/run-all-tests.sh
  2. View logs:        docker logs <container-name> -f
  3. Check status:     docker ps
  4. Stop services:    ./scripts/stop.sh
  5. Restart:          ./scripts/restart.sh
  6. Clean up:         ./scripts/cleanup.sh

EOF

}

# ---------------------------------------------------------------------------
# Minimal stack: SpiceDB + Relations API only (5 containers)
# Use this for: schema testing, CheckPermission calls, new service integration dev
# ---------------------------------------------------------------------------
deploy_minimal() {
    log_info "=========================================="
    log_info "MINIMAL MODE: SpiceDB + Relations API"
    log_info "=========================================="
    log_info "Starts only the authorization core — no Kafka, no Insights services."
    log_info "Use this to test your SpiceDB schema and CheckPermission calls quickly."
    echo ""

    cd "$PROJECT_ROOT"

    log_info "Starting SpiceDB postgres..."
    docker compose -f compose/docker-compose.yml up -d postgres-spicedb

    log_info "Waiting for SpiceDB postgres..."
    for i in {1..20}; do
        if docker exec kessel-postgres-spicedb pg_isready -U spicedb &>/dev/null; then
            log_success "SpiceDB postgres ready"
            break
        fi
        echo -n "."
        sleep 2
    done
    echo ""

    log_info "Running SpiceDB migration..."
    docker compose -f compose/docker-compose.yml up spicedb-migrate
    sleep 2

    log_info "Starting SpiceDB..."
    docker compose -f compose/docker-compose.yml up -d spicedb

    log_info "Waiting for SpiceDB..."
    for i in {1..30}; do
        if curl -sf http://localhost:8443/healthz &>/dev/null; then
            log_success "SpiceDB ready"
            break
        fi
        echo -n "."
        sleep 2
    done
    echo ""

    log_info "Starting kessel-relations-api..."
    docker compose -f compose/docker-compose.yml \
                   -f compose/docker-compose.kessel.yml \
                   up -d kessel-relations-api

    log_info "Waiting for Relations API..."
    for i in {1..30}; do
        if curl -s -o /dev/null -X POST \
                -H 'Content-Type: application/json' \
                -d '{"tuples":[]}' \
                http://localhost:${RELATIONS_GRPC_PORT:-8082}/api/authz/v1beta1/tuples 2>/dev/null; then
            log_success "Relations API ready"
            break
        fi
        echo -n "."
        sleep 2
    done
    echo ""

    log_success "Minimal stack is up!"
    cat << EOF

╔════════════════════════════════════════════════════════════╗
║               Minimal Stack Running                        ║
╚════════════════════════════════════════════════════════════╝

  SpiceDB HTTP:          http://localhost:8443
  SpiceDB gRPC:          localhost:50051  (token: testtesttesttest)
  Kessel Relations API:  http://localhost:8082 (HTTP)
                         localhost:9001   (gRPC)

Next steps for a new service integration:

  # 1. Load your schema
  cat onboarding/hello-world-service/schema/edge.zed | \\
    curl -s -X PUT http://localhost:8443/v1/schema \\
      -H "Authorization: Bearer testtesttesttest" \\
      -H "Content-Type: application/json" \\
      -d "{\\"schema\\": \$(jq -Rs .)}"

  # 2. Create a tuple
  curl -X POST http://localhost:8082/api/authz/v1beta1/tuples \\
    -H "Content-Type: application/json" \\
    -d '{"upsert":true,"tuples":[{"resource":{"type":{"namespace":"edge","name":"device"},"id":"dev-1"},"relation":"t_workspace","subject":{"type":{"namespace":"rbac","name":"workspace"},"id":"ws-1"}}]}'

  # 3. Check a permission
  curl -X POST http://localhost:8082/api/authz/v1beta1/check \\
    -H "Content-Type: application/json" \\
    -d '{"resource":{"type":{"namespace":"edge","name":"device"},"id":"dev-1"},"permission":"view","subject":{"type":{"namespace":"rbac","name":"principal"},"id":"alice"}}'

  # Stop: docker compose -f compose/docker-compose.yml \\
  #              -f compose/docker-compose.kessel.yml down

EOF
}

verify_minimal() {
    local all_healthy=true

    log_info "Checking minimal stack..."

    for container in kessel-postgres-spicedb kessel-spicedb kessel-relations-api; do
        if docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
            echo -e "  ✓ ${container}"
        else
            echo -e "  ${RED}✗${NC} ${container} (not running)"
            all_healthy=false
        fi
    done

    if curl -sf http://localhost:8443/healthz | grep -q "SERVING"; then
        echo "  ✓ SpiceDB: SERVING"
    else
        echo -e "  ${RED}✗${NC} SpiceDB: NOT RESPONDING"
        all_healthy=false
    fi

    if curl -s -o /dev/null -X POST \
              -H 'Content-Type: application/json' \
              -d '{"tuples":[]}' \
              http://localhost:${RELATIONS_GRPC_PORT:-8082}/api/authz/v1beta1/tuples 2>/dev/null; then
        echo "  ✓ Kessel Relations API: SERVING"
    else
        echo -e "  ${RED}✗${NC} Kessel Relations API: NOT RESPONDING"
        all_healthy=false
    fi

    [ "$all_healthy" = true ] && return 0 || return 1
}

# ---------------------------------------------------------------------------
# deploy_kafka_minimal: Zookeeper + Kafka only (no Connect, no consumers)
# Used by --kessel-core-rbac and --kessel-core-hbi
# ---------------------------------------------------------------------------
deploy_kafka_minimal() {
    cd "$PROJECT_ROOT"

    log_info "Starting Zookeeper..."
    docker compose -f compose/docker-compose.yml \
                   -f compose/docker-compose.kessel.yml \
                   -f compose/docker-compose.kafka.yml \
                   up -d zookeeper

    log_info "Waiting for Zookeeper to be ready..."
    for i in {1..30}; do
        if docker exec kessel-zookeeper bash -c "cub zk-ready localhost:2181 5 2>/dev/null"; then
            log_success "Zookeeper ready"
            break
        fi
        echo -n "."
        sleep 2
    done
    echo ""

    log_info "Starting Kafka..."
    docker compose -f compose/docker-compose.yml \
                   -f compose/docker-compose.kessel.yml \
                   -f compose/docker-compose.kafka.yml \
                   up -d kafka

    log_info "Waiting for Kafka to be ready..."
    for i in {1..60}; do
        if docker exec kessel-kafka kafka-broker-api-versions --bootstrap-server localhost:9092 &>/dev/null; then
            log_success "Kafka ready"
            break
        fi
        echo -n "."
        sleep 2
    done
    echo ""
}

# ---------------------------------------------------------------------------
# verify_kessel_core: SpiceDB + Relations API + Inventory API health
# ---------------------------------------------------------------------------
verify_kessel_core() {
    local all_healthy=true

    log_info "Checking kessel-core containers..."
    for container in kessel-postgres-spicedb kessel-spicedb \
                     kessel-postgres-kessel-inventory kessel-inventory-api \
                     kessel-relations-api; do
        if docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
            echo -e "  ✓ ${container}"
        else
            echo -e "  ${RED}✗${NC} ${container} (not running)"
            all_healthy=false
        fi
    done

    echo ""
    log_info "Checking service health..."

    if curl -sf http://localhost:8443/healthz | grep -q "SERVING"; then
        echo "  ✓ SpiceDB: SERVING"
    else
        echo -e "  ${RED}✗${NC} SpiceDB: NOT RESPONDING"
        all_healthy=false
    fi

    if curl -s -o /dev/null -X POST \
              -H 'Content-Type: application/json' \
              -d '{"tuples":[]}' \
              http://localhost:${RELATIONS_GRPC_PORT:-8082}/api/authz/v1beta1/tuples 2>/dev/null; then
        echo "  ✓ Kessel Relations API: SERVING"
    else
        echo -e "  ${RED}✗${NC} Kessel Relations API: NOT RESPONDING"
        all_healthy=false
    fi

    if curl -sf http://localhost:${KESSEL_INVENTORY_PORT:-8083}/api/kessel/v1/livez &>/dev/null; then
        echo "  ✓ Kessel Inventory API: SERVING"
    else
        echo -e "  ${RED}✗${NC} Kessel Inventory API: NOT RESPONDING"
        all_healthy=false
    fi

    [ "$all_healthy" = true ] && return 0 || return 1
}

# ---------------------------------------------------------------------------
# verify_kessel_core_rbac: kessel-core + insights-rbac
# ---------------------------------------------------------------------------
verify_kessel_core_rbac() {
    verify_kessel_core || return 1

    echo ""
    log_info "Checking insights-rbac..."
    if docker ps --format '{{.Names}}' | grep -q "^insights-rbac$"; then
        echo -e "  ✓ insights-rbac"
    else
        echo -e "  ${RED}✗${NC} insights-rbac (not running)"
        return 1
    fi

    if curl -sf http://localhost:8080/api/rbac/v1/status/ &>/dev/null; then
        echo "  ✓ Insights RBAC: healthy"
        return 0
    else
        echo -e "  ${RED}✗${NC} Insights RBAC: NOT RESPONDING"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# verify_kessel_core_hbi: kessel-core + insights-host-inventory
# ---------------------------------------------------------------------------
verify_kessel_core_hbi() {
    verify_kessel_core || return 1

    echo ""
    log_info "Checking insights-host-inventory..."
    if docker ps --format '{{.Names}}' | grep -q "^insights-host-inventory$"; then
        echo -e "  ✓ insights-host-inventory"
    else
        echo -e "  ${RED}✗${NC} insights-host-inventory (not running)"
        return 1
    fi

    if curl -sf http://localhost:8081/health &>/dev/null; then
        echo "  ✓ Insights Host Inventory: healthy"
        return 0
    else
        echo -e "  ${RED}✗${NC} Insights Host Inventory: NOT RESPONDING"
        return 1
    fi
}

# Main deployment flow
main() {
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --clean-volumes)
                export CLEAN_VOLUMES=true
                shift
                ;;
            --skip-tests)
                export SKIP_TESTS=true
                shift
                ;;
            --skip-relations-api)
                export SKIP_RELATIONS_API=true
                shift
                ;;
            --skip-inventory-api)
                export SKIP_INVENTORY_API=true
                shift
                ;;
            --skip-insights-rbac)
                export SKIP_INSIGHTS_RBAC=true
                shift
                ;;
            --skip-insights-host-inventory)
                export SKIP_INSIGHTS_HOST_INVENTORY=true
                shift
                ;;
            --with-observability)
                export WITH_OBSERVABILITY=true
                shift
                ;;
            --minimal)
                # Minimal mode: SpiceDB + Relations API only.
                # For new service integration testing — no Kafka, no Insights services.
                check_prerequisites
                cleanup_existing
                create_network
                deploy_minimal
                verify_minimal && exit 0 || exit 1
                ;;
            --kessel-core)
                # kessel-core: SpiceDB + Relations API + Inventory API
                # No Kafka, no CDC, no Insights services.
                check_prerequisites
                cleanup_existing
                create_network
                deploy_phase5
                verify_kessel_core && log_success "kessel-core is up!" && exit 0 || exit 1
                ;;
            --kessel-core-rbac)
                # kessel-core + Kafka + insights-rbac
                check_prerequisites
                cleanup_existing
                create_network
                deploy_phase5
                deploy_kafka_minimal
                cd "$PROJECT_ROOT"
                log_info "Starting insights-rbac..."
                docker compose -f compose/docker-compose.yml \
                               -f compose/docker-compose.kessel.yml \
                               -f compose/docker-compose.kafka.yml \
                               -f compose/docker-compose.insights.yml \
                               up -d insights-rbac
                log_info "Waiting for insights-rbac to be ready..."
                for i in {1..60}; do
                    if curl -sf http://localhost:8080/api/rbac/v1/status/ &>/dev/null; then
                        log_success "insights-rbac ready"
                        break
                    fi
                    echo -n "."
                    sleep 2
                done
                echo ""
                verify_kessel_core_rbac && log_success "kessel-core + RBAC is up!" && exit 0 || exit 1
                ;;
            --kessel-core-hbi)
                # kessel-core + Kafka + insights-host-inventory
                check_prerequisites
                cleanup_existing
                create_network
                deploy_phase5
                deploy_kafka_minimal
                cd "$PROJECT_ROOT"
                log_info "Starting insights-host-inventory..."
                docker compose -f compose/docker-compose.yml \
                               -f compose/docker-compose.kessel.yml \
                               -f compose/docker-compose.kafka.yml \
                               -f compose/docker-compose.insights.yml \
                               up -d --no-deps insights-host-inventory
                log_info "Waiting for insights-host-inventory to be ready..."
                for i in {1..60}; do
                    if curl -sf http://localhost:8081/health &>/dev/null; then
                        log_success "insights-host-inventory ready"
                        break
                    fi
                    echo -n "."
                    sleep 2
                done
                echo ""
                verify_kessel_core_hbi && log_success "kessel-core + HBI is up!" && exit 0 || exit 1
                ;;
            --help)
                cat << EOF
Usage: $0 [OPTIONS]

Options:
  --clean-volumes              Remove existing data volumes
  --skip-tests                 Skip verification tests
  --skip-relations-api         Skip kessel-relations-api (run locally on port 8000)
  --skip-inventory-api         Skip kessel-inventory-api (run locally on port 8000)
  --skip-insights-rbac         Skip insights-rbac (run locally on port 8080)
  --skip-insights-host-inventory  Skip insights-host-inventory (run locally on port 8081)
  --with-observability         Deploy Prometheus, Grafana, and Alertmanager
  --minimal                    SpiceDB + Relations API only (schema testing, new service dev)
  --kessel-core                SpiceDB + Relations API + Inventory API (no Kafka, no Insights)
  --kessel-core-rbac           kessel-core + Kafka + insights-rbac
  --kessel-core-hbi            kessel-core + Kafka + insights-host-inventory
  --help                       Show this help message

Examples:
  $0                          # Full deployment (14 containers)
  $0 --minimal                # SpiceDB + Relations API only (3 containers, fast)
  $0 --kessel-core            # SpiceDB + Relations + Inventory (7 containers)
  $0 --kessel-core-rbac       # kessel-core + Kafka + RBAC (10 containers)
  $0 --kessel-core-hbi        # kessel-core + Kafka + HBI (10 containers)
  $0 --clean-volumes          # Fresh deployment (removes data)
  $0 --skip-tests             # Deploy without verification
  $0 --with-observability     # Deploy with Prometheus + Grafana + Alertmanager

Local Development (skip services to run them from source locally):
  $0 --skip-inventory-api     # Run inventory-api locally on port 8000
  $0 --skip-relations-api     # Run relations-api locally on port 8000
  SKIP_INVENTORY_API=true $0  # Same as above, using env var

  Other Docker containers will route to your local process via host-gateway.
  See docs/local-dev.md for details.

New Service Integration:
  $0 --minimal                # Start just the auth layer
  $0 --kessel-core            # Start full Kessel authorization stack
  # Then load your schema, create tuples, run CheckPermission
  # See onboarding/ for step-by-step guides

Monitoring Dashboard (run separately):
  cd monitoring && ./run.sh

EOF
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                exit 1
                ;;
        esac
    done

    # Execute deployment steps
    check_prerequisites
    cleanup_existing
    create_network
    deploy_phase5
    deploy_phase6
    deploy_phase7

    # Deploy observability if requested
    if [ "${WITH_OBSERVABILITY:-false}" = "true" ]; then
        deploy_observability
    fi

    # Verify
    if verify_deployment; then
        show_deployment_info

        # Run tests if not skipped
        if [ "${SKIP_TESTS:-false}" = "false" ]; then
            echo ""
            log_info "Running automated tests..."
            if [ -x "$SCRIPT_DIR/run-all-tests.sh" ]; then
                "$SCRIPT_DIR/run-all-tests.sh" || log_warn "Some tests failed (check output above)"
            else
                log_warn "Test script not found or not executable"
            fi
        fi

        exit 0
    else
        log_error "Deployment verification failed"
        echo ""
        log_info "Troubleshooting:"
        echo "  1. Check logs: docker logs <container-name>"
        echo "  2. Check status: docker ps -a"
        echo "  3. Check network: docker network inspect kessel-network"
        exit 1
    fi
}

# Run main
main "$@"
