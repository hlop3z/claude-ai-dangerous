# Polyglot Worker Architecture

> The core owns the event store, command handling, and domain logic. **Workers** — projection builders, process managers, analytics pipelines, notification dispatchers — can be written in **any technology**.

---

## Design Principle: Core + Polyglot Edge

```
┌──────────────────────────────────────────────────────────────┐
│                       CORE (event-core)                       │
│  EventStore · Aggregates · Command Handlers · Outbox Relay    │
└──────────────┬──────────────────────────┬────────────────────┘
               │                          │
        ┌──────▼───────┐          ┌───────▼────────┐
        │ gRPC Event   │          │ Message Broker  │
        │ Subscription │          │ (Kafka / NATS)  │
        │ API (Proto)  │          │ via Outbox Relay│
        └──────┬───────┘          └───────┬────────┘
               │                          │
    ┌──────────┼──────────┐    ┌──────────┼──────────┐
    │          │          │    │          │          │
  Worker    Worker    Worker Worker    Worker    Worker
  (any)     (any)     (any) (any)     (any)     (any)
```

Workers consume events through three paths, presented in order of increasing complexity:

| Path                            | Protocol                       | Best For                                      | Checkpoint                                | Ordering                 |
| ------------------------------- | ------------------------------ | --------------------------------------------- | ----------------------------------------- | ------------------------ |
| **Redis Streams** (Phase 1)     | Redis protocol                 | Simple polyglot, already deployed             | Consumer groups (XACK)                    | Per-stream guaranteed    |
| **gRPC Subscription API** (Ph2) | gRPC server streaming (HTTP/2) | Low-latency, direct event store access        | Client-managed (CheckpointStore via gRPC) | Per-stream guaranteed    |
| **Message Broker** (Phase 3)    | Kafka/NATS protocol            | High-throughput, competing consumers, fan-out | Server-managed (consumer groups)          | Per-partition guaranteed |

---

## Simplified Path: Redis Streams (Phase 1)

Start here. Redis is already deployed for the Cache port — adding Streams costs **zero new infrastructure**.

```
Core → Outbox Table (Postgres) → Relay Worker → Redis Streams
                                                      │
                                        ┌─────────────┼─────────────┐
                                      Worker        Worker         Worker
                                      (any)         (any)          (any)
                                   (XREADGROUP)  (XREADGROUP)  (XREADGROUP)
```

### Redis Streams vs Kafka vs NATS

| Capability            | Kafka                                       | NATS JetStream            | Redis Streams                                  |
| --------------------- | ------------------------------------------- | ------------------------- | ---------------------------------------------- |
| Consumer groups       | Yes                                         | Yes                       | Yes (`XREADGROUP`)                             |
| Persistent messages   | Yes                                         | Yes                       | Yes (`MAXLEN` for retention)                   |
| Ordering guarantees   | Per-partition                               | Per-subject               | Per-stream                                     |
| Competing consumers   | Yes                                         | Yes                       | Yes (`XACK` + consumer groups)                 |
| Dead letter / pending | Manual                                      | Manual                    | Built-in (`XPENDING`, `XCLAIM`)                |
| Ops complexity        | High (ZooKeeper/KRaft, brokers, partitions) | Medium (JetStream config) | **Already running** (you have Redis for cache) |
| Throughput ceiling    | 1M+ msg/sec                                 | 100K+ msg/sec             | 100K+ msg/sec                                  |
| Polyglot clients      | All technologies                            | All technologies          | All technologies                               |

### Serialization: JSON + CloudEvents Envelope

No Protobuf. No Schema Registry. Just JSON serialization on both sides.

The Outbox Relay writes events to Redis Streams wrapped in a CloudEvents JSON envelope:

```
┌─────────────────────────────────────────────┐
│ CloudEvents Envelope (CNCF Standard)        │
│ ─────────────────────────────────────────── │
│ id: "019532a0-b73c-7def..."  (UUIDv7)      │
│ source: "event-core/commerce/product"       │
│ type: "commerce.product.created"            │
│ datacontenttype: "application/json"         │
│ subject: "019532a0-..."  (aggregate ID)     │
│ time: "2026-03-12T14:30:45.123Z"            │
│ ─────────────────────────────────────────── │
│ data: <JSON payload>                        │
└─────────────────────────────────────────────┘
```

Add Protobuf + Schema Registry when you need schema enforcement across 5+ consumer teams.

### Consumer Groups and Competing Consumers

Redis Streams provides built-in consumer group semantics:

