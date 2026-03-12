# Abstraction Patterns by Language

## The Universal Model: Ports & Adapters

Every system has a domain core that defines **ports** (abstract interfaces for capabilities it needs) and **adapters** (concrete implementations of those ports).

```text
Domain defines:    PaymentPort, AuthPort, StoragePort, NotificationPort
Adapters provide:  StripeAdapter, KeycloakAdapter, PostgresAdapter, EmailAdapter
Composition root:  wire(StripeAdapter -> PaymentPort, KeycloakAdapter -> AuthPort, ...)
```

The domain never imports adapter code. Adapters import domain ports.

---

## Rust Abstraction Patterns

### Trait-Based Ports

```rust
// Domain port - lives in domain/ports.rs
pub trait PaymentGateway: Send + Sync {
    async fn charge(&self, amount: Money, customer: &CustomerId) -> Result<PaymentId, PaymentError>;
    async fn refund(&self, payment: &PaymentId) -> Result<(), PaymentError>;
}

pub trait IdentityProvider: Send + Sync {
    async fn verify_token(&self, token: &str) -> Result<Claims, AuthError>;
    async fn get_user(&self, id: &UserId) -> Result<UserProfile, AuthError>;
}

pub trait Repository<T: Aggregate>: Send + Sync {
    async fn find_by_id(&self, id: &T::Id) -> Result<Option<T>, StorageError>;
    async fn save(&self, entity: &T) -> Result<(), StorageError>;
}
```

### Newtype Pattern - Type-Safe Domain IDs

```rust
// Prevents mixing up IDs at compile time - zero runtime cost
pub struct UserId(uuid::Uuid);
pub struct OrderId(uuid::Uuid);
pub struct PaymentId(String);

// UserId cannot be passed where OrderId is expected
```

### Typestate Pattern - Compile-Time State Machines

```rust
pub struct Order<S: OrderState> {
    id: OrderId,
    items: Vec<LineItem>,
    _state: PhantomData<S>,
}

pub struct Draft;
pub struct Confirmed;
pub struct Shipped;

impl Order<Draft> {
    pub fn confirm(self) -> Order<Confirmed> { /* ... */ }
}
impl Order<Confirmed> {
    pub fn ship(self) -> Order<Shipped> { /* ... */ }
}
// Order<Draft> cannot call .ship() - compiler enforces state transitions
```

### Zero-Cost Generics with Bounds

```rust
// Generic use case - works with any storage/payment implementation
pub struct CreateOrderUseCase<S, P>
where
    S: Repository<Order>,
    P: PaymentGateway,
{
    storage: S,
    payment: P,
}
// Monomorphized at compile time - no vtable, no dynamic dispatch overhead
```

### When to Use Dynamic Dispatch

```rust
// Use trait objects when you need runtime polymorphism
// (e.g., plugin systems, config-driven adapter selection)
pub struct AppContext {
    payment: Box<dyn PaymentGateway>,
    auth: Box<dyn IdentityProvider>,
    // Small vtable cost, but enables runtime flexibility
}
```

---

## Python Abstraction Patterns

### Protocol-Based Ports (Structural Subtyping)

```python
from typing import Protocol, runtime_checkable

@runtime_checkable
class PaymentGateway(Protocol):
    async def charge(self, amount: Money, customer: CustomerId) -> PaymentId: ...
    async def refund(self, payment: PaymentId) -> None: ...

@runtime_checkable
class IdentityProvider(Protocol):
    async def verify_token(self, token: str) -> Claims: ...
    async def get_user(self, user_id: UserId) -> UserProfile: ...

# Any class with matching methods satisfies the protocol - no inheritance needed
class StripeGateway:
    async def charge(self, amount: Money, customer: CustomerId) -> PaymentId:
        # Stripe-specific implementation
        ...
    async def refund(self, payment: PaymentId) -> None:
        ...
# StripeGateway satisfies PaymentGateway without inheriting from it
```

### Dataclass Domain Models

```python
from dataclasses import dataclass, field
from enum import Enum, auto

class OrderStatus(Enum):
    DRAFT = auto()
    CONFIRMED = auto()
    SHIPPED = auto()

@dataclass(frozen=True)
class Money:
    amount: int  # cents - avoid float for money
    currency: str = "USD"

@dataclass
class Order:
    id: OrderId
    items: list[LineItem] = field(default_factory=list)
    status: OrderStatus = OrderStatus.DRAFT

    def confirm(self) -> None:
        if self.status != OrderStatus.DRAFT:
            raise DomainError("Can only confirm draft orders")
        self.status = OrderStatus.CONFIRMED
```

