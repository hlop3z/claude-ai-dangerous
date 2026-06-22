---
name: sys-plan
description: Produces the single abstract, language-agnostic RFC of WHAT to build, written to docs-sys/rfc.md
argument-hint: [idea, concept, feature, or system to formalize]
allowed-tools: Read, Grep, Glob, Write
---

# sys-plan — Idea → The single RFC of WHAT to build

Transform the input idea into the project's **one canonical RFC**: an abstract, implementation-free description of **what** the system is and must do.

Input: **$ARGUMENTS**

This produces the content of **`docs-sys/rfc.md`** — the single source of truth for scope and behavior. There is exactly ONE such document; this command writes/replaces its content, it does not create per-feature files.

---

## Hard constraints

- **Single design.** One canonical specification. Do NOT propose alternatives or variants — decide and state the one design.
- **Abstract, not literal.** Describe behavior, contracts, and intent. Do NOT record concrete implementation, code, file names, schemas-as-written, or step-by-step procedures.
- **Programming-language agnostic.** No language, framework, library, vendor, or runtime names. Express everything in terms of capabilities, inputs, outputs, and rules that hold regardless of stack.
- **Deterministic & unambiguous.** Use MUST / SHOULD / MAY. Remove vagueness. Prefer precise observable behavior over prose.
- **Composable core, thin surfaces.** Specify the system as a set of small capabilities that compose like building blocks. Every point of interaction — command-line, graphical, or programmatic interface — MUST be described as a thin wrapper over those capabilities: it translates input and renders output only, holding no behavior of its own. Define behavior once, at the capability level, never per surface.

---

## What to define

### 1. Purpose & scope

- The problem solved, in one sentence.
- In scope / explicitly out of scope.
- Actors that interact with the system (abstract roles, not concrete systems).

### 2. Capabilities (functional requirements)

- The observable behaviors the system MUST support, stated abstractly.
- For each: trigger, expected outcome, and what MUST NOT happen.
- Each capability MUST be self-contained and combinable with others, and MUST be invocable identically regardless of which surface (command-line, graphical, programmatic) triggers it. No behavior may be unique to a single surface.

### 3. Contracts (interfaces, abstractly)

- Inputs: shape, validation rules, required vs optional — described conceptually, not as a concrete schema.
- Outputs: results, side effects, error conditions, determinism expectations.
- Invariants that must always hold.

### 4. Behavior & edge cases

- For each capability: normal path, edge cases, failure modes, behavior under invalid input.

### 5. Non-functional expectations

- Performance, reliability, scalability, security expectations — as goals/limits, not mechanisms.

### 6. Open questions

- Unknowns, ambiguous decisions, and assumptions that need validation.
- Flag every critical concern whose realization is a **build-vs-adopt** decision (hand-written vs. delegated to a mature tool). Name the concern abstractly only; the concrete tool choice is deferred to the coding ruleset's interactive decision protocol, not decided here.

---

## Output

Produce a clean RFC document — Title, Abstract, Terminology, then the sections above — using MUST / SHOULD / MAY. Nothing language- or implementation-specific may appear.

**Write the document to `docs-sys/rfc.md`**, creating the `docs-sys/` folder and the file if they do not exist, and replacing the file's content if it does. The written file is the complete output; do not leave the spec only in chat.
