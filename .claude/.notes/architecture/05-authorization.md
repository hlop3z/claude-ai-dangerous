# Authorization System

> ACS numeric model + two-layer rules + compile-then-evaluate policies. Zero external authorization dependencies on day one.

---

## Principles

### Authentication != Authorization

These are distinct concerns with different lifecycles, caching strategies, failure modes, and external tooling. The architecture enforces this via **two separate ports**.

| Aspect              | IdentityProvider Port           | AuthorizationPolicy Port              |
| ------------------- | ------------------------------- | ------------------------------------- |
| **Question**        | "Who are you?"                  | "What can you do?"                    |
| **Input**           | Bearer token                    | Principal + Action + Resource         |
| **Output**          | `Principal` (identity)          | `Decision` (Allow / Deny)             |
| **External tool**   | Zitadel, Keycloak, Auth0 (OIDC) | Cerbos, Cedar, OpenFGA, SpiceDB       |
| **Cache TTL**       | Long (token lifetime, hours)    | Short (permission freshness, minutes) |
| **Failure default** | Deny (401 Unauthorized)         | Deny (403 Forbidden)                  |
| **HTTP error**      | 401                             | 403                                   |
| **Spec**            | OAuth 2.0 / OIDC                | RFC 9396 Rich Authorization Requests  |

### Why Not Embed Permissions in Tokens

The flat `roles: [], permissions: []` pattern is a known anti-pattern:

| Problem                 | Consequence                                              |
| ----------------------- | -------------------------------------------------------- |
| **No tenant context**   | "admin" of which tenant?                                 |
| **Stale permissions**   | Token lives for hours; permissions change in minutes     |
| **Token bloat**         | 100 permissions × 10 resources = kilobyte-sized JWTs     |
| **Hardcoded roles**     | Adding a role requires redeploying the identity provider |
| **No resource context** | "can_edit" what? Global permission is meaningless        |

**Solution: Token Lookup Pattern**

The token carries only identity (`sub`, `tenant_id`, `tenant_role`). Permissions are resolved at request time via the `AuthorizationPolicy` port. This is the pattern used by Google (Zanzibar), Airbnb, and Salesforce.

### Deny-by-Default at Every Layer

| Layer          | Check                                                        | Default |
| -------------- | ------------------------------------------------------------ | ------- |
| Transport      | Token present and valid? (`IdentityProvider.verify_token`)   | Deny    |
| Application    | Principal allowed this action? (`AuthorizationPolicy.check`) | Deny    |
| Domain         | Business rules permit this transition? (`decide()`)          | Reject  |
| Infrastructure | Tenant owns this data? (`TenantIsolation`)                   | Deny    |

No implicit allows. Every layer must explicitly grant access.

---

## Two-Level Authorization Model

### Level 1: Tenant Role (RBAC) — Coarse-Grained

```
TenantRole hierarchy (ordered):
    Guest(0) < Viewer(1) < Editor(2) < Manager(3) < Admin(4) < Owner(5)
```

The `Principal.tenant_role` comes from the OIDC token. It's a single value, not a list. The hierarchy is strictly ordered — Owner includes all permissions of Admin, which includes Manager, etc.

### Level 2: Resource Relationships (ReBAC) — Fine-Grained

