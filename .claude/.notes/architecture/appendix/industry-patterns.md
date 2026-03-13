# Industry-Validated Patterns

The abstractions in this architecture are not invented — they are distilled from mature, production-proven frameworks. This appendix documents what works, what leaks, and what to avoid, drawn from six production event sourcing systems.

---

## Pattern 1: The Decider (Jeremie Chassaing, 2021)

The most important abstraction pattern for event-sourced aggregates. Adopted by Oskar Dudycz, Emmett, delta-base, and Jet's Equinox.

**Core definition** (language-agnostic):

```
Decider<Command, Event, State>:
    decide:       (command, state) → events[]       — business rules
    evolve:       (state, event)   → state          — pure state transition
    initialState: ()               → state          — starting point
    isTerminal:   (state)          → boolean        — lifecycle completion
```

**Why this outperforms traditional OOP aggregates:**

| Aspect                  | Traditional Aggregate                       | Decider                                                       |
| ----------------------- | ------------------------------------------- | ------------------------------------------------------------- |
| Side effects            | Methods mutate internal state + emit events | `decide` is pure: returns events, mutates nothing             |
| Testing                 | Requires framework, mocking, setup          | Call functions directly: `decide(cmd, state)` → assert events |
| Composition             | Aggregates don't compose                    | Deciders compose: two deciders merge into one                 |
| Infrastructure coupling | Often mixed with persistence                | Zero I/O — `decide` and `evolve` are pure functions           |
| Error handling          | Exceptions from deep inside methods         | Explicit: returns either events or domain error               |

