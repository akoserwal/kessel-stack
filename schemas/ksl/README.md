# KSL Schema Sources

This directory contains the [KSL (Kessel Schema Language)](https://github.com/project-kessel/ksl-schema-language) source files that compile to `services/spicedb/schema/schema.zed`.

These files are the **canonical source of truth** for the SpiceDB RBAC schema. Edit them here — do not hand-edit `schema.zed` directly.

## Files

| File | Namespace | Purpose |
|------|-----------|---------|
| `kessel.ksl` | `kessel` | Internal lock/versioning types used by relations-api |
| `rbac.ksl` | `rbac` | Core RBAC types: principal, group, role, role_binding, workspace + extension macros |
| `hbi.ksl` | `hbi` | Host-based inventory resource type (host) with view/update/delete/move permissions |
| `edge.ksl` | `edge` | Example extension: edge device resource type (hello-world service) |

## How KSL Maps to SpiceDB

KSL compiles each `type` block into a SpiceDB `definition`. The `namespace` prefix becomes the type prefix:

```
# KSL
namespace hbi
public type host { ... }

# Compiled SpiceDB (schema.zed)
definition hbi/host { ... }
```

The `extension` macro in `rbac.ksl` is the key pattern. When `hbi.ksl` calls:
```
@rbac.add_v1_based_permission(app:'inventory', resource:'hosts', verb:'read', v2_perm:'inventory_host_view')
```
…the compiler expands it into permission relations on `rbac/role`, `rbac/role_binding`, `rbac/workspace`, and `hbi/host`.

## Compile

Install the KSL compiler (requires Go 1.22+):
```bash
go install github.com/project-kessel/ksl-schema-language/cmd/ksl@latest
```

Compile all sources to `schema.zed`:
```bash
./scripts/compile-schema.sh
```

Or compile manually:
```bash
ksl schemas/ksl/kessel.ksl schemas/ksl/rbac.ksl schemas/ksl/hbi.ksl schemas/ksl/edge.ksl \
    -o services/spicedb/schema/schema.zed
```

## Adding a New Resource Type

1. Create a new `.ksl` file in this directory, e.g. `myservice.ksl`:

```ksl
version 0.1
namespace myservice

import rbac

public type widget {
    private relation workspace: [ExactlyOne rbac.workspace]

    @rbac.add_v1_based_permission(app:'myservice', resource:'widgets', verb:'read', v2_perm:'myservice_widget_view')
    relation view: workspace.myservice_widget_view

    @rbac.add_v1_based_permission(app:'myservice', resource:'widgets', verb:'write', v2_perm:'myservice_widget_edit')
    relation edit: workspace.myservice_widget_edit
}
```

2. Add `schemas/ksl/myservice.ksl` to the compile command in `scripts/compile-schema.sh`.

3. Run `./scripts/compile-schema.sh` to regenerate `schema.zed`.

4. Reload the schema into a running SpiceDB:
   ```bash
   ./scripts/manage-schema.sh compile-and-load
   ```

## Permissions Pattern

Every leaf permission follows the V1→V2 mapping convention via `@rbac.add_v1_based_permission`:

| V1 RBAC permission | V2 SpiceDB permission |
|--------------------|-----------------------|
| `inventory:hosts:read` | `inventory_host_view` |
| `inventory:hosts:write` | `inventory_host_update`, `inventory_host_delete` |
| `edge:devices:read` | `edge_device_view` |
| `edge:devices:write` | `edge_device_update`, `edge_device_delete` |
| `edge:devices:*` | `edge_device_manage` |

The extension macro propagates each permission up through: `role → role_binding → platform → tenant → workspace → resource`.
