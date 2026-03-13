# Port Definitions (Interface Contracts)

Ports define WHAT the system can do. They contain zero infrastructure knowledge. In-memory test adapters and production adapters both implement the same interfaces. This is the canonical reference for all 17 port contracts.

The architecture follows the **Ports & Adapters** (hexagonal) pattern: domain logic depends only on abstract interface contracts (ports). Infrastructure — databases, caches, auth providers, payment gateways — lives exclusively in adapters that implement port interfaces. The composition root wires adapters to ports via dependency injection.

---

## Value Objects

These types are shared across all port definitions. Every value type references an ISO or RFC standard. See **01-domain-core.md** for full definitions.

```
EventEnvelope:
    event_action:     string        — "created" — just the action (SOC: domain/entity come from stream)
    schema_version:   int16         — payload schema version for upcaster dispatch
    payload:          Document      — business data only
    metadata:         Document      — extensible operational baggage
    correlation_id:   UUID?         — UUIDv7 (RFC 9562)
    causation_id:     UUID?         — UUIDv7 (RFC 9562)
    user_id:          UUID?         — UUIDv7 (RFC 9562)

StoredEvent:
    id:               UUID          — UUIDv7 (RFC 9562), time-ordered
    global_position:  int64
    tenant_id:        UUID
    stream_domain:    string        — "commerce" — bounded context (SOC)
    stream_entity:    string        — "product" — aggregate type (SOC)
    stream_id:        UUID          — aggregate instance
    stream_version:   int32
    event_action:     string        — "created" — what happened (SOC)
    event_version:    int16         — schema version for upcaster dispatch
    payload:          Document
    metadata:         Document
    correlation_id:   UUID?
    causation_id:     UUID?
    user_id:          UUID?
    created_at:       Timestamp     — RFC 3339 UTC

Snapshot:
    aggregate_id:     UUID
    version:          int32
    state:            Document
    created_at:       Timestamp

Page<T>:
    items:            List<T>
    next_cursor:      string?
    has_more:         boolean

Relation:
    id:               UUID
    tenant_id:        UUID
    category:         string        — "schema" | "instance"
    domain:           string
    relation_type:    string        — "commerce.contains", "social.follows"
    source_id:        UUID
    source_type:      string
    target_id:        UUID
    target_type:      string
    metadata:         Document
    version:          int32
    created_at:       Timestamp
    updated_at:       Timestamp

Principal:
    sub:              UUID          — user identity
    tenant_id:        UUID          — tenant context from token
    tenant_role:      TenantRole    — coarse-grained role within tenant
    iss:              string        — OIDC issuer URL
    iat:              int64         — issued-at (Unix seconds)
    exp:              int64         — expiration (Unix seconds)

TenantRole (ordered hierarchy):
    Guest    — limited read on public resources
    Viewer   — read-only
    Editor   — read + write on assigned resources
    Manager  — Editor + manage team members
    Admin    — Manager + manage users/roles
    Owner    — Admin + billing, tenant settings, deletion

Decision:
    Allow
    Deny { reason: string }

Resource:
    Aggregate { domain, entity, id }
    ReadModel { domain, entity, id? }
    Domain { name }
    Tenant { id }

Action:
    Read | Write | Delete | ManageMembers | ManageRoles | Export | Custom(string)

DeadLetter:
    id:               UUID
    event_id:         UUID
    global_position:  int64
    handler_name:     string
    error_message:    string
    retry_count:      int32
    status:           string        — "pending" | "retrying" | "exhausted" | "resolved"
    created_at:       Timestamp

ProcessState:
    id:               UUID
    tenant_id:        UUID
    process_type:     string
    state:            string
    data:             Document
    started_at:       Timestamp
    updated_at:       Timestamp
    completed_at:     Timestamp?
```

---

## Port 1: EventStore

Append-only event journal. The single source of truth.

**Invariants:**

- Events are immutable once appended
- Global position is monotonic and gapless
- Optimistic concurrency via expected_version check
- One writer wins per (aggregate_id, version) pair

