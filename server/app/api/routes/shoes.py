"""Shoes live control and archived-session registration for System."""

from __future__ import annotations

import shutil
from pathlib import Path

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel

from app.api.dependencies import get_artifact_repository, get_patient_repository
from app.core.config import get_settings
from app.repositories.artifacts import ArtifactRepository
from app.repositories.patients import PatientNotFoundError, PatientRepository
from app.schemas.artifacts import Artifact
from app.services.shoes_runtime import (
    REFERENCE_ROOT,
    list_sessions,
    runtime,
    session_directory,
)


router = APIRouter(prefix="/shoes", tags=["shoes"])


class SessionRegistration(BaseModel):
    patient_id: str


@router.get("/runtime")
def get_runtime() -> dict:
    return runtime.status()


@router.post("/runtime/start")
def start_runtime() -> dict:
    try:
        return runtime.start()
    except RuntimeError as error:
        raise HTTPException(status_code=409, detail=str(error)) from error


@router.post("/runtime/commands/{command}")
def queue_command(command: str) -> dict:
    try:
        return runtime.command(command)
    except ValueError as error:
        raise HTTPException(status_code=422, detail=str(error)) from error
    except RuntimeError as error:
        raise HTTPException(status_code=409, detail=str(error)) from error


@router.get("/sessions")
def get_sessions() -> list[dict]:
    return list_sessions()


@router.post("/sessions/{session_stamp}/register", response_model=list[Artifact])
def register_session(
    session_stamp: str,
    payload: SessionRegistration,
    patients: PatientRepository = Depends(get_patient_repository),
    artifacts: ArtifactRepository = Depends(get_artifact_repository),
) -> list[Artifact]:
    try:
        patients.get(payload.patient_id)
    except PatientNotFoundError as error:
        raise HTTPException(status_code=404, detail="患者档案不存在。") from error
    try:
        source = session_directory(session_stamp)
    except ValueError as error:
        raise HTTPException(status_code=422, detail=str(error)) from error
    except FileNotFoundError as error:
        raise HTTPException(status_code=404, detail="Shoes 会话不存在。") from error
    current = runtime.status()
    if current["running"] and current["session_stamp"] == session_stamp:
        raise HTTPException(status_code=409, detail="请先结束 Shoes 会话再归档，避免读取仍在变化的文件。")

    active_source = REFERENCE_ROOT / "log" / session_stamp
    if active_source.is_dir():
        source = active_source
    archive = get_settings().data_dir / "shoes_archive" / "log" / session_stamp
    if source.resolve() != archive.resolve():
        archive.mkdir(parents=True, exist_ok=True)
        for file in source.iterdir():
            if file.is_file() and file.suffix.lower() in {".csv", ".txt"}:
                shutil.copy2(file, archive / file.name)
    files = sorted(
        file for file in archive.iterdir()
        if file.is_file() and file.suffix.lower() in {".csv", ".txt"}
    )
    if not files:
        raise HTTPException(status_code=422, detail="Shoes 会话没有可导入的日志文件。")
    existing = {
        Path(item.stored_path).resolve(): item
        for item in artifacts.list(payload.patient_id)
        if item.module_id == "smart-insole" and item.input_slot == "insole_data"
    }
    result: list[Artifact] = []
    for file in files:
        resolved = file.resolve()
        if resolved in existing:
            result.append(existing[resolved])
        else:
            result.append(artifacts.register_local(
                payload.patient_id, resolved, "tabular", "smart-insole", "insole_data"
            ))
    return result
