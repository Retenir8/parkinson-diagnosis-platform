from __future__ import annotations

import json
from datetime import datetime, timezone
from pathlib import Path
from threading import Thread

import pytest
from fastapi.testclient import TestClient

from app.core.config import get_settings
from app.main import app
from app.repositories.assessments import AssessmentRepository
from app.schemas.assessments import AssessmentCreate, ModuleRunRecord
from app.schemas.modules import ModuleResult
from app.services.video_preview import PreviewMetadata


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
            "kind": "realsense_bag",
            "module_id": "overall-posture",
            "input_slot": "walk_source",
        },
        files={"file": ("sample.bag", b"not-a-real-bag", "application/octet-stream")},
    )
    assert artifact_response.status_code == 201
    artifact = artifact_response.json()
    manifest_response = client.post(
        f"/api/v1/patients/{patient['id']}/artifacts/upload",
        data={
            "kind": "tabular",
            "module_id": "overall-posture",
            "input_slot": "segment_manifest",
        },
        files={
            "file": (
                "segments.csv",
                b"segment_id,label,task_type,start_s,end_s\n1,walk_1,walk,0,5\n",
                "text/csv",
            )
        },
    )
    assert manifest_response.status_code == 201
    manifest = manifest_response.json()

    assessment_response = client.post(
        "/api/v1/assessments",
        json={
            "patient_id": patient["id"],
            "module_inputs": {
                "overall-posture": {
                    "walk_source": [artifact["id"]],
                    "segment_manifest": [manifest["id"]],
                }
            },
        },
    )
    assert assessment_response.status_code == 201
    assessment = assessment_response.json()
    assert assessment["status"] == "draft"
    assert "映射" in assessment["status_detail"]
    assert assessment["module_inputs"]["overall-posture"][
        "walk_source"
    ] == [artifact["id"]]
    run = assessment["module_runs"]["overall-posture"]
    assert run["status"] == "queued"
    assert run["inputs"] == {
        "walk_source": [artifact["id"]],
        "segment_manifest": [manifest["id"]],
    }
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
    output_file = tmp_path / "data" / "patients" / patient["id"] / "result.csv"
    output_file.write_text("metric,value\nSP_U,1.0\n", encoding="utf-8")
    repository.store_module_result(
        assessment["id"],
        "overall-posture",
        ModuleResult(
            module_id="overall-posture",
            summary="测试模型输出",
            scores={"test_score": 1, "np3gait_class": 1},
            metrics={"test_metric": 2.5},
            result_data={
                "segments": [
                    {
                        "prediction": {
                            "probabilities": {
                                "0": 0.1,
                                "1": 0.8,
                                "2": 0.1,
                            }
                        }
                    }
                ]
            },
            output_artifacts=[str(output_file.resolve())],
        ),
    )
    completed = client.get(
        f"/api/v1/assessments/{assessment['id']}"
    ).json()
    assert completed["status"] == "completed"
    result = completed["module_runs"]["overall-posture"]["result"]
    assert result["summary"] == "测试模型输出"
    assert result["scores"]["test_score"] == 1

    output_response = client.get(
        f"/api/v1/assessments/{assessment['id']}"
        "/modules/overall-posture/outputs/0"
    )
    assert output_response.status_code == 200
    assert output_response.content.startswith(b"metric,value")

    reports_response = client.get("/api/v1/reports")
    assert reports_response.status_code == 200
    reports = reports_response.json()
    assert [item["assessment_id"] for item in reports] == [assessment["id"]]
    assert reports[0]["severity"]["code"] == "mild"
    assert reports[0]["severity"]["label"] == "帕金森轻度"

    report_detail = client.get(f"/api/v1/reports/{assessment['id']}")
    assert report_detail.status_code == 200
    report_payload = report_detail.json()
    assert report_payload["patient_code"] == "TEST-001"
    assert report_payload["severity"]["confidence"] == pytest.approx(0.8)
    assert (
        report_payload["modules"][0]["result"]["metrics"]["test_metric"]
        == 2.5
    )


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
                "leg-motion": {"toe_tapping_video": [artifact["id"]]}
            },
        },
    )
    assert response.status_code == 422
    issues = response.json()["detail"]["input_mapping_issues"]
    assert any("映射不一致" in issue["message"] for issue in issues)


