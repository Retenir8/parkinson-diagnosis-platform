from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, Query, status

from app.api.dependencies import get_report_repository
from app.repositories.reports import ReportRepository
from app.schemas.reports import ReportDetail, ReportSummary


router = APIRouter(prefix="/reports", tags=["reports"])


@router.get("", response_model=list[ReportSummary])
def list_reports(
    patient_id: str | None = Query(default=None),
    repository: ReportRepository = Depends(get_report_repository),
) -> list[ReportSummary]:
    return repository.list(patient_id)


@router.get("/{report_id}", response_model=ReportDetail)
def get_report(
    report_id: str,
    repository: ReportRepository = Depends(get_report_repository),
) -> ReportDetail:
    try:
        return repository.get(report_id)
    except KeyError as error:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="未找到评估报告。",
        ) from error
