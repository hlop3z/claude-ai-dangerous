# Validation commands

The canonical commands for Rule 6. **Use these exact commands** — don't improvise an
equivalent, and don't guess at a package manager the project doesn't use.

This file is per-project. The template ships it nearly empty on purpose: fill a row in the
moment you first discover the real command, so the next session doesn't rediscover it.

| Check             | Command                          | Status                                                                                             |
| ----------------- | -------------------------------- | -------------------------------------------------------------------------------------------------- |
| Formatter         | `sh scripts/format_markdown.sh`  | Markdown only — add the code formatter                                                             |
| Linter            | —                                | not yet defined                                                                                    |
| Type checker      | —                                | not yet defined                                                                                    |
| Unit tests        | —                                | not yet defined                                                                                    |
| Integration tests | —                                | not yet defined                                                                                    |
| Build             | —                                | not yet defined                                                                                    |
| File-size review  | `bash scripts/loc_rust.sh [min]` | Rust only — lists files over `min` LOC (default 500), per the thresholds in `.canon/guidelines.md` |

A row marked "not yet defined" is a real answer: that check is **unverified** and Rule 6 says
to report it as such. It is not permission to skip it silently.

If a project defines these somewhere canonical already — `package.json` scripts, a `Makefile`,
`justfile`, `Cargo.toml` — point at that instead of copying the commands here. One home.
