from __future__ import annotations

from datetime import date, datetime
from typing import Any, Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator


PatientGender = Literal["male", "female", "other", "unknown"]


class PatientBase(BaseModel):
    model_config = ConfigDict(str_strip_whitespace=True)

    patient_code: str = Field(min_length=1, max_length=100)
    name: str = Field(min_length=1, max_length=100)
    gender: PatientGender = "unknown"
    birth_date: date | None = None
    phone: str | None = Field(default=None, max_length=100)
    diagnosis: str | None = Field(default=None, max_length=500)
    notes: str | None = Field(default=None, max_length=4000)
    extra_fields: dict[str, Any] = Field(default_factory=dict)

    @field_validator("phone", "diagnosis", "notes", mode="before")
    @classmethod
    def empty_string_to_none(cls, value: object) -> object:
        if isinstance(value, str) and not value.strip():
            return None
        return value


class PatientCreate(PatientBase):
    pass


class PatientUpdate(BaseModel):
    model_config = ConfigDict(str_strip_whitespace=True)

    patient_code: str | None = Field(default=None, min_length=1, max_length=100)
    name: str | None = Field(default=None, min_length=1, max_length=100)
    gender: PatientGender | None = None
    birth_date: date | None = None
    phone: str | None = Field(default=None, max_length=100)
    diagnosis: str | None = Field(default=None, max_length=500)
    notes: str | None = Field(default=None, max_length=4000)
    extra_fields: dict[str, Any] | None = None


class Patient(PatientBase):
    id: str
    created_at: datetime
    updated_at: datetime
