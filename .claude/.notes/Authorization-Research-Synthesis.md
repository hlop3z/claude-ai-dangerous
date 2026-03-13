# Authorization & Embedded Scripting — Research Synthesis

> **Purpose**: Cross-reference 3 research streams against our current design. Identify what's validated, what needs fixing, what's missing.

---

## Research Sources

| Stream                          | Scope                                                                                                                               | Key Sources                                                |
| ------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------- |
| **Multi-tenant RBAC/ABAC**      | Zanzibar, SpiceDB, Cedar, OpenFGA, WorkOS, Salesforce, bitmask patterns, permission snapshots, OPAL                                 | Oso, Auth0, Permit.io, Authzed, WorkOS, AWS, Design Gurus  |
| **Embedded scripting security** | QuickJS CVEs, sandboxing, compile-then-evaluate, policy-as-code (OPA/Rego/Cedar/Cerbos), AST security, TOCTOU                       | Cloudflare, Shopify, AWS Firecracker, Trail of Bits, OWASP |
| **Event-sourced authorization** | Authorization placement, permissions as projections, multi-BC auth, Zanzibar tuples, Uber Charter, Stripe/Shopify/Salesforce models | CodeOpinion, Oskar Dudycz, Daniel Whittaker, ByteByteGo    |

---

## 1. What Our Current Design Gets RIGHT

### 1.1 Two-Layer System (Floor/Ceiling) — VALIDATED

WorkOS, Salesforce, and Shopify all use this exact pattern:

- **Platform (Layer 1)** defines the maximum permission ceiling per plan
- **Tenant (Layer 2)** customizes within those bounds
- Tenant can **restrict** but never **extend** beyond ceiling

WorkOS documents 3 evolution stages: static roles → configurable roles → custom roles. Our design starts at stage 2 (configurable) and supports stage 3 (custom via JS→AST). This is correct.

### 1.2 Authorization in Command Pipeline — VALIDATED

The dominant expert recommendation (MediatR behaviors, DDD literature, Daniel Whittaker) is authorization as **pipeline middleware/decorator** that runs **before** the command handler. Our 4-step pipeline matches this:

```
ACS role check → System invariants → Tenant policies → Tenant hooks → Command handler
```

Domain logic stays free of authorization concerns. The aggregate's `decide()` only contains domain invariants, not access control. This is correct separation.

### 1.3 Permission Snapshot as Projection — VALIDATED

Our `PermissionSnapshot` is effectively a read model projected from permission events. This pattern is explicitly recommended for event-sourced systems (Oskar Dudycz, CodeOpinion). Benefits:

- Rebuildable from event stream
- Optimized for the hot-path query (`can user X do action Y on system.entity?`)
- Full audit trail of permission changes in event store
- Cacheable (Redis) with event-driven invalidation

### 1.4 Compile-Then-Evaluate — VALIDATED

Cloudflare's wirefilter library proves this pattern at massive scale. Trail of Bits security assessment confirms it's safer than direct execution. Our design where JS compiles to JSON AST at write time, Rust evaluates at runtime, aligns with the gold standard.

### 1.5 Authorization as Bounded Context — VALIDATED

Vernon's IDDD and DDD practitioners recommend treating Identity & Access as a dedicated bounded context. Our design does this implicitly — permission tables, snapshot computation, and policy evaluation are self-contained. Other subsystems (PIM, CRM, ERP) consume authorization decisions without knowing how they're made.

### 1.6 Uber Charter Pattern Alignment — VALIDATED

Our architecture matches Uber's approach:

- **Centralized policy repository** → Postgres tables (system_permissions, tenant_permissions, tenant_policies)
- **Local evaluation library** → Rust ACS evaluator + AST walker (no network round-trip)
- **ABAC attributes** → context fields (principal, resource, environment)

---

## 2. What Our Current Design Gets WRONG

### 2.1 Numeric Model Limitations — NEEDS EVOLUTION PATH

**Research finding**: Pure numeric hierarchy (`role >= action`) is **not suitable** for multi-subsystem SaaS because:

1. **Only works for strict linear hierarchies** — can't model "can edit but not delete" at the same permission level
2. **Can't model disjoint permission sets** — an Accountant and Developer have non-overlapping permissions
3. **Breaks for non-linear relationships** — "can view orders AND create contacts" doesn't fit a single hierarchy

