# Build with:
#   docker build -t <your-registry>/mlops-training:latest -f pipelines/Dockerfile .
#   docker push <your-registry>/mlops-training:latest
#
# Bakes the pipeline code + DVC config into the image so the only thing
# that changes between runs is which git commit/tag you build from.
FROM python:3.11-slim

WORKDIR /app

COPY pipelines/requirements.txt ./pipelines/requirements.txt
RUN pip install --no-cache-dir -r pipelines/requirements.txt

COPY pipelines/ ./pipelines/
COPY dvc.yaml params.yaml ./
COPY .dvc/ ./.dvc/

# AWS creds come from the pod's node IAM instance role at runtime — nothing
# baked in here, nothing to rotate.
ENTRYPOINT ["dvc"]
CMD ["repro"]
