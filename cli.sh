#!/usr/bin/env bash
# ============================================================
# LumiGate — CLI Tool
# Quick terminal commands for managing the gateway
# ============================================================
set -euo pipefail

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

# --- Config ---
CONFIG_FILE="${HOME}/.aigateway"
GATEWAY_URL="${GATEWAY_URL:-}"
GATEWAY_SECRET="${GATEWAY_SECRET:-}"

# Load config file if env vars not set
if [[ -f "$CONFIG_FILE" ]]; then
  [[ -z "$GATEWAY_URL" ]] && GATEWAY_URL=$(grep -E '^GATEWAY_URL=' "$CONFIG_FILE" 2>/dev/null | cut -d= -f2- | tr -d '"' || true)
  [[ -z "$GATEWAY_SECRET" ]] && GATEWAY_SECRET=$(grep -E '^GATEWAY_SECRET=' "$CONFIG_FILE" 2>/dev/null | cut -d= -f2- | tr -d '"' || true)
fi

# Also try .env in script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/.env" ]]; then
  [[ -z "$GATEWAY_URL" ]] && GATEWAY_URL=$(grep -E '^GATEWAY_URL=' "${SCRIPT_DIR}/.env" 2>/dev/null | cut -d= -f2- | tr -d '"' || true)
  [[ -z "$GATEWAY_SECRET" ]] && {
    GATEWAY_SECRET=$(grep -E '^ADMIN_SECRET=' "${SCRIPT_DIR}/.env" 2>/dev/null | cut -d= -f2- | tr -d '"' || true)
  }
fi

GATEWAY_URL="${GATEWAY_URL:-http://localhost:9471}"
# Strip trailing slash
GATEWAY_URL="${GATEWAY_URL%/}"

# --- Dependency check ---
check_deps() {
  local missing=()
  command -v curl >/dev/null 2>&1 || missing+=("curl")
  command -v jq >/dev/null 2>&1 || missing+=("jq")
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo -e "${RED}Error: Missing required tools: ${missing[*]}${RESET}"
    echo "Install with: brew install ${missing[*]}  (macOS) or apt install ${missing[*]}  (Linux)"
    exit 1
  fi
}

# --- HTTP helpers ---
api_get() {
  local path="$1"
  local response
  response=$(curl -s -w "\n%{http_code}" --max-time 15 \
    -H "X-Admin-Token: ${GATEWAY_SECRET}" \
    "${GATEWAY_URL}${path}" 2>&1) || {
    echo -e "${RED}Error: Cannot reach gateway at ${GATEWAY_URL}${RESET}"
    exit 1
  }
  local http_code
  http_code=$(echo "$response" | tail -1)
  local body
  body=$(echo "$response" | sed '$d')

  if [[ "$http_code" == "401" ]]; then
    echo -e "${RED}Error: Unauthorized — check GATEWAY_SECRET${RESET}"
    echo -e "${DIM}Set via: export GATEWAY_SECRET=<secret>  or in ~/.aigateway${RESET}"
    exit 1
  fi
  if [[ "$http_code" -ge 400 ]]; then
    local err
    err=$(echo "$body" | jq -r '.error // "Unknown error"' 2>/dev/null || echo "$body")
    echo -e "${RED}Error (HTTP $http_code): ${err}${RESET}"
    exit 1
  fi
  echo "$body"
}

api_post() {
  local path="$1"
  local data="${2:-{}}"
  local response
  response=$(curl -s -w "\n%{http_code}" --max-time 30 \
    -X POST \
    -H "Content-Type: application/json" \
    -H "X-Admin-Token: ${GATEWAY_SECRET}" \
    -d "$data" \
    "${GATEWAY_URL}${path}" 2>&1) || {
    echo -e "${RED}Error: Cannot reach gateway at ${GATEWAY_URL}${RESET}"
    exit 1
  }
  local http_code
  http_code=$(echo "$response" | tail -1)
  local body
  body=$(echo "$response" | sed '$d')

  if [[ "$http_code" == "401" ]]; then
    echo -e "${RED}Error: Unauthorized — check GATEWAY_SECRET${RESET}"
    exit 1
  fi
  echo "$body"
}

