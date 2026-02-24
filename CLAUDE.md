# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This repository contains a minimal vLLM inference server setup. The single script `docker.sh` launches a vLLM OpenAI-compatible server via Docker with a locally mounted model.

## Running the Server

```bash
bash docker.sh
```

This starts a vLLM server on port `8000` using the model at `/models/Qwen2.5-7B-Instruct-AWQ` (mounted from the host's `/models` directory).

## Key Configuration

All server parameters are in `docker.sh`:

| Parameter | Value | Purpose |
|---|---|---|
| `--model` | `/models/Qwen2.5-7B-Instruct-AWQ` | AWQ-quantized model path inside container |
| `--tensor-parallel-size` | `1` | Single GPU inference |
| `--max-num-seqs` | `128` | Max concurrent sequences |
| `--max-model-len` | `4096` | Max context length |
| `--gpu-memory-utilization` | `0.9` | 90% VRAM allocation |
| `--enforce-eager` | — | Disables CUDA graph capture (slower but less memory) |

The host `/models` directory is bind-mounted to `/models` inside the container. To use a different model, update the `--model` path in `docker.sh`.

## API

Once running, the server exposes an OpenAI-compatible API at `http://localhost:8000`. Standard endpoints like `/v1/chat/completions` and `/v1/completions` are available.
