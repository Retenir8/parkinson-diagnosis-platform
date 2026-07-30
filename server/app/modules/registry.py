from __future__ import annotations

from app.modules.base import InferenceModule
from app.modules.providers.external import (
    hand_module,
    insole_module,
    leg_module,
)
from app.modules.providers.overall_posture import OverallPostureModule
from app.schemas.modules import ModelModuleDescriptor


class ModuleRegistry:
    def __init__(self, modules: list[InferenceModule] | None = None) -> None:
        registered = modules or [
            OverallPostureModule(),
            hand_module(),
            leg_module(),
            insole_module(),
        ]
        self._modules = {
            module.descriptor().id: module for module in registered
        }

    def list_descriptors(self) -> list[ModelModuleDescriptor]:
        return [module.descriptor() for module in self._modules.values()]

    def get(self, module_id: str) -> InferenceModule:
        try:
            return self._modules[module_id]
        except KeyError as error:
            raise KeyError(f"Unknown inference module: {module_id}") from error

    def contains(self, module_id: str) -> bool:
        return module_id in self._modules


registry = ModuleRegistry()
