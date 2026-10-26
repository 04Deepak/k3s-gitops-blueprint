#!/usr/bin/env bash
# ============================================================
# k3s-gitops-blueprint — init.sh
# Reads vars.env, copies templates/ → output/, replaces all
# {{PLACEHOLDER}} tokens, and validates nothing is left behind.
#
# Usage:
#   ./init.sh                 # uses ./vars.env
#   ./init.sh /path/to/vars   # uses a custom vars file
#
# Safe to re-run (idempotent — deletes output/ first).
# ============================================================
set -euo pipefail

if (( BASH_VERSINFO[0] < 4 )); then
  echo "init.sh needs bash 4+ (found $BASH_VERSION). On macOS: brew install bash, then run: /opt/homebrew/bin/bash init.sh" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VARS_FILE="${1:-${SCRIPT_DIR}/vars.env}"
OUTPUT_DIR="${SCRIPT_DIR}/output"

# ── Colors ──────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { printf "${CYAN}[INFO]${NC}  %s\n" "$*"; }
ok()    { printf "${GREEN}[OK]${NC}    %s\n" "$*"; }
warn()  { printf "${YELLOW}[WARN]${NC}  %s\n" "$*"; }
fail()  { printf "${RED}[FAIL]${NC}  %s\n" "$*"; exit 1; }

# ── Validate vars file ─────────────────────────────────────
[[ -f "$VARS_FILE" ]] || fail "vars file not found: $VARS_FILE"
info "Reading variables from: $VARS_FILE"

# ── Parse vars.env into associative array ──────────────────
declare -A VARS
declare -a VAR_KEYS=()
while IFS= read -r line || [[ -n "$line" ]]; do
  # Skip blank lines and comments
  [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
  # Extract KEY=VALUE (supports values with spaces, = signs, etc.)
  if [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=(.*) ]]; then
    key="${BASH_REMATCH[1]}"
    value="${BASH_REMATCH[2]}"
    VARS["$key"]="$value"
    VAR_KEYS+=("$key")
  fi
done < "$VARS_FILE"

info "Loaded ${#VARS[@]} variables"

# ── Warn on default / placeholder values ───────────────────
DEFAULTS_FOUND=0
for key in "${VAR_KEYS[@]}"; do
  val="${VARS[$key]}"
  if [[ "$val" == "CHANGE_ME"* || "$val" == "your-"* || "$val" == "1.2.3.4" || "$val" == "203.0.113.10" ]]; then
    warn "  $key still has a placeholder value: $val"
    DEFAULTS_FOUND=$((DEFAULTS_FOUND + 1))
  fi
done
if (( DEFAULTS_FOUND > 0 )); then
  warn "$DEFAULTS_FOUND variable(s) still have default values — output will contain placeholders."
  warn "Edit vars.env and re-run when ready for a real deployment."
fi

# ── Prepare output directory ───────────────────────────────
if [[ -d "$OUTPUT_DIR" ]]; then
  info "Removing previous output directory"
  rm -rf "$OUTPUT_DIR"
fi
mkdir -p "$OUTPUT_DIR"

# ── Copy template files (exclude init.sh, vars.env, output/) ─
info "Copying template files to output/"
cd "$SCRIPT_DIR"
find . -type f \
  ! -name 'init.sh' \
  ! -name 'vars.env' \
  ! -path './output/*' \
  ! -name '.DS_Store' \
  | while IFS= read -r file; do
    dest="$OUTPUT_DIR/$file"
    mkdir -p "$(dirname "$dest")"
    cp "$file" "$dest"
  done

# ── Replace {{PLACEHOLDER}} tokens ────────────────────────
info "Replacing {{PLACEHOLDER}} tokens..."
REPLACEMENTS=0

find "$OUTPUT_DIR" -type f | while IFS= read -r file; do
  for key in "${VAR_KEYS[@]}"; do
    value="${VARS[$key]}"
    # Use | as sed delimiter (unlikely to appear in values)
    # Escape special sed characters in the value
    escaped_value=$(printf '%s' "$value" | sed 's/[&/\]/\\&/g')
    if grep -q "{{${key}}}" "$file" 2>/dev/null; then
      sed -i'' -e "s|{{${key}}}|${escaped_value}|g" "$file"
    fi
  done
done

# ── Count actual replacements ──────────────────────────────
TOTAL_REPLACEMENTS=$(diff -rq "$SCRIPT_DIR" "$OUTPUT_DIR" \
  --exclude='init.sh' --exclude='vars.env' --exclude='output' --exclude='.DS_Store' \
  2>/dev/null | grep -c "differ" || true)

# ── Validate: check for unreplaced tokens ──────────────────
info "Validating — checking for unreplaced {{...}} tokens..."
UNREPLACED=$(grep -rn '{{[A-Z_][A-Z0-9_]*}}' "$OUTPUT_DIR" 2>/dev/null || true)

if [[ -n "$UNREPLACED" ]]; then
  warn "Found unreplaced tokens:"
  echo "$UNREPLACED" | while IFS= read -r match; do
    warn "  $match"
  done
  echo ""
  warn "These tokens are not defined in vars.env."
  warn "Add them to vars.env and re-run, or replace manually."
else
  ok "All tokens replaced successfully"
fi

# ── Summary ────────────────────────────────────────────────
FILE_COUNT=$(find "$OUTPUT_DIR" -type f | wc -l | tr -d ' ')
echo ""
echo "═══════════════════════════════════════════════════════"
printf " ${GREEN}Output ready:${NC}  %s\n" "$OUTPUT_DIR"
printf " ${CYAN}Files:${NC}         %s\n" "$FILE_COUNT"
printf " ${CYAN}Variables:${NC}     %s\n" "${#VARS[@]}"
if (( DEFAULTS_FOUND > 0 )); then
  printf " ${YELLOW}Warnings:${NC}      %s variable(s) still have defaults\n" "$DEFAULTS_FOUND"
fi
echo "═══════════════════════════════════════════════════════"
echo ""
info "Next steps:"
echo "  1. Review the output/ directory"
echo "  2. Push output/ as your new devops repo:"
echo "     cd output && git init && git add -A && git commit -m 'initial infra'"
echo "  3. Follow the setup guides in docs/ to deploy"
