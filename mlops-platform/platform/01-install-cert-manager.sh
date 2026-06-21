#!/usr/bin/env bash
# Run with KUBECONFIG pointed at the cluster (export KUBECONFIG=./kubeconfig.yaml)
set -euo pipefail

CERT_MANAGER_VERSION="v1.14.5"

echo "Installing cert-manager ${CERT_MANAGER_VERSION}..."
kubectl apply -f "https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml"

echo "Waiting for cert-manager to be ready..."
kubectl wait --for=condition=Available --timeout=180s -n cert-manager deployment/cert-manager
kubectl wait --for=condition=Available --timeout=180s -n cert-manager deployment/cert-manager-webhook
kubectl wait --for=condition=Available --timeout=180s -n cert-manager deployment/cert-manager-cainjector

echo "cert-manager is ready."
