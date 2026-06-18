---
name: rfc-init
description: Converts a raw idea into a structured RFC-style specification with clear interfaces, behavior, constraints, and implementation guidance
argument-hint: [idea, concept, feature, or system to formalize]
allowed-tools: Read, Grep, Glob
---

# RFC Builder — Idea → Formal Specification

Transform the input idea into a **complete RFC-style technical specification**.

Input: **$ARGUMENTS**

The goal is to convert an informal concept into a precise, implementable, and unambiguous system spec.

---

# Phase 1: Idea Normalization

Restate the idea as a system with:

- **Purpose** — what problem it solves
- **Scope** — what is included
- **Out of scope** — explicitly excluded behavior
- **Actors** — who or what interacts with the system

Identify ambiguities and implicit assumptions.

---

# Phase 2: System Definition

Define the system as a formal specification:

## Core Concept

- Single-sentence definition of the system

## Functional Requirements

- List of observable behaviors the system MUST support

## Non-Functional Requirements

- Performance expectations
- Reliability constraints
- Scalability assumptions
- Security considerations (if applicable)

---

# Phase 3: Interface Specification

Define how the system is used.

## Input Contract

- Inputs (commands, events, data structures)
- Validation rules
- Required vs optional fields

## Output Contract

- Outputs (responses, side effects, events)
- Error formats
- Determinism expectations

## State Model (if applicable)

- Internal state representation
- State transitions
- Invariants

---

# Phase 4: Behavior Specification

Define system behavior in deterministic terms.

For each major function:

- Trigger condition
- Execution rules
- Edge cases
- Failure modes
- Expected outputs

Explicitly define:

- What MUST happen
- What MUST NOT happen
- What happens under invalid input

---

# Phase 5: Architecture Model (Optional but preferred)

Describe system structure:

## Components

- Logical modules or subsystems
- Responsibilities of each

## Data Flow

- How data moves through the system
- Where transformation occurs

## Dependencies

- External systems
- Libraries
- Services

---

# Phase 6: Edge Cases & Failure Handling

Define:

- Invalid input behavior
- System failure modes
- Partial failure handling
- Timeout/retry semantics (if applicable)

---

# Phase 7: Open Questions

List:

- Unknown requirements
- Ambiguous decisions
- Assumptions that need validation

---

# Phase 8: RFC Output Formatting

The final output MUST be a clean RFC-style document with:

- Title
- Abstract
- Terminology
- Specification sections
- Formal requirement language (MUST / SHOULD / MAY)
- Clear structure suitable for implementation

---

# Execution Rules

- Convert ideas into **precise system definitions**
- Remove ambiguity wherever possible
- Prefer deterministic behavior over vague descriptions
- Do not propose multiple solutions — produce ONE canonical spec
- Focus on implementability and clarity over theory
