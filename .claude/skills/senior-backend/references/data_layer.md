# Data Layer - Abstraction-First

## Repository Pattern Implementation

### Port Definition (domain layer)

```text
Repository<T: Aggregate>:
  find_by_id(id: T::Id) -> Option<T>
  save(entity: T) -> void
  delete(id: T::Id) -> void
```

Extended for specific aggregates:

```text
OrderRepository:
  find_by_customer(customer_id, pagination) -> Page<Order>
  find_pending_older_than(duration) -> Vec<Order>
  count_by_status(status) -> u64
```

### Rust Implementation (sqlx - no ORM)

```rust
pub struct PgOrderRepository {
    pool: PgPool,
}

impl OrderRepository for PgOrderRepository {
    async fn find_by_id(&self, id: &OrderId) -> Result<Option<Order>, StorageError> {
        let row = sqlx::query_as!(
            OrderRow,
            "SELECT id, customer_id, status, total_cents, currency, created_at
             FROM orders WHERE id = $1",
            id.as_ref()
        )
        .fetch_optional(&self.pool)
        .await
        .map_err(|e| StorageError::Query(e.to_string()))?;

        Ok(row.map(|r| r.into_domain()))
    }

    async fn save(&self, order: &Order) -> Result<(), StorageError> {
        sqlx::query!(
            "INSERT INTO orders (id, customer_id, status, total_cents, currency, created_at)
             VALUES ($1, $2, $3, $4, $5, $6)
             ON CONFLICT (id) DO UPDATE SET status = $3, total_cents = $4",
            order.id.as_ref(),
            order.customer_id.as_ref(),
            order.status.as_str(),
            order.total.amount,
            order.total.currency,
            order.created_at
        )
        .execute(&self.pool)
        .await
        .map_err(|e| StorageError::Query(e.to_string()))?;
        Ok(())
    }
}
```

### Go Implementation (pgx - no ORM)

```go
type pgOrderRepository struct {
    pool *pgxpool.Pool
}

func (r *pgOrderRepository) FindByID(ctx context.Context, id OrderID) (*Order, error) {
    row := r.pool.QueryRow(ctx,
        `SELECT id, customer_id, status, total_cents, currency, created_at
         FROM orders WHERE id = $1`, id)

    var o orderRow
    if err := row.Scan(&o.ID, &o.CustomerID, &o.Status, &o.TotalCents, &o.Currency, &o.CreatedAt); err != nil {
        if errors.Is(err, pgx.ErrNoRows) {
            return nil, nil
        }
        return nil, fmt.Errorf("query order: %w", err)
    }
    return o.toDomain(), nil
}
```

### Python Implementation (asyncpg - no ORM)

```python
class PgOrderRepository:
    def __init__(self, pool: asyncpg.Pool) -> None:
        self._pool = pool

    async def find_by_id(self, order_id: OrderId) -> Order | None:
        async with self._pool.acquire() as conn:
            row = await conn.fetchrow(
                "SELECT id, customer_id, status, total_cents, currency, created_at "
                "FROM orders WHERE id = $1",
                str(order_id),
            )
        if row is None:
            return None
        return _row_to_order(row)

    async def save(self, order: Order) -> None:
        async with self._pool.acquire() as conn:
            await conn.execute(
                "INSERT INTO orders (id, customer_id, status, total_cents, currency, created_at) "
                "VALUES ($1, $2, $3, $4, $5, $6) "
                "ON CONFLICT (id) DO UPDATE SET status = $3, total_cents = $4",
                str(order.id), str(order.customer_id), order.status.value,
                order.total.amount, order.total.currency, order.created_at,
            )
```

### TypeScript Implementation (pg - no ORM)

```typescript
class PgOrderRepository implements OrderRepository {
  constructor(private pool: Pool) {}

  async findById(id: OrderId): Promise<Order | null> {
    const { rows } = await this.pool.query(
      `SELECT id, customer_id, status, total_cents, currency, created_at
       FROM orders WHERE id = $1`,
      [id],
    );
    return rows[0] ? rowToOrder(rows[0]) : null;
  }

  async save(order: Order): Promise<void> {
    await this.pool.query(
      `INSERT INTO orders (id, customer_id, status, total_cents, currency, created_at)
       VALUES ($1, $2, $3, $4, $5, $6)
       ON CONFLICT (id) DO UPDATE SET status = $3, total_cents = $4`,
      [
        order.id,
        order.customerId,
        order.status,
        order.total.amount,
        order.total.currency,
        order.createdAt,
      ],
    );
  }
}
```

## Row-to-Domain Mapping

The adapter maps between DB rows and domain types. This translation layer:

- Converts snake_case DB columns to domain types
- Reconstructs value objects (Money from cents + currency)
- Maps string enums to domain enum variants
- Handles nullable columns to Option/None/null

```text
DB Row (flat, primitive types)  <->  Domain Type (rich, typed)
--------------------------------------------------------------
total_cents: int, currency: str  ->  Money { amount: 1299, currency: "USD" }
status: "confirmed"              ->  Status::Confirmed
customer_id: uuid                ->  CustomerId(uuid)
```

## Query Optimization

### Indexing Strategy

**Rule: Index what you WHERE, ORDER BY, and JOIN on.**

