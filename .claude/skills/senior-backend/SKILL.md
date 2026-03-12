---
name: senior-backend
description: Abstraction-first backend development for building APIs, data layers, auth, and integrations across Rust, Python, Go, TypeScript, and JavaScript. Minimal dependencies - only libs for DB drivers, payment gateways (Stripe/PayPal), and IAM (Zitadel/Keycloak). Use when building APIs, implementing business logic, designing data access, handling auth/authorization, optimizing queries, or integrating 3rd party services.
allowed-tools: Read, Grep, Glob, Bash(*)
---

# Senior Backend - Abstraction-First Implementation

You are operating as a senior backend engineer. Every implementation follows the abstraction-first principle: **domain logic is pure, I/O lives at the boundary, dependencies flow inward**.

## Architecture Layers (always follow this order)

### 1. Domain Layer (build first - zero dependencies)

Contains: types, business rules, validation, domain events, error types.

**Rust:**

```rust
// domain/order.rs - no use statements from crates
pub struct Order { id: OrderId, items: Vec<LineItem>, status: Status }
impl Order {
    pub fn confirm(&mut self) -> Result<OrderConfirmed, DomainError> { /* pure logic */ }
}
```

**Python:**

```python
# domain/order.py - no imports from frameworks or libraries
@dataclass
class Order:
    id: OrderId
    items: list[LineItem]
    status: Status = Status.DRAFT

    def confirm(self) -> OrderConfirmed:
        if self.status != Status.DRAFT:
            raise InvalidStateTransition(self.status, Status.CONFIRMED)
        self.status = Status.CONFIRMED
        return OrderConfirmed(order_id=self.id)
```

**Go:**

```go
// domain/order.go - no imports from external modules
type Order struct {
    ID     OrderID
    Items  []LineItem
    Status Status
}
func (o *Order) Confirm() (OrderConfirmed, error) { /* pure logic */ }
```

**TypeScript:**

```typescript
// domain/order.ts - no imports from node_modules
interface Order {
  id: OrderId;
  items: LineItem[];
  status: Status;
}
function confirmOrder(order: Order): Result<OrderConfirmed, DomainError> {
  /* pure logic */
}
```

### 2. Port Layer (define interfaces the domain needs)

Ports are abstract contracts. The domain defines WHAT it needs, not HOW it's provided.

**Standard Ports every backend needs:**

```
Repository<T>     - persistence (CRUD + queries)
PaymentGateway    - charge, refund, webhook handling
IdentityProvider  - token verification, user profile lookup
NotificationPort  - email, SMS, push notifications
EventPublisher    - domain event broadcasting
CachePort         - get, set, invalidate with TTL
```

### 3. Use Case Layer (orchestrate domain + ports)

Each use case is a single operation. Receives ports via constructor injection.

```
CreateOrder(repo, payment, events) -> OrderId
ConfirmOrder(repo, events) -> void
ProcessPayment(repo, payment, events) -> PaymentResult
GetOrderDetails(read_repo) -> OrderView  (query side - can skip domain model)
```

### 4. Adapter Layer (implement ports with real I/O)

This is the ONLY layer that imports external libraries.

## API Design (Transport-Agnostic)

### The Service Pattern

Define operations as service methods. Transport adapters call them.

```
OrderService:
  create(cmd: CreateOrderCmd) -> Result<OrderId, OrderError>
  confirm(id: OrderId) -> Result<void, OrderError>
  get(id: OrderId) -> Result<OrderView, OrderError>
  list(filter: OrderFilter, page: Pagination) -> Result<Page<OrderView>, OrderError>
```

### REST Adapter (maps HTTP to service)

```
POST   /orders          -> service.create(body)
PATCH  /orders/:id      -> service.confirm(id)  or service.update(id, body)
GET    /orders/:id      -> service.get(id)
GET    /orders?status=X -> service.list(filter, page)
DELETE /orders/:id      -> service.cancel(id)
```

HTTP status mapping:

- Success: 200 (GET/PATCH), 201 (POST), 204 (DELETE)
- Domain errors: 400 (validation), 404 (not found), 409 (conflict/invalid state)
- Auth errors: 401 (no token), 403 (insufficient permissions)
- System errors: 500 (adapter failures) - never expose internals

### Error Response Format (consistent across all endpoints)

```json
{
  "error": {
    "code": "ORDER_INVALID_STATE",
    "message": "Cannot confirm an order that is already shipped",
    "details": { "current_status": "shipped", "attempted": "confirmed" }
  }
}
```

## Data Layer Abstraction

### Repository Pattern

The repository is an abstraction over persistence. The domain sees it as a collection.

**Interface definition (in domain layer):**

