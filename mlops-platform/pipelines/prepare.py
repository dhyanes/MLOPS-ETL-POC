"""Prepare stage: load data, split into train/test, write CSVs.

Swap load_breast_cancer() out for your real data source — e.g. read from
the S3 bucket directly, or from a path DVC already pulled.
"""
from pathlib import Path

import pandas as pd
import yaml
from sklearn.datasets import load_breast_cancer
from sklearn.model_selection import train_test_split

params = yaml.safe_load(Path("params.yaml").read_text())["prepare"]

data = load_breast_cancer(as_frame=True)
df = data.frame  # features + 'target' column

train_df, test_df = train_test_split(
    df,
    test_size=params["test_size"],
    random_state=params["random_state"],
    stratify=df["target"],
)

Path("data").mkdir(exist_ok=True)
train_df.to_csv("data/train.csv", index=False)
test_df.to_csv("data/test.csv", index=False)

print(f"Wrote {len(train_df)} train rows and {len(test_df)} test rows.")
