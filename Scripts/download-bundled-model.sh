#!/usr/bin/env bash
set -euo pipefail

REPO_ID="mlx-community/Qwen2.5-0.5B-Instruct-4bit"
DEST_DIR="$(cd "$(dirname "$0")/.." && pwd)/Sources/NookRuntime/Resources/BundledModels/Qwen2.5-0.5B-Instruct-4bit"

echo "Downloading ${REPO_ID} into ${DEST_DIR}"
mkdir -p "${DEST_DIR}"

REPO_ID="${REPO_ID}" DEST_DIR="${DEST_DIR}" python3 - <<'PY'
import os
from huggingface_hub import snapshot_download

repo_id = os.environ["REPO_ID"]
dest = os.environ["DEST_DIR"]

snapshot_download(
    repo_id=repo_id,
    local_dir=dest,
)
print(f"Done. Model files are in {dest}")
PY
