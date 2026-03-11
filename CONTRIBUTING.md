# Contributing to LumiGate

Thanks for your interest in contributing.

## Development Setup

```bash
git clone https://github.com/richardhxwang/lumigate.git
cd lumigate
cp .env.example .env
docker compose up -d --build
```

## Before Opening a PR

1. Keep changes focused (one concern per PR).
2. Run basic checks:
   - `node -c server.js`
   - `curl http://localhost:9471/health`
3. Do not include secrets (`.env`, tokens, API keys).
4. Update docs if behavior changes.

## PR Guidelines

- Use clear titles with intent (why).
- Include:
  - summary of changes
  - test steps
  - risk or compatibility notes
- For UI changes, include screenshot or short video.

## Good First Areas

- docs and onboarding flow improvements
- CLI UX polish (`cli.sh`)
- dashboard UI fixes (`public/index.html`)
- test coverage and chaos test scripts
