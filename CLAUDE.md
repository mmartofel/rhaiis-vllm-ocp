# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This repository deploys a vLLM OpenAI-compatible inference server on Red Hat OpenShift using the **Red Hat AI Inference Server (RHAIIS)** image. The primary entry point is `deploy.sh`, which renders Kubernetes manifests from `user-values.env` and applies them with `oc`.

## Deployment

```bash
cp user-values.env.example user-values.env   # fill in your values
bash deploy.sh
```

## Key design: single-container with lazy model download

The `k8s/deployment.yaml` uses a **single container** with a shell wrapper entrypoint. On startup the wrapper:

1. Checks whether `${MODEL_PATH}/config.json` already exists on the PVC
2. If missing, runs `huggingface-cli download` to fetch the model (download is resumable)
3. `exec`s into `python -m vllm.entrypoints.openai.api_server` so Python becomes PID 1 and receives SIGTERM correctly

The model is downloaded once and persisted on the PVC (`vllm-models-cache`). Subsequent pod restarts skip the download entirely.

## Key vLLM server parameters (`k8s/deployment.yaml`)

| Parameter | Value | Purpose |
|---|---|---|
| `--tensor-parallel-size` | `1` | Single GPU inference |
| `--max-num-seqs` | `128` | Max concurrent sequences |
| `--max-model-len` | `4096` | Max context length |
| `--gpu-memory-utilization` | `0.9` | 90% VRAM allocation |
| `--enforce-eager` | — | Disables CUDA graph capture (slower but less memory) |

## API

Once the pod is Ready, the server exposes an OpenAI-compatible API via the OpenShift Route. Standard endpoints like `/v1/chat/completions`, `/v1/completions`, and `/v1/models` are available.