```
interface EventStore:
    // Atomically append events to an aggregate stream.
    // Returns new aggregate version after append.
    // Fails with ConcurrencyConflict if current version != expected_version.
    // SOC: domain and entity are separate parameters, not combined.
    append(tenant_id, stream_id, stream_domain, stream_entity,
           expected_version, events: List<EventEnvelope>) → int32

    // Load all events for an aggregate, ordered by version.
    load_stream(tenant_id, stream_id) → List<StoredEvent>

    // Load events for an aggregate starting from a specific version.
    load_stream_from(tenant_id, stream_id, from_version) → List<StoredEvent>

    // Poll events after a global position (global catch-up subscription).
    poll_global(after_position, limit) → List<StoredEvent>

    // Poll by bounded context — equality match on stream_domain.
    poll_by_domain(domain, after_position, limit) → List<StoredEvent>

    // Poll by entity type within a domain.
    poll_by_entity(domain, entity, after_position, limit) → List<StoredEvent>

    // Poll by specific event action across all entities.
    poll_by_action(action, after_position, limit) → List<StoredEvent>
```

---

## Port 2: SnapshotStore

Caches aggregate state to avoid full event replay.

```
interface SnapshotStore:
    load(aggregate_id) → Snapshot?
    save(aggregate_id, version, state: Document) → void
```

---

## Port 3: ReadModelStore

Generic document store keyed by (tenant, domain, entity, id). No typed columns — entity structure lives in the document. Adding a new entity type means writing a new projection, not a migration. SOC: domain and entity are separate parameters.

```
interface ReadModelStore:
    upsert(tenant_id, domain, entity, entity_id, data: Document, version) → void
    find_by_id(tenant_id, domain, entity, entity_id) → Document?
    query(tenant_id, domain, entity, filters?, cursor?, limit) → Page<Document>
    query_by_domain(tenant_id, domain, filters?, cursor?, limit) → Page<Document>
    delete(tenant_id, domain, entity, entity_id) → void
```

---

## Port 4: RelationStore

Graph edge table for entity relationships. Supports structural (order→line_items) and instance (user→follows→user). This is a READ MODEL — always rebuildable from events.

```
interface RelationStore:
    upsert(tenant_id, relation: Relation) → void
    delete(tenant_id, source_id, target_id, relation_type) → void
    query_forward(tenant_id, source_id, relation_type, cursor?, limit) → Page<Relation>
    query_reverse(tenant_id, target_id, relation_type, cursor?, limit) → Page<Relation>
    exists(tenant_id, source_id, target_id, relation_type) → boolean
    count(tenant_id, target_id, relation_type) → uint64
```

---

## Port 5: IdentityProvider (Authentication)

**Responsibility**: "Who are you? Prove it."

Validates tokens, resolves user identity. No authorization logic. Abstracts over OIDC providers (Zitadel, Keycloak, Auth0, etc.)

**Adapters**: ZitadelAdapter, KeycloakAdapter, Auth0Adapter, FakeIdentityProvider (tests)

```
interface IdentityProvider:
    // Validate token signature, check expiration/revocation, extract Principal.
    // On failure: reject request (401 Unauthorized).
    verify_token(token: string) → Principal

    // Fetch user profile (display name, email, etc.) from the IdP.
    get_user_info(user_id: UUID) → Document
```

---

## Port 6: AuthorizationPolicy (Authorization)

**Responsibility**: "What are you allowed to do?"

Evaluates permissions given principal + action + resource. Separate from IdentityProvider because authentication != authorization:

- Different lifecycles (token expiry vs permission changes)
- Different caching strategies (long TTL vs short TTL)
- Different external tools (Keycloak vs Cerbos/Cedar/OpenFGA)
- Different failure modes (both deny-by-default)

**Adapters**: CerbosAdapter, CedarAdapter, OpenFGAAdapter, InMemoryPolicy (tests)

**Pattern**: Two-Level Authorization

- Level 1 — Tenant Role (RBAC): coarse-grained, from Principal.tenant_role
- Level 2 — Resource Relationships (ReBAC): fine-grained, owner/editor/viewer
- Combined via PBAC (Policy-Based Access Control)

```
interface AuthorizationPolicy:
    // Check if principal can perform action on resource.
    // Called in application layer (command/query handlers) BEFORE aggregate interaction.
    // Aggregates never call this — they enforce business invariants only.
    check(principal: Principal, action: Action, resource: Resource) → Decision

    // List what actions principal can perform on a resource type.
    // Used by UI to show/hide controls.
    list_permissions(principal: Principal, resource: Resource) → List<Action>
```

---

## Port 7: PaymentGateway

Abstracts over payment processors (Stripe, PayPal, Adyen, etc.)

```
interface PaymentGateway:
    // Returns charge reference ID.
    create_charge(amount_cents, currency, customer_ref, metadata?) → string

    // Full or partial refund. Returns refund reference ID.
    refund(charge_ref, amount_cents?) → string

    // Verify and parse webhook. Returns normalized payment event.
    handle_webhook(payload: bytes, signature: string) → Document
```

