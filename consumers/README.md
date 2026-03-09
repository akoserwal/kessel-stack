# Kessel Kafka Consumers

**Last Updated:** 2026-02-17
**Status:** ✅ Production-Ready

This directory contains the Kafka consumers for the Kessel Stack CDC (Change Data Capture) pipeline.

---

## Overview

Two production-ready Kafka consumers process events from PostgreSQL databases:

```
PostgreSQL → Debezium (CDC) → Kafka → Consumers → APIs → SpiceDB
```

| Consumer | Purpose | Source | Status |
|----------|---------|--------|--------|
| **RBAC Consumer** | Processes RBAC events<br>Creates authorization relationships in SpiceDB | Custom<br>(Red Hat Insights patterns) | ✅ Production-ready |
| **Inventory Consumer** | Processes inventory events<br>Syncs resources to Inventory API | Official<br>(project-kessel/inventory-consumer) | ✅ Production-ready |

---

## Directory Structure

```
consumers/
├── README.md                          # This file - Overview
├── CONSUMER_CONFIGURATION.md          # Complete configuration guide
│
├── rbac-consumer/                     # RBAC Kafka Consumer
│   ├── Dockerfile                     # Go multi-stage build
│   ├── go.mod, go.sum                 # Go dependencies
│   └── main.go                        # Consumer implementation
│
└── inventory-consumer/                # Inventory Kafka Consumer
    ├── Dockerfile                     # Builds from official repo
    ├── config.yaml                    # YAML configuration
    └── README.md                      # Inventory consumer guide
```

---

## Quick Start

### Start Both Consumers

```bash
docker compose -f compose/docker-compose.yml \
  -f compose/docker-compose.kafka.yml \
  up -d
```

### Check Status

```bash
# View running consumers
docker ps | grep consumer

# Check RBAC consumer logs
docker logs kessel-rbac-consumer -f

# Check Inventory consumer logs
docker logs kessel-inventory-consumer -f
```

### Monitor Consumer Groups

```bash
# List all consumer groups
docker exec kessel-kafka kafka-consumer-groups \
  --bootstrap-server localhost:9092 \
  --list

# Check RBAC consumer group
docker exec kessel-kafka kafka-consumer-groups \
  --bootstrap-server localhost:9092 \
  --group rbac-consumer-group \
  --describe

# Check Inventory consumer group
docker exec kessel-kafka kafka-consumer-groups \
  --bootstrap-server localhost:9092 \
  --group kic \
  --describe
```

---

## RBAC Consumer

### Purpose
Processes RBAC (Role-Based Access Control) events from PostgreSQL and creates authorization relationships in SpiceDB via the Relations API.

### Configuration
- **Method:** Environment variables
- **Topics:** `rbac.workspaces.events`, `rbac.roles.events`
- **Consumer Group:** `rbac-consumer-group`
- **Metrics Port:** 9095 (Prometheus)

### Key Features
- ✅ Exponential backoff retry with jitter
- ✅ Circuit breaker for API failures
- ✅ Prometheus metrics export
- ✅ Kubernetes health probes
- ✅ Based on Red Hat Insights RBAC patterns

### Quick Check
```bash
# View logs
docker logs kessel-rbac-consumer --tail 20

# Check health
curl http://localhost:9095/metrics

# View consumer lag
docker exec kessel-kafka kafka-consumer-groups \
  --bootstrap-server localhost:9092 \
  --group rbac-consumer-group \
  --describe
```

---

## Inventory Consumer

### Purpose
Processes inventory events (hosts, groups, tags) from PostgreSQL and syncs them to the Kessel Inventory API.

### Configuration
- **Method:** YAML configuration file
- **Topics:** `inventory.hosts.events`, `inventory.host_groups.events`, `inventory.tags.events`
- **Consumer Group:** `kic` (hardcoded in official consumer)
- **Metrics Port:** 9000 (internal, not exposed)

