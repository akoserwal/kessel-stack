# Kessel Kafka Consumers - Configuration Guide

**Last Updated:** 2026-02-17
**Status:** Production-Ready

This document explains how the Kafka consumers are configured in kessel-stack.

---

## Overview

Kessel Stack uses **two Kafka consumers** to process Change Data Capture (CDC) events from PostgreSQL databases:

| Consumer | Source | Status | Purpose |
|----------|--------|--------|---------|
| **RBAC Consumer** | Custom (Red Hat Insights patterns) | ✅ Production-ready | Processes RBAC events → Creates relationships in SpiceDB |
| **Inventory Consumer** | Official (project-kessel) | ✅ Production-ready | Processes inventory events → Syncs to Inventory API |

---

## Architecture

```
PostgreSQL (RBAC DB)
    ↓ CDC
Debezium Connector
    ↓ Events
Kafka (rbac.workspaces.events, rbac.roles.events)
    ↓ Consumed by
RBAC Consumer (Go application)
    ↓ REST API calls
Relations API (kessel-relations-api)
    ↓ gRPC
SpiceDB (Authorization Engine)


PostgreSQL (Inventory DB)
    ↓ CDC
Debezium Connector
    ↓ Events
Kafka (inventory.hosts.events, inventory.host_groups.events, inventory.tags.events)
    ↓ Consumed by
Inventory Consumer (Go application)
    ↓ REST API calls
Inventory API (kessel-inventory-api)
```

---

## 1. RBAC Consumer Configuration

### Location
- **Directory:** `consumers/rbac-consumer/`
- **Container Name:** `kessel-rbac-consumer`
- **Language:** Go 1.21
- **Based on:** Red Hat Insights RBAC consumer patterns

### Docker Configuration

**From:** `compose/docker-compose.kafka.yml` (lines 173-217)

```yaml
rbac-consumer:
  build:
    context: ../consumers/rbac-consumer
    dockerfile: Dockerfile
  container_name: kessel-rbac-consumer
  depends_on:
    kafka:
      condition: service_healthy
    kessel-relations-api:
      condition: service_healthy
  ports:
    - "${RBAC_CONSUMER_METRICS_PORT:-9095}:9090"  # Prometheus metrics
  environment:
    # Kafka configuration
    KAFKA_BROKERS: kafka:29092
    RBAC_KAFKA_CONSUMER_GROUP_ID: rbac-consumer-group

    # Topics
    RBAC_KAFKA_CONSUMER_TOPIC_WORKSPACES: rbac.workspaces.events
    RBAC_KAFKA_CONSUMER_TOPIC_ROLES: rbac.roles.events

    # Relations API
    KESSEL_RELATIONS_API_URL: http://kessel-relations-api:8000

    # Metrics
    METRICS_PORT: "9090"
  networks:
    - kessel-network
  restart: unless-stopped
  healthcheck:
    test: ["CMD", "test", "-f", "/tmp/kubernetes-liveness"]
    interval: 10s
    timeout: 5s
    retries: 5
    start_period: 30s
  deploy:
    resources:
      limits:
        memory: 256M
        cpus: '0.5'
      reservations:
        memory: 128M
        cpus: '0.25'
```

### Environment Variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `KAFKA_BROKERS` | `kafka:29092` | Kafka broker address (internal Docker network) |
| `RBAC_KAFKA_CONSUMER_GROUP_ID` | `rbac-consumer-group` | Consumer group ID for Kafka |
| `RBAC_KAFKA_CONSUMER_TOPIC_WORKSPACES` | `rbac.workspaces.events` | Topic for workspace events |
| `RBAC_KAFKA_CONSUMER_TOPIC_ROLES` | `rbac.roles.events` | Topic for role events |
| `KESSEL_RELATIONS_API_URL` | `http://kessel-relations-api:8000` | Relations API endpoint |
| `METRICS_PORT` | `9090` | Internal metrics port |
| `RBAC_CONSUMER_METRICS_PORT` | `9095` | External metrics port (host) |

### Key Features

**1. Production-Ready Patterns:**
- Exponential backoff retry with jitter
- Circuit breaker for API failures
- Prometheus metrics export
- Structured logging
- Health checks (Kubernetes-compatible)

**2. Debezium Event Processing:**
- Processes flattened CDC events (ExtractNewRecordState SMT)
- Handles create (c), update (u), delete (d), snapshot (r) operations
- Validates event structure before processing
- Tracks processing duration and errors

