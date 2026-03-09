#!/usr/bin/env bash

# Cache Setup Script
# Configures Redis caching and creates cache invalidation consumers

set -euo pipefail

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Setting up Redis Caching Layer"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo

# Wait for Redis to be ready
log_info "Waiting for Redis to be ready..."
max_attempts=30
attempt=0

while ! docker exec kessel-redis redis-cli --pass "${REDIS_PASSWORD:-redispassword}" ping &>/dev/null; do
    attempt=$((attempt + 1))
    if [[ $attempt -ge $max_attempts ]]; then
        log_error "Redis not ready after $max_attempts attempts"
        exit 1
    fi
    sleep 2
done

log_success "Redis is ready"

# Test Redis connection
log_info "Testing Redis connection..."
if docker exec kessel-redis redis-cli --pass "${REDIS_PASSWORD:-redispassword}" SET test_key "test_value" &>/dev/null; then
    log_success "Redis write test successful"
else
    log_error "Redis write test failed"
    exit 1
fi

if docker exec kessel-redis redis-cli --pass "${REDIS_PASSWORD:-redispassword}" GET test_key &>/dev/null; then
    log_success "Redis read test successful"
else
    log_error "Redis read test failed"
    exit 1
fi

# Clean up test key
docker exec kessel-redis redis-cli --pass "${REDIS_PASSWORD:-redispassword}" DEL test_key &>/dev/null

# Display Redis info
log_info "Redis Configuration:"
docker exec kessel-redis redis-cli --pass "${REDIS_PASSWORD:-redispassword}" INFO SERVER | grep -E "redis_version|os|arch" || true
docker exec kessel-redis redis-cli --pass "${REDIS_PASSWORD:-redispassword}" CONFIG GET maxmemory | tail -1
docker exec kessel-redis redis-cli --pass "${REDIS_PASSWORD:-redispassword}" CONFIG GET maxmemory-policy | tail -1

# Set up cache key namespaces
log_info "Setting up cache key namespaces..."

# Create cache key patterns documentation
cat > "${PROJECT_ROOT}/docs/cache-keys.md" << 'EOF'
# Redis Cache Key Patterns

This document describes the cache key patterns used in Kessel Stack.

## Key Namespaces

All cache keys follow the pattern: `kessel:{namespace}:{key}`

### Permission Check Results

**Pattern**: `kessel:perm:{resource_type}:{resource_id}:{permission}:{subject_type}:{subject_id}`

**Example**:
```
kessel:perm:repository:acmecorp/backend:read:user:bob
```

**TTL**: 60 seconds (configurable)

**Value**: JSON object
```json
{
  "permissionship": "GRANTED",
  "checked_at": "CAEQAhgD",
  "cached_at": 1707236789
}
```

### Schema Definitions

**Pattern**: `kessel:schema:{namespace}`

**Example**:
```
kessel:schema:repository
```

**TTL**: 300 seconds (5 minutes)

**Value**: Full schema definition

### Relationship Lookups

**Pattern**: `kessel:rel:{resource_type}:{resource_id}:{relation}`

**Example**:
```
kessel:rel:repository:acmecorp/backend:writer
```

**TTL**: 30 seconds

**Value**: List of subjects

### Invalidation Patterns

Cache keys are invalidated when:

1. **Relationship changes** → Invalidate related permission checks
2. **Schema updates** → Invalidate all schema caches
3. **Manual flush** → Clear all keys matching pattern

## Cache Statistics

View cache statistics:

```bash
# Connect to Redis
docker exec -it kessel-redis redis-cli --pass redispassword

# Get all kessel keys
KEYS kessel:*

# Get cache hit rate
INFO stats

# Get memory usage
INFO memory

# Get key count
DBSIZE
```

## Monitoring

Key metrics to monitor:

- **Hit rate**: `INFO stats` → `keyspace_hits` / (`keyspace_hits` + `keyspace_misses`)
- **Memory usage**: `INFO memory` → `used_memory_human`
- **Evictions**: `INFO stats` → `evicted_keys`
- **Expired keys**: `INFO stats` → `expired_keys`

## Best Practices

1. **TTL Selection**:
   - Short TTL (10-60s) for frequently changing data
   - Medium TTL (5-10min) for schemas
   - Long TTL (1hour+) for static data

2. **Key Naming**:
   - Always use `kessel:` prefix
   - Use colons `:` as separators
   - Keep keys concise but descriptive

3. **Invalidation**:
   - Invalidate on writes (relationship changes)
   - Use CDC events for automatic invalidation
   - Implement lazy invalidation for non-critical paths

4. **Memory Management**:
   - Set appropriate `maxmemory` limit
   - Use `allkeys-lru` eviction policy
   - Monitor memory usage regularly
