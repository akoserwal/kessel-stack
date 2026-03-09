# Kessel Grafana Dashboards Guide

**Last Updated:** 2026-02-16
**Grafana Version:** 10.2.2
**Access:** http://localhost:3000 (admin/admin)

---

## Overview

The Kessel Stack Grafana dashboards provide comprehensive observability for the entire Kessel authorization system, including APIs, SpiceDB, data pipelines, and infrastructure.

**Total Dashboards:** 7

---

## Dashboard Catalog

### 1. **Kessel APIs Overview** 🎯 START HERE

**File:** `kessel-apis-overview.json`
**Purpose:** High-level overview of all API services and system health

**Use For:**
- Quick system health checks before demos
- Identifying service issues at a glance
- Monitoring overall system performance

**Key Metrics:**
- ✅ Service status (Inventory API, Relations API, SpiceDB)
- 📊 Combined API request rates across all services
- ⏱️ Average latency (p50, p95, p99) for all APIs
- ❌ Error rates (4xx, 5xx) with threshold warnings
- 💾 Database connection pool status
- 📈 Total requests by status code (time series)

**Panels:**
1. **Service Health Row**
   - Inventory API Status (up/down indicator)
   - Relations API Status (up/down indicator)
   - SpiceDB Status (up/down indicator)

2. **Performance Row**
   - Combined Request Rate (requests/second)
   - Average Latency (milliseconds)
   - Error Rate Percentage (color-coded thresholds)
   - Total Requests (cumulative counter)

3. **Request Breakdown**
   - Requests by Status Code (time series graph)
   - Error breakdown (5xx vs 4xx)

4. **Database**
   - PostgreSQL Connection Pool
   - Database Operations Rate

**Best For:** Demo introductions, executive summaries, incident response

---

### 2. **Kessel Inventory API** 📦

**File:** `kessel-inventory-api.json`
**Purpose:** Detailed monitoring of the Inventory API service (resource management)

**Use For:**
- Debugging inventory operations
- Understanding resource type distribution
- Monitoring database performance
- Tracking authorization integration

**Key Metrics:**
- 🔄 Request rate and latency by endpoint
- 📝 Resource operations (create, update, delete)
- 🗄️ PostgreSQL database performance
- 🔐 Authorization API calls to Relations API
- 📊 Resource distribution by type

**Panels:**
1. **Service Health & Overview**
   - Inventory API Status
   - Requests Per Second
   - Average Response Time
   - Error Rate
   - Total Requests

2. **HTTP Metrics**
   - Request Rate by Endpoint (breakdown by handler/method)
   - Response Latency (p50, p95, p99 percentiles)
   - Status Code Summary Table
   - Error Distribution (pie chart)

3. **Resource Operations**
   - Resources Created (by type: host, group, workspace)
   - Resources Updated
   - Resources Deleted
   - Resource Distribution by Type

4. **Database Performance**
   - PostgreSQL Active Connections
   - Database Operations Rate (inserts, updates, deletes)
   - Query Latency Distribution
   - Connection Pool Utilization

5. **Authorization Integration**
   - Permission Check Rate (calls to Relations API)
   - Relationship Creation Rate
   - Authorization Latency
   - Authorization Errors

**Best For:** Inventory-specific troubleshooting, resource management analysis

---

### 3. **Kessel Relations API & SpiceDB** 🔐

**File:** `kessel-relations-api.json`
**Purpose:** Comprehensive monitoring of authorization services

**Use For:**
- Monitoring permission check performance
- Debugging authorization failures
- Understanding relationship operations
- Tracking SpiceDB internal metrics

**Key Metrics:**
- ⚡ Permission check latency and throughput
- 🔗 Relationship management operations
- 📡 gRPC method performance
- 💻 Go runtime metrics (goroutines, memory, GC)
- 📊 Status code distribution

**Panels:**
1. **Service Health & Overview**
   - SpiceDB Status
   - Relations API Status
   - Requests Per Second
   - Average Latency
   - Error Rate

2. **gRPC Method Performance**
   - Request Rate by Method (CheckPermission, WriteRelationships, etc.)
   - Latency by Method (p50, p95, p99)
   - Top Methods Table (sorted by call count)

3. **Permission Checks** ⭐ DEMO HIGHLIGHT
   - Permission Check Rate (checks/second)
   - Permission Check Latency (histogram)
   - Permission Results (granted vs denied)
   - Check Performance Trend

