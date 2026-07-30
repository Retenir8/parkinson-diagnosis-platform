from __future__ import annotations

import re
from datetime import datetime, timezone
from pathlib import Path
from uuid import uuid4

from app.repositories.json_store import JsonFileStore
from app.schemas.artifacts import Artifact, InputKind


class ArtifactNotFoundError(KeyError):
    pass


def safe_file_name(value: str) -> str:
    name = Path(value).name.strip()
    name = re.sub(r'[<>:"/\\|?*\x00-\x1f]', "_", name)
    return name[:240] or "unnamed"


class ArtifactRepository:
    def __init__(self, data_dir: Path, store: JsonFileStore | None = None) -> None:
        self.root = data_dir / "patients"
        self.store = store or JsonFileStore()

    def artifacts_dir(self, patient_id: str) -> Path:
        return self.root / patient_id / "artifacts"

    def artifact_dir(self, patient_id: str, artifact_id: str) -> Path:
        return self.artifacts_dir(patient_id) / artifact_id

    def prepare_upload(
        self, patient_id: str, original_name: str
    ) -> tuple[str, Path]:
        artifact_id = str(uuid4())
        directory = self.artifact_dir(patient_id, artifact_id)
        directory.mkdir(parents=True, exist_ok=False)
        return artifact_id, directory / safe_file_name(original_name)

    def finalize_upload(
        self,
        *,
        patient_id: str,
        artifact_id: str,
        module_id: str,
        input_slot: str,
        original_name: str,
        kind: InputKind,
        stored_path: Path,
    ) -> Artifact:
        artifact = Artifact(
            id=artifact_id,
            patient_id=patient_id,
            module_id=module_id,
            input_slot=input_slot,
            original_name=original_name,
            kind=kind,
            source_type="uploaded",
            stored_path=str(stored_path.resolve()),
            size_bytes=stored_path.stat().st_size,
            created_at=datetime.now(timezone.utc),
        )
        self._write(artifact)
        return artifact

    def register_local(
        self,
        patient_id: str,
        path: Path,
        kind: InputKind,
        module_id: str,
        input_slot: str,
    ) -> Artifact:
        resolved = path.expanduser().resolve(strict=True)
        if not resolved.is_file():
            raise FileNotFoundError(str(resolved))
        artifact = Artifact(
            id=str(uuid4()),
            patient_id=patient_id,
            module_id=module_id,
            input_slot=input_slot,
            original_name=resolved.name,
            kind=kind,
            source_type="local_reference",
            stored_path=str(resolved),
            size_bytes=resolved.stat().st_size,
            created_at=datetime.now(timezone.utc),
        )
        self.artifact_dir(patient_id, artifact.id).mkdir(
            parents=True, exist_ok=False
        )
        self._write(artifact)
        return artifact

    def list(self, patient_id: str) -> list[Artifact]:
        artifacts: list[Artifact] = []
        for path in self.artifacts_dir(patient_id).glob("*/artifact.json"):
            try:
                artifacts.append(Artifact.model_validate(self.store.read(path)))
            except (OSError, ValueError):
                continue
        return sorted(artifacts, key=lambda item: item.created_at, reverse=True)

    def get(self, patient_id: str, artifact_id: str) -> Artifact:
        path = self.artifact_dir(patient_id, artifact_id) / "artifact.json"
        if not path.is_file():
            raise ArtifactNotFoundError(artifact_id)
        return Artifact.model_validate(self.store.read(path))

    def _write(self, artifact: Artifact) -> None:
        path = self.artifact_dir(artifact.patient_id, artifact.id) / "artifact.json"
        self.store.write(path, artifact.model_dump(mode="json"))
