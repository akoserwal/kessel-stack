#!/bin/bash
# Compile KSL source files in schemas/ksl/ into services/spicedb/schema/schema.zed

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[✓]${NC} $1"; }
log_error() { echo -e "${RED}[✗]${NC} $1"; }

# Check ksl is installed
if ! command -v ksl &>/dev/null; then
    log_error "ksl compiler not found. Install it with:"
    echo "    go install github.com/project-kessel/ksl-schema-language/cmd/ksl@latest"
    exit 1
fi

KSL_DIR="$PROJECT_ROOT/schemas/ksl"
OUTPUT="$PROJECT_ROOT/services/spicedb/schema/schema.zed"

log_info "Compiling KSL sources → $OUTPUT"

ksl \
    -o "$OUTPUT" \
    "$KSL_DIR/kessel.ksl" \
    "$KSL_DIR/rbac.ksl" \
    "$KSL_DIR/hbi.ksl" \
    "$KSL_DIR/edge.ksl"

log_success "Compiled schema.zed — restart kessel-relations-api or run ./scripts/manage-schema.sh compile-and-load to hot-reload"
