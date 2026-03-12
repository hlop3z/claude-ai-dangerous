# Can Postgres + Redis Cover 99% of the Ports?

> **TL;DR**: Yes. 14 of 16 ports are fully covered by Postgres + Redis. The only ports that _require_ external services are `IdentityProvider` (OIDC is a protocol, not something you build) and `PaymentGateway` (Stripe/PayPal are external by definition). Everything else — including authorization, message relay, encryption key storage, event notification, and polyglot worker subscriptions — can run on Postgres + Redis alone.

---

## Port-by-Port Analysis

| #   | Port                    | Postgres                                                                                                                    | Redis                                                       | External Required?                   | Verdict              |
| --- | ----------------------- | --------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------- | ------------------------------------ | -------------------- |
| 1   | **EventStore**          | `sqlx` + PL/pgSQL: atomic append, gapless counter, UNIQUE constraint, SOC columns                                           | —                                                           | No                                   | **Postgres**         |
| 2   | **SnapshotStore**       | Simple table: `(aggregate_id, version, state JSONB, created_at)`                                                            | Optional: cache hot snapshots                               | No                                   | **Postgres**         |
| 3   | **ReadModelStore**      | JSONB + GIN indexes. `upsert` = `INSERT ON CONFLICT UPDATE`. Query filters via `jsonb_path_ops`.                            | Optional: cache query results                               | No                                   | **Postgres**         |
| 4   | **RelationStore**       | Two B-tree indexes (forward + reverse). Simple SQL joins.                                                                   | —                                                           | No                                   | **Postgres**         |
| 5   | **IdentityProvider**    | ❌ Cannot implement OIDC token validation in Postgres                                                                       | ❌                                                          | **Yes** — Zitadel/Keycloak/Auth0     | **External**         |
| 6   | **AuthorizationPolicy** | ✅ Pg table: `(tenant_id, user_id, resource_type, resource_id, action)`. SQL query = policy check.                          | Cache decisions (short TTL)                                 | No                                   | **Postgres + Redis** |
| 7   | **PaymentGateway**      | ❌ Cannot call Stripe/PayPal APIs from Postgres                                                                             | ❌                                                          | **Yes** — Stripe/PayPal are external | **External**         |
| 8   | **Cache**               | —                                                                                                                           | ✅ `GET`/`SET`/`EXPIRE`. Redis is literally built for this. | No                                   | **Redis**            |
| 9   | **EncryptionKeyStore**  | ✅ Pg table: `(subject_id, key_material BYTEA, created_at)`. `destroy_key` = `DELETE`.                                      | —                                                           | No                                   | **Postgres**         |
| 10  | **DeadLetterStore**     | ✅ Pg table: `(id, event_id, handler_name, error, retry_count, status)`                                                     | —                                                           | No                                   | **Postgres**         |
| 11  | **ProcessManagerStore** | ✅ Pg table: `(id, tenant_id, process_type, state, data JSONB, timestamps)`                                                 | —                                                           | No                                   | **Postgres**         |
| 12  | **OutboxPublisher**     | ✅ Pg table: `(id, tenant_id, domain, entity, action, payload, published_at)`. Written in same transaction as event append. | —                                                           | No                                   | **Postgres**         |
| 13  | **EventRelay**          | ✅ Pg-based relay: poll outbox table → push to Redis Streams (or Pg LISTEN/NOTIFY for simple cases)                         | ✅ Redis Streams as lightweight broker                      | No                                   | **Postgres + Redis** |
| 14  | **EventNotifier**       | ✅ `LISTEN/NOTIFY` — built-in, zero extra infrastructure                                                                    | Alternative: Redis Pub/Sub                                  | No                                   | **Postgres**         |
| 15  | **TenantIsolation**     | ✅ Row-Level Security: `SET app.tenant_id = $1` + RLS policies                                                              | —                                                           | No                                   | **Postgres**         |
| 16  | **CheckpointStore**     | ✅ Pg table: `(projection_name TEXT PRIMARY KEY, position BIGINT)`                                                          | —                                                           | No                                   | **Postgres**         |
| —   | **TypeRegistry**        | In-memory `HashMap` at startup (loaded from config/code). No storage needed.                                                | —                                                           | No                                   | **In-memory**        |
| —   | **Translator**          | In-memory i18n bundles loaded from files.                                                                                   | —                                                           | No                                   | **In-memory**        |

