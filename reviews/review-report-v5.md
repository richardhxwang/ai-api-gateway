# Enterprise Gateway Detailed Review Report (v5)

Project: `ai-api-proxy`  
Date: 2026-03-11  
Scope: Full re-review + stress/chaos tests on isolated test stack (including Cloudflare service in compose)

## Executive Summary

本轮按你的要求完成了两件事：

1. **测试环境重构**：`docker-compose.test.yml` 改为完整三服务栈（`lumigate + nginx + cloudflare-lumigate-test`），不再单独手工起 Cloudflare。  
2. **详细复审 + 实测**：安全、限流、企业模块可用性、内网极限压测、外网（Cloudflare）压测、重启/强杀故障注入、数据一致性验证。

当前系统在本地与内网路径表现稳定；外网 quick tunnel 路径在高并发下波动明显（预期内，quick tunnel 非生产 SLA）。企业能力方面，已具备审计/指标/备份接口，但仍有 SME 企业化落地差距。

---

## Test Environment (Isolated)

- Compose project: `ai-api-proxy-test`
- File: `docker-compose.test.yml`
- Services:
  - `lumigate` (port 9471, `DEPLOY_MODE=enterprise`, isolated data dir `data-test`)
  - `nginx` (host port `19471`)
  - `cloudflare-lumigate-test` (quick tunnel -> `http://nginx:80`)
- External test URL (quick tunnel):  
  `https://mounted-supposed-toddler-fixed.trycloudflare.com`

---

## Findings (Current State)

### H-01 (High) - 外网入口高压稳定性不足（quick tunnel 路径）

- 现象：外网压测（Cloudflare quick tunnel）出现非零错误与高尾延迟。
- 实测：500 请求/并发 50 -> `200: 473`, `errors: 27`, `p95: 1292ms`, `p99: 3493ms`。
- 结论：不适合作为生产级稳定性判断基线；需用 **named tunnel + 正式域名** 做企业级压测。

Recommendation:
- 生产环境改为 Cloudflare named tunnel（非 quick tunnel）。
- 压测按“入口链路 + 源站链路”分层采集指标（Cloudflare edge / origin）。

---

### H-02 (High) - Secret 管理仍未达到企业最小暴露要求

- 现状：运行依赖环境变量（部署便捷，但可见面仍偏大）。
- 风险：运维排障场景下凭据暴露风险仍高于企业标准。

Recommendation:
- 落地 Vault/KMS/SSM 等外部 secret backend。
- 建立固定轮换窗口与失效策略（admin secret、provider key、tunnel token）。

---

### M-01 (Medium) - 企业模块默认受 DEPLOY_MODE 影响，易被误配为 lite

- 现象：未设置 `DEPLOY_MODE=enterprise` 时，`/admin/metrics`、`/admin/audit`、`/admin/backup*` 返回 404（模块未启用）。
- 影响：容易出现“功能存在但线上不可用”的配置错配。

Recommendation:
- 在生产 compose 增加显式 `DEPLOY_MODE=enterprise`。
- 启动时增加关键模块启用检查与告警。

---

### M-02 (Medium) - 大包体错误返回由 Nginx 直接接管（非 JSON）

- 现象：`/admin/login` 超大 payload 返回 Nginx HTML `413 Request Entity Too Large`。
- 影响：API 客户端一致性与可观测性稍弱（非统一 JSON 错误格式）。

Recommendation:
- 若需统一 API 语义，可在 Nginx 增加 JSON `error_page 413`。
- 或将 `client_max_body_size` 与应用层响应策略统一文档化。

---

## Verified Good Controls

以下能力在本轮实测通过：

- 未授权访问控制：`/admin/projects` -> `401`
- 畸形 cookie 不再触发 500：`/admin/auth` -> `200 {"authenticated":false}`
- 登录暴力限制：12 次错误登录 -> `401 x10`, `429 x2`
- API 限流：620 次无 key 请求 -> `401 x600`, `429 x20`
- 企业模块（enterprise mode）可用：
  - `/admin/metrics` -> `200`
  - `/admin/backup` -> `200`
  - `/admin/backups` -> `200`
  - `/admin/audit` -> `200`

---

## Stress & Chaos Test Results

