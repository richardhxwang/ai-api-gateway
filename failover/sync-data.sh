#!/bin/bash
# Cron data sync for lumigate failover
# Usage: */5 * * * * /path/to/failover/sync-data.sh
# Skips sync if local docker stack is active (to avoid overwriting live data)

PRIMARY_HOST="${PRIMARY_HOST:-nas-ip}"
DATA_SYNC_SOURCE="${DATA_SYNC_SOURCE:-${PRIMARY_HOST}:/path/to/lumigate/data/}"
LOCAL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DATA_SYNC_TARGET="${LOCAL_DIR}/data/"
LOG="/tmp/lumigate-sync.log"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG"; }

# Skip if local instance is running (failover active)
if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "lumigate"; then
  log "SKIP: Local instance is running, not syncing"
  exit 0
fi

if rsync -az --delete "$DATA_SYNC_SOURCE" "$DATA_SYNC_TARGET" 2>/dev/null; then
  log "OK: Synced from $PRIMARY_HOST"
else
  log "WARN: Sync failed from $PRIMARY_HOST"
fi
