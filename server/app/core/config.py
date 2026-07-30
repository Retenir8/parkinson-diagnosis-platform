from __future__ import annotations

import os
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path


@dataclass(frozen=True)
class Settings:
    app_name: str
    version: str
    data_dir: Path
    allowed_origins: tuple[str, ...]


def _resolve_data_dir() -> Path:
    configured = os.getenv("MEDVISION_DATA_DIR")
    if configured:
        path = Path(configured).expanduser()
        if not path.is_absolute():
            path = Path.cwd() / path
        return path.resolve()

    system_root = Path(__file__).resolve().parents[3]
    return (system_root / "data").resolve()


@lru_cache(maxsize=1)
def get_settings() -> Settings:
    origins = os.getenv(
        "MEDVISION_ALLOWED_ORIGINS",
        ",".join(
            (
                "http://127.0.0.1:5173",
                "http://localhost:5173",
                "http://tauri.localhost",
                "tauri://localhost",
            )
        ),
    )
    data_dir = _resolve_data_dir()
    data_dir.mkdir(parents=True, exist_ok=True)
    (data_dir / "patients").mkdir(parents=True, exist_ok=True)
    return Settings(
        app_name="Multimodal Clinical Assessment Service",
        version="0.1.0",
        data_dir=data_dir,
        allowed_origins=tuple(
            origin.strip() for origin in origins.split(",") if origin.strip()
        ),
    )
