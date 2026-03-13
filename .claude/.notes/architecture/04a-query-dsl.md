# Query DSL — JSON Filter Grammar

The API exposes a MongoDB-inspired JSON filter grammar for querying read models. Clients send structured JSON filters; the adapter compiles them to parameterized queries. User input **never** touches a query string — injection is structurally impossible.

This is the grammar accepted by the `filters` parameter in `ReadModelStore.query()` and `ReadModelStore.query_by_domain()`.

---

## Why Not Raw SQL or GraphQL?

| Approach            | Problem                                                                                                                                             |
| ------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------- |
| Raw SQL in API      | SQL injection. Even parameterized, exposing SQL grammar leaks schema details and enables DoS via complex queries.                                   |
| OData / FIQL        | Parsing string-based DSLs is error-prone. Edge cases in URL encoding.                                                                               |
| GraphQL             | Requires schema introspection, client tooling, and a separate query language. Heavyweight for filtering document stores.                            |
| **JSON filter DSL** | Parsed to AST, compiled to parameterized queries. Closed grammar — clients can only express what we allow. Field whitelist prevents schema probing. |

### Who Does This Successfully?

- **Supabase / PostgREST** — hundreds of thousands of production databases, all queries parameterized.
- **Hasura** — GraphQL `where` clauses compiled to parameterized SQL. Enterprise adoption.
- **Directus** — REST + GraphQL over any SQL database. JSON filter objects compiled via query builder.
- **Strapi** — `$eq`, `$contains`, `$and`, `$or` operators. Compiled to parameterized queries.
- **Prisma** — typed `where` clauses generating parameterized SQL.
- **Elasticsearch** — the original JSON Query DSL. Full boolean nesting, all server-side.

---

## Operator Reference

### Comparison Operators

| Operator    | Meaning                 | JSON Example                             |
| ----------- | ----------------------- | ---------------------------------------- |
| `$eq`       | Equals                  | `{"status": {"$eq": "active"}}`          |
| `$neq`      | Not equals              | `{"status": {"$neq": "banned"}}`         |
| `$gt`       | Greater than            | `{"age": {"$gt": 18}}`                   |
| `$gte`      | Greater than or equal   | `{"age": {"$gte": 18}}`                  |
| `$lt`       | Less than               | `{"age": {"$lt": 65}}`                   |
| `$lte`      | Less than or equal      | `{"age": {"$lte": 65}}`                  |
| `$in`       | In array                | `{"role": {"$in": ["admin", "editor"]}}` |
| `$contains` | Array contains value    | `{"tags": {"$contains": "vip"}}`         |
| `$exists`   | Field exists (non-null) | `{"email": {"$exists": true}}`           |

### Logical Operators

| Operator | Meaning                   | Arity                   |
| -------- | ------------------------- | ----------------------- |
| `$and`   | All conditions must match | Array of conditions     |
| `$or`    | At least one must match   | Array of conditions     |
| `$not`   | Negate a condition        | Single condition object |

### Implicit `$eq`

Bare values are shorthand for `$eq`:

```json
{ "status": "active" }
```

is equivalent to:

```json
{ "status": { "$eq": "active" } }
```

---

## Grammar (Formal)

```
Filter       := LogicalExpr | FieldExpr | {}
LogicalExpr  := { "$and": [Filter, ...] }
              | { "$or":  [Filter, ...] }
              | { "$not": Filter }
FieldExpr    := { field: Operator } | { field: Value }
Operator     := { "$eq": Value }
              | { "$neq": Value }
              | { "$gt": Value }
              | { "$gte": Value }
              | { "$lt": Value }
              | { "$lte": Value }
              | { "$in": [Value, ...] }
              | { "$contains": Value }
              | { "$exists": Bool }
              | { "$not": Operator }
Value        := String | Number | Bool | null
```

Empty object `{}` matches all documents (no filter).

---

## Full Example

```json
{
  "$and": [
    { "age": { "$gte": 18 } },
    { "age": { "$lte": 65 } },
    {
      "$or": [{ "role": { "$eq": "admin" } }, { "role": { "$eq": "manager" } }]
    },
    { "tags": { "$contains": "vip" } },
    { "email": { "$exists": true } },
    { "status": { "$not": { "$eq": "banned" } } }
  ]
}
```

---

## Mapping to Domain Condition Type

The filter grammar maps directly to the `Condition` type defined in the domain:

| JSON Operator | Condition Variant                     |
| ------------- | ------------------------------------- |
| `$eq`         | `Condition.Eq { field, value }`       |
| `$neq`        | `Condition.Neq { field, value }`      |
| `$gt`         | `Condition.Gt { field, value }`       |
| `$gte`        | `Condition.Gte { field, value }`      |
| `$lt`         | `Condition.Lt { field, value }`       |
| `$lte`        | `Condition.Lte { field, value }`      |
| `$in`         | `Condition.In { field, values }`      |
| `$contains`   | `Condition.Contains { field, value }` |
| `$and`        | `Condition.And(List<Condition>)`      |
| `$or`         | `Condition.Or(List<Condition>)`       |
| `$not`        | `Condition.Not(Condition)`            |

