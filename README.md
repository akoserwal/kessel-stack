# Kessel-in-a-Box

**Complete local development environment for Kessel authorization platform**

A production-aligned, event-driven authorization system demonstrating Google Zanzibar-based Relationship-Based Access Control (ReBAC) with Change Data Capture (CDC) integration.

## What is Kessel-in-a-Box?

Kessel-in-a-box is a **complete, working implementation** of Red Hat's Kessel platform that runs entirely on your local machine using real upstream service images. It demonstrates:

- **ReBAC Authorization** using SpiceDB (Google Zanzibar)
- **Event-Driven Architecture** with Kafka CDC pipeline (transactional outbox pattern)
- **Microservices Integration** with Kessel gRPC APIs
- **Real Application Patterns** (RBAC and Host Inventory with two-stage CDC)
- **Production-Aligned Architecture** matching Red Hat's hosted deployment

All services use real upstream images from `quay.io/cloudservices` and official sources — no mocks.

## Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│                     APPLICATION LAYER                            │
│  insights-rbac (8080)          insights-host-inventory (8081)    │
│  quay.io/cloudservices/rbac    quay.io/cloudservices/            │
│                                insights-inventory                │
│  ↳ RBAC Celery Worker          ↳ insights-inventory-mq (opt.)   │
└────────────┬───────────────────────────────┬─────────────────────┘
             │ management_outbox (CDC)        │ Kafka host-ingress /
             │ REPLICATION_TO_RELATION=true   │ postgres-inventory CDC
             ↓                               ↓
┌──────────────────────────────────────────────────────────────────┐
│                     CONSUMER / EVENT LAYER                       │
│  insights-rbac-kafka-consumer      inventory-consumer            │
│  (outbox.event.relations-          (project-kessel/              │
│   replication-event → gRPC)         inventory-consumer)          │
└────────────┬───────────────────────────────┬─────────────────────┘
             │ gRPC (CreateTuples)            │ gRPC (ReportResource)
             ↓                               ↓
┌──────────────────────────────────────────────────────────────────┐
│                     KESSEL PLATFORM LAYER                        │
│  kessel-relations-api (8082/9001)  kessel-inventory-api          │
│                                    (8083/9002)                   │
│                                    ↳ postgres-kessel-inventory   │
│                                      (5435) + Stage-2 CDC        │
└───────────────────────────────┬──────────────────────────────────┘
                                │ gRPC (CheckPermission /
                                │ WriteRelationships)
                                ↓
┌──────────────────────────────────────────────────────────────────┐
│                   AUTHORIZATION ENGINE                           │
│  SpiceDB (50051 gRPC / 8443 HTTP) → postgres-spicedb (5434)     │
└──────────────────────────────────────────────────────────────────┘

Event backbone: Kafka (9092) + Kafka Connect/Debezium (8084)
Data stores: postgres-rbac (5432), postgres-inventory (5433),
             postgres-kessel-inventory (5435), postgres-spicedb (5434)
```

## Quick Start

### Prerequisites

- Docker/Podman and Docker Compose V2
- `grpcurl` (for gRPC health checks and demo)
- 8 GB RAM minimum, 20 GB disk space

### Deploy Everything

```bash
# Check prerequisites and port availability
./scripts/precheck.sh

# Deploy all services (full stack with Kafka)
./scripts/deploy.sh

# Minimal deploy — core services only, no Kafka/CDC
./scripts/deploy.sh --minimal
```

### Run the Demo

```bash
# Set up demo data (verifies all services)
./scripts/demo-setup.sh

# Run interactive authorization demo (5 scenarios)
./scripts/demo-run.sh
```

## Service Endpoints

### Application Layer

| Service | Port | Purpose |
|---------|------|---------|
| insights-rbac | `8080` | RBAC management — workspaces, roles, groups (v1 + v2 API) |
| insights-host-inventory | `8081` | Host inventory — read-only REST; write via Kafka ingress |

All requests to Insights services require an `x-rh-identity` header (base64-encoded JSON):

```bash
IDENTITY=$(echo -n '{"identity":{"account_number":"12345","org_id":"12345","type":"User","auth_type":"basic-auth","user":{"username":"admin","email":"admin@example.com","is_org_admin":true}}}' | base64)
```

**RBAC API:**

```bash
# Status
curl http://localhost:8080/api/rbac/v1/status/

