# Redis Caching Examples

This directory contains examples of using Redis for caching authorization data in Kessel.

## Overview

Caching permission check results and authorization data can dramatically improve performance:

- **Reduced latency**: 1-2ms cache hits vs 10-50ms SpiceDB queries
- **Lower load**: Fewer queries to SpiceDB and PostgreSQL
- **Better scalability**: Handle 10x-100x more requests
- **Cost savings**: Reduced database and compute costs

## Prerequisites

- Kessel Stack Phase 1 + Phase 3 running
- Node.js 16+ installed
- Dependencies installed: `npm install`

## Examples

### 1. Permission Check Caching

**File**: `permission-cache.js`

Demonstrates cache-aside pattern for permission checks.

**Run**:
```bash
npm install @authzed/authzed-node ioredis @grpc/grpc-js
node permission-cache.js
```

**What it does**:
- Checks Redis cache before querying SpiceDB
- Caches results with configurable TTL (default: 60s)
- Tracks cache hits/misses
- Provides cache statistics

**Expected output**:
```
Check 1: First permission check (cache miss expected)
❌ CACHE MISS - Querying SpiceDB...
✅ PERMISSION CHECK COMPLETE (15ms)
   Result: GRANTED
   Cached for: 60s

Check 2: Same permission check (cache hit expected)
✅ CACHE HIT (2ms)
   Key: kessel:perm:repository:acmecorp/backend:read:user:bob
   Result: GRANTED
   Cached at: 2026-02-06T10:00:00.000Z

Cache Statistics:
  Hits:      2
  Misses:    1
  Hit Rate:  66.67%
```

### 2. Cache Invalidation

When relationships change, caches must be invalidated:

```javascript
const { invalidateResourceCache } = require('./permission-cache');

// After creating/updating/deleting a relationship
await invalidateResourceCache('repository', 'acmecorp/backend');
```

**Automatic invalidation** is provided by the cache invalidator consumer (Phase 2 + CDC required).

## Cache Patterns

### Pattern 1: Cache-Aside (Lazy Loading)

**Use case**: Permission checks

**Flow**:
1. Check cache for result
2. If hit: Return cached result
3. If miss: Query SpiceDB, cache result, return

**Pros**:
- Only caches what's actually used
- Simple to implement
- Resilient to cache failures

**Cons**:
- First request is always slow (cache miss)
- Cache can become stale

**Implementation**: See `permission-cache.js`

### Pattern 2: Write-Through

**Use case**: Relationship writes

**Flow**:
1. Write to SpiceDB
2. Immediately update cache
3. Return success

**Pros**:
- Cache always up-to-date
- No cache misses for recent writes

**Cons**:
- Slower writes
- More complex
- Cache pollution

### Pattern 3: Write-Behind (Async Invalidation)

**Use case**: High-volume relationship changes

**Flow**:
1. Write to SpiceDB
2. Publish invalidation event to Kafka
3. Consumer invalidates cache asynchronously

**Pros**:
- Fast writes
- Eventually consistent cache
- Scalable

**Cons**:
- Temporary stale reads possible
- Requires event infrastructure (Kafka)

**Implementation**: See `cache-invalidator.js` in `event-consumers/`

## Cache Key Patterns

### Permission Checks

```
kessel:perm:{resource_type}:{resource_id}:{permission}:{subject_type}:{subject_id}
```

**Example**:
```
kessel:perm:repository:acmecorp/backend:read:user:bob
```

### Relationship Lookups

```
kessel:rel:{resource_type}:{resource_id}:{relation}
```

**Example**:
```
kessel:rel:repository:acmecorp/backend:writer
```

**Value**: JSON array of subjects
```json
["user:bob", "user:alice", "team:engineering#member"]
```

### Schema Definitions

```
kessel:schema:{namespace}
```

**Example**:
```
kessel:schema:repository
```

**Value**: Full schema definition (string)

## TTL Selection Guide

| Data Type | Volatility | Recommended TTL | Reason |
|-----------|------------|-----------------|---------|
| Permission checks | Medium | 30-60s | Balance freshness vs performance |
| Relationship lookups | High | 10-30s | Changes frequently |
| Schema definitions | Low | 5-10min | Changes rarely |
| User profiles | Low | 10-30min | Static data |
| Static resources | Very low | 1-24hr | Rarely changes |

**Factors to consider**:
- How often does the data change?
- How critical is freshness?
- What's the cost of a cache miss?
- What's the impact of stale data?

## Performance Comparison

### Without Caching

```
Permission check: 10-50ms (p50), 50-200ms (p99)
Throughput: ~100-500 req/s per SpiceDB instance
```

### With Redis Caching (80% hit rate)

```
Permission check: 1-2ms (p50), 5-10ms (p99)
Throughput: ~5,000-10,000 req/s per Redis instance
```

