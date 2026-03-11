#!/bin/bash
# Failover monitor for LumiGate (Plan A: Cold Standby)
# Monitors primary NAS health, activates local instance on failure.
# Install: launchctl load failover/com.lumigate.failover.plist

# --- Configuration (override via environment) ---
PRIMARY_HOST="${PRIMARY_HOST:-nas-ip}"
PRIMARY_PORT="${PRIMARY_PORT:-9471}"
LOCAL_COMPOSE_DIR="${LOCAL_COMPOSE_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
DATA_SYNC_SOURCE="${DATA_SYNC_SOURCE:-${PRIMARY_HOST}:/path/to/lumigate/data/}"
DATA_SYNC_TARGET="${LOCAL_COMPOSE_DIR}/data/"
CHECK_INTERVAL="${CHECK_INTERVAL:-10}"
FAIL_THRESHOLD="${FAIL_THRESHOLD:-3}"
AUTO_RECOVER="${AUTO_RECOVER:-true}"

fail_count=0
active=false

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $1"; }

sync_data() {
  rsync -az --delete "$DATA_SYNC_SOURCE" "$DATA_SYNC_TARGET" 2>/dev/null
}

start_local() {
  log "[FAILOVER] Activating local instance..."
  sync_data
  docker compose -f "$LOCAL_COMPOSE_DIR/docker-compose.yml" up -d 2>&1
  log "[FAILOVER] Local instance started"
}

stop_local() {
  log "[RECOVER] Stopping local instance, primary is back"
  docker compose -f "$LOCAL_COMPOSE_DIR/docker-compose.yml" down 2>&1
  log "[RECOVER] Local instance stopped"
}

log "Failover monitor started"
log "Primary: ${PRIMARY_HOST}:${PRIMARY_PORT}"
log "Local compose: ${LOCAL_COMPOSE_DIR}"
log "Check interval: ${CHECK_INTERVAL}s, threshold: ${FAIL_THRESHOLD}"

while true; do
  if curl -sf --max-time 5 "http://${PRIMARY_HOST}:${PRIMARY_PORT}/health" > /dev/null 2>&1; then
    if [ $fail_count -gt 0 ]; then
      log "Primary recovered (was at $fail_count failures)"
    fi
    fail_count=0
    if $active && [ "$AUTO_RECOVER" = "true" ]; then
      stop_local
      active=false
    fi
  else
    fail_count=$((fail_count + 1))
    log "Health check failed ($fail_count/$FAIL_THRESHOLD)"
    if [ $fail_count -ge $FAIL_THRESHOLD ] && ! $active; then
      start_local
      active=true
    fi
  fi
  sleep "$CHECK_INTERVAL"
done
