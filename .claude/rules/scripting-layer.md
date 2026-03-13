---
paths:
  - "crates/scripting/**/*.rs"
  - "crates/scripting/Cargo.toml"
---

# Scripting Layer Rules

You are editing the isolated ScriptCompiler adapter. This crate wraps rquickjs (C FFI) to compile JS declarations into evaluable JSON AST.

## Allowed

- `use domain::` (for ScriptCompiler trait and AST types)
- `rquickjs` crate (the ONLY external dependency beyond domain)
- Sandbox enforcement: memory 10MB, time 100ms, stack 1MB, no I/O in JS context

## Forbidden

- ANY `use application::`, `use adapters::`, `use server::`
- Exposing rquickjs types outside this crate — only domain AST types cross the boundary
- Running user JS at evaluation time — compilation only, pure Rust evaluates the AST
- Allowing JS access to: filesystem, network, timers, globals beyond the whitelist

## Security Constraints

- `#[serde(deny_unknown_fields)]` on all AST types
- HMAC-SHA256 signature on compiled AST
- Output validated against AST JSON Schema before storage
- Only whitelisted global functions: allow, deny, require, field, etc.
