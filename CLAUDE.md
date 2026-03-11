# LumiGate — Project-Focused Dev Guide

## What this repo is
Self-hosted multi-provider AI gateway (Express + Nginx + Docker), optimized for SME and low-memory hosts.

## Run (most common)
```bash
docker compose up -d --build              # prod stack
docker compose -f reviews/docker-compose.test.yml -p ai-api-proxy-test up -d --build  # isolated test stack
node server.js                            # direct dev run
```

## Verify quickly
```bash
node -c server.js
curl http://localhost:9471/health
```

## Files that matter first
- `server.js`: auth, modules, proxy, usage, backup/audit/metrics APIs
- `nginx/nginx.conf`: reverse proxy, health fallback, security headers
- `public/index.html`: dashboard + admin flows
- `docker-compose.yml`: prod deployment
- `reviews/docker-compose.test.yml`: isolated test/chaos environment

## Project rules (high signal)
- Keep port `9471` as default.
- Keep `/providers` response fields `baseUrl` + `available` (UI relies on both).
- Keep all data writes atomic (`*.tmp` + rename), never write partial JSON directly.
- Never log secrets (`ADMIN_SECRET`, API keys, tunnel tokens).
- Use `safeEqual()` for secret comparison; do not replace with plain equality.
- Keep 10MB body limit unless there is a scoped and tested reason to change it.

## Mode policy
- `lite`: keep data-plane security/perf behavior; trim management modules only.
- `enterprise`: enable governance modules (`audit`, `metrics`, `backup`, etc.).
- Any mode change must be root-controlled and clearly visible in UI/health output.

## Before merging changes
1. Syntax check passes.
2. Health endpoint responds.
3. Auth/limit behavior unchanged unless intentionally modified.
4. If touching proxy paths, verify `/v1/{provider}/...` compatibility.
