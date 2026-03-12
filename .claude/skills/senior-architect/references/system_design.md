# System Design - Abstraction-First

## Distributed Systems Through Abstraction

### Message-Driven Architecture

Abstract messaging behind a port - implementations can be in-process channels, Redis streams, Kafka, or NATS.

```text
Port:    MessageBus { publish(event), subscribe(topic, handler) }
Adapter: InMemoryBus (testing), RedisBus (single-node), KafkaBus (distributed)
```

The domain publishes events without knowing the transport:

- Order confirmed -> publish OrderConfirmed event
- Payment processed -> publish PaymentProcessed event
- Adapters handle delivery guarantees, serialization, routing

### Event Sourcing Pattern

Store state as a sequence of events rather than mutable records.

```text
Port:    EventStore { append(stream, events), load(stream) -> Vec<Event> }
Domain:  Aggregate::apply(event) -> state transition (pure function)
Adapter: PostgresEventStore, InMemoryEventStore
```

Complexity analysis:

- Append: O(1) per event
- Load/rebuild: O(n) where n = events in stream
- Optimization: snapshots reduce rebuild to O(1) + O(events since snapshot)

### CQRS (Command Query Responsibility Segregation)

Separate write models (optimized for consistency) from read models (optimized for queries).

```text
Write side:
  Command -> CommandHandler -> Aggregate -> EventStore
  Data structure: append-only log (O(1) writes)

Read side:
  EventStore -> Projection -> ReadModel -> QueryHandler
  Data structure: denormalized views (O(1) reads by key)
```

## Scaling Abstractions

### Connection Pooling

Abstract pool behind a port so the domain doesn't know about connection management.

```text
Port:    ConnectionPool { acquire() -> Connection, release(Connection) }
Impl:    Fixed-size pool with bounded queue
         - acquire: O(1) if available, O(wait) if exhausted
         - release: O(1) - return to pool
```

### Caching Strategies (abstracted)

```text
Port:    Cache<K, V> { get(K) -> Option<V>, set(K, V, TTL), invalidate(K) }

Strategies (implemented as adapters):
- Cache-Aside: app checks cache, falls back to DB, populates cache
- Write-Through: writes go to cache AND DB synchronously
- Write-Behind: writes go to cache, async flush to DB
- Read-Through: cache auto-loads from DB on miss

Data structure: HashMap with TTL tracking
- get: O(1) average
- set: O(1) average
- invalidate: O(1)
```

### Load Balancing Abstraction

```text
Port:    LoadBalancer { next() -> ServiceInstance }

Strategies:
- Round Robin: O(1) - cycle through instances
- Weighted: O(1) - probability-based selection
- Least Connections: O(log n) - min-heap of connections
- Consistent Hashing: O(log n) - binary search on hash ring
```

## Service Communication Patterns

### Transport-Agnostic Service Layer

Define services as plain types. Let adapters handle transport.

```text
Domain service:
  OrderService { create_order(cmd) -> Result, get_order(id) -> Result }

Transport adapters:
  RestAdapter    -> maps HTTP verbs to service methods
  GrpcAdapter    -> maps protobuf messages to service methods
  GraphQLAdapter -> maps queries/mutations to service methods
```

This means you can expose the SAME service over REST, gRPC, and GraphQL simultaneously without changing domain code.

### Circuit Breaker (abstracted)

```text
Port:    CircuitBreaker { call(fn) -> Result<T, CircuitOpenError> }

States: Closed -> Open -> Half-Open -> Closed
Thresholds: configurable failure count, timeout, success count

Wraps any external call:
  payment = circuit_breaker.call(|| payment_gateway.charge(amount))
```

## Bounded Contexts and Module Boundaries

### Context Mapping

Each bounded context:

- Has its own domain model (types can have same names, different meanings)
- Communicates via published events or explicit anti-corruption layers
- Has its own storage (database per context for true independence)

### Anti-Corruption Layer

When integrating with external systems or legacy code:

```text
Port:    OrderPort (our domain's language)
ACL:     LegacyOrderAdapter (translates between our types and legacy types)
External: LegacyOrderSystem (speaks its own language)
```

The ACL prevents foreign concepts from leaking into our domain.

## Observability Through Abstraction

```text
Port:    Telemetry {
           trace(span_name, fn) -> Result
           metric(name, value, tags)
           log(level, message, context)
         }

Adapters:
  OpenTelemetryAdapter (production)
  StdoutAdapter (development)
  NoopAdapter (testing)
```

The domain instruments itself through the port. Testing doesn't need a telemetry backend.

## Deployment Abstraction

The same binary/artifact deploys differently based on adapter configuration:

```text
Composition root reads config:
  if config.db == "postgres" -> PostgresAdapter
  if config.db == "sqlite"   -> SqliteAdapter (dev/testing)

  if config.auth == "keycloak" -> KeycloakAdapter
  if config.auth == "zitadel"  -> ZitadelAdapter

  if config.payment == "stripe" -> StripeAdapter
  if config.payment == "mock"   -> MockPaymentAdapter (testing)
```

No code changes needed to swap providers - just configuration.
