# Embedded Scripting (rquickjs) — Where It Makes Sense

> **Core idea**: Use JavaScript (via rquickjs/QuickJS) as a **declaration language** — users write rules/policies/transforms in JS, the engine compiles them to a JSON/AST representation, and Rust evaluates the compiled output. JS defines _what_, Rust executes _how_.

---

## The Pattern: JS Declares, Rust Executes

```
User writes JS declaration          rquickjs compiles             Rust evaluates
─────────────────────────          ──────────────────             ──────────────

policy("order.cancel", (ctx) => {     ┌──────────┐     ┌──────────────────────────┐
  if (ctx.role >= Role.Editor         │ JSON AST  │     │ Rust match on AST nodes  │
      && ctx.resource.state           │ / Bytecode│     │ No JS runtime at eval    │
         !== "shipped") {             │           │     │ Pure data traversal      │
    return Allow;                     └──────────┘     └──────────────────────────┘
  }                                        │                        │
  return Deny("already shipped");          │     ┌──────────────────┘
});                                        ▼     ▼
                                    Stored in Postgres
                                    (JSONB or BYTEA)
```

**Two execution models**:

| Model                     | How                                                                                    | Latency       | Safety                              | Best For                                                |
| ------------------------- | -------------------------------------------------------------------------------------- | ------------- | ----------------------------------- | ------------------------------------------------------- |
| **Compile-then-evaluate** | JS → JSON AST at write time. Rust evaluates AST at runtime. No JS engine at eval time. | ~microseconds | Highest — no code execution at eval | Authorization policies, validation rules, event routing |
| **Sandboxed execution**   | JS runs in rquickjs with memory + time limits at eval time.                            | ~0.1-1ms      | High — sandboxed, no I/O            | Projections, upcasters, complex transforms              |

---

## Production Validation

This isn't theoretical. Companies run embedded JS at massive scale:

| Company                | Engine                | Pattern                                                                          | Scale                        |
| ---------------------- | --------------------- | -------------------------------------------------------------------------------- | ---------------------------- |
| **Shopify Functions**  | QuickJS → Javy (Wasm) | Merchants write JS discount/payment logic. Compiled to Wasm. Rust host executes. | Millions of merchants        |
| **Cloudflare Workers** | V8 isolates           | Customer code runs in sandboxed JS. 100-1000 isolates per process.               | Millions of req/sec globally |
| **AWS LLRT**           | QuickJS               | Lambda functions with 10x faster cold start, 1/3 memory vs Node.js.              | AWS Lambda at scale          |
| **Deno Deploy**        | V8 + deno_core        | Edge functions in TypeScript/JS. Built on Rust (tokio + rusty_v8).               | Global edge network          |

**rquickjs specifically**: < 1ms startup, 210 KiB memory footprint, ES2020 compliant, 77K test suite passes. QuickJS itself is battle-tested (Bellard).

---

## Where Embedded JS Adds Value in This System

### 1. Authorization Policies — **Best fit (compile-then-evaluate)**

Instead of hardcoding `PgAuthorizationPolicy` SQL queries or deploying Cerbos, let tenants/admins define policies in JS that compile to evaluable JSON:

```javascript
// Tenant admin writes this in a policy editor UI
definePolicy("commerce.order.cancel", (ctx) => {
  // TenantRole hierarchy check
  if (ctx.principal.tenantRole >= TenantRole.Editor) {
    // Resource state check
    if (ctx.resource.state === "shipped") {
      return deny("Cannot cancel shipped orders");
    }
    return allow();
  }
  return deny("Insufficient role");
});
```

**At write time** (rquickjs compiles to JSON AST):

```json
{
  "type": "policy",
  "resource": "commerce.order.cancel",
  "version": 2,
  "rules": [
    {
      "condition": {
        "op": "gte",
        "field": "principal.tenant_role",
        "value": "editor"
      },
      "then": [
        {
          "condition": {
            "op": "eq",
            "field": "resource.state",
            "value": "shipped"
          },
          "then": {
            "decision": "deny",
            "reason": "Cannot cancel shipped orders"
          },
          "else": { "decision": "allow" }
        }
      ],
      "else": { "decision": "deny", "reason": "Insufficient role" }
    }
  ]
}
```

**At eval time** (Rust evaluates JSON — no JS engine needed):

