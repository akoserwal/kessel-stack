-- Kessel Stack: RBAC Database Initialization
-- Minimal setup — the real insights-rbac (Django) runs its own migrations

-- Enable required extensions
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pg_trgm";

-- Success message
DO $$
BEGIN
    RAISE NOTICE 'RBAC database initialized — Django migrations will create tables';
END $$;