api_delete() {
  local path="$1"
  local response
  response=$(curl -s -w "\n%{http_code}" --max-time 15 \
    -X DELETE \
    -H "X-Admin-Token: ${GATEWAY_SECRET}" \
    "${GATEWAY_URL}${path}" 2>&1) || {
    echo -e "${RED}Error: Cannot reach gateway at ${GATEWAY_URL}${RESET}"
    exit 1
  }
  local http_code
  http_code=$(echo "$response" | tail -1)
  local body
  body=$(echo "$response" | sed '$d')

  if [[ "$http_code" == "401" ]]; then
    echo -e "${RED}Error: Unauthorized — check GATEWAY_SECRET${RESET}"
    exit 1
  fi
  echo "$body"
}

# --- Formatting helpers ---
print_header() {
  echo ""
  echo -e "${BOLD}${BLUE}$1${RESET}"
  echo -e "${DIM}$(printf '─%.0s' $(seq 1 "${#1}"))${RESET}"
}

print_kv() {
  printf "  ${BOLD}%-16s${RESET} %s\n" "$1" "$2"
}

format_uptime() {
  local seconds=$1
  local d=$((seconds / 86400))
  local h=$(( (seconds % 86400) / 3600 ))
  local m=$(( (seconds % 3600) / 60 ))
  if [[ $d -gt 0 ]]; then
    echo "${d}d ${h}h ${m}m"
  elif [[ $h -gt 0 ]]; then
    echo "${h}h ${m}m"
  else
    echo "${m}m $((seconds % 60))s"
  fi
}

# --- Commands ---
cmd_status() {
  print_header "Gateway Status"

  local health
  health=$(api_get "/health")

  local status
  status=$(echo "$health" | jq -r '.status')
  local uptime_s
  uptime_s=$(echo "$health" | jq -r '.uptime')
  local providers_json
  providers_json=$(echo "$health" | jq -r '.providers')
  local provider_count
  provider_count=$(echo "$health" | jq '.providers | length')
  local total_providers=8

  if [[ "$status" == "ok" ]]; then
    print_kv "Status:" "${GREEN}● Online${RESET}"
  else
    print_kv "Status:" "${RED}● Offline${RESET}"
  fi

  print_kv "URL:" "${GATEWAY_URL}"
  print_kv "Uptime:" "$(format_uptime "$uptime_s")"
  print_kv "Providers:" "${GREEN}${provider_count}${RESET}/${total_providers} configured"

  echo ""
  echo -e "  ${DIM}Active:${RESET} $(echo "$health" | jq -r '.providers | join(", ")')"
  echo ""
}

cmd_providers() {
  print_header "Providers"

  local providers
  providers=$(api_get "/providers")

  printf "\n  ${BOLD}%-12s %-10s %s${RESET}\n" "PROVIDER" "STATUS" "BASE URL"
  echo -e "  ${DIM}$(printf '─%.0s' $(seq 1 60))${RESET}"

  echo "$providers" | jq -r '.[] | "\(.name) \(.available) \(.baseUrl)"' | while read -r name available url; do
    local status_str
    if [[ "$available" == "true" ]]; then
      status_str="${GREEN}● online${RESET} "
    else
      status_str="${RED}○ no key${RESET} "
    fi
    printf "  %-12s ${status_str}  ${DIM}%s${RESET}\n" "$name" "$url"
  done
  echo ""
}

cmd_test() {
  local provider="${1:-}"
  local model="${2:-}"

  if [[ -z "$provider" ]]; then
    echo -e "${RED}Usage: $0 test <provider> [model]${RESET}"
    echo -e "${DIM}Example: $0 test deepseek deepseek-chat${RESET}"
    exit 1
  fi

  local query=""
  [[ -n "$model" ]] && query="?model=${model}"

  echo -e "\n  ${DIM}Testing ${provider}${model:+ (model: $model)}...${RESET}"

  local result
  result=$(api_get "/admin/test/${provider}${query}")

  local success
  success=$(echo "$result" | jq -r '.success')

  if [[ "$success" == "true" ]]; then
    local reply latency rmodel
    reply=$(echo "$result" | jq -r '.reply')
    latency=$(echo "$result" | jq -r '.latency')
    rmodel=$(echo "$result" | jq -r '.model')

    echo ""
    echo -e "  ${GREEN}✓ Success${RESET}"
    print_kv "Model:" "$rmodel"
    print_kv "Reply:" "$reply"
    print_kv "Latency:" "${latency}ms"
  else
    local error
    error=$(echo "$result" | jq -r '.error')
    local latency
    latency=$(echo "$result" | jq -r '.latency // "—"')

    echo ""
    echo -e "  ${RED}✗ Failed${RESET}"
    print_kv "Error:" "$error"
    [[ "$latency" != "—" ]] && print_kv "Latency:" "${latency}ms"
  fi
  echo ""
}

cmd_projects() {
  local action="${1:-list}"

  case "$action" in
    list|"")
      print_header "Projects"

      local projects
      projects=$(api_get "/admin/projects")

      local count
      count=$(echo "$projects" | jq 'length')

      if [[ "$count" -eq 0 ]]; then
        echo -e "\n  ${DIM}No projects configured${RESET}"
        echo -e "  ${DIM}Create one: $0 projects add <name>${RESET}\n"
        return
      fi

      printf "\n  ${BOLD}%-20s %-10s %-24s %s${RESET}\n" "NAME" "STATUS" "CREATED" "KEY (first 16)"
      echo -e "  ${DIM}$(printf '─%.0s' $(seq 1 72))${RESET}"

      echo "$projects" | jq -r '.[] | "\(.name)\t\(.enabled)\t\(.createdAt)\t\(.key)"' | while IFS=$'\t' read -r name enabled created key; do
        local status_str
        if [[ "$enabled" == "true" ]]; then
          status_str="${GREEN}enabled${RESET}  "
        else
          status_str="${RED}disabled${RESET} "
        fi
        local key_short="${key:0:16}..."
        local created_short="${created:0:10}"
        printf "  %-20s ${status_str} %-24s ${DIM}%s${RESET}\n" "$name" "$created_short" "$key_short"
      done
      echo ""
      ;;

    add)
      local name="${2:-}"
      if [[ -z "$name" ]]; then
        echo -e "${RED}Usage: $0 projects add <name>${RESET}"
        exit 1
      fi

      local result
      result=$(api_post "/admin/projects" "{\"name\":\"${name}\"}")

      local success
      success=$(echo "$result" | jq -r '.success')

      if [[ "$success" == "true" ]]; then
        local key
        key=$(echo "$result" | jq -r '.project.key')
        echo ""
        echo -e "  ${GREEN}✓ Project '${name}' created${RESET}"
        echo ""
        echo -e "  ${BOLD}API Key:${RESET} ${YELLOW}${key}${RESET}"
        echo -e "  ${DIM}Use as Bearer token or X-Project-Key header${RESET}"
      else
        local error
        error=$(echo "$result" | jq -r '.error')
        echo -e "\n  ${RED}✗ Failed: ${error}${RESET}"
      fi
      echo ""
      ;;

    del|delete|rm)
      local name="${2:-}"
      if [[ -z "$name" ]]; then
        echo -e "${RED}Usage: $0 projects del <name>${RESET}"
        exit 1
      fi

      local result
      result=$(api_delete "/admin/projects/${name}")

      local success
      success=$(echo "$result" | jq -r '.success')

      if [[ "$success" == "true" ]]; then
        echo -e "\n  ${GREEN}✓ Project '${name}' deleted${RESET}\n"
      else
        local error
        error=$(echo "$result" | jq -r '.error')
        echo -e "\n  ${RED}✗ Failed: ${error}${RESET}\n"
      fi
      ;;

    *)
      echo -e "${RED}Unknown projects action: ${action}${RESET}"
      echo -e "  ${DIM}Available: list, add <name>, del <name>${RESET}"
      exit 1
      ;;
  esac
}

