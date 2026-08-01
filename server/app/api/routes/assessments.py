from __future__ import annotations

import logging
import mimetypes
import threading
from datetime import datetime, timezone
from pathlib import Path

from fastapi import APIRouter, BackgroundTasks, Depends, HTTPException, Query, status
from fastapi.responses import FileResponse

from app.api.dependencies import (
    get_artifact_repository,
    get_assessment_repository,
    get_patient_repository,
)
from app.modules.registry import registry
from app.repositories.artifacts import (
    ArtifactNotFoundError,
    ArtifactRepository,
)
from app.repositories.assessments import AssessmentRepository
from app.repositories.patients import PatientNotFoundError, PatientRepository
from app.schemas.assessments import (
    Assessment,
    AssessmentCreate,
    ModuleRunRecord,
)
from app.schemas.modules import InferenceRequest, InputArtifact


router = APIRouter(prefix="/assessments", tags=["assessments"])
logger = logging.getLogger(__name__)


# ============================================================================
# Background inference runner
# ============================================================================

def _run_inference_background(
    assessment_id: str,
    patient_id: str,
    module_inputs: dict,
    data_dir: Path,
) -> None:
    """Run all module inferences in background threads, update assessment as
    each module completes."""
    repo = AssessmentRepository(data_dir)

    def _run_one(module_id: str, slot_map: dict[str, list[str]]) -> None:
        try:
            module = registry.get(module_id)

            # Build InferenceRequest
            artifact_repo = ArtifactRepository(data_dir)
            inputs: dict[str, tuple[InputArtifact, ...]] = {}
            for slot_key, artifact_ids in slot_map.items():
                artifacts: list[InputArtifact] = []
                for aid in artifact_ids:
                    a = artifact_repo.get(patient_id, aid)
                    artifacts.append(InputArtifact(
                        id=a.id,
                        module_id=a.module_id,
                        input_slot=a.input_slot,
                        kind=a.kind,
                        path=Path(a.stored_path),
                        metadata={"original_name": a.original_name},
                    ))
                inputs[slot_key] = tuple(artifacts)

            request = InferenceRequest(
                assessment_id=assessment_id,
                patient_id=patient_id,
                module_id=module_id,
                inputs=inputs,
                parameters={
                    "output_dir": str(
                        data_dir
                        / "patients"
                        / patient_id
                        / "assessments"
                        / assessment_id
                        / "outputs"
                        / module_id
                    )
                },
            )

            issues = module.validate(request)
            if issues:
                repo.store_module_failure(
                    assessment_id,
                    module_id,
                    "; ".join(issues),
                    merge=False,
                )
                logger.warning("Module %s validation failed: %s", module_id, issues)
                return

            result = module.infer(request)
            repo.store_module_result(
                assessment_id,
                module_id,
                result,
                merge=False,
            )
            logger.info("Module %s inference completed", module_id)

        except Exception as exc:
            logger.exception("Module %s inference failed", module_id)
            try:
                repo.store_module_failure(
                    assessment_id,
                    module_id,
                    f"推理异常: {exc}",
                    merge=False,
                )
            except Exception:
                logger.exception(
                    "Module %s failure state could not be stored",
                    module_id,
                )

    threads: list[threading.Thread] = []
    for module_id, slots in module_inputs.items():
        t = threading.Thread(
            target=_run_one,
            args=(module_id, slots),
            name=f"inference-{assessment_id}-{module_id}",
        )
        t.start()
        threads.append(t)

    for thread in threads:
        thread.join()

    try:
        repo.merge_module_runs(assessment_id, list(module_inputs))
    except Exception:
        logger.exception(
            "Could not merge module results for assessment %s",
            assessment_id,
        )


# ============================================================================
# Endpoints
# ============================================================================

@router.get("", response_model=list[Assessment])
def list_assessments(
    patient_id: str | None = Query(default=None),
    repository: AssessmentRepository = Depends(get_assessment_repository),
) -> list[Assessment]:
    return repository.list(patient_id)


@router.get("/{assessment_id}", response_model=Assessment)
def get_assessment(
    assessment_id: str,
    repository: AssessmentRepository = Depends(get_assessment_repository),
) -> Assessment:
    try:
        return repository.get(assessment_id)
    except KeyError as error:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="未找到评估任务。",
        ) from error


@router.get(
    "/{assessment_id}/modules/{module_id}/outputs/{artifact_index}",
    response_class=FileResponse,
)
def get_module_output(
    assessment_id: str,
    module_id: str,
    artifact_index: int,
    repository: AssessmentRepository = Depends(get_assessment_repository),
) -> FileResponse:
    """Read one exact output declared by a completed module result.

    The client never supplies a filesystem path.  Only paths already stored in
    ``ModuleResult.output_artifacts`` can be served.
    """

    try:
        assessment = repository.get(assessment_id)
    except KeyError as error:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="未找到评估任务。",
        ) from error

    run = assessment.module_runs.get(module_id)
    if run is None or run.result is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="该模块尚无可读取输出。",
        )
    if artifact_index < 0 or artifact_index >= len(run.result.output_artifacts):
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="输出文件索引不存在。",
        )

    path = Path(run.result.output_artifacts[artifact_index]).resolve()
    if not path.is_file():
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="输出文件不存在或已被移动。",
        )
    media_type = mimetypes.guess_type(path.name)[0] or "application/octet-stream"
    return FileResponse(
        path,
        media_type=media_type,
        headers={"Content-Disposition": f'inline; filename="{path.name}"'},
    )