```rust
pub fn evaluate_policy(policy: &PolicyAst, ctx: &EvalContext) -> Decision {
    for rule in &policy.rules {
        if evaluate_condition(&rule.condition, ctx) {
            return match &rule.then {
                RuleOutcome::Decision(d) => d.clone(),
                RuleOutcome::Nested(rules) => evaluate_rules(rules, ctx),
            };
        } else if let Some(else_branch) = &rule.else_branch {
            return evaluate_outcome(else_branch, ctx);
        }
    }
    Decision::Deny { reason: "no matching rule".into() }
}
```

**Why this is better than raw SQL or Cerbos**:

- Policies are **versioned and stored as events** (`PolicyUpdatedEvent`) — full audit trail
- No external service (Cerbos/Cedar/OpenFGA) — just Postgres + the compiled JSON
- Tenants can customize policies **without redeployment** and without access to Rust code
- The compiled AST is a **subset of operations** — no arbitrary code execution at eval time
- Policy evaluation is **pure Rust data traversal** — microsecond latency, fully cacheable in Redis

### 2. Projection Definitions — **Good fit (sandboxed execution)**

Let developers define how events transform into read models without recompiling:

```javascript
// Projection definition stored in DB
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

**Execution**: rquickjs runs the `apply()` function in a sandboxed context with:

- 10 MB memory limit
- 50ms timeout per event
- No I/O (no `fetch`, no `fs`, no `require`)
- Only the event and current state are passed in

**Why useful**: Adding a new read model = inserting a projection definition. No Rust code, no recompilation, no redeployment. The projection worker loads definitions from DB and applies them.

### 3. Upcaster Definitions — **Good fit (compile-then-evaluate)**

Schema evolution rules as JS declarations that compile to transform operations:

```javascript
// Upcaster definition
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

Rust evaluates the ops list — no JS at runtime. Transform operations are a closed set (`set_default`, `rename`, `remove`, `restructure`, `copy`, `cast`).

### 4. Validation Rules — **Good fit (compile-then-evaluate)**

Business validation rules that change per tenant without redeployment:

```javascript
// Per-tenant validation rules
defineValidation("commerce.order.create", (cmd) => {
  require(cmd.items.length > 0, "Order must have at least one item");
  require(cmd.items.length <= 100, "Maximum 100 items per order");
  require(cmd.total_cents > 0, "Total must be positive");
  require(cmd.total_cents <= 10_000_00, "Orders over $10,000 require approval");
});
```

Compiles to constraint list → Rust evaluates constraints against command payload.

### 5. Event Routing / Subscription Filters — **Good fit (compile-then-evaluate)**

Dynamic subscription filters for polyglot workers:

```javascript
// Worker subscription filter
defineFilter("analytics-worker", (event) => {
  return (
    event.domain === "commerce" &&
    event.action !== "viewed" && // skip high-volume view events
    event.tenant_id !== "test-tenant-000"
  );
});
```

Compiles to a predicate AST → Rust evaluates at relay time to decide which events go to which Redis Stream.

### 6. Process Manager / Workflow Definitions — **Possible fit (sandboxed execution)**

State machine definitions in JS:

```javascript
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
    // ...
  },
});
```

This is essentially a JSON state machine definition with JS as the authoring syntax. Compiles to a state table that Rust traverses.

---

## What NOT to Use Embedded JS For

| Don't Use JS For                           | Why                                                                                 | Use Instead                                   |
| ------------------------------------------ | ----------------------------------------------------------------------------------- | --------------------------------------------- |
| **Domain aggregate logic** (decide/evolve) | Core business rules must be compile-time verified. Typestate pattern requires Rust. | Rust (the whole point of the Decider pattern) |
| **Event store operations**                 | Critical path, must be as fast as possible. No scripting overhead.                  | Rust + sqlx directly                          |
| **Tenant isolation / RLS**                 | Security-critical infrastructure. Must be enforced at DB level.                     | Postgres RLS                                  |
| **Cryptographic operations**               | Must use audited Rust crates (ring, rustcrypto). Never implement crypto in JS.      | Rust                                          |
| **gRPC/HTTP transport**                    | Performance-critical, connection-management. No JS overhead.                        | tonic / axum                                  |

**Rule of thumb**: If it's on the **write path** or **security boundary**, it stays in Rust. If it's a **configurable rule** that changes per tenant or per deployment, it's a candidate for JS declaration.

---

## rquickjs vs Alternatives

