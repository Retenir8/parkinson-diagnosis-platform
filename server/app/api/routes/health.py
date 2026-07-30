from __future__ import annotations

from fastapi import APIRouter, Depends

from app.core.config import Settings, get_settings


router = APIRouter(tags=["system"])


@router.get("/health")
def health(settings: Settings = Depends(get_settings)) -> dict[str, str]:
    return {
        "status": "ok",
        "service": settings.app_name,
        "version": settings.version,
        "data_dir": str(settings.data_dir),
    }