cmd_usage() {
  local days="${1:-7}"

  print_header "Usage Summary (${days} days)"

  local summary
  summary=$(api_get "/admin/usage/summary?days=${days}")

  local total_requests total_cost
  total_requests=$(echo "$summary" | jq -r '.totalRequests')
  total_cost=$(echo "$summary" | jq -r '.totalCost')

  print_kv "Requests:" "$total_requests"
  print_kv "Total cost:" "${YELLOW}\$${total_cost} USD${RESET}"

  echo ""
  echo -e "  ${BOLD}By project:${RESET}"
  echo ""

  local project_data
  project_data=$(echo "$summary" | jq -r '.byProject | to_entries[] | "\(.key)\t\(.value.requests)\t\(.value.cost)\t\(.value.inputTokens)\t\(.value.outputTokens)"')

  if [[ -z "$project_data" ]]; then
    echo -e "  ${DIM}No usage data${RESET}\n"
    return
  fi

  printf "  ${BOLD}%-20s %10s %12s %14s %14s${RESET}\n" "PROJECT" "REQUESTS" "COST (USD)" "INPUT TKN" "OUTPUT TKN"
  echo -e "  ${DIM}$(printf '─%.0s' $(seq 1 72))${RESET}"

  echo "$project_data" | while IFS=$'\t' read -r name requests cost input output; do
    printf "  %-20s %10s ${YELLOW}%12s${RESET} %14s %14s\n" \
      "$name" "$requests" "\$${cost}" "$input" "$output"
  done

  # Model breakdown
  echo ""
  echo -e "  ${BOLD}By model:${RESET}"
  echo ""

  local max_cost
  max_cost=$(echo "$summary" | jq '[.byProject[].models | to_entries[].value.cost] | max // 0')

  printf "  ${BOLD}%-30s %8s %12s  %s${RESET}\n" "MODEL" "CALLS" "COST" "BAR"
  echo -e "  ${DIM}$(printf '─%.0s' $(seq 1 72))${RESET}"

  echo "$summary" | jq -r '
    [.byProject | to_entries[] | .value.models | to_entries[] |
      { model: .key, count: .value.count, cost: .value.cost }
    ] | group_by(.model) | map({
      model: .[0].model,
      count: (map(.count) | add),
      cost: (map(.cost) | add)
    }) | sort_by(-.cost)[] |
    "\(.model)\t\(.count)\t\(.cost)"
  ' | while IFS=$'\t' read -r model count cost; do
    # Build a simple bar (max 20 chars)
    local bar_len=0
    if command -v bc >/dev/null 2>&1 && [[ $(echo "$max_cost > 0" | bc -l 2>/dev/null || echo "0") == "1" ]]; then
      bar_len=$(echo "scale=0; ($cost / $max_cost) * 20" | bc -l 2>/dev/null | cut -d. -f1 || echo "0")
    fi
    [[ -z "$bar_len" ]] && bar_len=0

    local bar=""
    for ((i = 0; i < bar_len; i++)); do bar+="█"; done
    local remaining=$((20 - bar_len))
    for ((i = 0; i < remaining; i++)); do bar+="░"; done

    local cost_str
    if [[ "$cost" == "0" ]]; then
      cost_str="${DIM}\$0 (free)${RESET}"
    else
      cost_str="${YELLOW}\$${cost}${RESET}"
    fi
    printf "  %-30s %8s %12s  ${GREEN}%s${RESET}\n" "$model" "$count" "$(echo -e "$cost_str")" "$bar"
  done
  echo ""
}