The `$exists` operator needs an additional variant: `Condition.Exists { field, exists: boolean }`.

### Data Flow

```
Client JSON → parse → Condition AST (domain) → Adapter compiles to parameterized query
```

1. **Transport layer**: Deserialize `filters` JSON into `Condition`.
2. **Application layer**: Pass `Condition` to `ReadModelStore.query()`.
3. **Adapter layer**: Walk the `Condition` tree, emit parameterized query using a query builder.

The same `Condition` type is reused across policies, event filters, validation, and queries. One AST, four use cases.

---

## Security: Defense in Depth

### Layer 1 — Structural (JSON → AST)

Injection is impossible because user input never reaches a query string. The adapter receives a typed `Condition` and emits parameterized queries. There is no code path from user JSON to raw query text.

### Layer 2 — Field Whitelist

Not every document field should be queryable. The adapter maintains a per-entity whitelist of allowed field names. Unknown fields are rejected at parse time with a validation error.

Without a whitelist, clients could probe for internal fields even though they'd only see filtered results.

### Layer 3 — Query Limits

| Limit                       | Default | Why                                            |
| --------------------------- | ------- | ---------------------------------------------- |
| Max nesting depth           | 4       | Prevents exponential query expansion           |
| Max clause count            | 20      | Bounds query complexity                        |
| Max `$in` array size        | 100     | Prevents large array parameters                |
| Max field path depth        | 3       | Prevents deep document traversal               |
| Disallow `$regex` / `$like` | Always  | Leading wildcards bypass indexes, enable ReDoS |

These limits are enforced at the **transport layer** (before reaching the adapter) via a validation pass over the `Condition` tree.

### Layer 4 — Tenant Isolation (RLS)

Even if a filter somehow bypassed all validation, database row-level security ensures results are scoped to the authenticated tenant. The tenant clause is injected by the infrastructure, not by the filter compiler.

### Layer 5 — Authorization

`AuthorizationPolicy.check()` runs before the query handler. If the principal lacks read permission on the resource, the query never executes.

---

## Nested Field Access

Document stores support nested paths. The DSL uses dot notation:

```json
{ "address.city": { "$eq": "Berlin" } }
```

Field path depth is limited (default: 3 levels) to prevent deep traversal abuse.

---

## Type Coercion Rules

JSON has limited types. The adapter must coerce values for comparison:

| JSON Type          | Coercion              | Example            |
| ------------------ | --------------------- | ------------------ |
| String             | text (no cast needed) | `"active"`         |
| Number (integer)   | integer               | `42`               |
| Number (float)     | numeric/decimal       | `3.14`             |
| Boolean            | boolean               | `true`             |
| null               | IS NULL               | `null`             |
| Timestamp (string) | timestamp             | `"2026-03-13T..."` |
| UUID (string)      | UUID                  | `"018e..."`        |

Timestamps and UUIDs are detected by format (RFC 3339, UUIDv7 pattern) and cast automatically. This avoids requiring clients to declare types explicitly.

---

## Sorting

Sorting uses a separate `sort` parameter (not part of the filter grammar):

```json
{
  "filters": { "status": "active" },
  "sort": [
    { "field": "created_at", "order": "desc" },
    { "field": "name", "order": "asc" }
  ],
  "cursor": null,
  "limit": 25
}
```

Sort fields must also be in the field whitelist. Default sort: `created_at DESC` (UUIDv7 `entity_id` is an acceptable fallback since it's time-ordered).

---

## Pagination

Cursor-based, not offset-based:

```
Page<T>:
    items:        List<T>
    next_cursor:  string?
    has_more:     boolean
```

The cursor is an opaque, base64-encoded token containing the last row's sort key(s). The adapter decodes it and adds a `WHERE (sort_key) > (cursor_value)` clause. Clients never see raw offsets or row IDs.

---

## What This DSL Does NOT Support (By Design)

| Feature                       | Why Excluded                                                                                          |
| ----------------------------- | ----------------------------------------------------------------------------------------------------- |
| Joins                         | Read models are pre-joined by projections. No cross-entity queries at read time.                      |
| Aggregations (`$sum`, `$avg`) | Aggregates are computed by dedicated projections, not ad-hoc queries.                                 |
| Subqueries                    | Closed grammar — no arbitrary nesting of query types.                                                 |
| `$regex` / `$like`            | Leading wildcards bypass indexes. ReDoS risk. Use full-text search (separate port) if needed.         |
| `$text` / full-text           | Separate concern. If needed, add a `SearchPort` backed by Postgres `tsvector` or Meilisearch.         |
| Projection (field selection)  | All fields are returned. Field-level access control is an authorization concern, not a query concern. |