**3. Prometheus Metrics:**
- `rbac_kafka_consumer_messages_processed_total` - Total messages by topic and status
- `rbac_kafka_consumer_validation_errors_total` - Validation errors
- `rbac_kafka_consumer_retry_attempts_total` - Retry attempts
- `rbac_kafka_consumer_message_processing_duration_seconds` - Processing latency

**4. Health Checks:**
- Creates `/tmp/kubernetes-liveness` file when ready
- Kubernetes-compatible health probe
- Graceful shutdown on SIGTERM/SIGINT

### Code Structure

**Main Components (main.go):**
```go
// Debezium event structure (flattened by SMT)
type DebeziumEvent struct {
    ID          string `json:"id"`
    Name        string `json:"name"`
    WorkspaceID string `json:"workspace_id"`
    Op          string `json:"__op"`      // c/u/d/r
    Table       string `json:"__table"`
    // ...
}

// Relationship API request
type RelationshipRequest struct {
    ResourceType string `json:"resource_type"`
    ResourceID   string `json:"resource_id"`
    Relation     string `json:"relation"`
    SubjectType  string `json:"subject_type"`
    SubjectID    string `json:"subject_id"`
}

// Main consumer with retry logic
type RBACConsumer struct {
    relationsAPIURL string
    consumer        sarama.ConsumerGroup
    topics          []string
    // ...
}
```

### Processing Flow

1. **Consumer subscribes** to Kafka topics (rbac.workspaces.events, rbac.roles.events)
2. **Receives flattened Debezium event** (already processed by ExtractNewRecordState SMT)
3. **Validates event** (checks required fields)
4. **Maps to relationship** based on operation type:
   - **Workspace created:** Create `workspace:parent:organization` relationship
   - **Role created:** Create `role:workspace:workspace_id` relationship
   - **Delete operations:** Delete corresponding relationships
5. **Calls Relations API** with exponential backoff retry
6. **Records metrics** for monitoring
7. **Commits offset** to Kafka

### Debezium SMT Configuration

The RBAC consumer expects Debezium to be configured with **ExtractNewRecordState SMT**:

```json
{
  "transforms": "unwrap",
  "transforms.unwrap.type": "io.debezium.transforms.ExtractNewRecordState",
  "transforms.unwrap.drop.tombstones": "false",
  "transforms.unwrap.delete.handling.mode": "rewrite",
  "transforms.unwrap.add.fields": "op,table,lsn,source.ts_ms"
}
```

This flattens the event structure so all data fields are at the top level (no `payload.after` nesting).

---

## 2. Inventory Consumer Configuration

### Location
- **Directory:** `consumers/inventory-consumer/`
- **Container Name:** `kessel-inventory-consumer`
- **Language:** Go 1.21
- **Source:** Official project-kessel repository
- **Version:** 0.1.0

### Docker Configuration

**From:** `compose/docker-compose.kafka.yml` (lines 219-251)

```yaml
inventory-consumer:
  build:
    context: ../consumers/inventory-consumer
    dockerfile: Dockerfile
    args:
      VERSION: latest
  container_name: kessel-inventory-consumer
  command: ["start"]
  depends_on:
    kafka:
      condition: service_healthy
    kessel-inventory-api:
      condition: service_healthy
  environment:
    INVENTORY_CONSUMER_CONFIG: /config.yaml
  volumes:
    - ../consumers/inventory-consumer/config.yaml:/config.yaml:ro
  networks:
    - kessel-network
  restart: unless-stopped
  deploy:
    resources:
      limits:
        memory: 256M
        cpus: '0.5'
      reservations:
        memory: 128M
        cpus: '0.25'
```

### Configuration File

The consumer uses a **YAML configuration file** instead of environment variables.

**File:** `consumers/inventory-consumer/config.yaml`

```yaml
consumer:
  bootstrap-servers: ["kafka:29092"]
  commit-modulo: 300
  topics:
    - inventory.hosts.events
    - inventory.host_groups.events
    - inventory.tags.events
  retry-options:
    consumer-max-retries: -1          # Unlimited retries
    operation-max-retries: -1         # Unlimited operation retries
    backoff-factor: 5                 # Exponential backoff multiplier
    max-backoff-seconds: 30           # Maximum wait between retries
  auth:
    enabled: false                     # No auth for local dev

client:
  enabled: true
  url: "http://kessel-inventory-api:8000"
  enable-oidc-auth: false
  insecure-client: true

log:
  level: "info"
```

