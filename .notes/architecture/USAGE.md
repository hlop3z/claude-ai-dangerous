# What Can You Build With This Architecture?

This is an **event-sourced CQRS platform** with hexagonal architecture. It provides the structural foundation — port interfaces, domain types, layer boundaries, and architecture docs — so you can focus on business logic instead of plumbing.

## Ideal For

### Multi-Tenant SaaS Platforms

Any B2B product where customers (tenants) must be strictly isolated. Tenant boundaries are enforced at every layer — from domain events to database row-level security. Examples:

- Project management tools (like Linear, Jira)
- CRM systems
- Invoicing / billing platforms
- Learning management systems

### Event-Sourced Domain Systems

Systems where **history matters** and you need a complete audit trail. Events are append-only and immutable — the source of truth. Examples:

- Order management / e-commerce backends
- Insurance claim processing
- Healthcare record systems
- Financial transaction ledgers
- Supply chain tracking

### Systems With Complex Authorization

Two-layer auth (RBAC + ReBAC) is built into the architecture. Deny-by-default, token-lookup pattern, no embedded permissions. Examples:

- Platforms with role hierarchies (Guest → Owner)
- Resource-level access control (can user X edit document Y?)
- Compliance-heavy domains (HIPAA, SOX, GDPR)

### GDPR-Compliant Applications

Crypto-shredding via `EncryptionKeyStore` lets you delete a user's data by destroying their encryption key — without rewriting the event log. No event mutation needed.

### Platforms With User-Defined Business Rules

The embedded scripting layer lets end-users define:

- Authorization policies (compiled to AST, evaluated natively — no scripting engine at runtime)
- Validation rules
- Event filters
- Custom projections
- Schema upcasters

All sandboxed: memory limits, time limits, zero I/O access.

### Polyglot Architectures

The core handles the event store, commands, and aggregates, but projection workers and analytics can be written in **any technology** via:

- Redis Streams (simplest — any language with a Redis client)
- gRPC subscription API (low-latency streaming)
- Message brokers like Kafka or NATS (high-throughput fan-out)

## Concrete Product Examples

| Product Type                | Key Features Used                                                                       |
| --------------------------- | --------------------------------------------------------------------------------------- |
| **E-commerce platform**     | Order aggregates, payment saga (process manager), inventory projections, Stripe adapter |
| **Project management tool** | Task/board aggregates, team RBAC, real-time projections, tenant isolation               |
| **Fintech ledger**          | Double-entry aggregates, immutable audit trail, crypto-shredding, compliance events     |
| **Healthcare records**      | Patient aggregates, HIPAA audit logging, encryption-at-rest, role-based access          |
| **Marketplace**             | Seller/buyer aggregates, escrow process manager, dispute workflows, multi-tenant        |
| **IoT command platform**    | Device aggregates, command sourcing, event-driven projections, polyglot workers         |
| **Workflow automation**     | Process managers as workflow engines, user-defined rules via scripting, event routing   |
| **Content management**      | Content aggregates, versioned publishing, approval workflows, tenant-scoped access      |

## What The Architecture Provides

**You get (ready to use):**

- 17 port interfaces covering persistence, auth, events, caching, scripting, and tenant isolation
- Domain types: StoredEvent, EventEnvelope, Principal, Decision, Money, compiled AST types
- Value objects compliant with UUIDv7, RFC 3339, ISO 4217, ISO 3166-1
- Decider pattern for aggregates (pure functional state machines)
- Schema evolution via upcaster pipelines — no migration hell
- Dead letter store, process managers, projection checkpoints
- Compile-time layer enforcement via build system dependency rules
- 14 of 16 ports implementable with just **Postgres + Redis**

**You implement:**

- Your domain aggregates and business rules
- Command and query handlers
- Port interface implementations (adapters for Postgres, Redis, OIDC, Stripe)
- Projections for your read models
- HTTP or gRPC transport layer
- Server composition (wiring adapters to ports)

## Not A Good Fit For

- **Simple CRUD apps** — the event sourcing overhead isn't worth it if you don't need history, audit trails, or temporal queries.
- **Read-heavy, write-light systems** — CQRS adds complexity; if your reads and writes look the same, a simpler architecture is better.
- **Prototypes or MVPs** — unless you already know you need event sourcing, start simpler and migrate later.
- **Single-user tools** — multi-tenancy and authorization layers are unnecessary overhead.

## Infrastructure Requirements

| Component           | Purpose                                                                                                                                         |
| ------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| **Postgres**        | Event store, read models, relations, snapshots, authorization, dead letters, process managers, outbox, checkpoints, encryption keys, tenant RLS |
| **Redis**           | Cache, event relay (Streams), event notifications (Pub/Sub)                                                                                     |
| **OIDC Provider**   | Authentication (Zitadel, Keycloak, or Auth0)                                                                                                    |
| **Payment Gateway** | Optional (Stripe, PayPal, Adyen)                                                                                                                |

That's it. Two databases, one identity provider, and optionally a payment gateway.
