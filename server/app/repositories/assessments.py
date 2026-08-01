from __future__ import annotations

from datetime import datetime, timezone
from pathlib import Path
from uuid import uuid4

from app.repositories.json_store import JsonFileStore
from app.schemas.assessments import (
    Assessment,
    AssessmentCreate,
    ModuleRunRecord,
)
from app.schemas.modules import ModuleResult


class AssessmentRepository:
    def __init__(self, data_dir: Path, store: JsonFileStore | None = None) -> None:
        self.root = data_dir / "patients"
        self.store = store or JsonFileStore()

    def create(
        self,
        payload: AssessmentCreate,
        status_detail: str,
        module_runs: dict[str, ModuleRunRecord],
    ) -> Assessment:
        now = datetime.now(timezone.utc)
        assessment = Assessment(
            id=str(uuid4()),
            **payload.model_dump(),
            status="draft",
            status_detail=status_detail,
            module_runs=module_runs,
            created_at=now,
            updated_at=now,
        )
        path = self._path(assessment.patient_id, assessment.id)
        self.store.write(path, assessment.model_dump(mode="json"))
        return assessment

    def list(self, patient_id: str | None = None) -> list[Assessment]:
        pattern = (
            f"{patient_id}/assessments/*/assessment.json"
            if patient_id
            else "*/assessments/*/assessment.json"
        )
        assessments: list[Assessment] = []
        for path in self.root.glob(pattern):
            try:
                assessments.append(
                    Assessment.model_validate(self.store.read(path))
                )
            except (OSError, ValueError):
                continue
        return sorted(
            assessments, key=lambda item: item.created_at, reverse=True
        )

    def get(self, assessment_id: str) -> Assessment:
        matches = list(
            self.root.glob(f"*/assessments/{assessment_id}/assessment.json")
        )
        if not matches:
            raise KeyError(assessment_id)
        return Assessment.model_validate(self.store.read(matches[0]))

    def save(self, assessment: Assessment) -> None:
        assessment.updated_at = datetime.now(timezone.utc)
        self.store.write(
            self._path(assessment.patient_id, assessment.id),
            assessment.model_dump(mode="json"),
        )

    def store_module_result(
        self,
        assessment_id: str,
        module_id: str,
        result: ModuleResult,
        *,
        merge: bool = True,
    ) -> Assessment:
        assessment = self.get(assessment_id)
        if module_id not in assessment.module_runs:
            raise KeyError(
                f"Module {module_id} is not part of assessment {assessment_id}"
            )
        if result.module_id != module_id:
            raise ValueError(
                "ModuleResult.module_id does not match the target module run"
            )

        run = assessment.module_runs[module_id]
        run.status = "completed"
        run.status_detail = "模型已返回结构化结果。"
        run.result = result
        run.updated_at = datetime.now(timezone.utc)
        assessment.module_runs[module_id] = run
        self.save_module_run(
            assessment.patient_id,
            assessment.id,
            run,
        )

        if merge:
            return self.merge_module_runs(assessment_id, [module_id])
        return assessment

    def store_module_failure(
        self,
        assessment_id: str,
        module_id: str,
        status_detail: str,
        *,
        merge: bool = True,
    ) -> Assessment:
        assessment = self.get(assessment_id)
        if module_id not in assessment.module_runs:
            raise KeyError(
                f"Module {module_id} is not part of assessment {assessment_id}"
            )

        run = assessment.module_runs[module_id]
        run.status = "failed"
        run.status_detail = status_detail
        run.result = None
        run.updated_at = datetime.now(timezone.utc)
        assessment.module_runs[module_id] = run
        self.save_module_run(
            assessment.patient_id,
            assessment.id,
            run,
        )

        if merge:
            return self.merge_module_runs(assessment_id, [module_id])
        return assessment

    def save_module_run(
        self,
        patient_id: str,
        assessment_id: str,
        run: ModuleRunRecord,
    ) -> None:
        """Persist one model run without touching the shared assessment JSON."""

        self.store.write(
            self._module_run_path(patient_id, assessment_id, run.module_id),
            run.model_dump(mode="json"),
        )

    def merge_module_runs(
        self,
        assessment_id: str,
        module_ids: list[str],
    ) -> Assessment:
        """Merge completed per-model JSON files into the assessment once."""

        assessment = self.get(assessment_id)
        for module_id in module_ids:
            if module_id not in assessment.module_runs:
                raise KeyError(
                    f"Module {module_id} is not part of assessment {assessment_id}"
                )
            path = self._module_run_path(
                assessment.patient_id,
                assessment.id,
                module_id,
            )
            run = ModuleRunRecord.model_validate(self.store.read(path))
            if run.module_id != module_id:
                raise ValueError(
                    "Stored module run does not match the requested module"
                )
            assessment.module_runs[module_id] = run

        all_runs = list(assessment.module_runs.values())
        active_count = sum(
            run.status in {"queued", "running"} for run in all_runs
        )
        failed_count = sum(run.status == "failed" for run in all_runs)
        completed_count = sum(run.status == "completed" for run in all_runs)
        if active_count:
            assessment.status = "running"
            assessment.status_detail = (
                f"已收到 {completed_count} 个模块结果，"
                f"仍有 {active_count} 个模块等待完成。"
            )
        elif failed_count:
            assessment.status = "failed"
            assessment.status_detail = (
                f"本次推理完成：{completed_count} 个模块成功，"
                f"{failed_count} 个模块失败。"
            )
        elif completed_count:
            assessment.status = "completed"
            assessment.status_detail = (
                f"本次推理的 {completed_count} 个模块均已返回结果。"
            )
        else:
            assessment.status = "running"
            assessment.status_detail = "模型结果尚未全部写入。"

        self.save(assessment)
        return assessment

    def _path(self, patient_id: str, assessment_id: str) -> Path:
        return (
            self.root
            / patient_id
            / "assessments"
            / assessment_id
            / "assessment.json"
        )

    def _module_run_path(
        self,
        patient_id: str,
        assessment_id: str,
        module_id: str,
    ) -> Path:
        return (
            self.root
            / patient_id
            / "assessments"
            / assessment_id
            / "module_runs"
            / f"{module_id}.json"
        )
