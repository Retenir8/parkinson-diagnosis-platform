"""Launch and monitor the byte-identical MATLAB Shoes implementation."""

from __future__ import annotations

import csv
import io
import json
import os
import re
import shutil
import subprocess
import threading
import time
from pathlib import Path
from uuid import uuid4

from app.core.config import get_settings


SYSTEM_ROOT = Path(__file__).resolve().parents[3]
REFERENCE_ROOT = SYSTEM_ROOT / "integrations" / "shoes_reference"
BRIDGE_ROOT = SYSTEM_ROOT / "integrations" / "shoes_bridge"
SESSION_ID = re.compile(r"^\d{8}_\d{6}_\d{3}$")
COMMANDS = frozenset({
    "start_time_alignment", "start_unloaded", "start_worn",
    "start_recording", "stop_recording", "shutdown",
})


def _tail_csv_rows(path: Path, limit: int = 100) -> list[dict[str, str]]:
    """Read complete tail rows while a MATLAB CSV is being appended."""
    if not path.is_file() or path.stat().st_size == 0:
        return []
    with path.open("rb") as stream:
        header = stream.readline().decode("utf-8-sig", "replace").strip()
        if not header:
            return []
        size = stream.seek(0, os.SEEK_END)
        stream.seek(max(0, size - 128 * 1024))
        chunk = stream.read().decode("utf-8", "replace")
    columns = next(csv.reader([header]))
    if size > 128 * 1024:
        first_newline = chunk.find("\n")
        chunk = chunk[first_newline + 1:] if first_newline >= 0 else ""
    if not chunk.endswith("\n"):
        last_newline = chunk.rfind("\n")
        chunk = chunk[:last_newline + 1] if last_newline >= 0 else ""
    parsed: list[dict[str, str]] = []
    for values in csv.reader(io.StringIO(chunk)):
        if len(columns) == len(values):
            if values == columns:
                continue
            parsed.append(dict(zip(columns, values)))
    return parsed[-limit:]


def _last_csv_row(path: Path) -> dict[str, str] | None:
    tail = _tail_csv_rows(path, 1)
    return tail[-1] if tail else None


def _session_file(directory: Path, prefix: str) -> Path | None:
    return next(iter(sorted(directory.glob(prefix + "_*.csv"))), None)


