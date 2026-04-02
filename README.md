# LlamaStack on RHOAI 3.3

Deploy a LlamaStack server with MCP server integration on OpenShift AI 3.3 using the LlamaStackDistribution custom resource.

## Architecture

```
External vLLM Endpoints
  (Inference + Embedding)
         |
         v
+---------------------+         +-------------------------+
| LlamaStack Server   |--SSE--->| OpenShift MCP Server    |
| (rh-dev, port 8321) |         | (port 8080)             |
|                     |         |                         |
| Providers:          |         | Tools:                  |
|  - vllm-inference   |         |   pods_list/get/log     |
|  - vllm-embedding   |         |   resources_get/create  |
|  - milvus (inline)  |         |   events_list           |
|  - rag-runtime      |         |   namespaces_list       |
|  - model-context-   |         |   helm_install/list/rm  |
|    protocol         |         +-------------------------+
|                     |                  |
| Tool Groups:        |             in-cluster SA
|  - builtin::rag     |                  |
|  - builtin::websearch                  v
|  - mcp::openshift   |         OpenShift API Server
+---------------------+
         |
         v
+---------------------+
| PostgreSQL          |
| (KV + SQL storage)  |
+---------------------+
```

## Prerequisites

- OpenShift AI 3.3 with the LlamaStack Operator activated
  (`llamastackoperator.managementState: Managed` in your DataScienceCluster CR)
- `oc` CLI logged in to your cluster
- `envsubst` available (part of `gettext` -- pre-installed on most systems)
- An external vLLM inference endpoint URL (ending in `/v1`) and API token
- An external vLLM embedding endpoint URL and API token

## Files

| File | Description |
|------|-------------|
| `llama-stack-secret.yaml` | Secret template (parameterized -- values come from `.env`) |
| `postgres.yaml` | PostgreSQL deployment (Secret + PVC + Deployment + Service) |
| `openshift-mcp-server.yaml` | MCP server (Deployment + Service + Route + ServiceAccount + RBAC) |
| `llamastackdistribution.yaml` | LlamaStackDistribution CR (the main LlamaStack server) |
| `llamastack-config.yaml` | LlamaStack config with providers, models, and tool groups |
| `mcp-playground-configmap.yaml` | (Optional) Register MCP server in RHOAI Gen AI Playground |
| `deploy.sh` | One-command deployment script |
| `teardown.sh` | Clean teardown script |
| `.env.example` | Template for required environment variables |

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
LLAMA_URL=https://$(oc get route llama-stack-server -o jsonpath='{.spec.host}')
curl -sk $LLAMA_URL/v1/health
```

## Manual Deployment

If you prefer step-by-step control over the deployment:

### 1. Create namespace

```bash
oc new-project llama-stack
```

### 2. Configure and create secrets

```bash
cp .env.example .env
# Edit .env with your values, then:
source .env
envsubst < llama-stack-secret.yaml | oc apply -f -
```

### 3. Create LlamaStack config

```bash
oc create configmap llama-stack-run-config \
  --from-file=config.yaml=llamastack-config.yaml
```

### 4. Deploy components

```bash
# PostgreSQL
oc apply -f postgres.yaml
oc wait --for=condition=available deployment/postgres-llamastack --timeout=120s

# OpenShift MCP Server
oc apply -f openshift-mcp-server.yaml
oc wait --for=condition=available deployment/openshift-mcp-server --timeout=120s

# LlamaStack
oc apply -f llamastackdistribution.yaml

# Create a route for external access
oc create route edge llama-stack-server \
  --service=llama-stack-server-service --port=8321
```

### 5. Verify

```bash
oc get pods
oc logs -l app.kubernetes.io/instance=llama-stack-server -f

LLAMA_URL=https://$(oc get route llama-stack-server -o jsonpath='{.spec.host}')
curl -sk $LLAMA_URL/v1/health
curl -sk $LLAMA_URL/v1/models
curl -sk $LLAMA_URL/v1/toolgroups
```

## Using MCP Tools

### Responses API (recommended)

The `/v1/responses` API runs a full agent loop server-side: tool discovery, LLM-driven tool selection, tool execution via MCP, and final response generation.

```python
import requests

LLAMA_STACK_URL = "https://<llama-stack-route-url>"
MCP_SERVER_URL = "http://openshift-mcp-server:8080/sse"

