-- kessel-stack-real: HBI (insights-host-inventory) Database Initialization
-- This is postgres-inventory — HBI's own postgres, separate from kessel-inventory-api.
-- HBI runs its own Alembic migrations to create application tables (hosts, groups, etc.)
-- This script sets up extensions and creates the hbi.outbox schema/table for CDC Stage 1.
--
-- Stage: Debezium hbi-outbox-connector watches hbi.outbox using the ghost-row pattern.
-- HBI writes INSERT + DELETE in the same transaction; Debezium captures the INSERT from WAL.
-- The outbox table may already be created by HBI's Alembic migrations — IF NOT EXISTS is safe.

-- Enable required extensions
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pg_trgm";

-- Create the hbi schema (used by the outbox table)
CREATE SCHEMA IF NOT EXISTS hbi;

-- HBI outbox table — ghost-row CDC pattern (Stage 1)
-- Matches Debezium EventRouter field expectations:
--   aggregatetype → routes to topic outbox.event.hbi.<aggregatetype>
--   aggregateid   → used as Kafka message key
--   payload       → event body (JSONB)
CREATE TABLE IF NOT EXISTS hbi.outbox (
    id            UUID        NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    aggregatetype VARCHAR(255) NOT NULL,
    aggregateid   VARCHAR(255) NOT NULL,
    type          VARCHAR(255) NOT NULL,
    payload       JSONB       NOT NULL,
    version       VARCHAR(50) DEFAULT 'v1beta2',
    operation     VARCHAR(50) DEFAULT 'created',
    created_at    TIMESTAMPTZ DEFAULT NOW()
);

-- Grant access to the inventory user (same user HBI runs as)
GRANT ALL ON SCHEMA hbi TO inventory;
GRANT ALL ON TABLE hbi.outbox TO inventory;

-- Success message
DO $$
BEGIN
    RAISE NOTICE 'HBI inventory database initialized — hbi.outbox table ready for CDC Stage 1';
END $$;
