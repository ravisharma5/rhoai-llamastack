---
name: llamastack
description: LlamaStack deployment, API reference, and agent creation guide. Use when building agents with LlamaStack, deploying on OpenShift/Kubernetes, configuring MCP servers, or calling LlamaStack APIs (inference, responses, tool-runtime, toolgroups).
user-invocable: true
disable-model-invocation: false
argument-hint: "[topic: deploy | api | agent | mcp | config | gotchas]"
allowed-tools: Read, Grep, Glob
---

# LlamaStack Reference

## LlamaStack Overview

LlamaStack (v0.4.x) provides a unified API for inference, agents, RAG, tools,
safety, and evals. It uses a provider-based architecture where each capability
(inference, vector_io, tool_runtime, etc.) is backed by configurable providers.

The RHOAI (Red Hat OpenShift AI) distribution uses the `rh-dev` distribution
image which bundles vLLM inference, Milvus vector store, MCP tool runtime,
TrustAI safety, and PostgreSQL storage backends.

---

## API Reference (v0.4.x)

### Key Endpoints

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/v1/health` | GET | Health check |
| `/v1/models` | GET | List registered models |
| `/v1/chat/completions` | POST | OpenAI-compatible chat completions |
| `/v1/embeddings` | POST | Generate embeddings |
| `/v1/responses` | POST | **Agent loop with tool calling** (Responses API) |
| `/v1/toolgroups` | GET/POST | List/register tool groups |
| `/v1/tools` | GET | List tools (filter by `?toolgroup_id=`) |
| `/v1/tool-runtime/invoke` | POST | Directly invoke a specific tool |
| `/v1/tool-runtime/list-tools` | GET | List available tools from runtime |

### Responses API (Agent Loop)

The `/v1/responses` API is the primary way to build agents. It handles the full
loop server-side: tool discovery, LLM-driven tool selection, execution, and
response generation.

```python
import requests

response = requests.post(
    f"{LLAMA_STACK_URL}/v1/responses",
    json={
        "model": "vllm-inference/Llama-4-Scout-17B-16E-W4A16",
        "input": "List all pods in the llama-stack namespace",
        "tools": [
            {
                "type": "mcp",
                "server_label": "openshift",
                "server_url": "http://openshift-mcp-server:8080/sse",
                "require_approval": "never",
            }
        ],
        "stream": False,
    },
    verify=False,
    timeout=120,
).json()

# Response output items (in order):
#   mcp_list_tools  - tools discovered from the MCP server
#   mcp_call        - tool calls the LLM decided to make (name + arguments)
#   mcp_call_output - results returned by the MCP server
#   message         - final LLM response incorporating tool results

for item in response["output"]:
    if item["type"] == "mcp_call":
        print(f"Tool: {item['name']}({item.get('arguments', '{}')})")
    elif item["type"] == "mcp_call_output":
        print(f"Result: {item['output'][:500]}")
    elif item["type"] == "message":
        content = item.get("content", "")
        if isinstance(content, list):
            for c in content:
                if c.get("type") == "output_text":
                    print(f"Assistant: {c['text']}")
```

### Tool Types for Responses API

The `tools` parameter accepts these types:

```python
# MCP server (discovers tools automatically)
{"type": "mcp", "server_label": "name", "server_url": "http://host:port/sse", "require_approval": "never"}

# Function (explicit tool definition)
{"type": "function", "name": "my_tool", "parameters": {"type": "object", "properties": {...}}}

# Web search
{"type": "web_search"}
```

### Direct Tool Invocation

Call a specific tool without LLM involvement:

```bash
curl -X POST $LLAMA_STACK_URL/v1/tool-runtime/invoke \
  -H "Content-Type: application/json" \
  -d '{
    "tool_name": "pods_list_in_namespace",
    "kwargs": {"namespace": "default"},
    "tool_group_id": "mcp::openshift"
  }'