response = requests.post(
    f"{LLAMA_STACK_URL}/v1/responses",
    json={
        "model": "your-inference-model",
        "input": "List all pods in the llama-stack namespace",
        "tools": [
            {
                "type": "mcp",
                "server_label": "openshift",
                "server_url": MCP_SERVER_URL,
                "require_approval": "never",
            }
        ],
        "stream": False,
    },
    verify=False,
    timeout=120,
).json()

for item in response["output"]:
    if item["type"] == "mcp_call":
        print(f"Tool: {item['name']}({item.get('arguments', '{}')})")
    elif item["type"] == "mcp_call_output":
        print(f"Output: {item['output'][:500]}")
    elif item["type"] == "message":
        content = item.get("content", "")
        if isinstance(content, list):
            for c in content:
                if c.get("type") == "output_text":
                    print(f"Assistant: {c['text']}")
```

### Direct tool invocation

```bash
curl -sk -X POST $LLAMA_URL/v1/tool-runtime/invoke \
  -H "Content-Type: application/json" \
  -d '{
    "tool_name": "pods_list_in_namespace",
    "kwargs": {"namespace": "llama-stack"},
    "tool_group_id": "mcp::openshift"
  }'
```

## Important Notes

### ConfigMap key must be `config.yaml`

The operator mounts the ConfigMap at `/etc/llama-stack/` and sets
`LLAMA_STACK_CONFIG=/etc/llama-stack/config.yaml`. The key **must** be `config.yaml`:

```bash
# Correct
oc create configmap llama-stack-run-config --from-file=config.yaml=llamastack-config.yaml

# Wrong -- causes "Could not resolve config" error
oc create configmap llama-stack-run-config --from-file=run.yaml=llamastack-config.yaml
```

### Use `base_url` not `url` in vLLM provider config

The RHOAI 0.4.x vLLM provider uses `base_url`. Using `url` is silently ignored:

```yaml
# Correct
config:
  base_url: ${env.VLLM_URL}

# Wrong
config:
  url: ${env.VLLM_URL}
```

### Use `userConfig` not `userConfigMapRef`

```yaml
# Correct
userConfig:
  configMapName: llama-stack-run-config

# Wrong -- silently ignored
userConfigMapRef:
  name: llama-stack-run-config
```

### PostgreSQL image uses `POSTGRESQL_*` env vars

The Red Hat PostgreSQL image expects `POSTGRESQL_USER`, `POSTGRESQL_PASSWORD`,
`POSTGRESQL_DATABASE` -- not `POSTGRES_*`.

### NetworkPolicy blocks external route traffic by default

The operator creates a NetworkPolicy that restricts ingress. The CR includes
`network.allowedFrom.namespaces: ["*"]` to allow traffic from the OpenShift
router.

## MCP Server Configuration

### Safety Mode

| Mode | Flag | What it allows |
|------|------|----------------|
| Read-only | `--read-only` | List, get, describe only |
| Non-destructive | `--disable-destructive` | Read + create (no delete/update) |
| Full access | (no flag) | All operations |

### Enabled Toolsets

| Toolset | Tools | Enabled |
|---------|-------|---------|
| `core` | pods, resources, events, namespaces, projects | Yes |
| `config` | kubeconfig/context management | Yes |
| `helm` | install, list, remove Helm charts | Yes |
| `kubevirt` | VM management (OpenShift Virtualization) | No |
| `observability` | Prometheus metrics, Alertmanager | No |

## Updating Configuration

```bash
oc create configmap llama-stack-run-config \
  --from-file=config.yaml=llamastack-config.yaml \
  --dry-run=client -o yaml | oc apply -f -
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

**LlamaStack pod in CrashLoopBackOff:**
- Check logs: `oc logs -l app.kubernetes.io/instance=llama-stack-server`
- Verify ConfigMap key is `config.yaml`
- Verify `base_url` (not `url`) in vLLM provider config

**Route returns 503:**
- Check NetworkPolicy: `oc get networkpolicy -o yaml`
- Ensure `network.allowedFrom.namespaces: ["*"]` is set in the CR

**MCP tools not appearing:**
- Verify `mcp::openshift` is in `llamastack-config.yaml` under `tool_groups`
- Verify `model-context-protocol` provider is under `providers.tool_runtime`
- Check LlamaStack logs for MCP connection errors
