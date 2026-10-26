#!/usr/bin/env bash
# Cluster Health Check
# Runs kubectl commands via SSH and reports color-coded status.
#
# Usage: ./health-check.sh
#
# Template placeholders (replace via init.sh or manually):
#   {{SSH_HOST}}            — SSH alias or user@host for the server
#   {{NAMESPACE}}           — primary app namespace (e.g. my-project)
#   {{STAGING_NAMESPACE}}   — staging namespace (e.g. my-project-staging)
#   {{DOMAIN}}              — production domain (e.g. app.example.com)
#   {{STAGING_DOMAIN}}      — staging domain (e.g. staging.example.com)

set -euo pipefail

SSH_HOST="{{SSH_HOST}}"
NS="{{NAMESPACE}}"
STAGING_NS="{{STAGING_NAMESPACE}}"
DOMAIN="{{DOMAIN}}"
STAGING_DOMAIN="{{STAGING_DOMAIN}}"

# ── Colors ─────────────────────────────────────────────────────────────
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

PASS=0; WARN=0; FAIL=0

ok()   { PASS=$((PASS+1)); echo -e "  ${GREEN}✔${NC} $1"; }
warn() { WARN=$((WARN+1)); echo -e "  ${YELLOW}⚠${NC} $1"; }
fail() { FAIL=$((FAIL+1)); echo -e "  ${RED}✘${NC} $1"; }
header() { echo -e "\n${CYAN}${BOLD}── $1 ──${NC}"; }

# Run a command on the remote server
run() { ssh -o ConnectTimeout=5 "$SSH_HOST" "$@" 2>/dev/null; }

# ── Node Status ────────────────────────────────────────────────────────
header "Node Status"
NODE_STATUS=$(run "kubectl get nodes --no-headers" || echo "UNREACHABLE")
if echo "$NODE_STATUS" | grep -q "UNREACHABLE"; then
  fail "Cannot reach server — check SSH config"
  echo -e "\n${RED}${BOLD}ABORT: Server unreachable${NC}"
  exit 1
fi

while IFS= read -r line; do
  name=$(echo "$line" | awk '{print $1}')
  status=$(echo "$line" | awk '{print $2}')
  if [ "$status" = "Ready" ]; then
    ok "Node $name: $status"
  else
    fail "Node $name: $status"
  fi
done <<< "$NODE_STATUS"

# ── Pod Status ─────────────────────────────────────────────────────────
header "Pods"
for ns in "$NS" "$STAGING_NS" "shared" "argocd" "infisical"; do
  PODS=$(run "kubectl get pods -n $ns --no-headers 2>/dev/null" || echo "")
  if [ -z "$PODS" ]; then
    warn "Namespace $ns: no pods or namespace missing"
    continue
  fi

  total=$(echo "$PODS" | wc -l | tr -d ' ')
  running=$(echo "$PODS" | grep -c "Running" || true)
  completed=$(echo "$PODS" | grep -c "Completed" || true)
  healthy=$((running + completed))

  if [ "$healthy" -eq "$total" ]; then
    ok "$ns: $total/$total healthy"
  else
    failed=$((total - healthy))
    fail "$ns: $failed/$total unhealthy"
    echo "$PODS" | grep -v "Running\|Completed" | while read -r p; do
      echo -e "      ${RED}→${NC} $p"
    done
  fi
done

# ── High-Restart Pods ──────────────────────────────────────────────────
header "Restart Check (threshold: 5)"
RESTARTS=$(run "kubectl get pods -A --no-headers -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,RESTARTS:.status.containerStatuses[0].restartCount' 2>/dev/null | awk '\$3 > 5'" || echo "")
if [ -z "$RESTARTS" ]; then
  ok "No pods with >5 restarts"
else
  while IFS= read -r line; do
    warn "$line"
  done <<< "$RESTARTS"
fi

# ── Top Memory Pods ────────────────────────────────────────────────────
header "Top Memory Pods"
TOP_MEM=$(run "kubectl top pods -A --no-headers --sort-by=memory 2>/dev/null | head -5" || echo "metrics unavailable")
if echo "$TOP_MEM" | grep -q "unavailable"; then
  warn "Metrics server not available"
else
  echo "$TOP_MEM" | while IFS= read -r line; do
    echo -e "    $line"
  done
  ok "Top 5 shown"
fi

