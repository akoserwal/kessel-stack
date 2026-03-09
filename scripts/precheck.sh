#!/usr/bin/env bash
# Kessel Stack: Pre-deployment Port Check Script
# Checks if all required ports are available before deployment

set -e

# Color codes
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# Logging functions
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[✓]${NC} $1"; }
log_error() { echo -e "${RED}[✗]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[!]${NC} $1"; }
log_port() { echo -e "${CYAN}[PORT]${NC} $1"; }

# Banner
cat << "EOF"
╔════════════════════════════════════════════════════════════╗
║                                                            ║
║        Kessel Stack Pre-Deployment Check                ║
║                                                            ║
║  Verifying system readiness and port availability         ║
║                                                            ║
╚════════════════════════════════════════════════════════════╝
EOF

echo ""

# Port definitions (port:description format)
# Compatible with bash 3.2+
PORT_DEFINITIONS=(
    "2181:Zookeeper (Kafka coordination)"
    "5432:PostgreSQL (RBAC database)"
    "5433:PostgreSQL (Inventory database)"
    "5434:PostgreSQL (SpiceDB datastore)"
    "8080:Insights RBAC Service"
    "8081:Insights Host Inventory Service"
    "8082:Kessel Relations API"
    "8083:Kessel Inventory API"
    "8084:Kafka Connect (Debezium)"
    "8086:Kafka UI (Web Interface)"
    "8443:SpiceDB HTTP API"
    "8888:Monitoring Dashboard Server"
    "9001:Health Exporter (RBAC)"
    "9002:Health Exporter (Inventory)"
    "9090:Prometheus"
    "9091:RBAC Consumer Metrics"
    "9092:Kafka Broker"
    "9101:Kafka JMX Metrics"
    "50051:SpiceDB gRPC API"
    "3000:Grafana (if using observability)"
)

# Get description for a port
get_port_description() {
    local search_port=$1
    for def in "${PORT_DEFINITIONS[@]}"; do
        local port="${def%%:*}"
        local desc="${def#*:}"
        if [ "$port" = "$search_port" ]; then
            echo "$desc"
            return
        fi
    done
    echo "Unknown service"
}

# Track results
PORTS_IN_USE=0
PORTS_AVAILABLE=0
BLOCKED_PORTS=()
PREREQUISITES_MET=true

# Check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."
    echo ""

    # Check Docker
    if command -v docker &> /dev/null; then
        log_success "Docker is installed ($(docker --version | cut -d' ' -f3 | tr -d ','))"
    else
        log_error "Docker is not installed"
        echo "        Install from: https://docs.docker.com/get-docker/"
        PREREQUISITES_MET=false
    fi

    # Check Docker Compose
    if docker compose version &> /dev/null 2>&1; then
        log_success "Docker Compose is installed ($(docker compose version --short))"
    else
        log_error "Docker Compose V2 is not installed"
        echo "        Install from: https://docs.docker.com/compose/install/"
        PREREQUISITES_MET=false
    fi

    # Check Docker daemon
    if docker ps &> /dev/null 2>&1; then
        log_success "Docker daemon is running"
    else
        log_error "Docker daemon is not running"
        echo "        Start Docker Desktop or run: sudo systemctl start docker"
        PREREQUISITES_MET=false
    fi

    # Check jq (optional)
    if command -v jq &> /dev/null; then
        log_success "jq is installed (optional but recommended)"
    else
        log_warn "jq is not installed (optional)"
        echo "        Install: brew install jq (macOS) or apt-get install jq (Linux)"
    fi

    # Check lsof (for port checking)
    if command -v lsof &> /dev/null; then
        log_success "lsof is available for port checking"
    else
        log_warn "lsof is not available (port checking may be limited)"
    fi

    # Check curl (for testing)
    if command -v curl &> /dev/null; then
        log_success "curl is installed"
    else
        log_warn "curl is not installed (recommended for testing)"
    fi

    echo ""
}

