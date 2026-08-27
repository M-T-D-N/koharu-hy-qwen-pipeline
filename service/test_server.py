from __future__ import annotations

import json
import ctypes
import os
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest.mock import patch

from service.server import FONT_FAMILIES, REQUEST_LOCAL, QwenUseLease, RequestControl, ServiceError, apply_typography, blocking_defects, defects, enforce_koharu_role, lifecycle, load_translation_policy, normalize_nonlinguistic, qwen_api, qwen_model, qwen_sparse_complete, request_layer_context, result_schema, review, run_managed_process, run_pipeline, service_error_message, sparse_review_schema, start_or_reuse_qwen, validate_font_policy_available, wait_for_qwen_stable


class ValidatorTests(unittest.TestCase):
    def test_qwen_stability_requires_two_consecutive_ready_checks(self) -> None:
        with patch("service.server.qwen_is_ready", side_effect=[False, True, True]) as ready_mock, \
             patch("service.server.wait_cancellable") as wait_mock:
            self.assertTrue(wait_for_qwen_stable(max_checks=5, interval_seconds=0.01))
        self.assertEqual(ready_mock.call_count, 3)
        self.assertEqual(wait_mock.call_count, 2)

    def test_qwen_stability_window_is_bounded(self) -> None:
        with patch("service.server.qwen_is_ready", return_value=False) as ready_mock, \
             patch("service.server.wait_cancellable") as wait_mock:
            self.assertFalse(wait_for_qwen_stable(max_checks=5, interval_seconds=0.01))
        self.assertEqual(ready_mock.call_count, 5)
        self.assertEqual(wait_mock.call_count, 4)

    def test_qwen_endpoint_and_model_are_read_from_environment(self) -> None:
        with patch.dict(
            "os.environ",
            {
                "KOHARU_QWEN_API": "http://127.0.0.1:9123/custom/",
                "KOHARU_QWEN_MODEL": "review-model",
            },
        ):
            self.assertEqual(qwen_api(), "http://127.0.0.1:9123/custom")
            self.assertEqual(qwen_model(), "review-model")

    def test_lifecycle_requires_an_explicit_script(self) -> None:
        with patch.dict("os.environ", {}, clear=True):
            with self.assertRaises(ServiceError) as caught:
                lifecycle("status")
        self.assertEqual(caught.exception.code, "QWEN_LIFECYCLE_MISSING")

    def test_lifecycle_uses_the_exact_configured_powershell(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            lifecycle_script = root / "lifecycle.ps1"
            powershell = root / "pwsh.exe"
            lifecycle_script.write_text("test", encoding="utf-8")
            powershell.write_bytes(b"test")
            completed = type("Completed", (), {"returncode": 0, "stdout": '{"ok":true}', "stderr": ""})()
            with patch.dict(
                "os.environ",
                {
                    "KOHARU_QWEN_LIFECYCLE_SCRIPT": str(lifecycle_script),
                    "KOHARU_PWSH_EXECUTABLE": str(powershell),
                },
                clear=True,
            ), patch("service.server.run_managed_process", return_value=completed) as managed:
                self.assertEqual(lifecycle("status"), {"ok": True})
        self.assertEqual(managed.call_args.args[0][0], str(powershell.resolve()))

    def test_start_qwen_lifecycle_preserves_its_persistent_child(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            lifecycle_script = root / "lifecycle.ps1"
            powershell = root / "pwsh.exe"
            lifecycle_script.write_text("test", encoding="utf-8")
            powershell.write_bytes(b"test")
            completed = type("Completed", (), {
                "returncode": 0,
                "stdout": '{"status":"ready_owned"}',
                "stderr": "",
            })()
            with patch.dict(
                "os.environ",
                {
                    "KOHARU_QWEN_LIFECYCLE_SCRIPT": str(lifecycle_script),
                    "KOHARU_PWSH_EXECUTABLE": str(powershell),
                },
                clear=True,
            ), patch("service.server.run_managed_process", return_value=completed) as managed:
                lifecycle("start-qwen")
        self.assertTrue(managed.call_args.kwargs["persistent_children"])

    def test_service_error_message_preserves_cleanup_failure_notes(self) -> None:
        error = ServiceError(502, "PRIMARY_FAILURE", "translation failed")
        error.add_note("Qwen cleanup also failed")
        self.assertEqual(service_error_message(error), "translation failed; Qwen cleanup also failed")

    def test_request_control_status_includes_the_exact_page_identity(self) -> None:
        with patch("service.server.WindowsChildJob"):
            control = RequestControl("request-id", page_id="page-id")
            try:
                self.assertEqual(control.snapshot()["page_id"], "page-id")
            finally:
                control.close()

    @patch("service.server.post_json")
    @patch("service.server.koharu_json")
    def test_reviewed_font_is_applied_without_erasing_typography(self, koharu_json_mock, post_json_mock) -> None:
        page_id = "00000000-0000-0000-0000-000000000001"
        layer_id = "00000000-0000-0000-0000-000000000002"
        koharu_json_mock.side_effect = [{
            "layers": [{
                "type": "text",
                "id": layer_id,
                "typography": {"preferred_font": None, "auto_fit": True, "color": [0, 0, 0, 255]},
            }]
        }, {}]
        apply_typography(page_id, [{"region_id": layer_id, "font_role": "Gowun Dodum"}])
        payload = koharu_json_mock.call_args_list[1].args[1]
        self.assertEqual(payload["updates"][0]["typography"]["preferred_font"], "Gowun Dodum")
        self.assertTrue(payload["updates"][0]["typography"]["auto_fit"])
        self.assertEqual(payload["updates"][0]["typography"]["color"], [0, 0, 0, 255])
        post_json_mock.assert_not_called()

    def test_translation_policy_maps_logical_fonts_to_koharu_families(self) -> None:
        role_fonts, role_defaults, families = load_translation_policy()
        self.assertEqual(families["HS Yuji"], "HS유지체")
        self.assertEqual(families["Nanum Brush Script"], "Nanum Pen")
        self.assertIn(role_defaults["handwritten_effect"], role_fonts["handwritten_effect"])
        self.assertEqual(families, FONT_FAMILIES)

    def test_font_policy_requires_every_mapped_koharu_family(self) -> None:
        catalog = [{"name": family} for family in set(FONT_FAMILIES.values())]
        validate_font_policy_available(catalog)
        with self.assertRaises(ServiceError) as caught:
            validate_font_policy_available(catalog[:-1])
        self.assertEqual(caught.exception.code, "KOHARU_FONT_POLICY_MISSING")

    def test_clean_translation_has_no_defects(self) -> None:
        self.assertEqual(defects({"final_translation": "자연스러운 번역", "status": "translated", "confidence": "high", "issues": ["none"], "semantic_role": "dialogue", "font_role": "Gowun Dodum"}), [])

    def test_validator_finds_residual_placeholder_and_low_confidence(self) -> None:
        self.assertEqual(
            defects({"final_translation": "아ッ [UNK]", "status": "failed", "confidence": "low", "issues": ["source_residual", "placeholder"], "semantic_role": "handwritten_effect", "font_role": "HS Yuji"}),
            ["source_residual", "placeholder", "failed", "low_confidence"],
        )

    def test_checkbox_block_is_an_explicit_terminal_nontranslation(self) -> None:
        item = {"semantic_role": "dialogue", "font_role": "Gowun Dodum"}
        source = "☐\n☑\n☒\n☐"
        normalize_nonlinguistic(item, source, {"koharu_role": "dev.koharu.text.dialogue"})
        self.assertEqual(item["final_translation"], source)
        self.assertEqual(item["status"], "ignored_with_reason")
        self.assertEqual(item["issues"], ["nonlinguistic_symbol"])
        self.assertEqual(defects(item), [])

    def test_schema_requires_one_result_per_region(self) -> None:
        schema = result_schema(3)
        results = schema["properties"]["results"]
        self.assertEqual(results["minItems"], 3)
        self.assertEqual(results["maxItems"], 3)
        self.assertEqual(results["items"]["properties"]["id"]["maximum"], 2)
        self.assertEqual(sparse_review_schema(3)["properties"]["defects"]["maxItems"], 3)

    @patch("service.server.post_json")
    @patch("service.server.time.sleep")
    def test_sparse_review_retries_invalid_json_once(self, sleep_mock, post_json_mock) -> None:
        post_json_mock.side_effect = [
            {"choices": [{"message": {"content": "not json"}}]},
            {"choices": [{"message": {"content": '{"defects": []}'}}]},
        ]
        self.assertEqual(qwen_sparse_complete("system", {"regions": []}, 0), [])
        self.assertEqual(post_json_mock.call_count, 2)
        sleep_mock.assert_not_called()

    @patch("service.server.post_json")
    @patch("service.server.time.sleep")
    def test_sparse_review_stops_after_two_invalid_json_responses(self, sleep_mock, post_json_mock) -> None:
        post_json_mock.return_value = {"choices": [{"message": {"content": "not json"}}]}
        with self.assertRaises(ServiceError) as caught:
            qwen_sparse_complete("system", {"regions": []}, 0)
        self.assertEqual(caught.exception.code, "QWEN_INVALID_JSON")
        self.assertEqual(post_json_mock.call_count, 2)
        sleep_mock.assert_not_called()

    @patch("service.server.post_json")
    @patch("service.server.time.sleep")
    def test_sparse_review_waits_before_retrying_a_reset(self, sleep_mock, post_json_mock) -> None:
        post_json_mock.side_effect = [
            ConnectionResetError(),
            {"choices": [{"finish_reason": "stop", "message": {"content": '{"defects": []}'}}]},
        ]
        self.assertEqual(qwen_sparse_complete("system", {"regions": []}, 1), [])
        sleep_mock.assert_called_once_with(2.0)
        self.assertEqual(post_json_mock.call_count, 2)

    @patch("service.server.post_json")
    def test_sparse_review_reserves_full_defect_response_budget(self, post_json_mock) -> None:
        post_json_mock.return_value = {"choices": [{"finish_reason": "stop", "message": {"content": '{"defects": []}'}}]}
        qwen_sparse_complete("system", {"regions": []}, 20)
        self.assertEqual(post_json_mock.call_args.args[1]["max_tokens"], 5120)

    def test_changed_text_requires_a_real_issue(self) -> None:
        item = {"final_translation": "바뀐 문장", "status": "translated", "confidence": "high", "issues": ["none"], "semantic_role": "dialogue", "font_role": "Gowun Dodum"}
        self.assertEqual(defects(item, "원래 문장"), ["review_metadata"])

    def test_role_font_mismatch_is_rejected(self) -> None:
        item = {"final_translation": "문장", "status": "translated", "confidence": "high", "issues": ["none"], "semantic_role": "narration", "font_role": "Nanum Brush Script"}
        self.assertEqual(defects(item), ["role_font_mismatch"])

    def test_soft_failed_low_confidence_output_is_nonblocking(self) -> None:
        item = {"final_translation": "최선의 번역", "status": "failed", "confidence": "low", "issues": ["ocr_uncertain"], "semantic_role": "dialogue", "font_role": "Gowun Dodum"}
        self.assertEqual(defects(item), ["failed", "low_confidence"])
        self.assertEqual(blocking_defects(defects(item)), [])

    def test_soft_review_metadata_and_role_font_mismatch_are_nonblocking(self) -> None:
        item = {"final_translation": "문장", "status": "translated", "confidence": "high", "issues": [], "semantic_role": "narration", "font_role": "Nanum Brush Script"}
        self.assertEqual(blocking_defects(defects(item)), [])

    def test_only_unusable_output_defects_remain_blocking(self) -> None:
        self.assertEqual(blocking_defects(defects({"final_translation": "", "status": "translated", "confidence": "high", "issues": ["none"], "semantic_role": "dialogue", "font_role": "Gowun Dodum"})), ["empty"])
        self.assertEqual(blocking_defects(defects({"final_translation": "이름 (日本語)", "status": "failed", "confidence": "low", "issues": ["source_residual"], "semantic_role": "dialogue", "font_role": "Gowun Dodum"})), [])
        self.assertEqual(blocking_defects(defects({"final_translation": "[UNK]", "status": "translated", "confidence": "high", "issues": ["none"], "semantic_role": "dialogue", "font_role": "Gowun Dodum"})), ["placeholder"])
        self.assertEqual(blocking_defects(defects({"final_translation": "문장", "status": "unknown", "confidence": "high", "issues": ["none"], "semantic_role": "dialogue", "font_role": "Gowun Dodum"})), ["unresolved_status"])

    def test_pipeline_returns_nonempty_low_confidence_translation_for_review(self) -> None:
        request = {
            "messages": [{"role": "user", "content": json.dumps({"segments": [{"id": 0, "text": "曖昧"}], "context": []})}],
            "metadata": {
                "koharu_page_id": "00000000-0000-0000-0000-000000000001",
                "koharu_region_ids": ["00000000-0000-0000-0000-000000000002"],
                "koharu_region_roles": ["dev.koharu.text.dialogue"],
            },
        }
        reviewed = [{
            "id": 0, "final_translation": "모호한 표현", "status": "failed", "issues": ["ocr_uncertain"],
            "repair_applied": True, "confidence": "low", "semantic_role": "dialogue",
            "font_role": "Gowun Dodum", "validator_defects": ["failed", "low_confidence"],
        }]
        with tempfile.TemporaryDirectory() as directory, \
             patch.dict("os.environ", {"KOHARU_QWEN_LEASE_PATH": str(Path(directory) / "qwen-use.lock")}), \
             patch("service.server.ROOT", Path(directory)), \
             patch("service.server.specialist_translate", return_value={"translations": [{"id": 0, "text": "초벌"}]}), \
             patch("service.server.qwen_is_ready", return_value=True), \
             patch("service.server.lifecycle", return_value={"status": "ready_owned", "started_by_request": False, "model": "dirk-qwen3.8-27b-q5", "context": 131072}) as lifecycle_mock, \
             patch("service.server.review", return_value=reviewed), \
             patch("service.server.validate_font_policy_available") as font_validation_mock, \
             patch("service.server.apply_typography") as typography_mock, \
             patch("service.server.wait_cancellable"):
            result = run_pipeline(request)
        self.assertEqual(result.translations, [{"id": 0, "text": "모호한 표현"}])
        self.assertTrue(result.audit[0]["review_required"])
        self.assertEqual(result.audit[0]["blocking_defects"], [])
        typography_mock.assert_called_once()
        font_validation_mock.assert_not_called()
        lifecycle_mock.assert_called_once_with("start-qwen")

    def test_pipeline_still_blocks_unusable_translation(self) -> None:
        request = {
            "messages": [{"role": "user", "content": json.dumps({"segments": [{"id": 0, "text": "原文"}], "context": []})}],
            "metadata": {
                "koharu_page_id": "00000000-0000-0000-0000-000000000001",
                "koharu_region_ids": ["00000000-0000-0000-0000-000000000002"],
                "koharu_region_roles": ["dev.koharu.text.dialogue"],
            },
        }
        reviewed = [{
            "id": 0, "final_translation": "", "status": "failed", "issues": ["ocr_uncertain"],
            "repair_applied": True, "confidence": "low", "semantic_role": "dialogue",
            "font_role": "Gowun Dodum", "validator_defects": ["empty", "failed", "low_confidence"],
        }]
        with tempfile.TemporaryDirectory() as directory, \
             patch.dict("os.environ", {"KOHARU_QWEN_LEASE_PATH": str(Path(directory) / "qwen-use.lock")}), \
             patch("service.server.ROOT", Path(directory)), \
             patch("service.server.specialist_translate", return_value={"translations": [{"id": 0, "text": "초벌"}]}), \
             patch("service.server.qwen_is_ready", return_value=True), \
             patch("service.server.lifecycle", return_value={"status": "ready_owned", "started_by_request": True, "model": "dirk-qwen3.8-27b-q5", "context": 131072}), \
             patch("service.server.review", return_value=reviewed), \
             patch("service.server.validate_font_policy_available") as font_validation_mock, \
             patch("service.server.apply_typography") as typography_mock, \
             patch("service.server.wait_cancellable"):
            with self.assertRaises(ServiceError) as caught:
                run_pipeline(request)
        self.assertEqual(caught.exception.code, "UNRESOLVED_TRANSLATION")
        typography_mock.assert_not_called()
        font_validation_mock.assert_not_called()

    def test_qwen_lease_fails_fast_without_replacing_an_existing_owner(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            lease_path = Path(directory) / "qwen-use.lock"
            original = '{"owner":"another-worker","pid":1234}'
            lease_path.write_text(original, encoding="utf-8")
            with patch.dict("os.environ", {"KOHARU_QWEN_LEASE_PATH": str(lease_path)}), \
                 patch("service.server.marker_owner_active", return_value=True):
                with self.assertRaises(ServiceError) as caught:
                    QwenUseLease(wait_seconds=0).__enter__()
            self.assertEqual(caught.exception.code, "QWEN_BUSY")
            self.assertEqual(lease_path.read_text(encoding="utf-8"), original)
            self.assertFalse((Path(directory) / "foreground-request.json").exists())

    def test_qwen_foreground_priority_wait_is_bounded_and_acquires_after_release(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            lease_path = root / "qwen-use.lock"
            lease_path.write_text('{"owner":"background","pid":1234}', encoding="utf-8")
            released = threading.Event()

            def release_background() -> None:
                time.sleep(0.05)
                lease_path.unlink()
                released.set()

            worker = threading.Thread(target=release_background)
            worker.start()
            with patch.dict("os.environ", {"KOHARU_QWEN_LEASE_PATH": str(lease_path)}), \
                 patch("service.server.marker_owner_active", return_value=True):
                lease = QwenUseLease(wait_seconds=1).__enter__()
                try:
                    self.assertTrue(lease.owned)
                    self.assertTrue(released.wait(timeout=1))
                    self.assertFalse((root / "foreground-request.json").exists())
                finally:
                    lease.release()
            worker.join(timeout=1)
            self.assertFalse(worker.is_alive())

    def test_stale_qwen_lease_is_recovered_without_touching_a_live_owner(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            lease_path = Path(directory) / "qwen-use.lock"
            lease_path.write_text('{"owner":"dead-worker","pid":1234,"processStartUtc":"2026-01-01T00:00:00Z"}', encoding="utf-8")
            with patch.dict("os.environ", {"KOHARU_QWEN_LEASE_PATH": str(lease_path)}), \
                 patch("service.server.marker_owner_active", return_value=False):
                lease = QwenUseLease(wait_seconds=0).__enter__()
                try:
                    self.assertTrue(lease.owned)
                    self.assertEqual(json.loads(lease_path.read_text(encoding="utf-8"))["token"], lease.token)
                finally:
                    lease.release()

    def test_stale_qwen_foreground_marker_is_recovered(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            lease_path = root / "qwen-use.lock"
            foreground_path = root / "foreground-request.json"
            foreground_path.write_text(
                '{"owner":"dead-foreground","pid":1234,"processStartUtc":"2026-01-01T00:00:00Z"}',
                encoding="utf-8",
            )
            with patch.dict("os.environ", {"KOHARU_QWEN_LEASE_PATH": str(lease_path)}), \
                 patch("service.server.marker_owner_active", return_value=False):
                lease = QwenUseLease(wait_seconds=0).__enter__()
                try:
                    self.assertTrue(lease.owned)
                    self.assertFalse(foreground_path.exists())
                finally:
                    lease.release()

    def test_qwen_marker_symlink_or_junction_is_rejected_before_use(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            lease_path = Path(directory) / "qwen-use.lock"
            with patch.dict("os.environ", {"KOHARU_QWEN_LEASE_PATH": str(lease_path)}), \
                 patch("service.server.marker_path_unsafe", return_value=True):
                with self.assertRaises(ServiceError) as caught:
                    QwenUseLease(wait_seconds=0).__enter__()
            self.assertEqual(caught.exception.code, "QWEN_LEASE_INVALID")

    def test_exact_running_qwen_is_reused_without_claiming_process_start(self) -> None:
        state = {
            "status": "ready_owned",
            "started_by_request": False,
            "model": "dirk-qwen3.8-27b-q5",
            "context": 131072,
        }
        with patch("service.server.lifecycle", return_value=state) as lifecycle_mock:
            self.assertFalse(start_or_reuse_qwen())
        lifecycle_mock.assert_called_once_with("start-qwen")

    def test_reused_qwen_still_requires_the_exact_model_and_context(self) -> None:
        for state, code in (
            ({"status": "ready_owned", "started_by_request": False, "model": "wrong", "context": 131072}, "QWEN_MODEL_MISMATCH"),
            ({"status": "ready_owned", "started_by_request": False, "model": "dirk-qwen3.8-27b-q5", "context": 65536}, "QWEN_CONTEXT_MISMATCH"),
        ):
            with self.subTest(code=code), patch("service.server.lifecycle", return_value=state):
                with self.assertRaises(ServiceError) as caught:
                    start_or_reuse_qwen()
                self.assertEqual(caught.exception.code, code)

    def test_qwen_lease_release_requires_the_same_token(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            lease_path = Path(directory) / "qwen-use.lock"
            with patch.dict("os.environ", {"KOHARU_QWEN_LEASE_PATH": str(lease_path)}):
                lease = QwenUseLease().__enter__()
                record = json.loads(lease_path.read_text(encoding="utf-8"))
                record["token"] = "changed"
                lease_path.write_text(json.dumps(record), encoding="utf-8")
                with self.assertRaises(ServiceError) as caught:
                    lease.release()
            self.assertEqual(caught.exception.code, "QWEN_LEASE_CHANGED")
            self.assertTrue(lease_path.is_file())

    @unittest.skipUnless(os.name == "nt", "Windows Job Object behavior")
    def test_cancel_closes_the_managed_child_process_tree(self) -> None:
        kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel32.OpenProcess.argtypes = [ctypes.c_ulong, ctypes.c_int, ctypes.c_ulong]
        kernel32.OpenProcess.restype = ctypes.c_void_p
        kernel32.CloseHandle.argtypes = [ctypes.c_void_p]
        kernel32.CloseHandle.restype = ctypes.c_int
        kernel32.GetExitCodeProcess.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_ulong)]
        kernel32.GetExitCodeProcess.restype = ctypes.c_int

        def process_is_alive(pid: int) -> bool:
            handle = kernel32.OpenProcess(0x1000, False, pid)
            if not handle:
                return False
            try:
                exit_code = ctypes.c_ulong()
                if not kernel32.GetExitCodeProcess(handle, ctypes.byref(exit_code)):
                    return True
                return exit_code.value == 259  # STILL_ACTIVE
            finally:
                kernel32.CloseHandle(handle)

        with tempfile.TemporaryDirectory() as directory:
            pid_path = Path(directory) / "child-pids.json"
            child_code = (
                "import json,os,subprocess,sys,time;"
                "grandchild=subprocess.Popen([sys.executable,'-c','import time;time.sleep(60)']);"
                f"open({str(pid_path)!r},'w',encoding='utf-8').write(json.dumps({{'child':os.getpid(),'grandchild':grandchild.pid}}));"
                "time.sleep(60)"
            )
            control = RequestControl("cancel-tree-test")
            errors: list[Exception] = []

            def worker() -> None:
                REQUEST_LOCAL.control = control
                try:
                    run_managed_process(
                        [sys.executable, "-c", child_code],
                        timeout=30,
                        phase="test_child_tree",
                    )
                except Exception as error:
                    errors.append(error)
                finally:
                    del REQUEST_LOCAL.control

            thread = threading.Thread(target=worker)
            try:
                thread.start()
                deadline = time.monotonic() + 10
                identities = None
                while time.monotonic() < deadline:
                    try:
                        identities = json.loads(pid_path.read_text(encoding="utf-8"))
                        break
                    except (FileNotFoundError, json.JSONDecodeError):
                        time.sleep(0.02)
                self.assertIsNotNone(identities, "managed child did not publish its complete process tree")
                self.assertTrue(process_is_alive(identities["child"]))
                self.assertTrue(process_is_alive(identities["grandchild"]))

                control.request_cancel()
                thread.join(timeout=10)
                self.assertFalse(thread.is_alive(), "managed process cancellation exceeded its bound")
                control.close()
                deadline = time.monotonic() + 5
                while any(process_is_alive(identities[key]) for key in ("child", "grandchild")) and time.monotonic() < deadline:
                    time.sleep(0.02)
                self.assertFalse(process_is_alive(identities["child"]))
                self.assertFalse(process_is_alive(identities["grandchild"]))
                self.assertEqual(len(errors), 1)
                self.assertIsInstance(errors[0], ServiceError)
                self.assertEqual(errors[0].code, "REQUEST_CANCELLED")
            finally:
                control.close()
                thread.join(timeout=1)

    def test_koharu_sound_effect_role_cannot_be_downgraded_to_dialogue(self) -> None:
        item = {"semantic_role": "dialogue", "font_role": "Gowun Dodum"}
        enforce_koharu_role(item, {"koharu_role": "dev.koharu.text.sound-effect"})
        self.assertEqual(item, {"semantic_role": "handwritten_effect", "font_role": "HS Yuji"})

    def test_koharu_sound_effect_preserves_valid_handwritten_font(self) -> None:
        item = {"semantic_role": "handwritten_effect", "font_role": "East Sea Dokdo"}
        enforce_koharu_role(item, {"koharu_role": "dev.koharu.text.sound-effect"})
        self.assertEqual(item["font_role"], "East Sea Dokdo")

    @patch("service.server.load_layer_context")
    def test_request_roles_avoid_callback_to_koharu(self, load_layer_context_mock) -> None:
        metadata = {
            "koharu_page_id": "page-1",
            "koharu_region_roles": ["dev.koharu.text.dialogue", "dev.koharu.text.sound-effect"],
        }
        result = request_layer_context(metadata, ["region-1", "region-2"])
        self.assertEqual(result, [
            {"koharu_role": "dev.koharu.text.dialogue"},
            {"koharu_role": "dev.koharu.text.sound-effect"},
        ])
        load_layer_context_mock.assert_not_called()

    def test_metadata_only_repair_closes_once(self) -> None:
        first = [{"id": 0, "text": "오늘은 날씨가 좋네요."}]
        source = [{"id": 0, "text": "今日はいい天気です。"}]
        sparse = [{"id": 0, "final_translation": "오늘 날씨가 좋네요.", "status": "translated", "issues": ["literal_or_awkward"], "confidence": "high", "semantic_role": "narration", "font_role": "Nanum Brush Script"}]
        repaired = [{"id": 0, "final_translation": "오늘 날씨가 좋네요.", "status": "translated", "issues": ["literal_or_awkward"], "confidence": "high", "semantic_role": "narration", "font_role": "Gowun Batang"}]
        with patch("service.server.qwen_sparse_complete", return_value=sparse) as sparse_complete, patch("service.server.qwen_complete", return_value=repaired) as complete:
            result = review(first, source, [])
        self.assertEqual(sparse_complete.call_count, 1)
        self.assertEqual(complete.call_count, 1)
        self.assertTrue(result[0]["repair_applied"])
        self.assertEqual(result[0]["validator_defects"], [])

    def test_review_chunks_large_pages_without_losing_ids(self) -> None:
        first = [{"id": index, "text": f"초벌 {index}"} for index in range(51)]
        source = [{"id": index, "text": f"원문 {index}"} for index in range(51)]

        with patch("service.server.qwen_sparse_complete", return_value=[]) as mocked:
            result = review(first, source, [])
        self.assertEqual(mocked.call_count, 3)
        self.assertEqual([item["id"] for item in result], list(range(51)))

    def test_repair_chunks_large_target_sets_without_losing_ids(self) -> None:
        first = [{"id": index, "text": f"초벌 {index}"} for index in range(41)]
        source = [{"id": index, "text": f"원문 {index}"} for index in range(41)]

        def sparse(_system, user, count):
            return [{"id": index, "final_translation": user["regions"][index]["first_translation"], "status": "translated", "issues": ["literal_or_awkward"], "confidence": "high", "semantic_role": "narration", "font_role": "Nanum Brush Script"} for index in range(count)]

        def complete(_system, user, count, _schema_name):
            return [{"id": index, "final_translation": user["regions"][index]["rejected_translation"], "status": "translated", "issues": ["literal_or_awkward"], "confidence": "high", "semantic_role": "narration", "font_role": "Gowun Batang"} for index in range(count)]

        with patch("service.server.qwen_sparse_complete", side_effect=sparse) as sparse_mocked, patch("service.server.qwen_complete", side_effect=complete) as mocked:
            result = review(first, source, [])
        self.assertEqual(sparse_mocked.call_count, 3)
        self.assertEqual(mocked.call_count, 3)
        self.assertEqual([item["id"] for item in result], list(range(41)))
        self.assertTrue(all(item["repair_applied"] for item in result))
        self.assertTrue(all(item["validator_defects"] == [] for item in result))


if __name__ == "__main__":
    unittest.main()