### 1) Internal Extreme Stress (test network)

- Target: `http://nginx/health`
- Load: `20000 requests`, concurrency `250`
- Result:
  - `errors: 0`
  - `200: 20000`
  - `rps: ~12787.7`
  - `avg: 19.18ms`, `p95: 14ms`, `p99: 283ms`

### 2) External Stress (Cloudflare quick tunnel)

- Target: `https://mounted-supposed-toddler-fixed.trycloudflare.com/health`
- Load: `500 requests`, concurrency `50`
- Result:
  - `200: 473`
  - `errors: 27`
  - `rps: ~137.3`
  - `avg: 297.34ms`, `p95: 1292ms`, `p99: 3493ms`

### 3) Restart Chaos (drop/recover)

- Scenario: stop `lumigate` 3s then start, while continuous probing
- Internal (test network): `200: 78`, `errors: 0`
- External (Cloudflare): `200: 66`, `errors: 0`
- Interpretation: health path在当前 Nginx 缓存/stale 策略下具备较强连续可用性。

### 4) Crash Consistency (SIGKILL during write burst)

- Scenario: Admin 登录后连续创建项目，同时对 `lumigate` 执行 `SIGKILL` 强杀并重启
- Burst result: `ok: 120`, `fail: 100`（故障窗口内失败属预期）
- File integrity check (`data-test/projects.json`):
  - `valid_json: true`
  - `project_count: 240`
  - `.tmp leftovers: []`
- Conclusion: 当前原子写（tmp+rename）在强杀下未见 JSON 文件损坏。

---

## Resource Snapshot (Test Stack)

- Node process (`lumigate`) memory:
  - `rss ~40.02MB`
  - `heapUsed ~2.87MB`
- Container snapshot (post-test):
  - `ai-api-proxy-test-lumigate-1`: `~17.59MiB` (瞬时取样)
  - `ai-api-proxy-test-nginx-1`: `~10.52MiB`
  - `ai-api-proxy-test-cloudflare-lumigate-test-1`: `~30.87MiB`

---

## SME Enterprise Recommendations (Prioritized)

1. **Cloudflare productionization**
   - Replace quick tunnel with named tunnel + managed DNS + explicit SLO.
2. **Secret governance**
   - Move runtime secrets to Vault/KMS/SSM; enforce rotation and access policies.
3. **Module guardrails**
   - Add startup validation for `DEPLOY_MODE` and required modules.
4. **Error contract consistency**
   - Normalize 4xx/5xx response format across Nginx and app layers.
5. **Release gate**
   - Make this test matrix part of pre-release checklist (internal stress + external stress + restart chaos + crash consistency).

---

## 0->1 Deployment to Onboard Test Flow Tree

```text
Start
├─ A. Environment readiness
│  ├─ OS/Kernel/Docker/Compose version check
│  ├─ Port planning (9471 prod / 19471 test)
│  ├─ Disk and backup path check
│  └─ Time sync / timezone / NTP
├─ B. Secret and config bootstrap
│  ├─ Generate ADMIN_SECRET (strong random)
│  ├─ Provider API keys import
│  ├─ Cloudflare token/tunnel config
│  └─ DEPLOY_MODE selection (lite/enterprise)
├─ C. First deployment
│  ├─ docker compose up -d --build
│  ├─ /health check
│  ├─ /providers and /models sanity
│  └─ admin login smoke
├─ D. Security baseline
│  ├─ unauthorized admin access -> 401
│  ├─ malformed cookie -> no 500
│  ├─ oversized body -> 413
│  └─ brute-force limiter -> 429
├─ E. Functional onboarding
│  ├─ create project / rotate project key
│  ├─ add provider key(s)
│  ├─ send first proxy request (/v1/*)
│  └─ verify usage and budget counters
├─ F. Enterprise module validation (enterprise mode)
│  ├─ /admin/metrics
│  ├─ /admin/audit
│  ├─ /admin/backup + /admin/backups + restore dry-run
│  └─ role and permission boundary checks
├─ G. Reliability tests
│  ├─ internal stress
│  ├─ external stress (via Cloudflare named tunnel)
│  ├─ restart chaos
│  └─ crash consistency (SIGKILL write burst)
└─ H. Release decision
   ├─ SLO threshold met?
   ├─ no data corruption?
   ├─ secrets rotation policy in place?
   └─ Go / No-Go
```