### Dependency Injection via Constructor

```python
class CreateOrderUseCase:
    def __init__(
        self,
        storage: OrderRepository,  # Protocol type
        payment: PaymentGateway,    # Protocol type
    ) -> None:
        self._storage = storage
        self._payment = payment

    async def execute(self, cmd: CreateOrderCommand) -> OrderId:
        order = Order.create(cmd.items)
        await self._payment.charge(order.total, cmd.customer_id)
        await self._storage.save(order)
        return order.id
```

---

## Go Abstraction Patterns

### Implicit Interface Satisfaction

```go
// Domain port - small, focused interfaces
type PaymentGateway interface {
    Charge(ctx context.Context, amount Money, customer CustomerID) (PaymentID, error)
    Refund(ctx context.Context, payment PaymentID) error
}

type IdentityProvider interface {
    VerifyToken(ctx context.Context, token string) (Claims, error)
}

// Accept interfaces, return structs
type OrderRepository interface {
    FindByID(ctx context.Context, id OrderID) (*Order, error)
    Save(ctx context.Context, order *Order) error
}
```

### Functional Options for Configuration

```go
type ServerOption func(*Server)

func WithPort(port int) ServerOption {
    return func(s *Server) { s.port = port }
}

func WithTimeout(d time.Duration) ServerOption {
    return func(s *Server) { s.timeout = d }
}

func NewServer(opts ...ServerOption) *Server {
    s := &Server{port: 8080, timeout: 30 * time.Second}
    for _, opt := range opts {
        opt(s)
    }
    return s
}
```

### Composition Root

```go
func main() {
    db := postgres.NewPool(cfg.DatabaseURL)

    // Wire adapters to ports
    orderRepo := postgres.NewOrderRepository(db)
    paymentGw := stripe.NewGateway(cfg.StripeKey)
    authProvider := keycloak.NewProvider(cfg.KeycloakURL)

    // Inject into use cases
    createOrder := usecase.NewCreateOrder(orderRepo, paymentGw)

    // Wire HTTP handlers
    handler := http.NewHandler(createOrder, authProvider)
    server := http.NewServer(handler, http.WithPort(cfg.Port))
    server.ListenAndServe()
}
```

---

## TypeScript Abstraction Patterns

### Discriminated Unions for Domain Events

```typescript
type OrderEvent =
  | { type: "order_created"; orderId: string; items: LineItem[] }
  | { type: "order_confirmed"; orderId: string; confirmedAt: Date }
  | { type: "order_shipped"; orderId: string; trackingNumber: string };

function handleEvent(event: OrderEvent): void {
  switch (event.type) {
    case "order_created":
      // TypeScript narrows: event.items is available here
      break;
    case "order_confirmed":
      // event.confirmedAt is available here
      break;
    case "order_shipped":
      // event.trackingNumber is available here
      break;
  }
  // Exhaustiveness checked at compile time
}
```

### Branded Types for Type-Safe IDs

```typescript
type Brand<T, B> = T & { __brand: B };
type UserId = Brand<string, "UserId">;
type OrderId = Brand<string, "OrderId">;

function createUserId(id: string): UserId {
  return id as UserId;
}
function createOrderId(id: string): OrderId {
  return id as OrderId;
}

// Cannot pass UserId where OrderId is expected
```

### Interface-Based Ports

```typescript
interface PaymentGateway {
  charge(
    amount: Money,
    customer: UserId,
  ): Promise<Result<PaymentId, PaymentError>>;
  refund(payment: PaymentId): Promise<Result<void, PaymentError>>;
}

interface AuthProvider {
  verifyToken(token: string): Promise<Result<Claims, AuthError>>;
}

// Result type - no throwing in domain code
type Result<T, E> = { ok: true; value: T } | { ok: false; error: E };
```

---

## Anti-Patterns to Avoid

### Leaky Abstractions

- Domain types that import `sqlalchemy`, `pgx`, or `serde` attributes
- Use case code that references HTTP status codes or SQL syntax
- Domain logic that catches database-specific exceptions

### God Interfaces

- A single `Service` interface with 20+ methods
- Fix: split into focused ports (Reader, Writer, Searcher)

### Premature Abstraction

- Creating interfaces before there are two implementations
- Exception: ports for external systems ALWAYS deserve an abstraction (you will swap them)

### Framework Coupling

- Domain types decorated with framework annotations (@Entity, @Table, @route)
- Fix: keep domain types plain, create adapter-layer mapping functions