```
Repository<T>:
  find_by_id(id) -> Option<T>
  save(entity) -> void
  delete(id) -> void

OrderRepository extends Repository<Order>:
  find_by_customer(customer_id, pagination) -> Page<Order>
  find_by_status(status) -> Vec<Order>
```

**PostgreSQL adapter (in adapter layer):**

Use parameterized queries ALWAYS. Never interpolate user input into SQL.

```sql
-- Optimized queries with proper indexing
SELECT id, status, total, created_at FROM orders
WHERE customer_id = $1 AND status = $2
ORDER BY created_at DESC
LIMIT $3 OFFSET $4;
```

**Index strategy based on query patterns:**

- Filter by customer: `CREATE INDEX idx_orders_customer ON orders(customer_id)`
- Filter by status: `CREATE INDEX idx_orders_status ON orders(status)`
- Composite: `CREATE INDEX idx_orders_customer_status ON orders(customer_id, status)`
- Sort + filter: include `created_at` in composite index

**Query complexity awareness:**

- Index lookup: O(log n) via B-tree
- Sequential scan: O(n) - avoid on large tables
- Join: O(n \* m) worst case, O(n + m) with hash join
- LIMIT with index: O(log n + k) where k = limit

### Migration Strategy

Migrations are versioned, forward-only, and reversible:

```
migrations/
  001_create_orders.up.sql
  001_create_orders.down.sql
  002_add_order_status_index.up.sql
  002_add_order_status_index.down.sql
```

Use the DB driver's migration support (sqlx migrate, golang-migrate, alembic) - this is an acceptable library use since it's a DB tooling concern.

## Authentication & Authorization Abstraction

### IAM Port

```
IdentityProvider:
  verify_token(token: str) -> Result<Claims, AuthError>
  get_user_info(user_id: str) -> Result<UserProfile, AuthError>
  has_permission(user_id: str, resource: str, action: str) -> bool
```

### Adapters for IAM Providers

**Zitadel adapter:**

- OIDC discovery endpoint for key rotation
- JWT validation using provider's JWKS
- Role/permission mapping from Zitadel's authorization model

**Keycloak adapter:**

- Same OIDC interface, different provider URLs
- Realm-based multi-tenancy mapping
- Role extraction from Keycloak's token claims

Both share the same port interface - swappable at configuration time.

### Auth Middleware Pattern

```
Request -> Extract Token -> Verify via IdentityProvider port -> Inject Claims -> Handler
```

The middleware uses the abstract IdentityProvider. It doesn't know if it's Zitadel, Keycloak, or a mock.

## Payment Integration Abstraction

### Payment Port

```
PaymentGateway:
  create_charge(amount: Money, customer: CustomerRef, metadata: dict) -> Result<ChargeId, PaymentError>
  capture_charge(charge_id: ChargeId) -> Result<void, PaymentError>
  refund(charge_id: ChargeId, amount: Option<Money>) -> Result<RefundId, PaymentError>
  handle_webhook(payload: bytes, signature: str) -> Result<PaymentEvent, PaymentError>
```

### Stripe Connect Adapter

- Uses Stripe SDK (acceptable dependency - 3rd party protocol)
- Maps Stripe-specific types to domain payment types
- Handles Connect account management for marketplace scenarios
- Webhook signature verification using Stripe's signing secret

### PayPal Adapter

- Same PaymentGateway port, different implementation
- Maps PayPal order/capture flow to charge/capture abstraction
- Webhook verification using PayPal's certificate chain

### Money Type (domain - no dependencies)

```
Money:
  amount: int (always in smallest unit - cents, pence)
  currency: str (ISO 4217 - "USD", "EUR")

  add(other: Money) -> Money  (assert same currency)
  multiply(factor: int) -> Money
  // NEVER use floating point for money
```

## Performance Patterns

### Connection Pooling

- Configure pool size based on: `pool_size = (core_count * 2) + disk_spindles`
- Always use pool at the adapter layer, injected into repositories
- Domain doesn't know about pools

### Query Optimization

- N+1 detection: if a use case calls repo.find N times in a loop, add a batch method
- Pagination: cursor-based (WHERE id > $cursor LIMIT N) over offset-based for large datasets
- Read replicas: use separate read repository adapter pointing to replica

### Caching

- Cache at the use case layer, not the domain layer
- Use CachePort abstraction - adapters can be Redis, in-memory, or no-op
- Cache invalidation on write: invalidate in the same use case that writes

## Reference Documentation

Detailed patterns in:

- `references/api_design.md` - transport-agnostic API patterns, versioning, pagination
- `references/data_layer.md` - repository implementations, query optimization, migrations
- `references/security.md` - auth middleware, rate limiting, input validation, CORS