---

## Port 8: Cache

Abstracts over Redis, Memcached, in-memory, etc.

```
interface Cache:
    get(key: string) → bytes?
    set(key: string, value: bytes, ttl_seconds?) → void
    invalidate(key: string) → void
```

---

## Port 9: EncryptionKeyStore

Per-subject encryption keys for GDPR crypto-shredding. Destroying a key renders all encrypted PII permanently unreadable.

```
interface EncryptionKeyStore:
    create_key(tenant_id, subject_id) → string
    get_key(subject_id) → bytes?
    destroy_key(subject_id) → void
```

---

## Port 10: DeadLetterStore

Captures poison events for inspection, retry, and resolution.

```
interface DeadLetterStore:
    record_failure(event_id, global_position, handler_name, error_message, error_stack?) → void
    get_pending(handler_name, limit) → List<DeadLetter>
    mark_resolved(dead_letter_id) → void
    retry(dead_letter_id) → void
```

---

## Port 11: ProcessManagerStore

Stateful saga/process manager coordination.

```
interface ProcessManagerStore:
    load(process_id) → ProcessState?
    save(process_id, state: ProcessState, associations?: Map<string, string>) → void
    find_by_association(key: string, value: string) → List<UUID>
    find_timed_out(timeout_seconds) → List<UUID>
```

---

## Port 12: OutboxPublisher

Writes integration events to an outbox table in the SAME transaction as the domain event append. The outbox is the "staging area" for events that need to cross the core boundary.

Integration events are lean public contracts (CloudEvents envelope + payload). They are NOT the same as domain events.

```
interface OutboxPublisher:
    // Write an integration event to the outbox (same DB transaction as event append).
    publish(tenant_id, domain, entity, action, schema_version, payload: Document, correlation_id?) → void
```

---

## Port 13: EventRelay

Background worker that reads from the outbox and publishes to an external message broker (Kafka, NATS, Redis Streams). Polyglot consumers subscribe to the broker, not to the core directly.

**Adapters**: KafkaRelayAdapter, NatsRelayAdapter, RedisStreamsRelayAdapter

**Guarantees:**

- At-least-once delivery (idempotent relay via outbox event ID)
- Ordered per aggregate (partition key = stream_id)
- Resumable on crash (tracks last relayed position)

```
interface EventRelay:
    // Relay pending outbox events to the broker. Returns count relayed.
    relay_pending(limit) → int32

    // Health check — is the broker reachable?
    health() → boolean
```

---

## Port 14: EventNotifier

Best-effort HINT for new events (optional optimization). Abstracts over: Postgres LISTEN/NOTIFY, Redis Pub/Sub, etc. A NoOp implementation is valid — system degrades to polling-only.

```
interface EventNotifier:
    notify(position: int64) → void
    subscribe() → void
```

---

## Port 15: TenantIsolation

Enforces tenant boundary at the infrastructure level. Abstracts over: Postgres RLS, application-level WHERE, schema-per-tenant.

```
interface TenantIsolation:
    set_tenant_context(tenant_id) → void
    clear_tenant_context() → void
```

---

## Port 16: CheckpointStore

Tracks projection worker progress through the event stream.

```
interface CheckpointStore:
    get_position(projection_name: string) → int64
    save_position(projection_name: string, position: int64) → void
```

---

## Port 17: ScriptCompiler

Compiles scripting declarations into evaluable AST. Runs ONLY at definition time (admin writes/updates a rule). The compiled AST is stored in the database and evaluated by the native runtime.

**Adapters**: Production compiler (sandboxed scripting engine), MockCompiler (tests)

**Security constraints:**

- Memory limit per compilation (10 MB)
- Time limit per compilation (100ms)
- No I/O, no network, no filesystem
- Only whitelisted global functions (allow, deny, require, etc.)
- Output validated against AST schema before storage

```
interface ScriptCompiler:
    compile_policy(source: string) → PolicyAst
    compile_projection(source: string) → ProjectionDef
    compile_upcaster(source: string) → List<TransformOp>
    compile_validation(source: string) → List<Constraint>
    compile_filter(source: string) → PredicateAst
```

### Compiled Types (pure domain, no scripting dependency)

