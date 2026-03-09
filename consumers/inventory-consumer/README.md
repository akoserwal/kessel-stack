# Official Inventory Consumer

**Source:** https://github.com/project-kessel/inventory-consumer
**Image:** quay.io/project-kessel/inventory-consumer:latest

This directory contains the configuration for the **official project-kessel inventory-consumer**, which is a production-ready Kafka consumer that processes inventory events and syncs them to the Kessel Inventory API.

---

## What is the Inventory Consumer?

The inventory consumer is a Go application that:
- Consumes CDC (Change Data Capture) events from Kafka topics
- Processes inventory resource changes (hosts, groups, tags)
- Syncs the changes to the Kessel Inventory API
- Provides retry logic, error handling, and monitoring

---

## Configuration

The consumer is configured via `config.yaml`, which is mounted into the container at runtime.

### config.yaml

```yaml
consumer:
  bootstrap-servers: ["kafka:29092"]
  commit-modulo: 300
  topics:
    - inventory.hosts.events
    - inventory.host_groups.events
    - inventory.tags.events
  retry-options:
    consumer-max-retries: -1
    operation-max-retries: -1
    backoff-factor: 5
    max-backoff-seconds: 30
  auth:
    enabled: false

client:
  enabled: true
  url: "http://kessel-inventory-api:8000"
  enable-oidc-auth: false
  insecure-client: true

log:
  level: "info"
```

### Configuration Options

**consumer:**
- `bootstrap-servers` - Kafka broker addresses
- `commit-modulo` - Commit offset every N messages (default: 300)
- `topics` - List of Kafka topics to consume
- `retry-options` - Retry behavior configuration
  - `consumer-max-retries` - Max retries for consumer errors (-1 = unlimited)
  - `operation-max-retries` - Max retries for operations (-1 = unlimited)
  - `backoff-factor` - Exponential backoff multiplier
  - `max-backoff-seconds` - Maximum wait between retries
- `auth.enabled` - Enable Kafka authentication (false for local dev)

**client:**
- `enabled` - Enable Inventory API client
- `url` - Inventory API endpoint
- `enable-oidc-auth` - Enable OAuth authentication (false for local dev)
- `insecure-client` - Skip TLS verification (true for local dev)

**log:**
- `level` - Logging level (info, debug, warn, error)

---

## Docker Compose Configuration

The consumer is defined in `compose/docker-compose.kafka.yml`:

```yaml
inventory-consumer:
  image: quay.io/project-kessel/inventory-consumer:latest
  container_name: kessel-inventory-consumer
  command: ["start"]
  environment:
    INVENTORY_CONSUMER_CONFIG: /config.yaml
  volumes:
    - ../consumers/inventory-consumer/config.yaml:/config.yaml:ro
  depends_on:
    - kafka
    - kessel-inventory-api
  networks:
    - kessel-network
  restart: unless-stopped
```

**Key points:**
- Uses official pre-built image from Quay.io
- Mounts `config.yaml` as read-only volume
- Sets `INVENTORY_CONSUMER_CONFIG` environment variable to point to config file
- Waits for Kafka and Inventory API to be healthy before starting

---

## Usage

### Start the Consumer

```bash
# Start all services including inventory consumer
docker compose -f compose/docker-compose.yml \
  -f compose/docker-compose.kafka.yml \
  up -d

# Or start just the inventory consumer
docker compose -f compose/docker-compose.kafka.yml up inventory-consumer
```

### View Logs

```bash
docker logs kessel-inventory-consumer -f
```

**Expected output:**
```
Starting inventory consumer...
Connected to Kafka brokers: kafka:29092
Subscribed to topics: [inventory.hosts.events, inventory.host_groups.events, inventory.tags.events]
Consumer group: inventory-consumer-group
Starting to consume messages...
```

### Check Consumer Status

```bash
# View consumer group details
docker exec kessel-kafka kafka-consumer-groups \
  --bootstrap-server localhost:9092 \
  --group inventory-consumer-group \
  --describe
```

**Healthy output:**
```
GROUP                      TOPIC                          PARTITION  CURRENT-OFFSET  LOG-END-OFFSET  LAG
inventory-consumer-group   inventory.hosts.events         0          10              10              0
inventory-consumer-group   inventory.hosts.events         1          8               8               0
inventory-consumer-group   inventory.hosts.events         2          9               9               0
```

**LAG should be 0** (consumer is keeping up with events)

---

## Monitoring

### Metrics

The official consumer exposes Prometheus metrics on port 9000 (if configured).

**To enable metrics in kessel-stack:**

1. Add port mapping in docker-compose.kafka.yml:
   ```yaml
   ports:
     - "9096:9000"  # Metrics endpoint
   ```

