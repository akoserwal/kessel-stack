# Kessel Integration Onboarding

This directory is the starting point for teams integrating a new service with Kessel — Red Hat's
relationship-based access control (ReBAC) platform built on SpiceDB.

## What's here

| Path | What it covers |
|------|---------------|
| [`01-integration-decision-guide.md`](01-integration-decision-guide.md) | Which integration pattern to use and why |
| [`02-outbox-template/`](02-outbox-template/) | Copy-paste templates: outbox DDL, Debezium connector, rbac-config permissions and roles |
| [`hello-world-service/`](hello-world-service/) | Complete runnable Go service (`edge-device-service`) that demonstrates the full CDC outbox pipeline end-to-end |

## Quick orientation: What is Kessel?

Kessel sits between your application and SpiceDB. It provides two APIs:

```
Your App
  │
  ├─→ kessel-relations-api  (pure SpiceDB proxy: CreateTuples, CheckPermission, LookupResources)
  │
  └─→ kessel-inventory-api  (resource management: ReportResource, DeleteResource, + auth proxy)
```

SpiceDB stores **relationship tuples** — facts like:
- `rbac/workspace:eng-team#member@rbac/principal:alice`
- `edge/device:router-42#t_workspace@rbac/workspace:eng-team`

A `CheckPermission` call evaluates whether a principal can perform an action on a resource
by traversing those tuples according to the schema.

## Decision flowchart

```
Does your service manage resources (hosts, devices, clusters, reports...)?
  YES → use the Kafka CDC Outbox pattern   → see 02-outbox-template/ and hello-world-service/
  NO  → is it workspace/role/group management?
          YES → use Direct gRPC replication   → see 01-integration-decision-guide.md §Direct gRPC
```

## How to run the stack before trying hello-world-service

```bash
# From the project root
bash scripts/deploy.sh

# Or for a minimal stack (SpiceDB + Relations API only, no Kafka):
bash scripts/deploy.sh --minimal
```

Then follow [`hello-world-service/README.md`](hello-world-service/README.md) step by step.
