from __future__ import annotations

from pathlib import Path

from fastapi import (
    APIRouter,
    Depends,
    File,
    Form,
    HTTPException,
    UploadFile,
    status,
)

from app.api.dependencies import (
    get_artifact_repository,
    get_patient_repository,
)
from app.repositories.artifacts import ArtifactRepository
from app.repositories.patients import PatientNotFoundError, PatientRepository
from app.schemas.artifacts import Artifact, InputKind, LocalArtifactCreate


router = APIRouter(prefix="/patients/{patient_id}/artifacts", tags=["artifacts"])


def ensure_patient(patient_id: str, repository: PatientRepository) -> None:
    try:
        repository.get(patient_id)
    except PatientNotFoundError as error:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="未找到患者档案。",
        ) from error


@router.get("", response_model=list[Artifact])
def list_artifacts(
    patient_id: str,
    patients: PatientRepository = Depends(get_patient_repository),
    artifacts: ArtifactRepository = Depends(get_artifact_repository),
) -> list[Artifact]:
    ensure_patient(patient_id, patients)
    return artifacts.list(patient_id)


@router.post(
    "/upload",
    response_model=Artifact,
    status_code=status.HTTP_201_CREATED,
)
async def upload_artifact(
    patient_id: str,
    file: UploadFile = File(...),
    kind: InputKind = Form(default="unknown"),
    module_id: str = Form(...),
    input_slot: str = Form(...),
    patients: PatientRepository = Depends(get_patient_repository),
    artifacts: ArtifactRepository = Depends(get_artifact_repository),
) -> Artifact:
    ensure_patient(patient_id, patients)
    original_name = file.filename or "unnamed"
    artifact_id, destination = artifacts.prepare_upload(
        patient_id, original_name
    )

    try:
        with destination.open("wb") as output:
            while chunk := await file.read(8 * 1024 * 1024):
                output.write(chunk)
    except OSError as error:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="文件保存失败。",
        ) from error
    finally:
        await file.close()

    return artifacts.finalize_upload(
        patient_id=patient_id,
        artifact_id=artifact_id,
        module_id=module_id,
        input_slot=input_slot,
        original_name=original_name,
        kind=kind,
        stored_path=destination,
    )


@router.post(
    "/register-local",
    response_model=Artifact,
    status_code=status.HTTP_201_CREATED,
)
def register_local_artifact(
    patient_id: str,
    payload: LocalArtifactCreate,
    patients: PatientRepository = Depends(get_patient_repository),
    artifacts: ArtifactRepository = Depends(get_artifact_repository),
) -> Artifact:
    ensure_patient(patient_id, patients)
    try:
        return artifacts.register_local(
            patient_id,
            Path(payload.path),
            payload.kind,
            payload.module_id,
            payload.input_slot,
        )
    except (FileNotFoundError, OSError) as error:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
            detail="本地文件不存在或无法读取。",
        ) from error
