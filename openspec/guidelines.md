# Engineering Guidelines

The distilled reference behind `config.yaml`. Commands point here; they don't restate it.

## Build-vs-adopt hierarchy (EDF)

Default decision order — moving **down** requires explicit justification:

```
Rent infrastructure  >  Adopt OSS  >  Extend OSS  >  Fork OSS  >  Build new
```

- **Rent** — compute, storage, networking, CDN/DNS, clusters. Infra is never "proprietary software."
- **Adopt** — OSS meets ~90% of needs → configure, don't rewrite. Contribute upstream where possible.
- **Extend** — gaps remain → add via plugin / middleware / adapter / wrapper. Preserve upstream compatibility.
- **Fork** — only if upstream is unmaintained, divergence is unavoidable, and extension/contribution aren't viable. Record maintenance burden + sync strategy.
- **Build** — last resort: no viable OSS, architecturally incompatible, or it's genuinely your differentiating value.

### Maturity rubric (score OSS candidates)

| Criterion             | Weight |
| --------------------- | ------ |
| Feature coverage      | 30%    |
| Extensibility         | 20%    |
| Maintenance activity  | 15%    |
| Documentation         | 10%    |
| Community size        | 10%    |
| Security history      | 10%    |
| License compatibility | 5%     |

Hard rejects (override score): active security risk · incompatible license · abandoned maintenance.

### Decision matrix

| Situation                          | Default |
| ---------------------------------- | ------- |
| Infrastructure                     | Rent    |
| OSS ≥ 90% match                    | Adopt   |
| OSS 70–90% match                   | Extend  |
| Small gap, OSS close               | Fork    |
| No OSS / strategic differentiation | Build   |
| Commodity functionality            | Adopt   |

Evaluate **lifecycle** cost (integration, upgrades, patching, ops), not just first build. Revisit decisions every 6–12 months — none are permanent.

## Abstraction layers

| Layer | Artifact              | Holds                                                      | Never holds           |
| ----- | --------------------- | ---------------------------------------------------------- | --------------------- |
| WHAT  | `specs/<cap>/spec.md` | observable behavior, contracts, invariants                 | tech, structure       |
| HOW   | `design.md`           | core/adapter structure, dependency direction, tool choices | behavior redefinition |
| DO    | `tasks.md` + code     | the pinned implementation                                  | new rules or scope    |

- One canonical design — decide, don't list variants.
- Composable core; every surface is a thin adapter (no logic, no state).
- Dependencies point **inward**: adapters → application → domain core. Core runs with no surface present.

## Document taxonomy

Map docs to a canonical type — don't invent categories:

- **RFC** — proposed change (here: a `proposal` + `specs`). Lifecycle: **draft → approved**.
- **ADR** — one architectural decision + context/tradeoffs (here: build-vs-adopt blocks in `design.md`).
- **ADD** — system/service architecture · **TDD** — feature/subsystem design.
- **Runbook** — ops procedures · **Postmortem** — post-incident learning · **Threat Model** — security analysis.

Separation of concerns: ADR ≠ design doc · RFC ≠ implementation plan · Runbook ≠ postmortem.
