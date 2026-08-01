from __future__ import annotations

import csv
import os
import re
from datetime import datetime, timezone
from pathlib import Path
from uuid import uuid4

from app.repositories.json_store import JsonFileStore
from app.schemas.segmentation import (
    SegmentationProject,
    SegmentationSourceKind,
    VideoSegment,
)


class SegmentationProjectNotFoundError(KeyError):
    pass


def _safe_name(value: str, fallback: str = "video") -> str:
    name = Path(value).name.strip()
    name = re.sub(r'[<>:"/\\|?*\x00-\x1f]', "_", name)
    name = name.rstrip(" .")
    return name[:160] or fallback


class SegmentationRepository:
    def __init__(self, data_dir: Path, store: JsonFileStore | None = None) -> None:
        self.root = data_dir / "video_segments"
        self.root.mkdir(parents=True, exist_ok=True)
        self.store = store or JsonFileStore()

    def prepare_import(
        self,
        *,
        name: str,
        original_name: str,
        source_kind: SegmentationSourceKind,
    ) -> tuple[SegmentationProject, Path]:
        project_id = str(uuid4())
        now = datetime.now(timezone.utc)
        display_name = name.strip() or Path(original_name).stem or "未命名视频"
        folder_stamp = now.strftime("%Y%m%d_%H%M%S")
        folder_name = (
            f"{folder_stamp}_{_safe_name(display_name, 'video')}_{project_id[:8]}"
        )
        project_dir = self.root / folder_name
        project_dir.mkdir(parents=True, exist_ok=False)

        source_file = _safe_name(original_name)
        source_path = project_dir / source_file
        project = SegmentationProject(
            id=project_id,
            name=display_name,
            original_name=original_name,
            source_kind=source_kind,
            source_file=source_file,
            status="processing",
            status_detail="原始文件已保存，正在生成浏览器预览。",
            archive_path=str(project_dir.resolve()),
            created_at=now,
            updated_at=now,
        )
        self._write(project)
        return project, source_path

    def list(self, keyword: str = "") -> list[SegmentationProject]:
        query = keyword.casefold().strip()
        projects: list[SegmentationProject] = []
        for path in self.root.glob("*/project.json"):
            try:
                project = SegmentationProject.model_validate(
                    self.store.read(path)
                )
            except (OSError, ValueError):
                continue
            if query:
                searchable = " ".join(
                    (
                        project.name,
                        project.original_name,
                        " ".join(item.label for item in project.segments),
                        " ".join(item.task_type for item in project.segments),
                    )
                ).casefold()
                if query not in searchable:
                    continue
            projects.append(project)
        return sorted(projects, key=lambda item: item.updated_at, reverse=True)

    def get(self, project_id: str) -> SegmentationProject:
        for path in self.root.glob("*/project.json"):
            try:
                payload = self.store.read(path)
            except (OSError, ValueError):
                continue
            if payload.get("id") == project_id:
                return SegmentationProject.model_validate(payload)
        raise SegmentationProjectNotFoundError(project_id)

    def project_dir(self, project_id: str) -> Path:
        return self._validated_archive_dir(self.get(project_id))

    def source_path(self, project_id: str) -> Path:
        project = self.get(project_id)
        return self._validated_archive_dir(project) / project.source_file

    def preview_path(self, project_id: str) -> Path:
        project = self.get(project_id)
        if not project.preview_file:
            raise FileNotFoundError("预览文件尚未生成")
        path = self._validated_archive_dir(project) / project.preview_file
        if not path.is_file():
            raise FileNotFoundError(str(path))
        return path

    def mark_ready(
        self,
        project_id: str,
        *,
        preview_file: str,
        duration_s: float,
        preview_duration_s: float,
        fps: float,
        width: int,
        height: int,
    ) -> SegmentationProject:
        project = self.get(project_id)
        updated = project.model_copy(
            update={
                "preview_file": preview_file,
                "status": "ready",
                "status_detail": "预览已生成，可以开始标记视频片段。",
                "duration_s": duration_s,
                "preview_duration_s": preview_duration_s,
                "fps": fps,
                "width": width,
                "height": height,
                "updated_at": datetime.now(timezone.utc),
            }
        )
        self._write(updated)
        return updated

    def mark_failed(
        self, project_id: str, detail: str
    ) -> SegmentationProject:
        project = self.get(project_id)
        updated = project.model_copy(
            update={
                "status": "failed",
                "status_detail": detail,
                "updated_at": datetime.now(timezone.utc),
            }
        )
        self._write(updated)
        return updated

    def save_segments(
        self,
        project_id: str,
        segments: list[VideoSegment],
        walk_distance_m: float | None = None,
    ) -> SegmentationProject:
        project = self.get(project_id)
        ordered = sorted(segments, key=lambda item: item.start_s)
        project_dir = self._validated_archive_dir(project)

        csv_path = project_dir / "segments.csv"
        csv_temp_path = project_dir / "segments.csv.tmp"
        with csv_temp_path.open(
            "w", newline="", encoding="utf-8-sig"
        ) as handle:
            writer = csv.DictWriter(
                handle,
                fieldnames=(
                    "segment_id",
                    "label",
                    "task_type",
                    "start_s",
                    "end_s",
                ),
            )
            writer.writeheader()
            for segment in ordered:
                writer.writerow(
                    {
                        **segment.model_dump(),
                        "start_s": round(segment.start_s, 3),
                        "end_s": round(segment.end_s, 3),
                    }
                )
        os.replace(csv_temp_path, csv_path)

        json_payload = {
            "project_id": project.id,
            "project_name": project.name,
            "source_file": project.source_file,
            "time_base": "seconds_from_first_frame",
            "walk_distance_m": walk_distance_m,
            "segments": [
                {
                    **segment.model_dump(),
                    "start_s": round(segment.start_s, 3),
                    "end_s": round(segment.end_s, 3),
                }
                for segment in ordered
            ],
        }
        self.store.write(project_dir / "segments.json", json_payload)

        updated = project.model_copy(
            update={
                "segments": ordered,
                "walk_distance_m": walk_distance_m,
                "status_detail": (
                    f"已保存 {len(ordered)} 个片段；CSV 与 JSON 已归档。"
                ),
                "updated_at": datetime.now(timezone.utc),
            }
        )
        self._write(updated)
        return updated

    def _write(self, project: SegmentationProject) -> None:
        path = self._validated_archive_dir(project) / "project.json"
        self.store.write(path, project.model_dump(mode="json"))

    def _validated_archive_dir(
        self, project: SegmentationProject
    ) -> Path:
        root = self.root.resolve()
        path = Path(project.archive_path).resolve()
        if path != root and root not in path.parents:
            raise ValueError("视频分割项目路径超出本地数据目录")
        return path
