from __future__ import annotations

import json
import os
import threading
from pathlib import Path
from typing import Any


class JsonFileStore:
    """Small atomic JSON helper.

    This is intentionally not a database abstraction. It keeps local storage
    replaceable when the project later chooses a database or encrypted store.
    """

    def __init__(self) -> None:
        self._write_lock = threading.RLock()

    def read(self, path: Path) -> dict[str, Any]:
        with path.open("r", encoding="utf-8") as handle:
            payload = json.load(handle)
        if not isinstance(payload, dict):
            raise ValueError(f"Expected a JSON object in {path}")
        return payload

    def write(self, path: Path, payload: dict[str, Any]) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        temp_path = path.with_suffix(f"{path.suffix}.tmp")
        with self._write_lock:
            temp_path.write_text(
                json.dumps(payload, ensure_ascii=False, indent=2),
                encoding="utf-8",
            )
            os.replace(temp_path, path)
