# LiteLLM Setup — Environment Variables Reference

All variables must be exported before running `setup-litellm.sh`.
The script is non-interactive — it reads everything from the environment.

---

## All Variables Are Optional

The script has **no required variables**. Sensible defaults are applied:

- If `LITELLM_MASTER_KEY` is not set, one is auto-generated and printed at the end of setup.
- If no provider keys are set, LiteLLM starts with zero models — you can add them later via the Admin UI.

| Variable | Default | Description |
|---|---|---|
| `LITELLM_MASTER_KEY` | *(auto-generated)* | Authentication key for the API and Admin UI. All requests must include this as a Bearer token. |

**Provider variables below are optional. Set any combination you need.**

---

## Provider: OpenAI

| Variable | Required | Description |
|---|---|---|
| `OPENAI_API_KEY` | Yes | Your OpenAI API key. Pre-configures: `gpt-4o`, `gpt-4o-mini`, `gpt-4-turbo`, `o1` |

---

## Provider: Anthropic

| Variable | Required | Description |
|---|---|---|
| `ANTHROPIC_API_KEY` | Yes | Your Anthropic API key. Pre-configures: `claude-sonnet-4-5`, `claude-opus-4`, `claude-haiku-3.5` |

---

## Provider: Azure OpenAI

All four variables are required when using Azure.

| Variable | Required | Description |
|---|---|---|
| `AZURE_API_KEY` | Yes | Azure OpenAI resource key |
| `AZURE_API_BASE` | Yes | Azure endpoint URL (e.g. `https://my-resource.openai.azure.com`) |
| `AZURE_API_VERSION` | Yes | API version (e.g. `2024-06-01`) |
| `AZURE_DEPLOYMENT_NAME` | Yes | The deployment/model name in your Azure resource |

---

## Provider: Local / Self-Hosted LLM

For any OpenAI-compatible endpoint (Ollama, vLLM, llama.cpp server, text-generation-webui, etc.).

| Variable | Required | Description |
|---|---|---|
| `LOCAL_LLM_ENDPOINT` | Yes | Base URL of the local LLM server (e.g. `http://10.0.0.5:11434/v1`) |
| `LOCAL_LLM_MODEL_NAME` | No | Model name to register in LiteLLM. Default: `local-model` |
| `LOCAL_LLM_API_KEY` | No | API key if the local endpoint requires one. Default: `no-key-required` |

---

## Optional / Defaults

| Variable | Default | Description |
|---|---|---|
| `LITELLM_PORT` | `4000` | Port LiteLLM listens on |
| `LITELLM_DB_NAME` | `litellm` | PostgreSQL database name |
| `LITELLM_DB_USER` | `litellm` | PostgreSQL user |
| `LITELLM_DB_PASSWORD` | *(auto-generated)* | PostgreSQL password. Auto-generated if not set; printed at end of setup |

---

## Example: Bare minimum (no providers, auto-generated key)

```bash
sudo bash setup-litellm.sh
```

The script will generate a master key and print it. Add models later via the Admin UI.

## Example: OpenAI only

```bash
export OPENAI_API_KEY="sk-proj-..."
sudo -E bash setup-litellm.sh
```

## Example: Multi-provider + Local LLM

```bash
export LITELLM_MASTER_KEY="sk-my-super-secret-key"
export OPENAI_API_KEY="sk-proj-..."
export ANTHROPIC_API_KEY="sk-ant-..."
export AZURE_API_KEY="abc123..."
export AZURE_API_BASE="https://my-resource.openai.azure.com"
export AZURE_API_VERSION="2024-06-01"
export AZURE_DEPLOYMENT_NAME="gpt-4o"
export LOCAL_LLM_ENDPOINT="http://10.0.0.5:11434/v1"
export LOCAL_LLM_MODEL_NAME="llama3"
sudo -E bash setup-litellm.sh
```

> **Note:** Use `sudo -E` to preserve your exported environment variables when running as root.
