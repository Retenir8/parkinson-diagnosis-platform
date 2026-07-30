from __future__ import annotations

from datetime import datetime
from typing import Literal

from pydantic import BaseModel


class ReportSummary(BaseModel):
    id: str
    patient_id: str
    patient_name: str
    assessment_id: str
    title: str
    status: Literal["draft", "ready", "failed"]
    created_at: datetime
    file_name: str | None = None
