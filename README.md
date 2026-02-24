# rhaiis-vllm-ocp

Deploy a vLLM OpenAI-compatible inference server on OpenShift using the **Red Hat AI Inference Server (RHAIIS)** image. A single `deploy.sh` script renders all manifests from a local env file and applies them to the cluster. The model is downloaded automatically from Hugging Face Hub on first start and cached on a persistent volume — subsequent restarts skip the download.

---

## Architecture

```
┌──────────────────────────────────────────────────────────┐
│  Pod (vllm)                                              │
│                                                          │
│  ┌─────────────────────────┐                             │
│  │ init: model-downloader  │──► huggingface-cli download │
│  │  runs once; skips if    │         HuggingFace Hub     │
│  │  config.json present    │                             │
│  └───────────┬─────────────┘                             │
│              │  PVC: vllm-models-cache (RWO)             │
│  ┌───────────▼─────────────┐                             │
│  │ server                  │  python -m vllm.entrypoints │
│  │  vLLM API server        │  .openai.api_server         │
│  └─────────────────────────┘                             │
└──────────────────────────────────────────────────────────┘
          │ ClusterIP :8000
          ▼
  Service (vllm) ──► Route (edge TLS) ──► external clients
```

| Component | Purpose |
|---|---|
| **init container** | Downloads the model into the PVC on first boot; idempotent |
| **server container** | Runs the vLLM OpenAI-compatible API; reads model from PVC |
| **PVC** `vllm-models-cache` | `ReadWriteOnce` persistent volume shared by both containers |
| **Route** | OpenShift edge-TLS route; hostname auto-assigned from cluster wildcard domain |

---

## Prerequisites

