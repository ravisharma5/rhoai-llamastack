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
| (rh-dev, port 8321) |         | (local, port 8080)      |
|                     |         |   --cluster-provider     |
| Providers:          |         |     in-cluster           |
|  - vllm-inference   |         +-------------------------+
|  - vllm-embedding   |                  |
|  - milvus (inline)  |             in-cluster SA
|  - rag-runtime      |                  |
|  - model-context-   |                  v
|    protocol         |         Local OpenShift API Server
|                     |
| Tool Groups:        |         +-------------------------+
|  - builtin::rag     |--SSE--->| OpenShift MCP Server    |
|  - builtin::websearch         | (remote, port 8080)     |
|  - mcp::openshift   |         |   --kubeconfig          |
|  - mcp::openshift-  |         |     /etc/mcp/kubeconfig  |
|    remote (optional) |         +-------------------------+
+---------------------+                  |
         |                          kubeconfig +
         v                          SA token
+---------------------+                  |
| PostgreSQL          |                  v
| (KV + SQL storage)  |         Remote OpenShift API Server
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
| `openshift-mcp-server.yaml` | MCP server for local cluster (Deployment + Service + Route + SA + RBAC) |
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

The `/v1/responses` API handles the full agent loop server-side -- it discovers available tools, lets the LLM pick which ones to call, executes them via MCP, and returns the final response.

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

## Adding a Remote OpenShift Cluster

The default `openshift-mcp-server` uses an in-cluster ServiceAccount to talk to the local cluster. To reach a different OpenShift cluster, deploy a second MCP server pod with a kubeconfig that points at it.

### 1. Create a ServiceAccount on the remote cluster

Log in to the remote cluster and create a read-only ServiceAccount:

```bash
# Log in to the remote cluster
oc login https://api.remote-cluster.example.com:6443

# Create namespace and ServiceAccount
oc new-project mcp
oc create sa mcp-viewer -n mcp

# Grant cluster-wide read access
oc adm policy add-cluster-role-to-user cluster-reader \
  system:serviceaccount:mcp:mcp-viewer
```

### 2. Generate a token and build a kubeconfig

```bash
# Generate a time-bound token (adjust duration as needed)
TOKEN="$(oc -n mcp create token mcp-viewer --duration=8h)"
API_SERVER="$(oc whoami --show-server)"

# Build a dedicated kubeconfig file
oc login --server="$API_SERVER" --token="$TOKEN" \
  --kubeconfig="$HOME/.kube/mcp-remote.kubeconfig"

# Verify
oc --kubeconfig="$HOME/.kube/mcp-remote.kubeconfig" get nodes
```

> **Note:** ServiceAccount tokens expire after the specified duration. You will
> need to regenerate the token and update the Secret when it expires. Use longer
> durations for development (`--duration=168h` for 7 days).

### 3. Create a Secret with the kubeconfig on the LlamaStack cluster

Switch back to the LlamaStack cluster and store the kubeconfig as a Secret:

```bash
# Log in to the LlamaStack cluster
oc login https://api.llamastack-cluster.example.com:6443
oc project llama-stack

# Create the Secret from the kubeconfig file
oc create secret generic remote-cluster-kubeconfig \
  --from-file=kubeconfig=$HOME/.kube/mcp-remote.kubeconfig
```

### 4. Deploy the remote MCP server

Create `openshift-mcp-server-remote.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: openshift-mcp-server-remote
  labels:
    app: openshift-mcp-server-remote
    app.kubernetes.io/component: mcp-server
spec:
  replicas: 1
  selector:
    matchLabels:
      app: openshift-mcp-server-remote
  template:
    metadata:
      labels:
        app: openshift-mcp-server-remote
        app.kubernetes.io/component: mcp-server
    spec:
      securityContext:
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: mcp-server
          image: quay.io/containers/kubernetes_mcp_server:latest
          args:
            - "--port"
            - "8080"
            - "--disable-destructive"
            - "--toolsets"
            - "core,config,helm"
            - "--kubeconfig"
            - "/etc/mcp/kubeconfig"
            - "--disable-multi-cluster"
          ports:
            - name: http
              containerPort: 8080
          volumeMounts:
            - name: kubeconfig
              mountPath: /etc/mcp
              readOnly: true
          securityContext:
            allowPrivilegeEscalation: false
            runAsNonRoot: true
            capabilities:
              drop:
                - ALL
          livenessProbe:
            httpGet:
              path: /healthz
              port: http
            initialDelaySeconds: 10
            periodSeconds: 20
          readinessProbe:
            httpGet:
              path: /healthz
              port: http
            initialDelaySeconds: 3
            periodSeconds: 10
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 100m
              memory: 128Mi
      volumes:
        - name: kubeconfig
          secret:
            secretName: remote-cluster-kubeconfig
---
apiVersion: v1
kind: Service
metadata:
  name: openshift-mcp-server-remote
  labels:
    app: openshift-mcp-server-remote
spec:
  selector:
    app: openshift-mcp-server-remote
  ports:
    - name: http
      port: 8080
      targetPort: http
  type: ClusterIP
```

Deploy it:

```bash
oc apply -f openshift-mcp-server-remote.yaml
oc wait --for=condition=available deployment/openshift-mcp-server-remote --timeout=120s
```

### 5. Register the toolgroup in LlamaStack config

Add the new toolgroup to `llamastack-config.yaml` under `tool_groups`:

```yaml
tool_groups:
  # ... existing toolgroups ...
  - toolgroup_id: mcp::openshift-remote
    provider_id: model-context-protocol
    mcp_endpoint:
      uri: http://openshift-mcp-server-remote:8080/sse
```

Update the ConfigMap:

```bash
oc create configmap llama-stack-run-config \
  --from-file=config.yaml=llamastack-config.yaml \
  --dry-run=client -o yaml | oc apply -f -
```

Restart LlamaStack to pick up the new toolgroup:

```bash
oc rollout restart deployment/llama-stack-server
```

### 6. Query the remote cluster

Use the Responses API with the `openshift-remote` server label:

```python
response = requests.post(
    f"{LLAMA_STACK_URL}/v1/responses",
    json={
        "model": "your-inference-model",
        "input": "List all pods in the default namespace",
        "tools": [
            {
                "type": "mcp",
                "server_label": "openshift-remote",
                "server_url": "http://openshift-mcp-server-remote:8080/sse",
                "require_approval": "never",
            }
        ],
        "stream": False,
    },
    verify=False,
    timeout=120,
).json()
```

The `server_label` controls which cluster gets the request: `"openshift"` hits the local cluster, `"openshift-remote"` hits the remote one. To add more clusters, repeat steps 1-5 with different names.

### Token renewal

When the SA token expires, regenerate it and update the Secret:

```bash
# On the remote cluster
oc login https://api.remote-cluster.example.com:6443
TOKEN="$(oc -n mcp create token mcp-viewer --duration=8h)"
API_SERVER="$(oc whoami --show-server)"
oc login --server="$API_SERVER" --token="$TOKEN" \
  --kubeconfig="$HOME/.kube/mcp-remote.kubeconfig"

# On the LlamaStack cluster
oc login https://api.llamastack-cluster.example.com:6443
oc project llama-stack
oc create secret generic remote-cluster-kubeconfig \
  --from-file=kubeconfig=$HOME/.kube/mcp-remote.kubeconfig \
  --dry-run=client -o yaml | oc apply -f -

# Restart the MCP server to pick up the new token
oc rollout restart deployment/openshift-mcp-server-remote
```

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
