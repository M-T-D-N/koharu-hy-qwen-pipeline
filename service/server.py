from __future__ import annotations

import argparse
import ctypes
import json
import math
import os
import re
import sys
import subprocess
import tempfile
import threading
import time
import traceback
import urllib.error
import urllib.request
import uuid
from datetime import datetime, timezone
from dataclasses import dataclass
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
SPECIALIST = ROOT / "scripts" / "hy-translate-request.py"
KOHARU_API = os.environ.get("KOHARU_API", "http://127.0.0.1:4010/api/v1").rstrip("/")
MODEL = "koharu-hy-qwen-v1"
JAPANESE = re.compile(r"[一-龯々〆ヵヶぁ-ゖァ-ヺー]")
PLACEHOLDER = re.compile(r"(?:<[^>]+>|\{[^}]+\}|\[UNK\]|�|☐|□)")
CHECKBOX_BLOCK = re.compile(r"[\s☐☑☒]+")
GPU_LOCK = threading.Lock()
ACTIVE_LOCK = threading.Lock()
ACTIVE_REQUEST: RequestControl | None = None
REQUEST_LOCAL = threading.local()
PROCESS_STARTED_UTC = datetime.now(timezone.utc).isoformat()
PROCESS_STARTED_FILETIME_UTC: str | None = None
QWEN_REVIEW_CHUNK = 20
ISSUES = [
    "meaning_error", "omission", "addition", "name_or_term", "voice_or_register",
    "literal_or_awkward", "source_residual", "placeholder", "sound_effect",
    "ocr_uncertain", "line_wrap", "nonlinguistic_symbol", "none",
]
STATUSES = ["translated", "preserved", "ignored_with_reason", "failed"]
ROLES = ["dialogue", "narration", "emphasis", "handwritten_effect"]


def load_translation_policy(path: Path = ROOT / "config" / "translation-policy.json") -> tuple[dict[str, set[str]], dict[str, str], dict[str, str]]:
    try:
        policy = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise RuntimeError(f"translation policy is unavailable or invalid: {path}: {error}") from error
    if policy.get("schema_version") != 1 or set((policy.get("roles") or {}).keys()) != set(ROLES):
        raise RuntimeError("translation policy must declare schema 1 and every supported role exactly once")
    role_fonts: dict[str, set[str]] = {}
    role_defaults: dict[str, str] = {}
    font_families: dict[str, str] = {}
    for role in ROLES:
        record = policy["roles"][role]
        fonts = record.get("fonts")
        if not isinstance(fonts, list) or not fonts:
            raise RuntimeError(f"translation policy role has no fonts: {role}")
        role_fonts[role] = set()
        for font in fonts:
            font_id = str(font.get("id") or "").strip()
            family = str(font.get("koharu_family") or "").strip()
            if not font_id or not family:
                raise RuntimeError(f"translation policy contains an incomplete font for role: {role}")
            if font_id in font_families and font_families[font_id] != family:
                raise RuntimeError(f"translation policy maps one font ID to multiple Koharu families: {font_id}")
            role_fonts[role].add(font_id)
            font_families[font_id] = family
        default = str(record.get("default") or "").strip()
        if default not in role_fonts[role]:
            raise RuntimeError(f"translation policy default is not allowed for role {role}: {default}")
        role_defaults[role] = default
    return role_fonts, role_defaults, font_families


ROLE_FONTS, ROLE_DEFAULTS, FONT_FAMILIES = load_translation_policy()
FONTS = list(FONT_FAMILIES)


class ServiceError(RuntimeError):
    def __init__(self, status: int, code: str, message: str):
        super().__init__(message)
        self.status = status
        self.code = code


def service_error_message(error: ServiceError) -> str:
    notes = [str(note) for note in getattr(error, "__notes__", [])]
    message = str(error)
    return f"{message}; {'; '.join(notes)}" if notes else message


if os.name == "nt":
    from ctypes import wintypes

    _kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    _kernel32.CreateJobObjectW.argtypes = [ctypes.c_void_p, wintypes.LPCWSTR]
    _kernel32.CreateJobObjectW.restype = wintypes.HANDLE
    _kernel32.SetInformationJobObject.argtypes = [wintypes.HANDLE, ctypes.c_int, ctypes.c_void_p, wintypes.DWORD]
    _kernel32.SetInformationJobObject.restype = wintypes.BOOL
    _kernel32.AssignProcessToJobObject.argtypes = [wintypes.HANDLE, wintypes.HANDLE]
    _kernel32.AssignProcessToJobObject.restype = wintypes.BOOL
    _kernel32.CloseHandle.argtypes = [wintypes.HANDLE]
    _kernel32.CloseHandle.restype = wintypes.BOOL
    _kernel32.GetCurrentProcess.argtypes = []
    _kernel32.GetCurrentProcess.restype = wintypes.HANDLE
    _kernel32.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
    _kernel32.OpenProcess.restype = wintypes.HANDLE

    class _FileTime(ctypes.Structure):
        _fields_ = [("low", wintypes.DWORD), ("high", wintypes.DWORD)]

    _kernel32.GetProcessTimes.argtypes = [
        wintypes.HANDLE,
        ctypes.POINTER(_FileTime),
        ctypes.POINTER(_FileTime),
        ctypes.POINTER(_FileTime),
        ctypes.POINTER(_FileTime),
    ]
    _kernel32.GetProcessTimes.restype = wintypes.BOOL

    class _IoCounters(ctypes.Structure):
        _fields_ = [(name, ctypes.c_ulonglong) for name in (
            "ReadOperationCount", "WriteOperationCount", "OtherOperationCount",
            "ReadTransferCount", "WriteTransferCount", "OtherTransferCount",
        )]

    class _BasicLimitInformation(ctypes.Structure):
        _fields_ = [
            ("PerProcessUserTimeLimit", ctypes.c_longlong),
            ("PerJobUserTimeLimit", ctypes.c_longlong),
            ("LimitFlags", wintypes.DWORD),
            ("MinimumWorkingSetSize", ctypes.c_size_t),
            ("MaximumWorkingSetSize", ctypes.c_size_t),
            ("ActiveProcessLimit", wintypes.DWORD),
            ("Affinity", ctypes.c_size_t),
            ("PriorityClass", wintypes.DWORD),
            ("SchedulingClass", wintypes.DWORD),
        ]

    class _ExtendedLimitInformation(ctypes.Structure):
        _fields_ = [
            ("BasicLimitInformation", _BasicLimitInformation),
            ("IoInfo", _IoCounters),
            ("ProcessMemoryLimit", ctypes.c_size_t),
            ("JobMemoryLimit", ctypes.c_size_t),
            ("PeakProcessMemoryUsed", ctypes.c_size_t),
            ("PeakJobMemoryUsed", ctypes.c_size_t),
        ]

    _created = _FileTime()
    _unused_exit = _FileTime()
    _unused_kernel = _FileTime()
    _unused_user = _FileTime()
    if not _kernel32.GetProcessTimes(
        _kernel32.GetCurrentProcess(),
        ctypes.byref(_created),
        ctypes.byref(_unused_exit),
        ctypes.byref(_unused_kernel),
        ctypes.byref(_unused_user),
    ):
        raise ctypes.WinError(ctypes.get_last_error())
    PROCESS_STARTED_FILETIME_UTC = str((_created.high << 32) | _created.low)

    def marker_owner_active(record: dict[str, Any]) -> bool | None:
        try:
            pid = int(record["pid"])
        except (KeyError, TypeError, ValueError):
            return None
        if pid <= 0:
            return None
        handle = _kernel32.OpenProcess(0x1000, False, pid)  # PROCESS_QUERY_LIMITED_INFORMATION
        if not handle:
            return False if ctypes.get_last_error() == 87 else None  # ERROR_INVALID_PARAMETER means no such PID.
        created = _FileTime()
        unused_exit = _FileTime()
        unused_kernel = _FileTime()
        unused_user = _FileTime()
        try:
            if not _kernel32.GetProcessTimes(
                handle,
                ctypes.byref(created),
                ctypes.byref(unused_exit),
                ctypes.byref(unused_kernel),
                ctypes.byref(unused_user),
            ):
                return None
        finally:
            _kernel32.CloseHandle(handle)
        observed_filetime = (created.high << 32) | created.low
        recorded_filetime = record.get("started_filetime_utc")
        if recorded_filetime is not None:
            return str(observed_filetime) == str(recorded_filetime)
        recorded_start = record.get("processStartUtc") or record.get("started_utc")
        if not recorded_start:
            return None
        try:
            expected = datetime.fromisoformat(str(recorded_start).replace("Z", "+00:00")).timestamp()
        except ValueError:
            return None
        observed = (observed_filetime - 116444736000000000) / 10_000_000
        return abs(observed - expected) <= 0.1
