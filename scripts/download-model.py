from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import uuid
from datetime import datetime, timezone
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
LOCK_PATH = ROOT / "config" / "model-lock.json"
MODEL_PATTERNS = (
    "*.json",
    "*.jinja",
    "*.model",
    "*.safetensors",
    "*.txt",
    "LICENSE*",
    "README*",
)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(8 * 1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest().upper()


def build_manifest(destination: Path, model: str, entry: dict[str, object]) -> dict[str, object]:
    files = []
    manifest_path = destination / "download-manifest.json"
    for path in sorted(item for item in destination.rglob("*") if item.is_file()):
        if ".cache" in path.parts or path == manifest_path:
            continue
        files.append(
            {
                "path": path.relative_to(destination).as_posix(),
                "size_bytes": path.stat().st_size,
                "sha256": sha256(path),
            }
        )
    if not files:
        raise RuntimeError(f"downloaded model contains no files: {destination}")
    return {
        "schema_version": 1,
        "generated_at_utc": datetime.now(timezone.utc).isoformat(),
        "model": model,
        "repo_id": entry["repo_id"],
        "revision": entry["revision"],
        "files": files,
        "total_bytes": sum(item["size_bytes"] for item in files),
    }


def write_manifest(destination: Path, manifest: dict[str, object]) -> Path:
    manifest_path = destination / "download-manifest.json"
    temporary = destination / f".download-manifest.{os.getpid()}.tmp"
    temporary.write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    os.replace(temporary, manifest_path)
    return manifest_path


def download_pinned_model(
    destination: Path,
    model: str,
    entry: dict[str, object],
    snapshot_download: object,
) -> dict[str, object]:
    if destination.exists():
        raise FileExistsError(f"model destination already exists; refusing to overlay it: {destination}")
    parent = destination.parent
    parent.mkdir(parents=True, exist_ok=True)
    staging = parent / f".{destination.name}.download-{uuid.uuid4().hex}"
    try:
        staging.mkdir()
        snapshot_download(
            repo_id=entry["repo_id"],
            revision=entry["revision"],
            local_dir=staging,
            allow_patterns=list(MODEL_PATTERNS),
            max_workers=4,
        )
        manifest = build_manifest(staging, model, entry)
        write_manifest(staging, manifest)
        staging.rename(destination)
        return manifest
    finally:
        if staging.exists():
            shutil.rmtree(staging)


def main() -> None:
    from huggingface_hub import snapshot_download

    lock = json.loads(LOCK_PATH.read_text(encoding="utf-8"))
    parser = argparse.ArgumentParser(description="Download one pinned translation model.")
    parser.add_argument("model", choices=sorted(lock["models"]))
    args = parser.parse_args()

    entry = lock["models"][args.model]
    destination = ROOT / "models" / args.model
    manifest = download_pinned_model(destination, args.model, entry, snapshot_download)
    print(json.dumps({"destination": str(destination), **manifest}, ensure_ascii=False))


if __name__ == "__main__":
    main()