**Improvement**: 5-10x latency reduction, 10-20x throughput increase

## Monitoring Cache Performance

### Key Metrics

1. **Hit Rate**: `hits / (hits + misses)`
   - Target: >70% for permission checks
   - Target: >90% for schemas

2. **Latency**:
   - Cache hit: <5ms
   - Cache miss: <50ms

3. **Memory Usage**:
   - Monitor `used_memory`
   - Watch for evictions

4. **Eviction Rate**:
   - Should be low (<5%)
   - High eviction = increase memory or reduce TTL

### View Metrics

```bash
# Connect to Redis
docker exec -it kessel-redis redis-cli --pass redispassword

# Get statistics
INFO stats

# Get memory usage
INFO memory

# Monitor in real-time
MONITOR
```

### Prometheus Metrics (Phase 4)

Redis exporter provides Prometheus metrics:
```
http://localhost:9121/metrics
```

Key metrics:
- `redis_keyspace_hits_total`
- `redis_keyspace_misses_total`
- `redis_memory_used_bytes`
- `redis_evicted_keys_total`

## Best Practices

### 1. Choose Appropriate TTL

```javascript
// High-volatility data
const TTL_SHORT = 30;  // 30 seconds

// Medium-volatility data
const TTL_MEDIUM = 300;  // 5 minutes

// Low-volatility data
const TTL_LONG = 3600;  // 1 hour
```

### 2. Handle Cache Failures Gracefully

```javascript
async function checkPermissionCached(resource, permission, subject) {
  try {
    // Try cache
    const cached = await redis.get(key);
    if (cached) return JSON.parse(cached);
  } catch (error) {
    console.warn('Cache error, falling back to SpiceDB:', error);
  }

  // Fall back to SpiceDB
  return await spicedb.checkPermission(request);
}
```

### 3. Use Pipeline for Bulk Operations

```javascript
// Bad: Multiple round trips
for (const key of keys) {
  await redis.get(key);
}

// Good: Single round trip
const pipeline = redis.pipeline();
for (const key of keys) {
  pipeline.get(key);
}
const results = await pipeline.exec();
```

### 4. Implement Proper Invalidation

```javascript
// When relationship changes
await redis.del(`kessel:perm:${resource}:*`);

// Or use pattern matching (slower, use sparingly)
const keys = await redis.keys(`kessel:perm:${resource}:*`);
if (keys.length > 0) {
  await redis.del(...keys);
}
```

### 5. Monitor and Alert

```javascript
// Check hit rate periodically
setInterval(async () => {
  const stats = await getCacheStats();

  if (stats.hitRate < 50) {
    console.warn('Low cache hit rate:', stats.hitRate);
    // Send alert
  }

  if (stats.evicted > 1000) {
    console.warn('High eviction rate:', stats.evicted);
    // Consider increasing memory
  }
}, 60000);  // Every minute
```

## Troubleshooting

### Low Hit Rate

**Causes**:
- TTL too short
- Cache not warmed up
- High data volatility
- Unique queries (no repeats)

**Solutions**:
- Increase TTL if acceptable
- Pre-populate cache (cache warming)
- Review access patterns
- Cache at higher level (e.g., user sessions)

### High Eviction Rate

**Causes**:
- Insufficient memory
- Too many unique keys
- Long TTLs

**Solutions**:
- Increase Redis memory limit
- Reduce TTL
- Use better key design (avoid unique timestamps)
- Implement LRU eviction (already default)

### Stale Data

**Causes**:
- TTL too long
- Invalidation not working
- Race conditions

**Solutions**:
- Reduce TTL
- Implement CDC-based invalidation
- Use versioned cache keys
- Add timestamp checks

## Integration with Learning Paths

These examples support:

### Level 2 (Developer)
- SDK patterns and optimization
- Performance tuning
- Production best practices

### Level 3 (Integrator)
- Event-driven cache invalidation
- Eventual consistency handling
- CQRS patterns

### Level 4 (Architect)
- Cache design patterns
- Performance modeling
- Scalability architecture

## Next Steps

1. **Run Examples**: Test cache performance
2. **Measure Impact**: Benchmark with/without caching
3. **Tune Settings**: Adjust TTL based on use case
4. **Implement Invalidation**: Use CDC for automatic invalidation
5. **Monitor**: Track hit rate and performance

## Resources

- [Redis Best Practices](https://redis.io/docs/manual/patterns/)
- [Cache-Aside Pattern](https://docs.microsoft.com/en-us/azure/architecture/patterns/cache-aside)
- [Redis Memory Optimization](https://redis.io/docs/manual/optimization/memory-optimization/)
- [Caching Strategies](https://aws.amazon.com/caching/best-practices/)
