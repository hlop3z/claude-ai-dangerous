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

---

## Multi-System Architecture: SYS | PIM | DAM | CMS | CRM | ERP | POS

The platform manages **7 subsystems**, each owning specific domain entities:

```
┌────────┬────────┬────────┬────────┬────────┬────────┬────────┐
│  SYS   │  PIM   │  DAM   │  CMS   │  CRM   │  ERP   │  POS   │
│ ────── │ ────── │ ────── │ ────── │ ────── │ ────── │ ────── │
│ auth   │product │ media  │  gui   │contact │ order  │  shop  │
│session │catalog │ asset  │  view  │  lead  │invoice │        │
│        │        │        │  page  │        │        │        │
└────────┴────────┴────────┴────────┴────────┴────────┴────────┘
```

Each subsystem is a **domain** in the event store's SOC columns (`stream_domain`). Each entity is a `stream_entity`. This maps directly to the namespaced type system: `pim.product.created`, `erp.order.placed`, `cms.page.published`.

---

## Two-Layer Rule System: System-Defined + Tenant-Defined

Rules come from two sources with different lifecycles:

```
┌──────────────────────────────────────────────────────────────────┐
│ LAYER 1: SYSTEM-DEFINED (built by our devs)                      │
│ ──────────────────────────────────────────────────────────────── │
│ • Ships with the platform binary (compiled into Rust)            │
│ • Defines the base ACS model (actions 0-6, roles 0-6)           │
│ • Defines default permissions per subsystem/entity               │
│ • Defines core business rules (aggregate invariants)             │
│ • Changes require deployment                                     │
│ • Written in Rust OR JS that compiles at build time              │
│                                                                  │
│ Source: code repo → compiled into binary / seed data             │
├──────────────────────────────────────────────────────────────────┤
│ LAYER 2: TENANT-DEFINED (configured by tenant admins)            │
│ ──────────────────────────────────────────────────────────────── │
│ • Stored in Postgres per tenant (JSONB, RLS-isolated)            │
│ • Overrides/extends system defaults (never weakens them)         │
│ • Custom validation rules, workflow tweaks, field policies       │
│ • Changes take effect immediately (no deployment)                │
│ • Written in JS via admin UI → compiled to AST by rquickjs       │
│                                                                  │
│ Source: admin UI → rquickjs compile → Postgres → Redis cache     │
└──────────────────────────────────────────────────────────────────┘

Evaluation order:
  1. System rules run first (Rust, hardcoded floor)
  2. Tenant rules layer on top (can restrict further, NEVER grant more)
  3. Final decision = min(system_grant, tenant_grant)
```

---

## Access Control System (ACS) — Numeric Model

### Actions (Ordered, 0-6)

```rust
/// Actions are ordered integers. Higher includes all lower.
/// Checking permission = comparing action level to granted level.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[repr(u8)]
pub enum AcsAction {
    Public = 0,   // no access required
    Filter = 1,   // read / list / search
    Create = 2,   // create new entities
    Update = 3,   // modify existing entities
    Delete = 4,   // soft-delete (recoverable)
    Remove = 5,   // hard-delete (permanent)
    Assign = 6,   // transfer ownership
}
```

### Roles (Ordered, 0-6) — Map to Action Sets

```rust
/// Roles are ordered. Each role grants all actions up to its level.
/// Role::Editor (3) grants: Filter(1), Create(2), Update(3).
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[repr(u8)]
pub enum AcsRole {
    Public = 0,   // actions: []
    Viewer = 1,   // actions: [Filter]
    Creator = 2,  // actions: [Filter, Create]
    Editor = 3,   // actions: [Filter, Create, Update]
    Admin = 4,    // actions: [Filter, Create, Update, Delete]
    Member = 5,   // actions: [Filter, Create, Update, Delete, Remove]
    Owner = 6,    // actions: [Filter, Create, Update, Delete, Remove, Assign]
}

impl AcsRole {
    /// Check if this role grants the given action.
    /// Because both are ordered, this is a single integer comparison.
    pub fn can(&self, action: AcsAction) -> bool {
        (*self as u8) >= (action as u8)
    }
}
```

**The elegance**: Permission check = `role >= action`. No bitfields, no permission sets to iterate, no set intersection. One integer comparison. O(1).

### Permission Snapshot (Per-User, Per-Tenant)

