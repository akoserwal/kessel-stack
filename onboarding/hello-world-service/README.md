# Hello World: edge-device-service

A complete, runnable Go service that demonstrates the full Kessel CDC Outbox integration pattern.

The service manages **edge devices** — a new resource type that doesn't exist in the current
stage schema. Walking through this example shows every step a real team would follow to
onboard a new service into Kessel.

---

## What this demonstrates

| Step | What happens |
|------|-------------|
| 1 | Define `edge/device` in KSL (rbac-config style) → compile to `.zed` |
| 2 | Add permissions and roles to rbac-config JSON files |
| 3 | Register a Debezium connector watching `edge.outbox` |
| 4 | POST /devices → ghost-row outbox write → Debezium → Kafka |
| 5 | Embedded consumer reads from Kafka → calls Relations API → SpiceDB tuple created |
| 6 | POST /check → Relations API CheckPermission → permitted/denied |

---

## Architecture

```
                     [edge-device-service :8085]
                            │
              ┌─────────────┴──────────────┐
              │  HTTP API                  │  Consumer goroutine
              │  POST /api/edge/v1/devices │  reads: outbox.event.edge.devices
              │                            │
              ▼                            ▼
        postgres-edge-devices        kafka:29092
        edge.devices table           (from kessel-in-a-box-real)
        edge.outbox table
              │
              ▼
        Debezium (kafka-connect)
        edge-device-outbox-connector
        watches: edge.outbox
              │
              ▼
        Kafka topic: outbox.event.edge.devices
              │
              ▼
        Consumer goroutine
              │
              ▼
        kessel-relations-api:8082
        POST /api/authz/v1beta1/tuples
              │
              ▼
        SpiceDB
        tuple: edge/device:{id}#t_workspace@rbac/workspace:{ws_id}
```

---

## Prerequisites

- kessel-in-a-box-real is running (`bash scripts/deploy.sh` from project root)
- Docker and Docker Compose
- `jq` installed
- `go 1.21+` (only needed if you want to run locally without Docker)

---

## Step 1 — Understand the schema

### 1a. KSL source (`schema/edge.ksl`)

The KSL file is what you'd add to `rbac-config/configs/prod/schemas/src/`:

```ksl
version 0.1
namespace edge

import rbac

public type device {
    private relation workspace: [ExactlyOne rbac.workspace]

    @rbac.add_v1_based_permission(app:'edge', resource:'devices', verb:'read',  v2_perm:'edge_device_view')
    relation view: workspace.edge_device_view

    @rbac.add_v1_based_permission(app:'edge', resource:'devices', verb:'write', v2_perm:'edge_device_update')
    relation update: workspace.edge_device_update

    @rbac.add_v1_based_permission(app:'edge', resource:'devices', verb:'write', v2_perm:'edge_device_delete')
    relation delete: workspace.edge_device_delete
}
```

The `@add_v1_based_permission` decorator tells the KSL compiler to:
1. Add `edge_device_view` to `rbac/role`, `rbac/role_binding`, `rbac/platform`, `rbac/tenant`, `rbac/workspace`
2. Wire them together so the permission propagates through the hierarchy
3. Map V1 permission `edge:devices:read` → V2 SpiceDB check `edge_device_view`

### 1b. Compiled ZED (`schema/edge.zed`)

The `edge.zed` file is what actually gets loaded into SpiceDB. It's self-contained for this demo
(includes the RBAC workspace hierarchy subset). In production, it would be merged into the full schema.

Key pattern: every permission on `edge/device` is delegated to its workspace:

```zed
definition edge/device {
    relation t_workspace: rbac/workspace
    permission view   = t_workspace->edge_device_view
    permission update = t_workspace->edge_device_update
    permission delete = t_workspace->edge_device_delete
}
```

**SpiceDB traverses**: `edge/device → t_workspace → rbac/workspace → t_binding → rbac/role_binding → t_subject` then checks if the requesting principal is a t_subject.

### 1c. Compile the schema (rbac-config toolchain)

```bash
cd /path/to/rbac-config

# Copy edge.ksl to the src directory
cp /path/to/edge.ksl configs/prod/schemas/src/edge.ksl

# Compile
make init              # install ksl compiler (first time only)
make ksl-test-schema-stage   # outputs _private/test-schema/stage-schema.zed
```

---

## Step 2 — rbac-config permissions and roles

### `rbac-config/permissions.json`

Copy to `rbac-config/configs/prod/permissions/edge.json`:

```json
{
    "devices": [
        { "verb": "read",  "description": "View edge devices" },
        { "verb": "write", "description": "Register, update, deregister edge devices", "requires": ["read"] },
        { "verb": "*" }
    ]
}
```

Permission strings this generates: `edge:devices:read`, `edge:devices:write`, `edge:devices:*`

### `rbac-config/roles.json`

Copy to `rbac-config/configs/prod/roles/edge.json`. These become system roles seeded into every tenant.

---

## Step 3 — Ghost-row outbox write pattern

The core integration pattern in `main.go`:

