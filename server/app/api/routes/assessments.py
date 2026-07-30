from __future__ import annotations

from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException, Query, status

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


router = APIRouter(prefix="/assessments", tags=["assessments"])


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
        module_id for module_id in payload.module_inputs if not registry.contains(module_id)
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
            validation_issues.append(
                {
                    "module_id": module_id,
                    "input_slot": unknown_slot,
                    "message": "输入槽未在该模块接口中定义。",
                }
            )

        for slot_key, slot in slot_contract.items():
            artifact_ids = list(dict.fromkeys(supplied_slots.get(slot_key, [])))
            if slot.required and not artifact_ids:
                validation_issues.append(
                    {
                        "module_id": module_id,
                        "input_slot": slot_key,
                        "message": "缺少必需输入。",
                    }
                )
                continue
            if not slot.multiple and len(artifact_ids) > 1:
                validation_issues.append(
                    {
                        "module_id": module_id,
                        "input_slot": slot_key,
                        "message": "该输入槽只允许一个文件。",
                    }
                )

            valid_ids: list[str] = []
            for artifact_id in artifact_ids:
                try:
                    artifact = artifacts.get(payload.patient_id, artifact_id)
                except ArtifactNotFoundError:
                    validation_issues.append(
                        {
                            "module_id": module_id,
                            "input_slot": slot_key,
                            "message": f"资料不存在或不属于该患者：{artifact_id}",
                        }
                    )
                    continue

                if artifact.module_id != module_id or artifact.input_slot != slot_key:
                    validation_issues.append(
                        {
                            "module_id": module_id,
                            "input_slot": slot_key,
                            "message": f"资料映射不一致：{artifact_id}",
                        }
                    )
                    continue
                if artifact.kind not in slot.accepted_kinds:
                    validation_issues.append(
                        {
                            "module_id": module_id,
                            "input_slot": slot_key,
                            "message": (
                                f"资料类型 {artifact.kind} 不在允许范围内："
                                f"{', '.join(slot.accepted_kinds)}"
                            ),
                        }
                    )
                    continue
                valid_ids.append(artifact_id)

            normalized_slots[slot_key] = valid_ids

        normalized_inputs[module_id] = normalized_slots
        module_runs[module_id] = ModuleRunRecord(
            module_id=module_id,
            status="awaiting_adapter",
            status_detail=descriptor.status_detail,
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
            "各模块输入已分别登记并建立固定映射。当前尚未启用推理编排器，"
            "结果区域只会显示模型真实返回，不生成可视化或综合评分。"
        ),
        module_runs=module_runs,
    )
