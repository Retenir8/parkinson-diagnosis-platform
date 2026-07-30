from __future__ import annotations

from pathlib import Path

from app.repositories.json_store import JsonFileStore
from app.repositories.patients import PatientRepository
from app.schemas.reports import ReportSummary


class ReportRepository:
    def __init__(self, data_dir: Path, store: JsonFileStore | None = None) -> None:
        self.root = data_dir / "patients"
        self.store = store or JsonFileStore()
        self.patients = PatientRepository(data_dir, self.store)

    def list(self, patient_id: str | None = None) -> list[ReportSummary]:
        pattern = (
            f"{patient_id}/reports/*/report.json"
            if patient_id
            else "*/reports/*/report.json"
        )
        reports: list[ReportSummary] = []
        for path in self.root.glob(pattern):
            try:
                payload = self.store.read(path)
                owner = self.patients.get(str(payload["patient_id"]))
                reports.append(
                    ReportSummary.model_validate(
                        {**payload, "patient_name": owner.name}
                    )
                )
            except (KeyError, OSError, ValueError):
                continue
        return sorted(reports, key=lambda item: item.created_at, reverse=True)
