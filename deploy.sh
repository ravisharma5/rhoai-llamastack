#!/usr/bin/env bash
set -euo pipefail

# Load .env if present
if [[ -f .env ]]; then
  echo "Loading .env file..."
  set -a; source .env; set +a
fi

NAMESPACE="${NAMESPACE:-llama-stack}"

# Validate required variables
REQUIRED_VARS=(
  INFERENCE_MODEL VLLM_URL VLLM_API_TOKEN
  EMBEDDING_MODEL EMBEDDING_PROVIDER_MODEL_ID VLLM_EMBEDDING_URL VLLM_EMBEDDING_API_TOKEN
  VLOGS_URL VLOGS_TOKEN VCPC_URL VCPC_TOKEN VCPC_TENANT
)
for var in "${REQUIRED_VARS[@]}"; do
  if [[ -z "${!var:-}" ]]; then
    echo "ERROR: $var is not set. Copy .env.example to .env and fill in your values."
    exit 1
  fi
done

echo "==> Creating namespace ${NAMESPACE}"
oc new-project "${NAMESPACE}" 2>/dev/null || oc project "${NAMESPACE}"

echo "==> Creating inference secret"
envsubst < llama-stack-secret.yaml | oc apply -f -

echo "==> Creating LlamaStack run config"
oc create configmap llama-stack-run-config \
  --from-file=config.yaml=llamastack-config.yaml \
  --dry-run=client -o yaml | oc apply -f -

echo "==> Deploying PostgreSQL"
oc apply -f postgres.yaml
oc wait --for=condition=available deployment/postgres-llamastack --timeout=120s

echo "==> Deploying OpenShift MCP Server"
# Update namespace in ClusterRoleBinding
sed "s/namespace: llama-stack/namespace: ${NAMESPACE}/g" openshift-mcp-server.yaml | oc apply -f -
oc wait --for=condition=available deployment/openshift-mcp-server --timeout=120s

echo "==> Deploying LlamaStack Distribution"
oc apply -f llamastackdistribution.yaml

echo "==> Creating route for external access"
oc create route edge llama-stack-server \
  --service=llama-stack-server-service --port=8321 2>/dev/null || true

echo ""
echo "Deployment complete. Verify with:"
echo "  oc get pods"
echo "  oc get routes"
ROUTE=$(oc get route llama-stack-server -o jsonpath='{.spec.host}' 2>/dev/null || echo "<pending>")
echo "  curl -sk https://${ROUTE}/v1/health"