```

### Chat Completions (OpenAI-compatible)

```bash
curl -X POST $LLAMA_STACK_URL/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "vllm-inference/Llama-4-Scout-17B-16E-W4A16",
    "messages": [{"role": "user", "content": "Hello!"}]
  }'
```

---

## MCP Server Integration

### Registering MCP Servers (config.yaml)

MCP servers are registered in the LlamaStack config file under two sections:

1. **Provider** (in `providers.tool_runtime`):
```yaml
tool_runtime:
  - provider_id: model-context-protocol
    provider_type: remote::model-context-protocol
    config: {}
```

2. **Tool group** (in `registered_resources.tool_groups`):
```yaml
tool_groups:
  - toolgroup_id: mcp::openshift
    provider_id: model-context-protocol
    mcp_endpoint:
      uri: http://openshift-mcp-server:8080/sse
```

### MCP Authentication (Tokens & Headers)

The `mcp_endpoint` in config.yaml **only supports `uri`** -- there is no
`headers`, `token`, or `authorization` field. Auth is a request-time concern.

**Config registration** (no auth -- just makes tools discoverable):
```yaml
tool_groups:
  - toolgroup_id: mcp::my-server
    provider_id: model-context-protocol
    mcp_endpoint:
      uri: ${env.MY_MCP_URL}
```

**Request-time auth** via Responses API `/v1/responses`:
```python
{
    "tools": [{
        "type": "mcp",
        "server_label": "my-server",
        "server_url": "https://my-mcp-server/mcp",
        "authorization": "<oauth_token>",   # becomes "Bearer <token>" header
        "headers": {                         # arbitrary custom headers
            "X-Scope-OrgID": "1000"          # e.g. tenant ID
        },
        "require_approval": "never"
    }]
}
```

Key rules:
- `authorization` -- server auto-prepends `Bearer `. Do NOT include the prefix.
- `headers` -- accepts any custom headers (tenant IDs, etc.), but putting
  `Authorization` in `headers` is rejected -- use `authorization` instead.
- Store tokens/URLs as Kubernetes secrets, inject as env vars into the pod.
  The client application reads them and passes to the Responses API.

### MCP Transport

LlamaStack connects to MCP servers via SSE (Server-Sent Events) at the
`/sse` endpoint, or Streamable HTTP at `/mcp`. The MCP server must run in
HTTP mode (not stdio). For kubernetes-mcp-server, use `--port 8080` to enable
HTTP/SSE mode.

### Dynamic Registration (API)

Register without restarting:

```bash
curl -X POST $LLAMA_STACK_URL/v1/toolgroups \
  -H "Content-Type: application/json" \
  -d '{
    "toolgroup_id": "mcp::my-server",
    "provider_id": "model-context-protocol",
    "mcp_endpoint": {"uri": "http://my-mcp-server:8080/sse"}
  }'
```

---

## Deployment on OpenShift (RHOAI 3.3)

### LlamaStackDistribution CR

```yaml
apiVersion: llamastack.io/v1alpha1
kind: LlamaStackDistribution
metadata:
  name: llama-stack-server
spec:
  replicas: 1
  network:
    exposeRoute: true
    allowedFrom:
      namespaces:
        - "*"
  server:
    distribution:
      name: rh-dev
    userConfig:
      configMapName: llama-stack-run-config  # references the config.yaml ConfigMap
    containerSpec:
      port: 8321
      env:
        - name: VLLM_URL
          valueFrom:
            secretKeyRef:
              name: llama-stack-inference-secret
              key: VLLM_URL
        # ... other env vars from secrets
    storage:
      size: "10Gi"
      mountPath: "/opt/app-root/src/.llama"
```

### ConfigMap Creation

The ConfigMap key **must** be `config.yaml`:

```bash
oc create configmap llama-stack-run-config \
  --from-file=config.yaml=llamastack-config.yaml