@router.post(
    "",
    response_model=Assessment,
    status_code=status.HTTP_201_CREATED,
)
def create_assessment(
    payload: AssessmentCreate,
    patients: PatientRepository = Depends(get_patient_repository),
    artifacts: ArtifactRepository = Depends(get_artifact_repository),
    assessments: AssessmentRepository = Depends(get_assessment_repository),
) -> Assessment:
    try:
        patients.get(payload.patient_id)
    except PatientNotFoundError as error:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="未找到患者档案。",
        ) from error

    unknown_modules = [
        module_id
        for module_id in payload.module_inputs
        if not registry.contains(module_id)
    ]
    if unknown_modules:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
            detail={"unknown_modules": unknown_modules},
        )

    normalized_inputs: dict[str, dict[str, list[str]]] = {}
    module_runs: dict[str, ModuleRunRecord] = {}
    validation_issues: list[dict[str, str]] = []
    now = datetime.now(timezone.utc)

    for module_id, supplied_slots in payload.module_inputs.items():
        descriptor = registry.get(module_id).descriptor()
        slot_contract = {slot.key: slot for slot in descriptor.input_slots}
        normalized_slots: dict[str, list[str]] = {}

        for unknown_slot in set(supplied_slots) - set(slot_contract):
            validation_issues.append({
                "module_id": module_id,
                "input_slot": unknown_slot,
                "message": "输入槽未在该模块接口中定义。",
            })

        for slot_key, slot in slot_contract.items():
            artifact_ids = list(dict.fromkeys(supplied_slots.get(slot_key, [])))
            if slot.required and not artifact_ids:
                validation_issues.append({
                    "module_id": module_id,
                    "input_slot": slot_key,
                    "message": "缺少必需输入。",
                })
                continue
            if not slot.multiple and len(artifact_ids) > 1:
                validation_issues.append({
                    "module_id": module_id,
                    "input_slot": slot_key,
                    "message": "该输入槽只允许一个文件。",
                })

            valid_ids: list[str] = []
            for artifact_id in artifact_ids:
                try:
                    artifact = artifacts.get(payload.patient_id, artifact_id)
                except ArtifactNotFoundError:
                    validation_issues.append({
                        "module_id": module_id,
                        "input_slot": slot_key,
                        "message": f"资料不存在或不属于该患者：{artifact_id}",
                    })
                    continue

                if artifact.module_id != module_id or artifact.input_slot != slot_key:
                    validation_issues.append({
                        "module_id": module_id,
                        "input_slot": slot_key,
                        "message": f"资料映射不一致：{artifact_id}",
                    })
                    continue
                if artifact.kind not in slot.accepted_kinds:
                    validation_issues.append({
                        "module_id": module_id,
                        "input_slot": slot_key,
                        "message": (
                            f"资料类型 {artifact.kind} 不在允许范围内："
                            f"{', '.join(slot.accepted_kinds)}"
                        ),
                    })
                    continue
                valid_ids.append(artifact_id)

            normalized_slots[slot_key] = valid_ids

        normalized_inputs[module_id] = normalized_slots

        # Determine initial status based on module readiness
        if descriptor.status == "ready":
            run_status = "queued"
            run_detail = "模块就绪，等待启动推理。"
        else:
            run_status = "awaiting_adapter"
            run_detail = descriptor.status_detail

        module_runs[module_id] = ModuleRunRecord(
            module_id=module_id,
            status=run_status,
            status_detail=run_detail,
            inputs=normalized_slots,
            result=None,
            updated_at=now,
        )

    if validation_issues:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
            detail={"input_mapping_issues": validation_issues},
        )

    normalized = AssessmentCreate(
        patient_id=payload.patient_id,
        module_inputs=normalized_inputs,
    )
    return assessments.create(
        normalized,
        status_detail=(
            "各模块输入已分别登记并建立固定映射。"
            "可由客户端立即启动推理。"
        ),
        module_runs=module_runs,
    )


@router.post("/{assessment_id}/run", response_model=Assessment)
def run_assessment(
    assessment_id: str,
    background_tasks: BackgroundTasks,
    assessments: AssessmentRepository = Depends(get_assessment_repository),
) -> Assessment:
    """Trigger inference for all queued modules in this assessment."""
    try:
        assessment = assessments.get(assessment_id)
    except KeyError as error:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="未找到评估任务。",
        ) from error

    # Count queued modules
    queued = [
        mid for mid, run in assessment.module_runs.items()
        if run.status == "queued"
    ]
    if not queued:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="没有等待执行的模块（所有模块可能已在运行或已完成）。",
        )

    # Mark all queued modules as running
    now = datetime.now(timezone.utc)
    for mid in queued:
        assessment.module_runs[mid].status = "running"
        assessment.module_runs[mid].status_detail = "推理中…"
        assessment.module_runs[mid].updated_at = now
    assessment.status = "running"
    assessment.status_detail = f"正在执行 {len(queued)} 个模块推理…"
    assessments.save(assessment)

    # Kick off background inference threads
    data_dir = assessments.root.parent  # assessments.root = data/patients, parent = data
    module_inputs = {
        mid: assessment.module_runs[mid].inputs
        for mid in queued
    }
    background_tasks.add_task(
        _run_inference_background,
        assessment_id=assessment.id,
        patient_id=assessment.patient_id,
        module_inputs=module_inputs,
        data_dir=data_dir,
    )

    return assessment
