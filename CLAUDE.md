# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This repository deploys a vLLM OpenAI-compatible inference server on **Red Hat OpenShift** using the RHAIIS image (`registry.redhat.io/rhaiis/vllm-cuda-rhel9`). A single `deploy.sh` script renders all Kubernetes manifests via `envsubst` and applies them with `oc apply`. The model is downloaded from Hugging Face Hub by an init container on first boot and cached on a PVC.

## Deploy

```bash
cp user-values.env.example user-values.env   # edit with your HF token and namespace
bash deploy.sh
```

`deploy.sh` sources `user-values.env`, creates the HF token secret imperatively (never touches a YAML file), renders `${VAR}` placeholders in each manifest, and applies them in order.

**Watch startup:**
```bash
oc logs -f -l app=vllm -c model-downloader -n vllm-inference   # init: model download (~5–10 min first run)
oc logs -f deployment/vllm -c server -n vllm-inference          # server: model load (~2–3 min)
oc get pods -n vllm-inference -w
```

**Test the API:**
```bash
bash curl.sh   # sends a chat completion request to the Route URL
```

## Architecture

The pod has two containers sharing a `ReadWriteOnce` PVC (`vllm-models-cache`):

1. **init container `model-downloader`** — runs `huggingface-cli download`; idempotent (skips if `config.json` already present).
2. **server container** — runs `python -m vllm.entrypoints.openai.api_server` (not `vllm serve`); reads model from PVC.

Traffic path: `Route (edge TLS)` → `Service (ClusterIP :8000)` → pod port 8000.

Deployment strategy is `Recreate` because the PVC is `ReadWriteOnce`.

## Configuration

**`user-values.env`** (gitignored) — copy from `user-values.env.example`:

| Variable | Default | Notes |
|---|---|---|
| `NAMESPACE` | `vllm-inference` | OpenShift namespace |
| `HF_DIR` | `/models-cache` | PVC mount path inside containers |
| `PVC_SIZE` | `30Gi` | Qwen2.5-7B-AWQ needs ~9 GB |
| `MODEL_ID` | `Qwen/Qwen2.5-7B-Instruct-AWQ` | HF repo ID; also used as `--served-model-name` |
| `RHIIS_IMAGE` | `registry.redhat.io/rhaiis/vllm-cuda-rhel9:3` | RHAIIS image |
| `HF_TOKEN` | — | Hugging Face read token |

**vLLM server args** (`k8s/deployment.yaml`):

| Parameter | Value | Notes |
|---|---|---|
| `--max-model-len` | `32768` | Bound by `max_position_embeddings` in model config |
| `--enable-auto-tool-choice` + `--tool-call-parser hermes` | — | Tool calling support |
| `--enforce-eager` | flag | Disables CUDA graph capture; lower memory, slightly slower |
| `--tensor-parallel-size` | `1` | Single GPU |

## OpenShift-Specific Constraints

- **anyuid SCC** — RHAIIS runs as root (UID 0); `serviceaccount.yaml` grants `anyuid` to `vllm-sa` via Role/RoleBinding. Pod spec sets `runAsUser: 0`.
- **`enableServiceLinks: false`** — OpenShift injects `VLLM_PORT=tcp://...` from the Service named `vllm`, colliding with vLLM's own integer `VLLM_PORT`. Service links must be disabled.
- **Use RHAIIS image, not community** — `vllm/vllm-openai` has a baked-in `NVIDIA_REQUIRE_CUDA` constraint capping driver compat at 570.x; RHAIIS removes this and works with driver 580.x+.
- **`HF_HUB_OFFLINE: "0"`** — must be set explicitly in the init container; the RHAIIS image defaults to offline mode.
- **Startup probe** — allows 12 min (24 × 30s) for model load before liveness/readiness kicks in.

## LiteLLM / Claude Code Integration

`setup_litellm.sh` registers the vLLM model under Anthropic alias names in LiteLLM so Claude Code can use it via `ANTHROPIC_BASE_URL`. Run it after any redeployment that changes the model registration.

### Tool calling

vLLM 0.11.2+rhai5 (RHAIIS) exposes both `/v1/chat/completions` and a native `/v1/messages` (Anthropic) endpoint.

**Working configuration** (verified end-to-end):
- vLLM: `--enable-auto-tool-choice --tool-call-parser hermes` — `hermes` is the correct parser for Qwen2.5's native `<tool_call>` format
- LiteLLM model registration: **no `drop_params`**, plus `supports_function_calling: true` and `supports_tool_choice: true` in `model_info`

**What breaks tool calling and why:**

| Mistake | Symptom | Root cause |
|---|---|---|
| `drop_params: true` in LiteLLM registration | Claude replies with raw JSON text (`{"name": "Task", "arguments": ...}`) | Silently strips `tools` and `tool_choice` before the request reaches vLLM; model has no schema, improvises JSON as plain text |
| Missing `supports_function_calling` in `model_info` | Tool call returns as text, not `tool_use` block | LiteLLM skips the OpenAI→Anthropic tool_use translation on the response |
| `--tool-call-parser pythonic` or other non-hermes parsers | Model outputs improvised XML (`<call_function>`, `<response>`, `<function_call>` tags) | Each parser injects its own system prompt format; 7B model doesn't follow it reliably and invents its own tags |

**Known limitation:** With `tool_choice: "auto"` (Claude Code default), the 7B model sometimes opts to respond in plain text rather than calling a tool. Tool calls are reliable when `tool_choice: "any"/"required"` is used. A 32B model handles `"auto"` much more consistently.

**Smoke test the full chain:**
```bash
curl -s -X POST https://<litellm-route>/v1/messages \
  -H "Authorization: Bearer <key>" \
  -H "Content-Type: application/json" \
  -H "anthropic-version: 2023-06-01" \
  -d '{
    "model": "claude-sonnet-4-5-20250929",
    "max_tokens": 64,
    "tools": [{"name": "ping", "description": "test", "input_schema": {"type": "object", "properties": {}}}],
    "tool_choice": {"type": "any"},
    "messages": [{"role": "user", "content": "call ping"}]
  }' | jq '{stop_reason, type: .content[0].type, name: .content[0].name}'
# Expected: stop_reason: "tool_use", type: "tool_use", name: "ping"
```

## Debugging

```bash
# Verify GPU/CUDA before deploying vLLM
oc apply -f debug/cuda-probe.yaml
oc logs cuda-probe -n vllm-inference
oc delete pod cuda-probe -n vllm-inference

# Re-download model (clears cache, restarts pod)
oc exec deployment/vllm -c server -n vllm-inference -- rm -rf /models-cache/Qwen /models-cache/.hf-cache
oc rollout restart deployment/vllm -n vllm-inference
```

| Symptom | Fix |
|---|---|
| Init container: `Permission denied` on PVC | Ensure `securityContext.runAsUser: 0` at pod level |
| Init container: `offline mode is enabled` | Set `HF_HUB_OFFLINE: "0"` in init container env |
| Server crashes: `VLLM_PORT` parse error | Set `enableServiceLinks: false` in pod spec |
| GPU not visible / `NVIDIA_REQUIRE_CUDA` error | Use RHAIIS image, not community `vllm/vllm-openai` |
| `/v1/models` returns a local path | Add `--served-model-name ${MODEL_ID}` to server args |
| Pod stuck `0/1 Running` | Model still loading; startup probe allows 12 min; check server logs |