else:
    def marker_owner_active(record: dict[str, Any]) -> bool | None:
        try:
            pid = int(record["pid"])
            os.kill(pid, 0)
            return True
        except ProcessLookupError:
            return False
        except (KeyError, PermissionError, TypeError, ValueError):
            return None


def marker_path_unsafe(path: Path) -> bool:
    try:
        return path.is_symlink() or bool(getattr(path, "is_junction", lambda: False)())
    except OSError:
        return True


class WindowsChildJob:
    def __init__(self) -> None:
        if os.name != "nt":
            raise OSError("Windows Job Objects are required for child-process cleanup")
        self._close = _kernel32.CloseHandle
        self._assign = _kernel32.AssignProcessToJobObject
        self._handle = _kernel32.CreateJobObjectW(None, None)
        if not self._handle:
            raise ctypes.WinError(ctypes.get_last_error())
        info = _ExtendedLimitInformation()
        info.BasicLimitInformation.LimitFlags = 0x00002000  # JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
        if not _kernel32.SetInformationJobObject(
            self._handle, 9, ctypes.byref(info), ctypes.sizeof(info)
        ):
            error = ctypes.WinError(ctypes.get_last_error())
            self.close()
            raise error

    def assign(self, process: subprocess.Popen[str]) -> None:
        if not self._assign(self._handle, ctypes.c_void_p(process._handle)):  # type: ignore[attr-defined]
            raise ctypes.WinError(ctypes.get_last_error())

    def close(self) -> None:
        handle = getattr(self, "_handle", None)
        if handle:
            self._handle = None
            self._close(handle)


class RequestControl:
    def __init__(self, request_id: str, page_id: str | None = None) -> None:
        self.request_id = request_id
        self.page_id = page_id
        self.started_at_utc = datetime.now(timezone.utc).isoformat()
        self.phase = "starting"
        self.percent = 1
        self.detail = "request accepted"
        self.cancel = threading.Event()
        self._lock = threading.Lock()
        self._process: subprocess.Popen[str] | None = None
        try:
            self._job = WindowsChildJob()
        except OSError as error:
            raise ServiceError(503, "PROCESS_TREE_UNSAFE", f"failed to create a child cleanup boundary: {error}") from error

    def attach(self, process: subprocess.Popen[str], phase: str) -> None:
        try:
            self._job.assign(process)
        except OSError as error:
            try:
                process.terminate()
            except OSError:
                pass
            raise ServiceError(503, "PROCESS_TREE_UNSAFE", f"failed to contain child PID {process.pid}: {error}") from error
        self.track(process, phase)

    def track(self, process: subprocess.Popen[str], phase: str) -> None:
        with self._lock:
            self.phase = phase
            self._process = process

    def clear(self, process: subprocess.Popen[str]) -> None:
        with self._lock:
            if self._process is process:
                self._process = None

    def update(self, phase: str, percent: int, detail: str) -> None:
        with self._lock:
            self.phase = phase
            self.percent = max(0, min(100, int(percent)))
            self.detail = detail

    def request_cancel(self) -> None:
        self.cancel.set()

    def snapshot(self) -> dict[str, Any]:
        with self._lock:
            return {
                "request_id": self.request_id,
                "page_id": self.page_id,
                "started_at_utc": self.started_at_utc,
                "phase": self.phase,
                "percent": self.percent,
                "detail": self.detail,
                "cancel_requested": self.cancel.is_set(),
                "child_pid": self._process.pid if self._process and self._process.poll() is None else None,
            }

    def close(self) -> None:
        self._job.close()


def active_request() -> RequestControl | None:
    with ACTIVE_LOCK:
        return ACTIVE_REQUEST


def set_active_request(control: RequestControl | None) -> None:
    global ACTIVE_REQUEST
    with ACTIVE_LOCK:
        ACTIVE_REQUEST = control


def run_managed_process(
    command: list[str], *, input_text: str | None = None, cwd: str | Path | None = None,
    timeout: float, phase: str, cancellable: bool = True, persistent_children: bool = False,
) -> subprocess.CompletedProcess[str]:
    control: RequestControl | None = getattr(REQUEST_LOCAL, "control", None)
    process = subprocess.Popen(
        command,
        cwd=str(cwd) if cwd is not None else None,
        stdin=subprocess.PIPE if input_text is not None else subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        encoding="utf-8",
    )
    if control is not None:
        if persistent_children:
            # start-qwen delegates an externally owned server. Track and bound
            # only the lifecycle wrapper so its persistent child is not killed
            # when this request's disposable-child Job Object closes.
            control.track(process, phase)
        else:
            control.attach(process, phase)
    deadline = time.monotonic() + timeout
    first = True
    try:
        while True:
            if cancellable and control is not None and control.cancel.is_set():
                try:
                    process.terminate()
                    process.wait(timeout=5)
                except (OSError, subprocess.TimeoutExpired):
                    try:
                        process.kill()
                        process.wait(timeout=5)
                    except OSError:
                        pass
                    except subprocess.TimeoutExpired:
                        pass
                raise ServiceError(409, "REQUEST_CANCELLED", f"translation cancelled during {phase}")
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                try:
                    process.terminate()
                    process.wait(timeout=5)
                except (OSError, subprocess.TimeoutExpired):
                    try:
                        process.kill()
                        process.wait(timeout=5)
                    except OSError:
                        pass
                    except subprocess.TimeoutExpired:
                        pass
                raise ServiceError(504, "CHILD_TIMEOUT", f"{phase} exceeded {int(timeout)} seconds")
            try:
                stdout, stderr = process.communicate(input=input_text if first else None, timeout=min(0.25, remaining))
                break
            except subprocess.TimeoutExpired:
                first = False
        return subprocess.CompletedProcess(command, process.returncode, stdout, stderr)
    finally:
        if control is not None:
            control.clear(process)


