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

# ── Secret-leak guard ──────────────────────────────────────
# A rendered manifest gets committed to git and read by ArgoCD's deploy key. Any password
# substituted into it in cleartext is therefore a password in git history, in every clone, and in
# every CI log that cats the file. This check fails the render rather than letting that happen.
#
# Secrets belong in a Kubernetes Secret (created out of band, see setup/02) or in Infisical (see
# setup/04), referenced from the manifest with valueFrom.secretKeyRef.
info "Checking that no secret value was rendered into a manifest..."
LEAKS=0
for key in "${VAR_KEYS[@]}"; do
  # Only variables whose NAME says they hold a credential.
  [[ "$key" =~ (_PASSWORD|_SECRET|_TOKEN|_PASS)$ ]] || continue
  val="${VARS[$key]}"
  # Skip empty, obviously-placeholder, and too-short-to-be-real values.
  [[ -z "$val" || "$val" == CHANGE_ME* || "$val" == your-* || ${#val} -lt 12 ]] && continue
  # Skip filesystem paths (SSH_KEY and friends point at a file, they are not the secret).
  [[ "$val" == /* || "$val" == '~'* ]] && continue

  while IFS= read -r hit; do
    [[ -z "$hit" ]] && continue
    # Mask the value so the warning itself does not leak it.
    warn "  ${hit//$val/<$key VALUE IN CLEARTEXT>}"
    LEAKS=$((LEAKS + 1))
  done < <(grep -rn -F -- "$val" "$OUTPUT_DIR" 2>/dev/null || true)
done

if (( LEAKS > 0 )); then
  echo "" >&2
  fail "$LEAKS cleartext secret occurrence(s) rendered into output/. Refusing to continue.
        Replace the {{TOKEN}} in those templates with a secretKeyRef, e.g.

            env:
              - name: DATABASE_URL
                valueFrom:
                  secretKeyRef:
                    name: my-app-auth
                    key: DATABASE_URL

        then create the Secret out of band:

            kubectl -n <ns> create secret generic my-app-auth --from-literal=DATABASE_URL='...'"
fi
ok "No secret values found in rendered output"

# ── Belt and braces: output/ gets its own .gitignore ───────
cat > "$OUTPUT_DIR/.gitignore" <<'GITIGNORE'
# Anything matching these must never reach the devops repo. ArgoCD reads this repo with a deploy
# key, and a credential committed here is a credential in every clone and every CI log.
*.env
!vars.env.example
.env
.env.*
*secret*.local.yaml
*-credentials.yaml
*.key
*.pem
id_rsa
id_ed25519
kubeconfig
GITIGNORE
ok "Wrote output/.gitignore"

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
echo "  1. Review the output/ directory — read it, do not just push it"
echo "  2. Create the Secrets the manifests reference (setup/02 for postgres-auth and"
echo "     redis-auth, setup/04 for everything Infisical manages). The manifests hold"
echo "     references only; no password is rendered into them."
echo "  3. Push output/ as your devops repo:"
echo "       cd output && git init && git add -A"
echo "       git diff --cached -S'password' --stat   # sanity-check before the first commit"
echo "       git commit -m 'initial infra'"
echo "  4. Follow the setup guides in setup/ in order (00 to 13)"
