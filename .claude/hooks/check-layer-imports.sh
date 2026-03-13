#!/bin/bash
# PreToolUse hook: blocks Edit/Write operations that violate layer boundaries.
# Reads tool input from stdin as JSON.
# Exit 0 = allow, Exit 2 = block with message on stderr.

INPUT=$(cat)
TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty')
FILE=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')

# Only check Rust files and Cargo.toml
if [[ ! "$FILE" =~ \.(rs|toml)$ ]]; then
    exit 0
fi

# Determine which crate this file belongs to
CRATE=""
if [[ "$FILE" == *"/crates/domain/"* ]]; then
    CRATE="domain"
elif [[ "$FILE" == *"/crates/application/"* ]]; then
    CRATE="application"
elif [[ "$FILE" == *"/crates/adapters/"* ]]; then
    CRATE="adapters"
elif [[ "$FILE" == *"/crates/scripting/"* ]]; then
    CRATE="scripting"
elif [[ "$FILE" == *"/crates/server/"* ]]; then
    CRATE="server"
fi

# No crate matched — allow
if [[ -z "$CRATE" ]]; then
    exit 0
fi

# For Edit operations, check the new_string content
CONTENT=""
if [[ "$TOOL" == "Edit" ]]; then
    CONTENT=$(echo "$INPUT" | jq -r '.tool_input.new_string // empty')
elif [[ "$TOOL" == "Write" ]]; then
    CONTENT=$(echo "$INPUT" | jq -r '.tool_input.content // empty')
fi

if [[ -z "$CONTENT" ]]; then
    exit 0
fi

# --- Layer violation checks ---

# domain/ cannot import application, adapters, scripting, or server
if [[ "$CRATE" == "domain" ]]; then
    if echo "$CONTENT" | grep -qE '(use\s+(application|adapters|scripting|server)::|^\s*(application|adapters|scripting)\s*=)'; then
        echo "LAYER VIOLATION: domain/ cannot depend on application/, adapters/, scripting/, or server/. Domain is the innermost layer with zero I/O." >&2
        exit 2
    fi
    # Block I/O crates in domain Cargo.toml
    if [[ "$FILE" == *"Cargo.toml" ]]; then
        if echo "$CONTENT" | grep -qE '(sqlx|reqwest|hyper|axum|tonic|deadpool|redis\s*=|rquickjs|tokio\s*=)'; then
            echo "LAYER VIOLATION: domain/Cargo.toml cannot have I/O dependencies. Only pure data crates allowed (serde, uuid, chrono, thiserror, async-trait)." >&2
            exit 2
        fi
    fi
fi

# application/ cannot import adapters, scripting, or server
if [[ "$CRATE" == "application" ]]; then
    if echo "$CONTENT" | grep -qE '(use\s+(adapters|scripting|server)::|^\s*(adapters|scripting)\s*=)'; then
        echo "LAYER VIOLATION: application/ can only depend on domain/. It cannot import adapters/, scripting/, or server/." >&2
        exit 2
    fi
    # Block I/O crates in application Cargo.toml
    if [[ "$FILE" == *"Cargo.toml" ]]; then
        if echo "$CONTENT" | grep -qE '(sqlx|reqwest|hyper|axum|tonic|deadpool|redis\s*=|rquickjs)'; then
            echo "LAYER VIOLATION: application/Cargo.toml cannot have I/O dependencies. All I/O goes through port traits." >&2
            exit 2
        fi
    fi
fi

# adapters/ cannot import application, scripting, or server
if [[ "$CRATE" == "adapters" ]]; then
    if echo "$CONTENT" | grep -qE '(use\s+(application|scripting|server)::|^\s*(application|scripting)\s*=)'; then
        echo "LAYER VIOLATION: adapters/ can only depend on domain/. It cannot import application/, scripting/, or server/." >&2
        exit 2
    fi
fi

# scripting/ cannot import application, adapters, or server
if [[ "$CRATE" == "scripting" ]]; then
    if echo "$CONTENT" | grep -qE '(use\s+(application|adapters|server)::|^\s*(application|adapters)\s*=)'; then
        echo "LAYER VIOLATION: scripting/ can only depend on domain/. It cannot import application/, adapters/, or server/." >&2
        exit 2
    fi
fi

exit 0
