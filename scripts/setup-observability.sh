#!/usr/bin/env bash

# Observability Setup Script
# Configures Prometheus, Grafana, and Jaeger for Kessel monitoring

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
echo "  Setting up Observability Stack"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo

# Wait for Prometheus to be ready
log_info "Waiting for Prometheus to be ready..."
max_attempts=30
attempt=0

while ! curl -sf http://localhost:9091/-/healthy &>/dev/null; do
    attempt=$((attempt + 1))
    if [[ $attempt -ge $max_attempts ]]; then
        log_error "Prometheus not ready after $max_attempts attempts"
        exit 1
    fi
    sleep 2
done

log_success "Prometheus is ready"

# Wait for Grafana to be ready
log_info "Waiting for Grafana to be ready..."
attempt=0

while ! curl -sf http://localhost:3000/api/health &>/dev/null; do
    attempt=$((attempt + 1))
    if [[ $attempt -ge $max_attempts ]]; then
        log_error "Grafana not ready after $max_attempts attempts"
        exit 1
    fi
    sleep 2
done

log_success "Grafana is ready"

# Wait for Jaeger to be ready
log_info "Waiting for Jaeger to be ready..."
attempt=0

while ! curl -sf http://localhost:16686/ &>/dev/null; do
    attempt=$((attempt + 1))
    if [[ $attempt -ge $max_attempts ]]; then
        log_warn "Jaeger not ready, skipping (optional component)"
        break
    fi
    sleep 2
done

if curl -sf http://localhost:16686/ &>/dev/null; then
    log_success "Jaeger is ready"
fi