### Key Features

**1. Production-Ready:**
- Built from official project-kessel repository
- Comprehensive error handling
- Exponential backoff retry logic
- Prometheus metrics on port 9000

**2. Multi-Topic Support:**
- Processes three different event types (hosts, groups, tags)
- Consumer group ID: `kic` (hardcoded in official consumer)
- 9 partitions total (3 per topic)

**3. API Integration:**
- Calls Inventory API for create/update/delete operations
- Retry logic with exponential backoff
- Connection pooling and health checks

**4. Monitoring:**
- Prometheus metrics exposed on port 9000
- Consumer lag tracking
- Message processing duration
- API call latency

### Build Process

The Dockerfile clones and builds from the official repository:

1. Clones https://github.com/project-kessel/inventory-consumer
2. Downloads Go dependencies
3. Builds using `make local-build`
4. Creates minimal runtime image (UBI9)
5. Binary size: ~35MB
6. Multi-architecture support (ARM64 + AMD64)

### Processing Flow

1. **Consumer subscribes** to Kafka topics
2. **Receives Debezium event** from CDC pipeline
3. **Validates event** structure
4. **Calls Inventory API** with retry logic:
   - Creates new resources
   - Updates existing resources
   - Deletes removed resources
5. **Records metrics** for monitoring
6. **Commits offset** to Kafka

### Consumer Group

- **Group ID:** `kic` (hardcoded in official consumer)
- **Topics:** 3 (inventory.hosts.events, inventory.host_groups.events, inventory.tags.events)
- **Partitions:** 9 total
- **Strategy:** Round-robin rebalancing

---

## Comparison: RBAC vs Inventory Consumer

| Feature | RBAC Consumer | Inventory Consumer |
|---------|---------------|-------------------|
| **Source** | Custom (Red Hat Insights patterns) | Official (project-kessel) |
| **Maturity** | ✅ Production-ready | ✅ Production-ready |
| **Version** | Custom | 0.1.0 |
| **Config Method** | Environment variables | YAML file |
| **Consumer Group** | `rbac-consumer-group` | `kic` |
| **Retry Logic** | ✅ Exponential backoff + jitter | ✅ Exponential backoff |
| **Metrics** | ✅ Prometheus metrics (port 9095) | ✅ Prometheus metrics (port 9000) |
| **Health Checks** | ✅ Kubernetes liveness probe | ✅ Service health checks |
| **Error Handling** | ✅ Circuit breaker, validation | ✅ Comprehensive retry logic |
| **Debezium Format** | Flattened (ExtractNewRecordState) | Standard CDC format |
| **API Calls** | ✅ Calls Relations API | ✅ Calls Inventory API |
| **Authentication** | None (local dev) | ✅ OIDC support (disabled for local) |
| **Maintenance** | Manual | Official upstream updates |

---

## Kafka Consumer Groups

### RBAC Consumer Group

**Group ID:** `rbac-consumer-group`

```bash
# View consumer group status
docker exec kessel-kafka kafka-consumer-groups \
  --bootstrap-server localhost:9092 \
  --group rbac-consumer-group \
  --describe
```

**Expected Output:**
```
GROUP                TOPIC                     PARTITION  CURRENT-OFFSET  LOG-END-OFFSET  LAG
rbac-consumer-group  rbac.workspaces.events    0          10              10              0
rbac-consumer-group  rbac.workspaces.events    1          8               8               0
rbac-consumer-group  rbac.workspaces.events    2          9               9               0
rbac-consumer-group  rbac.roles.events         0          15              15              0
rbac-consumer-group  rbac.roles.events         1          12              12              0
rbac-consumer-group  rbac.roles.events         2          14              14              0
```

**Healthy Status:**
- ✅ LAG = 0 (consumer keeping up)
- ✅ CONSUMER-ID present (consumer connected)

### Inventory Consumer Group

**Group ID:** `kic` (hardcoded in official consumer)

```bash
# View consumer group status
docker exec kessel-kafka kafka-consumer-groups \
  --bootstrap-server localhost:9092 \
  --group kic \
  --describe
```

