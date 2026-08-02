"""去重存储、生命周期清理与本地引用预检测试。"""

from __future__ import annotations

import json
import os
from datetime import datetime, timezone
from pathlib import Path

import pytest

from app.repositories.artifacts import ArtifactRepository
from app.repositories.assessments import AssessmentRepository
from app.repositories.segmentation import SegmentationRepository
from app.schemas.assessments import AssessmentCreate, ModuleRunRecord
from app.schemas.modules import ModuleResult
from app.services import dedup
from app.api.routes.assessments import _local_reference_issue


@pytest.fixture(autouse=True)
def small_dedup_threshold(monkeypatch: pytest.MonkeyPatch):
    """测试中使用小阈值，让任意内容都参与去重。"""
    monkeypatch.setattr(dedup, "DEDUP_MIN_SIZE", 1)


def _make_data(tmp_path: Path, patient_id: str = "p1") -> Path:
    data_dir = tmp_path / "data"
    repo = ArtifactRepository(data_dir)
    repo.artifacts_dir(patient_id).mkdir(parents=True, exist_ok=True)
    return data_dir


def _upload_bytes(
    data_dir: Path, patient_id: str, content: bytes, name: str = "clip.bag"
) -> ArtifactRepository:
    repo = ArtifactRepository(data_dir)
    artifact_id, destination = repo.prepare_upload(patient_id, name)
    destination.write_bytes(content)
    repo.finalize_upload(
        patient_id=patient_id,
        artifact_id=artifact_id,
        module_id="hand-motion",
        input_slot="hand_video",
        original_name=name,
        kind="realsense_bag",
        stored_path=destination,
    )
    return repo


class TestDedupStorage:
    def test_same_content_uploaded_twice_shares_storage(self, tmp_path: Path):
        data_dir = _make_data(tmp_path)
        content = os.urandom(256 * 1024)  # 内容相同、文件名不同

        _upload_bytes(data_dir, "p1", content, "first.bag")
        _upload_bytes(data_dir, "p1", content, "second.bag")

        paths = sorted(
            (data_dir / "patients" / "p1" / "artifacts").glob("*/*.bag")
        )
        first = paths[0]
        second = paths[1]
        # 同一物理文件（inode 相同）→ 硬链接
        assert first.stat().st_ino == second.stat().st_ino
        assert first.read_bytes() == second.read_bytes()

        index = json.loads(
            (data_dir / "content_index.json").read_text(encoding="utf-8")
        )
        assert len(index) == 1
        entry = next(iter(index.values()))
        assert len(entry["paths"]) == 2

    def test_different_content_keeps_own_copy(self, tmp_path: Path):
        data_dir = _make_data(tmp_path)
        _upload_bytes(data_dir, "p1", b"A" * 4096, "a.bag")
        _upload_bytes(data_dir, "p1", b"B" * 4096, "b.bag")

        paths = sorted(
            (data_dir / "patients" / "p1" / "artifacts").glob("*/*.bag"),
            key=lambda p: p.stat().st_size,
        )
        assert paths[0].stat().st_ino != paths[1].stat().st_ino
        index = json.loads(
            (data_dir / "content_index.json").read_text(encoding="utf-8")
        )
        assert len(index) == 2

    def test_delete_artifact_keeps_other_hardlink(self, tmp_path: Path):
        data_dir = _make_data(tmp_path)
        content = os.urandom(64 * 1024)
        _upload_bytes(data_dir, "p1", content, "first.bag")
        repo = _upload_bytes(data_dir, "p1", content, "second.bag")

        artifacts = repo.list("p1")
        second = next(item for item in artifacts if item.original_name == "second.bag")
        first = next(item for item in artifacts if item.original_name == "first.bag")

        repo.delete("p1", second.id)

        # 第二个目录已删除，第一个文件仍然可读（引用计数保护）
        assert not Path(second.stored_path).exists()
        assert Path(first.stored_path).read_bytes() == content
        index = json.loads(
            (data_dir / "content_index.json").read_text(encoding="utf-8")
        )
        entry = next(iter(index.values()))
        assert entry["paths"] == [str(Path(first.stored_path).resolve())]

    def test_delete_last_artifact_removes_index_entry(self, tmp_path: Path):
        data_dir = _make_data(tmp_path)
        content = os.urandom(64 * 1024)
        repo = _upload_bytes(data_dir, "p1", content, "only.bag")
        artifact = repo.list("p1")[0]

        repo.delete("p1", artifact.id)

        index_path = data_dir / "content_index.json"
        index = json.loads(index_path.read_text(encoding="utf-8"))
        assert index == {}


class TestSegmentationCleanup:
    def test_delete_project_removes_archive(self, tmp_path: Path):
        data_dir = tmp_path / "data"
        repo = SegmentationRepository(data_dir)
        project, source_path = repo.prepare_import(
            name="行走测试", original_name="walk.bag",
            source_kind="realsense_bag",
        )
        source_path.write_bytes(os.urandom(32 * 1024))
        repo.deduplicate(source_path)
        preview = Path(project.archive_path) / "preview.webm"
        preview.write_bytes(b"preview")
        repo.mark_ready(
            project.id,
            preview_file="preview.webm",
            duration_s=10.0, preview_duration_s=10.0, fps=30.0,
            width=640, height=480,
        )

        project_dir = Path(project.archive_path)
        assert project_dir.is_dir()

        repo.delete(project.id)

        assert not project_dir.exists()
        with pytest.raises(Exception):
            repo.get(project.id)


