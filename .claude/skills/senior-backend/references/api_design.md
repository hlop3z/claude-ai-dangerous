# API Design - Abstraction-First

## Transport-Agnostic Service Layer

The service layer is the single source of truth for business operations. Transport adapters (REST, gRPC, GraphQL) are thin wrappers.

### Service Definition Pattern

```text
// The service knows nothing about HTTP, gRPC, or GraphQL
OrderService {
  create(cmd: CreateOrderCmd) -> Result<OrderId, OrderError>
  confirm(id: OrderId) -> Result<void, OrderError>
  cancel(id: OrderId, reason: str) -> Result<void, OrderError>
  get(id: OrderId) -> Result<OrderView, OrderError>
  list(filter: OrderFilter, cursor: Cursor) -> Result<Page<OrderView>, OrderError>
}
```

### REST Adapter

Maps HTTP semantics to service calls:

```text
POST   /v1/orders           -> OrderService.create(parse_body(req))
PATCH  /v1/orders/:id       -> OrderService.update(id, parse_body(req))
POST   /v1/orders/:id/confirm -> OrderService.confirm(id)
DELETE /v1/orders/:id       -> OrderService.cancel(id, parse_body(req).reason)
GET    /v1/orders/:id       -> OrderService.get(id)
GET    /v1/orders           -> OrderService.list(parse_query(req))
```

### gRPC Adapter

Maps protobuf messages to the same service:

```protobuf
service OrderService {
  rpc CreateOrder(CreateOrderRequest) returns (CreateOrderResponse);
  rpc ConfirmOrder(ConfirmOrderRequest) returns (Empty);
  rpc GetOrder(GetOrderRequest) returns (OrderResponse);
  rpc ListOrders(ListOrdersRequest) returns (ListOrdersResponse);
}
```

### GraphQL Adapter

Maps queries/mutations to the same service:

```graphql
type Mutation {
  createOrder(input: CreateOrderInput!): Order!
  confirmOrder(id: ID!): Order!
}

type Query {
  order(id: ID!): Order
  orders(filter: OrderFilter, cursor: String, limit: Int): OrderConnection!
}
```

All three adapters call the SAME service. Changing business logic changes it in ONE place.

## API Versioning Strategy

### URL-Based (simplest, recommended for REST)

```text
/v1/orders  -> OrderServiceV1
/v2/orders  -> OrderServiceV2
```

### Adapter-Layer Concern

Versioning lives in the transport adapter, not in the domain:

```text
V1 REST Adapter -> transforms v1 request -> calls current service -> transforms to v1 response
V2 REST Adapter -> calls current service directly (native format)
```

Old API versions are adapters that translate between legacy and current formats.

## Pagination

### Cursor-Based (recommended for production)

```text
GET /v1/orders?cursor=eyJpZCI6MTIzfQ&limit=20

Response:
{
  "data": [...],
  "pagination": {
    "next_cursor": "eyJpZCI6MTQzfQ",
    "has_more": true
  }
}
```

Implementation: `WHERE id > $decoded_cursor ORDER BY id ASC LIMIT $limit + 1`

- Fetch limit+1 rows; if you get limit+1, there's more
- Cursor is opaque to client (base64-encoded position)
- Complexity: O(log n + k) with index, where k = page size

### Offset-Based (simple, fine for admin dashboards)

```text
GET /v1/orders?page=3&per_page=20

Response:
{
  "data": [...],
  "pagination": {
    "page": 3,
    "per_page": 20,
    "total": 156,
    "total_pages": 8
  }
}
```

Implementation: `LIMIT $per_page OFFSET ($page - 1) * $per_page`

- Complexity: O(offset + k) - degrades on deep pages
- Use only when total count is needed and dataset is bounded

## Request/Response Patterns

### Command Pattern (writes)

```text
// Request: exactly the data needed to perform the action
CreateOrderCmd {
  customer_id: CustomerId
  items: Vec<{product_id: ProductId, quantity: u32}>
  shipping_address: Address
}

// Response: just the ID (client fetches details separately if needed)
{ "id": "ord_abc123" }
```

### Query Pattern (reads)

```text
// Request: filters + pagination
OrderFilter {
  status?: Status
  customer_id?: CustomerId
  created_after?: DateTime
  created_before?: DateTime
}

// Response: denormalized view (not the domain model)
OrderView {
  id: string
  customer_name: string  // resolved, not just an ID
  items: Vec<{name: string, quantity: u32, price: Money}>
  total: Money
  status: string
  created_at: DateTime
}
```

Read models can skip the domain layer entirely - query the DB directly into view types.

## Error Handling at the API Boundary

### Error Mapping (adapter responsibility)

```text
Domain Error              -> HTTP Status + Error Response
------------------------------------------------------
ValidationError           -> 400 Bad Request
NotFound                  -> 404 Not Found
InvalidStateTransition    -> 409 Conflict
InsufficientPermissions   -> 403 Forbidden
DuplicateEntry            -> 409 Conflict

Adapter Error             -> HTTP Status
------------------------------------------------------
DatabaseError             -> 500 Internal Server Error
PaymentProviderError      -> 502 Bad Gateway
TimeoutError              -> 504 Gateway Timeout
```

### Error Response Structure

```json
{
  "error": {
    "code": "VALIDATION_FAILED",
    "message": "Human-readable description",
    "details": [
      { "field": "items", "issue": "Must contain at least one item" },
      { "field": "shipping_address.zip", "issue": "Invalid format" }
    ],
    "request_id": "req_xyz789"
  }
}
```

- `code`: machine-readable, stable across versions
- `message`: human-readable, can change
- `details`: structured context, optional
- `request_id`: for correlation with logs

## Rate Limiting (no external libraries needed)

### Token Bucket (stdlib implementation)

```text
State per client:
  tokens: float (current bucket level)
  last_refill: timestamp

On request:
  elapsed = now - last_refill
  tokens = min(max_tokens, tokens + elapsed * refill_rate)
  if tokens >= 1:
    tokens -= 1
    allow()
  else:
    reject(429, retry_after = (1 - tokens) / refill_rate)
```

Storage: in-memory HashMap for single-node, Redis for distributed.
Complexity: O(1) per request check.

### Rate Limit Headers

```text
X-RateLimit-Limit: 100
X-RateLimit-Remaining: 47
X-RateLimit-Reset: 1678886400
Retry-After: 30  (only on 429)
```

## Input Validation Strategy

### Layer 1: Transport Validation (adapter)

- JSON schema validity, required fields present, correct types
- Done by the HTTP framework (deserialization)

### Layer 2: Domain Validation (domain)

- Business rules: quantity > 0, amount > 0, valid state transitions
- Implemented as factory methods or builder patterns on domain types
- Returns domain errors, not HTTP errors

### Layer 3: Integration Validation (adapter)

- Foreign key existence, uniqueness constraints
- Handled by the database, surfaced as adapter errors