class QwenUseLease:
    def __init__(self, wait_seconds: float | None = None) -> None:
        value = os.environ.get("KOHARU_QWEN_LEASE_PATH", "").strip()
        if not value:
            raise ServiceError(503, "QWEN_LEASE_MISSING", "KOHARU_QWEN_LEASE_PATH is not configured")
        self.path = Path(os.path.abspath(Path(value).expanduser()))
        self.foreground_path = self.path.with_name("foreground-request.json")
        self.token = uuid.uuid4().hex
        configured_wait = os.environ.get("KOHARU_QWEN_LEASE_WAIT_SECONDS", "600").strip()
        try:
            requested_wait = float(configured_wait) if wait_seconds is None else float(wait_seconds)
        except (TypeError, ValueError) as error:
            raise ServiceError(503, "QWEN_LEASE_INVALID", "KOHARU_QWEN_LEASE_WAIT_SECONDS is invalid") from error
        if not math.isfinite(requested_wait) or requested_wait < 0 or requested_wait > 3600:
            raise ServiceError(503, "QWEN_LEASE_INVALID", "Qwen lease wait must be between 0 and 3600 seconds")
        self.wait_seconds = requested_wait
        self.owned = False
        self.foreground_owned = False

    def _record(self, owner: str) -> dict[str, Any]:
        record: dict[str, Any] = {
            "owner": owner,
            "pid": os.getpid(),
            "processStartUtc": PROCESS_STARTED_UTC,
            "token": self.token,
            "createdAtUtc": datetime.now(timezone.utc).isoformat(),
        }
        if PROCESS_STARTED_FILETIME_UTC is not None:
            record["started_filetime_utc"] = PROCESS_STARTED_FILETIME_UTC
        return record

    @staticmethod
    def _create_marker(path: Path, record: dict[str, Any]) -> None:
        if marker_path_unsafe(path):
            raise ServiceError(503, "QWEN_LEASE_INVALID", f"Qwen coordination marker cannot be a symlink or junction: {path}")
        with path.open("x", encoding="utf-8") as stream:
            json.dump(record, stream, ensure_ascii=False, separators=(",", ":"))
            stream.flush()
            os.fsync(stream.fileno())

    @staticmethod
    def _recover_stale_marker(path: Path) -> tuple[bool, str]:
        if marker_path_unsafe(path):
            raise ServiceError(503, "QWEN_LEASE_INVALID", f"Qwen coordination marker cannot be a symlink or junction: {path}")
        owner = "unknown"
        try:
            original = path.read_text(encoding="utf-8")
            existing = json.loads(original)
            owner = f"{existing.get('owner', 'unknown')} pid={existing.get('pid', '?')}"
            if marker_owner_active(existing) is not False:
                return False, owner
            if marker_path_unsafe(path):
                raise ServiceError(503, "QWEN_LEASE_INVALID", f"Qwen coordination marker cannot be a symlink or junction: {path}")
            if path.read_text(encoding="utf-8") == original:
                path.unlink()
                return True, owner
        except FileNotFoundError:
            return True, owner
        except (OSError, ValueError):
            pass
        return False, owner

    def _remove_foreground_if_owned(self) -> None:
        if not self.foreground_owned:
            return
        try:
            if marker_path_unsafe(self.foreground_path):
                raise ServiceError(500, "QWEN_FOREGROUND_CHANGED", "Qwen foreground priority became a symlink or junction")
            record = json.loads(self.foreground_path.read_text(encoding="utf-8"))
            if record.get("token") != self.token:
                raise ServiceError(500, "QWEN_FOREGROUND_CHANGED", "Qwen foreground priority ownership changed")
            if marker_path_unsafe(self.foreground_path):
                raise ServiceError(500, "QWEN_FOREGROUND_CHANGED", "Qwen foreground priority became a symlink or junction")
            self.foreground_path.unlink()
            self.foreground_owned = False
        except FileNotFoundError as error:
            raise ServiceError(500, "QWEN_FOREGROUND_CHANGED", "Qwen foreground priority disappeared") from error

    def __enter__(self) -> QwenUseLease:
        if not self.path.parent.is_dir() or marker_path_unsafe(self.path):
            raise ServiceError(503, "QWEN_LEASE_INVALID", f"Qwen lease path is unavailable: {self.path}")
        try:
            while True:
                try:
                    self._create_marker(self.foreground_path, self._record("koharu-translation-foreground"))
                    self.foreground_owned = True
                    break
                except FileExistsError as error:
                    recovered, owner = self._recover_stale_marker(self.foreground_path)
                    if recovered:
                        continue
                    raise ServiceError(409, "QWEN_FOREGROUND_BUSY", f"another foreground Qwen request is pending: {owner}") from error

            deadline = time.monotonic() + self.wait_seconds
            while True:
                try:
                    self._create_marker(self.path, self._record("koharu-translation"))
                    self.owned = True
                    return self
                except FileExistsError as error:
                    recovered, owner = self._recover_stale_marker(self.path)
                    if recovered:
                        continue
                    if time.monotonic() >= deadline:
                        raise ServiceError(409, "QWEN_BUSY", f"shared Qwen remained in use by {owner}") from error
                    control: RequestControl | None = getattr(REQUEST_LOCAL, "control", None)
                    if control is not None:
                        control.update("qwen_lease", 3, f"waiting for foreground Qwen priority; current owner {owner}")
                        if control.cancel.wait(timeout=0.25):
                            raise ServiceError(409, "REQUEST_CANCELLED", "translation cancelled while waiting for Qwen")
                    else:
                        time.sleep(0.25)
        finally:
            self._remove_foreground_if_owned()

    def release(self) -> None:
        if not self.owned:
            return
        try:
            if marker_path_unsafe(self.path):
                raise ServiceError(500, "QWEN_LEASE_CHANGED", "Qwen lease became a symlink or junction")
            record = json.loads(self.path.read_text(encoding="utf-8"))
            if record.get("token") != self.token:
                raise ServiceError(500, "QWEN_LEASE_CHANGED", "Qwen lease ownership changed before release")
            if marker_path_unsafe(self.path):
                raise ServiceError(500, "QWEN_LEASE_CHANGED", "Qwen lease became a symlink or junction")
            self.path.unlink()
            self.owned = False
        except FileNotFoundError as error:
            raise ServiceError(500, "QWEN_LEASE_CHANGED", "Qwen lease disappeared before release") from error

    def __exit__(self, exc_type: object, exc: object, traceback_value: object) -> None:
        self.release()


