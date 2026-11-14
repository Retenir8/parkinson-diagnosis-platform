"""End-to-end Shoes session registration and System assessment."""

from __future__ import annotations

from pathlib import Path
import json

import pytest
from fastapi.testclient import TestClient

from app.core.config import get_settings
from app.main import app
from app.services.shoes_runtime import _last_csv_row, runtime
from app.services import shoes_runtime


@pytest.fixture()
def client(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> TestClient:
    monkeypatch.setenv("MEDVISION_DATA_DIR", str(tmp_path / "data"))
    get_settings.cache_clear()
    with TestClient(app) as test_client:
        yield test_client
    get_settings.cache_clear()


def test_archived_shoes_session_runs_as_assessment(client: TestClient, tmp_path: Path) -> None:
    stamp = "20260923_105810_913"
    session = tmp_path / "data" / "shoes_archive" / "log" / stamp
    session.mkdir(parents=True)
    (session / f"gait_state_{stamp}.csv").write_text(
        "t,foot,heelStrike,toeOff,p01\n"
        "1.0,left,1,0,20\n"
        "2.0,right,1,0,30\n",
        encoding="utf-8",
    )
    (session / f"step_metrics_{stamp}.csv").write_text(
        "t,foot,foot_step_count,step_length_m,step_speed_mps\n"
        "1.0,left,1,0.5,0.6\n"
        "2.0,right,1,0.7,0.8\n",
        encoding="utf-8",
    )
    patient = client.post(
        "/api/v1/patients",
        json={"patient_code": "SHOES-001", "name": "测试患者", "gender": "unknown"},
    ).json()
    assert client.get("/api/v1/shoes/runtime").json()["running"] is False
    assert any(item["session_stamp"] == stamp for item in client.get("/api/v1/shoes/sessions").json())
    url = f"/api/v1/shoes/sessions/{stamp}/register"
    response = client.post(url, json={"patient_id": patient["id"]})
    assert response.status_code == 200
    files = response.json()
    assert len(files) == 2
    assert [item["id"] for item in client.post(url, json={"patient_id": patient["id"]}).json()] == [item["id"] for item in files]

    created = client.post(
        "/api/v1/assessments",
        json={"patient_id": patient["id"], "module_inputs": {
            "smart-insole": {"insole_data": [item["id"] for item in files]}
        }},
    )
    assert created.status_code == 201
    assessment_id = created.json()["id"]
    assert client.post(f"/api/v1/assessments/{assessment_id}/run").status_code == 200
    result = client.get(f"/api/v1/assessments/{assessment_id}").json()["module_runs"]["smart-insole"]
    assert result["status"] == "completed"
    assert result["result"]["metrics"]["left_step_count"] == 1
    assert result["result"]["scores"] == {}
    output = client.get(f"/api/v1/assessments/{assessment_id}/modules/smart-insole/outputs/0")
    assert output.status_code == 200
    assert output.content in [path.read_bytes() for path in session.iterdir()]


def test_session_registration_rejects_traversal(client: TestClient) -> None:
    patient = client.post(
        "/api/v1/patients",
        json={"patient_code": "SHOES-002", "name": "测试患者", "gender": "unknown"},
    ).json()
    response = client.post(
        "/api/v1/shoes/sessions/not-a-stamp/register",
        json={"patient_id": patient["id"]},
    )
    assert response.status_code == 422


def test_runtime_command_queue_uses_bridge_contract(
    client: TestClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    class RunningProcess:
        pid = 12345

        @staticmethod
        def poll() -> None:
            return None

    previous = runtime._process
    try:
        runtime._process = RunningProcess()  # type: ignore[assignment]
        response = client.post("/api/v1/shoes/runtime/commands/start_unloaded")
        assert response.status_code == 200
        queued = list(runtime.command_dir.glob("*.json"))
        assert len(queued) == 1
        assert json.loads(queued[0].read_text("utf-8"))["command"] == "start_unloaded"
        bad = client.post("/api/v1/shoes/runtime/commands/delete_everything")
        assert bad.status_code == 422
    finally:
        runtime._process = previous


def test_runtime_launcher_waits_for_matlab_process(
    client: TestClient, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    matlab = tmp_path / "matlab.exe"
    matlab.write_bytes(b"probe")
    monkeypatch.setattr(shoes_runtime.shutil, "which", lambda _: str(matlab))
    monkeypatch.delenv("MEDVISION_SHOES_EXECUTABLE", raising=False)
    monkeypatch.delenv("MEDVISION_MATLAB_EXECUTABLE", raising=False)
    commands: list[list[str]] = []

    class RunningProcess:
        pid = 24680

        @staticmethod
        def poll() -> None:
            return None

    def fake_popen(command: list[str], **kwargs: object) -> RunningProcess:
        del kwargs
        commands.append(command)
        return RunningProcess()

    monkeypatch.setattr(shoes_runtime.subprocess, "Popen", fake_popen)
    previous = runtime._process
    started_at = runtime._started_at
    stamp = runtime._session_stamp
    try:
        runtime._process = None
        response = client.post("/api/v1/shoes/runtime/start")
        assert response.status_code == 200
        assert commands and commands[0][1:3] == ["-wait", "-nosplash"]
    finally:
        runtime._process = previous
        runtime._started_at = started_at
        runtime._session_stamp = stamp


def test_compiled_shoes_launches_without_matlab_and_uses_data_dir(
    client: TestClient, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    executable = tmp_path / "runShoesFromSystem.exe"
    executable.write_bytes(b"probe")
    monkeypatch.setenv("MEDVISION_SHOES_EXECUTABLE", str(executable))
    monkeypatch.setattr(shoes_runtime.shutil, "which", lambda _: None)
    launched: list[tuple[list[str], dict[str, object]]] = []

    class RunningProcess:
        pid = 24681

        @staticmethod
        def poll() -> None:
            return None

    def fake_popen(command: list[str], **kwargs: object) -> RunningProcess:
        launched.append((command, kwargs))
        return RunningProcess()

    monkeypatch.setattr(shoes_runtime.subprocess, "Popen", fake_popen)
    previous = runtime._process
    started_at = runtime._started_at
    stamp = runtime._session_stamp
    engine = runtime._engine
    try:
        runtime._process = None
        response = client.post("/api/v1/shoes/runtime/start")
        assert response.status_code == 200
        assert response.json()["engine"] == "compiled-matlab"
        command, options = launched[0]
        assert command == [str(executable), str(runtime.command_dir)]
        assert options["cwd"] == executable.parent
        assert options["env"]["MEDVISION_SHOES_LOG_ROOT"] == str(
            get_settings().data_dir / "shoes_archive" / "log"
        )
    finally:
        runtime._process = previous
        runtime._started_at = started_at
        runtime._session_stamp = stamp
        runtime._engine = engine


def test_live_status_reads_complete_multiline_calibration_row(tmp_path: Path) -> None:
    path = tmp_path / "calibration.csv"
    path.write_bytes(b'event,note\nrecording,"line one\nline two"\n')
    assert _last_csv_row(path) == {"event": "recording", "note": "line one\nline two"}
