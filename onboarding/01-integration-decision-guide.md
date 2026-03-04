# Integration Decision Guide

How to decide which Kessel integration pattern to use for your service.

---

## The two patterns

### Pattern A — Direct gRPC Replication

Your service calls the Relations API **synchronously** whenever it writes a relationship-relevant record.

```
Your Service (write path)
    │
    ├── writes record to its own DB
    │
    └── immediately calls kessel-relations-api gRPC :9000
            CreateTuples / DeleteTuples
                │
                └── SpiceDB
```

**Used by**: `insights-rbac`

**How it's enabled**: Set `REPLICATION_TO_RELATION_ENABLED=true` and
`RELATION_API_SERVER=kessel-relations-api:9000` in your service's environment.

**Characteristics**:
- Simpler to implement (no Kafka, no Debezium, no consumer)
- Synchronous — the write path blocks until SpiceDB confirms
- If the Relations API is down, your write path fails (unless you add retries/circuit breakers)
- Suitable for low-volume management operations (workspaces, roles, groups)

---

### Pattern B — Kafka CDC Outbox (Two-Stage Transactional Outbox)

Your service writes a **ghost-row** to a local outbox table inside the same database transaction
as the main record. Debezium captures the INSERT from PostgreSQL WAL and publishes it to Kafka.
A consumer picks it up and calls Kessel APIs.

```
Your Service (write path)
    │
    ├── BEGIN TRANSACTION
    │     ├── INSERT your_record
    │     ├── INSERT outbox_row   ← ghost row (INSERT + DELETE in same txn)
    │     └── DELETE outbox_row   ← Debezium captures INSERT from WAL before DELETE
    └── COMMIT
          │
          (async, seconds later)
          │
     Debezium (hbi-outbox-connector)
          │
          ▼
     Kafka topic: outbox.event.<your-service>.<resource-type>
          │
          ▼
     Consumer (inventory-consumer or custom)
          │
          ▼
     kessel-inventory-api gRPC :9000
          ReportResource / DeleteResource
          │
          ▼
     SpiceDB
```

**Used by**: `insights-host-inventory` (HBI) for host resources

**Characteristics**:
- Fully decoupled — your service doesn't know Kessel exists at write time
- Eventual consistency (typically 1–5 seconds)
- Survives Relations API downtime (Kafka retains messages; consumer retries)
- Higher operational complexity (Debezium connector + Kafka consumer to manage)
- Required for high-volume resource ingestion (thousands of hosts/devices per minute)

---

## Decision table

| Criterion | Direct gRPC | Kafka CDC Outbox |
|-----------|------------|-----------------|
| Resource type | Workspace, role, group, permission | Host, device, cluster, report, any "resource" |
| Write volume | Low (management ops) | High (ingestion pipelines) |
| Latency requirement | Immediate consistency needed | Eventual consistency acceptable |
| API downtime tolerance | Low (write path fails) | High (consumer retries from Kafka) |
| Implementation effort | Low | Medium–High |
| Operational overhead | Low | Medium (connector + consumer) |
| Pattern matches stage | RBAC path | Inventory/HBI path |

**Rule of thumb**: If your service manages **access control structure** (who can do what),
use Pattern A. If your service manages **resources** that users have access *to*, use Pattern B.

---

## Pattern A walkthrough — Direct gRPC

### 1. What tuples to create

Every workspace your service creates should produce a tuple linking it to a parent:

```
rbac/workspace:{workspace_id}#t_parent@rbac/workspace:{parent_workspace_id}
```

Or if it's a top-level workspace:

```
rbac/workspace:{workspace_id}#t_parent@rbac/tenant:{org_id}
```

### 2. gRPC call (pseudo-code)

```go
conn, _ := grpc.Dial("kessel-relations-api:9000", grpc.WithTransportCredentials(insecure.NewCredentials()))
client := kesselv1beta1.NewKesselTupleServiceClient(conn)

client.CreateTuples(ctx, &kesselv1beta1.CreateTuplesRequest{
    Upsert: true,
    Tuples: []*common.Relationship{
        {
            Resource: &common.ObjectReference{
                Type: &common.ObjectType{Namespace: "rbac", Name: "workspace"},
                Id:   workspaceID,
            },
            Relation: "t_parent",
            Subject: &common.SubjectReference{
                Subject: &common.ObjectReference{
                    Type: &common.ObjectType{Namespace: "rbac", Name: "tenant"},
                    Id:   orgID,
                },
            },
        },
    },
})
```

### 3. Schema requirements

Your resource type must already exist in the SpiceDB schema. For workspace-level resources,
the schema is managed via `rbac-config`. See §Schema extension below.

---

## Pattern B walkthrough — Kafka CDC Outbox

### 1. Outbox table DDL

Your PostgreSQL schema needs an outbox table. See [`02-outbox-template/outbox-table.sql`](02-outbox-template/outbox-table.sql).

Column requirements for Debezium EventRouter SMT:

| Column | Type | Purpose |
|--------|------|---------|
| `id` | UUID | Unique message ID (Kafka message key) |
| `aggregatetype` | VARCHAR | Routes to topic: `outbox.event.<prefix>.<aggregatetype>` |
| `aggregateid` | VARCHAR | Resource ID (the entity being created/updated/deleted) |
| `type` | VARCHAR | Event type (e.g. `ReportResource`, `DeleteResource`) |
| `payload` | JSONB | The event payload consumed by the downstream consumer |

