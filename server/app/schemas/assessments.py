from __future__ import annotations

from datetime import datetime
from typing import Literal

from pydantic import BaseModel, Field

from app.schemas.modules import ModuleResult


AssessmentStatus = Literal[
    "draft",
    "queued",
    "running",
    "completed",
    "failed",
    "cancelled",
]


class AssessmentCreate(BaseModel):
    patient_id: str = Field(min_length=1)
    module_inputs: dict[str, dict[str, list[str]]] = Field(min_length=1)


ModuleRunStatus = Literal[
    "awaiting_adapter",
    "queued",
    "running",
    "completed",
    "failed",
    "cancelled",
]


class ModuleRunRecord(BaseModel):
    module_id: str
    status: ModuleRunStatus
    status_detail: str
    inputs: dict[str, list[str]]
    result: ModuleResult | None = None
    updated_at: datetime


class Assessment(BaseModel):
    id: str
    patient_id: str
    module_inputs: dict[str, dict[str, list[str]]]
    status: AssessmentStatus
    status_detail: str
    module_runs: dict[str, ModuleRunRecord] = Field(default_factory=dict)
    created_at: datetime
    updated_at: datetime