def post_json(url: str, payload: dict[str, Any], timeout: float = 600.0) -> dict[str, Any]:
    return curl_json(url, payload, timeout)


def get_json(url: str, timeout: float = 30.0) -> Any:
    with urllib.request.urlopen(url, timeout=timeout) as response:
        return json.loads(response.read().decode("utf-8"))


def curl_json(url: str, payload: dict[str, Any] | None = None, timeout: float = 60.0) -> Any:
    command = [
        "curl.exe",
        "-sS",
        "--fail-with-body",
        "--http1.1",
        "--max-time",
        str(max(1, int(timeout))),
        "--header",
        "content-type: application/json",
    ]
    body = None
    if payload is not None:
        command.extend(["--request", "POST", "--data-binary", "@-"])
        body = json.dumps(payload, ensure_ascii=False, separators=(",", ":"))
    command.append(url)
    completed = run_managed_process(
        command, input_text=body, timeout=timeout + 5.0, phase="http_request"
    )
    if completed.returncode != 0:
        raise OSError((completed.stderr or completed.stdout).strip()[:1000])
    return json.loads(completed.stdout) if completed.stdout.strip() else {}


def koharu_json(url: str, payload: dict[str, Any] | None = None, timeout: float = 60.0) -> Any:
    return curl_json(url, payload, timeout)


def load_layer_context(page_id: str, region_ids: list[str]) -> list[dict[str, Any]]:
    try:
        uuid.UUID(page_id)
        page = koharu_json(f"{KOHARU_API}/pages/{page_id}")
        layers = {str(layer.get("id")): layer for layer in page.get("layers", [])}
        result = []
        for layer_id in region_ids:
            uuid.UUID(str(layer_id))
            layer = layers.get(str(layer_id))
            if layer is None or layer.get("type") != "text":
                raise ServiceError(409, "KOHARU_LAYER_NOT_FOUND", f"text layer is unavailable: {layer_id}")
            result.append({
                "layer_id": str(layer_id),
                "koharu_role": str((layer.get("content") or {}).get("role") or ""),
            })
        return result
    except ServiceError:
        raise
    except (KeyError, TypeError, ValueError, OSError, urllib.error.URLError) as error:
        raise ServiceError(502, "KOHARU_SCENE_FAILED", f"failed to load Koharu layer context: {error}") from error


def request_layer_context(metadata: dict[str, Any], region_ids: list[str]) -> list[dict[str, Any]]:
    roles = metadata.get("koharu_region_roles")
    if isinstance(roles, list) and len(roles) == len(region_ids) and all(isinstance(role, str) and role for role in roles):
        return [{"koharu_role": role} for role in roles]
    return load_layer_context(str(metadata.get("koharu_page_id")), region_ids)


def enforce_koharu_role(item: dict[str, Any], layer_context: dict[str, Any]) -> None:
    if "sound-effect" not in layer_context.get("koharu_role", ""):
        return
    item["semantic_role"] = "handwritten_effect"
    if item.get("font_role") not in ROLE_FONTS["handwritten_effect"]:
        item["font_role"] = ROLE_DEFAULTS["handwritten_effect"]


def default_lettering(layer_context: dict[str, Any]) -> dict[str, str]:
    role = layer_context.get("koharu_role", "")
    if "sound-effect" in role:
        return {"semantic_role": "handwritten_effect", "font_role": ROLE_DEFAULTS["handwritten_effect"]}
    if "dialogue" in role:
        return {"semantic_role": "dialogue", "font_role": ROLE_DEFAULTS["dialogue"]}
    return {"semantic_role": "narration", "font_role": ROLE_DEFAULTS["narration"]}


def validate_font_policy_available(font_catalog: list[dict[str, Any]] | None = None) -> None:
    try:
        catalog = font_catalog if font_catalog is not None else koharu_json(f"{KOHARU_API}/fonts", timeout=30.0)
        available = {str(item.get("name") or "") for item in catalog if isinstance(item, dict)}
    except (OSError, TypeError, ValueError, urllib.error.URLError) as error:
        raise ServiceError(502, "KOHARU_FONT_CATALOG_FAILED", f"failed to read Koharu fonts: {error}") from error
    missing = sorted(set(FONT_FAMILIES.values()) - available)
    if missing:
        raise ServiceError(503, "KOHARU_FONT_POLICY_MISSING", f"required Koharu font families are unavailable: {', '.join(missing)}")


def apply_typography(page_id: str, audit: list[dict[str, Any]]) -> None:
    try:
        uuid.UUID(page_id)
        for item in audit:
            uuid.UUID(str(item["region_id"]))
    except (KeyError, TypeError, ValueError) as error:
        raise ServiceError(400, "INVALID_KOHARU_ENTITY_IDS", "page and region metadata must contain UUID entity IDs") from error

    try:
        page = koharu_json(f"{KOHARU_API}/pages/{page_id}")
        layers = {str(layer.get("id")): layer for layer in page.get("layers", [])}
        updates = []
        for item in audit:
            layer_id = str(item["region_id"])
            layer = layers.get(layer_id)
            if layer is None or layer.get("type") != "text":
                raise ServiceError(409, "KOHARU_LAYER_NOT_FOUND", f"text layer is unavailable: {layer_id}")
            typography = dict(layer.get("typography") or {})
            typography["preferred_font"] = FONT_FAMILIES[item["font_role"]]
            updates.append({"layer": layer_id, "typography": typography})
        koharu_json(f"{KOHARU_API}/text/typography", {"updates": updates}, timeout=60.0)
    except ServiceError:
        raise
    except (OSError, ValueError, urllib.error.URLError) as error:
        raise ServiceError(502, "KOHARU_TYPOGRAPHY_FAILED", f"failed to apply reviewed typography: {error}") from error


def qwen_api() -> str:
    return os.environ.get("KOHARU_QWEN_API", "http://127.0.0.1:8000/v1").rstrip("/")


def qwen_model() -> str:
    return os.environ.get("KOHARU_QWEN_MODEL", "dirk-qwen3.8-27b-q5")


def qwen_is_ready(timeout: float = 2.0) -> bool:
    try:
        with urllib.request.urlopen(f"{qwen_api()}/models", timeout=timeout) as response:
            value = json.loads(response.read().decode("utf-8"))
        return any(item.get("id") == qwen_model() for item in value.get("data", []))
    except (OSError, ValueError, urllib.error.URLError):
        return False