**Our mitigation**: We scope numeric roles **per entity** (matrix model: `system.entity → AcsRole`), which covers 90% of cases. A user can be `Editor` on `pim.product` and `Viewer` on `erp.order` independently.

**Where it still breaks**: Within a single entity, the hierarchy is rigid. You can't have:

- "Can create products but not update them" (Create=2, Update=3 — Update includes Create)
- "Can delete but not assign" is fine (Delete=4, Assign=6 — this works because ordering)
- "Can assign but not delete" is impossible (Assign=6 includes all lower)

**Recommendation**: Keep ACS numeric model as the **fast-path RBAC layer** (covers 95% of checks). Use **tenant-defined policies** (Layer 2 AST) for the 5% of non-linear cases. Document the limitation and evolution path:

```
Phase 1 (Now):  ACS numeric (role >= action) per entity — simple, O(1)
Phase 2 (When needed): Add optional per-entity action bitmask override
Phase 3 (When needed): Add ReBAC via Zanzibar tuples for relationship traversal
```

### 2.2 Permission Cache TOCTOU Vulnerability — NEEDS FIX

**Research finding**: TTL-based caching creates a TOCTOU (Time-of-Check-Time-of-Use) window where:

- Permission is revoked
- Cached snapshot still shows the old permission (up to TTL)
- User performs action in the window

**Current design**: Redis TTL of 5 minutes. This is too long for security-critical operations.

**Fix — Zanzibar-style version stamps**:

```rust
pub struct PermissionSnapshot {
    pub tenant_id: Uuid,
    pub user_id: Uuid,
    pub grants: HashMap<String, HashMap<String, AcsRole>>,
    pub computed_at: DateTime<Utc>,
    pub version: i64,           // NEW: monotonic version counter
    pub zookie: String,         // NEW: opaque consistency token
}
```

**Tiered consistency model** (per-request):

| Level                    | Behavior                                       | Use When                                   |
| ------------------------ | ---------------------------------------------- | ------------------------------------------ |
| `Eventual`               | Use cached snapshot (Redis, any age up to TTL) | Read-only queries, list operations         |
| `AtLeastAsFresh(zookie)` | Snapshot must be >= the zookie's version       | After a permission write, subsequent reads |
| `Strong`                 | Recompute from Postgres, bypass cache          | Sensitive ops: delete, assign, payment     |

```rust
pub enum ConsistencyLevel {
    Eventual,
    AtLeastAsFresh { zookie: String },
    Strong,
}
```

### 2.3 Missing AST Validation — SECURITY GAP

**Research finding**: CVE-2026-30860 showed that incomplete AST validation creates exploitable blind spots. Validators that fail to recursively inspect container nodes (ArrayExpr, RowExpr) allow attackers to smuggle restricted operations.

**Current design**: We validate output against "JSON Schema" but don't specify what validation covers.

**Required validation checklist** (add to ScriptCompiler):

```rust
pub struct AstValidationConfig {
    pub max_depth: usize,              // e.g., 10 — prevent stack overflow in evaluator
    pub max_node_count: usize,         // e.g., 500 — prevent memory exhaustion
    pub max_total_bytes: usize,        // e.g., 64 KB — prevent storage abuse
    pub allowed_fields: HashSet<String>, // whitelist: "principal.role", "resource.state", etc.
    pub allowed_operators: HashSet<String>, // whitelist: "eq", "gte", "and", "or", etc.
    pub max_string_length: usize,      // e.g., 1000 — prevent large string literals
    pub require_deterministic: bool,   // reject time-based, random conditions
}

pub fn validate_ast(ast: &PolicyAst, config: &AstValidationConfig) -> Result<(), Vec<ValidationError>> {
    let mut errors = vec![];
    validate_depth(ast, 0, config.max_depth, &mut errors);
    validate_node_count(ast, config.max_node_count, &mut errors);
    validate_total_size(ast, config.max_total_bytes, &mut errors);
    validate_fields_whitelist(ast, &config.allowed_fields, &mut errors);
    validate_operators_whitelist(ast, &config.allowed_operators, &mut errors);
    validate_string_lengths(ast, config.max_string_length, &mut errors);
    if config.require_deterministic {
        validate_determinism(ast, &mut errors);
    }
    if errors.is_empty() { Ok(()) } else { Err(errors) }
}
```