cmd_models() {
  local provider="${1:-}"

  if [[ -z "$provider" ]]; then
    echo -e "${RED}Usage: $0 models <provider>${RESET}"
    echo -e "${DIM}Providers: deepseek, openai, anthropic, gemini, kimi, doubao, qwen, minimax${RESET}"
    exit 1
  fi

  print_header "Models — ${provider}"

  local models
  models=$(api_get "/models/${provider}")

  local count
  count=$(echo "$models" | jq 'length')

  if [[ "$count" -eq 0 ]]; then
    echo -e "\n  ${RED}No models found for '${provider}'${RESET}\n"
    return
  fi

  printf "\n  ${BOLD}%-28s %-10s %8s %8s %8s  %s${RESET}\n" \
    "MODEL" "TIER" "IN/1M" "CACHE" "OUT/1M" "CAPS"
  echo -e "  ${DIM}$(printf '─%.0s' $(seq 1 80))${RESET}"

  echo "$models" | jq -r '.[] | "\(.id)\t\(.tier)\t\(.price.in)\t\(.price.cacheIn)\t\(.price.out)\t\(.caps | join(","))\t\(.desc)\t\(.freeRPD // 0)"' | \
  while IFS=$'\t' read -r id tier price_in price_cache price_out caps desc free_rpd; do
    local tier_color
    case "$tier" in
      economy)  tier_color="${GREEN}${tier}${RESET}   " ;;
      standard) tier_color="${YELLOW}${tier}${RESET}  " ;;
      flagship) tier_color="${RED}${tier}${RESET}  " ;;
      *)        tier_color="$tier" ;;
    esac
    local free_str=""
    [[ "$free_rpd" -gt 0 ]] && free_str=" ${CYAN}(${free_rpd} free/d)${RESET}"

    printf "  %-28s ${tier_color} %7s %7s %7s  ${DIM}%s${RESET}%s\n" \
      "$id" "\$${price_in}" "\$${price_cache}" "\$${price_out}" "$caps" "$(echo -e "$free_str")"
    echo -e "  ${DIM}  └ ${desc}${RESET}"
  done
  echo ""
}

