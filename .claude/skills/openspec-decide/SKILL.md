---
name: openspec-decide
description: Build-vs-adopt gate for a change. Use when deciding whether a critical concern should be built by hand or delegated to a mature tool (Rent/Adopt/Extend/Fork/Build), recording each decision into design.md before implementation.
license: MIT
compatibility: Requires openspec CLI.
metadata:
  author: hlop3z
  version: "1.0"
  generatedBy: "1.4.1"
---

Resolve the **build-vs-adopt** question for an OpenSpec change before implementing it.

For each critical concern, walk `Rent > Adopt > Extend > Fork > Build` (see `openspec/guidelines.md`), research current options, recommend one, and record the decision in the change's `design.md`. Prevents hand-writing what a mature tool already does well.

**Input**: Optionally a change name. If omitted, infer from context, auto-select the only active change, or run `openspec list --json` and ask which.

**Steps**

1. **Resolve paths** — `openspec status --change "<name>" --json`. Read `proposal.md` and the design file at `artifactPaths.design.resolvedOutputPath`. If `actionContext.mode` is `workspace-planning`, stop (unsupported).

2. **List critical concerns** — take those flagged in the proposal's Capabilities (correctness/security/reliability). If none, scan proposal + specs, propose a short list, and confirm with the user.

3. **Run the gate per concern**:
   - Infrastructure → `Rent`, done.
   - Else **research with WebSearch** (current options, not remembered). Score against the maturity rubric in `openspec/guidelines.md`; apply hard rejects (security / license / abandoned).
   - Present **≤3 options** as build-vs-adopt, one-line trade-off each, **always ending with a recommendation** and its tier.
   - Wait for the user's pick. Status is `draft` until confirmed, then `approved` (no "rejected" state).

4. **Record into `design.md`** — a `## Decisions` section, one block per concern:
   ```markdown
   ### Decision: <concern> — <Adopt|Extend|Fork|Build> <tool-or-"hand-written">
   - **Status**: approved
   - **Why**: <one line>
   - **Considered**: <other options, one line each>
   - **Isolation**: <adapter/boundary the choice lives behind>
   ```
   Tool names live in `design.md` only — keep `config.yaml` and `specs/` abstract.

5. **Summary** — concern → decision → status; flag any still `draft`.

**Guardrails**
- Research before recommending; ≤3 options, always a recommendation.
- Default toward Adopt/Extend; `Build` needs an explicit one-line justification.
- Draft → approved only. Decide HOW, not WHAT — if a decision exposes a scope problem, suggest updating the proposal/specs instead.