A user's permissions are a map of `system.entity → granted_role_level`:

```rust
/// A user's permission snapshot within a tenant.
/// Maps (system, entity) → max granted role level.
/// Stored as JSONB in Postgres, cached in Redis.
#[derive(Debug, Serialize, Deserialize)]
pub struct PermissionSnapshot {
    pub tenant_id: Uuid,
    pub user_id: Uuid,
    pub grants: HashMap<String, HashMap<String, AcsRole>>,
    // e.g. { "cms": { "gui": Owner, "view": Owner, "page": Owner },
    //        "pim": { "product": Viewer },
    //        "erp": { "order": Admin } }
    pub computed_at: DateTime<Utc>,  // RFC 3339 UTC
}

impl PermissionSnapshot {
    /// Check: can this user perform `action` on `system.entity`?
    pub fn check(&self, system: &str, entity: &str, action: AcsAction) -> Decision {
        match self.grants.get(system).and_then(|s| s.get(entity)) {
            Some(role) if role.can(action) => Decision::Allow,
            Some(_) => Decision::Deny {
                reason: format!("Insufficient role for {}.{}", system, entity),
            },
            None => Decision::Deny {
                reason: format!("No access to {}.{}", system, entity),
            },
        }
    }
}
```

### How It Maps to the AuthorizationPolicy Port

```rust
pub struct AcsAuthorizationPolicy {
    pool: PgPool,
    cache: Arc<dyn Cache>,
}

#[async_trait]
impl AuthorizationPolicy for AcsAuthorizationPolicy {
    async fn check(
        &self, principal: &Principal, action: &Action, resource: &Resource,
    ) -> Result<Decision> {
        // 1. Load permission snapshot (Redis cache → Postgres fallback)
        let snapshot = self.load_snapshot(principal.tenant_id, principal.sub).await?;

        // 2. Map abstract Action to AcsAction
        let acs_action = match action {
            Action::Read => AcsAction::Filter,
            Action::Write => AcsAction::Update,    // or Create depending on context
            Action::Delete => AcsAction::Delete,
            Action::ManageMembers => AcsAction::Assign,
            _ => AcsAction::Update,
        };

        // 3. Extract system + entity from resource
        let (system, entity) = match resource {
            Resource::Aggregate { domain, entity, .. } => (domain.as_str(), entity.as_str()),
            Resource::ReadModel { domain, entity, .. } => (domain.as_str(), entity.as_str()),
            Resource::Domain { name } => (name.as_str(), "*"),
            _ => return Ok(Decision::Deny { reason: "Unknown resource".into() }),
        };

        // 4. Check: role >= action (single integer comparison)
        Ok(snapshot.check(system, entity, acs_action))
    }
}
```

**No Cerbos. No Cedar. No OpenFGA. One integer comparison.**

---

## System-Defined Defaults (Layer 1 — Ships With Platform)

The platform ships with **default permission templates** per subsystem. These are seed data loaded at startup or migration:

```rust
// seed/default_permissions.rs — compiled into the binary

/// Default permission template for new tenants.
/// Tenant admins can restrict these further but NEVER grant more
/// than the system default for their plan.
pub fn default_permissions(plan: &TenantPlan) -> HashMap<String, HashMap<String, AcsRole>> {
    let mut grants = HashMap::new();

    // Every plan gets these minimums
    grants.insert("sys".into(), hashmap! {
        "auth" => AcsRole::Public,     // auth endpoints are public
        "session" => AcsRole::Viewer,  // users can view own session
    });

    match plan {
        TenantPlan::Starter => {
            grants.insert("pim".into(), hashmap! { "product" => AcsRole::Editor });
            grants.insert("dam".into(), hashmap! { "media" => AcsRole::Creator });
            grants.insert("cms".into(), hashmap! { "page" => AcsRole::Editor });
            // No ERP, CRM, POS on Starter plan
        },
        TenantPlan::Business => {
            grants.insert("pim".into(), hashmap! {
                "product" => AcsRole::Admin,
                "catalog" => AcsRole::Admin,
            });
            grants.insert("dam".into(), hashmap! {
                "media" => AcsRole::Admin,
                "asset" => AcsRole::Admin,
            });
            grants.insert("cms".into(), hashmap! {
                "gui" => AcsRole::Owner,
                "view" => AcsRole::Owner,
                "page" => AcsRole::Owner,
            });
            grants.insert("crm".into(), hashmap! { "contact" => AcsRole::Editor });
            grants.insert("erp".into(), hashmap! { "order" => AcsRole::Admin });
            grants.insert("pos".into(), hashmap! { "shop" => AcsRole::Member });
        },
        TenantPlan::Enterprise => {
            // All systems, all entities, Owner level
            for (sys, entities) in all_system_entities() {
                let mut entity_map = HashMap::new();
                for entity in entities {
                    entity_map.insert(entity.to_string(), AcsRole::Owner);
                }
                grants.insert(sys.to_string(), entity_map);
            }
        },
    }

    grants
}
```

