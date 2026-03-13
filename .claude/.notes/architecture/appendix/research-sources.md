# Appendix: Research Sources

## Multi-Tenant Authorization (RBAC / ABAC / ReBAC)

- Oso — Multi-tenant authorization patterns, RBAC/ABAC comparison guides
- Auth0 — Fine-grained authorization documentation, tenant isolation patterns
- Permit.io — Authorization-as-a-service, OPAL (Open Policy Administration Layer) for real-time policy distribution
- Authzed / SpiceDB — Google Zanzibar open-source implementation, relationship-based access control (ReBAC)
- WorkOS — Multi-tenant RBAC evolution stages (static → configurable → custom roles), FGA documentation
- AWS Cedar — Formal policy verification, policy-as-code, AWS Verified Permissions
- OpenFGA — Open-source Zanzibar implementation by Auth0/Okta, tuple-based authorization
- Design Gurus — Authorization architecture patterns, PEP/PDP/PAP/PIP decomposition
- OWASP — Multi-tenant security cheat sheet, broken access control (Top 10 #1), deny-by-default guidance
- Salesforce — Multi-tenant permission model, two-layer system (platform ceiling + tenant customization)
- Uber Charter — Centralized policy repository, local evaluation library, ABAC attributes pattern
- Vernon (IDDD) — Identity & Access as dedicated bounded context, DDD authorization patterns
- XACML — Industry-standard PEP/PDP/PAP/PIP decomposition for authorization architecture

## Embedded Scripting Security

- Cloudflare (wirefilter) — Compile-then-evaluate pattern at massive scale, DSL-to-closure compilation
- Shopify — Tenant scripting sandboxing, multi-tenant code execution security
- Trail of Bits — Scripting engine security assessments, compile-then-evaluate safety validation
- OWASP — AST validation requirements, injection prevention, sandbox escape mitigation
- AWS Firecracker — MicroVM-based process isolation for untrusted code execution
- Scripting engine CVE databases — ongoing memory safety vulnerabilities in embedded engines

## Event-Sourced Systems

- Functional Event Sourcing Decider (Jeremie Chassaing, 2021) — Core Decider pattern: decide/evolve/initialState/isTerminal
- Production event sourcing libraries — Aggregate interface design, Services injection pattern
- Axon Framework — Upcaster chain pattern (10+ years production), IntermediateEventRepresentation, event versioning
- Message DB / Eventide (PostgreSQL) — Pure SQL event store API, stream naming conventions, consumer groups in SQL
- Marten Async Daemon — Projection infrastructure, Solo/HotCold modes, error handling policies, dead letter events
- EventStoreDB / Kurrent — Catch-up and persistent subscription models, checkpoint management, consumer group strategies
- Oskar Dudycz — Projections explained, stream lifecycle design ("close the books"), snapshot guidance, permissions as projections
- CodeOpinion — Authorization placement in event-sourced systems, permissions as read model projections
- Daniel Whittaker — Authorization as pipeline middleware/decorator, command pipeline patterns
- ByteByteGo — Event-driven authorization architecture, distributed system authorization patterns
- Chris Kiehl ("Event Sourcing is Hard") — Materialization lag UX problems, projection maintenance scaling, production lessons
- Michal Ostruszka / SoftwareMill — Replay debugging tools, practical event sourcing lessons learned
- Kurrent — Snapshot guidance (don't snapshot prematurely), event store best practices
- Kspeakman (Postgres) — Stream type vs event type separation, SOC column design for event stores
- CNCF CloudEvents — Graduated specification for technology-agnostic event envelopes, SDKs in 9+ technologies
- Buf Schema Registry — Protobuf schema management, backward compatibility detection, breaking change CI enforcement
- AsyncAPI — Event contract documentation standard, cross-team event discovery
