# Tech Decision Framework

## Language Selection Criteria

Choose based on the problem's primary constraint:

| Constraint                             | Best Fit       | Why                                             |
| -------------------------------------- | -------------- | ----------------------------------------------- |
| Performance critical, memory safety    | **Rust**       | Zero-cost abstractions, no GC, ownership model  |
| Rapid prototyping, ML/data pipelines   | **Python**     | Fast iteration, rich ecosystem for data/ML      |
| High concurrency, network services     | **Go**         | Goroutines, simple deployment, fast compilation |
| Type-safe web APIs, full-stack sharing | **TypeScript** | Strong types, runs everywhere JS runs           |
| Edge functions, lightweight scripts    | **JavaScript** | Universal runtime, minimal overhead             |

### Decision Tree

```text
Is this performance-critical or systems-level?
  YES -> Rust
  NO  -> Does it involve ML, data science, or scripting?
    YES -> Python
    NO  -> Is it a networked service with high concurrency?
      YES -> Go
      NO  -> Is it a web API or needs to share types with frontend?
        YES -> TypeScript
        NO  -> JavaScript (lightweight, edge, scripting)
```

## Dependency Evaluation Checklist

Before adding ANY external dependency, answer:

1. **Can stdlib do this?** Go's stdlib covers HTTP, JSON, crypto, testing. Rust's std covers collections, I/O, threading. Python's stdlib covers HTTP, JSON, async, hashing.

2. **Is this a protocol implementation?** DB wire protocols (Postgres, MySQL), payment API protocols (Stripe), auth protocols (OIDC) - these justify libraries.

3. **What's the maintenance status?** Check: last commit < 6 months, open issues triaged, multiple maintainers, no CVEs.

4. **What's the transitive dependency count?** A library pulling 50 transitive deps is a liability. Prefer libraries with minimal dep trees.

5. **Can we wrap it behind a port?** If yes, the library becomes a swappable adapter. If no, it's coupling your domain to a 3rd party.

### Acceptable Dependencies by Category

**Always acceptable (protocol implementations):**

- DB drivers: sqlx (Rust), asyncpg/psycopg (Python), pgx (Go), pg (Node)
- Serialization: serde (Rust) - encoding/json is Go stdlib
- HTTP servers: axum (Rust), uvicorn (Python), stdlib (Go), Hono (TS)

**Acceptable when wrapped behind a port:**

- Payment: Stripe SDK, PayPal SDK -> behind PaymentGateway port
- IAM: Zitadel SDK, Keycloak client -> behind IdentityProvider port
- Email: SMTP client -> behind NotificationPort
- Storage: S3 client -> behind ObjectStoragePort

**Almost never acceptable:**

- Utility libraries (lodash, ramda) - use language builtins
- Validation libraries - write domain validation as pure functions
- ORM layers that generate SQL (prefer query builders or raw SQL behind repository ports)
- CSS/UI frameworks in backend code
- Wrapper libraries that add minimal value over the underlying SDK

## Trade-Off Analysis Template

When evaluating architectural decisions:

```text
DECISION: [what are we deciding]
CONTEXT: [why does this decision matter now]

OPTION A: [name]
  + [advantage 1]
  + [advantage 2]
  - [disadvantage 1]
  - [disadvantage 2]
  Complexity: [Big-O of critical operations]
  Dependencies: [count and names]
  Reversibility: [easy/medium/hard to change later]

OPTION B: [name]
  [same structure]

DECISION: [chosen option]
RATIONALE: [why this one]
CONSEQUENCES: [what follows from this choice]
REVIEW DATE: [when to reassess]
```

## Data Structure Selection by Use Case

Reference from CS fundamentals:

| Use Case                    | Data Structure         | Time Complexity            | Space               |
| --------------------------- | ---------------------- | -------------------------- | ------------------- |
| Key-value lookups           | Hash Table             | O(1) avg, O(n) worst       | O(n)                |
| Ordered data, range queries | B-Tree / BTreeMap      | O(log n) all ops           | O(n)                |
| Task scheduling, priority   | Min/Max Heap           | O(log n) insert, O(1) peek | O(n)                |
| FIFO processing             | Queue                  | O(1) enqueue/dequeue       | O(n)                |
| LIFO / undo stacks          | Stack                  | O(1) push/pop              | O(n)                |
| Relationships, paths        | Graph (adjacency list) | O(V+E) traversal           | O(V+E)              |
| Sorted with fast insert     | Skip List              | O(log n) avg all ops       | O(n log n)          |
| Autocomplete, prefix match  | Trie                   | O(m) where m = key length  | O(alphabet **n** m) |
| Fast membership testing     | Bloom Filter           | O(k) where k = hash count  | O(m) bits           |

