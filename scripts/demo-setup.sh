#!/bin/bash
#
# Demo Setup Script
# Prepares kessel-stack for demo presentation using the stage schema
# Uses the real project-kessel/relations-api and project-kessel/inventory-api
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  Kessel Stack Demo Setup${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# Check prerequisites
echo -e "${YELLOW}Checking prerequisites...${NC}"

if ! command -v docker &> /dev/null; then
    echo -e "${RED}Error: Docker not found. Please install Docker.${NC}"
    exit 1
fi
echo -e "${GREEN}  Docker installed${NC}"

if ! command -v curl &> /dev/null; then
    echo -e "${RED}Error: curl not found. Please install curl.${NC}"
    exit 1
fi
echo -e "${GREEN}  curl installed${NC}"

if ! command -v grpcurl &> /dev/null; then
    echo -e "${RED}Error: grpcurl not found. Install: brew install grpcurl${NC}"
    exit 1
fi
echo -e "${GREEN}  grpcurl installed${NC}"

if ! command -v python3 &> /dev/null; then
    echo -e "${RED}Error: python3 not found.${NC}"
    exit 1
fi
echo -e "${GREEN}  python3 installed${NC}"

# Optional: zed for schema management
if command -v zed &> /dev/null; then
    echo -e "${GREEN}  zed CLI installed (for schema management)${NC}"
    HAS_ZED=true
else
    echo -e "${YELLOW}  zed CLI not found (schema must be loaded via Docker)${NC}"
    HAS_ZED=false
fi
echo ""

RELATIONS_API="http://localhost:8082"
KESSEL_INVENTORY_API="http://localhost:8083"
INVENTORY_API="http://localhost:8081"
RBAC_API="http://localhost:8080"
RELATIONS_GRPC="${RELATIONS_GRPC:-localhost:9001}"
INVENTORY_GRPC="${INVENTORY_GRPC:-localhost:9002}"

# Check Relations API is running via gRPC
echo -e "${YELLOW}Checking services...${NC}"
if ! grpcurl -plaintext "$RELATIONS_GRPC" grpc.health.v1.Health/Check &>/dev/null; then
    echo -e "${RED}Error: Relations API not reachable at $RELATIONS_GRPC (gRPC)${NC}"
    echo "Start services: cd compose && docker compose up -d"
    exit 1
fi
echo -e "${GREEN}  Relations API is running (gRPC: $RELATIONS_GRPC)${NC}"

if ! grpcurl -plaintext "$INVENTORY_GRPC" grpc.health.v1.Health/Check &>/dev/null; then
    echo -e "${YELLOW}  Kessel Inventory API not reachable at $INVENTORY_GRPC (gRPC)${NC}"
else
    echo -e "${GREEN}  Kessel Inventory API is running (gRPC: $INVENTORY_GRPC)${NC}"
fi

if ! curl -s "$INVENTORY_API/health" &>/dev/null; then
    echo -e "${YELLOW}  Insights Inventory API not reachable (host creation will be skipped)${NC}"
else
    echo -e "${GREEN}  Insights Inventory API is running${NC}"
fi

if ! curl -s "$RBAC_API/api/rbac/v1/status/" &>/dev/null; then
    echo -e "${YELLOW}  RBAC API not reachable (workspace creation will be skipped)${NC}"
else
    echo -e "${GREEN}  RBAC API is running${NC}"
fi

# Load schema if zed is available
if [ "$HAS_ZED" = true ]; then
    SPICEDB_ENDPOINT="localhost:50051"
    AUTH_TOKEN="testtesttesttest"

    SCHEMA_DEFS=$(zed --endpoint "$SPICEDB_ENDPOINT" --token "$AUTH_TOKEN" --insecure \
        schema read 2>/dev/null | grep "^definition " | wc -l | tr -d ' ')

    if [ "$SCHEMA_DEFS" -lt 8 ]; then
        echo -e "${YELLOW}  Stage schema not loaded, loading now...${NC}"
        zed --endpoint "$SPICEDB_ENDPOINT" --token "$AUTH_TOKEN" --insecure \
            schema write "$PROJECT_ROOT/services/spicedb/schema/schema.zed" 2>/dev/null
    fi
    echo -e "${GREEN}  Stage schema loaded ($SCHEMA_DEFS definitions)${NC}"
fi
echo ""

# Create demo directory
DEMO_DIR="/tmp/kessel-demo"
mkdir -p "$DEMO_DIR"

echo -e "${YELLOW}Generating demo data files (Relations API CreateTuples format)...${NC}"

# Demo data files use the real project-kessel/relations-api CreateTuples format
# Each file contains a CreateTuplesRequest body with tuples array

# Scenario 1: Team membership (group + principal)
cat > "$DEMO_DIR/scenario1-team-membership.json" << 'EOF'
{
  "tuples": [
    {
      "resource": { "type": { "namespace": "rbac", "name": "group" }, "id": "engineering" },
      "relation": "t_member",
      "subject": { "subject": { "type": { "namespace": "rbac", "name": "principal" }, "id": "alice" } }
    }
  ]
}
EOF

# Scenario 2: Create role + role binding + workspace
cat > "$DEMO_DIR/scenario2-workspace-access.json" << 'EOF'
{
  "tuples": [
    {
      "resource": { "type": { "namespace": "rbac", "name": "role" }, "id": "host_viewer" },
      "relation": "t_inventory_hosts_read",
      "subject": { "subject": { "type": { "namespace": "rbac", "name": "principal" }, "id": "*" } }
    },
    {
      "resource": { "type": { "namespace": "rbac", "name": "role_binding" }, "id": "eng_prod_binding" },
      "relation": "t_subject",
      "subject": { "subject": { "type": { "namespace": "rbac", "name": "group" }, "id": "engineering" }, "relation": "member" }
    },
    {
      "resource": { "type": { "namespace": "rbac", "name": "role_binding" }, "id": "eng_prod_binding" },
      "relation": "t_role",
      "subject": { "subject": { "type": { "namespace": "rbac", "name": "role" }, "id": "host_viewer" } }
    },
    {
      "resource": { "type": { "namespace": "rbac", "name": "tenant" }, "id": "techcorp" },
      "relation": "t_platform",
      "subject": { "subject": { "type": { "namespace": "rbac", "name": "platform" }, "id": "techcorp_defaults" } }
    },
    {
      "resource": { "type": { "namespace": "rbac", "name": "workspace" }, "id": "production" },
      "relation": "t_parent",
      "subject": { "subject": { "type": { "namespace": "rbac", "name": "tenant" }, "id": "techcorp" } }
    },
    {
      "resource": { "type": { "namespace": "rbac", "name": "workspace" }, "id": "production" },
      "relation": "t_binding",
      "subject": { "subject": { "type": { "namespace": "rbac", "name": "role_binding" }, "id": "eng_prod_binding" } }
    }
  ]
}
EOF

# Scenario 3: Host in workspace (inheritance)
cat > "$DEMO_DIR/scenario3-host-access.json" << 'EOF'
{
  "tuples": [
    {
      "resource": { "type": { "namespace": "hbi", "name": "host" }, "id": "web-server-01" },
      "relation": "t_workspace",
      "subject": { "subject": { "type": { "namespace": "rbac", "name": "workspace" }, "id": "production" } }
    }
  ]
}
EOF

# Scenario 4: Revocation (remove from group) — uses DELETE endpoint
cat > "$DEMO_DIR/scenario4-revoke.json" << 'EOF'
{
  "tuples": [
    {
      "resource": { "type": { "namespace": "rbac", "name": "group" }, "id": "engineering" },
      "relation": "t_member",
      "subject": { "subject": { "type": { "namespace": "rbac", "name": "principal" }, "id": "alice" } }
    }
  ]
}
EOF

# Scenario 5: Direct binding for alice
cat > "$DEMO_DIR/scenario5-direct-binding.json" << 'EOF'
{
  "tuples": [
    {
      "resource": { "type": { "namespace": "rbac", "name": "workspace" }, "id": "staging" },
      "relation": "t_parent",
      "subject": { "subject": { "type": { "namespace": "rbac", "name": "tenant" }, "id": "techcorp" } }
    },
    {
      "resource": { "type": { "namespace": "rbac", "name": "role_binding" }, "id": "alice_staging_binding" },
      "relation": "t_subject",
      "subject": { "subject": { "type": { "namespace": "rbac", "name": "principal" }, "id": "alice" } }
    },
    {
      "resource": { "type": { "namespace": "rbac", "name": "role_binding" }, "id": "alice_staging_binding" },
      "relation": "t_role",
      "subject": { "subject": { "type": { "namespace": "rbac", "name": "role" }, "id": "host_viewer" } }
    },
    {
      "resource": { "type": { "namespace": "rbac", "name": "workspace" }, "id": "staging" },
      "relation": "t_binding",
      "subject": { "subject": { "type": { "namespace": "rbac", "name": "role_binding" }, "id": "alice_staging_binding" } }
    },
    {
      "resource": { "type": { "namespace": "hbi", "name": "host" }, "id": "staging-app-01" },
      "relation": "t_workspace",
      "subject": { "subject": { "type": { "namespace": "rbac", "name": "workspace" }, "id": "staging" } }
    }
  ]
}
EOF

echo -e "${GREEN}  Demo data files created${NC}"
echo ""

# Create helper script
cat > "$DEMO_DIR/check-permission.sh" << 'EOFSCRIPT'
#!/bin/bash
# Quick permission check helper (gRPC)
# Routes hbi/* checks through Inventory API, rbac/* checks through Relations API
# Usage: check-permission.sh <principal> <permission> <resource_type:resource_id>
# Example: check-permission.sh alice view hbi/host:web-server-01

if [ $# -ne 3 ]; then
    echo "Usage: $0 <principal> <permission> <resource_type:resource_id>"
    echo "Example: $0 alice view hbi/host:web-server-01"
    echo "Example: $0 alice inventory_host_view rbac/workspace:production"
    exit 1
fi

PRINCIPAL=$1
PERMISSION=$2
RESOURCE=$3
RELATIONS_GRPC="${RELATIONS_GRPC:-localhost:9001}"
INVENTORY_GRPC="${INVENTORY_GRPC:-localhost:9002}"

# Parse resource_type (namespace/name) and resource_id
RESOURCE_TYPE=$(echo "$RESOURCE" | rev | cut -d: -f2- | rev)
RESOURCE_ID=$(echo "$RESOURCE" | rev | cut -d: -f1 | rev)
RESOURCE_NS=$(echo "$RESOURCE_TYPE" | cut -d/ -f1)
RESOURCE_NAME=$(echo "$RESOURCE_TYPE" | cut -d/ -f2)

# Route based on resource type and use appropriate request format
if echo "$RESOURCE_TYPE" | grep -q "^hbi/"; then
    GRPC_ENDPOINT="$INVENTORY_GRPC"
    GRPC_SERVICE="kessel.inventory.v1beta2.KesselInventoryService/Check"
    echo "Routing via Inventory API → Relations API (gRPC)" >&2
    # Inventory API format: object.resource_type (name), object.reporter.type (namespace)
    REQUEST_BODY="{
      \"object\": { \"resource_type\": \"$RESOURCE_NAME\", \"resource_id\": \"$RESOURCE_ID\", \"reporter\": { \"type\": \"$RESOURCE_NS\" } },
      \"relation\": \"$PERMISSION\",
      \"subject\": { \"resource\": { \"resource_type\": \"principal\", \"resource_id\": \"$PRINCIPAL\", \"reporter\": { \"type\": \"rbac\" } } }
    }"
else
    GRPC_ENDPOINT="$RELATIONS_GRPC"
    GRPC_SERVICE="kessel.relations.v1beta1.KesselCheckService/Check"
    echo "Routing via Relations API (direct, gRPC)" >&2
    # Relations API format: nested ObjectType{namespace, name}
    REQUEST_BODY="{
      \"resource\": { \"type\": { \"namespace\": \"$RESOURCE_NS\", \"name\": \"$RESOURCE_NAME\" }, \"id\": \"$RESOURCE_ID\" },
      \"relation\": \"$PERMISSION\",
      \"subject\": { \"subject\": { \"type\": { \"namespace\": \"rbac\", \"name\": \"principal\" }, \"id\": \"$PRINCIPAL\" } }
    }"