| Engine                 | Startup   | Memory        | Safety                          | JS Spec              | Best For                              |
| ---------------------- | --------- | ------------- | ------------------------------- | -------------------- | ------------------------------------- |
| **rquickjs (QuickJS)** | < 1ms     | 210 KiB       | Sandboxable (mem + time limits) | ES2020               | Compile-time declarations, light eval |
| **boa**                | Slower    | Higher        | Pure Rust (no FFI)              | ~90% ES2020          | When you want zero C dependencies     |
| **rusty_v8**           | ~50-100ms | Higher        | V8 isolates                     | Full ES2023+         | Heavy compute, JIT needed             |
| **mlua (Lua)**         | < 1ms     | Lower than JS | Excellent sandbox               | Lua 5.x / Luau       | Simpler syntax, game-engine heritage  |
| **Wasm (wasmtime)**    | ~1-5ms    | Configurable  | Best (capability-based)         | N/A (compile target) | Untrusted third-party code            |

**Recommendation: rquickjs** for this system because:

1. JS is the most widely known language — lowest barrier for policy authors
2. < 1ms startup means you can create/destroy contexts per-request if needed
3. The compile-then-evaluate pattern means JS only runs at **definition time**, not eval time
4. ES2020 is enough for declarations (arrow functions, destructuring, optional chaining)
5. Shopify validates this exact pattern at merchant scale (QuickJS for function definitions)

---

## Architecture: Where rquickjs Fits

```
┌──────────────────────────────────────────────────────────────────┐
│ ADMIN / DEVELOPER writes JS declarations                         │
│ (policy editor, projection builder, upcaster definer)           │
└──────────────────────┬───────────────────────────────────────────┘
                       │
                       ▼
┌──────────────────────────────────────────────────────────────────┐
│ COMPILATION LAYER (rquickjs — runs ONCE at definition time)     │
│                                                                  │
│ JS source → rquickjs parse + evaluate → JSON AST / Op List      │
│                                                                  │
│ Validation:                                                      │
│   - Only allowed built-in functions (allow, deny, require, etc.) │
│   - No I/O, no imports, no eval()                                │
│   - Memory limit: 10 MB, time limit: 100ms                      │
│   - Output must be valid JSON AST conforming to schema           │
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
│ EVALUATION LAYER (Pure Rust — runs on EVERY request/event)      │
│                                                                  │
│ Load JSON AST from Postgres (cached in Redis)                    │
│ Rust evaluator walks the AST nodes:                              │
│   - PolicyEvaluator::evaluate(ast, context) → Decision           │
│   - ProjectionEvaluator::apply(ast, state, event) → new_state   │
│   - UpcasterEvaluator::transform(ops, payload) → new_payload    │
│   - ValidationEvaluator::check(rules, command) → Result          │
│   - FilterEvaluator::matches(predicate, event) → bool           │
│                                                                  │
│ No JS engine at eval time. Pure data traversal. Microseconds.    │
└──────────────────────────────────────────────────────────────────┘
```

---

## New Port: ScriptCompiler

```rust
// ─── Port: Script Compiler ──────────────────────────────────────
// Compiles JS declarations into evaluable JSON AST.
// Runs ONLY at definition time (admin writes/updates a rule).
// The compiled AST is stored in Postgres and evaluated by pure Rust.
//
// Adapters: RquickjsCompiler (production), MockCompiler (tests)
//
// Security:
//   - Memory limit per compilation (10 MB)
//   - Time limit per compilation (100ms)
//   - No I/O, no network, no filesystem
//   - Only whitelisted global functions (allow, deny, require, etc.)
//   - Output validated against AST JSON Schema before storage

#[async_trait]
pub trait ScriptCompiler: Send + Sync {
    /// Compile a JS policy declaration to a PolicyAst.
    fn compile_policy(&self, source: &str) -> Result<PolicyAst>;

    /// Compile a JS projection definition to a ProjectionDef.
    fn compile_projection(&self, source: &str) -> Result<ProjectionDef>;

    /// Compile a JS upcaster to a list of transform operations.
    fn compile_upcaster(&self, source: &str) -> Result<Vec<TransformOp>>;

    /// Compile a JS validation rule to a constraint list.
    fn compile_validation(&self, source: &str) -> Result<Vec<Constraint>>;

    /// Compile a JS filter predicate to a predicate AST.
    fn compile_filter(&self, source: &str) -> Result<PredicateAst>;
}
```

