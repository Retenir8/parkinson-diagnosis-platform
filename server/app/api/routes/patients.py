from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, Query, status

from app.api.dependencies import get_patient_repository
from app.repositories.patients import (
    DuplicatePatientCodeError,
    PatientNotFoundError,
    PatientRepository,
)
from app.schemas.patients import Patient, PatientCreate, PatientUpdate


router = APIRouter(prefix="/patients", tags=["patients"])


@router.get("", response_model=list[Patient])
def list_patients(
    keyword: str = Query(default="", max_length=200),
    repository: PatientRepository = Depends(get_patient_repository),
) -> list[Patient]:
    return repository.list(keyword)


@router.post("", response_model=Patient, status_code=status.HTTP_201_CREATED)
def create_patient(
    payload: PatientCreate,
    repository: PatientRepository = Depends(get_patient_repository),
) -> Patient:
    try:
        return repository.create(payload)
    except DuplicatePatientCodeError as error:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="患者编号已存在。",
        ) from error


@router.get("/{patient_id}", response_model=Patient)
def get_patient(
    patient_id: str,
    repository: PatientRepository = Depends(get_patient_repository),
) -> Patient:
    try:
        return repository.get(patient_id)
    except PatientNotFoundError as error:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="未找到患者档案。",
        ) from error


@router.put("/{patient_id}", response_model=Patient)
def update_patient(
    patient_id: str,
    payload: PatientUpdate,
    repository: PatientRepository = Depends(get_patient_repository),
) -> Patient:
    try:
        return repository.update(patient_id, payload)
    except PatientNotFoundError as error:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="未找到患者档案。",
        ) from error
    except DuplicatePatientCodeError as error:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="患者编号已存在。",
        ) from error