def wait_for_qwen_stable(max_checks: int = 5, interval_seconds: float = 2.0) -> bool:
    if max_checks < 2:
        raise ValueError("Qwen stability requires at least two checks")
    consecutive_ready = 0
    for check in range(1, max_checks + 1):
        if qwen_is_ready(timeout=5.0):
            consecutive_ready += 1
            if consecutive_ready >= 2:
                return True
        else:
            consecutive_ready = 0
        if check < max_checks:
            wait_cancellable(
                interval_seconds,
                "qwen_warmup",
                52,
                f"checking Qwen stability {check}/{max_checks}",
            )
    return False


def lifecycle(operation: str, *, cleanup: bool = False) -> dict[str, Any]:
    script = os.environ.get("KOHARU_QWEN_LIFECYCLE_SCRIPT", "").strip()
    if not script:
        raise ServiceError(503, "QWEN_LIFECYCLE_MISSING", "KOHARU_QWEN_LIFECYCLE_SCRIPT is not configured")
    try:
        script_path = Path(script).expanduser().resolve(strict=True)
    except OSError as error:
        raise ServiceError(503, "QWEN_LIFECYCLE_MISSING", f"Qwen lifecycle script is missing: {script}") from error
    if not script_path.is_file():
        raise ServiceError(503, "QWEN_LIFECYCLE_MISSING", f"Qwen lifecycle path is not a file: {script_path}")
    powershell = os.environ.get("KOHARU_PWSH_EXECUTABLE", "").strip()
    if not powershell:
        raise ServiceError(503, "POWERSHELL_RUNTIME_MISSING", "KOHARU_PWSH_EXECUTABLE is not configured")
    try:
        powershell_path = Path(powershell).expanduser().resolve(strict=True)
    except OSError as error:
        raise ServiceError(503, "POWERSHELL_RUNTIME_MISSING", f"PowerShell executable is missing: {powershell}") from error
    if not powershell_path.is_file():
        raise ServiceError(503, "POWERSHELL_RUNTIME_MISSING", f"PowerShell path is not a file: {powershell_path}")
    completed = run_managed_process(
        [str(powershell_path), "-NoProfile", "-File", str(script_path), "-Operation", operation],
        cwd=str(script_path.parent),
        timeout=900 if operation == "start-qwen" else 180,
        phase=f"qwen_{operation}",
        cancellable=not cleanup,
        persistent_children=operation == "start-qwen",
    )
    if completed.returncode != 0:
        raise ServiceError(503, "QWEN_LIFECYCLE_FAILED", (completed.stderr or completed.stdout).strip()[:1000])
    try:
        return json.loads(completed.stdout)
    except ValueError as error:
        raise ServiceError(503, "QWEN_LIFECYCLE_INVALID", "Qwen lifecycle returned invalid JSON") from error


def start_or_reuse_qwen() -> bool:
    state = lifecycle("start-qwen")
    if state.get("status") != "ready_owned":
        raise ServiceError(503, "QWEN_NOT_OWNED", f"Qwen lifecycle did not report exact ownership: {state.get('status')}")
    if state.get("model") != qwen_model():
        raise ServiceError(503, "QWEN_MODEL_MISMATCH", f"Qwen lifecycle reported model {state.get('model')!r}")
    try:
        context = int(state.get("context", 0))
    except (TypeError, ValueError) as error:
        raise ServiceError(503, "QWEN_CONTEXT_MISMATCH", "Qwen lifecycle returned an invalid context size") from error
    if context < 131072:
        raise ServiceError(503, "QWEN_CONTEXT_MISMATCH", f"Qwen lifecycle reported only {context} context tokens")
    return bool(state.get("started_by_request"))


def specialist_translate(segments: list[dict[str, Any]], job_dir: Path) -> dict[str, Any]:
    input_path = job_dir / "specialist-input.json"
    output_path = job_dir / "specialist-output.json"
    input_path.write_text(json.dumps({"segments": segments}, ensure_ascii=False), encoding="utf-8")
    python = os.environ.get("KOHARU_SPECIALIST_PYTHON", "").strip() or sys.executable
    if not Path(python).is_file():
        raise ServiceError(503, "SPECIALIST_RUNTIME_MISSING", f"specialist Python is missing: {python}")
    completed = run_managed_process(
        [python, str(SPECIALIST), str(input_path), str(output_path)],
        cwd=ROOT,
        timeout=900,
        phase="hy_mt2",
    )
    if completed.returncode != 0 or not output_path.is_file():
        detail = (completed.stderr or completed.stdout).strip()[-2000:]
        raise ServiceError(502, "SPECIALIST_FAILED", detail or "Hy-MT2 worker failed")
    return json.loads(output_path.read_text(encoding="utf-8"))


def result_schema(count: int) -> dict[str, Any]:
    return {
        "type": "object", "properties": {"results": {"type": "array", "minItems": count, "maxItems": count, "items": {
            "type": "object", "properties": {
                "id": {"type": "integer", "minimum": 0, "maximum": max(0, count - 1)},
                "final_translation": {"type": "string", "minLength": 1, "maxLength": 1024},
                "status": {"type": "string", "enum": STATUSES},
                "issues": {"type": "array", "minItems": 1, "uniqueItems": True, "items": {"type": "string", "enum": ISSUES}},
                "confidence": {"type": "string", "enum": ["high", "medium", "low"]},
                "semantic_role": {"type": "string", "enum": ROLES},
                "font_role": {"type": "string", "enum": FONTS},
            }, "required": ["id", "final_translation", "status", "issues", "confidence", "semantic_role", "font_role"], "additionalProperties": False,
        }}}, "required": ["results"], "additionalProperties": False,
    }


def sparse_review_schema(count: int) -> dict[str, Any]:
    return {
        "type": "object", "properties": {"defects": {"type": "array", "minItems": 0, "maxItems": count, "items": {
            "type": "object", "properties": {
                "id": {"type": "integer", "minimum": 0, "maximum": max(0, count - 1)},
                "final_translation": {"type": "string", "minLength": 1, "maxLength": 1024},
                "status": {"type": "string", "enum": STATUSES},
                "issues": {"type": "array", "minItems": 1, "uniqueItems": True, "items": {"type": "string", "enum": [issue for issue in ISSUES if issue != "none"]}},
                "confidence": {"type": "string", "enum": ["high", "medium", "low"]},
                "semantic_role": {"type": "string", "enum": ROLES},
                "font_role": {"type": "string", "enum": FONTS},
            }, "required": ["id", "final_translation", "status", "issues", "confidence", "semantic_role", "font_role"], "additionalProperties": False,
        }}}, "required": ["defects"], "additionalProperties": False,
    }