**System defaults are the ceiling**. A tenant on the Starter plan cannot grant `Owner` on `erp.order` — the system doesn't expose ERP to that plan. The system defaults are stored per-plan, not per-tenant, and loaded from compiled Rust code.

---

## Tenant-Defined Overrides (Layer 2 — JS via Admin UI)

Tenant admins customize permissions **within** the system ceiling via a policy editor. These are JS declarations that compile to AST:

```javascript
// Tenant admin writes this in the policy editor UI
// This RESTRICTS the system default, never EXTENDS it

definePermissions("sales-team", {
  // Sales team can manage CRM but only view products
  crm: { contact: Role.Admin, lead: Role.Editor },
  pim: { product: Role.Viewer },
  erp: { order: Role.Creator },  // can create orders, not delete
  // Everything else: no access (not listed = Public = 0)
});

definePermissions("content-team", {
  cms: { gui: Role.Owner, view: Role.Owner, page: Role.Owner },
  dam: { media: Role.Admin, asset: Role.Editor },
  pim: { product: Role.Viewer },  // read-only product data for reference
});

definePermissions("warehouse-ops", {
  erp: { order: Role.Editor, invoice: Role.Viewer },
  pos: { shop: Role.Viewer },
});
```

**Compiles to** (stored as JSONB):

```json
{
  "team": "sales-team",
  "version": 1,
  "grants": {
    "crm": { "contact": 4, "lead": 3 },
    "pim": { "product": 1 },
    "erp": { "order": 2 }
  }
}
```

**Evaluation**: `effective_role = min(system_ceiling, tenant_grant)`. If system says `erp.order = Admin(4)` for this plan but tenant admin assigned the user `Creator(2)`, the effective role is `2`.

---

## Tenant-Defined Custom Rules (Beyond Simple Roles)

For rules that go beyond role-level checks, tenants use JS policy declarations:

```javascript
// Custom business rule: orders over $5,000 require Admin approval
definePolicy("erp.order.create", (ctx) => {
  if (ctx.command.total_cents > 500_000 && ctx.principal.role < Role.Admin) {
    return deny("Orders over $5,000 require Admin approval");
  }
  return allow();
});

// Custom rule: only content team can publish pages on weekends
definePolicy("cms.page.publish", (ctx) => {
  const day = new Date(ctx.timestamp).getDay();
  const isWeekend = day === 0 || day === 6;
  if (isWeekend && ctx.principal.team !== "content-team") {
    return deny("Only content team can publish on weekends");
  }
  return allow();
});

// Custom validation: product names must follow tenant's naming convention
defineValidation("pim.product.create", (cmd) => {
  require(cmd.payload.name.length >= 3, "Product name too short");
  require(cmd.payload.name.length <= 200, "Product name too long");
  require(!cmd.payload.name.includes("TEST"), "Product name cannot contain TEST");
});
```

These compile to AST and layer **on top of** the ACS role check. The evaluation order is:

```
1. ACS role check (system-defined floor)
   └─ role >= action? → No → Deny (fast path, no AST evaluation)
                       → Yes → continue

2. System policy rules (compiled Rust, if any)
   └─ system invariants pass? → No → Deny
                                → Yes → continue

3. Tenant policy rules (compiled AST from JS)
   └─ all tenant rules pass? → No → Deny
                               → Yes → Allow
```

---

## System-Defined Workflows vs Tenant-Defined Workflows

### System-Defined (Rust, ships with platform)

Core workflows that define the platform's behavior. These are **compiled Rust** — typestate pattern, compile-time verified:

