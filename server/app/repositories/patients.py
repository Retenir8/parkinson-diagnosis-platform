from __future__ import annotations

from datetime import datetime, timezone
from pathlib import Path
from uuid import uuid4

from app.repositories.json_store import JsonFileStore
from app.schemas.patients import Patient, PatientCreate, PatientUpdate


class PatientNotFoundError(KeyError):
    pass


class DuplicatePatientCodeError(ValueError):
    pass


class PatientRepository:
    def __init__(self, data_dir: Path, store: JsonFileStore | None = None) -> None:
        self.root = data_dir / "patients"
        self.root.mkdir(parents=True, exist_ok=True)
        self.store = store or JsonFileStore()

    def patient_dir(self, patient_id: str) -> Path:
        return self.root / patient_id

    def profile_path(self, patient_id: str) -> Path:
        return self.patient_dir(patient_id) / "patient.json"

    def list(self, keyword: str = "") -> list[Patient]:
        query = keyword.casefold().strip()
        patients: list[Patient] = []
        for path in self.root.glob("*/patient.json"):
            try:
                patient = Patient.model_validate(self.store.read(path))
            except (OSError, ValueError):
                continue
            if query:
                searchable = " ".join(
                    filter(
                        None,
                        (
                            patient.patient_code,
                            patient.name,
                            patient.phone,
                            patient.diagnosis,
                        ),
                    )
                ).casefold()
                if query not in searchable:
                    continue
            patients.append(patient)
        return sorted(patients, key=lambda item: item.updated_at, reverse=True)

    def get(self, patient_id: str) -> Patient:
        path = self.profile_path(patient_id)
        if not path.is_file():
            raise PatientNotFoundError(patient_id)
        return Patient.model_validate(self.store.read(path))

    def create(self, payload: PatientCreate) -> Patient:
        self._ensure_unique_code(payload.patient_code)
        now = datetime.now(timezone.utc)
        patient = Patient(
            id=str(uuid4()),
            **payload.model_dump(),
            created_at=now,
            updated_at=now,
        )
        patient_dir = self.patient_dir(patient.id)
        for child in ("artifacts", "assessments", "reports"):
            (patient_dir / child).mkdir(parents=True, exist_ok=True)
        self.store.write(
            self.profile_path(patient.id), patient.model_dump(mode="json")
        )
        return patient

    def update(self, patient_id: str, payload: PatientUpdate) -> Patient:
        current = self.get(patient_id)
        changes = payload.model_dump(exclude_unset=True)
        new_code = changes.get("patient_code")
        if new_code and new_code != current.patient_code:
            self._ensure_unique_code(new_code, exclude_id=patient_id)
        patient = current.model_copy(
            update={**changes, "updated_at": datetime.now(timezone.utc)}
        )
        self.store.write(
            self.profile_path(patient.id), patient.model_dump(mode="json")
        )
        return patient

    def _ensure_unique_code(
        self, patient_code: str, exclude_id: str | None = None
    ) -> None:
        normalized = patient_code.casefold().strip()
        for patient in self.list():
            if patient.id != exclude_id and patient.patient_code.casefold() == normalized:
                raise DuplicatePatientCodeError(patient_code)
