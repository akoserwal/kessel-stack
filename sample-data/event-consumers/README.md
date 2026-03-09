# Kessel CDC Event Consumers

Sample event consumers for processing Kessel CDC events from Kafka.

## Overview

These consumers demonstrate how to build event-driven integrations with Kessel by consuming Change Data Capture (CDC) events from PostgreSQL via Debezium and Kafka.

## Prerequisites

- Node.js 16+ installed
- Kessel Stack running with Phase 2 (Kafka + CDC)
- Debezium connector configured

## Setup

```bash
# Install dependencies
npm install

# Or with yarn
yarn install
```

## Running Consumers

### Relationship Changes Consumer

Listens to relationship creation, updates, and deletions:

```bash
npm run consume:relationships
# or
node relationship-consumer.js
```

**What it does**:
- Consumes events from `kessel.cdc.public.relation_tuple` topic
- Processes relationship CRUD operations
- Displays formatted event information
- Can trigger downstream actions (webhooks, cache updates, etc.)

### Schema Changes Consumer

Listens to authorization schema changes:

```bash
npm run consume:schemas
# or
node schema-consumer.js
```

**What it does**:
- Consumes events from `kessel.cdc.public.namespace_config` topic
- Processes schema definition changes
- Can invalidate caches or notify applications

## Event Structure

### Relationship Event (Debezium Format)

```json
{
  "before": null,
  "after": {
    "namespace": "repository",
    "object_id": "acmecorp/backend",
    "relation": "writer",
    "userset_namespace": "user",
    "userset_object_id": "bob",
    "userset_relation": "",
    "created_xid": "513",
    "deleted_xid": "9223372036854775807"
  },
  "op": "c",
  "ts_ms": 1707236789123
}
```

### Operation Types

- `c` = CREATE (insert)
- `u` = UPDATE
- `d` = DELETE
- `r` = READ (initial snapshot)

## Use Cases

### 1. Cache Invalidation

When relationships change, invalidate authorization caches:

```javascript
if (operation === 'CREATE' || operation === 'UPDATE' || operation === 'DELETE') {
  await redis.del(`authz:${event.namespace}:${event.object_id}`);
}
```

### 2. Downstream System Sync

Replicate authorization data to read replicas:

```javascript
if (operation === 'CREATE') {
  await replicaDB.insert('relationships', event);
}
```

### 3. Audit Logging

Create audit trail of authorization changes:

```javascript
await auditLog.create({
  action: operation,
  resource: `${event.namespace}:${event.object_id}`,
  relation: event.relation,
  subject: `${event.userset_namespace}:${event.userset_object_id}`,
  timestamp: new Date(),
});
```

### 4. Webhook Notifications

Notify external systems of permission changes:

```javascript
if (event.namespace === 'organization' && event.relation === 'admin') {
  await webhook.post('https://api.example.com/admin-changed', {
    organization: event.object_id,
    admin: event.userset_object_id,
  });
}
```

### 5. Search Index Updates

Keep search indexes in sync:

```javascript
await elasticsearch.index({
  index: 'relationships',
  id: `${event.namespace}:${event.object_id}:${event.relation}`,
  body: event,
});
```

## Testing

### Generate Test Events

```bash
# In another terminal, create a relationship using zed CLI
zed relationship create repository:test/repo writer user:alice

# Your consumer should display:
# 📝 Relationship CREATED:
#    Resource: repository:test/repo
#    Relation: writer
#    Subject:  user:alice#self
```

### Monitor Kafka Topics

```bash
# List all topics
docker exec kessel-kafka kafka-topics \
  --list \
  --bootstrap-server localhost:9092

# View messages in topic
docker exec kessel-kafka kafka-console-consumer \
  --bootstrap-server localhost:9092 \
  --topic kessel.cdc.public.relation_tuple \
  --from-beginning
```

## Production Considerations

### Error Handling

Add robust error handling and retry logic:

```javascript
const retry = require('async-retry');

await retry(async () => {
  await processEvent(event);
}, {
  retries: 3,
  minTimeout: 1000,
  onRetry: (err, attempt) => {
    console.log(`Retry attempt ${attempt}:`, err.message);
  },
});
```

### Dead Letter Queue

Handle failed messages:

```javascript
try {
  await processEvent(event);
} catch (error) {
  await dlqProducer.send({
    topic: 'kessel.dlq',
    messages: [{
      key: message.key,
      value: JSON.stringify({ original: event, error: error.message }),
    }],
  });
}
```

### Idempotency

Ensure events can be safely replayed:

```javascript
const eventId = `${event.namespace}:${event.object_id}:${event.created_xid}`;

if (await processedEvents.has(eventId)) {
  console.log('Already processed, skipping');
  return;
}

await processEvent(event);
await processedEvents.add(eventId);
```

### Monitoring

Add metrics and logging:

```javascript
const metrics = require('prom-client');

const eventsProcessed = new metrics.Counter({
  name: 'kessel_events_processed_total',
  help: 'Total number of events processed',
  labelNames: ['operation', 'namespace'],
});

eventsProcessed.labels(operation, event.namespace).inc();
```

## Configuration

### Environment Variables

```bash
# Kafka broker
export KAFKA_BROKER=localhost:29092

# Consumer group ID
export CONSUMER_GROUP=my-app-processors

# Log level
export LOG_LEVEL=info
```

### Consumer Options

Modify consumer configuration in code:

```javascript
const consumer = kafka.consumer({
  groupId: process.env.CONSUMER_GROUP || 'relationship-processors',

  // Session timeout
  sessionTimeout: 30000,

  // Heartbeat interval
  heartbeatInterval: 3000,

  // Max bytes per partition
  maxBytesPerPartition: 1048576,

  // Auto-commit
  autoCommit: true,
  autoCommitInterval: 5000,
});
```

## Troubleshooting

### Consumer Not Receiving Events

1. Check Debezium connector status:
   ```bash
   curl http://localhost:8083/connectors/spicedb-postgres-connector/status
   ```

2. Verify topics exist:
   ```bash
   docker exec kessel-kafka kafka-topics --list --bootstrap-server localhost:9092
   ```

3. Check for messages in topic:
   ```bash
   docker exec kessel-kafka kafka-console-consumer \
     --bootstrap-server localhost:9092 \
     --topic kessel.cdc.public.relation_tuple \
     --max-messages 1
   ```

### Connection Errors

- Ensure Kafka is running: `docker ps | grep kessel-kafka`
- Check Kafka broker address: `localhost:29092` for host, `kafka:9092` for containers
- Verify network connectivity

### Performance Issues

- Increase `maxBytesPerPartition` for higher throughput
- Add more consumers to the consumer group for parallel processing
- Use batch processing instead of processing one message at a time

## Next Steps

- Explore event-driven patterns in `learning-paths/level-3-integrator/`
- Learn about eventual consistency handling
- Implement CQRS pattern with CDC events
- Build event sourcing system with Kessel events

## Resources

- [KafkaJS Documentation](https://kafka.js.org/)
- [Debezium Documentation](https://debezium.io/documentation/)
- [CDC Best Practices](https://debezium.io/documentation/reference/stable/tutorial.html)
- [Distributed Systems Fundamentals](../../docs/learning-paths/level-3-integrator/01-distributed-systems-fundamentals.md)