```rust
// Core order workflow — system-defined, not customizable
pub enum OrderState {
    Draft,
    Confirmed,
    Processing,
    Shipped,
    Delivered,
    Cancelled,
}

impl OrderAggregate {
    pub fn decide(&self, cmd: OrderCommand) -> Result<Vec<EventEnvelope>, DomainError> {
        match (&self.state, cmd) {
            (Draft, Confirm { .. }) => Ok(vec![confirmed_event(...)]),
            (Confirmed, Process { .. }) => Ok(vec![processing_event(...)]),
            (Processing, Ship { .. }) => Ok(vec![shipped_event(...)]),
            (Draft | Confirmed, Cancel { .. }) => Ok(vec![cancelled_event(...)]),
            _ => Err(DomainError::InvalidStateTransition { .. }),
        }
    }
}
```

### Tenant-Defined (JS → AST, extends system workflows)

Tenants add **hooks** at defined extension points, not rewrite the workflow:

```javascript
// Tenant adds a custom approval step before order confirmation
defineHook("erp.order.confirm", "before", (ctx) => {
  // Custom approval logic
  if (ctx.aggregate.total_cents > 1000_000) {
    return requireApproval({
      approver_role: Role.Admin,
      reason: "High-value order requires admin sign-off",
      timeout: "48h",
    });
  }
  return proceed();
});

// Tenant adds custom notification after shipment
defineHook("erp.order.ship", "after", (ctx) => {
  return emit("notification.send", {
    template: "order-shipped",
    to: ctx.aggregate.customer_email,
    data: { tracking: ctx.event.payload.tracking_number },
  });
});
```

**Compiles to**:

```json
{
  "hook": "erp.order.confirm",
  "phase": "before",
  "version": 1,
  "rules": [
    {
      "condition": { "op": "gt", "field": "aggregate.total_cents", "value": 1000000 },
      "then": {
        "action": "require_approval",
        "params": { "approver_role": 4, "reason": "...", "timeout": "48h" }
      },
      "else": { "action": "proceed" }
    }
  ]
}
```

**Key constraint**: Tenant hooks can **gate** (add approval, add validation) or **react** (emit notifications, trigger side effects). They can **never skip** system-defined workflow steps or weaken invariants.

---

## Permission Storage Schema (Postgres)

```sql
-- System defaults per plan (seed data, loaded from Rust code)
CREATE TABLE system_permissions (
    plan TEXT NOT NULL,                  -- 'starter' | 'business' | 'enterprise'
    system TEXT NOT NULL,                -- 'pim' | 'dam' | 'cms' | 'crm' | 'erp' | 'pos' | 'sys'
    entity TEXT NOT NULL,                -- 'product' | 'media' | 'order' | etc.
    max_role SMALLINT NOT NULL,          -- 0-6 (AcsRole ceiling for this plan)
    PRIMARY KEY (plan, system, entity)
);

-- Tenant team/user permission assignments
CREATE TABLE tenant_permissions (
    tenant_id UUID NOT NULL,
    principal_id UUID NOT NULL,          -- user or team UUID
    principal_type TEXT NOT NULL,         -- 'user' | 'team'
    system TEXT NOT NULL,                -- 'pim' | 'crm' | etc.
    entity TEXT NOT NULL,                -- 'product' | 'contact' | etc.
    granted_role SMALLINT NOT NULL,      -- 0-6 (must be <= system_permissions.max_role)
    granted_by UUID NOT NULL,
    granted_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, principal_id, principal_type, system, entity)
);

-- RLS: tenant isolation
ALTER TABLE tenant_permissions ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_rls ON tenant_permissions
    USING (tenant_id = current_setting('app.tenant_id')::UUID);

-- Tenant custom policy rules (compiled AST from JS)
CREATE TABLE tenant_policies (
    tenant_id UUID NOT NULL,
    resource TEXT NOT NULL,              -- 'erp.order.create' | 'cms.page.publish' | etc.
    version INT NOT NULL,
    ast JSONB NOT NULL,                  -- compiled PolicyAst
    source TEXT,                         -- original JS source (for editing)
    compiled_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    compiled_by UUID NOT NULL,
    PRIMARY KEY (tenant_id, resource)
);

ALTER TABLE tenant_policies ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_rls ON tenant_policies
    USING (tenant_id = current_setting('app.tenant_id')::UUID);

-- Tenant workflow hooks (compiled AST from JS)
CREATE TABLE tenant_hooks (
    tenant_id UUID NOT NULL,
    event_type TEXT NOT NULL,            -- 'erp.order.confirm' | 'cms.page.publish'
    phase TEXT NOT NULL,                 -- 'before' | 'after'
    version INT NOT NULL,
    ast JSONB NOT NULL,
    source TEXT,
    compiled_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, event_type, phase)
);

ALTER TABLE tenant_hooks ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_rls ON tenant_hooks
    USING (tenant_id = current_setting('app.tenant_id')::UUID);
```

