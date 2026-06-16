# OGX (formerly LlamaStack) on RHOAI 3.4

Deploy an OGX server with MCP server integration on OpenShift AI 3.4 using the LlamaStackDistribution custom resource.

> **Migration note:** OGX v0.7.1 ships with RHOAI 3.4, replacing LlamaStack v0.4.x from RHOAI 3.3. See [Migration from RHOAI 3.3](#migration-from-rhoai-33) for breaking changes.

## Architecture

```
External vLLM Endpoints
  (Inference + Embedding)
         |
         v
+---------------------+         +-------------------------+
| OGX Server          |--SSE--->| OpenShift MCP Server    |
| (port 8321)         |         | (port 8080)             |
|                     |         +-------------------------+
| Providers:          |
|  - vllm-inference   |         +-------------------------+
|    (remote::vllm)   |--SSE--->| VictoriaMetrics MCP     |
|  - vllm-embedding   |         | Aggregator (port 8000)  |
|    (remote::vllm)   |         +-------------------------+
|  - inline::builtin  |
|    (responses)      |         +-------------------------+
|  - model-context-   |--SSE--->| Incident Detection MCP  |
|    protocol         |         | (port 8085)             |
|                     |         +-------------------------+
| APIs:               |
|  - inference         |
|  - responses         |
|  - tool_runtime      |
|  - vector_io         |
|  - files             |
+---------------------+
         |
         v
+---------------------+
| PostgreSQL          |
| (KV + SQL storage)  |
+---------------------+
```

## Prerequisites

- OpenShift AI 3.4 with the LlamaStack/OGX Operator activated
  (`llamastackoperator.managementState: Managed` in your DataScienceCluster CR)
- `oc` CLI logged in to your cluster
- `envsubst` available (part of `gettext`)
- An external vLLM inference endpoint URL (ending in `/v1`) and API token
- An external vLLM embedding endpoint URL and API token

## Quick Start

```bash
# 1. Clone the repo
git clone https://github.com/ravisharma5/rhoai-llamastack.git
cd rhoai-llamastack

# 2. Configure your environment
cp .env.example .env
# Edit .env with your vLLM endpoints and API tokens

# 3. Login to your OpenShift cluster
oc login --server=https://api.your-cluster.com:6443

# 4. Deploy everything
./deploy.sh

# 5. Verify
oc get pods
OGX_URL=https://$(oc get route llama-stack-server -o jsonpath='{.spec.host}')
curl -sk $OGX_URL/v1/health
curl -sk $OGX_URL/v1/models
```

## Step-by-Step Deployment

### 1. Create namespace

```bash
oc new-project llama-stack
```

### 2. Configure and create secrets

```bash
cp .env.example .env
# Edit .env with your values:
#   VLLM_URL, VLLM_API_TOKEN
#   VLLM_EMBEDDING_URL, VLLM_EMBEDDING_API_TOKEN
#   POSTGRES_PASSWORD
source .env
envsubst < llama-stack-secret.yaml | oc apply -f -
```

### 3. Create OGX server config

The config uses OGX v0.7.x schema. Key differences from v0.4.x:

```yaml
version: 2
distro_name: rh                    # was: image_name

apis:
  - inference
  - responses                      # was: agents
  - tool_runtime
  - vector_io
  - files
  # Removed: eval, scoring, datasetio, safety

providers:
  inference:
    - provider_id: vllm-inference
      provider_type: remote::vllm
      config:
        base_url: ${env.VLLM_URL}  # must be base_url, not url
        max_tokens: 8192
        api_token: ${env.VLLM_API_TOKEN}
        network:                   # was: tls_verify (flat field)
          tls:
            verify: false

  responses:                       # was: agents
    - provider_id: builtin         # was: meta-reference
      provider_type: inline::builtin  # was: inline::meta-reference
      config:
        persistence:
          responses:
            backend: sql_default
            table_name: agents_responses

  tool_runtime:
    - provider_id: model-context-protocol
      provider_type: remote::model-context-protocol
      config: {}
```

Apply the ConfigMap:

```bash
oc create configmap llama-stack-run-config \
  --from-file=config.yaml=llamastack-config.yaml
```

> **Important:** The ConfigMap key **must** be `config.yaml`. The operator mounts it at `/etc/llama-stack/config.yaml`.

### 4. Deploy PostgreSQL

```bash
oc apply -f postgres.yaml
oc wait --for=condition=available deployment/postgres-llamastack --timeout=120s
```

### 5. Deploy OpenShift MCP Server

```bash
oc apply -f openshift-mcp-server.yaml
oc wait --for=condition=available deployment/openshift-mcp-server --timeout=120s
```

### 6. Deploy OGX Server (LlamaStackDistribution CR)

The CR tells the RHOAI operator to deploy and manage the OGX server:

```yaml
apiVersion: llamastack.rhoai.opendatahub.io/v1alpha1
kind: LlamaStackDistribution
metadata:
  name: llama-stack-server
spec:
  replicas: 1
  userConfig:                      # must be userConfig, not userConfigMapRef
    configMapName: llama-stack-run-config
  secretRef:
    name: llama-stack-secret
  network:
    allowedFrom:
      namespaces: ["*"]            # allows OpenShift router traffic
```

```bash
oc apply -f llamastackdistribution.yaml
```

### 7. Create external route

```bash
oc create route edge llama-stack-server \
  --service=llama-stack-server-service --port=8321
```

### 8. Verify deployment

```bash
# Check pods
oc get pods

# Follow logs
oc logs -l app.kubernetes.io/instance=llama-stack-server -f

# Health check
OGX_URL=https://$(oc get route llama-stack-server -o jsonpath='{.spec.host}')
curl -sk $OGX_URL/v1/health

# List models
curl -sk $OGX_URL/v1/models

# List registered toolgroups (still works in v0.7.x)
curl -sk $OGX_URL/v1/toolgroups
```

## Responses API

The `/v1/responses` API handles the full agent loop server-side: tool discovery, LLM-driven tool selection, execution, and response generation.

### Basic query

```python
from llama_stack_client import LlamaStackClient

client = LlamaStackClient(base_url="https://<ogx-route-url>")

response = client.responses.create(
    model="vllm-inference/your-model-id",
    input="List all pods in the llama-stack namespace",
    tools=[
        {
            "type": "mcp",
            "server_label": "openshift",
            "server_url": "http://openshift-mcp-server:8080/sse",
            "require_approval": "never",
        }
    ],
    stream=False,
)
```

### New parameters in v0.7.x

```python
response = client.responses.create(
    model="vllm-inference/your-model-id",
    input="Investigate high CPU usage across all namespaces",
    tools=mcp_tools,
    stream=True,
    instructions="You are an AIOps assistant...",
    # New in v0.7.x:
    parallel_tool_calls=True,       # concurrent MCP queries
    max_output_tokens=4096,         # per-request output limit
    max_tool_calls=10,              # total tool call cap
    reasoning={"effort": "medium"}, # reasoning depth control
    truncation="auto",              # was: extra_body={"truncation": "auto"}
)
```

| Parameter | Purpose | Default |
|-----------|---------|---------|
| `parallel_tool_calls` | Allow model to emit multiple tool calls per turn | `True` |
| `max_output_tokens` | Per-request output token limit | Model default |
| `max_tool_calls` | Cap total tool invocations per request | No limit |
| `reasoning` | Control reasoning depth (`none`/`minimal`/`low`/`medium`/`high`/`xhigh`) | None |
| `truncation` | Context window management strategy | None |

### Streaming events

```python
for event in response:
    if event.type == "response.output_text.delta":
        print(event.delta, end="")
    elif event.type == "response.output_item.added":
        if event.item.type == "mcp_call":
            print(f"Calling: {event.item.name}")
    elif event.type == "response.output_item.done":
        if event.item.type == "mcp_call":
            print(f"Result: {event.item.output[:200]}")
    elif event.type == "response.completed":
        print("Done")
    elif event.type == "response.failed":
        print(f"Error: {event.response.error}")
```

## MCP Server Configuration

### Registering MCP toolgroups

MCP servers are registered in the OGX config under `registered_resources.tool_groups`:

```yaml
registered_resources:
  tool_groups:
    - toolgroup_id: mcp::openshift
      provider_id: model-context-protocol
      mcp_endpoint:
        uri: http://openshift-mcp-server:8080/sse

    - toolgroup_id: mcp::victoriametrics
      provider_id: model-context-protocol
      mcp_endpoint:
        uri: http://victoriametrics-mcp-aggregator:8000/sse
```

### Safety modes

| Mode | Flag | What it allows |
|------|------|----------------|
| Read-only | `--read-only` | List, get, describe only |
| Non-destructive | `--disable-destructive` | Read + create (no delete/update) |
| Full access | (no flag) | All operations |

## Authentication (OAuth2/Keycloak)

OGX supports OAuth2 token authentication via Keycloak:

```yaml
server:
  port: 8321
  auth:
    provider_config:
      type: "oauth2_token"
      jwks:
        uri: "http://keycloak-service.rhbk.svc:8080/realms/aiops/protocol/openid-connect/certs"
      issuer: "https://keycloak-route/realms/aiops"
      audience: "account"
```

Client usage with auth:

```python
client = LlamaStackClient(
    base_url="https://<ogx-route-url>",
    api_key="<jwt-token>",
)
```

## Migration from RHOAI 3.3

### Breaking changes (v0.4.x → v0.7.x)

| Area | Old (v0.4.x) | New (v0.7.x) |
|------|-------------|-------------|
| Config field | `image_name: rh` | `distro_name: rh` |
| Agents provider | `inline::meta-reference` | `inline::builtin` |
| Agents API | `agents` in apis list | `responses` in apis list |
| TLS config | `tls_verify: false` | `network: { tls: { verify: false }}` |
| RAG toolgroup | `builtin::rag` | `builtin::file_search` |
| SDK version | `llama-stack-client>=0.4.0,<0.5` | `llama-stack-client>=0.7.0,<0.8` |
| Removed APIs | — | `eval`, `scoring`, `datasetio`, `safety` |
| Removed section | — | `registered_resources.tool_groups` auto-registers |

### SDK changes

```python
# Import path is UNCHANGED
from llama_stack_client import LlamaStackClient

# New parameters available on responses.create():
# parallel_tool_calls, max_output_tokens, max_tool_calls, reasoning, truncation

# max_infer_iters replaced by max_tool_calls
# extra_body={"truncation": "auto"} replaced by truncation="auto"
```

## Adding a Remote OpenShift Cluster

See the remote cluster setup guide in the previous version of this README. The process is unchanged — deploy a second MCP server pod with a kubeconfig pointing to the remote cluster, register it as `mcp::openshift-remote` in the OGX config.

## Updating Configuration

```bash
oc create configmap llama-stack-run-config \
  --from-file=config.yaml=llamastack-config.yaml \
  --dry-run=client -o yaml | oc apply -f -

# Restart to pick up changes
oc rollout restart deployment/llama-stack-server
```

## Teardown

```bash
./teardown.sh
# Or manually:
oc delete llamastackdistribution llama-stack-server
oc delete route llama-stack-server
oc delete configmap llama-stack-run-config
oc delete -f openshift-mcp-server.yaml
oc delete -f postgres.yaml
envsubst < llama-stack-secret.yaml | oc delete -f -
```

## Troubleshooting

**OGX pod in CrashLoopBackOff:**
- Check logs: `oc logs -l app.kubernetes.io/instance=llama-stack-server`
- Verify ConfigMap key is `config.yaml` (not `run.yaml`)
- Verify `base_url` (not `url`) in vLLM provider config
- Verify `distro_name` (not `image_name`)
- Verify `inline::builtin` (not `inline::meta-reference`)

**Route returns 503:**
- Check NetworkPolicy: `oc get networkpolicy -o yaml`
- Ensure `network.allowedFrom.namespaces: ["*"]` in the CR

**MCP tools not appearing:**
- Verify toolgroup entries in config under `registered_resources.tool_groups`
- Verify `model-context-protocol` provider under `providers.tool_runtime`
- Check OGX logs for MCP connection errors

**Auth errors (401/403):**
- Verify Keycloak JWKS URI is reachable from OGX pod
- Verify `issuer` matches the external Keycloak route URL (JWT `iss` claim uses the external URL)
- Check token expiry: `python3 -c "import jwt; print(jwt.decode(token, options={'verify_signature':False}))"`

**Silent accuracy regression after upgrade:**
- Upgrade OGX and vLLM atomically — Red Hat benchmarks show accuracy drops when only one is upgraded
- Run test queries before and after to verify quality
