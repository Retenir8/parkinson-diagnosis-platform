from __future__ import annotations

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.api.router import api_router
from app.core.config import get_settings


settings = get_settings()
app = FastAPI(
    title="多模态运动功能评估本地服务",
    version=settings.version,
    description=(
        "患者本地档案、评估资料和可插拔模型模块的本地 API。"
        "当前框架不会执行尚未确认的模型或评分逻辑。"
    ),
)
app.add_middleware(
    CORSMiddleware,
    allow_origins=list(settings.allowed_origins),
    allow_credentials=False,
    allow_methods=["GET", "POST", "PUT", "DELETE", "OPTIONS"],
    allow_headers=["Content-Type"],
)
app.include_router(api_router)


@app.get("/", include_in_schema=False)
def root() -> dict[str, str]:
    return {
        "service": settings.app_name,
        "docs": "/docs",
        "health": "/api/v1/health",
    }