fi

grpcurl -plaintext -d "$REQUEST_BODY" "$GRPC_ENDPOINT" "$GRPC_SERVICE" | \
  python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('allowed','UNKNOWN'))" 2>/dev/null || \
  echo "ERROR: Could not check permission"
EOFSCRIPT

chmod +x "$DEMO_DIR/check-permission.sh"

echo -e "${GREEN}  Helper scripts created${NC}"
echo ""

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  Demo Ready!${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""
echo -e "${GREEN}  kessel-stack is running${NC}"
echo -e "${GREEN}  Demo data files ready (Relations API CreateTuples format)${NC}"
echo ""
echo -e "${YELLOW}Service URLs:${NC}"
echo "  Relations API (gRPC): $RELATIONS_GRPC"
echo "  Inventory API (gRPC): $INVENTORY_GRPC"
echo "  Relations API (HTTP): $RELATIONS_API"
echo "  Kessel Inventory API: $KESSEL_INVENTORY_API"
echo "  Insights Inventory:   $INVENTORY_API"
echo "  Insights RBAC:        $RBAC_API"
echo ""
echo -e "${YELLOW}Permission Check Routing (gRPC):${NC}"
echo "  hbi/* → $INVENTORY_GRPC (KesselInventoryService/Check) → Relations API → SpiceDB"
echo "  rbac/* → $RELATIONS_GRPC (KesselCheckService/Check) → SpiceDB (direct, like insights-rbac)"
echo ""
echo -e "${YELLOW}Demo Resources:${NC}"
echo "  Demo directory:  $DEMO_DIR"
echo "  Demo script:     $PROJECT_ROOT/scripts/demo-run.sh"
echo "  Demo guide:      $PROJECT_ROOT/DEMO_GUIDE.md"
echo ""
echo -e "${YELLOW}Quick Test:${NC}"
echo "  $DEMO_DIR/check-permission.sh alice view hbi/host:web-server-01"
echo ""
echo -e "${YELLOW}Run Demo:${NC}"
echo "  $PROJECT_ROOT/scripts/demo-run.sh"
echo ""
