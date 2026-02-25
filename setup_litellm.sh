#!/usr/bin/env bash
# =============================================================================
# setup_litellm.sh
# Configures LiteLLM to expose your vLLM Qwen model as an Anthropic-compatible
# endpoint, ready for Claude Code.
#
# Usage:
#   chmod +x setup_litellm.sh
#   ./setup_litellm.sh
#
# Optionally override defaults via env vars before running:
#   LITELLM_URL=https://... LITELLM_ADMIN_KEY=sk-... ./setup_litellm.sh
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# CONFIG — edit these or override via environment variables
# ---------------------------------------------------------------------------
LITELLM_URL="${LITELLM_URL:-https://litellm-litemaas.apps.zenek.sandbox2706.opentlc.com}"
VLLM_URL="${VLLM_URL:-https://vllm-vllm-claude.apps.zenek.sandbox2706.opentlc.com}"

# LiteLLM admin password is used to obtain a master key via the UI login flow.
# The default UI login is admin / <MASTER_KEY>.
# If you already know your master key (starts with sk-), set it directly:
LITELLM_ADMIN_KEY="${LITELLM_ADMIN_KEY:-sk-n0fpy0a2zXS2PIsIIO7kpzPN6vexD4xbWnjMUT/kcVk=}"   # not important, temporaty key
LITELLM_ADMIN_USER="${LITELLM_ADMIN_USER:-admin}"
LITELLM_ADMIN_PASS="${LITELLM_ADMIN_PASS:-admin}"

# The full model ID as reported by vLLM /v1/models
VLLM_MODEL_ID="Qwen/Qwen2.5-Coder-7B-Instruct"

# Model names that Claude Code will use — these map to the same vLLM backend
# Claude Code internally uses "sonnet" as default and "haiku" for small tasks.
# We expose the same physical model under all three Anthropic alias names so
# every request is handled regardless of which alias Claude Code picks.
CLAUDE_MODEL_NAMES=(
  "claude-sonnet-4-5-20250929"
  "claude-haiku-4-5-20251001"
  "claude-opus-4-5-20251101"
)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
check_cmd() { command -v "$1" >/dev/null 2>&1 || error "Required command not found: $1. Please install it."; }

check_cmd curl
check_cmd jq

# ---------------------------------------------------------------------------
# Step 1 — Obtain a master/admin API key
# ---------------------------------------------------------------------------
obtain_master_key() {
  if [[ -n "$LITELLM_ADMIN_KEY" ]]; then
    info "Using provided LITELLM_ADMIN_KEY."
    MASTER_KEY="$LITELLM_ADMIN_KEY"
    return
  fi

  info "No LITELLM_ADMIN_KEY provided — attempting UI login to get a key..."

  # LiteLLM's UI login endpoint returns a token we can use for API calls
  local response
  response=$(curl -sf -X POST "${LITELLM_URL}/login" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "username=${LITELLM_ADMIN_USER}&password=${LITELLM_ADMIN_PASS}" \
    2>/dev/null) || true

  # Try alternate login path used in some LiteLLM versions
  if [[ -z "$response" ]] || ! echo "$response" | jq -e '.key' >/dev/null 2>&1; then
    response=$(curl -sf -X POST "${LITELLM_URL}/user/login" \
      -H "Content-Type: application/json" \
      -d "{\"username\":\"${LITELLM_ADMIN_USER}\",\"password\":\"${LITELLM_ADMIN_PASS}\"}" \
      2>/dev/null) || true
  fi

  if echo "$response" | jq -e '.key' >/dev/null 2>&1; then
    MASTER_KEY=$(echo "$response" | jq -r '.key')
    info "Login successful. Got key: ${MASTER_KEY:0:10}..."
  else
    # Fallback: many self-hosted LiteLLM instances on OpenShift set the master
    # key to the admin password itself (password IS the key)
    warn "Could not retrieve key via login endpoint. Trying admin password as master key..."
    MASTER_KEY="${LITELLM_ADMIN_PASS}"
  fi
}