## Algorithm Selection by Problem

| Problem                          | Algorithm     | Complexity     | When to Use                                      |
| -------------------------------- | ------------- | -------------- | ------------------------------------------------ |
| Find in sorted data              | Binary Search | O(log n)       | Sorted arrays, paginated results                 |
| Find in unsorted data            | Linear Search | O(n)           | Small datasets, one-time searches                |
| Sort with stability needed       | Merge Sort    | O(n log n)     | Preserving relative order matters                |
| Sort in-place                    | Quick Sort    | O(n log n) avg | Memory-constrained, general purpose              |
| Shortest path (positive weights) | Dijkstra      | O((V+E) log V) | Network routing, service mesh                    |
| Shortest path (negative weights) | Bellman-Ford  | O(V \* E)      | Financial calculations, arbitrage                |
| Graph traversal (exhaustive)     | BFS           | O(V + E)       | Level-order processing, shortest unweighted path |
| Graph traversal (deep search)    | DFS           | O(V + E)       | Cycle detection, topological sort                |

## Error Handling Strategy by Language

Errors are **codes + context**, never human-readable strings. Messages, help text, and
user-facing content resolve through an i18n layer at the adapter boundary. Domain errors
carry structured data only.

### Architecture

```text
Domain Layer:  ErrorCode enum + typed context (structured, no messages)
                  |
Application:   propagates error codes unchanged
                  |
Adapter Layer: i18n resolver maps (ErrorCode, locale, context) -> localized message
               this is the ONLY place human-readable text is produced
```

### i18n Port (domain defines the contract)

```text
Translator:
  resolve(code: ErrorCode, locale: Locale, context: Map<str, str>) -> str

Adapters:
  FileTranslator    -> loads from locale files (JSON/TOML/YAML)
  DbTranslator      -> loads from translations table
  InMemoryTranslator -> hardcoded map (testing)
```

Locale files structure:

```text
locales/
  en/
    errors.json     { "order.not_found": "Order {id} not found", ... }
    help.json       { "order.create": "Create a new order with ...", ... }
  es/
    errors.json     { "order.not_found": "Pedido {id} no encontrado", ... }
    help.json       { "order.create": "Crea un nuevo pedido con ...", ... }
```

### Rust

```rust
// Domain errors - codes + structured context, no messages
#[derive(Debug, Clone)]
pub enum ErrorCode {
    OrderNotFound,
    OrderInvalidState,
    InsufficientStock,
    PaymentDeclined,
    Unauthorized,
}

#[derive(Debug)]
pub struct DomainError {
    pub code: ErrorCode,
    pub context: Vec<(&'static str, String)>,  // key-value pairs for interpolation
}

impl DomainError {
    pub fn order_not_found(id: &OrderId) -> Self {
        Self {
            code: ErrorCode::OrderNotFound,
            context: vec![("id", id.to_string())],
        }
    }

    pub fn invalid_state(current: &Status, attempted: &Status) -> Self {
        Self {
            code: ErrorCode::OrderInvalidState,
            context: vec![
                ("current", current.as_str().into()),
                ("attempted", attempted.as_str().into()),
            ],
        }
    }
}

// Adapter errors wrap domain errors with source
pub enum AppError {
    Domain(DomainError),
    Storage(DomainError),   // storage adapter maps DB errors to domain codes
    External(DomainError),  // 3rd party adapter maps provider errors to domain codes
}

// i18n resolution at the HTTP adapter boundary
fn to_response(err: AppError, locale: &Locale, translator: &dyn Translator) -> Response {
    let domain_err = err.inner();
    let message = translator.resolve(&domain_err.code, locale, &domain_err.context);
    // now produce JSON: { "error": { "code": "order.not_found", "message": "..." } }
}
```

### Go

