# Embedded Scripting

> Use a scripting language as a **declaration language** — users write rules/policies/transforms in a familiar syntax, the engine compiles them to a JSON/AST representation, and the native runtime evaluates the compiled output. The scripting language defines _what_, the core evaluates _how_.

---

## Pattern: Script Declares, Core Evaluates

```
User writes declaration          Engine compiles              Core evaluates
─────────────────────          ──────────────────             ──────────────
                                 ┌──────────┐     ┌──────────────────────────┐
  policy("order.cancel", ...) →  │ JSON AST  │  →  │ Native match on AST nodes│
  if (ctx.role >= Editor          │           │     │ No scripting at eval time│
      && ctx.resource.state       │           │     │ Pure data traversal      │
         !== "shipped") {         └──────────┘     └──────────────────────────┘
    return Allow;                      │                        │
  }                                    │     ┌──────────────────┘
  return Deny("already shipped");      ▼     ▼
                                 Stored in Postgres
                                 (JSONB column)
```

**Two execution models**:

| Model                     | How                                                                                               | Latency       | Safety                              | Best For                                                |
| ------------------------- | ------------------------------------------------------------------------------------------------- | ------------- | ----------------------------------- | ------------------------------------------------------- |
| **Compile-then-evaluate** | Script → JSON AST at write time. Core evaluates AST at runtime. No scripting engine at eval time. | ~microseconds | Highest — no code execution at eval | Authorization policies, validation rules, event routing |
| **Sandboxed execution**   | Script runs in sandboxed engine with memory + time limits at eval time.                           | ~0.1-1ms      | High — sandboxed, no I/O            | Projections, upcasters, complex transforms              |

### Production Validation

| Company                | Pattern                                                                  | Scale                        |
| ---------------------- | ------------------------------------------------------------------------ | ---------------------------- |
| **Shopify Functions**  | Merchants write scripting logic. Compiled to Wasm. Host executes.        | Millions of merchants        |
| **Cloudflare Workers** | Customer code runs in sandboxed isolates. 100-1000 isolates per process. | Millions of req/sec globally |
| **AWS LLRT**           | Lightweight scripting runtime with 10x faster cold start, 1/3 memory.    | Lambda at scale              |
| **Deno Deploy**        | Edge functions. Built on async runtime + scripting engine.               | Global edge network          |

---

## Use Cases

### 1. Authorization Policies — Compile-then-evaluate

> See **05-authorization.md** for the full authorization model. This section covers only the scripting mechanics.

Tenant admins write policies that compile to `PolicyAst`. The core evaluates the AST at request time with zero scripting overhead. Policy changes are domain events (`PolicyUpdatedEvent`) with full audit trail.

### 2. Projection Definitions — Sandboxed execution

```js
defineProjection("commerce.product.summary", {
  events: [
    "commerce.product.created",
    "commerce.product.updated",
    "commerce.product.archived",
  ],
  apply(state, event) {
    switch (event.action) {
      case "created":
        return {
          id: event.stream_id,
          name: event.payload.name,
          price_cents: event.payload.price_cents,
          currency: event.payload.currency,
          status: "active",
          created_at: event.created_at,
        };
      case "updated":
        return { ...state, ...event.payload, updated_at: event.created_at };
      case "archived":
        return { ...state, status: "archived", archived_at: event.created_at };
    }
  },
});
```

**Execution**: Sandboxed scripting engine runs the `apply()` function with:

- 10 MB memory limit
- 50ms timeout per event
- No I/O (no fetch, no filesystem, no imports)
- Only the event and current state are passed in

Adding a new read model = inserting a projection definition. No recompilation, no redeployment. The projection worker loads definitions from DB and applies them.

### 3. Upcaster Definitions — Compile-then-evaluate

```js
defineUpcaster("commerce.product.created", 1, 2, (payload) => {
  payload.currency = payload.currency || "USD";
  return payload;
});

defineUpcaster("commerce.product.created", 2, 3, (payload) => {
  payload.tax_rate = payload.tax_rate ?? 0;
  payload.price = { amount: payload.price_cents, currency: payload.currency };
  delete payload.price_cents;
  delete payload.currency;
  return payload;
});
```

**Compiles to** (JSON transform operations):