# ── ArgoCD Applications ───────────────────────────────────────────────
header "ArgoCD Applications"
ARGO_APPS=$(run "kubectl get applications -n argocd --no-headers -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status' 2>/dev/null" || echo "")
if [ -z "$ARGO_APPS" ]; then
  warn "No ArgoCD applications found"
else
  while IFS= read -r line; do
    name=$(echo "$line" | awk '{print $1}')
    sync=$(echo "$line" | awk '{print $2}')
    health=$(echo "$line" | awk '{print $3}')
    if [ "$sync" = "Synced" ] && [ "$health" = "Healthy" ]; then
      ok "$name: $sync / $health"
    elif [ "$sync" = "Synced" ]; then
      warn "$name: $sync / $health"
    else
      fail "$name: $sync / $health"
    fi
  done <<< "$ARGO_APPS"
fi

# ── CronJobs ──────────────────────────────────────────────────────────
header "CronJobs"
for ns in "$NS" "$STAGING_NS"; do
  CRONS=$(run "kubectl get cronjobs -n $ns --no-headers -o custom-columns='NAME:.metadata.name,SCHEDULE:.spec.schedule,SUSPEND:.spec.suspend,LAST:.status.lastScheduleTime' 2>/dev/null" || echo "")
  if [ -z "$CRONS" ]; then
    warn "$ns: no CronJobs"
    continue
  fi
  while IFS= read -r line; do
    name=$(echo "$line" | awk '{print $1}')
    suspend=$(echo "$line" | awk '{print $3}')
    last=$(echo "$line" | awk '{print $4}')
    if [ "$suspend" = "true" ]; then
      warn "$ns/$name: SUSPENDED"
    elif [ "$last" = "<none>" ]; then
      warn "$ns/$name: never ran"
    else
      ok "$ns/$name: last=$last"
    fi
  done <<< "$CRONS"
done

# ── TLS Certificates ──────────────────────────────────────────────────
header "TLS Certificates"
for domain in "$DOMAIN" "$STAGING_DOMAIN"; do
  EXPIRY=$(echo | openssl s_client -servername "$domain" -connect "$domain:443" 2>/dev/null \
    | openssl x509 -noout -enddate 2>/dev/null \
    | cut -d= -f2)
  if [ -z "$EXPIRY" ]; then
    fail "$domain: cannot read certificate"
    continue
  fi
  EXPIRY_EPOCH=$(date -j -f "%b %d %T %Y %Z" "$EXPIRY" +%s 2>/dev/null \
    || date -d "$EXPIRY" +%s 2>/dev/null \
    || echo 0)
  NOW_EPOCH=$(date +%s)
  DAYS_LEFT=$(( (EXPIRY_EPOCH - NOW_EPOCH) / 86400 ))
  if [ "$DAYS_LEFT" -gt 30 ]; then
    ok "$domain: ${DAYS_LEFT}d remaining"
  elif [ "$DAYS_LEFT" -gt 7 ]; then
    warn "$domain: ${DAYS_LEFT}d remaining — renew soon"
  else
    fail "$domain: ${DAYS_LEFT}d remaining — EXPIRING"
  fi
done

# ── Disk Usage ─────────────────────────────────────────────────────────
header "Disk Usage"
DISK=$(run "df -h / | tail -1" || echo "")
if [ -n "$DISK" ]; then
  USE_PCT=$(echo "$DISK" | awk '{print $5}' | tr -d '%')
  if [ "$USE_PCT" -lt 80 ]; then
    ok "Root disk: ${USE_PCT}% used"
  elif [ "$USE_PCT" -lt 90 ]; then
    warn "Root disk: ${USE_PCT}% used — getting full"
  else
    fail "Root disk: ${USE_PCT}% used — CRITICAL"
  fi
fi

# ── K8s Warnings ──────────────────────────────────────────────────────
header "Recent Warnings (last 10 min)"
WARNINGS=$(run "kubectl get events -A --field-selector type=Warning --sort-by='.lastTimestamp' 2>/dev/null | tail -5" || echo "")
if [ -z "$WARNINGS" ] || echo "$WARNINGS" | grep -q "No resources"; then
  ok "No recent warnings"
else
  warn "Recent warnings found:"
  echo "$WARNINGS" | while IFS= read -r line; do
    echo -e "      ${YELLOW}→${NC} $line"
  done
fi

