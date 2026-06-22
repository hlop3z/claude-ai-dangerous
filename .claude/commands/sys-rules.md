---
name: sys-rules
description: Produces the single abstract, language-agnostic set of coding rules to follow, written to docs-sys/rules.md
argument-hint: [system, platform, or product idea to derive coding rules from]
allowed-tools: Read, Grep, Glob, Write, WebSearch, WebFetch
---

# sys-rules — Idea → The single ruleset for HOW to code

Transform the input concept into the project's **one canonical ruleset**: the abstract principles and constraints that all code MUST follow.

Input: **$ARGUMENTS**

This produces the content of **`docs-sys/rules.md`** — the single source of truth for how code is built. There is exactly ONE such document; this command writes/replaces its content. It is a constraint system, NOT an implementation plan.

---

## Hard constraints

- **Single design.** One coherent philosophy, not a menu of options. Decide the rules and state them.
- **Abstract, not literal.** Rules express principles and boundaries, never concrete code, file layouts, or procedures.
- **Programming-language agnostic.** No language, framework, library, vendor, or runtime names. Rules must hold regardless of stack.
- **Declarative & enforceable.** Each rule is a clear MUST / SHOULD / MAY that an author or reviewer can check against.

---

## What to define

### 1. Architectural priorities (ranked)

- The few priorities that govern this system, each with: why it matters, what it prevents, the risk if misused.

### 2. Structural model

- What is "core" vs "external"; the allowed direction of dependencies; how boundaries are enforced — all in abstract terms (ports/adapters, layering, isolation as concepts, not as named tech).
- **Composable like building blocks.** The system MUST be assembled from small, self-contained units that snap together through stable, uniform interfaces. Each unit MUST do one thing, own no hidden state of its neighbors, and be replaceable or recombinable without rework elsewhere. Behavior emerges from composition, not from large bespoke pieces.
- **Entry points are thin wrappers.** Every delivery surface — command-line, graphical, programmatic interface, or any other point of interaction — MUST be a thin adapter that only translates between the outside world and core capabilities. It MUST carry no business logic, no decision-making, and no state of its own: it parses/validates input, delegates to the core, and renders the result. All such surfaces MUST be interchangeable views over the same underlying capabilities, so that adding or removing one changes no behavior.

### 3. Design principles

- The guiding principles (e.g. simplicity over abstraction, composition over inheritance, explicit boundaries over implicit coupling).
- Each principle: definition, when it applies, when it MUST NOT be applied.
- **Adopt, don't reinvent, for critical concerns.** For anything critical — correctness-, security-, or reliability-sensitive — the system MUST rest on a mature, widely-adopted, actively-maintained external component rather than a bespoke implementation. Self-writing a critical concern is a defect unless no proven option exists and the decision is recorded. Reserve self-written code for the parts that are genuinely the system's own value.

### 4. Required properties

- The properties code MUST preserve (modularity, decoupling, composability, testability, framework independence) and how each is upheld structurally.
- **Composability** is first-class: any capability MUST be reachable and combinable independently of the surface that invokes it, and the core MUST be fully exercisable without any specific entry point present.

### 5. Anti-patterns (rejected)

- What this codebase explicitly forbids (over-abstraction, hidden dependencies, tight coupling to frameworks/vendors, scattered business logic, gratuitous patterns).
- **Fat entry points** — logic, branching, or state living in a command-line, graphical, or programmatic surface instead of the core — are forbidden. So are monolithic units that cannot be recombined, and capabilities that can only be reached through one specific surface.

### 6. Enforcement

- What constitutes a violation.
- What requires re-evaluating the rules themselves rather than the code.

---

## Decision protocol (interactive — happens in chat, not in the file)

Before finalizing, for each critical concern that could be either hand-written or delegated to a tool:

- **Research first.** Use web search to find the current, actively-maintained options — do not rely on memory; tooling moves.
- **Discuss with the user.** Present the choice as **pure-language vs. tool**, offering **at most 3 options total**, each with a one-line trade-off, and **always end with a clear recommendation** (which one and why).
- **Wait for the user's pick** before treating any specific tool as settled.
- **Keep the written `rules.md` abstract.** The concrete tool names belong only in this chat discussion. The file records the _principle_ (adopt mature components for critical concerns), never the vendor/library names chosen.

---

## Output

Produce a clean, declarative ruleset — Title, Objective, then the sections above — written as stable, long-lived, opinionated-but-justified rules. Nothing language- or implementation-specific may appear.

**Write the document to `docs-sys/rules.md`**, creating the `docs-sys/` folder and the file if they do not exist, and replacing the file's content if it does. The written file is the complete output; do not leave the ruleset only in chat.
