from __future__ import annotations

from fastapi import APIRouter

from app.modules.registry import registry
from app.schemas.modules import ModelModuleDescriptor


router = APIRouter(prefix="/modules", tags=["modules"])


@router.get("", response_model=list[ModelModuleDescriptor])
def list_modules() -> list[ModelModuleDescriptor]:
    return registry.list_descriptors()
