# Antigravity BYOM on Google Cloud Run GPU

Connect Antigravity (`agy` CLI, Desktop App, and VS Code extension) to open-weight coding models running on Google Cloud Run GPUs over OpenAI Chat Completions (`wireProtocol: "openai"`). You authenticate with one static API key from Secret Manager, with zero proxy processes on your laptop and zero separate LiteLLM containers in Cloud Run.

Model Dockerfiles, Cloud Build pipelines, and Cloud Run GPU presets live in [eggboy/vllm-container-image](https://github.com/eggboy/vllm-container-image).

> [!IMPORTANT]
> **Support scope**: Antigravity clients support `wireProtocol: "openai"` on the Desktop App (`>= 2.15.0`), `agy` CLI (`>= 1.2.15`), and VS Code extension (`JetBrains` and `Zed` use the ACP server, restricted to `genai`). Google scopes Enterprise Gateway support to Gemini and Vertex AI models; open-weight models run outside Google support.

## Architecture

```text
Antigravity (agy / Desktop App / VS Code)
  |  HTTPS + Authorization: Bearer <VLLM_API_KEY>
  v
Google Cloud Run GPU (--no-invoker-iam-check, 1x NVIDIA RTX PRO 6000 96 GB)
  |  Secret Manager injects VLLM_API_KEY
  v
vLLM OpenAI Server (/v1/models, /v1/chat/completions)
```

Cloud Run IAM intercepts `Authorization` headers by default and rejects non-Google tokens. Deploying with `--no-invoker-iam-check` disables IAM header checks at ingress without adding `allUsers` to the IAM policy, which keeps the service compatible with GCP organizations that enforce `constraints/iam.allowedPolicyMemberDomains` (provided `constraints/run.managed.requireInvokerIam` stays unenforced). Inside the container, `vLLM` leaves `GET /health` open for Cloud Run startup probes and enforces `VLLM_API_KEY` on `/v1/*` (`HTTP 401` on missing or invalid keys).

## Prerequisites

- **Antigravity client**: `agy` CLI `>= 1.2.15`, Desktop App `>= 2.15.0`, or VS Code extension.
- **Model container image**: Built into Artifact Registry from [eggboy/vllm-container-image](https://github.com/eggboy/vllm-container-image), such as [`qwen38-27b/Dockerfile.vllm.h100`](https://github.com/eggboy/vllm-container-image/blob/main/qwen38-27b/Dockerfile.vllm.h100) (`Qwen/Qwen3.8-27B-FP8` on `vllm/vllm-openai:v0.32.0`) or [`kat-coder-v2-5-dev/Dockerfile.vllm.a100`](https://github.com/eggboy/vllm-container-image/blob/main/kat-coder-v2-5-dev/Dockerfile.vllm.a100).
- **Cloud Run GPU quota**: Regional `nvidia-rtx-pro-6000` (96 GB) or `nvidia-l4` (24 GB) quota, plus Cloud Run Admin and Secret Manager Admin roles.
- **Ingress policy**: Organization constraint `constraints/run.managed.requireInvokerIam` left unenforced (`enforce: false`) so Cloud Run accepts `--no-invoker-iam-check`.

## 1. Store a Static API Key in Secret Manager

Generate a random bearer token, store it in Secret Manager, and grant read access to the runtime service account:

```bash
PROJECT_ID="your-gcp-project-id"
REGION="asia-southeast1"
PROJECT_NUMBER="$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')"
RUNTIME_SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"

gcloud services enable secretmanager.googleapis.com run.googleapis.com --project="$PROJECT_ID"

printf 'sk-vllm-%s' "$(openssl rand -hex 24)" | \
  gcloud secrets create vllm-api-key \
    --project="$PROJECT_ID" \
    --replication-policy="user-managed" \
    --locations="$REGION" \
    --data-file=-

gcloud secrets add-iam-policy-binding vllm-api-key \
  --project="$PROJECT_ID" \
  --member="serviceAccount:${RUNTIME_SA}" \
  --role="roles/secretmanager.secretAccessor"
```

## 2. Deploy the vLLM Image to Cloud Run GPU

Deploy `Qwen3.8-27B-FP8` from your Artifact Registry copy of [eggboy/vllm-container-image](https://github.com/eggboy/vllm-container-image). Run [`GCP/deploy-cloudrun.sh`](https://github.com/eggboy/vllm-container-image/blob/main/GCP/deploy-cloudrun.sh) with `API_KEY_SECRET=vllm-api-key`, or call `gcloud run deploy`:

```bash
IMAGE="${REGION}-docker.pkg.dev/${PROJECT_ID}/vllm/qwen38-27b-vllm:h100"

gcloud run deploy qwen38-27b \
  --project="$PROJECT_ID" \
  --region="$REGION" \
  --image="$IMAGE" \
  --execution-environment=gen2 \
  --gpu=1 \
  --gpu-type=nvidia-rtx-pro-6000 \
  --no-gpu-zonal-redundancy \
  --cpu=20 \
  --memory=80Gi \
  --no-cpu-throttling \
  --port=8000 \
  --timeout=3600 \
  --concurrency=16 \
  --min-instances=0 \
  --max-instances=1 \
  --no-invoker-iam-check \
  --set-secrets="VLLM_API_KEY=vllm-api-key:latest" \
  --startup-probe="httpGet.path=/health,httpGet.port=8000,periodSeconds=30,timeoutSeconds=10,failureThreshold=60" \
  --args="/model/qwen38-27b,--host,0.0.0.0,--port,8000,--tensor-parallel-size,1,--trust-remote-code,--gpu-memory-utilization,0.92,--max-model-len,262144,--dtype,auto,--kv-cache-dtype,fp8,--language-model-only,--enable-prefix-caching,--mamba-cache-mode,align,--enable-chunked-prefill,--max-num-batched-tokens,8384,--performance-mode,interactivity,--enable-auto-tool-choice,--reasoning-parser,qwen3,--tool-call-parser,qwen3_coder,--max-num-seqs,16,--served-model-name,Qwen3.8-27B"
```

Cold start from `gcloud run deploy` to `GET /health` `200 OK` takes about 5.5 minutes on `nvidia-rtx-pro-6000`. With `--min-instances=0`, Cloud Run scales idle GPU instances to zero; set `--min-instances=1` to keep a warm GPU during active work.

## 3. Connect Antigravity

Fetch the Cloud Run URL and your static API key once. After you copy those two values, client machines need zero Google Cloud SDK credentials or `gcloud` binaries.

### CLI (`agy`) via Environment Variables

```bash
export AGY_LLM_GATEWAY_URL="$(gcloud run services describe qwen38-27b --project="$PROJECT_ID" --region="$REGION" --format='value(status.url)')"
export AGY_LLM_GATEWAY_API_KEY="$(gcloud secrets versions access latest --secret=vllm-api-key --project="$PROJECT_ID")"
export AGY_LLM_GATEWAY_WIRE_PROTOCOL="openai"
# Keep AGY_LLM_GATEWAY_MODELS unset; see Configuration Traps below.

agy models
agy --model Qwen3.8-27B
```

### Desktop App, VS Code, or MDM (`settings.json` / `admin_settings.json`)

Write user settings to `~/.antigravity/settings.json`, or managed settings to `/Library/Application Support/Antigravity/admin_settings.json` on macOS (`/etc/antigravity/admin_settings.json` on Linux, `C:\ProgramData\Antigravity\admin_settings.json` on Windows):

```json
{
  "gateway": {
    "enabled": true,
    "url": "https://qwen38-27b-<PROJECT_NUMBER>.asia-southeast1.run.app",
    "apiKey": "sk-vllm-replace-with-your-secret",
    "wireProtocol": "openai"
  },
  "models": {
    "defaultModelId": "Qwen3.8-27B",
    "list": [
      {
        "modelId": "Qwen3.8-27B",
        "maxTokens": 262144,
        "maxOutputTokens": 65535,
        "supportsThinking": true,
        "thinkingBudget": 8192
      },
      {
        "modelId": "KAT-Coder-V2.5-Dev",
        "maxTokens": 131072,
        "maxOutputTokens": 32768,
        "supportsThinking": true,
        "thinkingBudget": 8192
      }
    ]
  }
}
```

## 4. Tear Down GPU Resources

Delete the Cloud Run service after your session to eliminate GPU billing risk. Your container image in Artifact Registry and `vllm-api-key` in Secret Manager stay ready for your next deployment:

```bash
gcloud run services delete qwen38-27b \
  --project="$PROJECT_ID" \
  --region="$REGION" \
  --quiet
```

## WARNING

> [!WARNING]
> **Leave `AGY_LLM_GATEWAY_MODELS` unset for custom model IDs.** Setting `AGY_LLM_GATEWAY_MODELS="Qwen3.8-27B"` routes `agy` (`1.5.2`) through Tier 1 inline model resolution without token metadata. Unknown model IDs resolve `maxMessageTokens` to `0` and abort before network I/O with `serializing trajectory: maxMessageTokens must be positive, got 0`. Omitting `AGY_LLM_GATEWAY_MODELS` triggers Tier 3 discovery (`GET /v1/models`) and populates working token defaults (`max_completion_tokens: 65535`). If you declare `models.list` in `settings.json`, include `maxTokens` and `maxOutputTokens` as shown above.

- **Size `--max-model-len` to `262144` for agent loops.** Running `Qwen3.8-27B` at its native `262144` context window on `nvidia-rtx-pro-6000` (96 GB VRAM, 1.71M FP8 KV-cache token capacity) prevents `HTTP 400` context-overflow errors and reaches an 85.6% prefix-cache hit rate with `--enable-prefix-caching --mamba-cache-mode align`.
- **Match reasoning and tool-call parsers to the model family.** `agy` sends 15 OpenAI tool schemas and reads reasoning deltas from the stream. Pass `--enable-auto-tool-choice --reasoning-parser qwen3 --tool-call-parser qwen3_coder` for `Qwen3.8-27B` and `KAT-Coder-V2.5-Dev` (see [eggboy/vllm-container-image](https://github.com/eggboy/vllm-container-image) for per-model flags).