# ── PostgreSQL ─────────────────────────────────────────────────────────
header "PostgreSQL"
PG_READY=$(run "kubectl exec -n shared statefulset/postgres -- pg_isready -U postgres 2>/dev/null" || echo "NOT READY")
if echo "$PG_READY" | grep -q "accepting"; then
  ok "Postgres: accepting connections"
else
  fail "Postgres: $PG_READY"
fi

CONN_COUNT=$(run "kubectl exec -n shared statefulset/postgres -- psql -U postgres -t -c 'SELECT count(*) FROM pg_stat_activity;' 2>/dev/null" || echo "?")
CONN_COUNT=$(echo "$CONN_COUNT" | tr -d ' ')
if [ "$CONN_COUNT" != "?" ]; then
  if [ "$CONN_COUNT" -lt 80 ]; then
    ok "Connections: $CONN_COUNT"
  elif [ "$CONN_COUNT" -lt 95 ]; then
    warn "Connections: $CONN_COUNT (approaching limit)"
  else
    fail "Connections: $CONN_COUNT (near max_connections)"
  fi
fi

DB_SIZES=$(run "kubectl exec -n shared statefulset/postgres -- psql -U postgres -t -c \"SELECT datname, pg_size_pretty(pg_database_size(datname)) FROM pg_database WHERE datistemplate = false ORDER BY pg_database_size(datname) DESC;\" 2>/dev/null" || echo "")
if [ -n "$DB_SIZES" ]; then
  echo "$DB_SIZES" | while IFS= read -r line; do
    [ -n "$line" ] && echo -e "    $line"
  done
  ok "Database sizes listed"
fi

# ── Redis ──────────────────────────────────────────────────────────────
header "Redis"
REDIS_PING=$(run "kubectl exec -n shared deploy/redis -- redis-cli ping 2>/dev/null" || echo "FAIL")
if [ "$REDIS_PING" = "PONG" ]; then
  ok "Redis: PONG"
else
  fail "Redis: not responding"
fi

REDIS_INFO=$(run "kubectl exec -n shared deploy/redis -- redis-cli info memory 2>/dev/null" || echo "")
REDIS_MEM=$(echo "$REDIS_INFO" | grep "used_memory_human" | cut -d: -f2 | tr -d '\r')
REDIS_MAX=$(echo "$REDIS_INFO" | grep "maxmemory_human" | cut -d: -f2 | tr -d '\r')
[ -n "$REDIS_MEM" ] && ok "Memory: $REDIS_MEM / max $REDIS_MAX"

REDIS_CLIENTS=$(run "kubectl exec -n shared deploy/redis -- redis-cli info clients 2>/dev/null | grep 'connected_clients' | cut -d: -f2 | tr -d '\r'" || echo "?")
[ "$REDIS_CLIENTS" != "?" ] && ok "Connected clients: $REDIS_CLIENTS"

REDIS_KEYS=$(run "kubectl exec -n shared deploy/redis -- redis-cli dbsize 2>/dev/null" || echo "?")
[ "$REDIS_KEYS" != "?" ] && ok "Keys: $REDIS_KEYS"

# ── HTTP Endpoints ─────────────────────────────────────────────────────
header "HTTP Endpoints"
for url in "https://$DOMAIN" "https://$DOMAIN/api/health" "https://$STAGING_DOMAIN" "https://$STAGING_DOMAIN/api/health"; do
  CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$url" 2>/dev/null || echo "000")
  if [ "$CODE" = "200" ]; then
    ok "$url → $CODE"
  elif [ "$CODE" = "000" ]; then
    fail "$url → timeout/unreachable"
  else
    warn "$url → $CODE"
  fi
done

# ── Summary ────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}═══════════════════════════════════════════${NC}"
if [ "$FAIL" -gt 0 ]; then
  echo -e "${RED}${BOLD}  HEALTH: $FAIL FAILED${NC}  ${YELLOW}$WARN warnings${NC}  ${GREEN}$PASS passed${NC}"
elif [ "$WARN" -gt 0 ]; then
  echo -e "${YELLOW}${BOLD}  HEALTH: $WARN WARNINGS${NC}  ${GREEN}$PASS passed${NC}"
else
  echo -e "${GREEN}${BOLD}  HEALTH: ALL $PASS CHECKS PASSED${NC}"
fi
echo -e "${BOLD}═══════════════════════════════════════════${NC}"
