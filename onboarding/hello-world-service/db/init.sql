-- edge-device-service: Database initialization
-- Run automatically by postgres docker-entrypoint-initdb.d

-- Enable UUID generation
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- Schema for this service
CREATE SCHEMA IF NOT EXISTS edge;

-- ---------------------------------------------------------------
-- Main application table: edge devices
-- ---------------------------------------------------------------
CREATE TABLE IF NOT EXISTS edge.devices (
    id           UUID        NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    display_name VARCHAR(255) NOT NULL,
    workspace_id VARCHAR(255) NOT NULL,   -- rbac/workspace ID from kessel-stack
    reporter     VARCHAR(100) NOT NULL DEFAULT 'edge-device-service',
    org_id       VARCHAR(100) NOT NULL DEFAULT '12345',
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS edge_devices_workspace_id_idx ON edge.devices (workspace_id);
CREATE INDEX IF NOT EXISTS edge_devices_org_id_idx       ON edge.devices (org_id);

-- ---------------------------------------------------------------
-- Outbox table: Debezium EventRouter CDC outbox
--
-- The write path does:
--   BEGIN
--     INSERT INTO edge.devices (...)
--     INSERT INTO edge.outbox (aggregatetype='devices', aggregateid=device_id, ...)
--     DELETE FROM edge.outbox WHERE id = <just-inserted-id>
--   COMMIT
--
-- Debezium captures the INSERT from WAL and routes to:
--   outbox.event.edge.devices
-- ---------------------------------------------------------------
CREATE TABLE IF NOT EXISTS edge.outbox (
    id            UUID        NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    aggregatetype VARCHAR(255) NOT NULL,   -- 'devices' → topic suffix
    aggregateid   VARCHAR(255) NOT NULL,   -- device UUID → Kafka message key
    type          VARCHAR(255) NOT NULL,   -- 'ReportResource' | 'DeleteResource'
    payload       JSONB       NOT NULL,    -- forwarded to the consumer verbatim
    operation     VARCHAR(50) NOT NULL DEFAULT 'created',  -- 'created'|'updated'|'deleted'
    version       VARCHAR(50) NOT NULL DEFAULT 'v1beta2',
    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Grant all permissions to the edge user
GRANT ALL ON SCHEMA edge TO edge;
GRANT ALL ON ALL TABLES IN SCHEMA edge TO edge;
GRANT ALL ON ALL SEQUENCES IN SCHEMA edge TO edge;
ALTER DEFAULT PRIVILEGES IN SCHEMA edge GRANT ALL ON TABLES TO edge;
ALTER DEFAULT PRIVILEGES IN SCHEMA edge GRANT ALL ON SEQUENCES TO edge;