```json
[
  {
    "event": "commerce.product.created",
    "from": 1,
    "to": 2,
    "ops": [{ "op": "set_default", "field": "currency", "value": "USD" }]
  },
  {
    "event": "commerce.product.created",
    "from": 2,
    "to": 3,
    "ops": [
      { "op": "set_default", "field": "tax_rate", "value": 0 },
      {
        "op": "restructure",
        "field": "price",
        "value": { "amount": "$price_cents", "currency": "$currency" }
      },
      { "op": "remove", "field": "price_cents" },
      { "op": "remove", "field": "currency" }
    ]
  }
]
```

The core evaluates the ops list natively — no scripting at runtime. Transform operations are a closed set (`set_default`, `rename`, `remove`, `restructure`, `copy`, `cast`).

### 4. Validation Rules — Compile-then-evaluate

```js
defineValidation("commerce.order.create", (cmd) => {
  require(cmd.items.length > 0, "Order must have at least one item");
  require(cmd.items.length <= 100, "Maximum 100 items per order");
  require(cmd.total_cents > 0, "Total must be positive");
  require(cmd.total_cents <= 10_000_00, "Orders over $10,000 require approval");
});
```

Compiles to constraint list — core evaluates constraints against command payload.

### 5. Event Routing / Subscription Filters — Compile-then-evaluate

```js
defineFilter("analytics-worker", (event) => {
  return (
    event.domain === "commerce" &&
    event.action !== "viewed" &&
    event.tenant_id !== "test-tenant-000"
  );
});
```

Compiles to a `PredicateAst` — evaluated at relay time to decide which events go to which stream.

### 6. Process Manager / Workflow Definitions — Sandboxed execution

```js
defineWorkflow("order-fulfillment", {
  initial: "awaiting_payment",
  states: {
    awaiting_payment: {
      on: {
        "payment.charged": "awaiting_inventory",
        "payment.failed": { target: "cancelled", compensate: ["refund"] },
      },
    },
    awaiting_inventory: {
      on: {
        "inventory.reserved": "awaiting_shipment",
        "inventory.insufficient": {
          target: "refunding",
          compensate: ["release_payment"],
        },
      },
      timeout: {
        after: "24h",
        goto: "cancelled",
        compensate: ["release_payment"],
      },
    },
  },
});
```

Essentially a JSON state machine definition with scripting as the authoring syntax. Compiles to a state table that the core traverses.

### What NOT to Use Embedded Scripting For

| Don't Use Scripting For                    | Why                                                            | Use Instead                |
| ------------------------------------------ | -------------------------------------------------------------- | -------------------------- |
| **Domain aggregate logic** (decide/evolve) | Core business rules must be compile-time verified              | Native domain code         |
| **Event store operations**                 | Critical path, must be as fast as possible                     | Native + database directly |
| **Tenant isolation / RLS**                 | Security-critical infrastructure. Must be enforced at DB level | Postgres RLS               |
| **Cryptographic operations**               | Must use audited crypto libraries. Never in scripting          | Audited crypto libraries   |
| **Transport layer (HTTP/gRPC)**            | Performance-critical, connection-management                    | Native server framework    |

**Rule of thumb**: If it's on the **write path** or **security boundary**, it stays native. If it's a **configurable rule** that changes per tenant or per deployment, it's a candidate for scripting declaration.

---

## ScriptCompiler Port

Full interface defined in **02-ports.md** (Port 17).

```
interface ScriptCompiler:
    compile_policy(source)     → PolicyAst
    compile_projection(source) → ProjectionDef
    compile_upcaster(source)   → List<TransformOp>
    compile_validation(source) → List<Constraint>
    compile_filter(source)     → PredicateAst
```

### Architecture: Where the Scripting Engine Fits