### 2. Ghost-row write pattern

```go
tx, _ := db.Begin()

// 1. Write your actual record
tx.Exec(`INSERT INTO edge.devices (id, display_name, workspace_id) VALUES ($1,$2,$3)`,
    deviceID, displayName, workspaceID)

// 2. Write the outbox ghost-row
outboxID := uuid.New().String()
tx.Exec(`INSERT INTO edge.outbox (id, aggregatetype, aggregateid, type, payload, operation)
         VALUES ($1, 'devices', $2, 'ReportResource', $3::jsonb, 'created')`,
    outboxID, deviceID, payloadJSON)

// 3. Delete it immediately — Debezium captures the INSERT from WAL before this DELETE
tx.Exec(`DELETE FROM edge.outbox WHERE id = $1`, outboxID)

tx.Commit()
// Debezium sees the INSERT in the WAL and publishes to Kafka
```

### 3. Debezium connector

Register a connector that watches your outbox table using the EventRouter SMT.
See [`02-outbox-template/connector-template.json`](02-outbox-template/connector-template.json).

### 4. Consumer

Configure `inventory-consumer` to subscribe to your topic:

```yaml
consumer:
  topics:
    - outbox.event.my-service.my-resource-type
client:
  url: "kessel-inventory-api:9000"
```

Or write a custom consumer (see `hello-world-service/` for a complete example).

---

## Schema extension

Both patterns require the resource type to exist in the SpiceDB schema.

### Step 1 — Write the KSL definition (rbac-config style)

Create `my-service.ksl` in `configs/prod/schemas/src/`:

```ksl
version 0.1
namespace my_service

import rbac

public type my_resource {
    private relation workspace: [ExactlyOne rbac.workspace]

    @rbac.add_v1_based_permission(app:'my-service', resource:'my-resources', verb:'read',  v2_perm:'my_service_resource_view')
    relation view: workspace.my_service_resource_view

    @rbac.add_v1_based_permission(app:'my-service', resource:'my-resources', verb:'write', v2_perm:'my_service_resource_update')
    relation update: workspace.my_service_resource_update

    @rbac.add_v1_based_permission(app:'my-service', resource:'my-resources', verb:'write', v2_perm:'my_service_resource_delete')
    relation delete: workspace.my_service_resource_delete
}
```

The `add_v1_based_permission()` extension automatically propagates the permission through
`role`, `role_binding`, `platform`, `tenant`, and `workspace` types.

### Step 2 — Add permissions to rbac-config

Create `configs/prod/permissions/my-service.json`:

```json
{
    "my-resources": [
        { "verb": "read" },
        { "verb": "write" },
        { "verb": "*" }
    ]
}
```

### Step 3 — Add roles to rbac-config

Create `configs/prod/roles/my-service.json`:

```json
{
    "roles": [
        {
            "name": "My Service Administrator",
            "description": "Perform any available operation on any My Service resource.",
            "system": true,
            "platform_default": false,
            "admin_default": true,
            "version": 1,
            "access": [{ "permission": "my-service:my-resources:*" }]
        },
        {
            "name": "My Service Viewer",
            "description": "View My Service resources.",
            "system": true,
            "platform_default": true,
            "admin_default": false,
            "version": 1,
            "access": [{ "permission": "my-service:my-resources:read" }]
        }
    ]
}
```

### Step 4 — Compile the schema

```bash
cd rbac-config
make ksl-test-schema-stage   # writes to _private/test-schema/stage-schema.zed
```

Then load the compiled schema into SpiceDB:

```bash
# Using zed CLI:
zed schema write --endpoint=localhost:50051 --token=testtesttesttest \
  _private/test-schema/stage-schema.zed

# Or via SpiceDB HTTP:
curl -X PUT http://localhost:8443/v1/schema \
  -H "Authorization: Bearer testtesttesttest" \
  -H "Content-Type: application/json" \
  -d "{\"schema\": \"$(cat _private/test-schema/stage-schema.zed | jq -Rs .)\"}"
```

---

## Verifying your integration

After tuples are created, verify with a `CheckPermission` call:

```bash
# Using grpcurl
grpcurl -plaintext -d '{
  "resource": {"type": {"namespace": "edge", "name": "device"}, "id": "device-123"},
  "permission": "view",
  "subject": {"subject": {"type": {"namespace": "rbac", "name": "principal"}, "id": "alice"}}
}' localhost:9001 kessel.relations.v1beta1.KesselCheckService/Check

# Expected: {"permissionCheckResponse": "PERMISSION_CHECK_RESPONSE_PERMISSION_PERMITTED"}
```

Or using the HTTP endpoint:

```bash
curl -s http://localhost:8082/api/authz/v1beta1/check \
  -H "Content-Type: application/json" \
  -d '{"resource": {"type": {"namespace":"edge","name":"device"}, "id":"device-123"},
       "permission": "view",
       "subject": {"subject": {"type": {"namespace":"rbac","name":"principal"}, "id":"alice"}}}'
```

---

## Next steps

- Work through the complete example: [`hello-world-service/README.md`](hello-world-service/README.md)
- Copy templates from [`02-outbox-template/`](02-outbox-template/)
- Read the production schema: [`services/spicedb/schema/schema.zed`](../services/spicedb/schema/schema.zed)
- Understand the existing HBI integration: [`docs/RBAC_INVENTORY_CONNECTION.md`](../docs/RBAC_INVENTORY_CONNECTION.md)
