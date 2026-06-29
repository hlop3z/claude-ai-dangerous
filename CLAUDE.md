# How to develop here

This project drives all work through **OpenSpec**, augmented with an abstraction-layer
discipline and a build-vs-adopt gate. Follow the pipeline — the rules apply themselves.

```
/opsx:explore   Think it through. Decompose (invariants, boundaries, ≥3 strategies). No code.
      ↓
/opsx:propose   Generate proposal.md (WHY/scope) + specs (abstract WHAT) + design.md (HOW).
      ↓
/opsx:decide    Build-vs-adopt gate: per critical concern, Rent>Adopt>Extend>Fork>Build.
      ↓             Records each decision into design.md. Run before implementing.
/opsx:apply     Implement the tasks. Thin entry points; adapters isolate every dependency.
      ↓
/opsx:sync      Fold the change's delta specs into the main specs.
      ↓
/opsx:archive   Close out the completed change.
```

## The two ideas that make this work

1. **Abstraction layers stay separate.** WHAT (`specs/`) is language-agnostic behavior.
   HOW (`design.md`) is structure + tool choices. DO (`tasks.md` + code) is the implementation.
   No layer leaks into another. Core holds behavior; every surface (CLI/GUI/API) is a thin adapter.

2. **Adopt before you build.** For anything correctness-, security-, or reliability-critical,
   prefer a mature tool over hand-writing it. `/opsx:decide` makes that call explicit and records it.

## Where the rules live (don't restate them)

- **`openspec/config.yaml`** — the philosophy, injected once into every artifact by the CLI.
- **`openspec/guidelines.md`** — the full reference: build-vs-adopt hierarchy, maturity rubric, doc taxonomy.

Commands stay thin and point at these, so a change costs few tokens to plan.