```rust
// ─── Compiled types (pure Rust, no JS dependency) ───────────────

/// A compiled authorization policy — evaluable without JS.
#[derive(Serialize, Deserialize)]
pub struct PolicyAst {
    pub resource: String,
    pub version: i32,
    pub rules: Vec<PolicyRule>,
}

#[derive(Serialize, Deserialize)]
pub struct PolicyRule {
    pub condition: Condition,
    pub then: RuleOutcome,
    pub else_branch: Option<RuleOutcome>,
}

#[derive(Serialize, Deserialize)]
pub enum Condition {
    Eq { field: String, value: JsonValue },
    Neq { field: String, value: JsonValue },
    Gt { field: String, value: JsonValue },
    Gte { field: String, value: JsonValue },
    Lt { field: String, value: JsonValue },
    Lte { field: String, value: JsonValue },
    In { field: String, values: Vec<JsonValue> },
    Contains { field: String, value: JsonValue },
    And(Vec<Condition>),
    Or(Vec<Condition>),
    Not(Box<Condition>),
}

#[derive(Serialize, Deserialize)]
pub enum RuleOutcome {
    Allow,
    Deny { reason: String },
    Nested(Vec<PolicyRule>),
}

/// A compiled transform operation for upcasters.
#[derive(Serialize, Deserialize)]
pub enum TransformOp {
    SetDefault { field: String, value: JsonValue },
    Rename { from: String, to: String },
    Remove { field: String },
    Restructure { field: String, template: JsonValue },
    Copy { from: String, to: String },
    Cast { field: String, to_type: String },
}

/// A compiled predicate for event filtering.
#[derive(Serialize, Deserialize)]
pub struct PredicateAst {
    pub condition: Condition,  // reuses the same Condition enum
}
```

---

## Postgres + Redis + rquickjs = Full Stack

Adding rquickjs to the Postgres + Redis stack from the simplification analysis:

| Concern                    | Technology                              | When JS Runs                                      |
| -------------------------- | --------------------------------------- | ------------------------------------------------- |
| **Policy storage**         | Postgres (JSONB)                        | Never (compiled AST stored)                       |
| **Policy compilation**     | rquickjs                                | Once (at write time)                              |
| **Policy evaluation**      | Rust (AST walker)                       | Every request (microseconds)                      |
| **Policy caching**         | Redis                                   | Every request (avoid Postgres round-trip)         |
| **Projection definitions** | Postgres (JSONB)                        | Never (compiled definition stored)                |
| **Projection execution**   | rquickjs (sandboxed) OR Rust AST walker | Per event (sandboxed: ~0.1ms, AST: ~microseconds) |
| **Upcaster definitions**   | Postgres (JSONB ops list)               | Never (compiled ops stored)                       |
| **Upcaster execution**     | Rust (op list walker)                   | Per event load (microseconds)                     |

**Infrastructure footprint stays the same**: Postgres + Redis + Zitadel + Stripe. rquickjs is a Rust library dependency (`Cargo.toml`), not a service.

---

## When to Use Each Execution Model

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
          │ (JS at write,    │  │ (rquickjs at eval,   │
          │  Rust at eval)   │  │  mem + time limits)  │
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
                    │ PURE RUST           │
                    │ (compiled, typed)   │
                    │                     │
                    │ • Aggregates        │
                    │ • Command handlers  │
                    │ • Port traits       │
                    │ • Transport layer   │
                    └─────────────────────┘
```

---

## Security Model

| Layer                   | Protection                                                          | Enforced By                             |
| ----------------------- | ------------------------------------------------------------------- | --------------------------------------- |
| **Compilation sandbox** | Memory: 10 MB, Time: 100ms, No I/O                                  | rquickjs runtime limits                 |
| **API surface**         | Only `allow()`, `deny()`, `require()`, `definePolicy()`, etc.       | Whitelisted globals in rquickjs context |
| **Output validation**   | Compiled AST must conform to JSON Schema                            | Rust validation before storage          |
| **Evaluation safety**   | No JS engine at eval time — pure Rust data traversal                | Architecture (compile-then-evaluate)    |
| **Tenant isolation**    | Compiled policies scoped by `tenant_id` in Postgres (RLS)           | Postgres RLS + application layer        |
| **Versioning**          | Policy changes are events (`PolicyUpdatedEvent`) — full audit trail | Event sourcing                          |

**The key insight**: By compiling JS to a **closed set of operations** (Condition, TransformOp, etc.), you get the **developer experience of a scripting language** with the **safety of a restricted DSL**. The JS engine is a compiler, not a runtime.