def test_parallel_module_results_merge_without_data_loss(
    tmp_path: Path,
) -> None:
    data_dir = (tmp_path / "data").resolve()
    repository = AssessmentRepository(data_dir)
    now = datetime.now(timezone.utc)
    inputs = {
        "hand-motion": {"hand_video": ["hand-artifact"]},
        "leg-motion": {
            "toe_tapping_video": ["toe-artifact"],
            "leg_agility_video": ["leg-artifact"],
        },
    }
    runs = {
        module_id: ModuleRunRecord(
            module_id=module_id,
            status="running",
            status_detail="推理中…",
            inputs=slot_inputs,
            updated_at=now,
        )
        for module_id, slot_inputs in inputs.items()
    }
    assessment = repository.create(
        AssessmentCreate(patient_id="parallel-patient", module_inputs=inputs),
        status_detail="并发写入测试",
        module_runs=runs,
    )

    errors: list[Exception] = []

    def store_result(module_id: str) -> None:
        try:
            repository.store_module_result(
                assessment.id,
                module_id,
                ModuleResult(module_id=module_id, summary=module_id),
                merge=False,
            )
        except Exception as error:  # pragma: no cover - assertion below
            errors.append(error)

    workers = [
        Thread(target=store_result, args=(module_id,))
        for module_id in inputs
    ]
    for worker in workers:
        worker.start()
    for worker in workers:
        worker.join()

    assert not errors
    before_merge = repository.get(assessment.id)
    assert all(
        run.result is None for run in before_merge.module_runs.values()
    )

    assessment_dir = (
        data_dir
        / "patients"
        / assessment.patient_id
        / "assessments"
        / assessment.id
    )
    assert (
        assessment_dir / "module_runs" / "hand-motion.json"
    ).is_file()
    assert (
        assessment_dir / "module_runs" / "leg-motion.json"
    ).is_file()

    merged = repository.merge_module_runs(
        assessment.id,
        list(inputs),
    )
    assert merged.status == "completed"
    assert all(
        run.status == "completed" and run.result is not None
        for run in merged.module_runs.values()
    )


def test_module_descriptors_define_input_slots(client: TestClient) -> None:
    response = client.get("/api/v1/modules")
    assert response.status_code == 200
    modules = {item["id"]: item for item in response.json()}
    posture_slots = {
        item["key"] for item in modules["overall-posture"]["input_slots"]
    }
    assert posture_slots == {"walk_source", "segment_manifest"}
    assert modules["overall-posture"]["status"] == "ready"
    assert modules["hand-motion"]["input_slots"][0]["key"] == "hand_video"
    leg_slots = {s["key"] for s in modules["leg-motion"]["input_slots"]}
    assert leg_slots == {"toe_tapping_video", "leg_agility_video"}
    assert modules["smart-insole"]["input_slots"][0]["key"] == "insole_data"


def test_video_segmentation_archive_flow(
    client: TestClient,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    def fake_preview(source_path: Path, preview_path: Path) -> PreviewMetadata:
        assert source_path.name == "walking-test.bag"
        preview_path.write_bytes(b"webm-preview")
        return PreviewMetadata(
            duration_s=12.0,
            preview_duration_s=12.0,
            fps=30.0,
            width=1280,
            height=720,
        )

    monkeypatch.setattr(
        "app.api.routes.segmentation.generate_video_preview",
        fake_preview,
    )

    upload = client.post(
        "/api/v1/segmentation-projects/upload",
        data={"project_name": "步态测试"},
        files={
            "file": (
                "walking-test.bag",
                b"fake-realsense-content",
                "application/octet-stream",
            )
        },
    )
    assert upload.status_code == 201
    project_id = upload.json()["id"]

    detail = client.get(f"/api/v1/segmentation-projects/{project_id}")
    assert detail.status_code == 200
    project = detail.json()
    assert project["status"] == "ready"
    assert project["preview_available"] is True
    assert project["duration_s"] == 12.0

    saved = client.put(
        f"/api/v1/segmentation-projects/{project_id}/segments",
        json={
            "walk_distance_m": 10.0,
            "segments": [
                {
                    "segment_id": "1",
                    "label": "walk_1",
                    "task_type": "walk",
                    "start_s": 0.0,
                    "end_s": 8.5,
                },
                {
                    "segment_id": "2",
                    "label": "turn_1",
                    "task_type": "turn",
                    "start_s": 8.5,
                    "end_s": 10.0,
                },
            ]
        },
    )
    assert saved.status_code == 200
    archive_dir = Path(saved.json()["archive_path"])
    assert (archive_dir / "walking-test.bag").read_bytes() == (
        b"fake-realsense-content"
    )
    assert (archive_dir / "preview.webm").read_bytes() == b"webm-preview"
    assert (archive_dir / "segments.csv").is_file()
    assert (archive_dir / "segments.json").is_file()
    assert (archive_dir / "project.json").is_file()
    segment_json = json.loads(
        (archive_dir / "segments.json").read_text(encoding="utf-8")
    )
    assert segment_json["walk_distance_m"] == 10.0

    preview = client.get(
        f"/api/v1/segmentation-projects/{project_id}/preview"
    )
    assert preview.status_code == 200
    assert preview.content == b"webm-preview"
    preview_range = client.get(
        f"/api/v1/segmentation-projects/{project_id}/preview",
        headers={"Range": "bytes=0-3"},
    )
    assert preview_range.status_code == 206
    assert preview_range.content == b"webm"

    search = client.get(
        "/api/v1/segmentation-projects", params={"keyword": "walk_1"}
    )
    assert search.status_code == 200
    assert [item["id"] for item in search.json()] == [project_id]

    overlap = client.put(
        f"/api/v1/segmentation-projects/{project_id}/segments",
        json={
            "segments": [
                {
                    "segment_id": "1",
                    "label": "walk_1",
                    "task_type": "walk",
                    "start_s": 0,
                    "end_s": 6,
                },
                {
                    "segment_id": "2",
                    "label": "walk_2",
                    "task_type": "walk",
                    "start_s": 5,
                    "end_s": 9,
                },
            ]
        },
    )
    assert overlap.status_code == 422
