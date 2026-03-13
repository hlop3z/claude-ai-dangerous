---
paths:
  - "crates/domain/**/*.rs"
  - "crates/domain/Cargo.toml"
---

# Domain Core Layer Rules

You are editing the INNERMOST layer. This code must be pure — zero I/O, zero infrastructure.

## Allowed

- Type definitions, value objects, newtypes
- Port trait definitions (`#[async_trait] pub trait ...`)
- Domain error types
- Pure functions (validation, business rules, state machines)
- `serde`, `uuid`, `chrono`, `thiserror`, `async-trait` (data + trait crates only)

## Forbidden

- ANY I/O crate (sqlx, reqwest, redis, tokio runtime, hyper, axum, tonic)
- ANY `use adapters::`, `use application::`, `use scripting::`, `use server::`
- File system, network, database, or HTTP operations
- `std::fs`, `std::net`, `std::process`
- Concrete adapter types — only trait definitions belong here

## Port Trait Pattern

```rust
#[async_trait]
pub trait PortName: Send + Sync {
    async fn method(&self, ...) -> Result<T>;
}
```

Port traits go in `domain/src/ports/`. They define WHAT, never HOW.