# Workspaces (v2 — note trailing slash)
curl -H "x-rh-identity: $IDENTITY" http://localhost:8080/api/rbac/v2/workspaces/
curl -H "x-rh-identity: $IDENTITY" http://localhost:8080/api/rbac/v2/workspaces/?type=root
curl -H "x-rh-identity: $IDENTITY" http://localhost:8080/api/rbac/v2/workspaces/?type=default

# Create workspace
curl -X POST http://localhost:8080/api/rbac/v2/workspaces/ \
  -H "Content-Type: application/json" \
  -H "x-rh-identity: $IDENTITY" \
  -d '{"name": "my-workspace"}'

# Groups / Roles (v1)
curl -H "x-rh-identity: $IDENTITY" http://localhost:8080/api/rbac/v1/groups/
curl -H "x-rh-identity: $IDENTITY" http://localhost:8080/api/rbac/v1/roles/
```

**Host Inventory API:**

```bash
# Health
curl -sf http://localhost:8081/health

# List hosts (read-only)
curl -H "x-rh-identity: $IDENTITY" http://localhost:8081/api/inventory/v1/hosts

# Note: host creation goes via Kafka ingress (platform.inventory.host-ingress),
# not via REST POST — the REST API is read-only for hosts.
```

### Kessel Platform Layer

Both Kessel APIs are **gRPC-primary**. HTTP is available for health/livez only.

| Service | HTTP | gRPC | Purpose |
|---------|------|------|---------|
| kessel-relations-api | `8082` | `9001` | Relationship management + permission checks |
| kessel-inventory-api | `8083` | `9002` | Resource inventory + authz proxy |

```bash
# Relations API gRPC health
grpcurl -plaintext localhost:9001 grpc.health.v1.Health/Check

# Create a relationship tuple
grpcurl -plaintext -d '{
  "tuples":[{"resource":{"type":{"namespace":"rbac","name":"workspace"},"id":"production"},
             "relation":"inventory_host_view",
             "subject":{"subject":{"type":{"namespace":"rbac","name":"principal"},"id":"alice"}}}],
  "upsert":true}' \
  localhost:9001 kessel.relations.v1beta1.KesselTupleService/CreateTuples

# Check a permission (rbac/* resources)
grpcurl -plaintext -d '{
  "resource":{"type":{"namespace":"rbac","name":"workspace"},"id":"production"},
  "relation":"inventory_host_view",
  "subject":{"subject":{"type":{"namespace":"rbac","name":"principal"},"id":"alice"}}}' \
  localhost:9001 kessel.relations.v1beta1.KesselCheckService/Check

# Inventory API gRPC health
grpcurl -plaintext localhost:9002 grpc.health.v1.Health/Check

# Check a host permission (routes inventory-api → relations-api → SpiceDB)
grpcurl -plaintext -d '{
  "object":{"resource_type":"host","resource_id":"web-server-01","reporter":{"type":"hbi"}},
  "relation":"view",
  "subject":{"resource":{"resource_type":"principal","resource_id":"alice","reporter":{"type":"rbac"}}}}' \
  localhost:9002 kessel.inventory.v1beta2.KesselInventoryService/Check

# Inventory API HTTP livez
curl http://localhost:8083/api/kessel/v1/livez
```

### Authorization Engine

```bash
# SpiceDB HTTP health
curl http://localhost:8443/healthz

# SpiceDB gRPC (used internally by kessel-relations-api)
grpcurl -plaintext localhost:50051 grpc.health.v1.Health/Check

# SpiceDB Prometheus metrics
curl http://localhost:9090/metrics | head -20
```

### Infrastructure

| Service | Port | Purpose |
|---------|------|---------|
| PostgreSQL RBAC | `5432` | RBAC database (`wal_level=logical`, outbox source) |
| PostgreSQL Inventory | `5433` | HBI database (`wal_level=logical`, Stage-1 CDC source) |
| PostgreSQL Kessel Inventory | `5435` | kessel-inventory-api datastore (`wal_level=logical`, Stage-2 CDC source) |
| PostgreSQL SpiceDB | `5434` | SpiceDB relationship storage |
| Kafka | `9092` | Event broker |
| Kafka Connect | `8084` | Debezium REST API |
| Kafka UI | `8086` | Web UI — `http://localhost:8086` |
| Zookeeper | `2181` | Kafka coordination |
| Redis | `6379` | RBAC Celery broker |