**Also required on Rust types**:

```rust
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]  // CRITICAL: reject unexpected fields
pub enum Condition {
    // ...variants...
}
```

### 2.4 Missing Scope Validation — SECURITY GAP

**Research finding**: Tenant-defined rules that reference other tenants' resources enable horizontal privilege escalation. OWASP multi-tenant cheat sheet: "Always validate that requested resources belong to the current tenant."

**Fix**: Every AST field reference must be validated against the tenant's accessible scope:

```rust
/// Validates that a tenant-defined AST only references:
/// 1. Fields the tenant's plan exposes (no accessing ERP if on Starter plan)
/// 2. Entities within the tenant's system scope
/// 3. No cross-tenant resource references
pub fn validate_tenant_scope(
    ast: &PolicyAst,
    tenant_plan: &TenantPlan,
    accessible_systems: &HashSet<String>,
) -> Result<(), ScopeViolation> {
    // Extract all system.entity references from the AST
    // Verify each is within the tenant's plan ceiling
    // Reject any reference to tenant_id, user_id of other tenants
}
```

### 2.5 QuickJS CVE Exposure — NEEDS HARDENING

**Research finding**: QuickJS has ongoing memory safety CVEs:

- CVE-2026-3979: Use-after-free (CVSS 4.8)
- CVE-2026-1145: Heap buffer overflow (High)
- CVE-2024-13903: Stack buffer overflow
- rquickjs format string vulnerability (CVSS 7.5, fixed in 0.4.2+)

**Required hardening** (add to ScriptCompiler security model):

| Layer                 | Protection                                               | Implementation                   |
| --------------------- | -------------------------------------------------------- | -------------------------------- |
| **Minimum version**   | rquickjs >= 0.4.2                                        | `Cargo.toml` version pin         |
| **Memory limits**     | `JS_SetMemoryLimit()` — 10 MB                            | rquickjs runtime config          |
| **CPU limits**        | `JS_SetInterruptHandler()` — 100ms timeout               | Interrupt callback with timer    |
| **Stack limits**      | `JS_SetMaxStackSize()` — 1 MB                            | rquickjs runtime config          |
| **No I/O**            | No filesystem, network, process globals exposed          | Don't register any I/O functions |
| **Process isolation** | Run compilation in separate process with seccomp-bpf     | Defense-in-depth (Phase 2)       |
| **AST signing**       | HMAC-SHA256 sign AST at compile time, verify before eval | Prevent AST tampering in storage |
| **CVE monitoring**    | Automated dependency scanning (cargo-audit)              | CI/CD pipeline                   |

### 2.6 Missing Event-Driven Cache Invalidation — INCOMPLETE

**Research finding**: OPAL (Open Policy Administration Layer) shows that event-driven policy updates are superior to TTL-based caching. Zanzibar uses timestamp quantization for cache efficiency.

**Current design**: Redis TTL of 5 minutes, invalidation on permission change event. But the invalidation path isn't fully specified.

**Fix — Permission change events + invalidation**:

```rust
// Permission changes MUST be domain events (expert consensus)
pub enum PermissionEvent {
    RoleGranted { tenant_id: Uuid, user_id: Uuid, system: String, entity: String, role: AcsRole, granted_by: Uuid },
    RoleRevoked { tenant_id: Uuid, user_id: Uuid, system: String, entity: String, revoked_by: Uuid },
    PolicyUpdated { tenant_id: Uuid, resource: String, version: i32, compiled_by: Uuid },
    HookUpdated { tenant_id: Uuid, event_type: String, phase: String, version: i32 },
}

// Projection handler: invalidate affected snapshots
async fn on_permission_event(event: &PermissionEvent, cache: &dyn Cache) {
    match event {
        PermissionEvent::RoleGranted { tenant_id, user_id, .. } |
        PermissionEvent::RoleRevoked { tenant_id, user_id, .. } => {
            // Invalidate specific user's snapshot
            cache.delete(&format!("perm:{}:{}", tenant_id, user_id)).await;
            // Also invalidate any team-level snapshots if user is in teams
        },
        PermissionEvent::PolicyUpdated { tenant_id, resource, .. } => {
            // Invalidate cached policy AST
            cache.delete(&format!("policy:{}:{}", tenant_id, resource)).await;
        },
        PermissionEvent::HookUpdated { tenant_id, event_type, phase, .. } => {
            cache.delete(&format!("hook:{}:{}:{}", tenant_id, event_type, phase)).await;
        },
    }
}
```

