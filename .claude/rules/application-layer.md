---
paths:
  - "crates/application/**/*.rs"
  - "crates/application/Cargo.toml"
---

# Application Layer Rules

You are editing the orchestration layer. Command handlers, query handlers, projections, and process managers live here.

## Allowed

- `use domain::` (port traits, types, errors)
- Injected port trait objects: `Arc<dyn EventStore>`, `Arc<dyn AuthorizationPolicy>`, etc.
- Authorization checks (call `AuthorizationPolicy::check()` BEFORE aggregate interaction)
- Projection workers that read events and update read models
- Process managers that coordinate multi-aggregate workflows

## Forbidden

- ANY `use adapters::`, `use scripting::`, `use server::`
- Direct database calls, HTTP requests, file I/O
- ANY I/O crate in Cargo.toml (sqlx, reqwest, redis, etc.)
- Concrete adapter types — only use trait objects

## Pattern: Command Handler

```rust
pub async fn handle_command(
    event_store: &dyn EventStore,
    authz: &dyn AuthorizationPolicy,
    principal: &Principal,
    command: Command,
) -> Result<()> {
    // 1. Authorize
    // 2. Load aggregate from events
    // 3. Execute domain logic (decide)
    // 4. Append new events
}
```
