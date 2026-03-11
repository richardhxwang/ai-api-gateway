# Enterprise Gateway Code Review Report (v2)

Project: `LumiGate`
Date: 2026-03-10
Positioning Target: Enterprise-grade gateway for AI-driven SME products, deployable on NAS / mini PC with low memory footprint.

## What Changed From v1

This v2 report removes items already fixed in the recent security patch and focuses on:
- Remaining open risks and regression risks
- Feature gap analysis vs. LiteLLM and One-API
- Practical architecture decisions for video-analysis workloads

---

## Current Open Findings (Only Unresolved)

### O-01 (High) - Secrets still persisted in plaintext `.env`

- Location: `app.post("/admin/key", ...)` in `server.js`
- Current state: improved file mode (`0600`), but value is still plaintext at rest.
- Why it matters: still below enterprise secret-management baseline (backup leakage, host compromise blast radius, audit/compliance concerns).

```808:829:server.js
  try {
    const envPath = path.join(__dirname, ".env");
    let envContent = fs.existsSync(envPath) ? fs.readFileSync(envPath, "utf8") : "";
    // ...
    // F-05: Write with strict permissions (owner read/write only)
    fs.writeFileSync(envPath, envContent, { mode: 0o600 });
  } catch (e) {
```

Recommendation:
- Move provider credentials to a secrets backend (Vault / KMS / SSM).
- Keep `.env` for bootstrap/non-sensitive config only.

---

### O-02 (Medium) - Upstream path allowlist may reject valid doubao paths (consistency risk)

- Location: `ALLOWED_UPSTREAM_PATHS` + allowlist check in `/v1/:provider`.
- Current state: request path is validated before proxy rewrite; doubao path prefix can be fragile depending on incoming path format.
- Why it matters: may cause false 403 on legitimate traffic (functional regression).

```89:97:server.js
const ALLOWED_UPSTREAM_PATHS = {
  // ...
  doubao:     ["/chat/completions", "/embeddings"],
};
```

```941:946:server.js
  const incomingSubpath = req.path.replace(new RegExp(`^/v1/${providerName}`, "i"), "");
  const allowedPaths = ALLOWED_UPSTREAM_PATHS[providerName];
  if (allowedPaths && !allowedPaths.some(p => incomingSubpath.startsWith(p))) {
    return res.status(403).json({ error: "Requested API path is not allowed for this provider" });
  }
```

Recommendation:
- Normalize/validate against one canonical form (prefer post-rewrite path).
- Add contract tests per provider route mapping.

---

### O-03 (Medium) - Video-analysis payload strategy not yet productionized

- Location: global body parser and proxy route design in `server.js`.
- Current state: global JSON limit is `10mb`; this is good for memory control but usually insufficient for raw/base64 video uploads.
- Why it matters: either uploads fail, or global limit gets raised and hurts low-memory deployment goal.

```403:405:server.js
// 4. Body parser with size limit (F-09: reduced from 100mb)
app.use(express.json({ limit: "10mb" }));
```

Recommendation:
- Keep global limit small.
- Add dedicated multimodal ingestion path:
  - Preferred: object storage URL reference (signed URL) instead of raw video body.
  - Alternative: streaming/multipart upload route with route-scoped limits.

---

## Closed in v2 Scope (No Longer Open Findings)

These v1 findings are considered covered by current patch and removed from active list:
- F-01 tenant auth bypass (`projects.length` conditional bypass removed)
- F-02 browser key exposure in `/chat`
- F-03 baseUrl validation strengthened (URL parsing + host allowlist + DNS check)
- F-06 rate-limit IPv6 keying warning addressed via normalized key generator
- F-09 global body limit reduced from `100mb` to `10mb`
- F-10 provider list leakage in unknown-provider response

---

## Competitive Analysis: LumiGate vs. LiteLLM vs. One-API

### Overview

| Dimension | LumiGate | LiteLLM (BerriAI) | One-API / New-API |
|-----------|-------------|-------------------|-------------------|
| **Language** | Node.js (Express) | Python (FastAPI) | Go + React |
| **Providers** | 8 | 140+ | 30+ |
| **Database** | JSON files (data/) | PostgreSQL (required) | SQLite / MySQL |
| **Redis** | Not needed | Recommended (1000+ RPS) | Optional |
| **Docker image** | Single container | Multi-container (+ PG + Redis) | Single binary |
| **RAM baseline** | ~30-50 MB | ~200-400 MB (+ PG + Redis) | ~20-40 MB |
| **License** | Private | Apache 2.0 (core) / Enterprise $$ | MIT (original) / AGPLv3 (New-API) |
| **GitHub stars** | — | ~25k | ~18k (original) / ~20k (New-API) |
| **Admin UI** | Built-in dashboard | Basic UI (enterprise for full) | Full admin panel with user management |

### Feature Comparison

