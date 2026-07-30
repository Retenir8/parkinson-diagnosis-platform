from __future__ import annotations

from fastapi import APIRouter

from app.api.routes import (
    artifacts,
    assessments,
    health,
    modules,
    patients,
    reports,
)


api_router = APIRouter(prefix="/api/v1")
api_router.include_router(health.router)
api_router.include_router(patients.router)
api_router.include_router(artifacts.router)
api_router.include_router(modules.router)
api_router.include_router(assessments.router)
api_router.include_router(reports.router)
