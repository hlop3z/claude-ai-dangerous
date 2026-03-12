---
name: tdd
description: Test-Driven Development discipline for all coding tasks. Use when writing new features, fixing bugs, refactoring code, adding system components, or implementing any logic. Enforces RED-GREEN-REFACTOR cycle, test-first development, and isolation of core logic from external dependencies. Applies to any language.
argument-hint: [component or feature description]
allowed-tools: Read, Grep, Glob, Bash(*)
---

# Test-Driven Development - Strict RED-GREEN-REFACTOR Discipline

You are operating under **strict TDD discipline**. Every piece of logic you write MUST be driven by a failing test first. No exceptions.

## The Cycle (follow this exactly)

### 1. RED - Write a Failing Test First

Before writing ANY implementation code:

- Write **one test** for **one behavior**
- Run it — confirm it **fails for the correct reason** (not a syntax error, not a missing import — the actual assertion fails or the function doesn't exist yet)
- Test name format: `test_<component>_<scenario>_<expected_result>`

**What to test first (priority order):**

1. Happy path — the core behavior works
2. Edge cases — boundary values, empty inputs, zero, max values
3. Error paths — invalid input, missing resources, permission failures
4. Integration points — adapters, system calls, I/O boundaries

### 2. GREEN - Write Minimal Code to Pass

- Implement **only** what the failing test demands
- No extra features, no "while I'm here" additions
- No premature optimization
- The goal is the shortest path from red to green

### 3. VERIFY - Run the Full Suite

- Run **all tests**, not just the new one
- If anything regressed, fix it immediately before proceeding
- Never move to refactor with a broken suite

### 4. REFACTOR - Clean Up Under Green Tests

- Remove duplication (DRY)
- Extract constants, helpers, shared types
- Simplify complex expressions
- Improve naming
- **Tests must stay green throughout** — run after each refactor step

### 5. REPEAT - Next Behavior

- Pick the next smallest testable behavior
- Return to RED

## Isolation Rules

### Core Logic (Domain / Pure Functions)

- **Zero external dependencies** — no file I/O, no network, no database, no OS calls
- Testable with fast, deterministic unit tests
- Receives dependencies via injection (traits, interfaces, protocols, function parameters)

### Boundary Code (Adapters / I/O)

- Wraps external systems behind abstractions defined by core logic
- Tested with integration tests (real DB, real filesystem) or contract tests
- Unit tests use fakes/mocks implementing the same interface

### Test Pyramid

```
         /  E2E  \        Few, slow, validate full workflows
        /----------\
       / Integration \     Moderate, test real I/O boundaries
      /----------------\
     /    Unit Tests     \  Many, fast, test core logic
    /______________________\
```

## Language-Specific Testing Patterns

### Rust
- Framework: `#[cfg(test)]` module + `#[test]`, or `cargo-nextest`
- Assertions: `assert_eq!`, `assert!(matches!(...))`, `assert!(result.is_err())`
- Mocking: trait objects or generics with test implementations
- Run: `cargo test` or `cargo nextest run`

### Python
- Framework: `pytest`
- Assertions: plain `assert`, `pytest.raises` for errors
- Mocking: `unittest.mock.patch` for adapters, prefer dependency injection over patching
- Fixtures: `@pytest.fixture` for setup, `conftest.py` for shared fixtures
- Run: `pytest -v` or `pytest -x` (stop on first failure)

### Go
- Framework: stdlib `testing` package
- Assertions: manual checks or `testify/assert`
- Table-driven tests for multiple scenarios
- Mocking: interface satisfaction with test structs
- Run: `go test ./...`

### TypeScript / JavaScript
- Framework: `vitest` (preferred), `jest`, or native `node --test`
- Assertions: `expect(x).toBe(y)`, `expect(() => fn()).toThrow()`
- Mocking: `vi.mock()` for modules, dependency injection for services
- Run: `npx vitest` or `npm test`

## Anti-Patterns to Block

| If you catch yourself doing this... | Stop and do this instead |
|--------------------------------------|--------------------------|
| Writing implementation before a test | Write the failing test first |
| Writing multiple tests before any implementation | One test at a time — RED then GREEN |
| Testing private/internal methods | Test observable behavior through public API |
| Mocking everything | Only mock I/O boundaries; test core logic directly |
| Writing a test that passes immediately | The test isn't driving new behavior — rethink it |
| Skipping the refactor step | Refactor now; technical debt compounds fast |
| Hard-coding values to pass tests | Triangulate — add another test to force real logic |

## Session Workflow

When the user asks you to build something:

1. **Clarify scope** — what behaviors need to exist?
2. **List test cases** — outline the RED tests you'll write (share with user)
3. **Cycle through each** — RED, GREEN, VERIFY, REFACTOR for each behavior
4. **Show progress** — after each GREEN, briefly state what's passing
5. **Final suite run** — run everything at the end to confirm

When the user asks you to fix a bug:

1. **Write a failing test** that reproduces the bug
2. **Confirm it fails** for the right reason
3. **Fix the bug** — minimal change
4. **Confirm the test passes** along with the full suite

When the user asks you to refactor:

1. **Ensure tests exist** for current behavior (write them if missing)
2. **Refactor under green tests** — small steps, run tests after each
3. **No behavior changes** unless explicitly requested

## Constants and Configuration

- Centralize magic numbers, timeout values, buffer sizes, and thresholds
- Use named constants or configuration objects — never inline literals in logic
- Test configuration should be explicit, not inherited from production defaults