```
PolicyAst:
    resource:   string
    version:    int32
    rules:      List<PolicyRule>

PolicyRule:
    condition:    Condition
    then:         RuleOutcome
    else_branch:  RuleOutcome?

Condition:
    Eq { field, value }
    Neq { field, value }
    Gt { field, value }
    Gte { field, value }
    Lt { field, value }
    Lte { field, value }
    In { field, values }
    Contains { field, value }
    And(List<Condition>)
    Or(List<Condition>)
    Not(Condition)

RuleOutcome:
    Allow
    Deny { reason }
    Nested(List<PolicyRule>)

TransformOp:
    SetDefault { field, value }
    Rename { from, to }
    Remove { field }
    Restructure { field, template }
    Copy { from, to }
    Cast { field, to_type }

PredicateAst:
    condition: Condition    — reuses the same Condition type
```

---

## In-Memory (No Port Needed)

| Component        | Description                                                            |
| ---------------- | ---------------------------------------------------------------------- |
| **TypeRegistry** | In-memory map at startup (loaded from config/code). No storage needed. |
| **Translator**   | In-memory i18n bundles loaded from files. No storage needed.           |

```
interface Translator:
    resolve(code: string, locale: string, context?: Document) → string
```

---

## Port-by-Port Infrastructure Mapping

| #   | Port                    | Postgres                                                        | Redis                               | External Required?                   | Verdict              |
| --- | ----------------------- | --------------------------------------------------------------- | ----------------------------------- | ------------------------------------ | -------------------- |
| 1   | **EventStore**          | Stored procedures: atomic append, gapless counter, UNIQUE       | —                                   | No                                   | **Postgres**         |
| 2   | **SnapshotStore**       | Simple table: (aggregate_id, version, state, created_at)        | Optional: cache hot snapshots       | No                                   | **Postgres**         |
| 3   | **ReadModelStore**      | JSONB + GIN indexes. Upsert + query filters via JSONB ops       | Optional: cache query results       | No                                   | **Postgres**         |
| 4   | **RelationStore**       | Two B-tree indexes (forward + reverse). Simple SQL joins        | —                                   | No                                   | **Postgres**         |
| 5   | **IdentityProvider**    | Cannot implement OIDC token validation in Postgres              | —                                   | **Yes** — Zitadel/Keycloak/Auth0     | **External**         |
| 6   | **AuthorizationPolicy** | Permission table + SQL query = policy check                     | Cache decisions (short TTL)         | No                                   | **Postgres + Redis** |
| 7   | **PaymentGateway**      | Cannot call Stripe/PayPal APIs from Postgres                    | —                                   | **Yes** — Stripe/PayPal are external | **External**         |
| 8   | **Cache**               | —                                                               | GET/SET/EXPIRE                      | No                                   | **Redis**            |
| 9   | **EncryptionKeyStore**  | Table: (subject_id, key_material, created_at). destroy = DELETE | —                                   | No                                   | **Postgres**         |
| 10  | **DeadLetterStore**     | Table: (id, event_id, handler_name, error, retry_count, status) | —                                   | No                                   | **Postgres**         |
| 11  | **ProcessManagerStore** | Table: (id, tenant_id, process_type, state, data, timestamps)   | —                                   | No                                   | **Postgres**         |
| 12  | **OutboxPublisher**     | Outbox table, same transaction as event append                  | —                                   | No                                   | **Postgres**         |
| 13  | **EventRelay**          | Poll outbox table → push to Redis Streams                       | Redis Streams as lightweight broker | No                                   | **Postgres + Redis** |
| 14  | **EventNotifier**       | LISTEN/NOTIFY — built-in, zero extra infrastructure             | Alternative: Redis Pub/Sub          | No                                   | **Postgres**         |
| 15  | **TenantIsolation**     | Row-Level Security policies                                     | —                                   | No                                   | **Postgres**         |
| 16  | **CheckpointStore**     | Table: (projection_name PRIMARY KEY, position)                  | —                                   | No                                   | **Postgres**         |
| —   | **TypeRegistry**        | In-memory map at startup. No storage needed.                    | —                                   | No                                   | **In-memory**        |
| —   | **Translator**          | In-memory i18n bundles loaded from files.                       | —                                   | No                                   | **In-memory**        |

### Score: 14/16 ports = **Postgres + Redis only** (87.5%)

The remaining 2 ports (`IdentityProvider`, `PaymentGateway`) are **inherently external** — they connect to third-party services that exist outside your infrastructure. You cannot build Stripe or Zitadel inside Postgres. These are not simplification opportunities; they are irreducible external dependencies.

The `ScriptCompiler` port (port 17) is a library dependency, not an infrastructure service. It adds zero operational overhead.
