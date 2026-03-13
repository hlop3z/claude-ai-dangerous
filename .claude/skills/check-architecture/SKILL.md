---
name: check-architecture
description: Audit workspace for layer violations, dependency direction, and architectural rule compliance. Use when you want to verify the codebase respects hexagonal boundaries.
allowed-tools: Read, Grep, Glob, Bash(cargo tree:*)
---

# Architecture Audit

Perform a comprehensive audit of the Rust workspace for architectural violations.

## Step 1: Dependency Direction

Check each crate's Cargo.toml for forbidden dependencies:

| Crate         | Allowed deps                                                 | Forbidden deps                                                             |
| ------------- | ------------------------------------------------------------ | -------------------------------------------------------------------------- |
| `domain`      | serde, uuid, chrono, thiserror, async-trait                  | sqlx, reqwest, redis, axum, tonic, tokio, application, adapters, scripting |
| `application` | domain, serde, uuid, chrono, thiserror, async-trait, tracing | sqlx, reqwest, redis, axum, tonic, adapters, scripting                     |
| `adapters`    | domain, sqlx, redis, reqwest, tokio, tracing                 | application, scripting                                                     |
| `scripting`   | domain, rquickjs, serde, tracing                             | application, adapters                                                      |
| `server`      | ALL                                                          | — (composition root)                                                       |

Run `cargo tree -p <crate> --depth 1` for each crate to verify.

## Step 2: Import Analysis

Search for cross-layer imports that violate boundaries:

```
# Domain must not import anything outside itself
grep -r "use application::\|use adapters::\|use scripting::\|use server::" crates/domain/

# Application must not import adapters/scripting/server
grep -r "use adapters::\|use scripting::\|use server::" crates/application/

# Adapters must not import application/scripting/server
grep -r "use application::\|use scripting::\|use server::" crates/adapters/

# Scripting must not import application/adapters/server
grep -r "use application::\|use adapters::\|use server::" crates/scripting/
```

## Step 3: Port Trait Location

Verify all `#[async_trait] pub trait` definitions for ports live in `crates/domain/src/ports/`.

## Step 4: Authorization Placement

Verify `AuthorizationPolicy::check()` calls happen only in `crates/application/`, never in `crates/domain/`.

## Step 5: I/O in Domain

Search for any I/O operations in the domain crate:

- `std::fs`, `std::net`, `std::process`
- `tokio::fs`, `tokio::net`
- Any `async fn` that does network/file I/O

## Output

Report all violations found with file paths and line numbers. If clean, confirm "Architecture audit passed — all layers respect boundaries."