### Key Features
- ✅ Official project-kessel implementation (v0.1.0)
- ✅ Built from https://github.com/project-kessel/inventory-consumer
- ✅ Exponential backoff retry logic
- ✅ Prometheus metrics
- ✅ OIDC authentication support (disabled for local dev)
- ✅ Comprehensive error handling

### Quick Check
```bash
# View logs
docker logs kessel-inventory-consumer --tail 20

# Verify config
docker exec kessel-inventory-consumer cat /config.yaml

# View consumer lag
docker exec kessel-kafka kafka-consumer-groups \
  --bootstrap-server localhost:9092 \
  --group kic \
  --describe
```

---

## Data Flow

### RBAC Pipeline
```
PostgreSQL (RBAC DB)
    ↓ Debezium CDC
Kafka Topics (rbac.workspaces.events, rbac.roles.events)
    ↓ RBAC Consumer
Relations API (kessel-relations-api:8000)
    ↓ gRPC
SpiceDB (Authorization Engine)
```

### Inventory Pipeline
```
PostgreSQL (Inventory DB)
    ↓ Debezium CDC
Kafka Topics (inventory.hosts.events, inventory.host_groups.events, inventory.tags.events)
    ↓ Inventory Consumer (kic)
Inventory API (kessel-inventory-api:8000)
```

---

## Monitoring

### Consumer Lag

**Healthy:** LAG = 0 (consumer is keeping up)
**Warning:** LAG > 100
**Critical:** LAG > 1000

```bash
# Check lag for all consumers
docker exec kessel-kafka kafka-consumer-groups \
  --bootstrap-server localhost:9092 \
  --describe --all-groups
```

### Metrics

**RBAC Consumer:**
- Endpoint: http://localhost:9095/metrics
- Metrics: Messages processed, retry attempts, validation errors, processing duration

**Inventory Consumer:**
- Endpoint: Internal port 9000 (not exposed)
- To expose: Add `ports: ["9096:9000"]` in docker-compose
- Metrics: Messages processed, API calls, error rates

---

## Troubleshooting

### Consumer Not Starting

```bash
# Check dependencies
docker ps | grep -E "kafka|postgres"

# View full logs
docker logs kessel-rbac-consumer
docker logs kessel-inventory-consumer

# Restart consumer
docker restart kessel-rbac-consumer
docker restart kessel-inventory-consumer
```

### High Consumer Lag

```bash
# Identify the problem
docker logs kessel-rbac-consumer | grep -i error
docker logs kessel-inventory-consumer | grep -i error

# Check API health
curl http://localhost:8082/livez  # Relations API
curl http://localhost:8083/livez  # Inventory API

# Check Kafka connectivity
docker exec kessel-rbac-consumer nc -zv kafka 29092
```

### Config File Issues (Inventory Consumer)

```bash
# Verify config file exists
ls -l consumers/inventory-consumer/config.yaml

# Verify config is mounted
docker exec kessel-inventory-consumer cat /config.yaml

# Check for config errors in logs
docker logs kessel-inventory-consumer | grep -i config
```

---

## Configuration Files

### RBAC Consumer Environment Variables

Set in `compose/docker-compose.kafka.yml`:

```yaml
environment:
  KAFKA_BROKERS: kafka:29092
  RBAC_KAFKA_CONSUMER_GROUP_ID: rbac-consumer-group
  RBAC_KAFKA_CONSUMER_TOPIC_WORKSPACES: rbac.workspaces.events
  RBAC_KAFKA_CONSUMER_TOPIC_ROLES: rbac.roles.events
  KESSEL_RELATIONS_API_URL: http://kessel-relations-api:8000
  METRICS_PORT: "9090"
```

### Inventory Consumer Config File

File: `consumers/inventory-consumer/config.yaml`

