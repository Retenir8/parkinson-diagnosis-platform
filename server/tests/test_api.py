from __future__ import annotations

from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from app.core.config import get_settings
from app.main import app
from app.repositories.assessments import AssessmentRepository
from app.schemas.modules import ModuleResult


@pytest.fixture()
def client(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> TestClient:
    monkeypatch.setenv("MEDVISION_DATA_DIR", str(tmp_path / "data"))
    get_settings.cache_clear()
    with TestClient(app) as test_client:
        yield test_client
    get_settings.cache_clear()


def test_health_reports_local_data_dir(
    client: TestClient, tmp_path: Path
) -> None:
    response = client.get("/api/v1/health")
    assert response.status_code == 200
    payload = response.json()
    assert payload["status"] == "ok"
    assert Path(payload["data_dir"]) == (tmp_path / "data").resolve()


def test_patient_artifact_and_assessment_flow(
    client: TestClient, tmp_path: Path
) -> None:
    patient_response = client.post(
        "/api/v1/patients",
        json={
            "patient_code": "TEST-001",
            "name": "接口测试",
            "gender": "unknown",
        },
    )
    assert patient_response.status_code == 201
    patient = patient_response.json()

    search_response = client.get(
        "/api/v1/patients", params={"keyword": "TEST-001"}
    )
    assert search_response.status_code == 200
    assert [item["id"] for item in search_response.json()] == [patient["id"]]

    artifact_response = client.post(
        f"/api/v1/patients/{patient['id']}/artifacts/upload",
        data={
            "kind": "video",
            "module_id": "overall-posture",
            "input_slot": "analysis_source",
        },
        files={"file": ("sample.mp4", b"not-a-real-video", "video/mp4")},
    )
    assert artifact_response.status_code == 201
    artifact = artifact_response.json()

    assessment_response = client.post(
        "/api/v1/assessments",
        json={
            "patient_id": patient["id"],
            "module_inputs": {
                "overall-posture": {
                    "analysis_source": [artifact["id"]],
                }
            },
        },
    )
    assert assessment_response.status_code == 201
    assessment = assessment_response.json()
    assert assessment["status"] == "draft"
    assert "固定映射" in assessment["status_detail"]
    assert assessment["module_inputs"]["overall-posture"][
        "analysis_source"
    ] == [artifact["id"]]
    run = assessment["module_runs"]["overall-posture"]
    assert run["status"] == "awaiting_adapter"
    assert run["inputs"] == {"analysis_source": [artifact["id"]]}
    assert run["result"] is None

    detail_response = client.get(
        f"/api/v1/assessments/{assessment['id']}"
    )
    assert detail_response.status_code == 200
    assert detail_response.json()["id"] == assessment["id"]

    repository = AssessmentRepository((tmp_path / "data").resolve())
    with pytest.raises(ValueError, match="does not match"):
        repository.store_module_result(
            assessment["id"],
            "overall-posture",
            ModuleResult(
                module_id="hand-motion",
                summary="不应写入整体姿态结果槽",
            ),
        )
    repository.store_module_result(
        assessment["id"],
        "overall-posture",
        ModuleResult(
            module_id="overall-posture",
            summary="测试模型输出",
            scores={"test_score": 1},
            metrics={"test_metric": 2.5},
        ),
    )
    completed = client.get(
        f"/api/v1/assessments/{assessment['id']}"
    ).json()
    assert completed["status"] == "completed"
    result = completed["module_runs"]["overall-posture"]["result"]
    assert result["summary"] == "测试模型输出"
    assert result["scores"]["test_score"] == 1


def test_rejects_cross_module_artifact_mapping(client: TestClient) -> None:
    patient = client.post(
        "/api/v1/patients",
        json={
            "patient_code": "TEST-002",
            "name": "映射测试",
            "gender": "unknown",
        },
    ).json()
    artifact = client.post(
        f"/api/v1/patients/{patient['id']}/artifacts/upload",
        data={
            "kind": "video",
            "module_id": "hand-motion",
            "input_slot": "hand_video",
        },
        files={"file": ("hand.mp4", b"test", "video/mp4")},
    ).json()

    response = client.post(
        "/api/v1/assessments",
        json={
            "patient_id": patient["id"],
            "module_inputs": {
                "leg-motion": {"leg_video": [artifact["id"]]}
            },
        },
    )
    assert response.status_code == 422
    issues = response.json()["detail"]["input_mapping_issues"]
    assert any("映射不一致" in issue["message"] for issue in issues)


def test_module_descriptors_define_input_slots(client: TestClient) -> None:
    response = client.get("/api/v1/modules")
    assert response.status_code == 200
    modules = {item["id"]: item for item in response.json()}
    assert modules["overall-posture"]["input_slots"][0]["key"] == "analysis_source"
    assert modules["hand-motion"]["input_slots"][0]["key"] == "hand_video"
    assert modules["leg-motion"]["input_slots"][0]["key"] == "leg_video"
    assert modules["smart-insole"]["input_slots"][0]["key"] == "insole_data"