def qwen_json_items(payload: dict[str, Any], key: str, invalid_message: str) -> list[dict[str, Any]]:
    last_code = "QWEN_INVALID_JSON"
    last_message = invalid_message
    for _attempt in range(2):
        try:
            response = post_json(f"{qwen_api()}/chat/completions", payload)
        except (OSError, ValueError, urllib.error.URLError) as error:
            last_code = "QWEN_REQUEST_FAILED"
            last_message = f"Qwen request failed: {type(error).__name__}"
            time.sleep(2.0)
            continue
        choice = (response.get("choices") or [{}])[0]
        content = str((choice.get("message") or {}).get("content", "")).strip()
        content = re.sub(r"^```(?:json)?\s*|\s*```$", "", content, flags=re.IGNORECASE)
        try:
            return json.loads(content)[key]
        except (ValueError, KeyError, TypeError):
            last_code = "QWEN_INVALID_JSON"
            last_message = (
                f"{invalid_message} (finish_reason={choice.get('finish_reason')}, "
                f"content_chars={len(content)}, max_tokens={payload.get('max_tokens')})"
            )
            continue
    raise ServiceError(502, last_code, last_message)


def qwen_complete(system: str, user: dict[str, Any], count: int, schema_name: str) -> list[dict[str, Any]]:
    payload = {
        "model": qwen_model(),
        "messages": [{"role": "system", "content": system}, {"role": "user", "content": json.dumps(user, ensure_ascii=False)}],
        "temperature": 0,
        "top_p": 1,
        "reasoning_effort": "none",
        "max_tokens": min(16384, max(2048, count * 256)),
        "response_format": {"type": "json_schema", "json_schema": {"name": schema_name, "strict": True, "schema": result_schema(count)}},
    }
    results = qwen_json_items(payload, "results", "Qwen returned invalid review JSON")
    if len(results) != count or sorted(item.get("id") for item in results) != list(range(count)):
        raise ServiceError(502, "QWEN_ID_COVERAGE", "Qwen review did not preserve exact ID coverage")
    return sorted(results, key=lambda item: item["id"])


def qwen_sparse_complete(system: str, user: dict[str, Any], count: int) -> list[dict[str, Any]]:
    payload = {
        "model": qwen_model(),
        "messages": [{"role": "system", "content": system}, {"role": "user", "content": json.dumps(user, ensure_ascii=False)}],
        "temperature": 0,
        "top_p": 1,
        "reasoning_effort": "none",
        "max_tokens": min(8192, max(2048, count * 256)),
        "response_format": {"type": "json_schema", "json_schema": {"name": "koharu_manga_sparse_review", "strict": True, "schema": sparse_review_schema(count)}},
    }
    results = qwen_json_items(payload, "defects", "Qwen returned invalid sparse review JSON")
    ids = [item.get("id") for item in results]
    if len(results) > count or any(not isinstance(item, int) or item < 0 or item >= count for item in ids) or len(set(ids)) != len(ids):
        raise ServiceError(502, "QWEN_ID_COVERAGE", "Qwen sparse review returned invalid IDs")
    return sorted(results, key=lambda item: item["id"])


def update_request_progress(phase: str, percent: int, detail: str) -> None:
    control: RequestControl | None = getattr(REQUEST_LOCAL, "control", None)
    if control is not None:
        control.update(phase, percent, detail)


def wait_cancellable(seconds: float, phase: str, percent: int, detail: str) -> None:
    update_request_progress(phase, percent, detail)
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        control: RequestControl | None = getattr(REQUEST_LOCAL, "control", None)
        if control is not None and control.cancel.wait(timeout=min(0.1, max(0.0, deadline - time.monotonic()))):
            raise ServiceError(409, "REQUEST_CANCELLED", f"translation cancelled during {phase}")


def defects(item: dict[str, Any], first_translation: str | None = None) -> list[str]:
    text = str(item.get("final_translation", "")).strip()
    status = item.get("status")
    issues = item.get("issues")
    found: list[str] = []
    if not text:
        found.append("empty")
    if JAPANESE.search(text):
        found.append("source_residual")
    if PLACEHOLDER.search(text) and not (status == "ignored_with_reason" and issues == ["nonlinguistic_symbol"]):
        found.append("placeholder")
    if status not in STATUSES:
        found.append("unresolved_status")
    elif status == "failed":
        found.append("failed")
    if item.get("confidence") == "low":
        found.append("low_confidence")
    if not isinstance(issues, list) or not issues:
        found.append("review_metadata")
    elif "none" in issues and (len(issues) != 1 or (first_translation is not None and text != first_translation)):
        found.append("review_metadata")
    role = item.get("semantic_role")
    if role not in ROLE_FONTS or item.get("font_role") not in ROLE_FONTS[role]:
        found.append("role_font_mismatch")
    return found


BLOCKING_DEFECTS = {"empty", "placeholder", "unresolved_status"}


def blocking_defects(defect_list: list[str]) -> list[str]:
    return [defect for defect in defect_list if defect in BLOCKING_DEFECTS]


def normalize_nonlinguistic(item: dict[str, Any], source: str, layer_context: dict[str, Any]) -> None:
    if not CHECKBOX_BLOCK.fullmatch(source.strip()):
        return
    item.update({
        "final_translation": source,
        "status": "ignored_with_reason",
        "issues": ["nonlinguistic_symbol"],
        "confidence": "high",
        **default_lettering(layer_context),
    })


