# Security - Abstraction-First

## Authentication Flow (OIDC/OAuth2)

### Architecture

```
Client -> API Gateway/Middleware -> Service
           |
           v
       IdentityProvider port
           |
           +-> ZitadelAdapter (production)
           +-> KeycloakAdapter (alternative)
           +-> MockAuthAdapter (testing)
```

### Auth Middleware Pattern

**Rust (axum):**

```rust
async fn auth_middleware(
    State(auth): State<Arc<dyn IdentityProvider>>,
    mut req: Request,
    next: Next,
) -> Result<Response, AppError> {
    let token = req.headers()
        .get("authorization")
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Bearer "))
        .ok_or(AppError::Unauthorized)?;

    let claims = auth.verify_token(token).await
        .map_err(|_| AppError::Unauthorized)?;

    req.extensions_mut().insert(claims);
    Ok(next.run(req).await)
}
```

**Go (stdlib net/http):**

```go
func AuthMiddleware(auth IdentityProvider) func(http.Handler) http.Handler {
    return func(next http.Handler) http.Handler {
        return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
            token := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
            if token == "" {
                http.Error(w, "unauthorized", http.StatusUnauthorized)
                return
            }
            claims, err := auth.VerifyToken(r.Context(), token)
            if err != nil {
                http.Error(w, "unauthorized", http.StatusUnauthorized)
                return
            }
            ctx := context.WithValue(r.Context(), claimsKey, claims)
            next.ServeHTTP(w, r.WithContext(ctx))
        })
    }
}
```

**Python (fastapi/starlette):**

```python
class AuthMiddleware:
    def __init__(self, app: ASGIApp, auth: IdentityProvider) -> None:
        self.app = app
        self.auth = auth

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            return await self.app(scope, receive, send)

        headers = dict(scope.get("headers", []))
        token = headers.get(b"authorization", b"").decode()
        token = token.removeprefix("Bearer ")

        if not token:
            return await self._unauthorized(send)

        try:
            claims = await self.auth.verify_token(token)
            scope["state"]["claims"] = claims
        except AuthError:
            return await self._unauthorized(send)

        await self.app(scope, receive, send)
```

### JWT Verification (no external JWT library needed in most cases)

OIDC providers publish JWKS (JSON Web Key Sets). Verification steps:

1. Fetch JWKS from provider's `.well-known/openid-configuration`
2. Cache the JWKS (refresh every ~24h or on key miss)
3. Decode JWT header to get `kid` (key ID)
4. Find matching key in JWKS
5. Verify signature using the public key
6. Validate claims: `exp`, `iss`, `aud`

Most languages have stdlib crypto that can verify RS256/ES256 signatures. The OIDC-specific logic is minimal adapter code.

### OIDC Discovery (both Zitadel and Keycloak)

Both providers implement standard OIDC discovery. Your adapter fetches configuration dynamically:

```
GET {issuer_url}/.well-known/openid-configuration

Response contains:
  issuer: "https://auth.example.com"
  authorization_endpoint: "https://auth.example.com/oauth/v2/authorize"
  token_endpoint: "https://auth.example.com/oauth/v2/token"
  jwks_uri: "https://auth.example.com/oauth/v2/keys"
  userinfo_endpoint: "https://auth.example.com/oidc/v1/userinfo"
```

Your adapter reads these URLs from discovery rather than hardcoding them. Swapping from Keycloak to Zitadel (or vice versa) becomes a config change: just update the issuer URL.