| Feature | LumiGate | LiteLLM | One-API |
|---------|-------------|---------|---------|
| OpenAI-compatible API | ✅ | ✅ | ✅ |
| Anthropic native format | ✅ (passthrough) | ✅ | ✅ (New-API) |
| Streaming (SSE) | ✅ | ✅ | ✅ |
| **Auth: Project keys** | ✅ | ✅ (Virtual Keys) | ✅ (Tokens) |
| **Auth: RBAC** | ❌ (admin only) | ✅ (enterprise $$) | ✅ (admin/user roles) |
| **Auth: SSO/OIDC** | ❌ | ✅ (enterprise $$) | ❌ |
| **Per-key budget/quota** | ❌ | ✅ (5-level hierarchy) | ✅ (quota system) |
| **Per-key model restrict** | ❌ | ✅ | ✅ |
| **Per-key rate limit** | ❌ (global IP only) | ✅ (RPM/TPM per key) | ⚠️ (basic global only) |
| **Cost tracking** | ✅ (token-level) | ✅ (per key/team/org) | ✅ (quota multiplier) |
| **Real USD cost calc** | ✅ (built-in pricing DB) | ✅ (auto + custom) | ⚠️ (multiplier-based, not exact USD) |
| **Cache-aware billing** | ✅ (cache_read tokens) | ✅ | ⚠️ (New-API only) |
| **Exchange rate** | ✅ (auto-fetch weekly) | ❌ | ❌ |
| **Weighted routing** | ❌ | ✅ (least-busy, latency-based) | ✅ (priority + weight) |
| **Auto failover** | ❌ | ✅ (retry + cooldown) | ⚠️ (imperfect) |
| **Multi-channel per provider** | ❌ | ✅ | ✅ |
| **Observability** | Console logs | 15+ integrations (Langfuse, etc.) | Basic usage counts |
| **Graceful shutdown** | ✅ (connection drain) | ❌ | ❌ |
| **Built-in chat UI** | ✅ | ❌ | ❌ |
| **CLI/TUI management** | ✅ | ❌ | ❌ |
| **Redemption codes** | ❌ | ❌ | ✅ (API reselling) |

### Where LumiGate Wins

1. **Deployment simplicity** — Single Node.js process, zero external dependencies (no PG, no Redis, no MySQL). Ideal for NAS / mini PC / homelab. LiteLLM needs PostgreSQL + optionally Redis; One-API needs at least SQLite, MySQL for production.

2. **Operational overhead** — JSON flat-file storage with atomic writes. No database migrations, no connection pool tuning, no ORM. LiteLLM users report needing periodic restarts due to memory leaks and database sluggishness at 1M+ log rows.

3. **Built-in tooling** — Chat UI, admin dashboard, CLI (`cli.sh`), and interactive TUI (`tui.js`) all included. Neither LiteLLM nor One-API offers CLI/TUI management tools.

4. **Accurate cost tracking** — Token-level cost calculation with real pricing database, cache-read token awareness, and automatic exchange rate updates. One-API uses approximate multipliers instead of real USD pricing.

5. **Memory footprint** — ~30-50 MB baseline. LiteLLM with its Python runtime + PostgreSQL + Redis can easily consume 500 MB+. Critical advantage for edge deployment targets.

6. **Graceful shutdown** — Connection draining with configurable timeout. Not present in LiteLLM or One-API.

### Where LumiGate Falls Short

1. **No per-project budget/quota enforcement** — Both LiteLLM and One-API can cap spend per key/user. LumiGate tracks usage but cannot block requests when a budget is exceeded. This is the single biggest enterprise gap.

2. **No per-project model restrictions** — Cannot restrict which models a project key can access. LiteLLM and One-API both support this.

3. **No failover / multi-channel routing** — Each provider has exactly one API key. If that key hits rate limits or goes down, all requests fail. LiteLLM offers least-busy/latency-based routing; One-API offers priority + weighted channels.

4. **No RBAC** — Only one role: admin. No team/viewer/ops separation. Both alternatives offer at least admin/user roles.

5. **Provider breadth** — 8 providers vs. 140+ (LiteLLM) or 30+ (One-API). Sufficient for current use, but limits flexibility. Adding new providers requires code changes.

6. **No structured logging / observability** — Console.log only. LiteLLM integrates with 15+ observability platforms. Enterprise customers expect request IDs, structured JSON logs, and metrics endpoints.

7. **Session/limiter state is process-local** — Cannot horizontally scale without losing rate-limit and session consistency (original F-08). LiteLLM uses Redis; One-API uses MySQL.

---

## Roadmap: Borrowable Features (Prioritized)

### Phase 1 — Enterprise Controls (High value, low-medium complexity)

**1a. Per-project budget enforcement (from LiteLLM)**
- Add fields to project metadata: `maxBudgetUsd`, `spentUsd`, `budgetResetInterval`, `expiresAt`
- Pre-proxy check in `/v1/:provider`: reject with 429 if budget exceeded
- Increment `spentUsd` in `onProxyRes` using existing cost-calculation logic
- Complexity: Low — extend existing `projects.json` schema and add one guard in the proxy route

**1b. Per-project model allowlist (from both)**
- Add `allowedModels: string[]` to project metadata
- Validate `req.body.model` against list before proxying
- Complexity: Low — one additional check in `/v1/:provider`