class TestClearOutputs:
    def test_clear_outputs_removes_files_and_artifacts(self, tmp_path: Path):
        data_dir = tmp_path / "data"
        repo = AssessmentRepository(data_dir)
        assessment = repo.create(
            AssessmentCreate(
                patient_id="p1",
                module_inputs={"hand-motion": {"hand_video": ["a1"]}},
            ),
            status_detail="排队中",
            module_runs={
                "hand-motion": ModuleRunRecord(
                    module_id="hand-motion",
                    status="queued",
                    status_detail="排队中",
                    inputs={"hand_video": ["a1"]},
                    updated_at=datetime.now(timezone.utc),
                )
            },
        )

        outputs = (
            data_dir / "patients" / "p1" / "assessments"
            / assessment.id / "outputs" / "hand-motion"
        )
        outputs.mkdir(parents=True)
        video = outputs / "clip_annotated.webm"
        video.write_bytes(b"webm-data")
        repo.store_module_result(
            assessment.id,
            "hand-motion",
            ModuleResult(
                module_id="hand-motion",
                summary="完成",
                result_data={
                    "visualization": {
                        "type": "annotated_pose_video",
                        "availability": "ready",
                        "annotated_videos": [
                            {
                                "artifact_index": 0,
                                "media_type": "video/webm",
                            }
                        ],
                    }
                },
                output_artifacts=[str(video)],
            ),
        )

        updated = repo.clear_outputs(assessment.id)

        assert not outputs.exists()
        run = updated.module_runs["hand-motion"]
        assert run.result is not None
        assert run.result.output_artifacts == []
        visualization = run.result.result_data["visualization"]
        assert visualization["availability"] == "unavailable"
        assert visualization["annotated_videos"] == []
        stored_run = json.loads(
            (
                outputs.parent.parent
                / "module_runs"
                / "hand-motion.json"
            ).read_text(encoding="utf-8")
        )
        assert stored_run["result"]["output_artifacts"] == []
        stored_visualization = stored_run["result"]["result_data"][
            "visualization"
        ]
        assert stored_visualization["availability"] == "unavailable"
        assert "已清理" in updated.status_detail

    def test_clear_outputs_rejects_active_assessment(self, tmp_path: Path):
        data_dir = tmp_path / "data"
        repo = AssessmentRepository(data_dir)
        assessment = repo.create(
            AssessmentCreate(
                patient_id="p1",
                module_inputs={"hand-motion": {"hand_video": ["a1"]}},
            ),
            status_detail="排队中",
            module_runs={
                "hand-motion": ModuleRunRecord(
                    module_id="hand-motion",
                    status="running",
                    status_detail="推理中",
                    inputs={"hand_video": ["a1"]},
                    updated_at=datetime.now(timezone.utc),
                )
            },
        )

        with pytest.raises(RuntimeError, match="仍在运行"):
            repo.clear_outputs(assessment.id)

    def test_delete_assessment_removes_record_and_outputs(self, tmp_path: Path):
        data_dir = tmp_path / "data"
        repo = AssessmentRepository(data_dir)
        assessment = repo.create(
            AssessmentCreate(
                patient_id="p1",
                module_inputs={"hand-motion": {"hand_video": ["a1"]}},
            ),
            status_detail="排队中",
            module_runs={
                "hand-motion": ModuleRunRecord(
                    module_id="hand-motion",
                    status="queued",
                    status_detail="排队中",
                    inputs={"hand_video": ["a1"]},
                    updated_at=datetime.now(timezone.utc),
                )
            },
        )
        outputs = (
            data_dir / "patients" / "p1" / "assessments"
            / assessment.id / "outputs" / "hand-motion"
        )
        outputs.mkdir(parents=True)
        (outputs / "clip_annotated.webm").write_bytes(b"webm-data")

        repo.delete(assessment.id)

        assessment_dir = (
            data_dir / "patients" / "p1" / "assessments" / assessment.id
        )
        assert not assessment_dir.exists()
        with pytest.raises(Exception):
            repo.get(assessment.id)
        # 删除后列表中不再出现
        assert repo.list("p1") == []


class TestLocalReferencePrecheck:
    def _artifact(self, stored_path: Path, size: int | None = None):
        from app.schemas.artifacts import Artifact

        return Artifact(
            id="a1", patient_id="p1", module_id="hand-motion",
            input_slot="hand_video", original_name="clip.bag",
            kind="realsense_bag", source_type="local_reference",
            stored_path=str(stored_path),
            size_bytes=size, created_at=datetime.now(timezone.utc),
        )

    def test_available_reference_passes(self, tmp_path: Path):
        file_path = tmp_path / "clip.bag"
        file_path.write_bytes(b"x" * 100)
        artifact = self._artifact(file_path, size=100)
        assert _local_reference_issue(artifact) is None

    def test_missing_file_reported(self, tmp_path: Path):
        missing = tmp_path / "gone.bag"
        artifact = self._artifact(missing, size=100)
        issue = _local_reference_issue(artifact)
        assert issue is not None
        assert "已被移动或删除" in issue

    def test_size_change_reported(self, tmp_path: Path):
        file_path = tmp_path / "clip.bag"
        file_path.write_bytes(b"x" * 200)
        artifact = self._artifact(file_path, size=100)
        issue = _local_reference_issue(artifact)
        assert issue is not None
        assert "已变更" in issue

    def test_uploaded_artifact_skipped(self, tmp_path: Path):
        file_path = tmp_path / "clip.bag"
        file_path.write_bytes(b"x" * 100)
        from app.schemas.artifacts import Artifact

        artifact = Artifact(
            id="a1", patient_id="p1", module_id="hand-motion",
            input_slot="hand_video", original_name="clip.bag",
            kind="realsense_bag", source_type="uploaded",
            stored_path=str(file_path),
            size_bytes=100, created_at=datetime.now(timezone.utc),
        )
        assert _local_reference_issue(artifact) is None