---

## 3. What's MISSING from Our Design

### 3.1 PEP/PDP/PAP Decomposition — Industry Standard

The XACML/industry-standard decomposition separates authorization into 4 components. Our design has them implicitly but should make them explicit:

```
┌──────────────────────────────────────────────────────────────────┐
│ PAP (Policy Administration Point)                                │
│ Where policies are created and managed                           │
│ ──────────────────────────────────────────────────────────────── │
│ • System: Rust seed data (system_permissions table)              │
│ • Tenant: Admin UI → JS → rquickjs compile → tenant_policies    │
│ • Storage: Postgres (JSONB, RLS-isolated per tenant)             │
└──────────────────────┬───────────────────────────────────────────┘
                       │ policies distributed via
                       │ Postgres + Redis cache
                       ▼
┌──────────────────────────────────────────────────────────────────┐
│ PDP (Policy Decision Point)                                      │
│ Evaluates policies — returns Allow/Deny                          │
│ ──────────────────────────────────────────────────────────────── │
│ • AcsAuthorizationPolicy (Rust, embedded library — not service)  │
│ • Loads PermissionSnapshot from Redis (PIP data)                 │
│ • Evaluates ACS role check (O(1) integer comparison)             │
│ • Evaluates tenant policy ASTs (Rust AST walker)                 │
│ • Evaluates tenant hooks (Rust AST walker)                       │
│ • Returns Decision { Allow | Deny { reason } }                  │
│                                                                  │
│ NOTE: This is a Rust library (like Uber's authfx), NOT a        │
│ separate service. Zero network overhead. Embedded in each        │
│ service instance.                                                │
└──────────────────────┬───────────────────────────────────────────┘
                       │
                       ▼
┌──────────────────────────────────────────────────────────────────┐
│ PEP (Policy Enforcement Point)                                   │
│ The ONLY authorization-related code in your business logic       │
│ ──────────────────────────────────────────────────────────────── │
│ • Command pipeline middleware (before handler)                   │
│ • Single call: authz.check(principal, action, resource).await    │
│ • If Deny → return 403 Forbidden                                │
│ • If Allow → proceed to command handler                         │
│                                                                  │
│ Business logic contains EXACTLY ONE authorization line.          │
└──────────────────────────────────────────────────────────────────┘
                       │
                       ▼
┌──────────────────────────────────────────────────────────────────┐
│ PIP (Policy Information Point)                                   │
│ Provides context data for policy decisions                       │
│ ──────────────────────────────────────────────────────────────── │
│ • Principal (from IdentityProvider — JWT/OIDC token)             │
│ • PermissionSnapshot (from Redis/Postgres projection)            │
│ • Resource metadata (from aggregate state or read model)         │
│ • Environment (timestamp, IP, device — for ABAC conditions)     │
└──────────────────────────────────────────────────────────────────┘
```

### 3.2 Deny-by-Default Everywhere — OWASP #1

OWASP's top recommendation: **deny by default**. Our design implies this (no matching rule → Deny) but should make it explicit at every layer:

```rust
impl PermissionSnapshot {
    pub fn check(&self, system: &str, entity: &str, action: AcsAction) -> Decision {
        // DENY BY DEFAULT — explicit, not implicit
        match self.grants.get(system).and_then(|s| s.get(entity)) {
            Some(role) if role.can(action) => Decision::Allow,
            _ => Decision::Deny {
                reason: format!("No grant for {}.{}.{}", system, entity, action.as_str()),
            },
        }
    }
}

// Policy AST evaluation: deny if no rules match
pub fn evaluate_policy(policy: &PolicyAst, ctx: &EvalContext) -> Decision {
    for rule in &policy.rules {
        if let Some(decision) = evaluate_rule(rule, ctx) {
            return decision;
        }
    }
    Decision::Deny { reason: "No matching policy rule (deny-by-default)".into() }
}
```

### 3.3 Authorization Logging & Alerting — OWASP Requirement