# ---------------------------------------------------------------------------
# Step 2 — Verify connectivity to both services
# ---------------------------------------------------------------------------
verify_services() {
  info "Checking vLLM health..."
  local vllm_resp
  vllm_resp=$(curl -sf "${VLLM_URL}/health" 2>/dev/null) \
    || vllm_resp=$(curl -sf "${VLLM_URL}/v1/models" 2>/dev/null) \
    || error "Cannot reach vLLM at ${VLLM_URL}. Check the URL and network access."
  info "vLLM is reachable. ✓"

  info "Checking LiteLLM health..."
  curl -sf "${LITELLM_URL}/health" >/dev/null 2>&1 \
    || curl -sf "${LITELLM_URL}/health/liveliness" >/dev/null 2>&1 \
    || error "Cannot reach LiteLLM at ${LITELLM_URL}. Check the URL and network access."
  info "LiteLLM is reachable. ✓"
}

# ---------------------------------------------------------------------------
# Step 3 — Register model mappings via LiteLLM /model/new API
# ---------------------------------------------------------------------------
deregister_model() {
  local model_name="$1"
  # Delete ALL existing registrations for this model name to avoid duplicates
  local ids
  ids=$(curl -s "${LITELLM_URL}/model/info" \
    -H "Authorization: Bearer ${MASTER_KEY}" | \
    jq -r --arg mn "$model_name" '.data[] | select(.model_name == $mn) | .model_info.id' 2>/dev/null || true)

  if [[ -z "$ids" ]]; then
    return
  fi

  while IFS= read -r id; do
    [[ -z "$id" ]] && continue
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" \
      -X POST "${LITELLM_URL}/model/delete" \
      -H "Authorization: Bearer ${MASTER_KEY}" \
      -H "Content-Type: application/json" \
      -d "{\"id\": \"$id\"}")
    info "  Removed old registration ${id} (HTTP ${code})"
  done <<< "$ids"
}

register_model() {
  local model_name="$1"
  deregister_model "$model_name"
  info "Registering model alias: ${model_name} → ${VLLM_MODEL_ID}"

  local payload
  payload=$(jq -n \
    --arg mn  "$model_name" \
    --arg m   "openai/${VLLM_MODEL_ID}" \
    --arg ab  "${VLLM_URL}/v1" \
    '{
      model_name: $mn,
      litellm_params: {
        model:       $m,
        api_base:    $ab,
        api_key:     "na",
        max_tokens:  4096
      },
      model_info: {
        max_tokens:                32768,
        max_input_tokens:          28000,
        max_output_tokens:         4096,
        input_cost_per_token:      0,
        output_cost_per_token:     0,
        mode:                      "chat",
        supports_function_calling: true,
        supports_tool_choice:      true
      }
    }')

  local http_code
  http_code=$(curl -s -o /tmp/litellm_resp.json -w "%{http_code}" \
    -X POST "${LITELLM_URL}/model/new" \
    -H "Authorization: Bearer ${MASTER_KEY}" \
    -H "Content-Type: application/json" \
    -d "$payload")

  if [[ "$http_code" =~ ^2 ]]; then
    info "  Registered successfully (HTTP ${http_code}) ✓"
  else
    local body
    body=$(cat /tmp/litellm_resp.json 2>/dev/null || echo "(no body)")
    warn "  Registration returned HTTP ${http_code}: ${body}"
    warn "  Model '${model_name}' may already exist, or the key may lack permission."
    warn "  This is non-fatal — continuing..."
  fi
}

# ---------------------------------------------------------------------------
# Step 4 — Generate a developer API key for Claude Code
# ---------------------------------------------------------------------------
generate_developer_key() {
  info "Generating a Claude Code developer API key..."

  local model_list
  model_list=$(jq -n '$ARGS.positional' --args "${CLAUDE_MODEL_NAMES[@]}")

  local payload
  payload=$(jq -n \
    --argjson ml "$model_list" \
    '{
      models:   $ml,
      metadata: { purpose: "claude-code-local" },
      key_alias: "claude-code-vllm"
    }')

  local http_code
  http_code=$(curl -s -o /tmp/litellm_key.json -w "%{http_code}" \
    -X POST "${LITELLM_URL}/key/generate" \
    -H "Authorization: Bearer ${MASTER_KEY}" \
    -H "Content-Type: application/json" \
    -d "$payload")

  if [[ "$http_code" =~ ^2 ]]; then
    DEV_KEY=$(jq -r '.key' /tmp/litellm_key.json)
    info "Developer key generated ✓"
  else
    warn "Key generation returned HTTP ${http_code}. Using master key for Claude Code."
    DEV_KEY="$MASTER_KEY"
  fi
}