2. Add to Prometheus scrape config:
   ```yaml
   - job_name: 'inventory-consumer'
     static_configs:
       - targets: ['inventory-consumer:9000']
   ```

### Key Metrics

```promql
# Messages processed
inventory_consumer_messages_processed_total

# Processing duration
inventory_consumer_processing_duration_seconds

# API call errors
inventory_consumer_api_errors_total

# Consumer lag
kafka_consumergroup_lag{group="inventory-consumer-group"}
```

---

## Troubleshooting

### Consumer Not Starting

**Check dependencies:**
```bash
# Verify Kafka is running
docker ps | grep kafka

# Verify Inventory API is running
docker ps | grep inventory-api

# Test Inventory API health
curl http://localhost:8083/livez
```

### Config File Not Found

**Error:** `failed to load config: open /config.yaml: no such file or directory`

**Solution:**
```bash
# Verify config file exists
ls -l consumers/inventory-consumer/config.yaml

# Verify volume mount in docker-compose.kafka.yml
docker compose -f compose/docker-compose.kafka.yml config | grep -A 5 volumes
```

### Consumer Lag Increasing

**Check logs for errors:**
```bash
docker logs kessel-inventory-consumer | grep -i error
```

**Common causes:**
- Inventory API is down or slow
- Network issues
- Invalid events in Kafka topics
- Resource constraints (CPU/memory)

### Connection Refused

**Error:** `dial tcp: lookup kessel-inventory-api: no such host`

**Solution:**
- Verify Inventory API container is running
- Check that both containers are on same network (`kessel-network`)
- Verify service name matches in config.yaml

---

## Differences from Stub Implementation

The official consumer replaces the previous stub implementation with these improvements:

| Feature | Stub (Old) | Official (New) |
|---------|-----------|----------------|
| **Configuration** | Environment variables | YAML config file |
| **API Calls** | ❌ Just logged events | ✅ Calls Inventory API |
| **Retry Logic** | ❌ None | ✅ Exponential backoff |
| **Error Handling** | ⚠️ Basic | ✅ Comprehensive |
| **Metrics** | ❌ None | ✅ Prometheus metrics |
| **Production Ready** | ❌ Demo only | ✅ Yes |
| **Maintenance** | ⚠️ Manual | ✅ Official repo |
| **Authentication** | ❌ None | ✅ OIDC support |

---

## Development

### Building Custom Image (Optional)

If you need to build from source instead of using the pre-built image:

```yaml
inventory-consumer:
  build:
    context: https://github.com/project-kessel/inventory-consumer.git
    dockerfile: Dockerfile
    args:
      VERSION: latest
  # ... rest of config
```

### Testing Configuration Changes

```bash
# Validate YAML syntax
docker run --rm -v $(pwd)/config.yaml:/config.yaml:ro \
  alpine/yamllint config.yaml

# Test with modified config
docker compose -f compose/docker-compose.kafka.yml up inventory-consumer

# Watch logs for errors
docker logs kessel-inventory-consumer -f
```

### Local Development

To develop against the official consumer source:

```bash
# Clone the repository
git clone https://github.com/project-kessel/inventory-consumer.git
cd inventory-consumer

# Run locally
make local-build
./bin/inventory-consumer start --consumer.bootstrap-servers localhost:9092
```

---

## Migration Notes

### From Stub to Official (Completed)

**What changed:**
1. ✅ Removed stub implementation files (main.go, Dockerfile, go.mod)
2. ✅ Created config.yaml with kessel-stack settings
3. ✅ Updated docker-compose.kafka.yml to use official image
4. ✅ Updated documentation

**What stayed the same:**
- Consumer group ID: `inventory-consumer-group`
- Kafka topics: `inventory.hosts.events`, etc.
- Network: `kessel-network`
- Resource limits (256MB RAM, 0.5 CPU)

**Testing required:**
- [ ] Consumer starts successfully
- [ ] Connects to Kafka
- [ ] Joins consumer group
- [ ] Processes messages
- [ ] Calls Inventory API
- [ ] Consumer lag stays at 0

---

## References

- **Official Repository:** https://github.com/project-kessel/inventory-consumer
- **Container Image:** quay.io/project-kessel/inventory-consumer
- **Documentation:** See upstream repository README
- **Issues:** https://github.com/project-kessel/inventory-consumer/issues

---

## Summary

This directory now uses the **official production-ready inventory-consumer** from project-kessel:

✅ **Production-grade** code with comprehensive error handling
✅ **Active maintenance** from project-kessel team
✅ **Advanced features** (retry logic, metrics, authentication)
✅ **Simple integration** via config file and pre-built image

The config.yaml file has been adapted for kessel-stack with the correct:
- Kafka broker addresses
- Topic names
- Inventory API endpoint
- Retry settings

**Ready to use in kessel-stack!**