4. **Relationship Management**
   - Relationships Created
   - Relationships Read
   - Relationships Deleted
   - Active Relationship Count

5. **Status Codes & Errors**
   - gRPC Status Codes (OK, PermissionDenied, NotFound, etc.)
   - Error Rate by Code
   - Status Distribution (pie chart)

6. **Go Runtime Metrics**
   - Active Goroutines
   - Memory Allocated
   - GC Pause Time
   - Memory Usage Trend

**Best For:** Authorization troubleshooting, performance optimization, demo deep-dives

---

### 4. **Kessel Data Pipeline** 🌊

**File:** `kessel-data-pipeline.json`
**Purpose:** Kafka streaming and CDC (Change Data Capture) monitoring

**Use For:**
- Monitoring event streaming health
- Detecting consumer lag
- Tracking CDC replication
- Debugging data flow issues

**Key Metrics:**
- 📨 Kafka message throughput
- ⏰ Consumer group lag
- 📤 Event publishing from Inventory API
- 🔄 CDC replication status
- 🖥️ Kafka broker health

**Panels:**
1. **Kafka Cluster Health**
   - Active Brokers
   - Under-Replicated Partitions (should be 0)
   - Offline Partitions (should be 0)
   - Leader Count per Broker

2. **Kafka Throughput**
   - Network Bytes In/Out
   - Messages In/Out Rate
   - Total Messages Processed

3. **Topic Metrics** (Inventory Events)
   - Inventory Topic Bytes In
   - Inventory Topic Messages In
   - Topic Partition Count

4. **Consumer Group Lag** ⚠️ CRITICAL
   - Consumer Lag by Topic
   - Lag by Partition
   - Lag Trend (should be near 0)

5. **Event Publishing** (from Inventory API)
   - Events Published Rate
   - Event Publish Errors
   - Event Types Distribution
   - Publishing Latency

6. **CDC & Replication** (Debezium)
   - CDC Connector Status
   - Replication Lag
   - Events Captured
   - Connector Errors

7. **Kafka Resource Usage**
   - CPU Usage
   - JVM Heap Memory
   - JVM GC Time
   - Disk Usage

**Best For:** Data pipeline troubleshooting, event streaming analysis

---

### 5. **Kessel Complete System** (Existing)

**File:** `kessel-complete-system.json`
**Purpose:** Original comprehensive system dashboard

**Retained For:** Historical reference and comprehensive view

---

### 6. **Kessel Data Flow** (Existing)

**File:** `kessel-data-flow.json`
**Purpose:** Original data flow visualization

**Retained For:** Visual representation of data movement

---

### 7. **SpiceDB Overview** (Existing)

**File:** `spicedb-overview.json`
**Purpose:** Basic SpiceDB metrics

**Note:** Superseded by the more comprehensive Relations API dashboard, but kept for backward compatibility

---

## Dashboard Organization in Grafana

All dashboards are organized in the **"Kessel"** folder with this hierarchy:

```
📁 Kessel/
├── 🎯 Kessel APIs Overview          (START HERE)
├── 📦 Kessel Inventory API
├── 🔐 Kessel Relations API & SpiceDB
├── 🌊 Kessel Data Pipeline
├── 📊 Kessel Complete System        (legacy)
├── 🔄 Kessel Data Flow              (legacy)
└── ⚡ SpiceDB Overview               (legacy)
```

---

## Quick Navigation Guide

### For Demos

**Recommended Flow:**
1. **Start:** Kessel APIs Overview (system health)
2. **Deep Dive:** Relations API & SpiceDB (show permission checks)
3. **Advanced:** Data Pipeline (show real-time event streaming)

**Key Demo Points:**
- Show sub-10ms permission check latency in Relations API dashboard
- Demonstrate request rates in APIs Overview
- Highlight consumer lag = 0 in Data Pipeline (real-time updates)

### For Troubleshooting

**High Error Rates:**
1. Check **APIs Overview** for which service has errors
2. Drill into specific API dashboard (Inventory or Relations)
3. Review status code distribution and error panels

**Slow Performance:**
1. Check **APIs Overview** for overall latency
2. Review specific API dashboard for p95/p99 latency
3. Check **Data Pipeline** for consumer lag issues
4. Review database panels for connection pool saturation