def review(first: list[dict[str, Any]], source: list[dict[str, Any]], context: Any, layer_context: list[dict[str, Any]] | None = None) -> list[dict[str, Any]]:
    first_by_id = {item["id"]: item["text"] for item in first}
    layer_context = layer_context or [{} for _ in source]
    if len(layer_context) != len(source):
        raise ServiceError(400, "LAYER_CONTEXT_COVERAGE", "Koharu layer context must match source coverage")
    regions = [{"id": item["id"], "source": item["text"], "first_translation": first_by_id[item["id"]], **layer_context[item["id"]], **default_lettering(layer_context[item["id"]])} for item in source]
    system = """You are the mandatory independent Korean manga reviewer and typesetting-role planner. Inspect every Japanese source against its untrusted Hy-MT2 draft and supplied Koharu role/default lettering. Preserve explicit meaning, names, honorifics, voice, emotion, and sound effects. Omit an ID from defects only when its draft and default lettering are clean and can be kept byte-for-byte unchanged. Return an ID only when a translation, confidence, semantic-role, or font correction is needed, and include at least one real issue. Return lettering only in final_translation. Never preserve Japanese residue or placeholders. Preserve a block consisting only of checkbox symbols unchanged as ignored_with_reason with issue nonlinguistic_symbol. If OCR is materially ambiguous, return failed with low confidence. Return only the sparse defects array as strict JSON; do not return clean IDs."""
    reviewed = []
    for offset in range(0, len(regions), QWEN_REVIEW_CHUNK):
        update_request_progress(
            "qwen_review",
            60 + int(18 * offset / max(1, len(regions))),
            f"Qwen review {min(offset + QWEN_REVIEW_CHUNK, len(regions))}/{len(regions)} regions",
        )
        chunk = [{**item, "id": local_id} for local_id, item in enumerate(regions[offset:offset + QWEN_REVIEW_CHUNK])]
        font_policy = {
            role: ROLE_DEFAULTS[role] if len(ROLE_FONTS[role]) == 1 else sorted(ROLE_FONTS[role])
            for role in ROLES
        }
        chunk_review = qwen_sparse_complete(system, {"source_language": "ja-JP", "target_language": "ko-KR", "context": context, "regions": chunk, "font_policy": font_policy}, len(chunk))
        defects_by_id = {item["id"]: item for item in chunk_review}
        for local_id, region in enumerate(chunk):
            item = {
                "id": offset + local_id,
                "final_translation": region["first_translation"],
                "status": "translated",
                "issues": ["none"],
                "confidence": "high",
                "semantic_role": region["semantic_role"],
                "font_role": region["font_role"],
                **(defects_by_id.get(local_id) or {}),
            }
            item["id"] = offset + local_id
            reviewed.append(item)
    for index, item in enumerate(reviewed):
        normalize_nonlinguistic(item, source[index]["text"], layer_context[index])
        enforce_koharu_role(item, layer_context[index])
    targets = [
        (index, item, defects(item, first_by_id[index]))
        for index, item in enumerate(reviewed)
        if defects(item, first_by_id[index])
    ]
    if targets:
        repair_regions = [{"id": repair_id, "source": source[index]["text"], "first_translation": first_by_id[index], "rejected_translation": item["final_translation"], "validator_defects": found, **layer_context[index]} for repair_id, (index, item, found) in enumerate(targets)]
        repair_system = """This is the single allowed targeted repair. Change only the listed defective regions and fix every validator defect without changing supported meaning. When validator_defects contains review_metadata or role_font_mismatch, preserve rejected_translation byte-for-byte and correct only issues/status/confidence/semantic_role/font_role. A translation different from first_translation must never use issues [\"none\"]. Enforce the supplied role-font policy exactly. Return translated with high or medium confidence only when the result is defensible; otherwise keep failed/low. Return each repair ID exactly once as strict JSON. No second repair is allowed."""
        repairs = []
        for offset in range(0, len(repair_regions), QWEN_REVIEW_CHUNK):
            update_request_progress(
                "qwen_repair",
                80 + int(8 * offset / max(1, len(repair_regions))),
                f"Qwen targeted repair {min(offset + QWEN_REVIEW_CHUNK, len(repair_regions))}/{len(repair_regions)} regions",
            )
            chunk = [{**item, "id": local_id} for local_id, item in enumerate(repair_regions[offset:offset + QWEN_REVIEW_CHUNK])]
            chunk_repairs = qwen_complete(
                repair_system,
                {
                    "source_language": "ja-JP",
                    "target_language": "ko-KR",
                    "context": context,
                    "role_font_policy": {key: sorted(value) for key, value in ROLE_FONTS.items()},
                    "regions": chunk,
                },
                len(chunk),
                "koharu_manga_targeted_repair",
            )
            for item in chunk_repairs:
                item["id"] += offset
            repairs.extend(chunk_repairs)
        for repair_id, (index, _, _) in enumerate(targets):
            repaired = repairs[repair_id]
            repaired["id"] = index
            repaired["repair_applied"] = True
            normalize_nonlinguistic(repaired, source[index]["text"], layer_context[index])
            enforce_koharu_role(repaired, layer_context[index])
            reviewed[index] = repaired
    for item in reviewed:
        item.setdefault("repair_applied", False)
        item["validator_defects"] = defects(item, first_by_id[item["id"]])
    return reviewed


@dataclass
class PipelineResult:
    translations: list[dict[str, Any]]
    audit: list[dict[str, Any]]
    specialist_metrics: dict[str, Any]


def run_pipeline(request: dict[str, Any]) -> PipelineResult:
    messages = request.get("messages")
    if not isinstance(messages, list):
        raise ServiceError(400, "INVALID_REQUEST", "messages must be an array")
    user = next((item for item in reversed(messages) if item.get("role") == "user"), None)
    if user is None:
        raise ServiceError(400, "INVALID_REQUEST", "a user message is required")
    content = user.get("content")
    if isinstance(content, list):
        text_part = next((part.get("text") for part in content if part.get("type") == "text"), None)
        content = text_part
    try:
        payload = json.loads(content)
    except (TypeError, ValueError) as error:
        raise ServiceError(400, "INVALID_KOHARU_PAYLOAD", "user content must be Koharu translation JSON") from error
    input_segments = payload.get("segments")
    if not isinstance(input_segments, list) or not input_segments:
        raise ServiceError(400, "INVALID_KOHARU_PAYLOAD", "segments must be a non-empty array")
    segments = sorted([{"id": int(item["id"]), "text": str(item["text"])} for item in input_segments], key=lambda item: item["id"])
    if [item["id"] for item in segments] != list(range(len(segments))):
        raise ServiceError(400, "INVALID_ID_COVERAGE", "input IDs must be contiguous and unique")
    metadata = request.get("metadata") or {}
    region_ids = metadata.get("koharu_region_ids")
    if not isinstance(region_ids, list) or len(region_ids) != len(segments):
        raise ServiceError(400, "MISSING_REGION_IDS", "Koharu region metadata must match segment count")
    page_id = metadata.get("koharu_page_id")
    if not GPU_LOCK.acquire(blocking=False):
        running = active_request()
        detail = running.snapshot() if running is not None else {}
        raise ServiceError(409, "PIPELINE_BUSY", f"another translation request is active: {detail}")

    job_id = str(uuid.uuid4())
    control: RequestControl | None = None
    lease: QwenUseLease | None = None
    result: PipelineResult | None = None
    primary_error: Exception | None = None
    primary_traceback = None
    cleanup_errors: list[Exception] = []
    try:
        control = RequestControl(job_id, page_id=str(page_id))
        set_active_request(control)
        REQUEST_LOCAL.control = control

        control.update("qwen_lease", 3, "reserving the shared Qwen worker")
        lease = QwenUseLease()
        lease.__enter__()
        control.update("koharu_context", 6, "loading the current Koharu text layers")
        layer_context = request_layer_context(metadata, [str(item) for item in region_ids])
        durable_job = ROOT / "run" / "reviews" / job_id
        durable_job.mkdir(parents=True, exist_ok=False)

        control.update("hy_mt2", 10, f"Hy-MT2 first pass for {len(segments)} regions")
        specialist = specialist_translate(segments, durable_job)
        first = specialist.get("translations", [])
        if len(first) != len(segments):
            raise ServiceError(502, "SPECIALIST_ID_COVERAGE", "Hy-MT2 did not preserve exact ID coverage")

        control.update("qwen_start", 45, "starting or reusing the exact shared Qwen reviewer")
        start_or_reuse_qwen()
        if not wait_for_qwen_stable():
            raise ServiceError(503, "QWEN_NOT_STABLE", "Qwen did not pass two consecutive readiness checks within the bounded startup window")

        control.update("qwen_review", 60, f"reviewing {len(segments)} translated regions")
        reviewed = review(first, segments, payload.get("context", []), layer_context)
        control.update("audit", 90, "writing the review audit")
        audit = []
        first_by_id = {item["id"]: item["text"] for item in first}
        for item in reviewed:
            index = item["id"]
            audit.append({
                "schema_version": 1, "job_id": job_id, "page_id": page_id, "region_id": region_ids[index],
                "source": segments[index]["text"], "first_translation": first_by_id[index],
                "final_translation": item["final_translation"], "status": item["status"], "issues": item["issues"],
                "repair_applied": item["repair_applied"], "repair_passes": 1 if item["repair_applied"] else 0,
                "confidence": item["confidence"], "semantic_role": item["semantic_role"], "font_role": item["font_role"],
                "validator_defects": item["validator_defects"],
                "review_required": item["status"] == "failed" or bool(item["validator_defects"]),
                "blocking_defects": blocking_defects(item["validator_defects"]),
            })
        audit_path = durable_job / "review.jsonl"
        audit_path.write_text("".join(json.dumps(item, ensure_ascii=False, separators=(",", ":")) + "\n" for item in audit), encoding="utf-8")
        failures = [item for item in audit if item["blocking_defects"]]
        if failures:
            raise ServiceError(422, "UNRESOLVED_TRANSLATION", f"{len(failures)} region(s) remain unusable; audit={audit_path}")

        control.update("typography", 94, "applying reviewed typography")
        apply_typography(str(page_id), audit)
        translations = [{"id": item["id"], "text": item["final_translation"]} for item in reviewed]
        metrics = {key: value for key, value in specialist.items() if key != "translations"}
        control.update("complete", 100, "translation and review complete")
        result = PipelineResult(translations, audit, metrics)
    except Exception as error:
        primary_error = error
        primary_traceback = error.__traceback__
    finally:
        if control is not None:
            if active_request() is control:
                set_active_request(None)
            try:
                control.close()
            except Exception as error:
                cleanup_errors.append(error)
        if lease is not None and lease.owned:
            try:
                lease.release()
            except Exception as error:
                cleanup_errors.append(error)
        if hasattr(REQUEST_LOCAL, "control"):
            del REQUEST_LOCAL.control
        GPU_LOCK.release()

    if primary_error is not None:
        for cleanup_error in cleanup_errors:
            primary_error.add_note(f"cleanup failure: {type(cleanup_error).__name__}: {cleanup_error}")
        raise primary_error.with_traceback(primary_traceback)
    if cleanup_errors:
        first_cleanup = cleanup_errors[0]
        for cleanup_error in cleanup_errors[1:]:
            first_cleanup.add_note(f"additional cleanup failure: {type(cleanup_error).__name__}: {cleanup_error}")
        raise first_cleanup
    if result is None:
        raise ServiceError(500, "PIPELINE_RESULT_MISSING", "translation finished without a result")
    return result


