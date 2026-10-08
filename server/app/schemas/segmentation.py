from __future__ import annotations

from datetime import datetime
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, computed_field, model_validator


SegmentationProjectStatus = Literal["processing", "ready", "failed"]
SegmentationSourceKind = Literal["video", "realsense_bag"]


class VideoSegment(BaseModel):
    model_config = ConfigDict(str_strip_whitespace=True)

    segment_id: str = Field(min_length=1, max_length=100)
    label: str = Field(min_length=1, max_length=200)
    task_type: str = Field(min_length=1, max_length=100)
    side: Literal["left", "right"] | None = None
    start_s: float = Field(ge=0)
    end_s: float = Field(gt=0)

    @model_validator(mode="after")
    def validate_time_range(self) -> "VideoSegment":
        if self.end_s <= self.start_s:
            raise ValueError("end_s 必须大于 start_s")
        return self


class VideoSegmentUpdate(BaseModel):
    segments: list[VideoSegment] = Field(default_factory=list)
    walk_distance_m: float | None = Field(default=None, gt=0)
    # 手部动作分段：裁剪区域 (x, y, w, h)，作用于整段视频
    crop_region: tuple[int, int, int, int] | None = None

    @model_validator(mode="after")
    def validate_segments(self) -> "VideoSegmentUpdate":
        ids = [item.segment_id for item in self.segments]
        if len(ids) != len(set(ids)):
            raise ValueError("segment_id 不能重复")

        ordered = sorted(self.segments, key=lambda item: item.start_s)
        for previous, current in zip(ordered, ordered[1:]):
            if current.start_s < previous.end_s:
                raise ValueError(
                    f"片段 {previous.segment_id} 与 {current.segment_id} 时间重叠"
                )
        if self.crop_region is not None:
            x, y, w, h = self.crop_region
            if x < 0 or y < 0:
                raise ValueError("crop_region 的 x/y 不允许负值")
            if w <= 0 or h <= 0:
                raise ValueError("crop_region 的宽度和高度必须大于 0")
        return self


class SegmentationProject(BaseModel):
    id: str
    name: str
    original_name: str
    source_kind: SegmentationSourceKind
    source_file: str
    preview_file: str | None = None
    status: SegmentationProjectStatus
    status_detail: str
    duration_s: float | None = None
    preview_duration_s: float | None = None
    fps: float | None = None
    width: int | None = None
    height: int | None = None
    archive_path: str
    walk_distance_m: float | None = None
    crop_region: tuple[int, int, int, int] | None = None
    segments: list[VideoSegment] = Field(default_factory=list)
    created_at: datetime
    updated_at: datetime

    @computed_field
    @property
    def preview_available(self) -> bool:
        return bool(self.preview_file) and self.status == "ready"