When the tenant role is insufficient (e.g., Editor trying to edit a specific document they don't own), the system checks resource-level permissions:

```
Permission record:
    tenant_id:       UUID
    principal_id:    UUID       — user or team
    principal_type:  string     — "user" | "team"
    resource_type:   string     — "domain" | "entity" | "aggregate"
    resource_id:     UUID?      — null = wildcard (all of that type)
    resource_domain: string?    — "commerce", "billing", etc.
    resource_entity: string?    — "product", "order", etc.
    action:          string     — "read" | "write" | "delete" | "manage_members"
    granted_by:      UUID
    granted_at:      Timestamp
    expires_at:      Timestamp? — null = permanent
```

### Combined Authorization Flow

```
1. Check TenantRole hierarchy (fast path, O(1)):
   if principal.tenant_role >= required_role_for(action):
       return Allow

2. Check resource-level permissions (ReBAC):
   query permissions table for matching (tenant, principal, action, resource)
   if found and not expired:
       return Allow

3. Default:
   return Deny("insufficient permissions")
```

---

## ACS Numeric Model (Access Control Score)

Each entity type defines a numeric access control score per action. The check is a single integer comparison: `role_level >= action_score`.

```
Entity: commerce.product
    read:           1 (Viewer)
    write:          2 (Editor)
    delete:         4 (Admin)
    manage_members: 4 (Admin)

Entity: billing.invoice
    read:           2 (Editor)
    write:          3 (Manager)
    delete:         5 (Owner)
    export:         3 (Manager)

Entity: iam.user
    read:           3 (Manager)
    write:          4 (Admin)
    delete:         5 (Owner)
    manage_roles:   5 (Owner)
```

**Fast path**: For 95% of requests, a single integer comparison resolves authorization with zero database queries.

**Slow path**: For the remaining 5% (resource-level permissions, team memberships, custom policies), the system falls back to the permission table query.

---

## Permission Changes as Domain Events

Permission grants and revocations are domain events, not silent mutations:

```
PermissionGrantedEvent:
    tenant_id, principal_id, resource_type, resource_id, action, granted_by, granted_at

PermissionRevokedEvent:
    tenant_id, principal_id, resource_type, resource_id, action, revoked_by, revoked_at
```

This enables:

- Full audit trail of who granted/revoked what and when
- Rebuilding permission state from events (permissions as a projection)
- Reacting to permission changes (e.g., cache invalidation, notifications)

---

## Cache Strategy: Version-Stamped Snapshots

Permission checks are hot-path. The system uses a tiered caching strategy:

### Tiered Consistency

| Tier               | When Used                                | Staleness Window | Example                          |
| ------------------ | ---------------------------------------- | ---------------- | -------------------------------- |
| **Strong**         | Sensitive operations (delete, admin ops) | 0                | Always query database            |
| **AtLeastAsFresh** | After permission writes                  | 0 (per-request)  | Bust cache for this session      |
| **Eventual**       | Normal reads, listing                    | Cache TTL        | Redis-cached permission snapshot |

### Version-Stamped Snapshots

Each permission snapshot carries a version. When a permission changes:

1. Permission event is appended → version increments
2. Cache entry is invalidated (or version-bumped)
3. Next request fetches fresh snapshot from database
4. Snapshot is cached with new version

TOCTOU (Time-of-check-to-time-of-use) is mitigated by:

- Short cache TTL (30-60 seconds for normal operations)
- Immediate invalidation for the requesting session after writes
- Strong consistency for sensitive operations (always bypass cache)

---

## Tenant-Defined Policies (Compile-Then-Evaluate)

Tenant admins can define custom authorization policies using the scripting layer (see **06-scripting.md**). Policies are compiled to `PolicyAst` at write time and evaluated natively at request time with zero scripting overhead.

### Policy Evaluation Pipeline

```
1. Load PolicyAst from database (cached in Redis)
2. Verify HMAC-SHA256 signature (detect storage tampering)
3. Evaluate AST against EvalContext:
   - principal: { sub, tenant_id, role, role_level }
   - resource:  { domain, entity, id, state, owner_id }
   - action:    { name }
   - environment: { timestamp, ip_address }
4. Return Decision (Allow or Deny with reason)
```

### AST Validation (Defense-in-Depth)

Before storing a compiled policy:

| Validation              | Limit | Purpose                                                    |
| ----------------------- | ----- | ---------------------------------------------------------- |
| Max depth               | 10    | Prevent stack overflow in evaluator                        |
| Max node count          | 500   | Prevent memory exhaustion                                  |
| Max total bytes         | 64 KB | Prevent storage abuse                                      |
| Field whitelist         | —     | Only allowed fields (principal.role, resource.state, etc.) |
| Operator whitelist      | —     | Only allowed operators (eq, gte, and, or, etc.)            |
| Max string length       | 1000  | Prevent large string literals                              |
| Determinism requirement | —     | Reject time-based, random conditions                       |

### Scope Validation

Tenant-defined rules that reference other tenants' resources enable horizontal privilege escalation. Every AST field reference must be validated against the tenant's accessible scope:

- Fields the tenant's plan exposes (no accessing ERP if on Starter plan)
- Entities within the tenant's system scope
- No cross-tenant resource references

### AST Signing: HMAC-SHA256

AST is signed at compile time with HMAC-SHA256. Before evaluation, the signature is verified to detect tampering in storage. Prevents an attacker who gains database write access from injecting malicious AST that bypasses the compilation sandbox.

---

## Saga Authorization

| Concern              | Recommendation                                                             |
| -------------------- | -------------------------------------------------------------------------- |
| **Entry point**      | Check auth when saga starts (the initiating command)                       |
| **Per-step auth**    | Each saga step dispatches commands that go through their own auth pipeline |
| **Security context** | Saga carries a `Principal` snapshot from initiating user                   |
| **Compensation**     | Compensating commands run with system-level privileges (not user)          |
| **Long-running**     | Re-check permissions at each step (user's permissions may change mid-saga) |

---

## Authorization Audit Logging

All authorization decisions are logged for compliance and security monitoring:

```
AuthorizationLog:
    timestamp:    Timestamp
    principal_id: UUID
    tenant_id:    UUID
    action:       string
    resource:     string
    decision:     Allow | Deny
    reason:       string?
    source:       string     — "role_check" | "permission_table" | "policy_ast"
```

Alert on patterns:

- Repeated denials from same principal (brute-force probing)
- Admin-action denials (privilege escalation attempt)
- Cross-system access patterns (lateral movement)

---

## Evolution Path

### Phase 1 — Day 1

- ACS numeric model per entity (role >= action, O(1))
- Postgres permission table + Redis cache
- Version-stamped permission snapshots with tiered consistency
- Deny-by-default at every layer
- Authorization audit logging
- Permission changes as domain events

### Phase 2 — When Permission Graphs Exceed 3 Levels

- Cerbos/OpenFGA for deep relationship traversal
- Per-entity action bitmask overrides (non-linear permissions)

### Phase 3 — When Formal Verification Is Required

- SpiceDB/Zanzibar for deep relationship graphs (Google Drive-style: 5+ levels)
- Cedar for formal policy verification (compliance, regulated industry)
- Sub-millisecond auth at 10K+ checks/sec (dedicated PDP service)