---

## Deployment to Config Full Checklist (with issue injection)

### Phase 1: Deploy

- Pull/build image -> start compose -> verify all services healthy.
- **If issue**:
  - Nginx unhealthy: validate `nginx.conf` syntax and upstream name.
  - App unhealthy: check `ADMIN_SECRET`, port mapping, `DEPLOY_MODE`.
  - Cloudflare unhealthy: tunnel token/domain mapping, DNS route.

### Phase 2: Config

- Set mode and modules:
  - Lite: minimal modules.
  - Enterprise: `DEPLOY_MODE=enterprise`.
- Load API keys and base URLs.
- Validate provider allowlist/path restrictions.
- **If issue**:
  - 404 on enterprise endpoints: mode/module misconfig.
  - Provider unavailable: key disabled or invalid base URL.
  - 401 on proxy: project key missing/invalid.

### Phase 3: Onboard

- Create project, generate key, test first call, confirm usage write.
- Enable users/roles if needed.
- Create baseline backup snapshot.
- **If issue**:
  - Data not persisted: volume mount or write permission.
  - Login works but modules fail: lite mode accidentally enabled.
  - High latency: external tunnel instability vs origin latency not separated.

### Phase 4: Gate

- Run minimum test pack:
  - auth + limiter + oversized + malformed input
  - stress + chaos + crash consistency
- Attach results to release ticket.
- **If issue**:
  - External-only errors -> prioritize tunnel/edge config.
  - Internal and external both degrade -> app/nginx bottleneck.

---

## Lite Minimum Memory vs Enterprise Performance Plan

### Lite Mode (memory-first target)

- Goal: lowest RSS and minimal background work.
- Recommended:
  - `DEPLOY_MODE=lite`
  - only required modules active (default lite modules)
  - disable unnecessary provider keys/models in test/dev
  - keep `--max-old-space-size` conservative (already set)
  - avoid heavy dashboard refresh loops
- Practical target (current codebase):
  - app RSS ~35-45MB range (idle)
  - smallest operational footprint among supported modes
- Backup policy in lite:
  - **Manual backup/restore/list should remain available**
  - **Auto-backup should remain enabled**, but RPO target can be slightly looser than enterprise if needed
  - If no measurable performance impact, use same backup interval as enterprise for operational consistency

### Enterprise Mode (governance + observability + resilience)

- Goal: full control plane capabilities with acceptable overhead.
- Enabled:
  - audit, metrics, backup, users, budget, multikey, smart
- Trade-off:
  - slightly higher CPU/memory under admin operations and background tasks
  - better traceability/recovery for SME enterprise usage
- Optimization focus:
  - keep fast caches on hot admin endpoints
  - limit dashboard polling frequency
  - use named tunnel + route-level stress tuning
  - define SLO thresholds and alerting windows

### Suggested Mode Policy

- Development / tiny single-tenant: **Lite**
- Production SME with compliance/governance needs: **Enterprise**
- Performance testing should always report both:
  - `lite baseline`
  - `enterprise baseline`
- Guardrail:
  - `lite` must keep the same data-plane security/performance path (auth, rate-limit, allowlist, proxy safety)
  - mode difference should focus on management/governance modules, not core request handling quality

---

## GUI Mode Switch Requirement (Root Only)

- Requirement:
  - GUI should provide mode switch (`lite` / `enterprise`) in settings.
  - Mode switch operation must be restricted to `root` role only.
- Behavioral expectation:
  - After switching mode, system should persist mode config and clearly show active mode in dashboard.
  - If mode change requires restart, GUI should display explicit prompt and safe restart guidance.
- Security expectation:
  - Non-root users must not see or invoke mode switch APIs/actions.

---

## Appendix: Commands/Scenarios Executed

- Security baseline: unauthorized access, malformed cookie, oversized payload, brute-force limiter, API limiter
- Enterprise APIs: login + metrics/audit/backup/backups
- Stress: internal 20k/250, external 500/50
- Chaos: restart under probe (internal + external)
- Crash consistency: SIGKILL during write burst + data integrity verification
