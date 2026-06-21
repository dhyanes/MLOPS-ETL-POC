"""
End-to-end MLOps DAG:
  1. Submit an Argo Workflow (from the `mlops-training` WorkflowTemplate)
     that runs `dvc repro` — prepare -> train -> evaluate — and uploads the
     model to a versioned S3 path.
  2. Poll the Workflow until it succeeds or fails.
  3. Read back its output parameters (metrics, model-uri).
  4. Patch the KServe InferenceService to point at the new model, which
     rolls a new revision.

Talks to Argo and KServe purely as Kubernetes custom resources via the
in-cluster service account — no Argo CLI, no extra network hop. This
service account needs the RBAC granted in platform/airflow/values.yaml.
"""
from __future__ import annotations

import json
import time
from datetime import datetime, timezone

from airflow import DAG
from airflow.operators.python import PythonOperator
from airflow.exceptions import AirflowException
from kubernetes import client, config

NAMESPACE = "mlops"
WORKFLOW_TEMPLATE = "mlops-training"
INFERENCE_SERVICE_NAME = "mlops-model"

TRAINING_IMAGE = "your-registry/mlops-training:latest"   # set to your built image
DVC_BUCKET = "your-mlops-bucket"                          # same bucket DVC pushes to

ARGO_GROUP, ARGO_VERSION, ARGO_WORKFLOWS_PLURAL = "argoproj.io", "v1alpha1", "workflows"
KSERVE_GROUP, KSERVE_VERSION, KSERVE_PLURAL = "serving.kserve.io", "v1beta1", "inferenceservices"

POLL_INTERVAL_SECONDS = 15
MAX_WAIT_SECONDS = 30 * 60


def _k8s_custom_api() -> client.CustomObjectsApi:
    try:
        config.load_incluster_config()  # when running as an Airflow worker pod
    except config.ConfigException:
        config.load_kube_config()       # when testing the DAG locally
    return client.CustomObjectsApi()


def submit_training_workflow(**context) -> str:
    api = _k8s_custom_api()
    run_id = context["run_id"].replace("+", "-").replace(":", "-").lower()
    workflow_name = f"mlops-training-{run_id}"[:63]

    workflow_body = {
        "apiVersion": f"{ARGO_GROUP}/{ARGO_VERSION}",
        "kind": "Workflow",
        "metadata": {"name": workflow_name, "namespace": NAMESPACE},
        "spec": {
            "workflowTemplateRef": {"name": WORKFLOW_TEMPLATE},
            "arguments": {
                "parameters": [
                    {"name": "image", "value": TRAINING_IMAGE},
                    {"name": "dvc-bucket", "value": DVC_BUCKET},
                    {"name": "run-id", "value": run_id},
                ]
            },
        },
    }

    api.create_namespaced_custom_object(
        group=ARGO_GROUP, version=ARGO_VERSION, namespace=NAMESPACE,
        plural=ARGO_WORKFLOWS_PLURAL, body=workflow_body,
    )
    context["ti"].xcom_push(key="workflow_name", value=workflow_name)
    return workflow_name


def wait_for_workflow(**context) -> None:
    api = _k8s_custom_api()
    workflow_name = context["ti"].xcom_pull(key="workflow_name")

    deadline = time.monotonic() + MAX_WAIT_SECONDS
    while time.monotonic() < deadline:
        wf = api.get_namespaced_custom_object(
            group=ARGO_GROUP, version=ARGO_VERSION, namespace=NAMESPACE,
            plural=ARGO_WORKFLOWS_PLURAL, name=workflow_name,
        )
        phase = wf.get("status", {}).get("phase")
        if phase == "Succeeded":
            outputs = wf["status"]["nodes"][workflow_name].get("outputs", {}).get("parameters", [])
            output_map = {p["name"]: p.get("value") for p in outputs}
            context["ti"].xcom_push(key="metrics", value=output_map.get("metrics"))
            context["ti"].xcom_push(key="model_uri", value=output_map.get("model-uri"))
            return
        if phase in ("Failed", "Error"):
            raise AirflowException(f"Argo workflow {workflow_name} ended in phase {phase}")
        time.sleep(POLL_INTERVAL_SECONDS)

    raise AirflowException(f"Timed out waiting for workflow {workflow_name} after {MAX_WAIT_SECONDS}s")


def deploy_to_kserve(**context) -> None:
    api = _k8s_custom_api()
    model_uri = context["ti"].xcom_pull(key="model_uri")
    metrics_raw = context["ti"].xcom_pull(key="metrics")
    metrics = json.loads(metrics_raw) if metrics_raw else {}

    print(f"Training metrics: {json.dumps(metrics, indent=2)}")
    # Optional quality gate — don't ship a worse model.
    min_accuracy = 0.85
    if metrics.get("accuracy", 0) < min_accuracy:
        raise AirflowException(
            f"Model accuracy {metrics.get('accuracy')} below threshold {min_accuracy} — not deploying."
        )

    patch_body = {"spec": {"predictor": {"sklearn": {"storageUri": model_uri}}}}

    try:
        api.patch_namespaced_custom_object(
            group=KSERVE_GROUP, version=KSERVE_VERSION, namespace=NAMESPACE,
            plural=KSERVE_PLURAL, name=INFERENCE_SERVICE_NAME, body=patch_body,
        )
        print(f"Patched InferenceService {INFERENCE_SERVICE_NAME} -> {model_uri}")
    except client.exceptions.ApiException as e:
        if e.status != 404:
            raise
        # First-ever deploy: InferenceService doesn't exist yet, create it.
        full_body = {
            "apiVersion": f"{KSERVE_GROUP}/{KSERVE_VERSION}",
            "kind": "InferenceService",
            "metadata": {
                "name": INFERENCE_SERVICE_NAME,
                "namespace": NAMESPACE,
                "annotations": {"serving.kserve.io/deploymentMode": "RawDeployment"},
            },
            "spec": {
                "predictor": {
                    "minReplicas": 1,
                    "maxReplicas": 2,
                    "sklearn": {"storageUri": model_uri},
                }
            },
        }
        api.create_namespaced_custom_object(
            group=KSERVE_GROUP, version=KSERVE_VERSION, namespace=NAMESPACE,
            plural=KSERVE_PLURAL, body=full_body,
        )
        print(f"Created InferenceService {INFERENCE_SERVICE_NAME} -> {model_uri}")


with DAG(
    dag_id="mlops_training_pipeline",
    description="DVC pipeline (Argo) -> quality gate -> KServe deploy",
    schedule=None,  # trigger manually, or set e.g. "@daily" once you trust it
    start_date=datetime(2026, 1, 1, tzinfo=timezone.utc),
    catchup=False,
    tags=["mlops"],
) as dag:

    submit = PythonOperator(
        task_id="submit_training_workflow",
        python_callable=submit_training_workflow,
    )

    wait = PythonOperator(
        task_id="wait_for_workflow",
        python_callable=wait_for_workflow,
    )

    deploy = PythonOperator(
        task_id="deploy_to_kserve",
        python_callable=deploy_to_kserve,
    )

    submit >> wait >> deploy
