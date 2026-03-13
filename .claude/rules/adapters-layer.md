---
paths:
  - "crates/adapters/**/*.rs"
  - "crates/adapters/Cargo.toml"
---

# Adapters Layer Rules

You are editing the I/O boundary. ALL infrastructure access lives here. Adapters implement domain port traits.

## Allowed

- `use domain::` (for port traits and types to implement)
- Infrastructure crates: sqlx, deadpool-redis, reqwest, etc.
- Concrete implementations: `PgEventStore`, `RedisCache`, `ZitadelProvider`, etc.
- In-memory test adapters that implement port traits

## Forbidden

- ANY `use application::`, `use scripting::`, `use server::`
- Business logic or orchestration — adapters only translate between domain and infrastructure
- Domain decisions — adapters just read/write, they don't decide

## Pattern: Adapter Implementation

```rust
pub struct PgEventStore { pool: PgPool }

#[async_trait]
impl EventStore for PgEventStore {
    async fn append(&self, ...) -> Result<i32> {
        // SQL here — infrastructure concern
    }
}
```

## Test Adapter Pattern

```rust
pub struct InMemoryEventStore { events: RwLock<Vec<StoredEvent>> }

#[async_trait]
impl EventStore for InMemoryEventStore {
    // Same trait, in-memory implementation for tests
}
```
