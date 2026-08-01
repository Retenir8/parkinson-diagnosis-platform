from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class PreviewMetadata:
    duration_s: float
    preview_duration_s: float
    fps: float
    width: int
    height: int


def _preview_size(width: int, height: int) -> tuple[int, int]:
    if width <= 0 or height <= 0:
        raise ValueError("无法读取视频分辨率")
    scale = min(1.0, 1280 / width, 720 / height)
    target_width = max(2, int(round(width * scale)) // 2 * 2)
    target_height = max(2, int(round(height * scale)) // 2 * 2)
    return target_width, target_height


def _open_writer(path: Path, fps: float, size: tuple[int, int]):
    import cv2

    writer = cv2.VideoWriter(
        str(path),
        cv2.VideoWriter_fourcc(*"VP80"),
        fps,
        size,
    )
    if not writer.isOpened():
        raise RuntimeError("无法创建 WebM 预览文件（VP8 编码器不可用）")
    return writer


def _write_frame(writer, frame, target_size: tuple[int, int]) -> None:
    import cv2

    if (frame.shape[1], frame.shape[0]) != target_size:
        frame = cv2.resize(frame, target_size, interpolation=cv2.INTER_AREA)
    writer.write(frame)


def generate_video_preview(
    source_path: Path, preview_path: Path
) -> PreviewMetadata:
    if source_path.suffix.lower() == ".bag":
        return _generate_bag_preview(source_path, preview_path)
    return _generate_regular_preview(source_path, preview_path)


def _generate_regular_preview(
    source_path: Path, preview_path: Path
) -> PreviewMetadata:
    import cv2

    capture = cv2.VideoCapture(str(source_path))
    if not capture.isOpened():
        raise ValueError("视频无法解码，请检查文件格式或完整性")

    writer = None
    try:
        fps = float(capture.get(cv2.CAP_PROP_FPS))
        if not 1 <= fps <= 240:
            fps = 30.0
        width = int(capture.get(cv2.CAP_PROP_FRAME_WIDTH))
        height = int(capture.get(cv2.CAP_PROP_FRAME_HEIGHT))
        target_size = _preview_size(width, height)
        writer = _open_writer(preview_path, fps, target_size)

        frames_written = 0
        while True:
            ok, frame = capture.read()
            if not ok:
                break
            _write_frame(writer, frame, target_size)
            frames_written += 1

        if frames_written == 0:
            raise ValueError("视频中没有可读取的画面")
        duration_s = frames_written / fps
        return PreviewMetadata(
            duration_s=duration_s,
            preview_duration_s=duration_s,
            fps=fps,
            width=width,
            height=height,
        )
    finally:
        capture.release()
        if writer is not None:
            writer.release()


def _generate_bag_preview(
    source_path: Path, preview_path: Path
) -> PreviewMetadata:
    import cv2
    import numpy as np
    import pyrealsense2 as rs

    pipeline = rs.pipeline()
    config = rs.config()
    rs.config.enable_device_from_file(
        config, str(source_path), repeat_playback=False
    )
    profile = pipeline.start(config)
    writer = None
    frames_written = 0
    first_timestamp_ms: float | None = None
    last_timestamp_ms: float | None = None

    try:
        playback = profile.get_device().as_playback()
        playback.set_real_time(False)
        color_profile = profile.get_stream(rs.stream.color)
        video_profile = color_profile.as_video_stream_profile()
        fps = float(video_profile.fps() or 30.0)
        width = int(video_profile.width())
        height = int(video_profile.height())
        target_size = _preview_size(width, height)
        writer = _open_writer(preview_path, fps, target_size)

        while True:
            try:
                frames = pipeline.wait_for_frames(timeout_ms=5000)
            except RuntimeError:
                break
            color_frame = frames.get_color_frame()
            if not color_frame:
                continue

            timestamp_ms = float(color_frame.get_timestamp())
            if first_timestamp_ms is None:
                first_timestamp_ms = timestamp_ms
            last_timestamp_ms = timestamp_ms

            frame = np.asanyarray(color_frame.get_data())
            color_format = color_frame.get_profile().format()
            if color_format == rs.format.rgb8:
                frame = cv2.cvtColor(frame, cv2.COLOR_RGB2BGR)
            elif color_format == rs.format.rgba8:
                frame = cv2.cvtColor(frame, cv2.COLOR_RGBA2BGR)
            elif color_format == rs.format.bgra8:
                frame = cv2.cvtColor(frame, cv2.COLOR_BGRA2BGR)

            _write_frame(writer, frame, target_size)
            frames_written += 1

        if frames_written == 0:
            raise ValueError(".bag 中没有可读取的彩色画面")
        preview_duration_s = frames_written / fps
        if (
            first_timestamp_ms is not None
            and last_timestamp_ms is not None
            and last_timestamp_ms > first_timestamp_ms
        ):
            duration_s = (last_timestamp_ms - first_timestamp_ms) / 1000.0
        else:
            duration_s = preview_duration_s
        return PreviewMetadata(
            duration_s=duration_s,
            preview_duration_s=preview_duration_s,
            fps=fps,
            width=width,
            height=height,
        )
    finally:
        if writer is not None:
            writer.release()
        pipeline.stop()