EOF

log_success "Cache key patterns documented in docs/cache-keys.md"

# Create cache invalidation consumer (if Kafka is available)
if docker ps | grep -q kessel-kafka; then
    log_info "Kafka detected, creating cache invalidation consumer..."

    cat > "${PROJECT_ROOT}/sample-data/event-consumers/cache-invalidator.js" << 'EOF'
#!/usr/bin/env node

/**
 * Kessel Cache Invalidator
 *
 * Consumes CDC events and invalidates Redis cache keys automatically.
 * This ensures cache consistency with the database.
 */

const { Kafka } = require('kafkajs');
const Redis = require('ioredis');

// Redis client
const redis = new Redis({
  host: process.env.REDIS_HOST || 'localhost',
  port: process.env.REDIS_PORT || 6379,
  password: process.env.REDIS_PASSWORD || 'redispassword',
});

// Kafka client
const kafka = new Kafka({
  clientId: 'kessel-cache-invalidator',
  brokers: [process.env.KAFKA_BROKER || 'localhost:29092'],
});

const consumer = kafka.consumer({
  groupId: 'cache-invalidators',
});

const topic = 'kessel.cdc.public.relation_tuple';

// Invalidation handlers
const invalidationHandlers = {
  // Invalidate permission check caches when relationships change
  async invalidatePermissionCaches(relationship) {
    const { namespace, object_id, relation } = relationship;

    // Pattern: kessel:perm:{namespace}:{object_id}:*
    const pattern = `kessel:perm:${namespace}:${object_id}:*`;

    // Find all matching keys
    const keys = await redis.keys(pattern);

    if (keys.length > 0) {
      await redis.del(...keys);
      console.log(`🗑️  Invalidated ${keys.length} permission cache keys for ${namespace}:${object_id}`);
    }

    // Also invalidate relationship lookup cache
    const relKey = `kessel:rel:${namespace}:${object_id}:${relation}`;
    await redis.del(relKey);
    console.log(`🗑️  Invalidated relationship cache: ${relKey}`);
  },

  // Invalidate schema caches when schemas change
  async invalidateSchemaCaches(schema) {
    const { namespace } = schema;

    const schemaKey = `kessel:schema:${namespace}`;
    await redis.del(schemaKey);
    console.log(`🗑️  Invalidated schema cache: ${schemaKey}`);

    // Also invalidate all permission caches for this namespace
    const pattern = `kessel:perm:${namespace}:*`;
    const keys = await redis.keys(pattern);

    if (keys.length > 0) {
      await redis.del(...keys);
      console.log(`🗑️  Invalidated ${keys.length} permission caches for namespace ${namespace}`);
    }
  },
};

async function run() {
  await consumer.connect();
  console.log('✅ Connected to Kafka and Redis');

  await consumer.subscribe({ topic, fromBeginning: false });
  console.log(`📡 Subscribed to topic: ${topic}`);
  console.log('🔥 Cache invalidator running...\n');

  await consumer.run({
    eachMessage: async ({ topic, partition, message }) => {
      try {
        const value = JSON.parse(message.value.toString());
        const { before, after, op } = value;

        // Get the event data
        const event = after || before;

        // Invalidate caches based on operation
        if (op === 'c' || op === 'u' || op === 'd') {
          if (topic.includes('relation_tuple')) {
            await invalidationHandlers.invalidatePermissionCaches(event);
          } else if (topic.includes('namespace_config')) {
            await invalidationHandlers.invalidateSchemaCaches(event);
          }
        }

        // Log cache stats periodically
        const stats = await redis.info('stats');
        const hits = stats.match(/keyspace_hits:(\d+)/)?.[1] || 0;
        const misses = stats.match(/keyspace_misses:(\d+)/)?.[1] || 0;
        const hitRate = (hits / (parseInt(hits) + parseInt(misses)) * 100).toFixed(2);

        console.log(`📊 Cache hit rate: ${hitRate}%`);

      } catch (error) {
        console.error('❌ Error processing message:', error);
      }
    },
  });
}

// Graceful shutdown
process.on('SIGTERM', async () => {
  console.log('\n🛑 Shutting down cache invalidator...');
  await consumer.disconnect();
  await redis.quit();
  process.exit(0);
});

process.on('SIGINT', async () => {
  console.log('\n🛑 Shutting down cache invalidator...');
  await consumer.disconnect();
  await redis.quit();
  process.exit(0);
});