**Minimal OIDC libraries (when stdlib crypto isn't enough for RS256/ES256):**

- Go: `coreos/go-oidc` + `golang.org/x/oauth2` or `zitadel/oidc`
- Rust: `openidconnect-rs`
- Python: `authlib` (lightweight, supports discovery + token validation)
- TypeScript: `openid-client`

**Zitadel-specific:** Event-sourced architecture, full audit trails, Session API for custom auth flows.
**Keycloak-specific:** More flexible for on-premise, deeper admin API for user provisioning.

## Authorization Patterns

### Role-Based Access Control (RBAC)

```
Claims {
  sub: "user_123"
  roles: ["admin", "order_manager"]
}

Permission check (domain logic):
  can_confirm_order(claims) -> claims.roles.contains("order_manager") || claims.roles.contains("admin")
```

### Attribute-Based Access Control (ABAC)

```
Policy:
  allow if user.org_id == resource.org_id AND user.role in ["manager", "admin"]

Check:
  fn authorize(claims: &Claims, resource: &Resource, action: Action) -> bool
```

### Authorization as a Port

```
Authorizer:
  can(subject: Claims, action: Action, resource: ResourceRef) -> bool

Adapters:
  - RBACAuthorizer (role-based, simplest)
  - PolicyAuthorizer (policy engine, Zitadel/Keycloak policies)
  - MockAuthorizer (testing - always allow or always deny)
```

## Input Validation (no validation libraries)

### Domain-Level Validation

Validation belongs in domain types. Use constructors/factory methods that reject invalid data.

**Rust:**

```rust
pub struct Email(String);

impl Email {
    pub fn parse(s: &str) -> Result<Self, ValidationError> {
        let s = s.trim().to_lowercase();
        if s.contains('@') && s.len() >= 5 && s.len() <= 254 {
            Ok(Self(s))
        } else {
            Err(ValidationError::InvalidEmail)
        }
    }
}
// Email can never contain invalid data - invariant enforced at construction
```

**Go:**

```go
type Email string

func NewEmail(s string) (Email, error) {
    s = strings.TrimSpace(strings.ToLower(s))
    if !strings.Contains(s, "@") || len(s) < 5 || len(s) > 254 {
        return "", ErrInvalidEmail
    }
    return Email(s), nil
}
```

**Python:**

```python
@dataclass(frozen=True)
class Email:
    value: str

    def __post_init__(self):
        v = self.value.strip().lower()
        if "@" not in v or len(v) < 5 or len(v) > 254:
            raise ValidationError("Invalid email")
        object.__setattr__(self, "value", v)
```

### SQL Injection Prevention

**Rule: ALWAYS use parameterized queries. No exceptions.**

```sql
-- SAFE: parameterized
SELECT * FROM users WHERE email = $1

-- DANGEROUS: string interpolation
-- SELECT * FROM users WHERE email = '{email}'  -- NEVER DO THIS
```

Every repository implementation in this system uses parameterized queries by default.

### XSS Prevention

- All user-generated content is HTML-encoded before rendering
- Content-Security-Policy headers set in transport adapter
- No `innerHTML` or equivalent in any response generation

## Rate Limiting (stdlib implementation)

### Token Bucket Algorithm

```python
class TokenBucket:
    def __init__(self, rate: float, capacity: int) -> None:
        self.rate = rate          # tokens per second
        self.capacity = capacity  # max burst
        self.tokens = capacity
        self.last_refill = time.monotonic()

    def consume(self) -> bool:
        now = time.monotonic()
        elapsed = now - self.last_refill
        self.tokens = min(self.capacity, self.tokens + elapsed * self.rate)
        self.last_refill = now

        if self.tokens >= 1:
            self.tokens -= 1
            return True
        return False
```

### Rate Limiter as Middleware

```
RateLimiter:
  store: HashMap<ClientKey, TokenBucket>  (in-memory)
  -- or --
  store: Redis (distributed)

  check(client_key) -> Allow | Deny(retry_after)
```

Client key extraction: API key, user ID from JWT, or IP address (fallback).

## CORS Configuration (no library needed)

Handle CORS at the transport adapter level with stdlib:

```
Preflight (OPTIONS):
  Access-Control-Allow-Origin: [configured origins]
  Access-Control-Allow-Methods: GET, POST, PATCH, DELETE, OPTIONS
  Access-Control-Allow-Headers: Authorization, Content-Type
  Access-Control-Max-Age: 86400

Actual request:
  Access-Control-Allow-Origin: [matching origin]
  Access-Control-Expose-Headers: X-RateLimit-Remaining, X-Request-Id
```

Implementation: a middleware that checks `Origin` header against allowed list, sets response headers. Pure stdlib string matching.

## Security Headers

Set in transport adapter (not domain concern):

```
Strict-Transport-Security: max-age=31536000; includeSubDomains
Content-Security-Policy: default-src 'self'
X-Content-Type-Options: nosniff
X-Frame-Options: DENY
X-Request-Id: [generated UUID for request correlation]
```

## Secrets Management

- Never hardcode secrets in source code
- Read from environment variables at the composition root
- Pass to adapters via constructor injection
- Log redaction: never log tokens, keys, or passwords
- Rotation: JWKS keys rotate automatically via OIDC discovery
