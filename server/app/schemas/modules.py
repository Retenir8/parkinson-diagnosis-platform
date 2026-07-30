from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Literal

from pydantic import BaseModel, Field

from app.schemas.artifacts import InputKind


ModuleCategory = Literal["posture", "hand", "leg", "insole"]
ModuleStatus = Literal[
    "ready",
    "adapter_pending",
    "external_pending",
    "disabled",
    "error",
]


class ModelModuleDescriptor(BaseModel):
    id: str
    display_name: str
    category: ModuleCategory
    description: str
    status: ModuleStatus
    status_detail: str
    input_kinds: list[InputKind]
    input_slots: list["InputSlotDescriptor"]
    output_capabilities: list[str]
    model_version: str | None = None


class InputSlotDescriptor(BaseModel):
    key: str
    label: str
    description: str
    accepted_kinds: list[InputKind]
    required: bool = True
    multiple: bool = True


@dataclass(frozen=True)
class InputArtifact:
    id: str
    module_id: str
    input_slot: str
    kind: InputKind
    path: Path
    metadata: dict[str, Any] = field(default_factory=dict)


@dataclass(frozen=True)
class InferenceRequest:
    assessment_id: str
    patient_id: str
    module_id: str
    inputs: dict[str, tuple[InputArtifact, ...]]
    parameters: dict[str, Any] = field(default_factory=dict)

    @property
    def artifacts(self) -> tuple[InputArtifact, ...]:
        """Flatten slot-bound inputs for adapters that process one shared stream."""

        return tuple(
            artifact
            for slot_artifacts in self.inputs.values()
            for artifact in slot_artifacts
        )


class ModuleResult(BaseModel):
    module_id: str
    module_version: str | None = None
    summary: str | None = None
    quality: dict[str, Any] = Field(default_factory=dict)
    metrics: dict[str, float | int | str | None] = Field(default_factory=dict)
    scores: dict[str, float | int | str | None] = Field(default_factory=dict)
    result_data: dict[str, Any] = Field(default_factory=dict)
    output_artifacts: list[str] = Field(default_factory=list)
    warnings: list[str] = Field(default_factory=list)