class Handler(BaseHTTPRequestHandler):
    server_version = "KoharuMangaPipeline/1"
    protocol_version = "HTTP/1.1"

    def send_json(self, status: int, value: dict[str, Any]) -> None:
        body = json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.send_header("content-type", "application/json; charset=utf-8")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
        self.wfile.flush()

    def do_GET(self) -> None:
        if self.path == "/health":
            specialist_model = Path(os.environ.get("KOHARU_HY_MODEL_PATH", ROOT / "models" / "hy-mt2-7b"))
            self.send_json(200, {
                "status": "ok", "model": MODEL, "gpu_serialized": True,
                "qwen_reasoning": "off", "qwen_context": 131072,
                "specialist_model_ready": (specialist_model / "download-manifest.json").is_file(),
                "koharu_api": KOHARU_API,
                "qwen_api": qwen_api(),
                "qwen_lease_configured": bool(os.environ.get("KOHARU_QWEN_LEASE_PATH", "").strip()),
                "child_cleanup": "windows_job_object",
            })
        elif self.path == "/status":
            running = active_request()
            self.send_json(200, {
                "status": "busy" if running is not None else "idle",
                "active": running.snapshot() if running is not None else None,
            })
        elif self.path == "/v1/models":
            self.send_json(200, {"object": "list", "data": [{"id": MODEL, "object": "model", "owned_by": "local"}]})
        else:
            self.send_json(404, {"error": {"code": "NOT_FOUND", "message": "not found"}})

    def do_POST(self) -> None:
        if self.path == "/control/cancel":
            running = active_request()
            if running is None:
                self.send_json(409, {"error": {"code": "NO_ACTIVE_REQUEST", "message": "no translation request is active"}})
                return
            running.request_cancel()
            self.send_json(202, {"status": "cancelling", "active": running.snapshot()})
            return
        if self.path != "/v1/chat/completions":
            self.send_json(404, {"error": {"code": "NOT_FOUND", "message": "not found"}})
            return
        try:
            length = int(self.headers.get("content-length", "0"))
            request = json.loads(self.rfile.read(length).decode("utf-8"))
            result = run_pipeline(request)
            content = json.dumps({"translations": result.translations}, ensure_ascii=False, separators=(",", ":"))
            self.send_json(200, {"id": f"chatcmpl-{uuid.uuid4().hex}", "object": "chat.completion", "created": int(time.time()), "model": MODEL, "choices": [{"index": 0, "message": {"role": "assistant", "content": content}, "finish_reason": "stop"}], "usage": {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0}})
        except ServiceError as error:
            message = service_error_message(error)
            failure_path = ROOT / "run" / "service-failures.jsonl"
            failure_path.parent.mkdir(parents=True, exist_ok=True)
            with failure_path.open("a", encoding="utf-8") as stream:
                stream.write(json.dumps({"timestamp": time.time(), "status": error.status, "code": error.code, "message": message}, ensure_ascii=False, separators=(",", ":")) + "\n")
            self.send_json(error.status, {"error": {"code": error.code, "message": message}})
        except Exception as error:  # fail closed at the HTTP boundary
            error_path = ROOT / "run" / "service-errors.log"
            error_path.parent.mkdir(parents=True, exist_ok=True)
            with error_path.open("a", encoding="utf-8") as stream:
                stream.write(f"{time.time()} {traceback.format_exc()}\n")
            self.send_json(500, {"error": {"code": "INTERNAL_ERROR", "message": str(error)[:1000]}})

    def log_message(self, format: str, *args: object) -> None:
        try:
            print(f"{self.log_date_time_string()} {format % args}", flush=True)
        except (OSError, ValueError):
            # Start-Process can close its inherited redirected stdout handle after
            # the launcher exits. Request handling must remain independent of it.
            pass


def main() -> None:
    parser = argparse.ArgumentParser(description="Independent Koharu manga translation sidecar")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=4020)
    args = parser.parse_args()
    if args.host not in {"127.0.0.1", "localhost", "::1"}:
        raise SystemExit("only loopback hosts are permitted")
    server = ThreadingHTTPServer((args.host, args.port), Handler)
    print(json.dumps({"status": "ready", "url": f"http://{args.host}:{args.port}/v1", "model": MODEL}), flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