**Expected Output:**
```
GROUP  TOPIC                        PARTITION  CURRENT-OFFSET  LOG-END-OFFSET  LAG  CONSUMER-ID                    HOST
kic    inventory.hosts.events       0          5               5               0    kic-xxx-xxx                    /10.89.3.198
kic    inventory.hosts.events       1          4               4               0    kic-xxx-xxx                    /10.89.3.198
kic    inventory.hosts.events       2          6               6               0    kic-xxx-xxx                    /10.89.3.198
kic    inventory.host_groups.events 0          2               2               0    kic-xxx-xxx                    /10.89.3.198
kic    inventory.host_groups.events 1          3               3               0    kic-xxx-xxx                    /10.89.3.198
kic    inventory.host_groups.events 2          2               2               0    kic-xxx-xxx                    /10.89.3.198
kic    inventory.tags.events        0          8               8               0    kic-xxx-xxx                    /10.89.3.198
kic    inventory.tags.events        1          7               7               0    kic-xxx-xxx                    /10.89.3.198
kic    inventory.tags.events        2          9               9               0    kic-xxx-xxx                    /10.89.3.198
```

---

## Monitoring

### RBAC Consumer Metrics

**Endpoint:** http://localhost:9095/metrics

**Key Metrics:**
```promql
# Total messages processed
rbac_kafka_consumer_messages_processed_total{topic="rbac.workspaces.events",status="success"}

# Processing duration
rate(rbac_kafka_consumer_message_processing_duration_seconds_sum[5m])

# Validation errors
rate(rbac_kafka_consumer_validation_errors_total[5m])

# Retry attempts
rate(rbac_kafka_consumer_retry_attempts_total[5m])
```

### Inventory Consumer Metrics

**Endpoint:** http://localhost:9000/metrics (port 9000 internal, not exposed by default)

**Key Metrics:**
```promql
# Messages processed (if exposed)
inventory_consumer_messages_processed_total

# Processing duration
inventory_consumer_processing_duration_seconds

# API call errors
inventory_consumer_api_errors_total
```

**To expose:** Add port mapping `9096:9000` in docker-compose

### Kafka Consumer Lag

Monitor lag via Prometheus (scraped from Kafka):

```promql
# Consumer lag
kafka_consumergroup_lag{group="rbac-consumer-group"}
kafka_consumergroup_lag{group="kic"}
```

**Alert when:** LAG > 100

---

## Logs

### RBAC Consumer Logs

```bash
# View logs
docker logs kessel-rbac-consumer -f

# Expected output
2026/02/17 15:09:27 Starting RBAC Kafka Consumer
2026/02/17 15:09:27 Kafka Brokers: kafka:29092
2026/02/17 15:09:27 Consumer Group: rbac-consumer-group
2026/02/17 15:09:27 Relations API: http://kessel-relations-api:8000
2026/02/17 15:09:27 Topics: [rbac.workspaces.events rbac.roles.events]
2026/02/17 15:09:27 Metrics Port: 9090
2026/02/17 15:09:27 Starting metrics server on :9090
2026/02/17 15:09:27 Starting to consume messages...
2026/02/17 15:09:30 Consumer group session setup complete
```

### Inventory Consumer Logs

```bash
# View logs
docker logs kessel-inventory-consumer -f

# Expected output
2026/02/17 15:09:27 Starting Inventory Consumer
2026/02/17 15:09:27 Kafka Brokers: kafka:29092
2026/02/17 15:09:27 Consumer Group: inventory-consumer-group
2026/02/17 15:09:27 Inventory API: http://kessel-inventory-api:8000
2026/02/17 15:09:27 Topics: [inventory.hosts.events inventory.host_groups.events inventory.tags.events]
2026/02/17 15:09:27 Starting to consume messages...
```

---

## Troubleshooting

### Consumer Not Starting

**Check dependencies:**
```bash
# Verify Kafka is healthy
docker ps | grep kafka

# Verify APIs are healthy
curl http://localhost:8082/livez  # Relations API
curl http://localhost:8083/livez  # Inventory API
```

### High Consumer Lag

**Check processing speed:**
```bash
# View RBAC consumer lag
docker exec kessel-kafka kafka-consumer-groups \
  --bootstrap-server localhost:9092 \
  --group rbac-consumer-group \
  --describe

# View Inventory consumer lag
docker exec kessel-kafka kafka-consumer-groups \
  --bootstrap-server localhost:9092 \
  --group kic \
  --describe
```

**If LAG > 100:**
1. Check consumer logs for errors
2. Verify API is responding
3. Check if consumer is stuck/crashed
4. Consider scaling consumers (increase partitions)

### Consumer Errors

