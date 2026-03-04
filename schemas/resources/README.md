# Resource Type Schemas

This directory contains JSON Schema validation configs for resource types registered with `kessel-inventory-api`.

At startup (with `use_cache: false`), inventory-api reads this directory and registers each resource type it finds. Resources submitted to the API are validated against these schemas before being stored.

## Directory Structure

```
schemas/resources/
└── <resource_type>/
    ├── config.yaml                    # resource_type name + list of reporters
    ├── common_representation.json     # JSON Schema for fields shared across all reporters
    └── reporters/
        └── <reporter_name>/
            ├── config.yaml            # reporter_name + namespace
            └── <resource_type>.json   # JSON Schema for reporter-specific fields
```

## Included Resource Types

### `host` (reporter: `hbi`)

The standard HBI (Host-Based Inventory) host resource. Represents a system managed by Red Hat Insights.

- **Common fields**: `workspace_id` (required)
- **HBI-specific fields**: `satellite_id`, `subscription_manager_id`, `insights_id`, `ansible_host`

### `edge_device` (reporter: `edge`)

Example extension demonstrating the hello-world edge service resource type.

- **Common fields**: `workspace_id` (required), `org_id` (required)
- **Edge-specific fields**: `display_name`

## Adding a New Resource Type

1. Create the directory structure:
   ```
   schemas/resources/my_resource/
   ├── config.yaml
   ├── common_representation.json
   └── reporters/my_reporter/
       ├── config.yaml
       └── my_resource.json
   ```

2. Define `config.yaml`:
   ```yaml
   resource_type: my_resource
   resource_reporters:
     - my_reporter
   ```

3. Define `common_representation.json` with fields shared by all reporters:
   ```json
   {
     "$schema": "http://json-schema.org/draft-07/schema#",
     "type": "object",
     "properties": {
       "workspace_id": { "type": "string" }
     },
     "required": ["workspace_id"]
   }
   ```

4. Define `reporters/my_reporter/config.yaml`:
   ```yaml
   resource_type: my_resource
   reporter_name: my_reporter
   namespace: my_namespace
   ```

5. Define `reporters/my_reporter/my_resource.json` with reporter-specific fields:
   ```json
   {
     "$schema": "http://json-schema.org/draft-07/schema#",
     "type": "object",
     "properties": {
       "my_field": { "type": "string" }
     },
     "required": []
   }
   ```

6. Restart `kessel-inventory-api` (or rebuild the stack) — no precompile step is needed when `use_cache: false`.

## Configuration

The inventory-api config at `services/kessel-inventory-api/.inventory-api.yaml` points to this directory:

```yaml
resources:
  schemaPath: /schemas/resources
  use_cache: false
```

The Docker Compose volume mount in `compose/docker-compose.kessel.yml` makes this directory available inside the container:

```yaml
volumes:
  - ../schemas/resources:/schemas/resources:ro
```
