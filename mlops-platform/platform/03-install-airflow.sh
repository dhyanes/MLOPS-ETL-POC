#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AIRFLOW_CHART_VERSION="1.13.1"

kubectl create namespace airflow --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace mlops --dry-run=client -o yaml | kubectl apply -f -

echo "Adding apache-airflow helm repo..."
helm repo add apache-airflow https://airflow.apache.org
helm repo update

echo "Installing Airflow (KubernetesExecutor)..."
helm upgrade --install airflow apache-airflow/airflow \
  --namespace airflow \
  --version "$AIRFLOW_CHART_VERSION" \
  -f "$SCRIPT_DIR/values.yaml" \
  --wait --timeout 10m

echo
echo "Airflow webserver NodePort:"
kubectl -n airflow get svc airflow-webserver -o jsonpath='{.spec.ports[0].nodePort}'
echo
echo "Default login is admin/admin unless you changed it in values.yaml — change it before exposing this beyond a PoC."
echo "Visit: http://<any-node-public-ip>:<nodeport>"
