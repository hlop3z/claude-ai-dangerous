#!/bin/sh

set -eu

# -----------------------------
# CONFIGURATION
# -----------------------------

REPO_OWNER="hlop3z"
REPO_NAME="claude-ai-dangerous"

REMOVE_PATHS="
install.sh
LICENSE
README.md
.notes/
"

# -----------------------------
# URL(s)
# -----------------------------
REPO_URL="https://github.com/${REPO_OWNER}/${REPO_NAME}.git"
RAW_INSTALL_URL="https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/main/install.sh"

# -----------------------------
# DERIVED CONSTANTS
# -----------------------------

WORK_DIR="$(mktemp -d)"
CLONE_DIR="${WORK_DIR}/${REPO_NAME}"
FINAL_DIR="${PWD}/${REPO_NAME}"

# -----------------------------
# HELP
# -----------------------------

print_help() {
  cat <<EOF

curl -sSL ${RAW_INSTALL_URL} | sh
EOF
}

# -----------------------------
# LOGGING
# -----------------------------

log() {
  echo "[install] $1"
}

# -----------------------------
# CLEANUP FUNCTION
# -----------------------------

cleanup() {
  rm -rf "$WORK_DIR"
}

trap cleanup EXIT

# -----------------------------
# ARGUMENTS
# -----------------------------

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  print_help
  exit 0
fi

# -----------------------------
# CLEANUP LOGIC
# -----------------------------

remove_paths() {
  log "Cleaning unnecessary files..."

  for path in $REMOVE_PATHS; do
    if [ -e "$path" ]; then
      log "Removing: $path"
      rm -rf "$path"
    else
      log "Not found: $path"
    fi
  done
}

# -----------------------------
# INSTALL FLOW
# -----------------------------

log "Cloning repository into temp workspace..."
git clone "$REPO_URL" "$CLONE_DIR"

cd "$CLONE_DIR"

remove_paths

log "Installing to final location..."

if [ -d "$FINAL_DIR" ]; then
  echo "[error] Target already exists: $FINAL_DIR"
  exit 1
fi

mv "$CLONE_DIR" "$FINAL_DIR"

log "Installation complete at: $FINAL_DIR"