
# Enterprise Gateway Code Review Report (v3)

Project: `ai-api-proxy`  
Date: 2026-03-10  
Scope: Full review + runnable tests (security, smoke, basic load)

## Executive Verdict

The project has improved significantly and passes current built-in test coverage.  
However, **enterprise-grade positioning is still blocked by 2 High findings**:

1. user-session path can bypass project-level policy in `/v1/*`
2. root/admin privilege boundary is still too weak for identity governance

For NAS/mini-PC goals, runtime posture remains good (lightweight stack, low overhead, stable smoke/load results).

---

## Findings (Open Only)

### H-01 (High) - Session-based bypass of project policy in proxy path

- File: `server.js`
- Route/Function: `app.use("/v1/:provider", ...)`, `hasAdminSession()`
- Risk: any valid session enters `_chat` branch; project key, allowlist, and budget checks are skipped.
- Impact: weak tenant isolation for non-root users if session cookies are present.

```1168:1181:server.js
app.use("/v1/:provider", apiLimiter, (req, res, next) => {
  // Identify project: internal chat key, admin session, project key, or reject
  let projectName;
  const projectKey =
    req.headers["x-project-key"] ||
    (req.headers["authorization"] || "").replace(/^Bearer\s+/i, "");

  if (safeEqual(projectKey, INTERNAL_CHAT_KEY)) {
    projectName = "_chat";
  } else if (hasAdminSession(req)) {
    projectName = "_chat";
```

Recommendation:
- Restrict `_chat` shortcut to `root/admin` only (not generic `hasAdminSession`), or remove it and require explicit project key for API traffic.

---

### H-02 (High) - `admin` can mint/promote other admins

- File: `server.js`
- Route/Function: `/admin/users` create/update handlers with `requireRole("root","admin")`
- Risk: compromised admin can create more admins, increasing blast radius and persistence.

```1016:1026:server.js
app.post("/admin/users", requireRole("root", "admin"), async (req, res) => {
  const { username, password, role, projects: linkedProjects } = req.body;
  // ...
  if (!["admin", "user"].includes(role)) {
    return res.json({ success: false, error: "Role must be 'admin' or 'user'" });
  }
```

```1056:1058:server.js
if (req.body.role && ["admin", "user"].includes(req.body.role)) {
  user.role = req.body.role;
}
```

Recommendation:
- Make admin user-management operations root-only for role elevation and admin creation.

---

### M-01 (Medium) - Secrets still plaintext in `.env`

- File: `server.js`
- Route: `POST /admin/key`
- Risk: file permission hardening helps, but plaintext at rest remains.

```1003:1005:server.js
// F-05: Write with strict permissions (owner read/write only)
fs.writeFileSync(envPath, envContent, { mode: 0o600 });
```

Recommendation:
- move secrets to Vault/KMS/SSM (or equivalent); keep `.env` non-sensitive.

---

### M-02 (Medium) - Free-tier accounting is cross-project aggregated

- File: `server.js`
- Routes: `/admin/usage`, `/admin/usage/summary`
- Risk: one tenant can affect another tenant's free-tier cost attribution.

```833:843:server.js
const dailyCounts = {};
for (let i = 0; i < days; i++) {
  // ...
  for (const [, models] of Object.entries(dayData)) {
    for (const [modelKey, stats] of Object.entries(models)) {
      dailyCounts[dateKey][modelKey] = (dailyCounts[dateKey][modelKey] || 0) + stats.count;
```

Recommendation:
- compute free-tier counters per project (or explicitly define global-pool billing policy in docs/contract).

---

### L-01 (Low) - Rate-limit key relies on forwarding header trust

- File: `server.js`
- Function: `normalizeIP()`
- Risk: spoofing possible if app exposed without trusted reverse proxy normalization.

```82:85:server.js
function normalizeIP(req) {
  const forwarded = req.headers["x-forwarded-for"]?.split(",")[0]?.trim();
  const ip = forwarded || req.ip || "unknown";
```

Recommendation:
- enforce trusted proxy assumptions explicitly in deployment guardrails.

---

## Verified as Fixed from Previous Reviews

These previously reported issues are now covered:
- tenant auth bypass when no projects existed
- chat key exposed to browser
- baseUrl SSRF hardening baseline (URL parse + host allowlist + DNS check)
- body limit reduced from 100MB to 10MB
- provider list leakage in unknown-provider responses
- path allowlist normalization regression (doubao/gemini route normalization tests pass)

---

## Tests Executed (This Review)

Environment: running instance on `localhost:9471`

- `node -c server.js` -> PASS
- `npm audit --omit=dev --json` -> PASS (0 vulns)
- `bash ./test-v2.sh` -> PASS (`27/27`)
- Unauthorized admin access (`GET /admin/projects`) -> `401`
- Oversized JSON body (`/admin/login`, ~11MB) -> `413`
- Login brute-force limiter (12 wrong attempts) -> `401 ... 429 ...`
- Basic load (`ab -n 500 -c 50 /health`) -> PASS
  - failed requests: `0`
  - requests/sec: ~`2313`
  - mean request time: `21.6ms`

---

## Positioning Fit (SME enterprise + NAS/mini-PC)

- **SME + self-hosted**: strong fit
- **NAS/mini-PC deployability**: strong fit
- **Low-memory direction**: strong fit (current limits and architecture support this)
- **Enterprise security maturity**: moderate (blocked by H-01/H-02)

---

## Priority Actions for v4

1. Fix H-01: lock `_chat` bypass to `root/admin` only or remove session bypass for `/v1/*`.
2. Fix H-02: root-only admin account creation/promotion.
3. Plan secret backend migration path (M-01).
4. Decide and codify tenant-billing policy for free-tier accounting (M-02).

