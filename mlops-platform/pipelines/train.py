"""Train stage: fit a RandomForestClassifier and save it with joblib.

KServe's sklearn runtime loads joblib/pickle model files directly from the
storageUri you point it at, so this is the exact artifact format it expects.
"""
from pathlib import Path

import joblib
import pandas as pd
import yaml
from sklearn.ensemble import RandomForestClassifier

params = yaml.safe_load(Path("params.yaml").read_text())["train"]

train_df = pd.read_csv("data/train.csv")
X_train = train_df.drop(columns=["target"])
y_train = train_df["target"]

model = RandomForestClassifier(
    n_estimators=params["n_estimators"],
    max_depth=params["max_depth"],
    random_state=params["random_state"],
)
model.fit(X_train, y_train)

Path("model").mkdir(exist_ok=True)
joblib.dump(model, "model/model.joblib")

print("Model trained and saved to model/model.joblib")
