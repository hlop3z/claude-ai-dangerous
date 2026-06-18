---
name: sys-design
description: Converts a system idea into a structured Architecture Manifesto defining principles, priorities, and long-term architectural direction
argument-hint:
  [system, platform, or product idea to derive architectural principles from]
allowed-tools: Read, Grep, Glob
---

# Architecture Manifesto Builder — Idea → System Design Philosophy

Transform the input concept into a **high-level architecture manifesto** that defines enduring principles, structural priorities, and system-wide design philosophy.

Input: **$ARGUMENTS**

The output is NOT an implementation plan — it is a **strategic architectural north star** guiding all future design decisions.

---

# Phase 1: Context Extraction

Analyze the idea and extract:

- **System domain** — what kind of system this is (platform, SaaS, backend, infra, etc.)
- **Primary complexity drivers** — scale, integrations, workflows, state, concurrency, etc.
- **Change vectors** — what is expected to evolve over time
- **Risk areas** — coupling, vendor lock-in, complexity, performance, governance

---

# Phase 2: Architectural Intent

Define the intent of the architecture:

- What must the system optimize for long-term?
- What must the system explicitly avoid?
- What trade-offs are acceptable?
- What must remain stable vs what must remain flexible?

---

# Phase 3: Architectural Priorities

Derive a ranked set of architectural priorities tailored to the system.

Include patterns where appropriate:

- Plugin-based extensibility
- Hexagonal Architecture (Ports & Adapters)
- Clean Architecture (layered dependency inversion)
- Event-driven architecture
- Feature flags for runtime variability
- Dependency Injection for modularity

For each priority:

- Why it matters for this system
- What problem it prevents
- What risk it introduces if misused

---

# Phase 4: Core Architectural Model

Define the structural model of the system.

If applicable, unify:

## Hexagonal Architecture (Ports & Adapters)

- Core domain isolation from external systems
- Explicit ports for all I/O boundaries
- Adapters for all infrastructure concerns

## Clean Architecture

- Dependency direction enforcement (inward-only)
- Separation of domain, application, and infrastructure layers
- Framework independence at the core

## Combined Interpretation

Explain how both models apply together:

- What is treated as “core”
- What is considered “external”
- How boundaries are enforced in practice

---

# Phase 5: Design Philosophy

Generate a coherent set of guiding principles such as:

- Simplicity over abstraction
- Composition over inheritance
- Explicit boundaries over implicit coupling
- Runtime flexibility over compile-time rigidity (or vice versa, if justified)
- Convention over configuration (if applicable)
- Right pattern, right context

Each principle must include:

- Definition
- When it applies
- When it should NOT be used

---

# Phase 6: Core System Characteristics

Define the expected system properties:

- Modularity
- Decoupling
- Composability
- Extensibility
- Testability
- Framework independence
- Runtime adaptability

For each characteristic:

- Why it matters for this system
- How it manifests structurally
- What design decisions enforce it

---

# Phase 7: Strategic Engineering Goals

Produce a table of architectural goals:

| Goal | Intended Impact |

Include system-specific goals such as:

- Maintainability at scale
- Safe evolution over time
- Parallel team development
- Reduced cognitive load
- Controlled complexity growth
- Minimized coupling surface

---

# Phase 8: Usage Guidelines

Define how this manifesto should be used:

- As pre-implementation alignment tool
- As architectural review baseline
- As constraint system for design decisions
- As onboarding reference for engineers
- As protection against architectural drift

Also define:

- What violates the manifesto
- What requires re-evaluation of the manifesto itself

---

# Phase 9: Anti-Patterns

Explicitly list what this architecture rejects:

- Over-abstraction / premature generalization
- Tight coupling to frameworks or vendors
- Hidden dependencies
- Distributed business logic
- Overuse of design patterns without necessity
- Inconsistent boundary enforcement

---

# Phase 10: Output Format (STRICT)

Generate final output as a **formal Architecture Manifesto document** with:

- Title
- Objective
- Architectural Priorities
- Core Architectural Model
- Design Philosophy
- System Characteristics
- Strategic Goals
- Usage Guidelines
- Anti-Patterns

Style requirements:

- Declarative, not exploratory
- Opinionated but justified
- Stable, long-lived language (avoid implementation detail)
- Suitable as a “north star” document for engineering teams

---

# Execution Constraints

- MUST derive all principles from the input system context
- MUST NOT include implementation details or code
- MUST avoid technology-specific prescriptions unless structurally necessary
- MUST prioritize long-term architectural guidance over tactical decisions
- MUST produce a cohesive philosophy, not a list of unrelated ideas
