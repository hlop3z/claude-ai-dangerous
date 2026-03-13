# Project: Event-Sourced CQRS Platform

Hexagonal architecture with strict layer boundaries. The build system enforces dependency direction at compile time.

## Workspace Layout

```
layers/
  domain/       → Pure logic. Value objects, port interfaces, aggregates, errors. ZERO I/O.
  application/  → Command/query handlers, projections, process managers. Depends on: domain.
  adapters/     → ALL I/O. Postgres, Redis, OIDC, Stripe. Implements domain port interfaces. Depends on: domain.
  scripting/    → Sandboxed ScriptCompiler. Isolated compilation sandbox. Depends on: domain.
  server/       → Composition root. Wires adapters to ports via dependency injection. Depends on: ALL layers.
```

## Layer Rules (CRITICAL — never violate)

| Layer         | Can depend on                            | Cannot depend on                         | Why                                                |
| ------------- | ---------------------------------------- | ---------------------------------------- | -------------------------------------------------- |
| `domain`      | nothing (only stdlib + serialization)    | application, adapters, scripting, server | Pure core — zero I/O                               |
| `application` | domain                                   | adapters, scripting, server              | Orchestrates via port interfaces, not concrete I/O |
| `adapters`    | domain                                   | application, scripting, server           | Implements ports, doesn't orchestrate              |
| `scripting`   | domain                                   | application, adapters, server            | Implements ScriptCompiler port only                |
| `server`      | domain, application, adapters, scripting | —                                        | Composition root wires everything                  |

## Key Patterns

- **Port interfaces** are defined in `domain/ports/`. Adapters implement them.
- **Authorization** is checked in `application/` (command handlers), never in domain aggregates.
- **Domain events** are the source of truth. Append-only, immutable.
- **SOC columns**: `stream_domain`, `stream_entity`, `event_action` — never a composite string.
- **All timestamps UTC** (RFC 3339). All IDs UUIDv7 (RFC 9562). Money in integer cents (ISO 4217).
- **Deny-by-default** for authorization at every layer.

## Before Adding a Dependency

1. Ask: "Does this dependency do I/O?" → If yes, it goes in `adapters/` or `scripting/`, never `domain/` or `application/`.
2. Ask: "Is this already covered by stdlib?" → Prefer stdlib over external dependencies.
3. Ask: "Does this break the dependency direction?" → Check the table above.

## Architecture Docs

Full specifications are in `.claude/.notes/architecture/` (00 through 10 + appendix). Legacy (language-specific) versions are in `.claude/.notes/architecture/.legacy/`.