---

## Permission Snapshot Computation + Caching

```
┌────────────────────────────────────────────────────────────┐
│ On user login or permission change event:                   │
│                                                             │
│ 1. Load tenant plan → system_permissions (ceiling)          │
│ 2. Load user's team memberships                             │
│ 3. Load tenant_permissions for user + all their teams       │
│ 4. Merge: for each (system, entity), take max across teams  │
│ 5. Clamp: effective = min(system_ceiling, merged_grant)     │
│ 6. Store snapshot:                                          │
│    Redis SET perm:{tenant}:{user} → JSON snapshot (TTL 5m)  │
│    Postgres: materialized for audit                         │
│                                                             │
│ On permission change event (PermissionGrantedEvent, etc.):  │
│    Invalidate Redis key for affected user(s)                │
│    Next request recomputes snapshot                         │
└────────────────────────────────────────────────────────────┘
```

**Hot path** (every request):

```rust
// 1. Redis GET (< 1ms)
let snapshot = cache.get(&format!("perm:{}:{}", tenant_id, user_id)).await;

// 2. If miss, recompute from Postgres (< 5ms)
let snapshot = snapshot.unwrap_or_else(|| compute_snapshot(tenant_id, user_id).await);

// 3. Check: one integer comparison (nanoseconds)
let decision = snapshot.check("erp", "order", AcsAction::Update);
```

---

## Full Evaluation Pipeline

```
Request: "User X wants to UPDATE entity erp.order.123"

Step 1: ACS Role Check (Rust, system-defined)
  └─ snapshot.check("erp", "order", AcsAction::Update)
  └─ user has role 3 (Editor) for erp.order
  └─ Update = 3, Editor = 3 → 3 >= 3 → PASS

Step 2: System Invariants (Rust, compiled)
  └─ OrderAggregate.decide(UpdateOrder { ... })
  └─ Is order in editable state? (Draft | Confirmed) → PASS

Step 3: Tenant Policies (Rust AST evaluator, from tenant_policies table)
  └─ Load AST for "erp.order.update" (Redis cached)
  └─ Evaluate conditions against context
  └─ "Orders over $5,000 require Admin" → total is $200 → PASS

Step 4: Tenant Hooks "before" (Rust AST evaluator, from tenant_hooks table)
  └─ Load hooks for "erp.order.update" phase="before"
  └─ No hooks defined → PASS

Result: ALLOW → proceed to event append
```

---

## Summary: What's System vs What's Tenant

| Concern | System-Defined (Layer 1) | Tenant-Defined (Layer 2) |
| --- | --- | --- |
| **ACS model** (actions 0-6, roles 0-6) | Rust enums. Hardcoded. Universal. | — (not customizable) |
| **Plan permissions** (which systems/entities) | Rust seed data per plan. Ceiling. | — (not customizable) |
| **User/team role assignments** | Default roles for new users | Admin UI → `tenant_permissions` table |
| **Permission snapshot** | Computed by Rust from both layers | — (result of merge) |
| **Core workflows** (order states, etc.) | Rust typestate. Compiled. | Hooks at extension points (before/after) |
| **Aggregate invariants** | Rust `decide()`. Compiled. | — (not customizable) |
| **Custom business rules** | — | JS → AST → `tenant_policies` table |
| **Custom validations** | Base validations in Rust | JS → AST → `tenant_policies` table |
| **Custom notifications** | — | JS → AST → `tenant_hooks` (after phase) |
| **Projections** | Core projections in Rust | Custom projections via JS (sandboxed) |
| **Upcasters** | Core upcasters in Rust | — (schema evolution is system concern) |

**The principle**: System defines the **floor** (minimum invariants that always hold) and the **ceiling** (maximum grants per plan). Tenants operate **between** floor and ceiling. Tenant rules can only **restrict**, never **extend** beyond the system ceiling.
