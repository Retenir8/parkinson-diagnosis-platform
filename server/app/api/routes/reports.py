from __future__ import annotations

from fastapi import APIRouter, Depends, Query

from app.api.dependencies import get_report_repository
from app.repositories.reports import ReportRepository
from app.schemas.reports import ReportSummary


router = APIRouter(prefix="/reports", tags=["reports"])


@router.get("", response_model=list[ReportSummary])
def list_reports(
    patient_id: str | None = Query(default=None),
    repository: ReportRepository = Depends(get_report_repository),
) -> list[ReportSummary]:
    return repository.list(patient_id)