### Score: 14/16 ports = **Postgres + Redis only** (87.5%)

The remaining 2 ports (`IdentityProvider`, `PaymentGateway`) are **inherently external** — they connect to third-party services that exist outside your infrastructure. You can't build Stripe or Zitadel inside Postgres. These aren't simplification opportunities; they're irreducible external dependencies.

---

## The Hard Question: Do You Need Kafka/NATS?

**Short answer: No. Not at the start. Probably not for a long time.**

The architecture document defines two polyglot consumption paths: gRPC streaming and message broker (Kafka/NATS). But for 99% of cases, **Redis Streams** replaces both Kafka and NATS with dramatically less operational complexity.

### Redis Streams as the "Good Enough" Broker

| Capability            | Kafka                                       | NATS JetStream            | Redis Streams                                  |
| --------------------- | ------------------------------------------- | ------------------------- | ---------------------------------------------- |
| Consumer groups       | ✅                                          | ✅                        | ✅ (`XREADGROUP`)                              |
| Persistent messages   | ✅                                          | ✅                        | ✅ (`MAXLEN` for retention)                    |
| Ordering guarantees   | Per-partition                               | Per-subject               | Per-stream                                     |
| Competing consumers   | ✅                                          | ✅                        | ✅ (`XACK` + consumer groups)                  |
| Dead letter / pending | Manual                                      | Manual                    | ✅ Built-in (`XPENDING`, `XCLAIM`)             |
| Ops complexity        | High (ZooKeeper/KRaft, brokers, partitions) | Medium (JetStream config) | **Already running** (you have Redis for cache) |
| Throughput ceiling    | 1M+ msg/sec                                 | 100K+ msg/sec             | 100K+ msg/sec                                  |
| Polyglot clients      | All languages                               | All languages             | All languages                                  |

**When you already have Redis for the Cache port**, adding Redis Streams for event relay costs **zero new infrastructure**. The `EventRelay` adapter polls the Postgres outbox table and writes to Redis Streams. Polyglot workers consume via `XREADGROUP`.

### When to Actually Add Kafka

Only when you hit **all three** of these simultaneously:

1. **> 100K events/second sustained** (not burst — Redis Streams handles bursts fine)
2. **Multi-datacenter replication** required (Kafka MirrorMaker)
3. **Weeks of retention** needed (Redis Streams are in-memory; Kafka is on-disk)

Until then, Redis Streams is strictly simpler and already deployed.

---

## The Hard Question: Do You Need Cerbos/Cedar/OpenFGA?

**Short answer: No. Start with a Postgres authorization table.**

The architecture document defines an `AuthorizationPolicy` port with adapters for Cerbos, Cedar, OpenFGA, and SpiceDB. These are powerful but add external services, new protocols, and operational burden.

### Postgres-Native Authorization

```sql
-- One table covers RBAC + basic ReBAC
CREATE TABLE permissions (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id UUID NOT NULL,
    principal_id UUID NOT NULL,          -- user or team
    principal_type TEXT NOT NULL,         -- 'user' | 'team'
    resource_type TEXT NOT NULL,          -- 'domain' | 'entity' | 'aggregate'
    resource_id UUID,                    -- NULL = wildcard (all of that type)
    resource_domain TEXT,                -- 'commerce', 'billing', etc.
    resource_entity TEXT,                -- 'product', 'order', etc.
    action TEXT NOT NULL,                -- 'read' | 'write' | 'delete' | 'manage_members'
    granted_by UUID NOT NULL,
    granted_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at TIMESTAMPTZ,             -- NULL = permanent
    UNIQUE(tenant_id, principal_id, principal_type, resource_type, resource_id, action)
);

-- RLS: tenant isolation applies here too
ALTER TABLE permissions ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON permissions
    USING (tenant_id = current_setting('app.tenant_id')::UUID);

-- Index for the hot path: "can user X do action Y on resource Z?"
CREATE INDEX idx_perm_check ON permissions
    (tenant_id, principal_id, action, resource_type, resource_domain);
```