# Check Prometheus targets
log_info "Checking Prometheus targets..."
targets_up=$(curl -s http://localhost:9091/api/v1/targets | grep -o '"health":"up"' | wc -l || echo "0")
targets_total=$(curl -s http://localhost:9091/api/v1/targets | grep -o '"health":"' | wc -l || echo "0")

log_info "Prometheus targets: $targets_up/$targets_total up"

# Display configuration info
log_info "Observability Stack Configuration:"
echo "  Prometheus retention: ${PROMETHEUS_RETENTION:-15d}"
echo "  Grafana admin user: ${GRAFANA_ADMIN_USER:-admin}"
echo "  Alert evaluation interval: 15s"

# Create documentation
cat > "${PROJECT_ROOT}/docs/observability-guide.md" << 'EOF'
# Observability Guide

This guide covers monitoring and observability for Kessel Stack.

## Overview

The observability stack includes:
- **Prometheus**: Metrics collection and storage
- **Grafana**: Visualization and dashboards
- **Jaeger**: Distributed tracing
- **AlertManager**: Alert routing and management

## Access Points

- **Prometheus**: http://localhost:9091
- **Grafana**: http://localhost:3000 (admin/admin)
- **Jaeger UI**: http://localhost:16686
- **AlertManager**: http://localhost:9093

## Pre-built Dashboards

### SpiceDB Overview
Shows key SpiceDB metrics:
- Request rate
- Error rate
- Latency percentiles (p50, p95, p99)
- Active connections

Access: Grafana → Dashboards → Kessel → SpiceDB Overview

## Key Metrics

### SpiceDB

**Request Rate**:
```promql
rate(spicedb_grpc_server_started_total[1m])
```

**Error Rate**:
```promql
rate(spicedb_grpc_server_handled_total{grpc_code!="OK"}[1m])
```

**Latency (p99)**:
```promql
histogram_quantile(0.99, rate(spicedb_grpc_server_handling_seconds_bucket[1m]))
```

### Redis

**Hit Rate**:
```promql
rate(redis_keyspace_hits_total[5m]) /
(rate(redis_keyspace_hits_total[5m]) + rate(redis_keyspace_misses_total[5m]))
```

**Memory Usage**:
```promql
redis_memory_used_bytes / redis_memory_max_bytes
```

### Kafka

**Consumer Lag**:
```promql
kafka_consumergroup_lag
```

**Under-replicated Partitions**:
```promql
kafka_server_replicamanager_underreplicatedpartitions
```

## Alerts

### Critical Alerts

- **SpiceDBDown**: SpiceDB unavailable for >1 minute
- **PostgresDown**: Database unavailable for >1 minute
- **RedisDown**: Cache unavailable for >1 minute
- **KafkaDown**: Kafka unavailable for >1 minute

### Warning Alerts

- **SpiceDBHighErrorRate**: >5% errors for 5 minutes
- **SpiceDBHighLatency**: p99 >1s for 5 minutes
- **RedisLowHitRate**: <50% hit rate for 10 minutes
- **RedisHighMemory**: >90% memory usage for 5 minutes
- **KafkaHighConsumerLag**: >1000 messages lag

## Troubleshooting with Metrics

### High Latency Investigation

1. Check SpiceDB latency:
   ```promql
   histogram_quantile(0.99, rate(spicedb_grpc_server_handling_seconds_bucket[5m]))
   ```

2. Check database query time:
   ```promql
   pg_stat_statements_mean_exec_time_ms
   ```

3. Check cache hit rate:
   ```promql
   rate(redis_keyspace_hits_total[5m]) /
   (rate(redis_keyspace_hits_total[5m]) + rate(redis_keyspace_misses_total[5m]))
   ```

### High Error Rate Investigation

1. Check error breakdown:
   ```promql
   rate(spicedb_grpc_server_handled_total{grpc_code!="OK"}[5m])
   ```

2. View error logs in Grafana Explore

3. Check trace samples in Jaeger

## Distributed Tracing

### Viewing Traces

1. Open Jaeger UI: http://localhost:16686
2. Select service: `spicedb`
3. Click "Find Traces"
4. Select a trace to view

### Understanding Traces

Each trace shows:
- Request path through components
- Timing breakdown
- Database queries
- Cache lookups
- Error details

### Example Trace Analysis

Permission check trace spans:
1. `CheckPermission` - Total request
2. `cache.lookup` - Redis check
3. `dispatch` - Permission computation
4. `db.query` - PostgreSQL query

## Custom Dashboards

### Creating a Dashboard

1. Open Grafana: http://localhost:3000
2. Click "+" → "Dashboard"
3. Add panels with PromQL queries
4. Save dashboard

### Example Panel

**Title**: Permission Check Rate
**Query**:
```promql
rate(spicedb_grpc_server_started_total{grpc_method="CheckPermission"}[1m])
```

## Alert Configuration

### Adding Slack Notifications

Edit `alertmanager/config.yml`:

```yaml
receivers:
  - name: 'critical'
    slack_configs:
      - api_url: 'YOUR_SLACK_WEBHOOK_URL'
        channel: '#alerts-critical'
        title: 'Critical Alert'
```

### Adding Email Notifications

```yaml
receivers:
  - name: 'warning'
    email_configs:
      - to: 'team@example.com'
        from: 'alertmanager@kessel.local'
        smarthost: 'smtp.example.com:587'
```

## Performance Monitoring

### Key Performance Indicators

Monitor these metrics:

1. **Latency**: p50 < 10ms, p99 < 50ms
2. **Error Rate**: < 1%
3. **Cache Hit Rate**: > 70%
4. **Resource Usage**: CPU < 80%, Memory < 90%

### Setting Up Alerts

Alerts are pre-configured in `prometheus/alerts.yml`.

To modify thresholds, edit the file and reload:

```bash
docker exec kessel-prometheus kill -HUP 1
```

## Retention and Storage

### Prometheus

- **Retention**: 15 days (configurable via `PROMETHEUS_RETENTION`)
- **Storage**: `/prometheus` volume
- **Disk Usage**: ~1GB per day for typical load

### Grafana

- **Database**: SQLite (local)
- **Dashboards**: Persisted in volume

### Jaeger

- **Storage**: BadgerDB (local, ephemeral in dev)
- **Retention**: Unlimited in dev (configure for prod)

## Next Steps

1. Explore pre-built dashboards
2. Create custom dashboards for your use case
3. Configure alert receivers (Slack, email, PagerDuty)
4. Set up log aggregation (Loki) for complete observability
EOF

log_success "Observability guide created at docs/observability-guide.md"

echo
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_success "Observability Stack setup complete!"
echo
echo "Access Points:"
echo "  Prometheus:   http://localhost:9091"
echo "  Grafana:      http://localhost:3000 (admin/admin)"
echo "  Jaeger UI:    http://localhost:16686"
echo "  AlertManager: http://localhost:9093"
echo
echo "Quick Start:"
echo "  # View metrics"
echo "  open http://localhost:9091/graph"
echo
echo "  # View dashboards"
echo "  open http://localhost:3000"
echo "  Navigate to: Dashboards → Kessel → SpiceDB Overview"
echo
echo "  # View traces"
echo "  open http://localhost:16686"
echo "  Select service: spicedb → Find Traces"
echo
echo "  # Check alerts"
echo "  curl http://localhost:9091/api/v1/alerts"
echo
echo "Documentation:"
echo "  Complete guide: docs/observability-guide.md"
echo "  Prometheus config: prometheus/prometheus.yml"
echo "  Alert rules: prometheus/alerts.yml"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