```yaml
consumer:
  bootstrap-servers: ["kafka:29092"]
  topics:
    - inventory.hosts.events
    - inventory.host_groups.events
    - inventory.tags.events
  retry-options:
    consumer-max-retries: -1
    operation-max-retries: -1
    backoff-factor: 5
    max-backoff-seconds: 30

client:
  url: "http://kessel-inventory-api:8000"

log:
  level: "info"
```

---

## Comparison

| Feature | RBAC Consumer | Inventory Consumer |
|---------|---------------|-------------------|
| **Source** | Custom implementation | Official project-kessel |
| **Config** | Environment variables | YAML file |
| **Consumer Group** | `rbac-consumer-group` | `kic` |
| **Topics** | 2 RBAC topics | 3 inventory topics |
| **Partitions** | 6 total | 9 total |
| **Metrics Port** | 9095 (exposed) | 9000 (internal) |
| **Health Probes** | ✅ Kubernetes-compatible | ✅ Health checks |
| **Retry Logic** | ✅ Exponential backoff | ✅ Exponential backoff |
| **Production Ready** | ✅ Yes | ✅ Yes |

---

## Production Deployment

### RBAC Consumer
- ✅ Ready for production as-is
- Configure resource limits
- Set up Prometheus scraping
- Configure alerting on lag

### Inventory Consumer
- ✅ Ready for production
- Built from official source (v0.1.0)
- Enable OIDC auth for production
- Use TLS for Kafka/API connections
- Expose metrics port for monitoring
- Consider official AMD64 image for x86_64

---

## Development

### Building Locally

**RBAC Consumer:**
```bash
cd consumers/rbac-consumer
docker build -t kessel-rbac-consumer:dev .
```

**Inventory Consumer:**
```bash
cd consumers/inventory-consumer
docker build -t kessel-inventory-consumer:dev .
```

### Running Standalone

**RBAC Consumer:**
```bash
docker run -d \
  --name rbac-consumer \
  --network kessel-network \
  -e KAFKA_BROKERS=kafka:29092 \
  -e KESSEL_RELATIONS_API_URL=http://kessel-relations-api:8000 \
  kessel-rbac-consumer:dev
```

**Inventory Consumer:**
```bash
docker run -d \
  --name inventory-consumer \
  --network kessel-network \
  -e INVENTORY_CONSUMER_CONFIG=/config.yaml \
  -v $(pwd)/config.yaml:/config.yaml:ro \
  kessel-inventory-consumer:dev start
```

---

## Documentation

- **[CONSUMER_CONFIGURATION.md](CONSUMER_CONFIGURATION.md)** - Complete configuration guide with all details
- **[rbac-consumer/](rbac-consumer/)** - RBAC consumer source code
- **[inventory-consumer/README.md](inventory-consumer/README.md)** - Inventory consumer detailed guide
- **[inventory-consumer/config.yaml](inventory-consumer/config.yaml)** - Configuration file

---

## References

- **RBAC Consumer:** Based on Red Hat Insights RBAC consumer patterns
- **Inventory Consumer:** https://github.com/project-kessel/inventory-consumer
- **Debezium:** https://debezium.io
- **Kafka:** https://kafka.apache.org
- **Sarama:** https://github.com/IBM/sarama (Kafka client for Go)

---

## Summary

✅ **Two production-ready Kafka consumers**
✅ **RBAC Consumer:** Custom implementation with Red Hat Insights patterns
✅ **Inventory Consumer:** Official project-kessel implementation (v0.1.0)
✅ **Both:** Comprehensive error handling, retry logic, and monitoring
✅ **Status:** Ready for production use

**Quick verification:**
```bash
# Check both consumers are running
docker ps | grep consumer

# Verify zero lag
docker exec kessel-kafka kafka-consumer-groups \
  --bootstrap-server localhost:9092 \
  --describe --all-groups
```

---

*For detailed configuration and advanced usage, see [CONSUMER_CONFIGURATION.md](CONSUMER_CONFIGURATION.md)*