```
┌──────────────────────────────────────────────────────────────────┐
│ ADMIN / DEVELOPER writes declarations                             │
│ (policy editor, projection builder, upcaster definer)            │
└──────────────────────┬───────────────────────────────────────────┘
                       │
                       ▼
┌──────────────────────────────────────────────────────────────────┐
│ COMPILATION LAYER (sandboxed engine — runs ONCE at definition)   │
│                                                                  │
│ Source → parse + evaluate → JSON AST / Op List                   │
│                                                                  │
│ Validation:                                                      │
│   - Only allowed built-in functions (allow, deny, require, etc.) │
│   - No I/O, no imports, no eval()                                │
│   - Memory limit: 10 MB, time limit: 100ms                      │
│   - Output must conform to AST schema                            │
└──────────────────────┬───────────────────────────────────────────┘
                       │
                       ▼
┌──────────────────────────────────────────────────────────────────┐
│ STORAGE (Postgres — JSONB column)                                │
│                                                                  │
│ policies table:     (tenant_id, resource, version, ast JSONB)    │
│ projections table:  (name, version, definition JSONB)            │
│ upcasters table:    (domain, entity, action, from_v, ops JSONB)  │
│ validations table:  (tenant_id, command, version, rules JSONB)   │
│ filters table:      (consumer_name, version, predicate JSONB)    │
└──────────────────────┬───────────────────────────────────────────┘
                       │
                       ▼
┌──────────────────────────────────────────────────────────────────┐
│ EVALUATION LAYER (native runtime — runs on EVERY request/event)  │
│                                                                  │
│ Load JSON AST from Postgres (cached in Redis)                    │
│ Evaluator walks the AST nodes:                                   │
│   - PolicyEvaluator.evaluate(ast, context) → Decision            │
│   - ProjectionEvaluator.apply(ast, state, event) → new_state    │
│   - UpcasterEvaluator.transform(ops, payload) → new_payload     │
│   - ValidationEvaluator.check(rules, command) → Result           │
│   - FilterEvaluator.matches(predicate, event) → boolean          │
│                                                                  │
│ No scripting engine at eval time. Pure data traversal.           │
└──────────────────────────────────────────────────────────────────┘
```

---

## Security Model

### Compilation Sandbox

| Limit  | Value | Purpose                                 |
| ------ | ----- | --------------------------------------- |
| Memory | 10 MB | Prevent resource exhaustion             |
| Time   | 100ms | Prevent infinite loops                  |
| Stack  | 1 MB  | Prevent stack overflow                  |
| I/O    | None  | No filesystem, network, process globals |

### API Surface Whitelist

Only these globals are registered in the scripting context: `allow()`, `deny()`, `require()`, `definePolicy()`, `defineProjection()`, `defineUpcaster()`, `defineValidation()`, `defineFilter()`, `defineWorkflow()`. No fetch, filesystem, require, eval, or dynamic code construction.

### AST Validation

| Validation              | Limit | Purpose                              |
| ----------------------- | ----- | ------------------------------------ |
| Max depth               | 10    | Prevent stack overflow in evaluator  |
| Max node count          | 500   | Prevent memory exhaustion            |
| Max total bytes         | 64 KB | Prevent storage abuse                |
| Field whitelist         | —     | Only allowed fields                  |
| Operator whitelist      | —     | Only allowed operators               |
| Max string length       | 1000  | Prevent large string literals        |
| Determinism requirement | —     | Reject time-based, random conditions |

### Deserialization Hardening

All AST types must reject unexpected fields during deserialization. This prevents unknown field injection attacks where an attacker adds extra fields to stored data that bypass validation.

### Scope Validation

Tenant-defined rules that reference other tenants' resources enable horizontal privilege escalation. Every AST field reference must be validated against the tenant's accessible scope.

### AST Signing: HMAC-SHA256

AST is signed at compile time with HMAC-SHA256. Before evaluation, the signature is verified to detect tampering in storage.

### Scripting Engine CVE Exposure

Any embedded scripting engine has ongoing security vulnerabilities. Required hardening:

| Layer                 | Protection                                              |
| --------------------- | ------------------------------------------------------- |
| **Minimum version**   | Pin to latest patched version in dependency manifest    |
| **Memory limits**     | Configure engine memory ceiling                         |
| **CPU limits**        | Configure interrupt handler with timeout                |
| **Stack limits**      | Configure max stack size                                |
| **No I/O**            | Don't register any I/O functions                        |
| **Process isolation** | Run compilation in separate process with syscall filter |
| **CVE monitoring**    | Automated dependency scanning in CI/CD                  |

### Decision Tree: When to Use Each Execution Model