> **Source**: [Functional Event Sourcing Decider](https://thinkbeforecoding.com/post/2021/12/17/functional-event-sourcing-decider) — Jeremie Chassaing

---

## Pattern 2: Aggregate Interface Design (Production-Validated)

The most mature event sourcing libraries share a common aggregate interface shape:

```
interface Aggregate<Command, Event, Error, Services>:
    TYPE: string                          — aggregate type identifier
    handle(command, services, event_sink) — async, may call ports via services
    apply(event)                          — synchronous, pure state transition
```

Key design decisions validated in production:

- `Services` = dependency injection of ports without coupling to concrete implementations
- `apply()` is synchronous and pure — "No business logic should be placed here."
- `handle()` is async — it may need to call external services via ports
- Default/initial state = aggregates have a natural starting point
- Serializable = snapshots are built-in at the type level

---

## Pattern 3: Upcaster Chain (10+ Years Production)

The most battle-tested upcasting abstraction (Axon Framework pattern):

```
interface Upcaster:
    upcast(stream_of_events) → stream_of_events

// Most common: one-to-one transformation
interface SingleEventUpcaster extends Upcaster:
    can_upcast(event_representation) → boolean
    do_upcast(event_representation) → event_representation

// Advanced: one-to-many transformation (split one event into multiple)
interface EventMultiUpcaster extends Upcaster:
    can_upcast(event_representation) → boolean
    do_upcast(event_representation) → stream_of_events
```

**Critical insight**: Upcasters operate on the raw serialized form (intermediate representation), not on deserialized domain objects. This avoids needing to maintain old event type definitions. The intermediate representation gives upcasters access to metadata (type, revision) without deserializing the payload.

**Chain ordering**: Upcasters compose in sequence. Each upcaster's output feeds the next.

> **Source**: [Axon Framework Event Versioning](https://docs.axoniq.io/axon-framework-reference/4.11/events/event-versioning/)

---

## Pattern 4: Message DB / Eventide (PostgreSQL, Pure SQL)

The reference implementation of an event store as pure Postgres functions:

```sql
write_message(id, stream_name, type, data, metadata, expected_version)
get_stream_messages(stream_name, position, batch_size, condition)
get_category_messages(category, position, batch_size, correlation,
                      consumer_group_member, consumer_group_size, condition)
get_last_stream_message(stream_name, type)
```

**Key validated patterns:**

- **Stream naming convention**: `{category}-{id}` (e.g., `account-abc123`). Category = aggregate type. Enables category-level subscriptions without extra indexes.
- **Consumer groups built into the SQL function** — no external message broker needed.
- **`expected_version`** parameter = optimistic concurrency in one function call.
- **Correlation filtering** built into the query function — pub/sub routing at the query level.

> **Source**: [Message DB Server Functions](http://docs.eventide-project.org/user-guide/message-db/server-functions.html)

---

## Pattern 5: Async Daemon Projections (Production at Scale)

The most sophisticated projection infrastructure (Marten pattern):

**Architecture:**

- Runs as a hosted background service — no external infrastructure beyond Postgres
- **Solo mode**: single-node, auto-start
- **HotCold mode**: multi-node with built-in leader election (one projection per node)
- Tracks a **high water mark** — the furthest safely-processable event sequence
- Each projection maintains its own checkpoint

**Error handling** (three configurable policies):

| Policy                    | Default (continuous) | Default (rebuild) | Purpose                           |
| ------------------------- | -------------------- | ----------------- | --------------------------------- |
| `SkipApplyErrors`         | true                 | false             | Ignore projection code failures   |
| `SkipSerializationErrors` | true                 | false             | Overlook deserialization failures |
| `SkipUnknownEvents`       | true                 | false             | Bypass unrecognized event types   |

**Rebuild capability**: Full re-projection from event store via CLI or API command.

> **Source**: [Marten Async Daemon](https://martendb.io/events/projections/async-daemon.html)

---

## Pattern 6: Catch-Up and Persistent Subscriptions

Two subscription models proven across thousands of deployments (EventStoreDB/Kurrent pattern):

| Model          | State Management           | Delivery                                      | Use Case                                    |
| -------------- | -------------------------- | --------------------------------------------- | ------------------------------------------- |
| **Catch-up**   | Client-managed checkpoints | Exactly-once (if same-transaction checkpoint) | Read model projections                      |
| **Persistent** | Server-managed state       | At-least-once with ACK/NACK                   | Competing consumers, distributed processing |

**Best practice**: Store checkpoint in the same transaction as the projection write. This achieves exactly-once semantics without an inbox pattern.

**Persistent subscription strategies**: `RoundRobin` (load balance), `DispatchToSingle` (HA failover), `Pinned` (category-based ordering).

> **Source**: [Kurrent Subscriptions](https://docs.kurrent.io/clients/tcp/dotnet/21.2/subscriptions)

---

## Production Lessons Learned (What Went Wrong)

Compiled from production post-mortems and practitioner blog posts.

### 1. Don't expose internal events as integration events

Raw event subscriptions between services create coupling worse than shared databases. Every internal refactor breaks downstream consumers.
**Mitigation**: `OutboxPublisher` + Anti-Corruption Layer pattern.

### 2. Keep streams short — design for bounded lifecycles

Streams that grow indefinitely cause replay performance degradation.
**Mitigation**: Design aggregates with natural lifecycle boundaries. Use "close the books" pattern.

### 3. Materialization lag causes UX problems

After writes, clients query the read model and get stale data.
**Mitigation**: Return `{aggregate_id, version}` from writes. Client polls until caught up.

### 4. Projection maintenance scales linearly with event types

Each new event type requires updating N projections.
**Mitigation**: Domain-scoped projection workers. Each worker owns one domain.

### 5. Build a replay debugging tool on day one

The most valuable production tool: replay an aggregate's stream to inspect intermediate state.
**Mitigation**: The Decider pattern makes this trivial: `events.fold(initial_state, evolve)`.

### 6. Don't snapshot prematurely

Snapshots add write amplification and versioning complexity. Most streams have < 100 events.
**Mitigation**: Measure first.

> **Sources**: [Event Sourcing is Hard](https://chriskiehl.com/article/event-sourcing-is-hard), [Should You Always Keep Streams Short?](https://event-driven.io/en/should_you_always_keep_streams_short/), [Things I Wish I Knew](https://softwaremill.com/things-i-wish-i-knew-when-i-started-with-event-sourcing-part-1/), [Snapshots in Event Sourcing](https://www.kurrent.io/blog/snapshots-in-event-sourcing)
