#!/usr/bin/env bash
# Run this once, from the root of your project repo.
set -euo pipefail

if [ -z "${1:-}" ]; then
  echo "Usage: $0 <s3-bucket-name> [s3-prefix]"
  echo "Example: $0 my-mlops-bucket dvc-store"
  exit 1
fi

BUCKET="$1"
PREFIX="${2:-dvc-store}"

pip install --break-system-packages "dvc[s3]"

dvc init
dvc remote add -d s3remote "s3://$BUCKET/$PREFIX"

# Credentials: on the cluster, prefer an IAM role attached to the node/pod
# instead of static keys. For local use, `aws configure` is enough — DVC's
# S3 remote uses the standard AWS credential chain (env vars, ~/.aws/credentials,
# instance profile, IRSA, etc.) automatically, no extra config needed.

git add .dvc .dvcignore dvc.yaml params.yaml 2>/dev/null || true
echo
echo "DVC initialized with remote s3://$BUCKET/$PREFIX"
echo "Next: dvc repro   (runs the pipeline defined in dvc.yaml)"
echo "Then: dvc push    (uploads data/model artifacts to S3)"
