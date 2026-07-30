from __future__ import annotations

from datetime import datetime
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field


InputKind = Literal[
    "video",
    "realsense_bag",
    "tabular",
    "insole_timeseries",
    "unknown",
]
ArtifactSource = Literal["uploaded", "local_reference"]


class LocalArtifactCreate(BaseModel):
    model_config = ConfigDict(str_strip_whitespace=True)

    path: str = Field(min_length=1)
    kind: InputKind = "unknown"
    module_id: str = Field(min_length=1)
    input_slot: str = Field(min_length=1)


class Artifact(BaseModel):
    id: str
    patient_id: str
    module_id: str
    input_slot: str
    original_name: str
    kind: InputKind
    source_type: ArtifactSource
    stored_path: str
    size_bytes: int | None = None
    created_at: datetime
