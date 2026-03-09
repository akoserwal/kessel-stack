#!/bin/bash
# Kessel Stack: Port Cleanup Script
# Frees up ports required for Kessel deployment

set -e

# Color codes
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[✓]${NC} $1"; }
log_error() { echo -e "${RED}[✗]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[!]${NC} $1"; }

# Banner
cat << "EOF"
╔════════════════════════════════════════════════════════════╗
║                                                            ║
║            Kessel Stack Port Cleanup                    ║
║                                                            ║
║  Free up ports required for deployment                    ║
║                                                            ║
╚════════════════════════════════════════════════════════════╝
EOF

echo ""

# Required ports
PORTS=(2181 5432 5433 5434 8080 8081 8082 8083 8084 8086 8443 8888 9001 9002 9090 9091 9092 9101 50051)

# Parse arguments
FORCE=false
if [[ "$1" == "--force" || "$1" == "-f" ]]; then
    FORCE=true
    log_warn "Force mode enabled - will kill all processes without confirmation"
    echo ""
fi

# Check for lsof
if ! command -v lsof &> /dev/null; then
    log_error "lsof command not found - cannot identify processes on ports"
    echo "Install lsof: brew install lsof (macOS) or apt-get install lsof (Linux)"
    exit 1
fi

# Find processes on ports
log_info "Scanning for processes on required ports..."
echo ""

FOUND_PROCESSES=()
for port in "${PORTS[@]}"; do
    pid=$(lsof -ti:$port 2>/dev/null || echo "")
    if [ -n "$pid" ]; then
        process=$(ps -p $pid -o comm= 2>/dev/null || echo "unknown")
        user=$(ps -p $pid -o user= 2>/dev/null || echo "unknown")
        FOUND_PROCESSES+=("$port:$pid:$process:$user")
        log_warn "Port $port - Process: $process (PID: $pid, User: $user)"
    fi
done

echo ""

# If no processes found
if [ ${#FOUND_PROCESSES[@]} -eq 0 ]; then
    log_success "All required ports are free - no cleanup needed!"
    echo ""
    echo "You can proceed with deployment:"
    echo "  ./scripts/deploy.sh"
    exit 0
fi

# Show summary
log_info "Found ${#FOUND_PROCESSES[@]} process(es) using required ports"
echo ""

# Confirm cleanup
if [ "$FORCE" != "true" ]; then
    echo "This will kill the following processes:"
    echo ""
    printf "%-10s %-10s %-20s %-10s\n" "PORT" "PID" "PROCESS" "USER"
    printf "%-10s %-10s %-20s %-10s\n" "----" "---" "-------" "----"
    for entry in "${FOUND_PROCESSES[@]}"; do
        IFS=':' read -r port pid process user <<< "$entry"
        printf "%-10s %-10s %-20s %-10s\n" "$port" "$pid" "$process" "$user"
    done
    echo ""

    read -p "Do you want to proceed? (y/N): " -n 1 -r
    echo ""

    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Cleanup cancelled"
        exit 0
    fi
    echo ""
fi

# Kill processes
log_info "Stopping processes..."
echo ""

KILLED=0
FAILED=0

for entry in "${FOUND_PROCESSES[@]}"; do
    IFS=':' read -r port pid process user <<< "$entry"

    if kill -9 "$pid" 2>/dev/null; then
        log_success "Killed $process (PID: $pid) on port $port"
        ((KILLED++))
    else
        log_error "Failed to kill PID $pid on port $port"
        ((FAILED++))
    fi
done

echo ""
echo "════════════════════════════════════════════════════════════"
log_info "CLEANUP SUMMARY"
echo "════════════════════════════════════════════════════════════"
echo ""
printf "%-30s %s\n" "Processes killed:" "$KILLED"
printf "%-30s %s\n" "Failed to kill:" "$FAILED"
echo ""

if [ $FAILED -eq 0 ]; then
    log_success "Cleanup complete - all ports should now be available"
    echo ""
    echo "Verify with:"
    echo "  ./scripts/precheck.sh"
    echo ""
    echo "Then deploy:"
    echo "  ./scripts/deploy.sh"
else
    log_warn "Some processes could not be killed (may require sudo)"
    echo ""
    echo "Try with sudo if you have permission issues:"
    echo "  sudo ./scripts/cleanup-ports.sh"
fi
echo ""
