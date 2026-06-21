"""Evaluate stage: score the held-out test set and write metrics/eval.json.

`dvc metrics show` / `dvc metrics diff` read this file, so any run can be
compared against the last one DVC tracked.
"""
import json
from pathlib import Path

import joblib
import pandas as pd
from sklearn.metrics import accuracy_score, f1_score, precision_score, recall_score

model = joblib.load("model/model.joblib")
test_df = pd.read_csv("data/test.csv")
X_test = test_df.drop(columns=["target"])
y_test = test_df["target"]

preds = model.predict(X_test)

metrics = {
    "accuracy": round(accuracy_score(y_test, preds), 4),
    "precision": round(precision_score(y_test, preds), 4),
    "recall": round(recall_score(y_test, preds), 4),
    "f1": round(f1_score(y_test, preds), 4),
}

Path("metrics").mkdir(exist_ok=True)
Path("metrics/eval.json").write_text(json.dumps(metrics, indent=2))

print(json.dumps(metrics, indent=2))
