#!/usr/bin/env bash

# Cleanup Script for Kessel Stack
# Stops and removes all containers, volumes, and networks

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Parse arguments
REMOVE_VOLUMES=false
REMOVE_KIND=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --volumes)
            REMOVE_VOLUMES=true
            shift
            ;;
        --kind)
            REMOVE_KIND=true
            shift
            ;;
        --all)
            REMOVE_VOLUMES=true
            REMOVE_KIND=true
            shift
            ;;
        -h|--help)
            cat << EOF
Usage: $0 [OPTIONS]

Clean up Kessel Stack environment

OPTIONS:
    --volumes    Also remove data volumes (deletes all data!)
    --kind       Also delete Kind cluster
    --all        Remove everything (volumes + kind cluster)
    -h, --help   Show this help

EXAMPLES:
    # Stop containers but keep data
    $0

    # Stop containers and delete all data
    $0 --volumes

    # Remove everything including Kind cluster
    $0 --all
EOF
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Kessel Stack Cleanup"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo

# Confirmation for destructive operations
if [[ "$REMOVE_VOLUMES" == true ]]; then
    log_warn "This will DELETE ALL DATA in PostgreSQL and other services!"
    read -p "Are you sure? [y/N] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Cancelled"
        exit 0
    fi
fi

# Stop Docker Compose services
if command -v docker-compose &>/dev/null || command -v podman-compose &>/dev/null; then
    log_info "Stopping Docker Compose services..."
    cd "$PROJECT_ROOT/compose"

    if [[ "$REMOVE_VOLUMES" == true ]]; then
        docker-compose down -v
        log_info "Containers and volumes removed"
    else
        docker-compose down
        log_info "Containers stopped (volumes preserved)"
    fi
else
    log_warn "docker-compose not found, skipping"
fi

# Remove Kind cluster
if [[ "$REMOVE_KIND" == true ]]; then
    if command -v kind &>/dev/null; then
        log_info "Deleting Kind cluster..."
        kind delete cluster --name kessel-local 2>/dev/null || log_warn "No Kind cluster found"
    else
        log_warn "kind not found, skipping"
    fi
fi

# Clean up any dangling resources
log_info "Cleaning up dangling resources..."

if command -v docker &>/dev/null; then
    # Remove stopped containers
    STOPPED=$(docker ps -aq -f "name=kessel-" 2>/dev/null || true)
    if [[ -n "$STOPPED" ]]; then
        docker rm -f $STOPPED &>/dev/null || true
    fi

    # Remove dangling networks
    docker network rm kessel-network 2>/dev/null || true
fi

echo
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "Cleanup complete!"

if [[ "$REMOVE_VOLUMES" == false ]]; then
    echo
    log_info "Data volumes were preserved. To remove them:"
    echo "  $0 --volumes"
fi

echo
log_info "To start fresh:"
echo "  ./scripts/setup.sh"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
