#!/usr/bin/env bash
set -euo pipefail

KSERVE_VERSION="v0.13.1"

echo "Installing KServe CRDs + controller ($KSERVE_VERSION)..."
kubectl apply -f "https://github.com/kserve/kserve/releases/download/$KSERVE_VERSION/kserve.yaml"

echo "Waiting for the KServe controller to be ready..."
kubectl wait --for=condition=Available --timeout=180s -n kserve deployment/kserve-controller-manager

echo "Switching default deployment mode to RawDeployment (skips Istio/Knative — fine for a PoC, no need for a service mesh)..."
kubectl patch configmap/inferenceservice-config -n kserve --type=strategic -p \
  '{"data": {"deploy": "{\"defaultDeploymentMode\": \"RawDeployment\"}"}}'

# Restart the controller so it picks up the configmap change
kubectl rollout restart deployment/kserve-controller-manager -n kserve
kubectl rollout status deployment/kserve-controller-manager -n kserve --timeout=120s

echo "KServe is ready (RawDeployment mode)."
echo "Note: RawDeployment exposes InferenceServices as plain ClusterIP services + an optional Ingress —"
echo "no Istio sidecar, no Knative autoscaling-to-zero. Good tradeoff for a PoC; revisit for production."
