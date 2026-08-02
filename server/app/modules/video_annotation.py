"""
标注视频写入与骨架绘制共享工具
================================
供手部/腿部运动模块生成可回放的标注视频（VP8/WebM），
骨架颜色与整体姿态模块的 annotate_frame 保持一致。
"""

from __future__ import annotations

from pathlib import Path
from typing import Optional, Sequence

import numpy as np

# MediaPipe Hands 21 点连接（与 mp.solutions.hands.HAND_CONNECTIONS 一致）
HAND_CONNECTIONS = (
    (0, 1), (1, 2), (2, 3), (3, 4),          # 拇指
    (0, 5), (5, 6), (6, 7), (7, 8),          # 食指
    (5, 9), (9, 10), (10, 11), (11, 12),     # 中指
    (9, 13), (13, 14), (14, 15), (15, 16),   # 无名指
    (13, 17), (17, 18), (18, 19), (19, 20),  # 小指
    (0, 17),
)

# MediaPipe Pose 下半身关键点（脚趾拍地/抬腿任务用）
LEG_LANDMARKS = (0, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32)
LEG_CONNECTIONS = (
    (23, 24),                                      # 髋连线
    (23, 25), (25, 27), (27, 29), (29, 31),        # 左腿链
    (24, 26), (26, 28), (28, 30), (30, 32),        # 右腿链
    (0, 23), (0, 24),                              # 鼻子→髋（躯干参考）
)

BONE_COLOR = (70, 220, 205)      # BGR，与整体姿态骨架一致
JOINT_FILL = (255, 255, 255)
JOINT_RING = (14, 139, 130)
HIGHLIGHT_COLOR = (0, 80, 255)   # BGR 红橙色，目标点高亮
TEXT_BG = (0, 0, 0)
TEXT_FG = (255, 255, 255)
OK_COLOR = (0, 220, 0)
ALERT_COLOR = (0, 0, 255)

# 手部骨架专用样式（更细腻：细线、小节点）
HAND_BONE_COLOR = (90, 220, 205)      # 连接线：柔和青色
HAND_JOINT_FILL = (255, 255, 255)     # 关节：白色实心小点
HAND_JOINT_RING = (16, 130, 125)      # 关节描边：深青细圈


class AnnotatedVideoWriter:
    """将标注帧写入 WebM(VP8)/MP4 文件的封装。

    VP8/WebM 可直接被 Chromium/Tauri WebView 播放，
    无需外部 ffmpeg/H.264 安装（与整体姿态模块一致）。
    编码器不可用时 ``opened`` 为 False，调用方应静默降级。
    """

    def __init__(
        self,
        path: Path,
        fps: float,
        frame_size: tuple[int, int],
        codec: str = "VP80",
    ) -> None:
        import cv2

        self.path = path
        self._writer = None
        if fps <= 0:
            fps = 30.0
        try:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            fourcc = cv2.VideoWriter_fourcc(*codec)
            writer = cv2.VideoWriter(
                str(self.path), fourcc, float(fps), frame_size,
            )
            if writer.isOpened():
                self._writer = writer
        except Exception:
            self._writer = None

    @property
    def opened(self) -> bool:
        return self._writer is not None

    def write(self, frame: np.ndarray) -> None:
        if self._writer is not None:
            self._writer.write(frame)

    def close(self) -> None:
        if self._writer is not None:
            self._writer.release()
            self._writer = None


def put_text_block(
    image: np.ndarray,
    lines: Sequence[str],
    origin: tuple[int, int] = (12, 28),
    line_height: int = 26,
    scale: float = 0.62,
    thickness: int = 2,
    color: tuple[int, int, int] = TEXT_FG,
    status_index: Optional[int] = None,
    status_color: tuple[int, int, int] = OK_COLOR,
) -> None:
    """在画面指定位置绘制一组带黑色描边的文字行。"""
    import cv2

    x, y = origin
    for index, line in enumerate(lines):
        line_color = status_color if index == status_index else color
        pos = (x, y + index * line_height)
        cv2.putText(
            image, line, pos, cv2.FONT_HERSHEY_SIMPLEX,
            scale, TEXT_BG, thickness + 2, cv2.LINE_AA,
        )
        cv2.putText(
            image, line, pos, cv2.FONT_HERSHEY_SIMPLEX,
            scale, line_color, thickness, cv2.LINE_AA,
        )


def _point(landmark, width: int, height: int) -> tuple[int, int]:
    return (int(landmark.x * width), int(landmark.y * height))


def _visible(landmark, min_visibility: float) -> bool:
    visibility = getattr(landmark, "visibility", None)
    return visibility is None or float(visibility) >= min_visibility


def draw_hand_skeleton(
    image: np.ndarray,
    landmarks,
) -> None:
    """绘制手部 21 点骨架（细线 + 小节点）。

    手部关键点不检查 visibility：MediaPipe Hands 不输出有效
    visibility（protobuf 默认 0.0），按阈值过滤会把全部点跳过。
    样式：2px 柔和青色连接线；2px 白色关节圆点 + 深青细描边。
    """
    import cv2

    height, width = image.shape[:2]
    for a, b in HAND_CONNECTIONS:
        cv2.line(
            image, _point(landmarks[a], width, height),
            _point(landmarks[b], width, height),
            HAND_BONE_COLOR, 2, cv2.LINE_AA,
        )
    for landmark in landmarks:
        center = _point(landmark, width, height)
        cv2.circle(
            image, center, 2, HAND_JOINT_FILL, -1, cv2.LINE_AA,
        )
        cv2.circle(
            image, center, 3, HAND_JOINT_RING, 1, cv2.LINE_AA,
        )


def draw_leg_skeleton(
    image: np.ndarray,
    landmarks,
    *,
    highlight: Sequence[int] = (),
    min_visibility: float = 0.35,
) -> None:
    """绘制下半身骨架；highlight 中的关键点用高亮圈标出。"""
    import cv2

    height, width = image.shape[:2]
    for a, b in LEG_CONNECTIONS:
        if not _visible(landmarks[a], min_visibility):
            continue
        if not _visible(landmarks[b], min_visibility):
            continue
        cv2.line(
            image, _point(landmarks[a], width, height),
            _point(landmarks[b], width, height),
            BONE_COLOR, 3, cv2.LINE_AA,
        )
    for index in LEG_LANDMARKS:
        landmark = landmarks[index]
        if not _visible(landmark, min_visibility):
            continue
        center = _point(landmark, width, height)
        cv2.circle(image, center, 4, JOINT_FILL, -1, cv2.LINE_AA)
        cv2.circle(image, center, 5, JOINT_RING, 1, cv2.LINE_AA)
    for index in highlight:
        landmark = landmarks[index]
        if not _visible(landmark, min_visibility):
            continue
        center = _point(landmark, width, height)
        cv2.circle(image, center, 8, HIGHLIGHT_COLOR, 2, cv2.LINE_AA)
        cv2.circle(image, center, 3, HIGHLIGHT_COLOR, -1, cv2.LINE_AA)