```
                    ┌─────────────────────────────────┐
                    │ Does the rule change per-tenant  │
                    │ or per-deployment?               │
                    └──────────┬──────────────────────┘
                               │
                    ┌──────────▼──────────┐
                    │        YES          │
                    └──────────┬──────────┘
                               │
              ┌────────────────▼────────────────┐
              │ Can the logic be expressed as    │
              │ conditions + outcomes (no loops, │
              │ no async, no side effects)?      │
              └───────┬──────────────┬──────────┘
                      │              │
               ┌──────▼──────┐ ┌────▼──────────────┐
               │     YES     │ │        NO          │
               └──────┬──────┘ └────┬──────────────┘
                      │             │
          ┌───────────▼──────┐  ┌──▼──────────────────┐
          │ COMPILE TO AST   │  │ SANDBOXED EXECUTION  │
          │ (script at write,│  │ (engine at eval,     │
          │  native at eval) │  │  mem + time limits)  │
          │                  │  │                      │
          │ • Policies       │  │ • Complex projections│
          │ • Validations    │  │ • Custom transforms  │
          │ • Filters        │  │ • Workflow guards     │
          │ • Simple upcasts │  │ • Rich upcasters     │
          └──────────────────┘  └──────────────────────┘

                    ┌──────────▼──────────┐
                    │        NO           │
                    │ (static logic)      │
                    └──────────┬──────────┘
                               │
                    ┌──────────▼──────────┐
                    │ NATIVE CODE         │
                    │ (compiled, typed)   │
                    │                     │
                    │ • Aggregates        │
                    │ • Command handlers  │
                    │ • Port interfaces   │
                    │ • Transport layer   │
                    └─────────────────────┘
```

### Full Security Model

| Layer                         | Threat                              | Protection                                                   |
| ----------------------------- | ----------------------------------- | ------------------------------------------------------------ |
| **Compilation sandbox**       | Resource exhaustion, code injection | Memory 10MB, time 100ms, stack 1MB, no I/O                   |
| **API surface**               | Unauthorized globals                | Whitelist: allow, deny, require, definePolicy, etc.          |
| **Output validation**         | Malicious AST bypass                | Depth, node count, size, field whitelist, operator whitelist |
| **Scope validation**          | Cross-tenant access                 | AST references validated against tenant's plan scope         |
| **AST integrity**             | Storage tampering                   | HMAC-SHA256 signature on AST at compile time                 |
| **Deserialization hardening** | Unknown field injection             | Reject unknown fields on all AST types                       |
| **Evaluation safety**         | No scripting at eval time           | Architecture (compile-then-evaluate)                         |
| **Tenant isolation**          | Horizontal escalation               | Database RLS + composite keys + scope validation             |
| **Cache consistency**         | TOCTOU race condition               | Version-stamped snapshots + tiered consistency               |
| **Audit logging**             | Undetected access violations        | All auth decisions logged, alert on patterns                 |
| **Deny-by-default**           | Missing access checks               | Explicit deny at every layer, no implicit allows             |
| **CVE monitoring**            | Engine vulnerabilities              | Dependency scanning in CI, minimum version pinning           |
| **Process isolation**         | Engine escape                       | Syscall filter for compilation process (Phase 2)             |

**The key insight**: By compiling scripts to a **closed set of operations** (Condition, TransformOp, etc.), you get the **developer experience of a scripting language** with the **safety of a restricted DSL**. The scripting engine is a compiler, not a runtime.

---

## Technology Stack Impact

| Concern                    | Technology                 | When Scripting Runs                               |
| -------------------------- | -------------------------- | ------------------------------------------------- |
| **Policy storage**         | Postgres (JSONB)           | Never (compiled AST stored)                       |
| **Policy compilation**     | Sandboxed scripting engine | Once (at write time)                              |
| **Policy evaluation**      | Native AST walker          | Every request (microseconds)                      |
| **Policy caching**         | Redis                      | Every request (avoid Postgres round-trip)         |
| **Projection definitions** | Postgres (JSONB)           | Never (compiled definition stored)                |
| **Projection execution**   | Sandboxed OR native AST    | Per event (sandboxed: ~0.1ms, AST: ~microseconds) |
| **Upcaster definitions**   | Postgres (JSONB ops list)  | Never (compiled ops stored)                       |
| **Upcaster execution**     | Native op list walker      | Per event load (microseconds)                     |

**Infrastructure footprint stays the same**: Postgres + Redis + Zitadel + Stripe. The scripting engine is a library dependency, not a service. Zero infrastructure impact.