```go
// Domain errors - codes, not messages
type ErrorCode string

const (
    ErrOrderNotFound    ErrorCode = "order.not_found"
    ErrInvalidTransition ErrorCode = "order.invalid_state"
    ErrInsufficientStock ErrorCode = "product.insufficient_stock"
    ErrPaymentDeclined   ErrorCode = "payment.declined"
)

type DomainError struct {
    Code    ErrorCode
    Context map[string]string // interpolation params
    Source  error             // wrapped cause (for errors.Is/As)
}

func (e *DomainError) Error() string { return string(e.Code) } // code only, no message
func (e *DomainError) Unwrap() error { return e.Source }

func OrderNotFound(id OrderID) *DomainError {
    return &DomainError{
        Code:    ErrOrderNotFound,
        Context: map[string]string{"id": id.String()},
    }
}

// Wrap adapter errors with domain codes
func (r *pgOrderRepo) FindByID(ctx context.Context, id OrderID) (*Order, error) {
    row := r.pool.QueryRow(ctx, query, id)
    if err := row.Scan(&o); err != nil {
        if errors.Is(err, pgx.ErrNoRows) {
            return nil, OrderNotFound(id) // domain code, not DB message
        }
        return nil, &DomainError{Code: "storage.query_failed", Source: err}
    }
    return o.toDomain(), nil
}

// i18n at HTTP boundary
func writeError(w http.ResponseWriter, err *DomainError, t Translator, locale string) {
    msg := t.Resolve(err.Code, locale, err.Context)
    // write JSON: { "error": { "code": "order.not_found", "message": msg } }
}
```

### Python

```python
from dataclasses import dataclass, field
from enum import Enum

class ErrorCode(str, Enum):
    ORDER_NOT_FOUND = "order.not_found"
    ORDER_INVALID_STATE = "order.invalid_state"
    INSUFFICIENT_STOCK = "product.insufficient_stock"
    PAYMENT_DECLINED = "payment.declined"
    UNAUTHORIZED = "auth.unauthorized"

@dataclass
class DomainError(Exception):
    code: ErrorCode
    context: dict[str, str] = field(default_factory=dict)

    def __str__(self) -> str:
        return self.code.value  # code only, never a message

def order_not_found(order_id: OrderId) -> DomainError:
    return DomainError(
        code=ErrorCode.ORDER_NOT_FOUND,
        context={"id": str(order_id)},
    )

# Adapter wraps external errors into domain codes
async def find_by_id(self, order_id: OrderId) -> Order | None:
    try:
        row = await self._pool.fetchrow(query, str(order_id))
    except asyncpg.PostgresError as e:
        raise DomainError(
            code=ErrorCode.STORAGE_FAILURE,
            context={"source": type(e).__name__},
        ) from e
    if row is None:
        raise order_not_found(order_id)
    return _to_domain(row)

# i18n at HTTP boundary
async def error_handler(request, err: DomainError, translator: Translator):
    locale = request.headers.get("Accept-Language", "en")
    message = translator.resolve(err.code, locale, err.context)
    return JSONResponse({"error": {"code": err.code.value, "message": message}})
```

### TypeScript

```typescript
// Domain errors - codes + typed context, no messages
type ErrorCode =
  | "order.not_found"
  | "order.invalid_state"
  | "product.insufficient_stock"
  | "payment.declined"
  | "auth.unauthorized";

type DomainError = {
  code: ErrorCode;
  context: Record<string, string>;
};

// Result type - never throw in domain
type Result<T, E = DomainError> =
  | { ok: true; value: T }
  | { ok: false; error: E };

function orderNotFound(id: string): DomainError {
  return { code: "order.not_found", context: { id } };
}

function invalidState(current: string, attempted: string): DomainError {
  return { code: "order.invalid_state", context: { current, attempted } };
}

function createOrder(cmd: CreateOrderCmd): Result<Order> {
  if (!cmd.items.length) {
    return {
      ok: false,
      error: {
        code: "order.invalid_state",
        context: { reason: "empty_items" },
      },
    };
  }
  // ...
}

// i18n at HTTP boundary
function toResponse(err: DomainError, locale: string, t: Translator): Response {
  const message = t.resolve(err.code, locale, err.context);
  return Response.json({ error: { code: err.code, message } });
}
```

### Key Rules

- Domain errors carry a **code** (enum/const) and **context** (key-value map for interpolation)
- **No human-readable text** in domain or application layers
- The adapter boundary resolves codes to localized messages using the `Translator` port
- Error codes are stable API contracts - they don't change when translations change
- Context keys (`{id}`, `{current}`, `{attempted}`) are interpolated into locale templates
- Help text, validation hints, and UI copy follow the same pattern: code + context -> i18n resolver
