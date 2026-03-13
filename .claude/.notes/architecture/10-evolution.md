# Evolution

## Implementation Order

```
Phase 1: Domain Core (zero dependencies)
=======================================
1. Value objects: TenantId, AggregateId, EventId, Version, Money, etc.
2. Port interfaces: EventStore, ReadModelStore, RelationStore, etc.
3. Event types: namespaced type validation
4. Aggregate base: decide/evolve pattern + state machine enforcement
5. Upcaster framework: pure function pipeline
6. Error code registry: i18n-ready error catalog

Phase 2: In-Memory Adapters + Tests
=======================================
7. InMemoryEventStore + compliance tests
8. InMemoryReadModelStore + compliance tests
9. InMemoryRelationStore + compliance tests
10. Fake adapters for auth, payments, cache
11. First aggregate implementation with Given/When/Then tests

Phase 3: Production Adapters
=======================================
12. PgEventStore (stored procedures, gapless counter, concurrency)
13. PgReadModelStore (JSONB, GIN indexes)
14. PgRelationStore (forward/reverse indexes)
15. PgTenantIsolation via RLS
16. PgCheckpointStore
17. PgAuthorizationPolicy (SQL permission table + Redis cache)
18. Run compliance tests against Postgres adapters

Phase 4: Application Layer
=======================================
19. Command handlers with authorization pipeline
20. Query handlers with caching
21. Projection workers (domain-scoped polling)
22. PgEventNotifier (LISTEN/NOTIFY adapter)
23. RedisStreamsRelay (outbox → Redis Streams → workers)
24. ScriptCompiler: sandboxed engine (script → AST → native eval)

Phase 5: External Integrations
=======================================
25. IdentityProvider adapter (Zitadel OIDC)
26. PaymentGateway adapter (Stripe)
27. HTTP/gRPC transport adapters

Phase 6: Polyglot Worker Infrastructure
=======================================
28. CloudEvents envelope serialization (JSON)
29. Redis Streams consumer examples (any technology)
30. AsyncAPI event documentation
31. Protobuf event contracts (.proto files + Buf schema registry) — when earned

Phase 7: Production Hardening
=======================================
32. Process managers + saga coordination
33. Dead letter queue + retry with backoff (internal + per-consumer DLQs)
34. GDPR: EncryptionKeyStore + crypto-shredding
35. Integration events: ACL translators
36. Observability: OpenTelemetry traces, projection lag metrics, consumer group lag alerting
37. Table partitioning (when scale demands it)
```

---

## Evolution Path: Earning Complexity

### Phase 1 — Day 1

Infrastructure: Postgres + Redis + Zitadel + Stripe.

**Authorization**:

- ACS numeric model per entity (role >= action, O(1))
- PgAuthorizationPolicy (SQL permission table + Redis cache)
- Version-stamped permission snapshots with tiered consistency
- Deny-by-default at every layer
- Authorization audit logging
- Permission changes as domain events

**Event System**:

- PgEventNotifier (LISTEN/NOTIFY)
- RedisStreamsRelay (outbox → Redis Streams → workers)
- JSON + CloudEvents (no Protobuf yet)

**Embedded Scripting**:

- Sandboxed engine for tenant policy compilation (script → AST → native eval)
- Exhaustive AST validation (depth, size, scope, whitelist, signing)
- Reject unknown fields on all AST types
- Full sandboxing (memory 10MB, time 100ms, stack 1MB, no I/O)

### Phase 2 — When Earned

**Authorization** (when permission graphs exceed 3 levels):

- Cerbos/OpenFGA for deep relationship traversal
- Per-entity action bitmask overrides (non-linear permissions within single entity)

**Event System** (when > 100K events/sec sustained):

- Kafka/NATS replacing Redis Streams
- gRPC streaming for workers needing direct event store access
- Protobuf + Buf when > 5 consumer teams need schema enforcement

**Embedded Scripting**:

- Process isolation for scripting engine (syscall filter, separate process)
- Closure compilation for system policies (no serialization overhead)
- Complexity scoring for tenant ASTs (reject expensive policies)

### Phase 3 — When Required

**Authorization** (when formal verification or deep graphs are mandated):

- SpiceDB/Zanzibar for deep relationship graphs (Google Drive-style: 5+ levels of transitive access)
- Cedar for formal policy verification (compliance, regulated industry)
- Sub-millisecond auth at 10K+ checks/sec (dedicated PDP service)

**Event System** (when multi-datacenter or strict schema governance):

- Multi-datacenter replication (Kafka MirrorMaker)
- Schema Registry for backward compatibility CI enforcement

---

## Key Decisions

