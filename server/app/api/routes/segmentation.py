from __future__ import annotations

from pathlib import Path

from fastapi import (
    APIRouter,
    BackgroundTasks,
    Depends,
    File,
    Form,
    HTTPException,
    UploadFile,
    status,
)
from fastapi.responses import FileResponse

from app.api.dependencies import get_segmentation_repository
from app.repositories.segmentation import (
    SegmentationProjectNotFoundError,
    SegmentationRepository,
)
from app.schemas.segmentation import (
    SegmentationProject,
    VideoSegmentUpdate,
)
from app.services.video_preview import generate_video_preview


router = APIRouter(prefix="/segmentation-projects", tags=["video-segmentation"])

VIDEO_SUFFIXES = {".mp4", ".mov", ".avi", ".mkv", ".webm", ".m4v"}


def _get_project(
    project_id: str, repository: SegmentationRepository
) -> SegmentationProject:
    try:
        return repository.get(project_id)
    except SegmentationProjectNotFoundError as error:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="未找到视频分割项目。",
        ) from error


def _build_preview(
    project_id: str,
    source_path: Path,
    repository: SegmentationRepository,
) -> None:
    preview_path = source_path.parent / "preview.webm"
    try:
        metadata = generate_video_preview(source_path, preview_path)
        repository.mark_ready(
            project_id,
            preview_file=preview_path.name,
            duration_s=metadata.duration_s,
            preview_duration_s=metadata.preview_duration_s,
            fps=metadata.fps,
            width=metadata.width,
            height=metadata.height,
        )
    except Exception as error:  # background task must persist a readable failure
        repository.mark_failed(
            project_id,
            f"预览生成失败：{error}",
        )


@router.get("", response_model=list[SegmentationProject])
def list_projects(
    keyword: str = "",
    repository: SegmentationRepository = Depends(
        get_segmentation_repository
    ),
) -> list[SegmentationProject]:
    return repository.list(keyword)


@router.post(
    "/upload",
    response_model=SegmentationProject,
    status_code=status.HTTP_201_CREATED,
)
async def upload_project(
    background_tasks: BackgroundTasks,
    file: UploadFile = File(...),
    project_name: str = Form(default=""),
    repository: SegmentationRepository = Depends(
        get_segmentation_repository
    ),
) -> SegmentationProject:
    original_name = file.filename or "unnamed"
    suffix = Path(original_name).suffix.lower()
    if suffix != ".bag" and suffix not in VIDEO_SUFFIXES:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
            detail="仅支持 .bag、.mp4、.mov、.avi、.mkv、.webm 或 .m4v。",
        )
    source_kind = "realsense_bag" if suffix == ".bag" else "video"
    project, destination = repository.prepare_import(
        name=project_name,
        original_name=original_name,
        source_kind=source_kind,
    )

    try:
        with destination.open("wb") as output:
            while chunk := await file.read(8 * 1024 * 1024):
                output.write(chunk)
    except OSError as error:
        repository.mark_failed(project.id, "原始文件保存失败。")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="原始文件保存失败。",
        ) from error
    finally:
        await file.close()

    background_tasks.add_task(
        _build_preview,
        project.id,
        destination,
        repository,
    )
    return project


@router.get("/{project_id}", response_model=SegmentationProject)
def get_project(
    project_id: str,
    repository: SegmentationRepository = Depends(
        get_segmentation_repository
    ),
) -> SegmentationProject:
    return _get_project(project_id, repository)


@router.get("/{project_id}/preview")
def get_preview(
    project_id: str,
    repository: SegmentationRepository = Depends(
        get_segmentation_repository
    ),
) -> FileResponse:
    project = _get_project(project_id, repository)
    if project.status == "processing":
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="预览仍在生成。",
        )
    try:
        preview_path = repository.preview_path(project_id)
    except FileNotFoundError as error:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=project.status_detail,
        ) from error
    return FileResponse(
        preview_path,
        media_type="video/webm",
        filename="preview.webm",
        content_disposition_type="inline",
    )


@router.put("/{project_id}/segments", response_model=SegmentationProject)
def save_segments(
    project_id: str,
    payload: VideoSegmentUpdate,
    repository: SegmentationRepository = Depends(
        get_segmentation_repository
    ),
) -> SegmentationProject:
    project = _get_project(project_id, repository)
    if project.status != "ready":
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="预览未就绪，暂时不能保存片段。",
        )
    if project.duration_s is not None:
        beyond_end = [
            item.segment_id
            for item in payload.segments
            if item.end_s > project.duration_s + 0.05
        ]
        if beyond_end:
            raise HTTPException(
                status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
                detail=f"片段结束时间超过视频时长：{', '.join(beyond_end)}",
            )
    return repository.save_segments(
        project_id,
        payload.segments,
        walk_distance_m=payload.walk_distance_m,
    )
