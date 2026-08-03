#!/bin/sh

set -eu

# -----------------------------
# CONFIGURATION
# -----------------------------

REPO_OWNER="hlop3z"
REPO_NAME="claude-ai-dangerous"

# The installer's own files — never copied into a destination.
REMOVE_PATHS="
install.sh
LICENSE
README.md
"

# Template-owned. Overwritten by --update; the template is the source of truth.
MANAGED_PATHS="
.canon/rules
.canon/guidelines.md
.canon/README.md
.claude/commands
"

# Seeded once, then yours. Never overwritten — --update only reports drift.
SEEDED_PATHS="
CLAUDE.md
.canon/checks.md
DECISIONS.md
openspec/config.yaml
.claude/settings.json
.mcp.json
.gitignore
scripts
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
DEST_DIR="${PWD}"

MODE="install"
FORCE="0"

# -----------------------------
# HELP
# -----------------------------

print_help() {
  cat <<EOF

Install:  curl -sSL ${RAW_INSTALL_URL} | sh
Update:   curl -sSL ${RAW_INSTALL_URL} | sh -s -- --update

  --update   Refresh template-owned files in place. Overwrites:
$(for p in $MANAGED_PATHS; do printf '               %s\n' "$p"; done)
             Copies anything new that is missing, never clobbers your own files,
             and reports which seeded files have drifted from the template.
  --force    Skip the clean-git-tree guard used by --update.
  -h         Show this help.

Without --update, existing files are left untouched (first-install behavior).
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

while [ $# -gt 0 ]; do
  case "$1" in
    -h | --help)
      print_help
      exit 0
      ;;
    --update)
      MODE="update"
      ;;
    --force)
      FORCE="1"
      ;;
    *)
      log "Unknown option: $1"
      print_help
      exit 1
      ;;
  esac
  shift
done

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
# UPDATE HELPERS
# -----------------------------

# --update overwrites files. Git is the review surface and the undo, so refuse to
# run without one unless the caller explicitly accepts the risk.
require_reviewable_dest() {
  if [ "$FORCE" = "1" ]; then
    log "WARNING: --force given; skipping the clean-tree guard."
    return 0
  fi

  if ! git -C "$DEST_DIR" rev-parse --git-dir >/dev/null 2>&1; then
    log "ERROR: $DEST_DIR is not a git repository."
    log "       --update overwrites template-owned files and git is the only undo."
    log "       Initialize a repo, or re-run with --force to accept the risk."
    exit 1
  fi

  if [ -n "$(git -C "$DEST_DIR" status --porcelain)" ]; then
    log "ERROR: working tree has uncommitted changes."
    log "       Commit or stash first, so 'git diff' shows exactly what the update changed."
    exit 1
  fi
}

overwrite_managed() {
  src="${CLONE_DIR}/$1"
  dst="${DEST_DIR}/$1"

  if [ ! -e "$src" ]; then
    log "Managed path missing from template, skipped: $1"
    return 0
  fi

  mkdir -p "$(dirname "$dst")"
  rm -rf "$dst"
  cp -R "$src" "$dst"
  log "Updated: $1"
}

report_seeded_drift() {
  src="${CLONE_DIR}/$1"
  dst="${DEST_DIR}/$1"

  # Missing locally: it was just seeded by the copy step, nothing to report.
  if [ ! -e "$src" ] || [ ! -e "$dst" ]; then
    return 0
  fi

  if ! diff -rq "$src" "$dst" >/dev/null 2>&1; then
    log "Differs from template (kept yours): $1"
  fi
}

# -----------------------------
# INSTALL FLOW
# -----------------------------

log "Cloning repository into temp workspace..."
git clone --depth 1 "$REPO_URL" "$CLONE_DIR"

cd "$CLONE_DIR"

remove_paths

# Drop the clone's git history so it is not copied into the destination.
rm -rf "${CLONE_DIR}/.git"

if [ "$MODE" = "update" ]; then
  require_reviewable_dest
fi

log "Installing into: $DEST_DIR"

# Merge the cleaned contents (including dotfiles) into the current directory,
# overlaying onto any existing folders. The -n flag skips files that already
# exist, so nothing in the destination is overwritten. Temp is removed on exit.
cp -Rn "${CLONE_DIR}/." "${DEST_DIR}/"

if [ "$MODE" = "update" ]; then
  log "Refreshing template-owned paths..."
  for path in $MANAGED_PATHS; do
    overwrite_managed "$path"
  done

  log "Checking seeded files for drift..."
  for path in $SEEDED_PATHS; do
    report_seeded_drift "$path"
  done

  log "Review the result with: git diff"
fi

log "Installation complete at: $DEST_DIR"