```rust
// Postgres adapter for AuthorizationPolicy
pub struct PgAuthorizationPolicy { pool: PgPool }

#[async_trait]
impl AuthorizationPolicy for PgAuthorizationPolicy {
    async fn check(
        &self, principal: &Principal, action: &Action, resource: &Resource,
    ) -> Result<Decision> {
        // 1. Check TenantRole hierarchy first (fast path)
        if principal.tenant_role >= required_role_for(action) {
            return Ok(Decision::Allow);
        }

        // 2. Check resource-level permissions (ReBAC)
        let exists: bool = sqlx::query_scalar(
            "SELECT EXISTS(
                SELECT 1 FROM permissions
                WHERE tenant_id = $1
                  AND principal_id = $2
                  AND action = $3
                  AND (resource_id = $4 OR resource_id IS NULL)
                  AND (resource_domain = $5 OR resource_domain IS NULL)
                  AND (expires_at IS NULL OR expires_at > now())
            )"
        )
        .bind(principal.tenant_id)
        .bind(principal.sub)
        .bind(action.as_str())
        .bind(resource.id())
        .bind(resource.domain())
        .fetch_one(&self.pool).await?;

        // 3. Cache the result in Redis (short TTL)
        Ok(if exists { Decision::Allow } else {
            Decision::Deny { reason: "insufficient permissions".into() }
        })
    }
}
```

### When to Actually Add Cerbos/OpenFGA

Only when:

1. **Deep relationship graphs** (Google Drive-style: user → team → folder → subfolder → document, 5+ levels of transitive access)
2. **Policy-as-code** requirement (auditors want to review authorization rules in YAML/Cedar, not SQL)
3. **Sub-millisecond authorization** at scale (10K+ checks/sec where Postgres round-trip becomes bottleneck)

For a typical multi-tenant SaaS with 6 tenant roles and resource-level ownership? **The Postgres table + Redis cache is more than enough.**

---

## The Hard Question: Do You Need gRPC for Polyglot Workers?

**Short answer: Start with Redis Streams. Add gRPC when you need direct event store access.**

The gRPC Event Subscription API is elegant but adds:

- Proto compilation pipeline
- tonic server in the Rust core
- Client codegen for every worker language

**Redis Streams gives you polyglot for free** — every language has a Redis client. Workers `XREADGROUP` from streams, `XACK` after processing. The Outbox Relay writes events to Redis Streams with CloudEvents JSON envelope (no Protobuf required initially).

### Simplified Polyglot Path (Phase 1)

```
Rust Core → Outbox Table (Postgres) → Relay Worker → Redis Streams
                                                          │
                                            ┌─────────────┼─────────────┐
                                          Python        Node.js         Go
                                          worker        worker        worker
                                       (XREADGROUP)  (XREADGROUP)  (XREADGROUP)
```

**Serialization: JSON with CloudEvents envelope.** No Protobuf. No Schema Registry. Just `serde_json` on the Rust side, `json.loads()` on the Python side. Add Protobuf + Schema Registry when you need schema enforcement across 5+ consumer teams.

### When to Add gRPC Streaming

1. Workers need **exactly-once** semantics (gRPC checkpoint in same DB transaction)
2. Workers need **real-time** latency (< 50ms from event append to worker processing)
3. Workers need to **query the event store** directly (load specific streams, not just receive broadcasts)

---

## Recommended Simplification

### What to Keep from the Architecture Document

Everything. The **port traits don't change**. The abstractions are correct. What changes is which **adapter** you wire at the composition root.