| Decision                    | Choice                               | Why                                             | Alternative Considered                          |
| --------------------------- | ------------------------------------ | ----------------------------------------------- | ----------------------------------------------- |
| **Auth model**              | ACS numeric + AST policies           | O(1) fast path, tenant-customizable             | Cedar (adds dependency), bitmask (64-bit limit) |
| **PDP deployment**          | Embedded library                     | Zero network overhead, simplest infra           | Sidecar (Cerbos), service (SpiceDB)             |
| **Tenant rules format**     | Script → JSON AST                    | Familiar syntax, serializable, auditable        | Cedar DSL (unfamiliar), Rego (error-prone)      |
| **Cache strategy**          | Version-stamped + tiered consistency | Balances performance and consistency            | Pure TTL (TOCTOU risk), strong-only (too slow)  |
| **AST security**            | Exhaustive validation + HMAC signing | Defense-in-depth against tampering              | Trust-the-compiler (insufficient)               |
| **Permission events**       | First-class domain events            | Audit trail, rebuild, react                     | Silent mutations (no trail)                     |
| **Deny default**            | Explicit at every layer              | OWASP #1, no implicit allows                    | Implicit deny (easy to miss)                    |
| **Infrastructure baseline** | Postgres + Redis                     | 14/16 ports covered, minimal ops                | Kafka + Cerbos + external services (premature)  |
| **Polyglot messaging**      | Redis Streams (Day 1)                | Already deployed for Cache, zero new infra      | Kafka (high ops), NATS (another service)        |
| **Serialization format**    | JSON + CloudEvents (Day 1)           | Universal, no codegen needed                    | Protobuf (overhead without 5+ consumer teams)   |
| **Event notification**      | Postgres LISTEN/NOTIFY               | Zero new infrastructure, hint-only optimization | Redis Pub/Sub (viable alternative)              |
| **Authorization storage**   | Postgres table + Redis cache         | Uses existing infra, SQL-queryable permissions  | External PDP service (unnecessary at start)     |

---

## Risks and Mitigations

| Risk                                              | Mitigation                                                                                                                       |
| ------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------- |
| Event store becomes write bottleneck              | Partition by tenant_id. Connection pooling. At extreme scale, shard by domain.                                                   |
| Projection lag causes stale reads                 | Return version in write response. Client polls until projection catches up.                                                      |
| Upcaster chain grows long for ancient events      | Periodic snapshot creation. Optional background copy-and-transform.                                                              |
| Document query performance degrades               | Adapter uses appropriate indexes. Keep read model payloads flat.                                                                 |
| Adapter lock-in via port leakage                  | Port compliance tests catch any adapter-specific assumptions leaking into domain code.                                           |
| Schema_version mismatch between writer/reader     | Upcasters are pure functions tested independently. Version is explicit on every event.                                           |
| Over-abstraction makes debugging harder           | Keep adapter implementations straightforward. Structured logging with correlation_id traces full flow.                           |
| Polyglot schema drift across technologies         | Schema Registry enforces backward compatibility. Breaking changes blocked at CI. Proto contracts are the single source of truth. |
| External worker falls behind (consumer lag)       | Monitor consumer group lag via broker metrics. Alert when lag exceeds threshold. Scale consumer instances horizontally.          |
| Message broker becomes SPOF for external workers  | Outbox table buffers events if broker is down. Relay resumes on recovery. gRPC path is independent.                              |
| Serialization mismatch (version skew)             | `dataschema` field in CloudEvents envelope points to exact schema version. Consumer fetches correct deserializer.                |
| gRPC subscription overwhelms core                 | gRPC flow control (HTTP/2 backpressure). Rate limiting per consumer. Prefer broker path for high-volume consumers.               |
| Scripting engine CVE exposure                     | Pin latest patched version. Dependency scanning in CI. Memory/CPU/stack limits enforced at runtime.                              |
| AST tampering in storage                          | HMAC-SHA256 signature on AST at compile time, verified before evaluation. Reject unknown fields.                                 |
| Cross-tenant policy escalation                    | AST field references validated against tenant's plan scope. Database RLS on all permission tables.                               |
| Permission cache TOCTOU window                    | Version-stamped snapshots. Tiered consistency: Strong for sensitive ops, Eventual for reads, AtLeastAsFresh after writes.        |
| Numeric role model can't express non-linear perms | Scoped per entity (covers 95%). Tenant policies (AST) handle the remaining 5%. Bitmask override in Phase 2 if needed.            |
| Undetected access violations                      | All auth decisions logged. Alert on patterns: repeated denials, admin-action denials, cross-system access.                       |