```

### Deployment Order

1. Create namespace: `oc new-project llama-stack`
2. Create secrets (vLLM credentials, PostgreSQL credentials)
3. Create ConfigMap from config.yaml
4. Deploy PostgreSQL
5. Deploy MCP server(s)
6. Deploy LlamaStackDistribution CR
7. Create route (if operator doesn't): `oc create route edge llama-stack-server --service=llama-stack-server-service --port=8321`

---

## Config File Reference (config.yaml)

The config uses `${env.VARIABLE_NAME}` for environment variable interpolation
and `${env.VARIABLE_NAME:=default}` for defaults.

### vLLM Provider Config

```yaml
providers:
  inference:
    - provider_id: vllm-inference
      provider_type: remote::vllm
      config:
        base_url: ${env.VLLM_URL}          # MUST be base_url, not url
        max_tokens: ${env.VLLM_MAX_TOKENS:=4096}
        api_token: ${env.VLLM_API_TOKEN}
        tls_verify: ${env.VLLM_TLS_VERIFY:=false}
```

### Model Registration

```yaml
registered_resources:
  models:
    - model_id: ${env.INFERENCE_MODEL}
      provider_id: vllm-inference
      model_type: llm
      provider_model_id: ${env.INFERENCE_MODEL}
    - model_id: ${env.EMBEDDING_MODEL}
      provider_id: vllm-embedding
      model_type: embedding
      provider_model_id: ${env.EMBEDDING_PROVIDER_MODEL_ID}
      metadata:
        embedding_dimension: ${env.EMBEDDING_DIMENSION:=768}
```

---

## Common Gotchas

### 1. Use `base_url` not `url` in vLLM provider config
The RHOAI 0.4.x vLLM provider field is `base_url`. Using `url` is silently
ignored and the server crashes with "You must provide a URL".

### 2. ConfigMap key must be `config.yaml`
The operator mounts the ConfigMap at `/etc/llama-stack/` and
`LLAMA_STACK_CONFIG=/etc/llama-stack/config.yaml`. Using `run.yaml` as the key
causes "Could not resolve config" errors.

### 3. Use `userConfig.configMapName` not `userConfigMapRef`
The CRD field is `userConfig` with `configMapName` and optional
`configMapNamespace`. The field `userConfigMapRef` does not exist in the CRD
and is silently ignored.

### 4. Red Hat PostgreSQL uses `POSTGRESQL_*` env vars
The `registry.redhat.io/rhel9/postgresql-16` image expects `POSTGRESQL_USER`,
`POSTGRESQL_PASSWORD`, `POSTGRESQL_DATABASE` -- not `POSTGRES_*`.

### 5. NetworkPolicy blocks route traffic by default
The operator creates a NetworkPolicy restricting ingress. Add
`network.allowedFrom.namespaces: ["*"]` to the CR to allow the OpenShift
router to reach the service.

### 6. `exposeRoute: true` may not work in operator v0.4.0
The `network.exposeRoute` field exists in the CRD but the operator may not
create the route. Create it manually with `oc create route edge`.

### 7. Model IDs include the provider prefix
When referencing models in API calls, use the full ID including provider prefix:
`vllm-inference/Llama-4-Scout-17B-16E-W4A16` (not just `Llama-4-Scout-17B-16E-W4A16`).

### 8. MCP auth tokens cannot be set in config.yaml
The `mcp_endpoint` field only accepts `{uri: str}`. There is no `headers`,
`token`, or `authorization` field at the config level. Auth must be passed
per-request via the Responses API `authorization` and `headers` fields.
Register the toolgroup in config for discoverability, pass tokens at runtime.

### 9. No description/metadata field on ToolGroup
Unlike individual tools (which have `description` from the MCP server),
`ToolGroup` has no `description` or `metadata` field. You cannot annotate
auth requirements or usage notes at the config level. Use system prompts
or client-side orchestration instead.