**Research finding**: "Log access control failures and alert admins on repeated failures." 100% of tested applications had broken access control.

```rust
/// Every authorization decision MUST be logged for audit.
pub struct AuthzAuditEntry {
    pub timestamp: DateTime<Utc>,
    pub tenant_id: Uuid,
    pub user_id: Uuid,
    pub action: AcsAction,
    pub system: String,
    pub entity: String,
    pub resource_id: Option<Uuid>,
    pub decision: Decision,
    pub evaluation_path: Vec<String>,  // which layers were checked
    pub latency_us: u64,               // microseconds
}

// Alert on patterns:
// - > N denials from same user in M minutes (brute-force probing)
// - Denial on admin-level actions (privilege escalation attempt)
// - Cross-system access patterns (horizontal escalation attempt)
```

### 3.4 Saga Authorization — INCOMPLETE

**Research finding**: Long-running sagas need special authorization handling.

| Concern              | Recommendation                                                             |
| -------------------- | -------------------------------------------------------------------------- |
| **Entry point**      | Check auth when saga starts (the initiating command)                       |
| **Per-step auth**    | Each saga step dispatches commands that go through their own auth pipeline |
| **Security context** | Saga carries a `Principal` snapshot from initiating user                   |
| **Compensation**     | Compensating commands run with system-level privileges (not user)          |
| **Long-running**     | Re-check permissions at each step (user's permissions may change mid-saga) |

```rust
pub struct SagaSecurityContext {
    pub initiator: Principal,              // who started the saga
    pub initiated_at: DateTime<Utc>,       // when they started
    pub permission_snapshot_version: i64,  // version at saga start
    pub consistency: ConsistencyLevel,     // Strong for sensitive sagas
}
```

### 3.5 Retroactive Permission Changes — NOT HANDLED

**Research finding**: Permissions should be events. Retroactive changes (revoking access after-the-fact) should emit compensating events, never mutate history.

```rust
// NEVER mutate the event stream. Retroactive changes are new events.
pub struct PermissionRetroactivelyRevoked {
    pub tenant_id: Uuid,
    pub user_id: Uuid,
    pub system: String,
    pub entity: String,
    pub effective_from: DateTime<Utc>,  // retroactive effective date
    pub reason: String,
    pub revoked_by: Uuid,
    pub revoked_at: DateTime<Utc>,
}
```

### 3.6 Wirefilter Optimization — FUTURE ENHANCEMENT

**Research finding**: Cloudflare's wirefilter compiles DSL directly to Rust closures (`Box<dyn Fn(&ExecutionContext) -> bool>`). This eliminates serialization/deserialization attack surface and provides ~10-15% improvement over AST interpretation.

**Current approach**: JSON AST (serializable, storable, inspectable).
**Wirefilter approach**: Rust closures (fastest, no serialization attack surface, but not storable/inspectable).

**Recommendation**: Keep JSON AST for tenant-defined rules (need storage, versioning, audit). Consider wirefilter-style closure compilation for system-defined rules that don't need serialization:

```rust
// System-defined rules: compile to closures at startup (wirefilter pattern)
type PolicyFn = Box<dyn Fn(&EvalContext) -> Decision + Send + Sync>;

pub struct SystemPolicy {
    pub resource: String,
    pub evaluator: PolicyFn,  // compiled closure, not AST
}

// Tenant-defined rules: keep AST for storage/versioning/audit
pub struct TenantPolicy {
    pub resource: String,
    pub ast: PolicyAst,       // serializable, storable, inspectable
}
```

---

## 4. Comparison: Our Approach vs Industry Tools

| Capability               | Our ACS + AST                    | Cedar (AWS)            | SpiceDB (Zanzibar)   | Cerbos             | OPA/Rego          |
| ------------------------ | -------------------------------- | ---------------------- | -------------------- | ------------------ | ----------------- |
| **RBAC**                 | AcsRole per entity (O(1))        | Entity-based           | Via relation tuples  | YAML + CEL         | Rego policies     |
| **ABAC**                 | Tenant policies (AST conditions) | First-class            | Caveats (limited)    | CEL expressions    | Full Rego         |
| **ReBAC**                | Not yet (future Phase 3)         | Not native             | Core strength        | Not native         | Via data rules    |
| **Formal verification**  | No                               | Yes (provably correct) | No                   | No                 | No                |
| **Tenant customization** | JS → AST (native)                | Cedar policies         | Schema-based         | Scoped policies    | Policy bundles    |
| **Performance**          | Microseconds (embedded)          | Sub-millisecond        | Network round-trip   | Network or sidecar | Sub-millisecond   |
| **Infrastructure**       | None (Rust library)              | AWS service or library | Separate service     | Separate service   | Sidecar           |
| **Audit trail**          | Event-sourced (native)           | CloudTrail             | Limited              | Logs               | Logs              |
| **Multi-tenant**         | RLS + plan ceiling               | Via tenant scoping     | Namespace per tenant | Scope-based        | Bundle per tenant |

**Why our approach wins for this system**:

- Zero additional infrastructure (embedded Rust library)
- Event-sourced audit trail is first-class, not bolted on
- Tenant customization via familiar JS syntax (vs Cedar/Rego DSLs)
- Sub-microsecond RBAC checks (integer comparison)
- Natural fit with hexagonal architecture (AuthorizationPolicy port)

**When to migrate to Cedar or SpiceDB**:

- Cedar: when formal verification of policies is required (compliance, regulated industry)
- SpiceDB: when permission graphs exceed 3 levels (Google Drive-style nested sharing)
- Both: when you have 5+ teams authoring policies and need a governance layer

---

## 5. Revised Security Model

| Layer                   | Threat                              | Protection                                                                | Status   |
| ----------------------- | ----------------------------------- | ------------------------------------------------------------------------- | -------- |
| **Compilation sandbox** | Resource exhaustion, code injection | Memory 10MB, time 100ms, stack 1MB, no I/O                                | Existing |
| **API surface**         | Unauthorized globals                | Whitelist: `allow()`, `deny()`, `require()`, `definePolicy()`             | Existing |
| **Output validation**   | Malicious AST bypass                | Depth, node count, size, field whitelist, operator whitelist, determinism | **NEW**  |
| **Scope validation**    | Cross-tenant access                 | AST references validated against tenant's plan scope                      | **NEW**  |
| **AST integrity**       | Storage tampering                   | HMAC-SHA256 signature on AST at compile time                              | **NEW**  |
| **Serde hardening**     | Unknown field injection             | `#[serde(deny_unknown_fields)]` on all AST types                          | **NEW**  |
| **Evaluation safety**   | No JS at eval time                  | Architecture (compile-then-evaluate)                                      | Existing |
| **Tenant isolation**    | Horizontal escalation               | Postgres RLS + composite keys + scope validation                          | Enhanced |
| **Cache consistency**   | TOCTOU race condition               | Version-stamped snapshots + tiered consistency                            | **NEW**  |
| **Audit logging**       | Undetected access violations        | All auth decisions logged, alert on patterns                              | **NEW**  |
| **Deny-by-default**     | Missing access checks               | Explicit deny at every layer, no implicit allows                          | **NEW**  |
| **CVE monitoring**      | QuickJS vulnerabilities             | cargo-audit in CI, minimum rquickjs 0.4.2+                                | **NEW**  |
| **Process isolation**   | QuickJS escape                      | seccomp-bpf for compilation process (Phase 2)                             | **NEW**  |

---

## 6. Revised Evaluation Pipeline

```
Request: "User X wants to UPDATE entity erp.order.123"

┌─────────────────────────────────────────────────────────────────────┐
│ Step 0: CONSISTENCY CHECK (NEW)                                     │
│   └─ Determine consistency level from request context               │
│   └─ Sensitive op (delete, assign, payment) → Strong                │
│   └─ Normal op → Eventual (use cached snapshot)                     │
│   └─ After permission write → AtLeastAsFresh(zookie)                │
└─────────────────────┬───────────────────────────────────────────────┘
                      ▼
┌─────────────────────────────────────────────────────────────────────┐
│ Step 1: ACS ROLE CHECK (Rust, system-defined)                       │
│   └─ Load PermissionSnapshot (Redis → Postgres fallback)            │
│   └─ Check version against consistency requirement                  │
│   └─ snapshot.check("erp", "order", AcsAction::Update)              │
│   └─ role(3) >= action(3) → PASS                                   │
│   └─ LOG: { decision: Allow, layer: "acs", latency: 0.1ms }        │
└─────────────────────┬───────────────────────────────────────────────┘
                      ▼
┌─────────────────────────────────────────────────────────────────────┐
│ Step 2: SYSTEM INVARIANTS (Rust, compiled)                          │
│   └─ OrderAggregate.decide(UpdateOrder { ... })                     │
│   └─ Is order in editable state? (Draft | Confirmed) → PASS        │
│   └─ System policies (wirefilter closures) if any → PASS           │
└─────────────────────┬───────────────────────────────────────────────┘
                      ▼
┌─────────────────────────────────────────────────────────────────────┐
│ Step 3: TENANT POLICIES (Rust AST evaluator)                        │
│   └─ Load PolicyAst for "erp.order.update" (Redis → Postgres)      │
│   └─ Verify AST signature (HMAC-SHA256)                             │
│   └─ Evaluate conditions against EvalContext                        │
│   └─ "Orders > $5K require Admin" → total $200 → PASS              │
│   └─ LOG: { decision: Allow, layer: "tenant_policy", latency: 5µs }│
└─────────────────────┬───────────────────────────────────────────────┘
                      ▼
┌─────────────────────────────────────────────────────────────────────┐
│ Step 4: TENANT HOOKS "before" (Rust AST evaluator)                  │
│   └─ Load hooks for "erp.order.update" phase="before"               │
│   └─ No hooks defined → PASS                                       │
│   └─ LOG: { decision: Allow, layer: "tenant_hook", latency: 0µs }  │
└─────────────────────┬───────────────────────────────────────────────┘
                      ▼
                   ALLOW → proceed to command handler → event append
```

---

## 7. Evolution Path (Updated)

```
Phase 1 — Day 1 (Current Design + Fixes)
══════════════════════════════════════════════════════
• ACS numeric model per entity (role >= action, O(1))
• Two-layer system (system ceiling + tenant overrides)
• Compile-then-evaluate for tenant policies (JS → AST → Rust eval)
• PermissionSnapshot with version stamps + tiered consistency
• Exhaustive AST validation (depth, size, scope, whitelist, signing)
• Deny-by-default at every layer
• Authorization audit logging
• Permission changes as domain events
• #[serde(deny_unknown_fields)] on all AST types
• rquickjs >= 0.4.2 with full sandboxing

Phase 2 — When Earned
══════════════════════════════════════════════════════
• Process isolation for rquickjs (seccomp-bpf, separate process)
• Wirefilter-style closure compilation for system policies
• Complexity scoring for tenant ASTs (reject expensive policies)
• Per-entity action bitmask overrides (non-linear permissions)
• OPAL-style real-time policy distribution (if multi-instance)

Phase 3 — When Required
══════════════════════════════════════════════════════
• ReBAC via Zanzibar tuples (SpiceDB/OpenFGA) for deep graphs
• Cedar integration for formal policy verification (compliance)
• Cross-subsystem relationship traversal (5+ levels)
• Sub-millisecond auth at 10K+ checks/sec (dedicated PDP service)
```

---

## 8. Key Decisions Made

| Decision                | Choice                          | Why                                      | Alternative Considered                          |
| ----------------------- | ------------------------------- | ---------------------------------------- | ----------------------------------------------- |
| **Auth model**          | ACS numeric + AST policies      | O(1) fast path, tenant-customizable      | Cedar (adds dependency), bitmask (64-bit limit) |
| **PDP deployment**      | Embedded Rust library           | Zero network overhead, simplest infra    | Sidecar (Cerbos), service (SpiceDB)             |
| **Tenant rules format** | JS → JSON AST                   | Familiar syntax, serializable, auditable | Cedar DSL (unfamiliar), Rego (error-prone)      |
| **Cache strategy**      | Version-stamped + tiered        | Balances performance and consistency     | Pure TTL (TOCTOU risk), strong-only (too slow)  |
| **AST security**        | Exhaustive validation + signing | Defense-in-depth against tampering       | Trust-the-compiler (insufficient)               |
| **Permission events**   | First-class domain events       | Audit trail, rebuild, react              | Silent mutations (no trail)                     |
| **Deny default**        | Explicit at every layer         | OWASP #1, no implicit allows             | Implicit deny (easy to miss)                    |
