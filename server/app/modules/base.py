from __future__ import annotations

from abc import ABC, abstractmethod
from collections.abc import Callable

from app.schemas.modules import (
    InferenceRequest,
    ModelModuleDescriptor,
    ModuleResult,
)


ProgressCallback = Callable[[float, str], None]


class ModuleUnavailableError(RuntimeError):
    """Raised when an adapter exists but its model runtime is not ready."""


class InferenceModule(ABC):
    """Contract implemented by every independently deployable model module."""

    @abstractmethod
    def descriptor(self) -> ModelModuleDescriptor:
        """Return runtime capability and readiness information."""

    @abstractmethod
    def validate(self, request: InferenceRequest) -> list[str]:
        """Return actionable validation issues without running inference."""

    @abstractmethod
    def infer(
        self,
        request: InferenceRequest,
        progress: ProgressCallback | None = None,
    ) -> ModuleResult:
        """Run inference and return a normalized, module-owned result."""