**1c. Per-project rate limiting (from LiteLLM)**
- Add `rpmLimit`, `tpmLimit` to project metadata
- Track per-project request/token counts in memory with sliding window
- Complexity: Medium — needs in-memory counter with time-window logic

### Phase 2 — Reliability (Medium complexity)

**2a. Multi-channel with failover (from One-API)**
- Allow multiple API keys per provider (channels), each with weight and priority
- On 429/5xx from upstream, retry on next channel with exponential backoff
- Add cooldown period for failed channels (e.g., 60s)
- Complexity: Medium — refactor `PROVIDERS` from single-key to channel array, add retry logic in proxy error handler

**2b. Weighted routing (from One-API)**
- Among healthy channels of same priority, distribute by weight
- Routing strategies: round-robin (default), least-recently-used, random-weighted
- Complexity: Low once 2a is in place

### Phase 3 — Enterprise Readiness (Higher complexity)

**3a. RBAC: admin / operator / viewer (from LiteLLM)**
- `admin`: full access (current behavior)
- `operator`: manage projects, view usage, cannot change provider keys or admin settings
- `viewer`: read-only dashboard access
- Store roles in project metadata or separate users file
- Complexity: Medium — add role field to session, guard each admin route by role

**3b. Structured logging + request IDs (industry standard)**
- Assign UUID per request, propagate through proxy
- JSON log format: `{ timestamp, requestId, project, provider, model, latency, status, tokens }`
- Optional: expose `/admin/logs` endpoint for recent request log query
- Complexity: Medium

**3c. Externalize state to Redis (from LiteLLM, for horizontal scaling)**
- Move sessions, rate-limit counters, and optionally usage aggregation to Redis
- Make Redis optional (fallback to in-memory for single-node)
- Complexity: Medium-High — add Redis client with graceful degradation

---

## Strategic Positioning

### vs. LiteLLM

LiteLLM is the feature-richest open-source gateway but carries significant operational burden: Python runtime, mandatory PostgreSQL, recommended Redis, reported memory leaks, and key enterprise features (SSO, full RBAC, audit logs) gated behind $250/month or $30k/year enterprise license.

**LumiGate's angle**: Zero-dependency, edge-deployable, with enterprise security built-in rather than bolted-on. Target users who need a gateway that "just runs" on a NAS/mini-PC without a DevOps team, while still having real cost tracking and project isolation.

### vs. One-API / New-API

One-API excels at turnkey deployment (single Go binary) and has a mature multi-tenant billing system with redemption codes — ideal for API reselling. However, its cost tracking uses approximate multipliers rather than real token pricing, rate limiting is basic, and the original repo's development has slowed (New-API fork is more active but switched to AGPLv3).

**LumiGate's angle**: More accurate cost tracking (real token-level pricing vs. multipliers), better operational tooling (CLI/TUI/chat UI), and actively maintained under your direct control. The gap to close is budget enforcement and multi-channel routing, both achievable in Phase 1-2.

### Differentiation Summary

| Selling Point | vs. LiteLLM | vs. One-API |
|--------------|-------------|-------------|
| **Zero-dep deployment** | ✅ (no PG/Redis) | ≈ (both lightweight) |
| **Edge/NAS friendly** | ✅ (30MB vs 500MB+) | ✅ (comparable RAM) |
| **Accurate USD cost** | ≈ (both good) | ✅ (token-level vs multipliers) |
| **Built-in tooling** | ✅ (CLI/TUI/chat) | ✅ (CLI/TUI unique) |
| **No license paywall** | ✅ (no enterprise tier) | ✅ (vs AGPLv3 New-API) |
| **Budget enforcement** | ❌ (need Phase 1) | ❌ (need Phase 1) |
| **Failover routing** | ❌ (need Phase 2) | ❌ (need Phase 2) |

---

## v2 Acceptance Checklist

- [ ] Secrets no longer persisted in plaintext `.env` (or formally exception-approved with compensating controls)
- [ ] Provider allowlist route tests pass (including doubao path cases)
- [ ] Video workflow does not require global body-limit increase
- [ ] NAS/mini PC memory profile remains stable under mixed text + video-reference load
- [ ] Phase 1a (per-project budget) implemented and enforced

---

## Bottom Line

After the security patch, the project is materially safer and closer to target positioning.

**Immediate priorities** (to match enterprise baseline):
1. Per-project budget enforcement (Phase 1a) — the single biggest feature gap vs. both competitors
2. Per-project model allowlist (Phase 1b) — low effort, high control value
3. Secret management uplift (O-01) — plaintext `.env` is the last remaining security finding

**Medium-term** (to differentiate):
4. Multi-channel failover (Phase 2a) — reliability parity with One-API/LiteLLM
5. Structured logging (Phase 3b) — enterprise observability baseline

The project's core advantage is **operational simplicity at the edge** — zero external dependencies, 30 MB footprint, built-in CLI/TUI/chat tooling. This is a defensible position that neither LiteLLM (heavy stack) nor One-API (no CLI/TUI, approximate billing) matches. Focus on closing the budget/routing gaps while preserving this lightweight architecture.