# Check if port is in use
check_port() {
    local port=$1
    local description=$2

    # Try lsof first (more reliable)
    if command -v lsof &> /dev/null; then
        local pid=$(lsof -ti:$port 2>/dev/null || echo "")
        if [ -n "$pid" ]; then
            local process=$(ps -p $pid -o comm= 2>/dev/null || echo "unknown")
            local user=$(ps -p $pid -o user= 2>/dev/null || echo "unknown")
            log_error "Port $port in use - $description"
            echo "        Process: $process (PID: $pid, User: $user)"
            BLOCKED_PORTS+=("$port:$process:$pid")
            ((PORTS_IN_USE++))
            return 1
        else
            log_success "Port $port available - $description"
            ((PORTS_AVAILABLE++))
            return 0
        fi
    else
        # Fallback to nc if available
        if command -v nc &> /dev/null; then
            if nc -z localhost $port 2>/dev/null; then
                log_error "Port $port in use - $description"
                echo "        (Unable to determine process - lsof not available)"
                BLOCKED_PORTS+=("$port:unknown:unknown")
                ((PORTS_IN_USE++))
                return 1
            else
                log_success "Port $port available - $description"
                ((PORTS_AVAILABLE++))
                return 0
            fi
        else
            log_warn "Port $port - Unable to check (no lsof or nc available)"
            return 2
        fi
    fi
}

# Check all ports
check_all_ports() {
    log_info "Checking port availability..."
    echo ""

    # Extract and sort ports
    local ports=()
    for def in "${PORT_DEFINITIONS[@]}"; do
        ports+=("${def%%:*}")
    done

    # Sort ports numerically
    IFS=$'\n' sorted_ports=($(sort -n <<<"${ports[*]}"))
    unset IFS

    # Check each port
    for port in "${sorted_ports[@]}"; do
        local desc=$(get_port_description "$port")
        check_port "$port" "$desc"
    done

    echo ""
}

