# Project Rules (self-enforced)

This project is governed by **4 rules**. Rules 1–3 are abstract and language-agnostic, spread across 4 files in `docs-sys/`. Rule 4 is the concrete frontend state ruleset, living in `.claude/commands/`. Know them every session.

| Rule                | File(s)                                            | Purpose                     |
| ------------------- | -------------------------------------------------- | --------------------------- |
| 1. What to build    | `docs-sys/rfc.md`                                  | The system's spec           |
| 2. How to code      | `docs-sys/rules.md`                                | The coding ruleset          |
| 3. What to remember | `docs-sys/ai_memory.md` + `docs-sys/ai_session.md` | Persistent + session memory |
| 4. Frontend state   | `.claude/commands/sys-frontend.md`                 | The frontend state ruleset  |

Rules 1–3 are single, abstract, programming-language-agnostic. Read the relevant ones before writing code and keep them in sync.

---

## Rule 1 — `docs-sys/rfc.md` — WHAT to build

The single canonical RFC: scope, capabilities, contracts, and behavior of the system, in abstract terms.

- Generated/maintained via `/sys-plan`, which writes this file directly (creating `docs-sys/` and the file if missing).
- Before building anything non-trivial, read `rfc.md`. The code MUST conform to it.
- If reality forces a change, update `rfc.md` first (re-run `/sys-plan`), then change the code.

## Rule 2 — `docs-sys/rules.md` — RULES to follow when coding

The single canonical ruleset: architectural priorities, principles, required properties, and anti-patterns the code MUST obey.

- Generated/maintained via `/sys-rules`, which writes this file directly (creating `docs-sys/` and the file if missing).
- Every change MUST comply with `rules.md`. A change that violates it is a defect — fix the change, or, if the rule is genuinely wrong, update `rules.md` first (re-run `/sys-rules`).

## Rule 3 — Memory (`ai_memory.md` + `ai_session.md`)

Two memory files with a clean separation of concerns. Keep BOTH small — they are a high-level-abstraction index, never a literal record.

### `docs-sys/ai_memory.md` — persistent memory

Things that matter long-term and save us time and context across sessions.

- Primarily tracks **how the system fits together**: which `adapters` / `ports` / `domains` are associated with each other.
- Track at the **folder** level by default; reference individual **files** only on special occasions.
- Always use a **`./` relative path** so entries are local to `docs-sys/`, never an absolute OS path.
- Keep it **small** with a clean SoC — one concern per entry. Prune anything no longer true.

### `docs-sys/ai_session.md` — session cache

A scratch tracker for the **current session only** — like cache memory of what matters right now at a high level of abstraction.

- High-level-abstraction notes only; ephemeral, not committed.
- Safe to clear/overwrite each session. Promote anything that proves durable into `ai_memory.md`.

## Rule 4 — `.claude/commands/sys-frontend.md` — FRONTEND state model

The single canonical frontend state ruleset. Unlike Rules 1–3, this one is **concrete and may name tools** — it is the deliberate exception to Rule 2's "adopt a mature external library for critical concerns": frontend state is **our own model**, a stable path-based reactive store contract.

- Invoked/maintained via `/sys-frontend`. Read it before building any frontend state; the code MUST conform.
- Prefer **`nanostores`** as the state model whenever it fits.
- In **Preact / React**, use **signals** when `nanostores` is not a good fit.
- The store's public contract is **stable** — depend on the surface, never internals; never introduce a competing state mechanism.

---

## Standing constraints

These constraints govern **Rules 1–3** (the `docs-sys/` files). **Rule 4 is the deliberate exception**: it is concrete and may name tools (`nanostores`, signals).

- **Single design** — `rfc.md` and `rules.md` each give one canonical answer, no alternatives.
- **Abstract, not literal** — principles, contracts, intent, and associations; never implementation detail or code.
- **Language-agnostic** — no language, framework, library, or vendor names.
- **`./` relative paths** in memory — local to `docs-sys/`, not the OS filesystem.
- **Four files only** — the design/memory files in `docs-sys/` are exactly `rfc.md`, `rules.md`, `ai_memory.md`, `ai_session.md`. Meta files (e.g. `.gitignore`) are allowed; nothing else.