### Observability

| Service | Port | Purpose |
|---------|------|---------|
| Prometheus | `9091` | Metrics — `http://localhost:9091` |
| Grafana | `3000` | Dashboards — `http://localhost:3000` (admin/admin) |
| AlertManager | `9093` | Alerts — `http://localhost:9093` |
| Node Exporter | `9100` | Host metrics |
| Health Exporter | `9094` | Service health → Prometheus bridge |

### Monitoring Dashboard & Management Console

Two local web tools ship with the box. See [docs/monitoring-and-console.md](docs/monitoring-and-console.md) for full details.

| Tool | URL | Start |
|------|-----|-------|
| Monitoring dashboard | `http://localhost:8888` | `cd monitoring && python3 app.py` |
| Management console | `http://localhost:8889` | `cd console && go run .` |

## Data Flows

### Flow 1: Workspace Creation (RBAC → Outbox CDC → SpiceDB)

```
User → POST /api/rbac/v2/workspaces/ (x-rh-identity required)
  ↓ atomic: INSERT INTO workspaces + INSERT INTO management_outbox
postgres-rbac (wal_level=logical)
  ↓ WAL → Debezium rbac-connector (kafka-connect :8084)
  ↓ EventRouter SMT → outbox.event.relations-replication-event
Kafka
  ↓ insights-rbac-kafka-consumer
    (python manage.py launch-rbac-kafka-consumer)
kessel-relations-api gRPC :9000 → CreateTuples / DeleteTuples
  ↓
SpiceDB
```

**Latency**: 2–5 s (eventual consistency via CDC)

The outbox write is gated by `REPLICATION_TO_RELATION_ENABLED=true`. The management_outbox row is created and immediately deleted within the same transaction — Debezium captures the INSERT before the DELETE, producing an event without leaving a record in the table (ghost-row pattern).

### Flow 2: Host Registration (Two-Stage CDC)

**Stage 1 — HBI → inventory-consumer → kessel-inventory-api:**

```
Host agent → platform.inventory.host-ingress (Kafka topic)
  ↓ inv_mq_service.py (optional — commented out by default)
insights-host-inventory: REST API or direct DB write
  ↓ INSERT INTO hbi.hosts (postgres-inventory, wal_level=logical)
  ↓ WAL → Debezium hbi-outbox-connector (kafka-connect :8084)
Kafka → outbox events topic
  ↓ inventory-consumer (project-kessel/inventory-consumer)
kessel-inventory-api gRPC :9002 → ReportResource
  ↓ writes to postgres-kessel-inventory (5435)
```

**Stage 2 — kessel-inventory-api outbox → kessel-relations-api → SpiceDB:**

```
postgres-kessel-inventory (wal_level=logical) — public.outbox_events
  ↓ WAL → Debezium kessel-inventory-api-connector (kafka-connect :8084)
Kafka
  ↓ kessel-relations-api internal consumer
kessel-relations-api → SpiceDB WriteRelationships
```

**Latency**: 5–15 s end-to-end (two CDC hops)

### Flow 3: Permission Check

```
App → kessel-inventory-api gRPC :9002: Check (hbi/* resources)
   OR kessel-relations-api gRPC :9001: Check (rbac/* resources)
  ↓ kessel-relations-api → SpiceDB :50051 CheckPermission
  ↓ Graph traversal through relationship tuples
SpiceDB → ALLOWED_TRUE / ALLOWED_FALSE
```

**Latency**: 5–50 ms

## Schema Management (KSL)

The SpiceDB permission schema is maintained as KSL source files compiled to ZED:

```
schemas/
├── ksl/                          # KSL source files
│   ├── rbac.ksl                  # RBAC permission model
│   └── inventory.ksl             # Inventory resource types
├── kessel-authorization.zed      # Compiled output (applied to SpiceDB)
└── resources/                    # kessel-inventory-api resource type configs
```

