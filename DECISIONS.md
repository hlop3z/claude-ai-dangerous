# Decisions

Build-vs-adopt decisions recorded per `/ai:decide`. This is the fallback home the command
uses when a project has no active OpenSpec change and no `PROJECT.md`.

Concrete tool names live here only — `.canon/` and `openspec/specs/` stay abstract.

## Decisions

### Decision: Python dependency and workspace management — Adopt uv

- **Status**: approved
- **Why**: Specified by the user, and it is the only Python tool that covers workspaces, the
  lockfile, the interpreter, and PEP 723 single-file scripts in one binary — which is exactly
  the reusable/disposable split this workshop needs.
- **Considered**: Poetry (no PEP 723 script support, slower); pip + venv (no workspace or
  lockfile story).
- **Isolation**: `scripts/py/pyproject.toml`. Tool source imports nothing from uv; swapping it
  would change the run commands, not any tool's code.

### Decision: Go CLI framework — Adopt cobra

- **Status**: approved
- **Why**: The mature standard (kubectl, gh, hugo; ~44k stars) with subcommands, generated
  help, and shell completions. The reference tool's own shape — download / retry / merge /
  validate / cleanup — is a subcommand tree, which is where stdlib `flag` fails outright.
  Boilerplate cost is paid by the scaffold, not by hand.
- **Considered**: urfave/cli (lighter, mature, weaker completions); stdlib `flag` (zero deps,
  but no short/long pairing, no required args, no subcommands — hand-rolling those is exactly
  what the never-hand-roll rule forbids).
- **Isolation**: `cmd/<name>/main.go` only. Logic lives in `internal/`, which imports no CLI
  library, so replacing cobra touches adapters alone.

### Decision: Python CLI framework — Adopt cyclopts

- **Status**: approved
- **Why**: Beats typer on the two highest-weighted rubric criteria. Feature coverage (30%):
  Unions, Literals, and mutually exclusive groups, none of which typer supports. Documentation
  (10%): ships API docs; typer does not. Maintenance is strong — 138 releases, latest days
  old, 56 contributors, Apache-2.0. Its type-hint-driven design also makes promotion cheap:
  a lab function becomes a CLI without being rewritten.
- **Considered**: typer (larger community, ~17k stars vs ~1.2k — the one criterion cyclopts
  loses, weighted 10%; no Union support); click (mature and explicit, but more boilerplate and
  no type-hint inference); argparse (stdlib, zero deps, verbose and fully manual validation).
- **Risk accepted**: smaller community means a thinner bus factor than typer's. Mitigated by
  the isolation below — a migration would be confined to `cli.py` files.
- **Isolation**: `src/<name>/cli.py` only. `core.py` holds plain functions that import no CLI
  library.

### Decision: Disposable script packaging — Adopt PEP 723 inline metadata

- **Status**: approved
- **Why**: A uv workspace member needs a `pyproject.toml` and enters the shared lockfile,
  which is the opposite of disposable — every experiment would become a resolution event and
  every deletion would leave the lockfile inconsistent. PEP 723 keeps dependencies in the file
  that uses them and runs in an ephemeral environment. Verified working with `uv run`.
- **Considered**: workspace member per experiment (lockfile churn, deletion inconsistency);
  gitignored member directory (breaks `uv sync` on a fresh clone, since the lockfile
  references a path that isn't there); a shared `lab` package with pooled dependencies (one
  experiment's dependency becomes everyone's).
- **Isolation**: `scripts/py/lab/`, listed under `exclude` in the workspace root.
