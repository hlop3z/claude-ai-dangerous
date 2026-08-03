# Project: Dangerous Development

Install into the current directory — existing files are never overwritten:

```sh
curl -sSL https://raw.githubusercontent.com/hlop3z/claude-ai-dangerous/main/install.sh | sh
```

Pull newer template versions into an existing install:

```sh
curl -sSL https://raw.githubusercontent.com/hlop3z/claude-ai-dangerous/main/install.sh | sh -s -- --update
```

`--update` overwrites only template-owned paths (`.canon/rules/`, `.canon/guidelines.md`,
`.claude/commands/`), copies anything new that's missing, and leaves your `CLAUDE.md`,
`.canon/checks.md`, `openspec/config.yaml`, settings, and scripts alone — reporting which of
them have drifted from the template so you can merge by hand. It requires a clean git tree,
so `git diff` shows exactly what changed and `git checkout` undoes it.

## Layout

| Path                   | Owner    | Notes                                                     |
| ---------------------- | -------- | --------------------------------------------------------- |
| `.canon/`              | yours    | The engineering rules. No external tool writes here.      |
| `CLAUDE.md`            | yours    | Always-loaded index: pipeline, precedence, rule triggers. |
| `.claude/commands/ai/` | yours    | Custom commands. Work with or without OpenSpec installed. |
| `openspec/config.yaml` | bridge   | Our content, OpenSpec's schema. Re-derive from `.canon/`. |
| `openspec/`, `opsx/`   | upstream | Vendored from the OpenSpec CLI. Regenerable, expendable.  |