| Requirement | Notes |
|---|---|
| OpenShift 4.x | GPU node with NVIDIA driver ≥ 550 |
| NVIDIA GPU Operator | Provides `nvidia` runtimeClassName and device plugin |
| `oc` CLI | Logged in with cluster-admin or namespace-admin rights |
| `envsubst` | Part of `gettext` — `brew install gettext` on macOS |
| Red Hat registry pull secret | `registry.redhat.io` credentials in the target namespace |
| Hugging Face account | Free read token at [huggingface.co/settings/tokens](https://huggingface.co/settings/tokens) |

---

## Quick Start

### 1. Configure

```bash
cp user-values.env.example user-values.env
```

Edit `user-values.env`:

```bash
NAMESPACE=vllm-inference
HF_DIR=/models-cache
PVC_SIZE=30Gi
MODEL_ID="Qwen/Qwen2.5-7B-Instruct-AWQ"
RHIIS_IMAGE="registry.redhat.io/rhaiis/vllm-cuda-rhel9:3"
HF_TOKEN=hf_<your_token>
```

> **`user-values.env` contains your HF token — never commit it to git.**
> It is listed in `.gitignore` for this reason.

### 2. Deploy

```bash
bash deploy.sh
```

`deploy.sh` does the following:
1. Sources `user-values.env`
2. Creates / updates the namespace
3. Creates the `hf-token-secret` Secret imperatively (token never touches a YAML file)
4. Renders `${VAR}` placeholders in every manifest via `envsubst`
5. Applies all manifests with `oc apply`

### 3. Watch startup

```bash
# Init container — model download (first run only, ~5–10 min depending on bandwidth)
oc logs -f -l app=vllm -c model-downloader -n vllm-inference

# Server — model load and vLLM startup (~2–3 min)
oc logs -f deployment/vllm -c server -n vllm-inference

# Pod status
oc get pods -n vllm-inference -w
```

### 4. Test the API

```bash
bash curl.sh
```

Or manually:

```bash
CLUSTER_DOMAIN=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')

curl -X POST https://vllm-vllm-inference.${CLUSTER_DOMAIN}/v1/chat/completions \
  -H 'Authorization: Bearer fake-api-key' \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "Qwen/Qwen2.5-7B-Instruct-AWQ",
    "messages": [{"role": "user", "content": "What is 1 + 1?"}]
  }'
```

---

## Configuration

### `user-values.env`

| Variable | Default | Description |
|---|---|---|
| `NAMESPACE` | `vllm-inference` | OpenShift namespace |
| `HF_DIR` | `/models-cache` | PVC mount path inside containers |
| `PVC_SIZE` | `30Gi` | PVC size (Qwen2.5-7B-AWQ needs ~9 GB; increase for multiple models) |
| `MODEL_ID` | `Qwen/Qwen2.5-7B-Instruct-AWQ` | Hugging Face model repo ID |
| `RHIIS_IMAGE` | `registry.redhat.io/rhaiis/vllm-cuda-rhel9:3` | RHAIIS container image |
| `HF_TOKEN` | — | Hugging Face read token |

### vLLM server parameters (`k8s/deployment.yaml`)

| Parameter | Value | Purpose |
|---|---|---|
| `--tensor-parallel-size` | `1` | Single GPU |
| `--max-num-seqs` | `128` | Max concurrent sequences |
| `--max-model-len` | `4096` | Max context length (tokens) |
| `--gpu-memory-utilization` | `0.9` | 90 % VRAM allocation |
| `--enforce-eager` | _(flag)_ | Disables CUDA graph capture — lower memory, slightly slower |
| `--served-model-name` | `${MODEL_ID}` | Model ID returned by `/v1/models`; defaults to local path without this |

---

## Repository Layout

```
.
├── deploy.sh                   # Main deploy script — start here
├── curl.sh                     # Quick API smoke test
├── user-values.env.example     # Template — copy to user-values.env
├── k8s/
│   ├── namespace.yaml          # Namespace
│   ├── serviceaccount.yaml     # ServiceAccount + anyuid SCC Role/RoleBinding
│   ├── secret-hf-token.yaml    # Documentation only (secret created by deploy.sh)
│   ├── pvc-models.yaml         # PVC for model weights + HF cache
│   ├── deployment.yaml         # Init container (download) + server (vLLM)
│   ├── service.yaml            # ClusterIP Service on port 8000
│   ├── route.yaml              # OpenShift edge-TLS Route
│   └── kustomization.yaml      # Resource listing (reference; deploy.sh is primary)
└── debug/
    └── cuda-probe.yaml         # Diagnostic pod: verifies CUDA/GPU visibility
```

---

## OpenShift-Specific Notes

### anyuid SCC

The RHAIIS image runs as root (UID 0). `serviceaccount.yaml` grants the `anyuid` SCC to `vllm-sa` via a Role/RoleBinding. The pod spec sets `securityContext.runAsUser: 0` at the pod level so both the init container and the server container can write to the PVC mount point.

### Service link collision

OpenShift injects `<SERVICE>_PORT=tcp://...` env vars into all pods in the namespace. Because the Service is named `vllm`, this produces `VLLM_PORT=tcp://...`, which conflicts with vLLM's own `VLLM_PORT` integer variable. The deployment sets `enableServiceLinks: false` to suppress all such injections.

### RHAIIS vs community image

The community `vllm/vllm-openai` image embeds an `NVIDIA_REQUIRE_CUDA` constraint that caps driver compatibility at 570.x. The RHAIIS image (`vllm-cuda-rhel9:3`) removes this constraint and is compatible with driver 580.x and later.

### Recreate strategy

The PVC is `ReadWriteOnce` — only one node can mount it at a time. `strategy: Recreate` ensures the old pod is fully terminated before the new pod starts, preventing the new pod from being stuck waiting to claim the volume.

---

## API Reference

Once the pod is Ready, the following OpenAI-compatible endpoints are available:

| Method | Path | Description |
|---|---|---|
| `GET` | `/v1/models` | List loaded models |
| `POST` | `/v1/chat/completions` | Chat completion (messages array) |
| `POST` | `/v1/completions` | Text completion (prompt string) |
| `GET` | `/health` | Liveness / readiness check |

The model ID to use in requests is the value of `MODEL_ID` from `user-values.env`, e.g. `Qwen/Qwen2.5-7B-Instruct-AWQ`.

---

## Debugging

### GPU / CUDA probe

Verify the GPU is visible and CUDA is functional before deploying vLLM:

```bash
oc apply -f debug/cuda-probe.yaml
oc logs cuda-probe -n vllm-inference
oc delete pod cuda-probe -n vllm-inference
```

### Common issues

| Symptom | Cause | Fix |
|---|---|---|
| Init container: `Permission denied` on `/models-cache` | PVC root owned by `root:root 755`, container not running as root | Ensure `securityContext.runAsUser: 0` at pod level in `deployment.yaml` |
| Init container: `offline mode is enabled` | `HF_HUB_OFFLINE=1` baked into the RHAIIS image | Set `HF_HUB_OFFLINE: "0"` in init container env |
| Init container downloads metadata only (no `.safetensors` shards) | Download interrupted or offline mode active | Re-run with online mode; `huggingface-cli download` resumes partial downloads |
| Server crashes: `VLLM_PORT` parse error | Service link env var collision | Set `enableServiceLinks: false` in pod spec |
| GPU not visible / `NVIDIA_REQUIRE_CUDA` error | Community image driver constraint | Use RHAIIS image (`registry.redhat.io/rhaiis/vllm-cuda-rhel9:3`) |
| `/v1/models` returns a local path | `--served-model-name` not set | Add `--served-model-name ${MODEL_ID}` to server args |
| Pod stuck in `0/1 Running` (not Ready) | Model still loading | Startup probe allows up to 12 min; check server logs |
| Route returns 503 | Pod not yet Ready | Wait for `oc rollout status deployment/vllm -n vllm-inference` |

### Re-download the model

```bash
# Delete cached files via exec into the running server container
oc exec deployment/vllm -c server -n vllm-inference -- \
  rm -rf /models-cache/Qwen /models-cache/.hf-cache

# Restart to trigger the init container again
oc rollout restart deployment/vllm -n vllm-inference
```