# Show blocked ports summary
show_blocked_ports_summary() {
    if [ ${#BLOCKED_PORTS[@]} -gt 0 ]; then
        echo "════════════════════════════════════════════════════════════"
        log_error "BLOCKED PORTS SUMMARY"
        echo "════════════════════════════════════════════════════════════"
        echo ""

        printf "%-10s %-30s %-10s %-10s\n" "PORT" "SERVICE" "PROCESS" "PID"
        printf "%-10s %-30s %-10s %-10s\n" "----" "-------" "-------" "---"

        for blocked in "${BLOCKED_PORTS[@]}"; do
            IFS=':' read -r port process pid <<< "$blocked"
            local desc=$(get_port_description "$port")
            printf "%-10s %-30s %-10s %-10s\n" "$port" "$desc" "$process" "$pid"
        done

        echo ""
    fi
}

# Show recommendations
show_recommendations() {
    if [ ${#BLOCKED_PORTS[@]} -gt 0 ]; then
        echo "════════════════════════════════════════════════════════════"
        log_warn "RECOMMENDATIONS"
        echo "════════════════════════════════════════════════════════════"
        echo ""

        echo "To free up blocked ports, you can:"
        echo ""
        echo "1. Stop processes manually:"
        for blocked in "${BLOCKED_PORTS[@]}"; do
            IFS=':' read -r port process pid <<< "$blocked"
            if [ "$pid" != "unknown" ]; then
                local desc=$(get_port_description "$port")
                echo "   kill $pid    # $process on port $port ($desc)"
            fi
        done
        echo ""

        echo "2. Use the cleanup script:"
        echo "   ./scripts/cleanup-ports.sh"
        echo ""

        echo "3. Stop existing Kessel deployment:"
        echo "   ./scripts/deploy.sh --clean-volumes"
        echo ""

        echo "4. Identify what's using each port:"
        for blocked in "${BLOCKED_PORTS[@]}"; do
            IFS=':' read -r port process pid <<< "$blocked"
            if [ "$pid" != "unknown" ]; then
                echo "   lsof -i:$port    # Check port $port"
            fi
        done
        echo ""
    fi
}

# Offer to kill processes
offer_cleanup() {
    if [ ${#BLOCKED_PORTS[@]} -gt 0 ]; then
        echo "════════════════════════════════════════════════════════════"
        log_warn "AUTOMATIC CLEANUP AVAILABLE"
        echo "════════════════════════════════════════════════════════════"
        echo ""

        if [ "${AUTO_KILL:-false}" = "true" ]; then
            log_info "Auto-kill enabled - stopping processes on blocked ports..."
            echo ""

            for blocked in "${BLOCKED_PORTS[@]}"; do
                IFS=':' read -r port process pid <<< "$blocked"
                if [ "$pid" != "unknown" ] && [ -n "$pid" ]; then
                    log_info "Killing process on port $port (PID: $pid, Process: $process)"
                    kill -9 "$pid" 2>/dev/null || log_warn "Failed to kill PID $pid"
                fi
            done

            echo ""
            log_success "Cleanup complete - ports should now be available"
            echo ""
            log_info "Run precheck again to verify: ./scripts/precheck.sh"
        else
            echo "Run with --kill flag to automatically stop processes:"
            echo "  ./scripts/precheck.sh --kill"
            echo ""
            echo "Or use the cleanup script:"
            echo "  ./scripts/cleanup-ports.sh"
        fi
        echo ""
    fi
}

# Show final summary
show_summary() {
    echo "════════════════════════════════════════════════════════════"
    echo "                    PRECHECK SUMMARY                        "
    echo "════════════════════════════════════════════════════════════"
    echo ""

    printf "%-30s %s\n" "Total Ports Checked:" "$((PORTS_AVAILABLE + PORTS_IN_USE))"
    printf "%-30s ${GREEN}%s${NC}\n" "Ports Available:" "$PORTS_AVAILABLE"
    printf "%-30s ${RED}%s${NC}\n" "Ports Blocked:" "$PORTS_IN_USE"
    echo ""

    if [ "$PREREQUISITES_MET" = "true" ]; then
        printf "%-30s ${GREEN}%s${NC}\n" "Prerequisites:" "MET"
    else
        printf "%-30s ${RED}%s${NC}\n" "Prerequisites:" "NOT MET"
    fi
    echo ""

    if [ ${#BLOCKED_PORTS[@]} -eq 0 ] && [ "$PREREQUISITES_MET" = "true" ]; then
        echo "════════════════════════════════════════════════════════════"
        log_success "SYSTEM READY FOR DEPLOYMENT!"
        echo "════════════════════════════════════════════════════════════"
        echo ""
        echo "All ports are available and prerequisites are met."
        echo ""
        echo "You can proceed with deployment:"
        echo "  ./scripts/deploy.sh"
        echo "  ./scripts/deploy.sh --with-monitoring"
        echo "  ./scripts/deploy.sh --clean-volumes --with-monitoring"
        echo ""
        exit 0
    else
        echo "════════════════════════════════════════════════════════════"
        log_error "SYSTEM NOT READY FOR DEPLOYMENT"
        echo "════════════════════════════════════════════════════════════"
        echo ""

        if [ "$PREREQUISITES_MET" = "false" ]; then
            echo "Please install missing prerequisites (see above)."
            echo ""
        fi

        if [ ${#BLOCKED_PORTS[@]} -gt 0 ]; then
            echo "Please free up blocked ports before deploying."
            echo ""
            echo "Quick fix options:"
            echo "  1. ./scripts/precheck.sh --kill     # Auto-kill processes"
            echo "  2. ./scripts/cleanup-ports.sh       # Interactive cleanup"
            echo "  3. Manually stop processes (see recommendations above)"
            echo ""
        fi

        exit 1
    fi
}

# Parse arguments
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --kill)
                export AUTO_KILL=true
                shift
                ;;
            --help|-h)
                cat << EOF

Usage: $0 [OPTIONS]

Pre-deployment check for Kessel Stack

Options:
  --kill          Automatically kill processes on blocked ports
  --help, -h      Show this help message

Examples:
  $0              # Check ports and prerequisites
  $0 --kill       # Check and auto-kill blocking processes

This script checks:
  - Docker and Docker Compose installation
  - Docker daemon status
  - Port availability for all Kessel services
  - Optional tools (jq, curl, lsof)

Number of ports checked: ${#PORT_DEFINITIONS[@]}

EOF
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                echo "Use --help for usage information"
                exit 1
                ;;
        esac
    done
}

# Main execution
main() {
    parse_arguments "$@"

    check_prerequisites
    check_all_ports
    show_blocked_ports_summary
    show_recommendations
    offer_cleanup
    show_summary
}

main "$@"
