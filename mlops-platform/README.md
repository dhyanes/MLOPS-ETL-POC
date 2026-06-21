# MLOps platform: DVC + Airflow + Argo Workflows + KServe on self-managed Kubernetes (AWS)

A proof-of-concept MLOps platform built on a kubeadm cluster you provision
on plain EC2 instances (no EKS control plane). The flow:

```
Git repo (code + dvc.yaml)
        |
        v
   Airflow DAG  ──triggers──>  Argo Workflow ──dvc repro──> trains model
        |                              │
        │                              └──push──> S3 bucket (DVC remote)
        │
        └──deploy (patch storageUri)──> KServe InferenceService ──pulls model── S3
```

Airflow owns orchestration and scheduling. Argo Workflows owns the actual
training run (so training pods come and go independently of Airflow's own
infra). DVC owns data/model versioning, backed by S3. KServe owns serving.

This is scoped as a **PoC / learning setup**, not a hardened production
deployment — see "Hardening for production" at the bottom for what's
deliberately cut.

## Prerequisites

- An AWS account with permissions to create VPCs, EC2 instances, IAM roles
- Terraform >= 1.5
- An existing EC2 key pair (`aws ec2 create-key-pair --key-name mlops-key`)
- `kubectl`, `helm`, `dvc`, `docker`, AWS CLI installed locally
- A container registry you can push to (Docker Hub, ECR, GHCR, etc.)
- An S3 bucket already created (for the kubeconfig handoff and/or DVC)

## 1. Provision the cluster

```bash
cd infra/terraform
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars: key_name, allowed_ssh_cidr, kubeconfig_bucket, dvc_bucket

terraform init
terraform apply
```

This creates a VPC, security group, IAM role (scoped to SSM + your S3
buckets), 1 master + N worker EC2 instances. Each instance bootstraps
itself via `user_data`: installs containerd/kubeadm/kubelet, the master
runs `kubeadm init` + installs Calico, workers fetch the join command from
SSM Parameter Store and join automatically. No manual SSH steps required.

Bootstrapping takes ~3-5 minutes after `apply` finishes. Watch progress:

```bash
ssh ubuntu@$(terraform output -raw master_public_ip) \
  'tail -f /var/log/mlops-bootstrap.log'
```

Once `/var/log/mlops-bootstrap.done` exists on the master, pull your
kubeconfig:

```bash
terraform output -raw fetch_kubeconfig | bash
export KUBECONFIG=$(pwd)/kubeconfig.yaml
kubectl get nodes   # should show master + workers, all Ready within ~1 min
```

## 2. Install the platform components

Run from the repo root, with `KUBECONFIG` still exported:

```bash
bash platform/01-install-cert-manager.sh
bash platform/02-install-argo-workflows.sh
bash platform/03-install-airflow.sh
bash platform/04-install-kserve.sh
```

KServe is installed in **RawDeployment** mode — plain Deployments/Services
instead of Knative + Istio. That's the right tradeoff for a PoC: you lose
scale-to-zero and request-based autoscaling, but you skip standing up a
service mesh just to serve one model. Switch to Serverless mode later if
you need it.

## 3. Set up DVC and build the training image

```bash
# from the repo root
bash dvc/setup.sh <your-dvc-bucket> dvc-store
dvc repro          # sanity-check the pipeline runs locally first
dvc push

docker build -t <your-registry>/mlops-training:latest -f pipelines/Dockerfile .
docker push <your-registry>/mlops-training:latest
```

Then edit the placeholder values in two places:
- `workflows/training-workflow-template.yaml` — `image`, `dvc-bucket` defaults
- `airflow_dags/mlops_training_pipeline.py` — `TRAINING_IMAGE`, `DVC_BUCKET`
- `kserve/inferenceservice.yaml` — `storageUri` bucket name (only needed if
  you apply it manually; the DAG creates/patches it itself on first run)

## 4. Register the Argo WorkflowTemplate

```bash
kubectl apply -f workflows/training-workflow-template.yaml
```

## 5. Deploy the DAG

The Airflow Helm values are configured for `gitSync` — point
`platform/airflow/values.yaml`'s `dags.gitSync.repo` at wherever you push
this repo, and Airflow will pick up `airflow_dags/mlops_training_pipeline.py`
automatically. (For a quick local test without git-sync, you can
`kubectl cp` the DAG file into the scheduler pod's DAGs folder instead.)

Open the Airflow UI (NodePort printed by step 2's install script),
unpause `mlops_training_pipeline`, and trigger it manually.

## 6. Watch it run

```bash
# Argo
kubectl -n mlops get workflows -w

# KServe, once the DAG's deploy step has run
kubectl -n mlops get inferenceservice mlops-model
```

Test the endpoint (RawDeployment exposes a plain ClusterIP service — port-forward for a quick check):

```bash
kubectl -n mlops port-forward svc/mlops-model-predictor 8080:80
curl -X POST localhost:8080/v1/models/mlops-model:predict \
  -H "Content-Type: application/json" \
  -d '{"instances": [[14.1, 20.0, 90.0, 600.0, 0.1, 0.1, 0.05, 0.03, 0.18, 0.06, 0.4, 1.2, 2.5, 40.0, 0.006, 0.02, 0.02, 0.01, 0.02, 0.003, 16.0, 25.0, 105.0, 800.0, 0.14, 0.25, 0.27, 0.11, 0.29, 0.08]]}'
```

(The 30 feature values above match the breast-cancer toy dataset used in
`pipelines/prepare.py` — swap in your real schema once you replace it.)

## What's in this repo

| Path | Purpose |
|---|---|
| `infra/terraform/` | VPC, IAM, EC2 instances, kubeadm bootstrap scripts |
| `platform/` | Helm/kubectl install scripts for cert-manager, Argo Workflows, Airflow, KServe |
| `pipelines/` | The actual ML code: prepare → train → evaluate, plus the Dockerfile that packages it |
| `dvc.yaml`, `params.yaml` | DVC pipeline definition and parameters |
| `workflows/training-workflow-template.yaml` | Argo WorkflowTemplate that runs `dvc repro` on the cluster |
| `airflow_dags/mlops_training_pipeline.py` | Orchestrates: submit workflow → wait → quality gate → deploy to KServe |
| `kserve/inferenceservice.yaml` | Reference InferenceService manifest |

## Hardening for production (deliberately out of scope here)

- **HA control plane**: this is a single master. For real HA you'd run 3
  masters behind a load balancer (or just move to EKS).
- **Private subnets**: nodes are in a public subnet with public IPs for PoC
  simplicity. Move workers to a private subnet + NAT gateway.
- **TLS everywhere**: the K8s API, Airflow UI, and Argo UI are all plain
  NodePort HTTP here. Put an ingress + cert-manager-issued TLS in front.
- **Secrets**: AWS credentials flow through the node IAM instance role,
  which means every pod on a node can use it. Fine for a PoC; for
  production, isolate per-workload credentials (e.g. via
  [Pod Identity webhook](https://github.com/aws/amazon-eks-pod-identity-webhook)
  even outside EKS, or per-namespace IAM via kube2iam/kiam).
- **Quality gates**: the DAG's accuracy threshold is a placeholder — wire
  in real validation (data drift checks, held-out eval sets, shadow
  deployment) before auto-promoting models.
- **Observability**: no Prometheus/Grafana here. You'll want metrics on
  training duration, model accuracy over time, and inference latency/error
  rates before running this for real.