**Compile and apply:**

```bash
# Compile KSL → ZED (requires ksl CLI on PATH)
./scripts/compile-schema.sh

# Or via management console API
curl -X POST http://localhost:8889/api/mgmt/schema/compile

# Apply compiled schema to SpiceDB
curl -X POST http://localhost:8889/api/mgmt/schema \
  -H "Content-Type: application/json" \
  -d "{\"schema\": \"$(cat schemas/kessel-authorization.zed | jq -Rs .)\"}"
```

**RBAC v1→v2 migration extension:**

```ksl
// Make a v1-named permission also available under the v2 name
@rbac.add_v1_based_permission(v1_name="read", v2_name="view")
permission view = ...
```

See the [migration guide](https://project-kessel.github.io/docs/building-with-kessel/how-to/migrate-from-rbac-v1-to-v2/) for the full v1→v2 pattern including workspace types.

## Onboarding New Services

Use the 7-step wizard at `http://localhost:8888/app-onboarding.html` or call the API directly:

```bash
# Stream onboarding progress via SSE
curl -N -X POST http://localhost:8889/api/mgmt/onboard \
  -H "Content-Type: application/json" \
  -d '{
    "app_name": "my-service",
    "db": {"host": "localhost", "port": 5432, "name": "mydb", "user": "myuser", "password": "secret"},
    "cdc": {"connector_name": "my-service-connector"},
    "kafka": {"topics": ["my-service.events"]},
    "schema": {"additions": "definition my_service/resource { ... }"},
    "rbac_config": {
      "workspace_name": "my-service-workspace",
      "workspace_pattern": "native"
    }
  }'
```

**Workspace patterns** (`workspace_pattern`):

| Pattern | Behaviour |
|---------|-----------|
| `native` | Creates a new child workspace under the root workspace |
| `default` | Creates a new child workspace under the default workspace |
| `root` | Uses the root workspace directly — no child created |
| `org` | Organisation-level checks — no workspace required |

The `onboarding/` directory contains a `hello-world-service` example with pre-filled values.

## Testing

```bash
# Full test suite
./scripts/run-all-tests.sh

# Service health validation
./scripts/validate.sh

# Comprehensive flow verification
./scripts/verify-all-flows.sh
```

## Management

### View Logs

```bash
# All services
docker compose \
  -f compose/docker-compose.yml \
  -f compose/docker-compose.kessel.yml \
  -f compose/docker-compose.kafka.yml \
  -f compose/docker-compose.insights.yml \
  logs -f

# Specific service
docker logs -f insights-rbac
docker logs -f insights-rbac-kafka-consumer
docker logs -f insights-host-inventory
docker logs -f kessel-relations-api
docker logs -f kessel-inventory-api
docker logs -f kessel-inventory-consumer
```

### Database Access

```bash
# RBAC database — check outbox table
docker exec -it kessel-postgres-rbac psql -U rbac -d rbac
# SELECT * FROM management_outbox LIMIT 10;

# HBI database (hbi schema — created by Alembic)
docker exec -it kessel-postgres-inventory psql -U inventory -d inventory
# \dt hbi.*

# kessel-inventory-api database — check Stage-2 outbox
docker exec -it kessel-postgres-kessel-inventory psql -U inventory -d inventory
# SELECT * FROM outbox_events ORDER BY created_at DESC LIMIT 10;

# SpiceDB database
docker exec -it kessel-postgres-spicedb psql -U spicedb -d spicedb
```

### Monitor CDC

```bash
# Debezium connector status (Kafka Connect on port 8084)
curl http://localhost:8084/connectors | jq
curl http://localhost:8084/connectors/rbac-connector/status | jq
curl http://localhost:8084/connectors/hbi-outbox-connector/status | jq
curl http://localhost:8084/connectors/kessel-inventory-api-connector/status | jq

# Restart a connector
curl -X POST http://localhost:8084/connectors/rbac-connector/restart

# Or use the management console
curl http://localhost:8889/api/mgmt/cdc/connectors | jq

# Kafka UI
open http://localhost:8086
```

## Troubleshooting

### Services won't start

```bash
docker logs <container-name>
docker ps --format "table {{.Names}}\t{{.Status}}"
```

### HBI returns 401/400 errors

The real HBI requires a valid `x-rh-identity` header with `auth_type` on every request:

```bash
IDENTITY=$(echo -n '{"identity":{"account_number":"12345","org_id":"12345","type":"User","auth_type":"basic-auth","user":{"username":"admin","email":"admin@example.com","is_org_admin":true}}}' | base64)
curl -H "x-rh-identity: $IDENTITY" http://localhost:8081/api/inventory/v1/hosts
```

### HBI returns 405 on POST /hosts

The real HBI REST API is **read-only** for hosts. Host creation is supported only via Kafka ingress on `platform.inventory.host-ingress`. The `inv_mq_service` consumer is commented out by default — uncomment it in `compose/docker-compose.insights.yml` to enable.

### RBAC returns 404 on /api/v1/workspaces

Workspaces are on the **v2** API. Groups and roles remain on v1:

```bash
curl -H "x-rh-identity: $IDENTITY" http://localhost:8080/api/rbac/v2/workspaces/   # v2
curl -H "x-rh-identity: $IDENTITY" http://localhost:8080/api/rbac/v1/groups/        # v1
```

### Kessel APIs return 404 on /health

Both Kessel APIs are gRPC-primary:

```bash
grpcurl -plaintext localhost:9001 grpc.health.v1.Health/Check  # Relations API
grpcurl -plaintext localhost:9002 grpc.health.v1.Health/Check  # Inventory API
curl http://localhost:8083/api/kessel/v1/livez                 # Inventory API HTTP livez
curl http://localhost:8080/api/rbac/v1/status/                 # RBAC status
```

### CDC not working / relations not appearing in SpiceDB

```bash
# Check replication slots exist
docker exec kessel-postgres-rbac psql -U rbac -d rbac \
  -c "SELECT slot_name, active FROM pg_replication_slots;"
docker exec kessel-postgres-inventory psql -U inventory -d inventory \
  -c "SELECT slot_name, active FROM pg_replication_slots;"
docker exec kessel-postgres-kessel-inventory psql -U inventory -d inventory \
  -c "SELECT slot_name, active FROM pg_replication_slots;"

# Verify WAL level (must be logical on all three)
docker exec kessel-postgres-rbac psql -U rbac -c "SHOW wal_level;"
docker exec kessel-postgres-inventory psql -U inventory -c "SHOW wal_level;"

# Check connector health
curl http://localhost:8084/connectors/rbac-connector/status | jq .connector.state

# Restart connector if FAILED
curl -X POST http://localhost:8084/connectors/rbac-connector/restart
```

### Dashboard shows "console offline"

The management console must be running separately:

```bash
cd console && go run .
# Listens on :8889 — dashboard polls http://localhost:8889/api/mgmt/status
```

### SpiceDB schema empty after docker compose up

The schema is loaded by `spicedb-schema-loader` which runs once at startup. If it failed:

```bash
docker logs kessel-spicedb-schema-loader

# Re-apply manually
curl -X POST http://localhost:8889/api/mgmt/schema \
  -H "Content-Type: application/json" \
  -d "{\"schema\": \"$(cat schemas/kessel-authorization.zed | jq -Rs .)\"}"
```

## References

- [project-kessel/relations-api](https://github.com/project-kessel/relations-api)
- [project-kessel/inventory-api](https://github.com/project-kessel/inventory-api)
- [project-kessel/inventory-consumer](https://github.com/project-kessel/inventory-consumer)
- [RedHatInsights/insights-rbac](https://github.com/RedHatInsights/insights-rbac)
- [RedHatInsights/insights-host-inventory](https://github.com/RedHatInsights/insights-host-inventory)
- [RedHatInsights/rbac-config](https://github.com/RedHatInsights/rbac-config) — SpiceDB schema (KSL source)
- [Kessel RBAC v1→v2 Migration Guide](https://project-kessel.github.io/docs/building-with-kessel/how-to/migrate-from-rbac-v1-to-v2/)
- [SpiceDB Documentation](https://authzed.com/docs/spicedb)
- [Debezium Documentation](https://debezium.io/documentation/)
- [Google Zanzibar Paper](https://research.google/pubs/pub48190/)