**Check RBAC consumer logs:**
```bash
docker logs kessel-rbac-consumer | grep -i error
```

**Common errors:**
- "context deadline exceeded" - API timeout, check Relations API health
- "validation failed" - Event structure mismatch, check Debezium SMT config
- "connection refused" - Kafka or API not reachable

---

## Configuration Files

### Directory Structure

```
consumers/
├── rbac-consumer/
│   ├── Dockerfile          # Multi-stage Go build
│   ├── go.mod              # Go module dependencies
│   ├── go.sum              # Dependency checksums
│   └── main.go             # Consumer implementation
│
└── inventory-consumer/
    ├── Dockerfile          # Multi-stage Go build
    ├── go.mod              # Go module (auto-download)
    └── main.go             # Consumer stub
```

### Build Process

**RBAC Consumer:**
```dockerfile
# Stage 1: Build
FROM golang:1.21-alpine AS builder
COPY go.mod go.sum* ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -o rbac-consumer .

# Stage 2: Runtime
FROM alpine:latest
COPY --from=builder /build/rbac-consumer .
CMD ["./rbac-consumer"]
```

**Inventory Consumer:**
```dockerfile
# Stage 1: Build
FROM golang:1.21-alpine AS builder
COPY . .
RUN CGO_ENABLED=0 go build -mod=mod -o inventory-consumer .

# Stage 2: Runtime
FROM alpine:latest
COPY --from=builder /app/inventory-consumer .
CMD ["./inventory-consumer"]
```

---

## Dependencies

### Go Packages

**RBAC Consumer (go.mod):**
```go
module rbac-consumer

go 1.21

require (
    github.com/IBM/sarama v1.42.1           // Kafka client
    github.com/prometheus/client_golang     // Metrics
)
```

**Inventory Consumer (go.mod):**
```go
module inventory-consumer

go 1.21

require github.com/IBM/sarama v1.42.1
```

### Sarama Configuration

**RBAC Consumer:**
- Version: V3_0_0_0
- Rebalance: RoundRobin
- Initial offset: OffsetOldest (consume from beginning)
- Return errors: true

**Inventory Consumer:**
- Same configuration as RBAC consumer

---

## Production Considerations

### RBAC Consumer

**Ready for production:**
- ✅ Retry logic with exponential backoff
- ✅ Circuit breaker for API failures
- ✅ Prometheus metrics
- ✅ Health checks
- ✅ Graceful shutdown
- ✅ Resource limits configured

**Scaling:**
- Partitions: 3 per topic (rbac.workspaces.events, rbac.roles.events)
- Max consumers: 3 (one per partition)
- Increase partitions to scale beyond 3 consumers

### Inventory Consumer

**Ready for production:**
- ✅ Official project-kessel implementation
- ✅ API calls with retry logic
- ✅ Prometheus metrics (port 9000)
- ✅ Comprehensive error handling
- ✅ YAML configuration file
- ✅ OIDC authentication support (disabled for local dev)

**Built from:** https://github.com/project-kessel/inventory-consumer

**For production:**
1. Enable OIDC authentication in config
2. Use TLS for Kafka and API connections
3. Expose metrics port for Prometheus scraping
4. Configure proper resource limits
5. Set up alerting on consumer lag
6. Consider using official AMD64 image if on x86_64 platform

---

## Summary

**Two consumers handle event-driven data synchronization:**

**RBAC Consumer:**
- Production-ready Go application
- Processes RBAC CDC events from Kafka
- Creates authorization relationships in SpiceDB via Relations API
- Includes retry logic, metrics, and health checks
- Exposed on port 9095 for metrics

**Inventory Consumer:**
- Demo stub implementation
- Processes Inventory CDC events from Kafka
- Should call Inventory API (currently just logs)
- For production: use official project-kessel/inventory-consumer

**Key Configuration:**
- Both use Sarama Kafka client
- Both subscribe to specific Kafka topics
- Both connect to respective APIs
- RBAC consumer is production-ready
- Inventory consumer is placeholder for kessel-stack

**Old Consumer Removed:**
- `relations-sink` was the original RBAC consumer
- Replaced by production-ready `rbac-consumer`
- Directory removed from consumers/

---

*For more details, see:*
- compose/docker-compose.kafka.yml (consumer definitions)
- consumers/rbac-consumer/main.go (RBAC implementation)
- consumers/inventory-consumer/main.go (Inventory stub)