```sql
-- Single column indexes for common filters
CREATE INDEX idx_orders_customer ON orders(customer_id);
CREATE INDEX idx_orders_status ON orders(status);
CREATE INDEX idx_orders_created ON orders(created_at);

-- Composite index for common combined queries
-- Column order matters: most selective first, then order/range columns
CREATE INDEX idx_orders_customer_created ON orders(customer_id, created_at DESC);

-- Partial index for hot queries
CREATE INDEX idx_orders_pending ON orders(created_at)
  WHERE status = 'pending';

-- Covering index to avoid table lookup
CREATE INDEX idx_orders_list ON orders(customer_id, created_at DESC)
  INCLUDE (id, status, total_cents);
```

### N+1 Detection and Prevention

**Problem:**

```python
orders = await repo.find_by_customer(customer_id)
for order in orders:
    items = await item_repo.find_by_order(order.id)  # N queries!
```

**Solution - batch fetch:**

```python
orders = await repo.find_by_customer(customer_id)
order_ids = [o.id for o in orders]
items_by_order = await item_repo.find_by_orders(order_ids)  # 1 query
```

**SQL:**

```sql
SELECT * FROM order_items WHERE order_id = ANY($1)  -- $1 is array of IDs
```

### Connection Pool Sizing

```text
Optimal pool size = (physical_cores * 2) + effective_spindle_count

Examples:
  4-core SSD machine:  (4 * 2) + 1 = 9 connections
  8-core SSD machine:  (8 * 2) + 1 = 17 connections
  16-core NVMe:        (16 * 2) + 1 = 33 connections
```

More connections != better. Beyond the optimal, context switching degrades performance.

## Migration Best Practices

### File Structure

```text
migrations/
  0001_create_orders.sql
  0002_create_order_items.sql
  0003_add_customer_index.sql
  0004_add_status_enum.sql
```

### Safe Migration Patterns

**Adding a column:**

```sql
-- Safe: nullable column with default
ALTER TABLE orders ADD COLUMN notes text DEFAULT '';

-- Dangerous: NOT NULL without default on populated table
-- ALTER TABLE orders ADD COLUMN notes text NOT NULL;  -- LOCKS TABLE
```

**Adding an index:**

```sql
-- Safe: concurrent index creation (no lock)
CREATE INDEX CONCURRENTLY idx_orders_status ON orders(status);

-- Dangerous: regular index creation locks writes
-- CREATE INDEX idx_orders_status ON orders(status);
```

**Renaming a column (zero-downtime):**

1. Add new column
2. Write to both old and new
3. Backfill new from old
4. Switch reads to new
5. Stop writing to old
6. Drop old column

## Testing the Data Layer

### Repository Tests (integration)

Test against a real database (Docker-based):

```text
Setup: create test database, run migrations
Test:  save entity -> find entity -> assert equality
       save entity -> delete entity -> find returns None
       save multiple -> list with filter -> assert correct subset
Teardown: drop test database
```

### In-Memory Repository (for use case tests)

```text
InMemoryOrderRepository implements OrderRepository:
  storage: HashMap<OrderId, Order>

  find_by_id(id) -> storage.get(id).cloned()
  save(order) -> storage.insert(order.id, order)
  delete(id) -> storage.remove(id)
```

Use the in-memory adapter for unit testing use cases. Use the real adapter for integration tests.

## Unit of Work Pattern

Coordinates writes across multiple repositories within a single transaction.

### Go Implementation

```go
type UnitOfWork struct {
    tx pgx.Tx
}

func (uow *UnitOfWork) Orders() OrderRepository {
    return &pgOrderRepository{tx: uow.tx}
}

func (uow *UnitOfWork) Payments() PaymentRepository {
    return &pgPaymentRepository{tx: uow.tx}
}

func (uow *UnitOfWork) Commit(ctx context.Context) error {
    return uow.tx.Commit(ctx)
}

func (uow *UnitOfWork) Rollback(ctx context.Context) error {
    return uow.tx.Rollback(ctx)
}

// Usage in use case:
func (uc *PlaceOrderUseCase) Execute(ctx context.Context, cmd PlaceOrderCmd) error {
    uow, err := uc.uowFactory.Begin(ctx)
    if err != nil { return err }
    defer uow.Rollback(ctx)

    order := domain.NewOrder(cmd)
    if err := uow.Orders().Save(ctx, order); err != nil { return err }
    if err := uow.Payments().Save(ctx, payment); err != nil { return err }

    return uow.Commit(ctx)
}
```

### Rust Implementation

```rust
pub struct UnitOfWork<'a> {
    tx: Transaction<'a, Postgres>,
}

impl<'a> UnitOfWork<'a> {
    pub fn orders(&mut self) -> PgOrderRepository<'_> {
        PgOrderRepository { tx: &mut self.tx }
    }

    pub async fn commit(self) -> Result<(), StorageError> {
        self.tx.commit().await.map_err(Into::into)
    }
}
```

## Caching Repository Decorator

The Decorator pattern applied to repositories - the service layer is unaware caching exists.

```text
CachingRepository<T> implements Repository<T>:
  inner: Repository<T>   // the real repository
  cache: CachePort        // abstract cache

  find_by_id(id):
    if cached = cache.get(id): return cached   // cache-aside read
    result = inner.find_by_id(id)
    cache.set(id, result, ttl=300)
    return result

  save(entity):
    inner.save(entity)
    cache.invalidate(entity.id)                 // invalidate on write
```

This composes at the wire-up level:

```text
real_repo = PgOrderRepository(pool)
cached_repo = CachingOrderRepository(real_repo, redis_cache)
use_case = CreateOrderUseCase(cached_repo)  // use case doesn't know about caching
```