| Command      | Purpose                                              |
| ------------ | ---------------------------------------------------- |
| `XREADGROUP` | Read new messages for this consumer within its group |
| `XACK`       | Acknowledge successful processing                    |
| `XPENDING`   | List messages delivered but not yet acknowledged     |
| `XCLAIM`     | Reassign a pending message to a different consumer   |

Multiple instances of the same worker join the same consumer group for horizontal scaling. Each message is delivered to exactly one consumer in the group.

---

## Full Path: gRPC Streaming API (Phase 2)

The core exposes a gRPC streaming API for direct event store access. Workers talk to the event store without an intermediate broker.

### When to Add gRPC

Only when one or more of these apply:

1. Workers need **exactly-once** semantics (gRPC checkpoint in same DB transaction)
2. Workers need **real-time** latency (< 50ms from event append to worker processing)
3. Workers need to **query the event store** directly (load specific streams, not just receive broadcasts)

### Protocol Buffer Contract

```protobuf
syntax = "proto3";
package eventcore.v1;

service EventSubscription {
    rpc SubscribeByDomain (SubscribeRequest) returns (stream EventMessage) {}
    rpc SubscribeByEntity (SubscribeByEntityRequest) returns (stream EventMessage) {}
    rpc SubscribeGlobal (SubscribeGlobalRequest) returns (stream EventMessage) {}
    rpc GetCheckpoint (CheckpointRequest) returns (CheckpointResponse) {}
    rpc SaveCheckpoint (SaveCheckpointRequest) returns (SaveCheckpointResponse) {}
}

message SubscribeRequest {
    string domain = 1;
    int64 after_position = 2;
    int32 batch_size = 3;
}

message EventMessage {
    string id = 1;                  // UUIDv7
    int64 global_position = 2;
    string tenant_id = 3;
    string stream_domain = 4;
    string stream_entity = 5;
    string stream_id = 6;
    int32 stream_version = 7;
    string event_action = 8;
    int32 event_version = 9;
    google.protobuf.Struct payload = 10;
    google.protobuf.Struct metadata = 11;
    optional string correlation_id = 12;
    optional string causation_id = 13;
    optional string user_id = 14;
    google.protobuf.Timestamp created_at = 15;
}
```

### Why gRPC Server Streaming

| Benefit                  | How                                                    |
| ------------------------ | ------------------------------------------------------ |
| **Polyglot**             | `protoc` generates clients for all major technologies  |
| **Type-safe**            | Proto schema enforces field types across all consumers |
| **HTTP/2 multiplexing**  | Hundreds of concurrent subscriptions on one connection |
| **Backpressure**         | gRPC flow control prevents overwhelming slow consumers |
| **Long-lived**           | Server streaming naturally models event subscriptions  |
| **No broker dependency** | Direct event store access — fewer moving parts         |

---

## Message Broker Path (Phase 3)

For high-throughput fan-out, competing consumers, and full technology decoupling, the core relays events to Kafka or NATS via the Outbox pattern.

```
Core:
  EventStore → Outbox Relay Worker → Outbox Table (same DB transaction)
                                         │
                                         ▼ relay
                                   Message Broker (Kafka / NATS / Redis Streams)
                                         │
                    ┌────────────────────┬┼────────────────────┬──────────────────┐
                    ▼                    ▼                     ▼                  ▼
             Analytics          Notifications          Search indexer       Projection
             (consumer group)   (consumer group)       (consumer group)    (consumer group)
```

### Broker Selection

| Broker             | Best For                                        | Consumer Groups         | Ordering      | Ops Complexity         |
| ------------------ | ----------------------------------------------- | ----------------------- | ------------- | ---------------------- |
| **Kafka**          | High throughput, enterprise scale, audit trails | Yes (partition-based)   | Per-partition | High (ZooKeeper/KRaft) |
| **NATS JetStream** | Cloud-native, low latency, simpler ops          | Yes (durable consumers) | Per-subject   | Low                    |
| **Redis Streams**  | Low volume, already using Redis for cache       | Yes (XREADGROUP)        | Per-stream    | Lowest                 |

### When to Actually Add Kafka

Only when you hit **all three** simultaneously:

1. **> 100K events/second sustained** (not burst — Redis Streams handles bursts fine)
2. **Multi-datacenter replication** required (Kafka MirrorMaker)
3. **Weeks of retention** needed (Redis Streams are in-memory; Kafka is on-disk)

Until then, Redis Streams is strictly simpler and already deployed.

---

## Serialization Strategy

### Envelope: CloudEvents (CNCF Standard)

