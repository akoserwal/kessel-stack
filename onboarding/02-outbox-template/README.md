# Outbox Integration Templates

Copy-paste templates for integrating a new service with Kessel via the Kafka CDC Outbox pattern.

## Files

| File | Copy to | Description |
|------|---------|-------------|
| `outbox-table.sql` | your service's `db/init.sql` | PostgreSQL outbox table DDL |
| `connector-template.json` | `config/debezium/my-service-connector.json` | Debezium connector config |
| `rbac-config/permissions.json` | `rbac-config/configs/prod/permissions/my-service.json` | Permission definitions |
| `rbac-config/roles.json` | `rbac-config/configs/prod/roles/my-service.json` | System roles |

## Checklist

```
[ ] 1. Add outbox table to your database schema (outbox-table.sql)
[ ] 2. Write ghost-row outbox INSERT+DELETE in your application's write path
[ ] 3. Enable wal_level=logical on your PostgreSQL instance
[ ] 4. Create a Debezium connector (connector-template.json)
[ ] 5. Configure inventory-consumer or write a custom consumer
[ ] 6. Add your resource type to the SpiceDB schema (see KSL example below)
[ ] 7. Add permissions to rbac-config (rbac-config/permissions.json)
[ ] 8. Add roles to rbac-config (rbac-config/roles.json)
[ ] 9. Verify with CheckPermission (see 01-integration-decision-guide.md)
```

## Required PostgreSQL setting

Your PostgreSQL instance **must** have `wal_level=logical` for Debezium to capture WAL events:

```yaml
# In your docker-compose service:
services:
  postgres-my-service:
    image: postgres:15-alpine
    command: postgres -c wal_level=logical   # ← required
```

Or in `postgresql.conf`:
```
wal_level = logical
```

## KSL schema definition (rbac-config style)

Create `configs/prod/schemas/src/my-service.ksl`:

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

Then compile:

```bash
cd rbac-config
make ksl-test-schema-stage   # outputs _private/test-schema/stage-schema.zed
```

## Registering the Debezium connector

```bash
# Register
curl -X POST http://localhost:8084/connectors \
  -H "Content-Type: application/json" \
  -d @config/debezium/my-service-connector.json

# Check status
curl http://localhost:8084/connectors/my-service-outbox-connector/status

# Expected: {"connector": {"state": "RUNNING"}, "tasks": [{"state": "RUNNING"}]}
```

## Testing the outbox flow

After everything is running, insert a test ghost-row directly:

```sql
-- Connect to your service's database
\c my_service

BEGIN;

INSERT INTO my_service.outbox (aggregatetype, aggregateid, type, payload, operation)
VALUES (
    'my-resources',
    'test-resource-001',
    'ReportResource',
    '{"type":"my_service/my_resource","id":"test-resource-001","displayName":"Test Resource","workspaceId":"your-workspace-id","reporter":{"type":"my-service"}}'::jsonb,
    'created'
);

DELETE FROM my_service.outbox WHERE aggregateid = 'test-resource-001';

COMMIT;
```

Then check Kafka:

```bash
docker exec kessel-kafka kafka-console-consumer \
  --bootstrap-server localhost:9092 \
  --topic outbox.event.my-service.my-resources \
  --from-beginning \
  --max-messages 5
```

For a complete working example, see [`../hello-world-service/`](../hello-world-service/).
