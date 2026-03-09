-- kessel-stack-real: kessel-inventory-api Database Initialization
-- kessel-inventory-api runs its own migrations (via 'inventory-api migrate') to create
-- all application tables including public.outbox_events (ghost-row CDC outbox).
-- This script only sets up extensions needed before migrations run.

-- Required extensions
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- Success message
DO $$
BEGIN
    RAISE NOTICE 'kessel-inventory database initialized — kessel-inventory-api will run migrations';
END $$;
