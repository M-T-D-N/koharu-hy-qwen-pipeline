from __future__ import annotations

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock


SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "download-model.py"
SPEC = importlib.util.spec_from_file_location("download_model", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
download_model = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(download_model)


class DownloadManifestTests(unittest.TestCase):
    def test_regeneration_excludes_the_previous_manifest_and_keeps_hashes(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory)
            (destination / "weights.safetensors").write_bytes(b"weights")
            (destination / "download-manifest.json").write_text("old", encoding="utf-8")
            (destination / ".cache").mkdir()
            (destination / ".cache" / "ignored.json").write_text("cache", encoding="utf-8")
            entry = {"repo_id": "example/model", "revision": "abc123"}

            first = download_model.build_manifest(destination, "test", entry)
            download_model.write_manifest(destination, first)
            second = download_model.build_manifest(destination, "test", entry)

            self.assertEqual([item["path"] for item in second["files"]], ["weights.safetensors"])
            self.assertRegex(second["files"][0]["sha256"], r"^[0-9A-F]{64}$")
            stored = json.loads((destination / "download-manifest.json").read_text(encoding="utf-8"))
            self.assertEqual(stored["files"], first["files"])

    def test_download_refuses_to_trust_residual_files_in_an_existing_destination(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / "model"
            destination.mkdir()
            stale = destination / "stale.safetensors"
            stale.write_bytes(b"stale")
            snapshot = Mock()
            with self.assertRaises(FileExistsError):
                download_model.download_pinned_model(
                    destination,
                    "test",
                    {"repo_id": "example/model", "revision": "abc123"},
                    snapshot,
                )
            snapshot.assert_not_called()
            self.assertEqual(stale.read_bytes(), b"stale")

    def test_download_publishes_only_a_complete_private_staging_directory(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / "model"

            def snapshot_download(**kwargs: object) -> None:
                staging = Path(str(kwargs["local_dir"]))
                (staging / "weights.safetensors").write_bytes(b"weights")

            manifest = download_model.download_pinned_model(
                destination,
                "test",
                {"repo_id": "example/model", "revision": "abc123"},
                snapshot_download,
            )
            self.assertTrue((destination / "weights.safetensors").is_file())
            self.assertTrue((destination / "download-manifest.json").is_file())
            self.assertEqual([item["path"] for item in manifest["files"]], ["weights.safetensors"])
            self.assertEqual(list(Path(directory).glob(".model.download-*")), [])


if __name__ == "__main__":
    unittest.main()