**Data Flow Issues:**
1. Start with **Data Pipeline** dashboard
2. Check consumer lag metrics
3. Review event publishing from Inventory API
4. Check CDC connector status

### For Operations

**Daily Checks:**
- [ ] APIs Overview - all services green
- [ ] Relations API - permission check latency <10ms
- [ ] Data Pipeline - consumer lag <100

**Weekly Review:**
- [ ] Trend analysis on all request rate graphs
- [ ] Resource usage trends (database connections, memory)
- [ ] Error rate trends

---

## Metrics Reference

### Key Prometheus Metrics Used

#### HTTP/API Metrics
```
http_requests_total - Total HTTP requests
http_request_duration_seconds_bucket - Request latency histogram
http_requests_in_progress - Active requests
```

#### gRPC/SpiceDB Metrics
```
grpc_server_handled_total - Total gRPC requests by method
grpc_server_handling_seconds_bucket - gRPC latency histogram
grpc_server_started_total - gRPC requests started
```

#### Database Metrics
```
pg_stat_activity_count - PostgreSQL active connections
pg_stat_database_tup_inserted - Rows inserted
pg_stat_database_tup_updated - Rows updated
pg_stat_database_tup_deleted - Rows deleted
```

#### Kafka Metrics
```
kafka_server_brokertopicmetrics_bytesin_total - Bytes into Kafka
kafka_server_brokertopicmetrics_messagesin_total - Messages into Kafka
kafka_consumergroup_lag - Consumer group lag
kafka_server_replicamanager_underreplicatedpartitions - Under-replicated partitions
```

#### Go Runtime Metrics
```
go_goroutines - Active goroutines
go_memstats_alloc_bytes - Memory allocated
go_gc_duration_seconds - GC pause duration
```

---

## Configuration

### Datasource

All dashboards use the **Prometheus** datasource configured at:
- **URL:** http://prometheus:9090
- **Type:** Prometheus
- **Access:** Proxy

Configuration file: `grafana/provisioning/datasources/prometheus.yml`

### Auto-Refresh

Default settings:
- **Refresh Interval:** 10 seconds (optimal for demos)
- **Time Range:** Last 1 hour (adjustable)

### Thresholds

Color-coded thresholds used across dashboards:

**Error Rates:**
- 🟢 Green: <1% (healthy)
- 🟡 Yellow: 1-5% (warning)
- 🔴 Red: >5% (critical)

**Latency:**
- 🟢 Green: <10ms (excellent)
- 🟡 Yellow: 10-50ms (acceptable)
- 🔴 Red: >50ms (needs attention)

**Service Status:**
- 🟢 1 = Service UP
- 🔴 0 = Service DOWN

---

## Customization

### Adding Custom Panels

1. Navigate to desired dashboard in Grafana UI
2. Click "Add Panel"
3. Configure metric query from Prometheus
4. Save dashboard (updates are allowed via `allowUiUpdates: true`)

### Modifying Queries

All dashboards use PromQL queries. Example patterns:

**Request Rate:**
```promql
rate(http_requests_total{job="inventory-api"}[5m])
```

**Latency Percentiles:**
```promql
histogram_quantile(0.95,
  rate(http_request_duration_seconds_bucket{job="inventory-api"}[5m])
)
```

**Error Rate:**
```promql
sum(rate(http_requests_total{job="inventory-api",code=~"5.."}[5m])) /
sum(rate(http_requests_total{job="inventory-api"}[5m])) * 100
```

### Adding Variables

For multi-environment support, add template variables:

1. Dashboard Settings → Variables
2. Add variable (e.g., `$environment`)
3. Use in queries: `{job="inventory-api",env="$environment"}`

---

## Troubleshooting

### Dashboards Not Showing

**Check:**
1. Grafana container is running: `docker ps | grep grafana`
2. Dashboards directory mounted: Check docker-compose volumes
3. Provisioning config correct: `grafana/provisioning/dashboards/dashboards.yml`
4. Restart Grafana: `docker-compose restart grafana`

### No Data in Panels

**Check:**
1. Prometheus is scraping targets: http://localhost:9091/targets
2. Services are exposing metrics (check `/metrics` endpoint)
3. Metric names match queries (Prometheus may use different naming)
4. Time range is appropriate (try "Last 5 minutes")

### Permission Denied