// Start
run().catch(error => {
  console.error('💥 Fatal error:', error);
  process.exit(1);
});
EOF

    chmod +x "${PROJECT_ROOT}/sample-data/event-consumers/cache-invalidator.js"

    # Update package.json
    if [[ -f "${PROJECT_ROOT}/sample-data/event-consumers/package.json" ]]; then
        # Add ioredis dependency if not present
        if ! grep -q "ioredis" "${PROJECT_ROOT}/sample-data/event-consumers/package.json"; then
            # This is a simple approach - in production, use proper JSON editing
            log_info "Add 'ioredis' to package.json manually or run: npm install ioredis"
        fi
    fi

    log_success "Cache invalidation consumer created"
else
    log_warn "Kafka not running - skipping cache invalidation consumer setup"
fi

# Create cache testing script
cat > "${PROJECT_ROOT}/scripts/test-cache.sh" << 'EOF'
#!/usr/bin/env bash

# Test Redis caching performance

set -euo pipefail

REDIS_PASSWORD="${REDIS_PASSWORD:-redispassword}"

echo "Testing Redis Cache Performance..."
echo

# Test 1: Write performance
echo "Test 1: Write Performance (1000 keys)"
start=$(date +%s%N)
for i in {1..1000}; do
    docker exec kessel-redis redis-cli --pass "$REDIS_PASSWORD" \
        SET "kessel:test:key_$i" "value_$i" EX 60 &>/dev/null
done
end=$(date +%s%N)
duration=$(( (end - start) / 1000000 ))
echo "  ✓ Wrote 1000 keys in ${duration}ms"
echo "  ✓ Average: $((duration / 1000))ms per key"
echo

# Test 2: Read performance
echo "Test 2: Read Performance (1000 keys)"
start=$(date +%s%N)
for i in {1..1000}; do
    docker exec kessel-redis redis-cli --pass "$REDIS_PASSWORD" \
        GET "kessel:test:key_$i" &>/dev/null
done
end=$(date +%s%N)
duration=$(( (end - start) / 1000000 ))
echo "  ✓ Read 1000 keys in ${duration}ms"
echo "  ✓ Average: $((duration / 1000))ms per key"
echo

# Test 3: Pattern matching
echo "Test 3: Pattern Matching"
start=$(date +%s%N)
count=$(docker exec kessel-redis redis-cli --pass "$REDIS_PASSWORD" \
    KEYS "kessel:test:*" | wc -l)
end=$(date +%s%N)
duration=$(( (end - start) / 1000000 ))
echo "  ✓ Found $count keys in ${duration}ms"
echo

# Test 4: Bulk delete
echo "Test 4: Bulk Delete"
start=$(date +%s%N)
docker exec kessel-redis redis-cli --pass "$REDIS_PASSWORD" \
    --eval <(echo "return redis.call('del', unpack(redis.call('keys', ARGV[1])))") , "kessel:test:*" &>/dev/null
end=$(date +%s%N)
duration=$(( (end - start) / 1000000 ))
echo "  ✓ Deleted all test keys in ${duration}ms"
echo

# Display cache stats
echo "Cache Statistics:"
docker exec kessel-redis redis-cli --pass "$REDIS_PASSWORD" INFO stats | grep -E "keyspace_hits|keyspace_misses|evicted_keys|expired_keys"
echo

# Display memory usage
echo "Memory Usage:"
docker exec kessel-redis redis-cli --pass "$REDIS_PASSWORD" INFO memory | grep -E "used_memory_human|maxmemory_human|mem_fragmentation_ratio"
echo

echo "✅ Cache performance test complete"
EOF

chmod +x "${PROJECT_ROOT}/scripts/test-cache.sh"
log_success "Cache testing script created at scripts/test-cache.sh"

echo
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_success "Redis Caching Layer setup complete!"
echo
echo "Access Points:"
echo "  Redis CLI:       docker exec -it kessel-redis redis-cli --pass redispassword"
echo "  Redis Commander: http://localhost:8081 (admin/admin)"
echo "  Metrics:         http://localhost:9121/metrics"
echo
echo "Useful Commands:"
echo "  # View all cache keys"
echo "  docker exec kessel-redis redis-cli --pass redispassword KEYS 'kessel:*'"
echo
echo "  # Monitor cache in real-time"
echo "  docker exec kessel-redis redis-cli --pass redispassword MONITOR"
echo
echo "  # Get cache statistics"
echo "  docker exec kessel-redis redis-cli --pass redispassword INFO stats"
echo
echo "  # Test cache performance"
echo "  ./scripts/test-cache.sh"
echo
if docker ps | grep -q kessel-kafka; then
    echo "  # Run cache invalidator (requires npm install ioredis)"
    echo "  cd sample-data/event-consumers"
    echo "  npm install ioredis"
    echo "  node cache-invalidator.js"
    echo
fi
echo "Documentation:"
echo "  Cache key patterns: docs/cache-keys.md"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