```go
func createDevice(db *sql.DB, device Device) error {
    tx, _ := db.Begin()
    defer tx.Rollback()

    // 1. Write the device record
    tx.Exec(`INSERT INTO edge.devices (id, display_name, workspace_id, ...) VALUES (...)`, ...)

    // 2. Write the outbox ghost-row (Debezium captures this INSERT from WAL)
    outboxID := uuid.New().String()
    tx.Exec(`
        INSERT INTO edge.outbox (id, aggregatetype, aggregateid, type, payload, operation)
        VALUES ($1, 'devices', $2, 'ReportResource', $3::jsonb, 'created')`,
        outboxID, device.ID, payloadJSON)

    // 3. Delete immediately (ghost-row pattern — Debezium already saw the INSERT in WAL)
    tx.Exec(`DELETE FROM edge.outbox WHERE id = $1`, outboxID)

    return tx.Commit()
    // If Commit() succeeds: Debezium will publish the message to Kafka
    // If Commit() fails: nothing was published (transactional guarantee)
}
```

---

## Step 4 — Run the service

```bash
# From the hello-world-service directory
cd onboarding/hello-world-service

# Build and start the service + its postgres
docker compose -f compose/docker-compose.yml up --build -d

# Verify it started
curl http://localhost:8085/health
# → {"status":"ok"}

# Check readiness (waits for DB)
curl http://localhost:8085/ready
# → {"status":"ready"}
```

---

## Step 5 — Run the setup script

The setup script loads the schema, registers the connector, and runs an end-to-end test:

```bash
bash setup.sh
```

What it does:
1. Loads `schema/edge.zed` into SpiceDB
2. Registers `config/connector.json` with Kafka Connect (Debezium)
3. Creates a test workspace in RBAC
4. Creates SpiceDB tuples granting `alice` view access on the workspace
5. Creates a test device via `POST /api/edge/v1/devices`
6. Waits for the CDC pipeline to deliver the `edge/device` → `rbac/workspace` tuple to SpiceDB
7. Verifies `CheckPermission` returns PERMITTED for alice + view

---

## Step 6 — Try the API manually

```bash
# Create a device
curl -X POST http://localhost:8085/api/edge/v1/devices \
  -H "Content-Type: application/json" \
  -d '{
    "display_name": "Factory Floor Sensor A1",
    "workspace_id": "<your-workspace-id>",
    "org_id": "12345"
  }'
# Returns: {"id":"<device-id>","display_name":"Factory Floor Sensor A1",...}

# List devices
curl http://localhost:8085/api/edge/v1/devices

# Check permission (after CDC pipeline delivers the tuple ~2-5s)
curl -X POST http://localhost:8085/api/edge/v1/check \
  -H "Content-Type: application/json" \
  -d '{
    "device_id":  "<device-id>",
    "permission": "view",
    "subject_id": "alice"
  }'
# Returns: {"permitted": true}

# Delete device (also writes a DeleteResource outbox event)
curl -X DELETE http://localhost:8085/api/edge/v1/devices/<device-id>
```

---

## Observing the pipeline

```bash
# Watch the Kafka outbox topic in real time
docker exec kessel-kafka kafka-console-consumer \
  --bootstrap-server localhost:9092 \
  --topic outbox.event.edge.devices \
  --from-beginning

# Check Debezium connector status
curl http://localhost:8084/connectors/edge-device-outbox-connector/status | jq .

# Check connector lag (how many messages are pending)
docker exec kessel-kafka kafka-consumer-groups \
  --bootstrap-server localhost:9092 \
  --group edge-device-consumer \
  --describe

# Query SpiceDB tuples for edge/device
curl -s -X POST http://localhost:8082/api/authz/v1beta1/readtuples \
  -H "Content-Type: application/json" \
  -d '{"resourceType":{"namespace":"edge","name":"device"}}' | jq .

# View edge-device-service logs (shows consumer processing)
docker logs edge-device-service -f
```

---

## Running locally (without Docker)

```bash
# Prerequisites: kessel-in-a-box-real running, and postgres-edge-devices running

# Start just the postgres
docker compose -f compose/docker-compose.yml up -d postgres-edge-devices

# Run the service
DB_HOST=localhost \
DB_PORT=5436 \
KAFKA_BROKERS=localhost:9092 \
RELATIONS_API_URL=http://localhost:8082 \
  go run main.go
```

---

## How it maps to the production pattern

| This example | Production |
|-------------|-----------|
| `edge.outbox` ghost-row | `hbi.outbox` in HBI / `public.outbox_events` in kessel-inventory-api |
| Embedded consumer goroutine | Official `project-kessel/inventory-consumer` |
| Direct Relations API call | Via `kessel-inventory-api` (which manages resource metadata + calls Relations API) |
| `schema/edge.zed` | `rbac-config` compiled schema deployed to stage/prod |
| `rbac-config/permissions.json` | `rbac-config/configs/prod/permissions/edge.json` |
| `rbac-config/roles.json` | `rbac-config/configs/prod/roles/edge.json` |

---

## Next steps

1. Read [`../01-integration-decision-guide.md`](../01-integration-decision-guide.md) to understand when to use this pattern vs. direct gRPC
2. Copy the templates from [`../02-outbox-template/`](../02-outbox-template/) to your service
3. Review the production HBI integration in [`../../compose/docker-compose.insights.yml`](../../compose/docker-compose.insights.yml)
4. Review the production schema in [`../../services/spicedb/schema/schema.zed`](../../services/spicedb/schema/schema.zed) to see how `hbi/host` is defined — your service follows the same pattern
