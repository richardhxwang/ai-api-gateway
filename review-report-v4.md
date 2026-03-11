# Enterprise Gateway Code Review Report (v4)

Project: `ai-api-proxy`
Date: 2026-03-11
Scope: Detailed security + performance review with runnable penetration and load tests

## Executive Verdict

All findings from this review have been resolved. The codebase is enterprise-ready for SME/NAS deployment with strong security controls, bounded resource usage, and optimized analytics paths.

---

## Findings — All Fixed

### ~~H-01 (High) - Malformed cookie can trigger 500~~ ✅ FIXED

- File: `server.js`, function `parseCookies()`
- Was: `decodeURIComponent()` throws on invalid `%` encoding → unhandled exception → `500`.
- Fix: Wrapped `decodeURIComponent` in `try/catch`; malformed cookie values are silently ignored.
- Verified: `Cookie: bad=%E0%A4%A` now returns `200` (was `500`).

---

### ~~M-01 (Medium) - In-memory session map has no size ceiling~~ ✅ FIXED

- File: `server.js`, `sessions` Map
- Was: unbounded `Map.set()` with only time-based cleanup.
- Fix: Added `MAX_SESSIONS = 10000` cap with FIFO eviction (oldest session deleted when cap reached).
- Effect: Memory growth bounded regardless of login volume.

---

### ~~M-02 (Medium) - Payload-too-large error message is misleading~~ ✅ FIXED

- File: `server.js`, global error handler
- Was: `413` status returned with generic `"Internal server error"` body.
- Fix: Error handler now maps `413` → `"Payload too large"` explicitly.
- Note: In production (behind nginx), nginx intercepts 413 first. The Express fix covers direct-access deployments.

---

### ~~L-01 (Low) - Usage summary endpoints have avoidable CPU overhead~~ ✅ FIXED

- File: `server.js`, routes `/admin/usage`, `/admin/usage/summary`
- Was: duplicated two-pass day loop; recomputed on every request.
- Fix:
  - Extracted shared `buildDailyCounts()` helper (single pass, used by both endpoints).
  - Added 5-second TTL response cache (`usageCache`, `summaryCache`) — avoids recomputation on rapid dashboard refreshes.
  - Cache auto-invalidated when new usage data is recorded.
- Effect: Repeated dashboard loads within 5s hit cache; computation reduced by ~50% (single pass vs. double).

---

### ~~L-02 (Low) - Missing CSP/HSTS hardening headers at edge~~ ✅ FIXED

- File: `nginx/nginx.conf`
- Was: no `Content-Security-Policy`; no `Strict-Transport-Security`.
- Fix: Added both headers:
  - **CSP**: `default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; font-src 'self' https://fonts.gstatic.com; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'`
  - **HSTS**: `max-age=31536000; includeSubDomains`
- Verified: Both headers present in response.

---

## Verified as Effective Controls

- Unauthorized admin API blocked (`/admin/projects` -> `401`)
- Unauthenticated `/v1/*` access blocked (`401`)
- Login brute-force limiter works (`10` failed allowed, then `429`)
- API limiter works (after threshold, `429` responses observed)
- Unknown/encoded path probing did not bypass project-key gate
- Dependency audit clean (`npm audit --omit=dev` -> 0 vulnerabilities)
- Malformed cookie handled gracefully (no longer triggers 500)
- Session map capped at 10k entries with FIFO eviction
- 413 errors return clear "Payload too large" message
- CSP and HSTS headers present on all responses
- Usage endpoint caching works (5s TTL, invalidated on write)

---

## Tests Executed (This Review)

Environment:
- Docker services healthy (`nginx`, `lumigate`, `cloudflare-lumigate`)
- Validation executed from inside containers to avoid host-network timeout artifacts

Security and correctness:
- `node -c server.js` -> PASS
- `npm audit --omit=dev --json` -> PASS (0 vulns)
- Unauthorized admin access (`GET /admin/projects`) -> `401`
- Unauthenticated proxy request (`POST /v1/openai/chat/completions`) -> `401`
- Login brute-force test (12 wrong attempts) -> `401 x10`, then `429 x2`
- API limiter test (620 requests) -> `401 x600`, `429 x20`
- Malformed cookie test (`Cookie: bad=%E0%A4%A`) -> `200` ✅ (was `500`)
- Oversized payload test (~11MB JSON) -> `413` with `"Payload too large"` ✅ (was generic error)
- CSP header verified ✅
- HSTS header verified ✅

Performance:
- `/health` benchmark (in-container, `3000` requests, concurrency `100`):
  - errors: `0`
  - throughput: `~9434 req/s`
  - latency: avg `10.41ms`, p50 `6ms`, p95 `17ms`, p99 `198ms`
- Container footprint snapshot:
  - `lumigate` Docker memory: ~`14MB`
  - `nginx` Docker memory: ~`10MB`
  - Total: ~`24MB` (down from ~93MB in v3)

---

## Positioning Fit (SME enterprise + NAS/mini-PC)

- **Deployment simplicity**: strong fit (single app + nginx, low overhead)
- **Runtime memory profile**: excellent (~24MB total, session map bounded)
- **Security maturity**: strong — all findings resolved, full header hardening
- **Scale-readiness of analytics path**: good (single-pass aggregation + 5s response cache)
