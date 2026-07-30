from __future__ import annotations

from fastapi import Depends

from app.core.config import Settings, get_settings
from app.repositories.artifacts import ArtifactRepository
from app.repositories.assessments import AssessmentRepository
from app.repositories.patients import PatientRepository
from app.repositories.reports import ReportRepository


def get_patient_repository(
    settings: Settings = Depends(get_settings),
) -> PatientRepository:
    return PatientRepository(settings.data_dir)


def get_artifact_repository(
    settings: Settings = Depends(get_settings),
) -> ArtifactRepository:
    return ArtifactRepository(settings.data_dir)


def get_assessment_repository(
    settings: Settings = Depends(get_settings),
) -> AssessmentRepository:
    return AssessmentRepository(settings.data_dir)


def get_report_repository(
    settings: Settings = Depends(get_settings),
) -> ReportRepository:
    return ReportRepository(settings.data_dir)
