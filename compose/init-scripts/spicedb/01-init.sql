-- Kessel Stack: SpiceDB Database Initialization
-- Database for SpiceDB authorization engine
-- Note: SpiceDB migration tool (spicedb-migrate) will create the actual tables

-- Enable required extensions
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- Grant permissions to spicedb user
GRANT ALL PRIVILEGES ON DATABASE spicedb TO spicedb;
GRANT ALL PRIVILEGES ON SCHEMA public TO spicedb;

-- Set default privileges for future tables created by SpiceDB
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO spicedb;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO spicedb;

-- Success message
DO $$
BEGIN
    RAISE NOTICE 'SpiceDB database initialized - ready for migration';
END $$;
