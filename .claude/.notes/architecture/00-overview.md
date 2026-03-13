# Architecture Overview

This document is the entry point for the system architecture. It defines the problem, the principles, and the map of all architectural decisions documented in this directory.

---

## Problem Statement

Traditional relational schemas couple business logic to table structure. Every new entity type, every field change, every relationship modification requires DDL migrations. At scale with multi-tenancy, this becomes:

- **Migration hell**: N tenants x M schema changes = operational risk
- **Rigid entity models**: adding a field requires deployment
- **Coupled code**: application code mirrors storage columns, changes cascade everywhere
- **Lost history**: mutable updates overwrite previous state permanently
- **Vendor lock-in**: architecture is welded to specific databases and services

## What We Want Instead

Entities defined by **data + versioning**, not by typed columns. Business logic evolves without storage migrations. Full history via event sourcing. **Zero infrastructure dependencies in domain code** — every external system is accessed through an abstract port interface.

---

## Core Principles

1. **Simple > Complex** — start with the least powerful tool that works.
2. **Postgres + Redis first** — they cover 14 of 16 ports. No Kafka, no Elasticsearch, no DynamoDB until measured need.
3. **Complexity when earned** — add infrastructure only when a concrete bottleneck or requirement demands it.

---

## Multi-System Map

The platform manages 7 subsystems. Each is a `stream_domain` in the event store; each entity is a `stream_entity`.

```
┌────────┬────────┬────────┬────────┬────────┬────────┬────────┐
│  SYS   │  PIM   │  DAM   │  CMS   │  CRM   │  ERP   │  POS   │
│ ────── │ ────── │ ────── │ ────── │ ────── │ ────── │ ────── │
│ auth   │product │ media  │  gui   │contact │ order  │  shop  │
│session │catalog │ asset  │  view  │  lead  │invoice │        │
│        │        │        │  page  │        │        │        │
└────────┴────────┴────────┴────────┴────────┴────────┴────────┘
```

Maps directly to the namespaced type system: `pim.product.created`, `erp.order.placed`, `cms.page.published`.

---

## Architecture at a Glance

**Hexagonal** (ports and adapters) + **CQRS** (separate write/read paths) + **Event Sourcing** (append-only event log as source of truth).

- **Domain Core**: pure logic, zero I/O. Aggregates, value objects, domain events, port interfaces.
- **Application Layer**: command handlers, query handlers, projection workers, process managers.
- **Adapter Layer**: all I/O. Postgres, Redis, OIDC providers, payment gateways, message brokers.
- **Composition Root**: wires concrete adapters to abstract port interfaces via dependency injection.

---

## Layer Rules

| Layer         | Can depend on                            | Cannot depend on                         | Why                                                |
| ------------- | ---------------------------------------- | ---------------------------------------- | -------------------------------------------------- |
| `domain`      | nothing (only stdlib + serialization)    | application, adapters, scripting, server | Pure core — zero I/O                               |
| `application` | domain                                   | adapters, scripting, server              | Orchestrates via port interfaces, not concrete I/O |
| `adapters`    | domain                                   | application, scripting, server           | Implements ports, doesn't orchestrate              |
| `scripting`   | domain                                   | application, adapters, server            | Implements ScriptCompiler port only                |
| `server`      | domain, application, adapters, scripting | —                                        | Composition root wires everything                  |

These dependency rules should be enforced at the build system level — compile-time or module-boundary enforcement, not convention.

---

## Document Map

| File                     | Title                 | What It Covers                                                                            |
| ------------------------ | --------------------- | ----------------------------------------------------------------------------------------- |
| **00-overview.md**       | Architecture Overview | Problem, principles, system map, document index (this file)                               |
| **01-domain-core.md**    | Domain Core           | Entities, value objects, ISO/RFC compliance, namespaced types, SOC storage design         |
| **02-ports.md**          | Ports and Adapters    | All 17 port interface definitions, adapter registry, capability matrix                    |
| **03-event-sourcing.md** | Event Sourcing        | Aggregate design, Decider pattern, schema evolution, upcasters, EventStore interface      |
| **04-cqrs-flows.md**     | CQRS and Projections  | Write path, read path, projection pipeline, projection types                              |
| **04a-query-dsl.md**     | Query DSL             | JSON filter grammar, security model, type coercion                                        |
| **05-authorization.md**  | Access Control        | AuthN vs AuthZ separation, PBAC model, token lookup pattern, ACS numeric model            |
| **06-scripting.md**      | Embedded Scripting    | Compile-then-evaluate pattern, sandboxed execution, security model                        |
| **07-polyglot.md**       | Polyglot Workers      | Redis Streams, gRPC subscription API, message broker relay, CloudEvents, schema registry  |
| **08-infrastructure.md** | Infrastructure        | Port-by-port adapter mapping, composition root, adapter examples                          |
| **09-production.md**     | Production Readiness  | GDPR crypto-shredding, dead letters, process managers, testing, deployment, failure model |
| **10-evolution.md**      | Evolution             | Implementation phases, key decisions, risks and mitigations                               |
| **appendix/**            | Reference             | Industry patterns, research sources                                                       |

---

## Philosophy

Postgres + Redis covers 14/16 ports. Start simple, earn complexity. Every adapter is swappable. Every port is testable with an in-memory stub. The domain core compiles with zero dependencies on any infrastructure.
