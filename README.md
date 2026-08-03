# Project: Dangerous Development

Install into the current directory — existing files are never overwritten:

```sh
curl -sSL https://raw.githubusercontent.com/hlop3z/claude-ai-dangerous/main/install.sh | sh
```

Pull newer template versions into an existing install:

```sh
curl -sSL https://raw.githubusercontent.com/hlop3z/claude-ai-dangerous/main/install.sh | sh -s -- --update
```

`--update` overwrites only template-owned paths (`.claude/commands/`,
`openspec/guidelines.md`), copies anything new that's missing, and leaves your
`CLAUDE.md`, `openspec/config.yaml`, settings, and scripts alone — reporting which of
them have drifted from the template so you can merge by hand. It requires a clean git
tree, so `git diff` shows exactly what changed and `git checkout` undoes it.