# ---------------------------------------------------------------------------
# Step 5 — Verify the full chain with a test completion
# ---------------------------------------------------------------------------
smoke_test() {
  info "Running smoke test via LiteLLM Anthropic-compatible endpoint..."

  local test_model="${CLAUDE_MODEL_NAMES[0]}"
  local http_code
  http_code=$(curl -s -o /tmp/litellm_test.json -w "%{http_code}" \
    -X POST "${LITELLM_URL}/v1/messages" \
    -H "Authorization: Bearer ${DEV_KEY}" \
    -H "Content-Type: application/json" \
    -H "anthropic-version: 2023-06-01" \
    -d "{
      \"model\": \"${test_model}\",
      \"max_tokens\": 64,
      \"messages\": [{\"role\": \"user\", \"content\": \"Reply with just: OK\"}]
    }")

  if [[ "$http_code" =~ ^2 ]]; then
    local reply
    reply=$(jq -r '.content[0].text // .choices[0].message.content // "(empty)"' /tmp/litellm_test.json 2>/dev/null)
    info "Smoke test passed (HTTP ${http_code}). Model replied: '${reply}' ✓"
    return 0
  else
    local body
    body=$(cat /tmp/litellm_test.json 2>/dev/null || echo "(no body)")
    warn "Smoke test returned HTTP ${http_code}: ${body}"
    warn "The /v1/messages endpoint may not be available — check LiteLLM version."
    warn "Falling back to OpenAI-compatible endpoint for Claude Code..."
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  echo ""
  echo "============================================================"
  echo "  LiteLLM ↔ vLLM Setup for Claude Code"
  echo "  vLLM:    ${VLLM_URL}"
  echo "  LiteLLM: ${LITELLM_URL}"
  echo "============================================================"
  echo ""

  verify_services
  echo ""
  obtain_master_key
  echo ""

  for name in "${CLAUDE_MODEL_NAMES[@]}"; do
    register_model "$name"
  done
  echo ""

  generate_developer_key
  echo ""

  smoke_test
  echo ""

  # -------------------------------------------------------------------------
  # Print final instructions
  # -------------------------------------------------------------------------
  echo "============================================================"
  echo -e "${GREEN}  Setup complete! Your Claude Code environment:${NC}"
  echo "============================================================"
  echo ""
  echo "  Export these in your shell (or add to ~/.bashrc / ~/.zshrc):"
  echo ""
  echo "  export ANTHROPIC_BASE_URL=\"${LITELLM_URL}\""
  echo "  export ANTHROPIC_AUTH_TOKEN=\"${DEV_KEY}\""
  echo ""
  echo "  # Pin Claude Code to use your local model for all roles:"
  echo "  export ANTHROPIC_DEFAULT_SONNET_MODEL=\"${CLAUDE_MODEL_NAMES[0]}\""
  echo "  export ANTHROPIC_DEFAULT_HAIKU_MODEL=\"${CLAUDE_MODEL_NAMES[1]}\""
  echo "  export ANTHROPIC_DEFAULT_OPUS_MODEL=\"${CLAUDE_MODEL_NAMES[2]}\""
  echo ""
  echo "  Then simply run:  claude"
  echo ""
  echo "  To verify models registered in LiteLLM:"
  echo "  curl -s ${LITELLM_URL}/v1/models -H 'Authorization: Bearer ${DEV_KEY}' | jq '.data[].id'"
  echo ""
  echo "  LiteLLM Admin UI:  ${LITELLM_URL}/ui"
  echo ""
  echo "  NOTE: Qwen2.5-Coder-7B is a capable but small model. For best"
  echo "  agentic results with Claude Code, consider upgrading to the 32B"
  echo "  variant on your GPU cluster when capacity allows."
  echo "============================================================"
}

main "$@"