- CNCF graduated project — production-proven across AWS EventBridge, Google Eventarc, Azure Event Grid.
- SDKs in 9+ technologies.
- Context attributes can be inspected **without deserializing** the payload — enables broker-level routing.
- `dataschema` field points to the Schema Registry version — consumers know how to deserialize.

### Payload: JSON First, Protobuf When Earned

| Phase   | Payload Format | When                                                                 |
| ------- | -------------- | -------------------------------------------------------------------- |
| Phase 1 | JSON           | Start here. Every technology parses JSON natively.                   |
| Phase 2 | Protobuf       | When > 5 consumer teams need schema enforcement across technologies. |

### Schema Registry (When Needed)

```
┌────────────────────────────────────────────────────────┐
│ Schema Registry (Buf / Confluent)                      │
│ ────────────────────────────────────────────────────── │
│ commerce.product.created.v1.proto                      │
│ commerce.product.created.v2.proto  ← backward compat  │
│ commerce.order.placed.v1.proto                         │
│ billing.invoice.paid.v1.proto                          │
│ ────────────────────────────────────────────────────── │
│ Compatibility: BACKWARD (new consumers read old data)  │
│ Breaking change detection: automatic on push           │
└────────────────────────────────────────────────────────┘
```

### AsyncAPI for Event Contract Documentation

Every event contract is documented in AsyncAPI format, enabling any team to discover and implement a consumer:

```yaml
asyncapi: 3.0.0
info:
  title: Commerce Domain Events
  version: 1.0.0
channels:
  commerce.product.created:
    messages:
      ProductCreated:
        contentType: application/json
        headers:
          type: object
          properties:
            ce_type: { type: string, const: "commerce.product.created" }
            ce_source: { type: string }
            ce_id: { type: string, format: uuid }
            ce_time: { type: string, format: date-time }
```

---

## Event Routing Filters

Script-defined subscription filters compile to `PredicateAst` and are evaluated at relay time. See **06-embedded-scripting.md** for filter compilation details.

The relay worker loads filter predicates from Postgres (cached in Redis) and evaluates them against each outbox event to determine which streams / broker topics receive the event. This enables per-consumer filtering without consumer-side waste.

---

## Operational Concerns

### Checkpoint Management

| Model                            | Protocol                             | Who Manages State                       | Exactly-Once                          | Best For                       |
| -------------------------------- | ------------------------------------ | --------------------------------------- | ------------------------------------- | ------------------------------ |
| **Client-managed** (gRPC path)   | CheckpointStore via gRPC             | Worker saves position after processing  | Yes (same-transaction checkpoint)     | Single consumer per projection |
| **Server-managed** (broker path) | Kafka consumer groups / NATS durable | Broker tracks offset per consumer group | At-least-once (idempotent processing) | Competing consumers, fan-out   |

### Dead Letter Handling

Each consumer owns its own DLQ. One worker's poison event is its problem — other consumers are unaffected.

```
Topic: commerce.product.created
  ├─> analytics-service   → DLQ: commerce.product.created.analytics.dlq
  ├─> search-indexer       → DLQ: commerce.product.created.search.dlq
  └─> notifications        → DLQ: commerce.product.created.notifications.dlq
```

**Replay mechanism**: Admin tool moves messages from DLQ back to main topic after the bug is fixed. The worker re-processes them like any new event.

### Internal vs External Workers

```
┌─────────────────────────────────────────────────────────────────┐
│ INTERNAL (in-process)                                           │
│ ─────────────────────────────────────────────────────────────── │
│ • Uses port interfaces directly                                 │
│ • Same process as the core — deployed together                  │
│ • Checkpoint via CheckpointStore interface (in-process)          │
│ • Example: primary read model projections, inline projections   │
│ • Advantage: lowest latency, strongest consistency              │
├─────────────────────────────────────────────────────────────────┤
│ EXTERNAL (any technology, out-of-process)                        │
│ ─────────────────────────────────────────────────────────────── │
│ • Uses gRPC Subscription API or Message Broker                  │
│ • Separate binary/container — deployed independently            │
│ • Checkpoint via gRPC or broker consumer groups                  │
│ • Example: analytics, search indexing, notifications, ML        │
│ • Advantage: technology freedom, independent scaling/deployment  │
├─────────────────────────────────────────────────────────────────┤
│ DECISION RULE                                                   │
│ ─────────────────────────────────────────────────────────────── │
│ Use INTERNAL when: projection is critical path, needs strong    │
│   consistency, or latency < 10ms matters.                       │
│ Use EXTERNAL when: team uses a different technology, worker     │
│   needs independent scaling, or eventual consistency is fine.   │
└─────────────────────────────────────────────────────────────────┘
```