class ShoesRuntime:
    def __init__(self) -> None:
        self._lock = threading.RLock()
        self._process: subprocess.Popen | None = None
        self._started_at = 0.0
        self._session_stamp: str | None = None
        self._engine = "compiled-matlab" if os.getenv("MEDVISION_SHOES_EXECUTABLE") else "matlab"

    @property
    def command_dir(self) -> Path:
        return get_settings().data_dir / "shoes_runtime" / "commands"

    def start(self) -> dict:
        with self._lock:
            if self._process and self._process.poll() is None:
                raise RuntimeError("Shoes 采集会话已在运行。")
            compiled = os.getenv("MEDVISION_SHOES_EXECUTABLE")
            matlab = None if compiled else os.getenv("MEDVISION_MATLAB_EXECUTABLE") or shutil.which("matlab")
            if compiled and not Path(compiled).is_file():
                raise RuntimeError("Shoes 编译程序不存在，请检查 MEDVISION_SHOES_EXECUTABLE。")
            if not compiled and (not matlab or not Path(matlab).is_file()):
                raise RuntimeError("未找到 Shoes 编译程序或 MATLAB。请配置 MEDVISION_SHOES_EXECUTABLE 或 MEDVISION_MATLAB_EXECUTABLE。")
            if not compiled and not (REFERENCE_ROOT / "runMqttGaitLowLatency.m").is_file():
                raise RuntimeError("System 内缺少 Shoes 源码副本。")
            self.command_dir.mkdir(parents=True, exist_ok=True)
            log_path = get_settings().data_dir / "shoes_runtime" / "matlab_console.log"
            log_path.parent.mkdir(parents=True, exist_ok=True)
            if compiled:
                command = [compiled, str(self.command_dir)]
                environment = os.environ.copy()
                environment["MEDVISION_SHOES_LOG_ROOT"] = str(
                    get_settings().data_dir / "shoes_archive" / "log"
                )
                self._engine = "compiled-matlab"
            else:
                bridge = str(BRIDGE_ROOT).replace("'", "''")
                command_path = str(self.command_dir).replace("'", "''")
                expression = (
                    f"try, addpath('{bridge}'); runShoesFromSystem('{command_path}'); "
                    "catch ME, disp(getReport(ME, 'extended')); exit(1); end; exit(0)"
                )
                command = [matlab, "-wait", "-nosplash", "-r", expression]
                environment = os.environ.copy()
                self._engine = "matlab"
            with log_path.open("ab") as output:
                self._process = subprocess.Popen(
                    command,
                    cwd=Path(compiled).parent if compiled else REFERENCE_ROOT,
                    stdout=output,
                    stderr=subprocess.STDOUT,
                    stdin=subprocess.DEVNULL,
                    env=environment,
                )
            self._started_at = time.time()
            self._session_stamp = None
            return self.status()

    def command(self, value: str) -> dict:
        if value not in COMMANDS:
            raise ValueError("未知 Shoes 控制命令。")
        with self._lock:
            if not self._process or self._process.poll() is not None:
                raise RuntimeError("Shoes MATLAB 会话未运行。")
            self.command_dir.mkdir(parents=True, exist_ok=True)
            payload = {"command": value, "queued_at": time.time()}
            path = self.command_dir / f"{time.time_ns():020d}_{uuid4().hex}.json"
            temporary = path.with_suffix(".tmp")
            temporary.write_text(json.dumps(payload), encoding="utf-8")
            temporary.replace(path)
            return {"queued": value, "status": self.status()}

    def _current_session(self) -> Path | None:
        log_root = (
            get_settings().data_dir / "shoes_archive" / "log"
            if self._engine == "compiled-matlab"
            else REFERENCE_ROOT / "log"
        )
        if self._session_stamp:
            path = log_root / self._session_stamp
            if path.is_dir():
                return path
        if not log_root.is_dir():
            return None
        candidates = [
            path for path in log_root.iterdir()
            if path.is_dir() and SESSION_ID.fullmatch(path.name)
            and path.stat().st_mtime >= self._started_at - 3
        ]
        if not candidates:
            return None
        latest = max(candidates, key=lambda path: path.stat().st_mtime)
        self._session_stamp = latest.name
        return latest

    def status(self) -> dict:
        with self._lock:
            active = self._process is not None and self._process.poll() is None
            session = self._current_session() if self._started_at else None
            result: dict = {
                "running": active,
                "engine": self._engine,
                "pid": self._process.pid if active and self._process else None,
                "exit_code": self._process.poll() if self._process and not active else None,
                "session_stamp": session.name if session else None,
                "phase": "starting" if active else "stopped",
                "latest_gait": None,
                "latest_gait_by_foot": {},
                "pressure_history_by_foot": {"left": [], "right": []},
                "latest_step": None,
                "step_history": [],
                "latest_trajectory": None,
                "trajectory_history": [],
                "imu_history_by_foot": {"left": [], "right": []},
                "alignment": None,
            }
            if session:
                lookup = {
                    "latest_gait": "gait_state",
                    "latest_step": "step_metrics",
                    "latest_trajectory": "trajectory_state",
                    "alignment": "time_alignment",
                }
                for key, prefix in lookup.items():
                    file = _session_file(session, prefix)
                    if file:
                        tail = _tail_csv_rows(file, 500 if key == "latest_gait" else 150)
                        result[key] = tail[-1] if tail else None
                        if key == "latest_gait":
                            for row in tail:
                                foot = row.get("foot")
                                if foot in {"left", "right"}:
                                    result["pressure_history_by_foot"][foot].append({
                                        key: row.get(key, "")
                                        for key in ("t", "total", "COPyNorm", "contact")
                                    })
                            for row in reversed(tail):
                                foot = row.get("foot")
                                if foot in {"left", "right"} and foot not in result["latest_gait_by_foot"]:
                                    result["latest_gait_by_foot"][foot] = row
                        elif key == "latest_step":
                            result["step_history"] = [{
                                field: row.get(field, "")
                                for field in ("t", "foot", "foot_step_count", "step_length_m", "step_frequency_spm", "step_speed_mps")
                            } for row in tail[-100:]]
                        elif key == "latest_trajectory":
                            result["trajectory_history"] = [{
                                field: row.get(field, "")
                                for field in ("t", "left_pos_x", "left_pos_y", "left_pos_z", "right_pos_x", "right_pos_y", "right_pos_z")
                            } for row in tail]
                imu_file = _session_file(session, "imu_decoded")
                if imu_file:
                    for row in _tail_csv_rows(imu_file, 500):
                        foot = row.get("foot")
                        if foot in {"left", "right"}:
                            result["imu_history_by_foot"][foot].append({
                                field: row.get(field, "")
                                for field in ("t", "accX_g", "accY_g", "accZ_g")
                            })
                calibration = _session_file(session, "calibration")
                last_event = _last_csv_row(calibration) if calibration else None
                if last_event:
                    result["phase"] = last_event.get("event", result["phase"])
                elif result["latest_gait"]:
                    result["phase"] = "recording"
            return result


runtime = ShoesRuntime()


def session_directory(stamp: str) -> Path:
    if not SESSION_ID.fullmatch(stamp):
        raise ValueError("Shoes 会话编号格式不正确。")
    archived = get_settings().data_dir / "shoes_archive" / "log" / stamp
    if archived.is_dir():
        return archived
    active = REFERENCE_ROOT / "log" / stamp
    if active.is_dir():
        return active
    raise FileNotFoundError(stamp)


def list_sessions() -> list[dict]:
    roots = (
        get_settings().data_dir / "shoes_archive" / "log",
        REFERENCE_ROOT / "log",
    )
    sessions: dict[str, dict] = {}
    current = runtime.status()
    for root in roots:
        if not root.is_dir():
            continue
        for path in root.iterdir():
            if path.is_dir() and SESSION_ID.fullmatch(path.name):
                sessions[path.name] = {
                    "session_stamp": path.name,
                    "file_count": sum(child.suffix.lower() in {".csv", ".txt"} for child in path.iterdir()),
                    "active": current["session_stamp"] == path.name and current["running"],
                }
    return sorted(sessions.values(), key=lambda item: item["session_stamp"], reverse=True)
