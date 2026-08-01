from __future__ import annotations

from pathlib import Path
from statistics import mean
from app.modules.registry import registry
from app.repositories.assessments import AssessmentRepository
from app.repositories.json_store import JsonFileStore
from app.repositories.patients import PatientRepository
from app.schemas.assessments import Assessment
from app.schemas.reports import (
    ReportDetail,
    ReportModule,
    ReportSeverity,
    ReportSummary,
)


class ReportRepository:
    def __init__(self, data_dir: Path, store: JsonFileStore | None = None) -> None:
        self.root = data_dir / "patients"
        self.store = store or JsonFileStore()
        self.patients = PatientRepository(data_dir, self.store)
        self.assessments = AssessmentRepository(data_dir, self.store)

    def list(self, patient_id: str | None = None) -> list[ReportSummary]:
        pattern = (
            f"{patient_id}/reports/*/report.json"
            if patient_id
            else "*/reports/*/report.json"
        )
        reports: list[ReportSummary] = [
            self._summary(assessment)
            for assessment in self.assessments.list(patient_id)
            if any(run.result is not None for run in assessment.module_runs.values())
        ]
        known_assessments = {report.assessment_id for report in reports}
        for path in self.root.glob(pattern):
            try:
                payload = self.store.read(path)
                if str(payload.get("assessment_id", "")) in known_assessments:
                    continue
                owner = self.patients.get(str(payload["patient_id"]))
                reports.append(
                    ReportSummary.model_validate(
                        {**payload, "patient_name": owner.name}
                    )
                )
            except (KeyError, OSError, ValueError):
                continue
        return sorted(reports, key=lambda item: item.created_at, reverse=True)

    def get(self, report_id: str) -> ReportDetail:
        assessment = self.assessments.get(report_id)
        patient = self.patients.get(assessment.patient_id)
        summary = self._summary(assessment)
        modules: list[ReportModule] = []
        for module_id, run in assessment.module_runs.items():
            try:
                display_name = registry.get(module_id).descriptor().display_name
            except KeyError:
                display_name = module_id
            modules.append(
                ReportModule(
                    module_id=module_id,
                    display_name=display_name,
                    status=run.status,
                    status_detail=run.status_detail,
                    result=run.result,
                )
            )
        return ReportDetail(
            **summary.model_dump(),
            patient_code=patient.patient_code,
            patient_gender=patient.gender,
            patient_birth_date=(
                patient.birth_date.isoformat() if patient.birth_date else None
            ),
            patient_diagnosis=patient.diagnosis,
            assessment_status=assessment.status,
            assessment_status_detail=assessment.status_detail,
            modules=modules,
            disclaimer=(
                "本报告用于科研和辅助评估。健康/轻度/中重度分层当前仅映射自"
                "整体姿态 walk17 模型的 0/1/2 输出，不能替代临床诊断。"
            ),
        )

    def _summary(self, assessment: Assessment) -> ReportSummary:
        patient = self.patients.get(assessment.patient_id)
        completed = sum(
            run.result is not None for run in assessment.module_runs.values()
        )
        return ReportSummary(
            id=assessment.id,
            patient_id=patient.id,
            patient_name=patient.name,
            assessment_id=assessment.id,
            title=f"{patient.name} · 多模态运动功能评估",
            status="ready" if completed else "draft",
            created_at=assessment.updated_at,
            severity=self._severity(assessment),
            completed_module_count=completed,
        )

    @staticmethod
    def _severity(assessment: Assessment) -> ReportSeverity:
        posture_run = assessment.module_runs.get("overall-posture")
        result = posture_run.result if posture_run else None
        raw_class = result.scores.get("np3gait_class") if result else None
        try:
            class_value = int(raw_class) if raw_class is not None else None
        except (TypeError, ValueError):
            class_value = None
        labels = {
            0: ("healthy", "帕金森健康"),
            1: ("mild", "帕金森轻度"),
            2: ("moderate_severe", "帕金森中重度"),
        }
        if class_value not in labels:
            return ReportSeverity(
                code="unavailable",
                label="暂无法分层",
                basis="缺少整体姿态 np3gait_class 输出",
            )

        confidence_values: list[float] = []
        segments = result.result_data.get("segments", []) if result else []
        if isinstance(segments, list):
            for segment in segments:
                if not isinstance(segment, dict):
                    continue
                prediction = segment.get("prediction", {})
                probabilities = (
                    prediction.get("probabilities", {})
                    if isinstance(prediction, dict)
                    else {}
                )
                if isinstance(probabilities, dict):
                    value = probabilities.get(str(class_value))
                    if isinstance(value, (int, float)):
                        confidence_values.append(float(value))

        code, label = labels[class_value]
        return ReportSeverity(
            code=code,
            label=label,
            class_value=class_value,
            confidence=(mean(confidence_values) if confidence_values else None),
            source_module_id="overall-posture",
            source_score_key="np3gait_class",
            basis="整体姿态 walk17 三分类模型输出的研究性映射",
        )
