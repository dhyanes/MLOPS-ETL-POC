#!/usr/bin/env bash
set -euo pipefail

ARGO_NS="argo"
ARGO_CHART_VERSION="0.42.3"  # argo-workflows helm chart version

echo "Creating namespaces..."
kubectl create namespace "$ARGO_NS" --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace mlops --dry-run=client -o yaml | kubectl apply -f -

echo "Adding argo helm repo..."
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

echo "Installing Argo Workflows..."
helm upgrade --install argo-workflows argo/argo-workflows \
  --namespace "$ARGO_NS" \
  --version "$ARGO_CHART_VERSION" \
  --set server.serviceType=NodePort \
  --set server.extraArgs[0]="--auth-mode=server" \
  --set controller.workflowNamespaces[0]="$ARGO_NS" \
  --set controller.workflowNamespaces[1]="mlops" \
  --wait --timeout 5m

echo "Argo Workflows server NodePort:"
kubectl -n "$ARGO_NS" get svc argo-workflows-server -o jsonpath='{.spec.ports[0].nodePort}'
echo
echo "Done. The Airflow DAG talks to the Workflow CRDs directly (no need to hit this UI),"
echo "but it's handy for watching runs: http://<any-node-public-ip>:<nodeport>"
