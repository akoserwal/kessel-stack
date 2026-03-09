#!/usr/bin/env bash

# Kessel Stack Setup Script
# One-command deployment for local Kessel environment

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
COMPOSE_FILE="${PROJECT_ROOT}/compose/docker-compose.yml"
ENV_FILE="${PROJECT_ROOT}/.env"
ENV_EXAMPLE="${PROJECT_ROOT}/.env.example"

# Default options
DEPLOYMENT_MODE="docker"  # docker or kubernetes
COMPONENTS="minimal"      # minimal, standard, or full
LOAD_SAMPLES=true
RUN_TESTS=false
SKIP_HEALTH_CHECK=false

# ============================================================================
# Helper Functions
# ============================================================================

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_banner() {
    cat << 'EOF'
╔══════════════════════════════════════════════════════════════╗
║                                                              ║
║   ██╗  ██╗███████╗███████╗███████╗███████╗██╗              ║
║   ██║ ██╔╝██╔════╝██╔════╝██╔════╝██╔════╝██║              ║
║   █████╔╝ █████╗  ███████╗███████╗█████╗  ██║              ║
║   ██╔═██╗ ██╔══╝  ╚════██║╚════██║██╔══╝  ██║              ║
║   ██║  ██╗███████╗███████║███████║███████╗███████╗         ║
║   ╚═╝  ╚═╝╚══════╝╚══════╝╚══════╝╚══════╝╚══════╝         ║
║                                                              ║
║              Kessel Stack Setup v1.0.0                   ║
║        One-command local development environment            ║
║                                                              ║
╚══════════════════════════════════════════════════════════════╝
EOF
}

usage() {
    cat << EOF

Usage: $0 [OPTIONS]

Deploy Kessel locally using Docker Compose or Kubernetes Kind.

OPTIONS:
    -m, --mode <MODE>        Deployment mode: docker (default) or kind
    -c, --components <TYPE>  Components to deploy: minimal, standard, full
                             minimal:  SpiceDB + PostgreSQL only
                             standard: + Kafka + Redis
                             full:     + Monitoring + Tracing
    --no-samples             Skip loading sample data
    --run-tests              Run integration tests after setup
    --skip-health            Skip health checks
    -h, --help               Show this help message

EXAMPLES:
    # Minimal setup (fastest, recommended for beginners)
    $0

    # Standard setup with event streaming
    $0 --components standard

    # Full setup with monitoring
    $0 --components full

    # Kubernetes deployment
    $0 --mode kind --components full

EOF
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -m|--mode)
                DEPLOYMENT_MODE="$2"
                shift 2
                ;;
            -c|--components)
                COMPONENTS="$2"
                shift 2
                ;;
            --no-samples)
                LOAD_SAMPLES=false
                shift
                ;;
            --run-tests)
                RUN_TESTS=true
                shift
                ;;
            --skip-health)
                SKIP_HEALTH_CHECK=true
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done
}

# Check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."

    if [[ "$DEPLOYMENT_MODE" == "docker" ]]; then
        if command -v docker &> /dev/null; then
            log_success "Docker found: $(docker --version)"
        elif command -v podman &> /dev/null; then
            log_success "Podman found: $(podman --version)"
            # Create docker alias for podman
            alias docker=podman
        else
            log_error "Neither Docker nor Podman found. Please install one of them."
            exit 1
        fi

        if command -v docker-compose &> /dev/null; then
            log_success "Docker Compose found: $(docker-compose --version)"
        elif command -v podman-compose &> /dev/null; then
            log_success "Podman Compose found: $(podman-compose --version)"
            alias docker-compose=podman-compose
        else
            log_error "Docker Compose or Podman Compose not found."
            exit 1
        fi
    elif [[ "$DEPLOYMENT_MODE" == "kind" ]]; then
        if ! command -v kind &> /dev/null; then
            log_error "Kind not found. Please install: https://kind.sigs.k8s.io/"
            exit 1
        fi
        log_success "Kind found: $(kind --version)"

        if ! command -v kubectl &> /dev/null; then
            log_error "kubectl not found. Please install: https://kubernetes.io/docs/tasks/tools/"
            exit 1
        fi
        log_success "kubectl found: $(kubectl version --client --short 2>/dev/null || kubectl version --client)"
    fi
}

# Setup environment file
setup_env() {
    log_info "Setting up environment configuration..."

    if [[ ! -f "$ENV_FILE" ]]; then
        log_info "Creating .env from .env.example..."
        cp "$ENV_EXAMPLE" "$ENV_FILE"
        log_success "Created $ENV_FILE"
        log_warn "Review and customize $ENV_FILE if needed"
    else
        log_info ".env file already exists, using existing configuration"
    fi
}

# Deploy with Docker Compose
deploy_docker() {
    log_info "Deploying with Docker Compose (mode: $COMPONENTS)..."

    cd "$PROJECT_ROOT/compose"

    # Determine which compose files to use
    local compose_files="-f docker-compose.yml"

    case "$COMPONENTS" in
        minimal)
            log_info "Deploying minimal stack: SpiceDB + PostgreSQL"
            ;;
        standard)
            log_info "Deploying standard stack: + Kafka + Redis"
            if [[ -f "docker-compose.kafka.yml" ]]; then
                compose_files="$compose_files -f docker-compose.kafka.yml"
            fi
            ;;
        full)
            log_info "Deploying full stack: + Monitoring + Tracing"
            if [[ -f "docker-compose.full.yml" ]]; then
                compose_files="$compose_files -f docker-compose.full.yml"
            fi
            ;;
        *)
            log_error "Invalid components: $COMPONENTS"
            exit 1
            ;;
    esac

    # Stop any existing containers
    log_info "Stopping any existing containers..."
    docker-compose $compose_files down -v 2>/dev/null || true

    # Start services
    log_info "Starting services..."
    docker-compose $compose_files up -d

    log_success "Services started successfully"
}

