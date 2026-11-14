from __future__ import annotations

import os
import secrets

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.requests import Request
from fastapi.responses import JSONResponse

from app.api.router import api_router
from app.core.config import get_settings


settings = get_settings()
app = FastAPI(
    title="多模态运动功能评估本地服务",
    version=settings.version,
    description=(
        "患者本地档案、评估资料和可插拔模型模块的本地 API。"
        "系统仅执行已注册且状态就绪的模型；未确认模块不会进入推理。"
    ),
)
app.add_middleware(
    CORSMiddleware,
    allow_origins=list(settings.allowed_origins),
    allow_credentials=False,
    allow_methods=["GET", "POST", "PUT", "DELETE", "OPTIONS"],
    allow_headers=["Content-Type", "X-Medvision-Token"],
)
app.include_router(api_router)

desktop_token = os.getenv("MEDVISION_DESKTOP_TOKEN")
if desktop_token:
    @app.middleware("http")
    async def require_desktop_token(request: Request, call_next):
        if request.method == "OPTIONS":
            return await call_next(request)
        supplied = (
            request.headers.get("X-Medvision-Token")
            or request.query_params.get("desktop_token")
            or ""
        )
        if not secrets.compare_digest(supplied, desktop_token):
            return JSONResponse(status_code=403, content={"detail": "桌面会话验证失败。"})
        return await call_next(request)


@app.get("/", include_in_schema=False)
def root() -> dict[str, str]:
    return {
        "service": settings.app_name,
        "docs": "/docs",
        "health": "/api/v1/health",
    }