### Minimal Composition Root (Postgres + Redis Only)

```rust
#[tokio::main]
async fn main() {
    let config = Config::from_env();
    let pg = PgPool::connect(&config.database_url).await.unwrap();
    let redis = RedisPool::new(&config.redis_url);

    // 14 ports, 2 technologies
    let event_store: Arc<dyn EventStore> = Arc::new(PgEventStore::new(pg.clone()));
    let snapshot_store: Arc<dyn SnapshotStore> = Arc::new(PgSnapshotStore::new(pg.clone()));
    let read_model: Arc<dyn ReadModelStore> = Arc::new(PgReadModelStore::new(pg.clone()));
    let relations: Arc<dyn RelationStore> = Arc::new(PgRelationStore::new(pg.clone()));
    let authz: Arc<dyn AuthorizationPolicy> = Arc::new(PgAuthorizationPolicy::new(pg.clone()));
    let cache: Arc<dyn Cache> = Arc::new(RedisAdapter::new(redis.clone()));
    let encryption: Arc<dyn EncryptionKeyStore> = Arc::new(PgEncryptionKeyStore::new(pg.clone()));
    let dead_letters: Arc<dyn DeadLetterStore> = Arc::new(PgDeadLetterStore::new(pg.clone()));
    let process_mgr: Arc<dyn ProcessManagerStore> = Arc::new(PgProcessManagerStore::new(pg.clone()));
    let outbox: Arc<dyn OutboxPublisher> = Arc::new(PgOutboxPublisher::new(pg.clone()));
    let relay: Arc<dyn EventRelay> = Arc::new(RedisStreamsRelay::new(pg.clone(), redis.clone()));
    let notifier: Arc<dyn EventNotifier> = Arc::new(PgEventNotifier::new(pg.clone()));
    let tenant: Arc<dyn TenantIsolation> = Arc::new(PgTenantIsolation::new(pg.clone()));
    let checkpoints: Arc<dyn CheckpointStore> = Arc::new(PgCheckpointStore::new(pg.clone()));

    // 2 external (irreducible)
    let identity: Arc<dyn IdentityProvider> = Arc::new(ZitadelAdapter::new(&config.oidc));
    let payments: Arc<dyn PaymentGateway> = Arc::new(StripeAdapter::new(&config.stripe));

    // Wire and run
    let command_bus = CommandBus::new(event_store.clone(), identity.clone(), authz.clone());
    let query_bus = QueryBus::new(read_model.clone(), cache.clone(), authz.clone());
    // ...
}
```

**Infrastructure footprint: 2 services (Postgres, Redis) + 2 external APIs (Zitadel, Stripe).**

### Evolution Path (When Complexity is Earned)

```
Start here (Day 1)
══════════════════════════════════════════════════════
Postgres + Redis + Zitadel + Stripe
- PgAuthorizationPolicy (SQL permission table)
- PgEventNotifier (LISTEN/NOTIFY)
- RedisStreamsRelay (outbox → Redis Streams → workers)
- JSON + CloudEvents (no Protobuf yet)

When you need it (earned complexity)
══════════════════════════════════════════════════════
+ Cerbos/OpenFGA     → when permission graphs exceed 3 levels
+ Kafka/NATS         → when > 100K events/sec sustained
+ gRPC streaming     → when workers need direct event store access
+ Protobuf + Buf     → when > 5 consumer teams need schema enforcement
+ Schema Registry    → when backward compatibility must be CI-enforced
```

---

## What This Means for the Architecture Document

**Nothing changes architecturally.** The port traits are the same. The hexagonal boundary is the same. The only difference is which adapters you implement first.

The architecture document is the **target state** — it shows all the adapters you _could_ build. This document says: **start with the Postgres + Redis adapters for everything, and only add complexity when the system demands it.**

The ports protect you: swapping `PgAuthorizationPolicy` for `CerbosAdapter` later is a one-line change at the composition root. That's the entire point of hexagonal architecture.
