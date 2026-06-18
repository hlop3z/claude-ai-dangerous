# Infrastructure

## Philosophy: Simple > Complex

14 of 16 ports are fully covered by Postgres + Redis. The only ports that _require_ external services are `IdentityProvider` (OIDC is a protocol, not something you build) and `PaymentGateway` (Stripe/PayPal are external by definition). These aren't simplification opportunities; they're irreducible external dependencies.

**What this means for the architecture**: Nothing changes architecturally. The port interfaces are the same. The hexagonal boundary is the same. The only difference is which adapters you implement first.

The ports protect you: swapping one adapter for another later is a one-line change at the composition root. That's the entire point of hexagonal architecture.

---

## Port-by-Port Adapter Mapping

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
| 9   | **EncryptionKeyStore**  | Table: (subject_id, key_material BYTEA, created_at). DELETE     | —                                   | No                                   | **Postgres**         |
| 10  | **DeadLetterStore**     | Table: (id, event_id, handler_name, error, retry_count, status) | —                                   | No                                   | **Postgres**         |
| 11  | **ProcessManagerStore** | Table: (id, tenant_id, process_type, state, data, timestamps)   | —                                   | No                                   | **Postgres**         |
| 12  | **OutboxPublisher**     | Outbox table, same transaction as event append                  | —                                   | No                                   | **Postgres**         |
| 13  | **EventRelay**          | Poll outbox table → push to Redis Streams                       | Redis Streams as lightweight broker | No                                   | **Postgres + Redis** |
| 14  | **EventNotifier**       | LISTEN/NOTIFY — built-in, zero extra infrastructure             | Alternative: Redis Pub/Sub          | No                                   | **Postgres**         |
| 15  | **TenantIsolation**     | Row-Level Security policies                                     | —                                   | No                                   | **Postgres**         |
| 16  | **CheckpointStore**     | Table: (projection_name PRIMARY KEY, position)                  | —                                   | No                                   | **Postgres**         |
| —   | **TypeRegistry**        | In-memory map at startup. No storage needed.                    | —                                   | No                                   | **In-memory**        |
| —   | **Translator**          | In-memory i18n bundles loaded from files.                       | —                                   | No                                   | **In-memory**        |

### Score: 14/16 ports = Postgres + Redis only (87.5%)

---

## Composition Root

The composition root wires concrete adapters to abstract port interfaces via dependency injection. This is the only place in the codebase that knows about concrete adapter types.

```
// Pseudocode — composition root (server entry point)
main():
    config = load_from_environment()
    pg = connect_postgres(config.database_url)
    redis = connect_redis(config.redis_url)

    // 14 ports, 2 technologies
    event_store       = PgEventStore(pg)            implements EventStore
    snapshot_store    = PgSnapshotStore(pg)          implements SnapshotStore
    read_model        = PgReadModelStore(pg)         implements ReadModelStore
    relations         = PgRelationStore(pg)          implements RelationStore
    authz             = PgAuthorizationPolicy(pg)    implements AuthorizationPolicy
    cache             = RedisAdapter(redis)          implements Cache
    encryption        = PgEncryptionKeyStore(pg)     implements EncryptionKeyStore
    dead_letters      = PgDeadLetterStore(pg)        implements DeadLetterStore
    process_mgr       = PgProcessManagerStore(pg)    implements ProcessManagerStore
    outbox            = PgOutboxPublisher(pg)         implements OutboxPublisher
    relay             = RedisStreamsRelay(pg, redis)  implements EventRelay
    notifier          = PgEventNotifier(pg)          implements EventNotifier
    tenant            = PgTenantIsolation(pg)        implements TenantIsolation
    checkpoints       = PgCheckpointStore(pg)        implements CheckpointStore

    // 2 external (irreducible)
    identity          = ZitadelAdapter(config.oidc)  implements IdentityProvider
    payments          = StripeAdapter(config.stripe)  implements PaymentGateway

    // Wire and run
    command_bus = CommandBus(event_store, identity, authz)
    query_bus   = QueryBus(read_model, cache, authz)
```

**Infrastructure footprint: 2 services (Postgres, Redis) + 2 external APIs (Zitadel, Stripe).**

---

## Storage Abstraction Mapping

| Storage-Specific Feature                  | Abstract Port Capability                          | What the Adapter Hides                      |
| ----------------------------------------- | ------------------------------------------------- | ------------------------------------------- |
| Stored procedure for atomic append        | `EventStore.append()`                             | Atomic append with gapless position counter |
| Unique constraint on (aggregate, version) | `EventStore.append()` returns ConcurrencyConflict | How concurrency is enforced                 |
| JSONB column + GIN inverted index         | `ReadModelStore.query(filters)`                   | How document queries are indexed            |
| Row-Level Security policies               | `TenantIsolation.set_tenant_context()`            | How tenant data is isolated                 |
| LISTEN/NOTIFY trigger                     | `EventNotifier.notify()` / `.subscribe()`         | How event availability is signaled          |
| Monotonic position counter                | `EventStore.append()` returns position            | How monotonic ordering is achieved          |
| Table partitioning (hash/range)           | Transparent to port consumers                     | How data is physically organized            |

---

## Postgres Authorization Adapter

```sql
-- One table covers RBAC + basic ReBAC
CREATE TABLE permissions (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id UUID NOT NULL,
    principal_id UUID NOT NULL,
    principal_type TEXT NOT NULL,         -- 'user' | 'team'
    resource_type TEXT NOT NULL,          -- 'domain' | 'entity' | 'aggregate'
    resource_id UUID,                    -- NULL = wildcard
    resource_domain TEXT,
    resource_entity TEXT,
    action TEXT NOT NULL,
    granted_by UUID NOT NULL,
    granted_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at TIMESTAMPTZ,
    UNIQUE(tenant_id, principal_id, principal_type, resource_type, resource_id, action)
);

-- RLS: tenant isolation
ALTER TABLE permissions ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON permissions
    USING (tenant_id = current_setting('app.tenant_id')::UUID);

-- Index for the hot path
CREATE INDEX idx_perm_check ON permissions
    (tenant_id, principal_id, action, resource_type, resource_domain);
```

---

## Adapter Capability Matrix

| Port                    | Postgres Adapter                                     | DynamoDB Adapter (future)                       | In-Memory Adapter (tests)                     |
| ----------------------- | ---------------------------------------------------- | ----------------------------------------------- | --------------------------------------------- |
| **EventStore**          | Stored procedure, gapless counter, UNIQUE constraint | Conditional writes on version, DynamoDB Streams | HashMap, simple version check                 |
| **ReadModelStore**      | JSONB + GIN indexes, equality on SOC columns         | Single-table design, GSI for type queries       | Nested HashMap, linear scan for filters       |
| **IdentityProvider**    | N/A (external: Zitadel, Keycloak via OIDC)           | N/A (same external OIDC providers)              | FakeIdentityProvider returns preset Principal |
| **AuthorizationPolicy** | SQL permission table + Redis cache                   | N/A (same external engines)                     | InMemoryPolicy with configurable RBAC rules   |
| **TenantIsolation**     | RLS policies                                         | Partition key = tenant_id, implicit isolation   | tenant_id filter in every method              |
| **EventNotifier**       | LISTEN/NOTIFY trigger on events table                | DynamoDB Streams + Lambda trigger               | In-process signal                             |
| **Cache**               | N/A                                                  | DAX                                             | HashMap with TTL                              |

Key point: The domain and application layers are identical regardless of which adapter column you choose. Switching from Postgres to DynamoDB means writing new adapters — zero domain code changes.
