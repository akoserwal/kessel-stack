-- ============================================================
-- Outbox Table Template for Kessel CDC Integration
-- ============================================================
-- Copy this into your service's database init script.
-- Debezium's EventRouter SMT requires these exact column names.
--
-- How it works:
--   1. Your write path INSERTs a row here (same transaction as the main record)
--   2. Your write path immediately DELETEs that row (ghost-row pattern)
--   3. Debezium captures the INSERT from PostgreSQL WAL (before the DELETE arrives)
--   4. EventRouter routes by aggregatetype → outbox.event.<prefix>.<aggregatetype>
--   5. Consumer reads from Kafka and calls kessel-inventory-api gRPC
--
-- Topic produced: outbox.event.<topic_prefix>.<aggregatetype>
-- Example:        outbox.event.my-service.widgets
-- ============================================================

-- Replace 'my_service' with your service's schema name
CREATE SCHEMA IF NOT EXISTS my_service;

CREATE TABLE IF NOT EXISTS my_service.outbox (
    -- Unique message ID — becomes the Kafka message key via EventRouter
    id              UUID        NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,

    -- Routes the event to a Kafka topic.
    -- EventRouter produces to: outbox.event.<topic_prefix>.<aggregatetype>
    -- Set topic_prefix in the connector config; aggregatetype comes from this column.
    -- Use the plural resource name: 'widgets', 'devices', 'clusters'
    aggregatetype   VARCHAR(255) NOT NULL,

    -- The ID of the resource being reported/deleted.
    -- This is the resource ID that ends up in SpiceDB.
    aggregateid     VARCHAR(255) NOT NULL,

    -- Event type consumed by the downstream consumer.
    -- Use 'ReportResource' for creates/updates, 'DeleteResource' for deletes.
    type            VARCHAR(255) NOT NULL,

    -- JSON payload forwarded to the consumer.
    -- Must match the format expected by your consumer (see payload section below).
    payload         JSONB       NOT NULL,

    -- Operation hint for the consumer: 'created', 'updated', 'deleted'
    operation       VARCHAR(50) DEFAULT 'created',

    -- API version for the kessel-inventory-api call.
    -- Set to 'v1beta2' unless you have a specific reason to use another version.
    version         VARCHAR(50) DEFAULT 'v1beta2',

    -- Timestamp of the event (informational — not used by Debezium routing)
    created_at      TIMESTAMPTZ DEFAULT NOW()
);

-- Index to support fast deletes (the ghost-row DELETE immediately after INSERT)
CREATE INDEX IF NOT EXISTS my_service_outbox_aggregateid_idx
    ON my_service.outbox (aggregateid);

-- Grant permissions to your service's database user
GRANT ALL ON SCHEMA my_service TO my_service_user;
GRANT ALL ON TABLE my_service.outbox TO my_service_user;

-- ============================================================
-- PAYLOAD FORMAT
-- ============================================================
-- The payload is forwarded verbatim to the consumer.
-- For inventory-consumer (project-kessel/inventory-consumer), it expects:
--
--   ReportResource payload:
--   {
--     "type":         "my_service/widget",       ← SpiceDB resource type (namespace/name)
--     "id":           "widget-uuid-here",        ← resource ID
--     "displayName":  "My Widget",               ← human-readable name
--     "workspaceId":  "ws-uuid-here",            ← workspace this resource belongs to
--     "reporter": {
--       "type":       "my-service",              ← reporter service name
--       "reporterInstanceId": "instance-1"
--     }
--   }
--
--   DeleteResource payload:
--   {
--     "type":   "my_service/widget",
--     "id":     "widget-uuid-here",
--     "reporter": { "type": "my-service", "reporterInstanceId": "instance-1" }
--   }
--
-- If writing a custom consumer (see hello-world-service/), you define the payload format yourself.
-- ============================================================

-- ============================================================
-- GHOST-ROW WRITE PATTERN (Application Code Example)
-- ============================================================
--
-- In your application, write the outbox row in the SAME transaction
-- as the main record, then DELETE it immediately:
--
--   BEGIN;
--
--   -- Write your main record
--   INSERT INTO my_service.widgets (id, name, workspace_id)
--   VALUES ('widget-123', 'My Widget', 'ws-456');
--
--   -- Write the outbox ghost-row
--   INSERT INTO my_service.outbox (aggregatetype, aggregateid, type, payload, operation)
--   VALUES (
--     'widgets',                                        -- routes to outbox.event.<prefix>.widgets
--     'widget-123',                                     -- the resource ID
--     'ReportResource',                                 -- event type
--     '{"type":"my_service/widget","id":"widget-123","displayName":"My Widget","workspaceId":"ws-456","reporter":{"type":"my-service"}}'::jsonb,
--     'created'
--   );
--
--   -- Delete immediately — Debezium sees the INSERT in WAL before this DELETE arrives
--   DELETE FROM my_service.outbox WHERE aggregateid = 'widget-123';
--
--   COMMIT;
--
-- Debezium captures the INSERT from WAL and publishes to Kafka.
-- The DELETE is also captured but filtered by the EventRouter (only INSERT events are routed).
-- ============================================================
