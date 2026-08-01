from __future__ import annotations

from datetime import datetime
from typing import Literal

from pydantic import BaseModel

from app.schemas.modules import ModuleResult


ReportStatus = Literal["draft", "ready", "failed"]
SeverityCode = Literal[
    "healthy",
    "mild",
    "moderate_severe",
    "unavailable",
]


class ReportSeverity(BaseModel):
    code: SeverityCode
    label: str
    class_value: int | None = None
    confidence: float | None = None
    source_module_id: str | None = None
    source_score_key: str | None = None
    basis: str
    research_only: bool = True


class ReportSummary(BaseModel):
    id: str
    patient_id: str
    patient_name: str
    assessment_id: str
    title: str
    status: ReportStatus
    created_at: datetime
    file_name: str | None = None
    severity: ReportSeverity | None = None
    completed_module_count: int = 0


class ReportModule(BaseModel):
    module_id: str
    display_name: str
    status: str
    status_detail: str
    result: ModuleResult | None = None


class ReportDetail(ReportSummary):
    patient_code: str
    patient_gender: str
    patient_birth_date: str | None = None
    patient_diagnosis: str | None = None
    assessment_status: str
    assessment_status_detail: str
    modules: list[ReportModule]
    disclaimer: str
