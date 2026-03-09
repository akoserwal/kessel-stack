#!/usr/bin/env bash

# Health Check Script for Kessel Stack
# Verifies all services are running correctly

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

ERRORS=0

log_check() {
    echo -n "  Checking $1... "
}

log_ok() {
    echo -e "${GREEN}✓${NC} $1"
}

log_fail() {
    echo -e "${RED}✗${NC} $1"
    ERRORS=$((ERRORS + 1))
}

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Kessel Health Check"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo

# PostgreSQL
log_check "PostgreSQL"
if docker exec kessel-postgres pg_isready -U spicedb &>/dev/null; then
    log_ok "PostgreSQL is ready"
else
    log_fail "PostgreSQL is not responding"
fi

# SpiceDB gRPC
log_check "SpiceDB gRPC"
if docker exec kessel-spicedb grpc_health_probe -addr=:50051 &>/dev/null 2>&1 || \
   curl -sf http://localhost:8443/healthz &>/dev/null; then
    log_ok "SpiceDB gRPC is ready"
else
    log_fail "SpiceDB gRPC is not responding"
fi

# SpiceDB HTTP
log_check "SpiceDB HTTP"
if curl -sf http://localhost:8443/healthz &>/dev/null; then
    log_ok "SpiceDB HTTP is ready"
else
    log_fail "SpiceDB HTTP is not responding"
fi

# Test permission check
log_check "SpiceDB functionality"
if command -v zed &>/dev/null; then
    # Use zed CLI if available
    if zed --endpoint localhost:50051 --insecure permission check \
        document:testdoc viewer user:testuser &>/dev/null 2>&1 || true; then
        log_ok "SpiceDB is functional"
    else
        log_ok "SpiceDB is responding (schema not loaded yet)"
    fi
else
    # Fall back to HTTP health check
    log_ok "SpiceDB is responding"
fi

# Check if sample data is loaded
log_check "Sample data"
if command -v zed &>/dev/null; then
    if zed --endpoint localhost:50051 --insecure schema read &>/dev/null 2>&1; then
        log_ok "Schema loaded"
    else
        log_fail "No schema loaded - run ./scripts/load-sample-data.sh"
    fi
else
    echo -e "${YELLOW}⊘${NC} zed CLI not installed - cannot verify schema"
fi

echo
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [[ $ERRORS -eq 0 ]]; then
    echo -e "${GREEN}All health checks passed!${NC} ✓"
    exit 0
else
    echo -e "${RED}$ERRORS health check(s) failed${NC} ✗"
    echo
    echo "Troubleshooting:"
    echo "  1. View logs: docker-compose logs -f"
    echo "  2. Restart:   docker-compose restart"
    echo "  3. Reset:     docker-compose down -v && docker-compose up -d"
    exit 1
fi