# Deploy with Kubernetes Kind
deploy_kind() {
    log_info "Deploying with Kubernetes Kind (mode: $COMPONENTS)..."

    local cluster_name="kessel-local"

    # Check if cluster exists
    if kind get clusters 2>/dev/null | grep -q "^${cluster_name}$"; then
        log_warn "Cluster $cluster_name already exists"
        read -p "Delete and recreate? [y/N] " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            log_info "Deleting existing cluster..."
            kind delete cluster --name "$cluster_name"
        else
            log_info "Using existing cluster"
            return
        fi
    fi

    # Create cluster
    log_info "Creating Kind cluster..."
    local kind_config="${PROJECT_ROOT}/kubernetes/kind-config.yaml"

    if [[ -f "$kind_config" ]]; then
        kind create cluster --name "$cluster_name" --config "$kind_config"
    else
        kind create cluster --name "$cluster_name"
    fi

    log_success "Kind cluster created"

    # Deploy components
    log_info "Deploying Kubernetes manifests..."
    kubectl apply -f "${PROJECT_ROOT}/kubernetes/"

    log_success "Kubernetes manifests applied"
}

# Wait for services to be healthy
wait_for_services() {
    if [[ "$SKIP_HEALTH_CHECK" == true ]]; then
        log_warn "Skipping health checks"
        return
    fi

    log_info "Waiting for services to be ready..."

    if [[ "$DEPLOYMENT_MODE" == "docker" ]]; then
        # Wait for PostgreSQL
        log_info "Waiting for PostgreSQL..."
        local max_attempts=30
        local attempt=0

        while ! docker exec kessel-postgres pg_isready -U spicedb &>/dev/null; do
            attempt=$((attempt + 1))
            if [[ $attempt -ge $max_attempts ]]; then
                log_error "PostgreSQL failed to start"
                exit 1
            fi
            echo -n "."
            sleep 2
        done
        echo
        log_success "PostgreSQL is ready"

        # Wait for SpiceDB
        log_info "Waiting for SpiceDB..."
        attempt=0
        while ! curl -sf http://localhost:8443/healthz &>/dev/null; do
            attempt=$((attempt + 1))
            if [[ $attempt -ge $max_attempts ]]; then
                log_error "SpiceDB failed to start"
                docker logs kessel-spicedb --tail 50
                exit 1
            fi
            echo -n "."
            sleep 2
        done
        echo
        log_success "SpiceDB is ready"
    fi
}

# Load sample data
load_sample_data() {
    if [[ "$LOAD_SAMPLES" == false ]]; then
        log_warn "Skipping sample data load"
        return
    fi

    log_info "Loading sample data..."

    if [[ -x "${SCRIPT_DIR}/load-sample-data.sh" ]]; then
        "${SCRIPT_DIR}/load-sample-data.sh"
        log_success "Sample data loaded"
    else
        log_warn "Sample data script not found, skipping"
    fi
}

# Run health checks
run_health_checks() {
    log_info "Running health checks..."

    if [[ -x "${SCRIPT_DIR}/health-check.sh" ]]; then
        "${SCRIPT_DIR}/health-check.sh"
    else
        log_warn "Health check script not found, skipping"
    fi
}

# Run integration tests
run_integration_tests() {
    if [[ "$RUN_TESTS" == false ]]; then
        return
    fi

    log_info "Running integration tests..."

    if [[ -x "${SCRIPT_DIR}/tests/run-all.sh" ]]; then
        "${SCRIPT_DIR}/tests/run-all.sh"
    else
        log_warn "Test script not found, skipping"
    fi
}

# Print access information
print_access_info() {
    log_success "Setup complete! 🎉"
    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Kessel Environment Access Information"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    echo "SpiceDB:"
    echo "  gRPC:    localhost:50051"
    echo "  REST:    http://localhost:8443"
    echo "  Metrics: http://localhost:9090/metrics"
    echo "  Auth:    Pre-shared key = testtesttesttest"
    echo

    if [[ "$COMPONENTS" != "minimal" ]]; then
        echo "Additional Services:"
        echo "  PostgreSQL: localhost:5432 (user: spicedb, password: secretpassword)"

        if [[ "$COMPONENTS" == "full" ]]; then
            echo "  Prometheus: http://localhost:9091"
            echo "  Grafana:    http://localhost:3000 (admin/admin)"
            echo "  Jaeger:     http://localhost:16686"
        fi
        echo
    fi

    echo "Quick Commands:"
    echo "  Health check:    ./scripts/health-check.sh"
    echo "  View logs:       docker-compose logs -f spicedb"
    echo "  Run tests:       ./scripts/tests/run-all.sh"
    echo "  Load schema:     ./scripts/load-schema.sh <schema-file>"
    echo "  Cleanup:         ./scripts/cleanup.sh"
    echo
    echo "Documentation:"
    echo "  Getting started: docs/examples/getting-started.md"
    echo "  Troubleshooting: docs/troubleshooting.md"
    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# ============================================================================
# Main Execution
# ============================================================================

main() {
    print_banner
    echo

    parse_args "$@"
    check_prerequisites
    setup_env

    # Deploy based on mode
    if [[ "$DEPLOYMENT_MODE" == "docker" ]]; then
        deploy_docker
    elif [[ "$DEPLOYMENT_MODE" == "kind" ]]; then
        deploy_kind
    fi

    wait_for_services
    load_sample_data
    run_health_checks
    run_integration_tests

    echo
    print_access_info
}

# Run main function
main "$@"
