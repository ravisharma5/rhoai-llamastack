#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-llama-stack}"

echo "==> Tearing down LlamaStack deployment in ${NAMESPACE}"

oc delete llamastackdistribution llama-stack-server --ignore-not-found
oc delete route llama-stack-server --ignore-not-found
oc delete configmap llama-stack-run-config --ignore-not-found
oc delete -f openshift-mcp-server.yaml --ignore-not-found
oc delete -f postgres.yaml --ignore-not-found
oc delete -f llama-stack-secret.yaml --ignore-not-found

echo "Done. Namespace ${NAMESPACE} still exists -- delete manually if needed:"
echo "  oc delete project ${NAMESPACE}"