**Fix:**
1. Login with default credentials: admin/admin
2. Change password on first login
3. Check `GF_SECURITY_*` environment variables in docker-compose

---

## Best Practices

### For Demos

1. **Pre-Demo:**
   - Open dashboards 5 minutes before demo
   - Verify all panels showing data
   - Generate some test traffic (run verification script)

2. **During Demo:**
   - Start with APIs Overview for context
   - Focus on Relations API for authorization demo
   - Show real-time updates (10s refresh)
   - Highlight sub-10ms latency

3. **Demo Script Integration:**
   - Open APIs Overview in separate browser tab
   - Reference metrics while running demo scenarios
   - Show impact of relationship creation/deletion in real-time

### For Operations

1. **Set Up Alerts:**
   - Configure alert rules in Grafana for critical metrics
   - Alert on: error rate >5%, latency >50ms, consumer lag >1000

2. **Regular Reviews:**
   - Weekly dashboard review meetings
   - Track trends, not just current values
   - Document anomalies and resolutions

3. **Capacity Planning:**
   - Monitor trends in request rates
   - Track database connection pool usage
   - Watch memory and CPU trends

---

## Advanced Features

### Linking Dashboards

Dashboards include navigation links:
- APIs Overview → detailed API dashboards
- Relations API → SpiceDB internal metrics
- Inventory API → Database performance

### Annotations

Add annotations for events:
- Deployment times
- Configuration changes
- Incident markers
- Demo recording timestamps

### Sharing

**Export Dashboard:**
- Dashboard Settings → JSON Model → Copy

**Share Link:**
- Share icon → Link → Copy URL

**Snapshot:**
- Share icon → Snapshot → Create

---

## Metrics Sources

### From insights-host-inventory

**Extracted metrics patterns:**
- `inventory_http_request_total` - HTTP request counts
- `inventory_http_request_duration_seconds_bucket` - Latency histograms
- `kafka` metrics for MSK integration
- Pod/container health metrics

**Dashboards analyzed:**
- `grafana-dashboard-insights-inventory-general.configmap.yaml` (4,399 lines)
- `grafana-dashboard-insights-inventory-msk.configmap.yaml` (1,207 lines)

### Adaptations for kessel-stack

- Adapted job labels for local environment
- Added SpiceDB-specific gRPC metrics
- Included Relations API alongside Inventory API
- Simplified for demo environment (removed AWS-specific metrics)

---

## Dashboard Development

### Created Dashboards

All new dashboards created on: **2026-02-16**

**Files:**
1. `kessel-apis-overview.json` - 30 KB
2. `kessel-inventory-api.json` - 36 KB
3. `kessel-relations-api.json` - 46 KB
4. `kessel-data-pipeline.json` - 39 KB

**Total Size:** ~151 KB of new dashboard JSON

### Design Principles

1. **Consistency:** Uniform color schemes, naming conventions, layout
2. **Clarity:** Clear panel titles, descriptions, units
3. **Performance:** Optimized queries, appropriate refresh rates
4. **Demo-Ready:** Visually appealing, easy to understand
5. **Production-Grade:** Based on real production dashboards

---

## Support

### Documentation

- **Learning Paths:** `/Users/akoserwa/kessel/kessel-world/docs/learning-paths/`
- **Demo Scripts:** `/Users/akoserwa/kessel/kessel-world/kessel-stack/DEMO_*.md`
- **Architecture:** `/Users/akoserwa/kessel/kessel-world/kessel-stack/ARCHITECTURE_REVIEW_GUIDE.md`

### Quick Reference

**Grafana Access:** http://localhost:3000 (admin/admin)
**Prometheus:** http://localhost:9091
**Dashboard Directory:** `/Users/akoserwa/kessel/kessel-world/kessel-stack/grafana/dashboards/`

---

## Summary

✅ **7 comprehensive dashboards** covering all Kessel services
✅ **Production-based metrics** from insights-host-inventory
✅ **Demo-optimized** with 10-second refresh and clear visualizations
✅ **Fully integrated** with kessel-stack environment
✅ **Ready for presentations** with logical navigation flow

**Start exploring:** Open http://localhost:3000 and navigate to the "Kessel" folder!

---

*Last updated: 2026-02-16*
*Dashboards auto-load on Grafana startup*
*Source: insights-host-inventory + kessel-specific enhancements*
