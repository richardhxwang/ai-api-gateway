# AI API Gateway — Development Guide

## Project
Self-hosted multi-provider AI API gateway. Express.js + Nginx + Docker.
Target: Personal/SME, AI-driven apps, ~10k DAU, runs on NAS/mini PC.

## Build & Run
```bash
docker compose up -d --build          # Full stack (nginx + app + cloudflare)
docker compose up -d --build ai-api-proxy  # Rebuild app only
node server.js                        # Direct run (dev)
```

## Test
```bash
node -c server.js                     # Syntax check
curl http://localhost:9471/health      # Health check
ab -n 1000 -c 100 http://localhost:9471/health  # Stress test
```

## Architecture
- **server.js** — Single monolith: proxy, auth, usage tracking, admin API, cost engine
- **nginx/nginx.conf** — Reverse proxy with cache, failover, maintenance pages, security headers
- **public/index.html** — Dashboard SPA (Canvas charts, SF Pro fonts, Apple HIG style)
- **public/chat.html** — Chat interface (SSE streaming, admin-session gated)
- **data/** — JSON persistence (projects, usage, exchange rates). Docker volume mounted.

## Key Patterns
- **Auth**: Session tokens in Map, 24h expiry. Cookie (HttpOnly+Secure+SameSite). CLI/TUI can use raw ADMIN_SECRET directly.
- **Proxy**: Single pre-created middleware with dynamic `router`. Auth headers injected in onProxyReq. Usage parsed from SSE tail buffer (8KB).
- **Data writes**: Always atomic (tmp file + rename). ensureDataDir() runs once.
- **Rate limiting**: normalizeIP() handles IPv6-mapped IPv4. Nginx sets X-Forwarded-For to $remote_addr.
- **Security**: See PROVIDER_HOST_ALLOWLIST, ALLOWED_UPSTREAM_PATHS, isPrivateIP(), safeEqual() in server.js.

## Provider Order
openai, anthropic, gemini, deepseek, kimi, doubao, qwen, minimax

## Conventions
- Port: 9471 everywhere
- Fonts: SF Pro Display/Text (CSS), SF Pro Display (Canvas ctx.font — use double quotes for outer string)
- Currency: 10 currencies, fmtCost() with max 5 decimal places (no scientific notation)
- Body limit: 10MB (express.json + nginx client_max_body_size)
- Projects page: key hidden, click to reveal + auto-copy, 5s timeout
- Error responses: never include stack traces or internal details
- Provider responses: include baseUrl + available, never include apiKey

## Don't
- Don't use `replace_all` on strings that appear in both HTML/CSS and JavaScript (quote conflicts)
- Don't remove baseUrl from /providers response (dashboard frontend needs it)
- Don't log secrets to console
- Don't use `===` for auth comparisons (use safeEqual)