cmd_key() {
  local provider="${1:-}"
  local key="${2:-}"

  if [[ -z "$provider" || -z "$key" ]]; then
    echo -e "${RED}Usage: $0 key <provider> <api-key>${RESET}"
    echo -e "${DIM}Example: $0 key openai sk-proj-abc123${RESET}"
    exit 1
  fi

  local result
  result=$(api_post "/admin/key" "{\"provider\":\"${provider}\",\"apiKey\":\"${key}\"}")

  local success
  success=$(echo "$result" | jq -r '.success')

  if [[ "$success" == "true" ]]; then
    echo -e "\n  ${GREEN}✓ API key updated for '${provider}'${RESET}"
    echo -e "  ${DIM}Key persisted to .env on server${RESET}\n"
  else
    local error
    error=$(echo "$result" | jq -r '.error')
    echo -e "\n  ${RED}✗ Failed: ${error}${RESET}\n"
  fi
}

cmd_help() {
  echo ""
  echo -e "${BOLD}${BLUE}LumiGate — CLI${RESET}"
  echo -e "${DIM}Manage your gateway from the terminal${RESET}"
  echo ""
  echo -e "${BOLD}Usage:${RESET}  $0 <command> [args]"
  echo ""
  echo -e "${BOLD}Commands:${RESET}"
  printf "  ${CYAN}%-30s${RESET} %s\n" "status"                "Show gateway status, providers, uptime"
  printf "  ${CYAN}%-30s${RESET} %s\n" "providers"             "List all providers with status"
  printf "  ${CYAN}%-30s${RESET} %s\n" "test <provider> [model]" "Test a provider connection"
  printf "  ${CYAN}%-30s${RESET} %s\n" "projects"              "List all projects"
  printf "  ${CYAN}%-30s${RESET} %s\n" "projects add <name>"   "Create a new project"
  printf "  ${CYAN}%-30s${RESET} %s\n" "projects del <name>"   "Delete a project"
  printf "  ${CYAN}%-30s${RESET} %s\n" "usage [days]"          "Show usage summary (default: 7 days)"
  printf "  ${CYAN}%-30s${RESET} %s\n" "models <provider>"     "List models for a provider"
  printf "  ${CYAN}%-30s${RESET} %s\n" "key <provider> <key>"  "Update provider API key"
  printf "  ${CYAN}%-30s${RESET} %s\n" "help"                  "Show this help"
  echo ""
  echo -e "${BOLD}Config:${RESET}"
  echo -e "  Environment variables or ${CYAN}~/.aigateway${RESET} file:"
  echo -e "    ${DIM}GATEWAY_URL=http://localhost:9471${RESET}"
  echo -e "    ${DIM}GATEWAY_SECRET=your-admin-secret${RESET}"
  echo ""
  echo -e "  Also reads ${CYAN}ADMIN_SECRET${RESET} from ${CYAN}.env${RESET} in the script directory."
  echo ""
}

# --- Main ---
check_deps

COMMAND="${1:-help}"
shift || true

case "$COMMAND" in
  status)     cmd_status ;;
  providers)  cmd_providers ;;
  test)       cmd_test "$@" ;;
  projects)   cmd_projects "$@" ;;
  usage)      cmd_usage "$@" ;;
  models)     cmd_models "$@" ;;
  key)        cmd_key "$@" ;;
  help|--help|-h) cmd_help ;;
  *)
    echo -e "${RED}Unknown command: ${COMMAND}${RESET}"
    echo -e "Run ${CYAN}$0 help${RESET} for available commands."
    exit 1
    ;;
esac
