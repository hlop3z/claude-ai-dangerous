---
paths:
  - "crates/server/**/*.rs"
  - "crates/server/Cargo.toml"
---

# Composition Root Rules

You are editing the wiring layer. This is the ONLY place that knows about all crates and concrete types.

## Allowed

- `use domain::`, `use application::`, `use adapters::`, `use scripting::`
- Creating concrete adapters: `PgEventStore::new(pool)`, `RedisCache::new(redis)`, etc.
- Wrapping in trait objects: `Arc::new(PgEventStore::new(pool)) as Arc<dyn EventStore>`
- HTTP/gRPC transport (axum, tonic), config loading, tracing setup
- Passing trait objects into application layer handlers

## Forbidden

- Business logic — this crate only wires, never decides
- Domain types beyond what's needed for routing/config
- Direct SQL or infrastructure calls outside of adapter construction

## Pattern: Composition

```rust
let event_store: Arc<dyn EventStore> = Arc::new(PgEventStore::new(pg.clone()));
let authz: Arc<dyn AuthorizationPolicy> = Arc::new(PgAuthorizationPolicy::new(pg.clone()));
// Pass to application handlers...
```
