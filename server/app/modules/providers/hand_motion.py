"""
手部运动分析推理模块 (MDS-UPDRS 3.4/3.5/3.6)
==============================================
集成三个手部动作评分器：
- 手指对指 (Finger Opposition) — MDS-UPDRS 3.4
- 手掌轮替 (Hand Alternation) — MDS-UPDRS 3.5
- 握拳     (Fist Clenching)  — MDS-UPDRS 3.6

MediaPipe Hands 关键点只提取一次，三个评分器共享。
无头模式：不产生 OpenCV 窗口，生成 VP8/WebM 标注视频作为模块输出。
"""

from __future__ import annotations

import csv
import json
import os
import sys
import time
import math
import logging
import tempfile
from pathlib import Path
from collections import deque
from typing import Any, Dict, List, Optional, Tuple

import numpy as np

from app.modules.base import (
    InferenceModule,
    ModuleUnavailableError,
    ProgressCallback,
)
from app.modules.mediapipe_compat import prepare_legacy_solutions
from app.modules.video_annotation import (
    AnnotatedVideoWriter,
    draw_hand_skeleton,
    put_text_block,
)
from app.schemas.modules import (
    InputSlotDescriptor,
    InferenceRequest,
    ModelModuleDescriptor,
    ModuleResult,
)

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Sentinel & constants
# ---------------------------------------------------------------------------
INVALID_SIGNAL_SENTINEL = 900.0

SPEED_THRESHOLDS_DUIZHI = [0.9, 0.8, 0.6, 0.4]
SPEED_THRESHOLDS_LUNTI  = [0.9, 0.65, 0.5, 0.3]
SPEED_THRESHOLDS_WOQUAN = [0.9, 0.8, 0.6, 0.4]


# ============================================================================
# Geometry helpers (pure functions)
# ============================================================================

def _joint_angle(a, b, c) -> float:
    ba = np.array([a.x - b.x, a.y - b.y])
    bc = np.array([c.x - b.x, c.y - b.y])
    dot = np.dot(ba, bc)
    norm = np.linalg.norm(ba) * np.linalg.norm(bc)
    if norm < 1e-8:
        return 180.0
    return float(np.degrees(np.arccos(np.clip(dot / norm, -1.0, 1.0))))


def _norm_dist(a, b) -> float:
    return float(np.linalg.norm([a.x - b.x, a.y - b.y]))


# ---------------------------------------------------------------------------
# Task-specific 2D signals (mirror hand_utils.py logic)
# ---------------------------------------------------------------------------

def opposition_signal(hand_lm, index_extension_angle: float = 60.0) -> float:
    thumb_tip = hand_lm.landmark[4]
    index_tip = hand_lm.landmark[8]
    wrist = hand_lm.landmark[0]
    index_mcp = hand_lm.landmark[5]
    index_pip = hand_lm.landmark[6]
    middle_mcp = hand_lm.landmark[9]

    if _joint_angle(index_mcp, index_pip, index_tip) < index_extension_angle:
        return INVALID_SIGNAL_SENTINEL

    scale = max(_norm_dist(wrist, middle_mcp), 0.001)
    return _norm_dist(thumb_tip, index_tip) / scale


def alternation_signal(hand_lm) -> float:
    thumb_mcp = hand_lm.landmark[2]
    pinky_mcp = hand_lm.landmark[17]
    wrist = hand_lm.landmark[0]
    middle_mcp = hand_lm.landmark[9]

    dx = pinky_mcp.x - thumb_mcp.x
    scale = max(_norm_dist(wrist, middle_mcp), 0.001)
    return (dx / scale) * 100.0


def fist_signal(hand_lm, fist_angle_threshold: float = 140.0) -> float:
    triplets = [(5, 6, 8), (9, 10, 12), (13, 14, 16), (17, 18, 20)]
    angles = [
        _joint_angle(
            hand_lm.landmark[mcp], hand_lm.landmark[pip], hand_lm.landmark[tip],
        )
        for mcp, pip, tip in triplets
    ]
    if sum(1 for a in angles if a < fist_angle_threshold) < 3:
        return INVALID_SIGNAL_SENTINEL

    median_4 = float(np.median(angles))
    thumb_angle = _joint_angle(
        hand_lm.landmark[2], hand_lm.landmark[3], hand_lm.landmark[4],
    )
    return median_4 * 0.8 + thumb_angle * 0.2


# ============================================================================
# ActionDetector (mirror hand_utils.py)
# ============================================================================

class ActionEvent:
    __slots__ = (
        "index", "timestamp", "signal_value", "amplitude",
        "start_time", "end_time", "duration", "speed",
    )

    def __init__(self, index, timestamp, signal_value, amplitude):
        self.index = index
        self.timestamp = timestamp
        self.signal_value = signal_value
        self.amplitude = amplitude
        self.start_time = None
        self.end_time = None
        self.duration = 0.0
        self.speed = 0.0


class ActionDetector:
    def __init__(
        self,
        mode="valley",
        buffer_size=30,
        min_prominence=0.15,
        min_interval=0.3,
        smoothing_window=5,
        min_abs_amplitude=0.0,
        min_direction_time=0.15,
    ):
        self.mode = mode
        self.buffer_size = buffer_size
        self.min_prominence = min_prominence
        self.min_interval = min_interval
        self.smoothing_window = smoothing_window
        self.min_abs_amplitude = min_abs_amplitude
        self._min_direction_time = min_direction_time

        self.signal_buffer = deque(maxlen=buffer_size)
        self.time_buffer = deque(maxlen=buffer_size)
        self.smoothed_buffer = deque(maxlen=buffer_size)

        self.last_detection_time = -min_interval
        self.detection_count = 0
        self.prev_deriv_sign = 0
        self.recent_max = -float("inf")
        self.recent_min = float("inf")

        self._last_dir_change_time = 0.0
        self._prev_dir_duration = 0.0

        self.action_records = []
        self._cycle_start_time = None

    def update(self, signal, timestamp):
        self.signal_buffer.append(signal)
        self.time_buffer.append(timestamp)

        if len(self.signal_buffer) < self.smoothing_window + 2:
            return None

        smoothed = self._ema(list(self.signal_buffer), alpha=0.3)
        self.smoothed_buffer.append(smoothed[-1])

        if len(self.smoothed_buffer) < 2:
            return None

        s_list = list(self.smoothed_buffer)
        deriv = s_list[-1] - s_list[-2]
        cur_sign = 1 if deriv > 1e-6 else (-1 if deriv < -1e-6 else 0)

        if cur_sign != 0 and cur_sign != self.prev_deriv_sign and self.prev_deriv_sign != 0:
            self._prev_dir_duration = timestamp - self._last_dir_change_time
            self._last_dir_change_time = timestamp
        elif cur_sign != 0 and self.prev_deriv_sign == 0:
            self._last_dir_change_time = timestamp

        self.recent_max = max(self.recent_max, s_list[-1])
        self.recent_min = min(self.recent_min, s_list[-1])

        if (timestamp - self.last_detection_time > 3.0
                and len(self.signal_buffer) >= 10):
            buf = list(self.signal_buffer)
            rng = max(buf[-10:]) - min(buf[-10:])
            if rng < max(self.min_abs_amplitude * 0.5, 0.01):
                self.recent_max = signal
                self.recent_min = signal

        detected = None

        if self.mode == "valley":
            if self.prev_deriv_sign == -1 and cur_sign == 1:
                detected = self._try_valley(s_list, timestamp)
        else:
            if ((self.prev_deriv_sign == -1 and cur_sign == 1)
                    or (self.prev_deriv_sign == 1 and cur_sign == -1)):
                detected = self._try_extrema(s_list, timestamp)

        self.prev_deriv_sign = cur_sign if cur_sign != 0 else self.prev_deriv_sign

        if detected is not None:
            self._finalize(detected)
            self.recent_max = signal
            self.recent_min = signal

        return detected

    def get_event_count(self):
        return len(self.action_records)

    def reset_smooth(self, value):
        self.smoothed_buffer.clear()
        self.signal_buffer.clear()
        for _ in range(min(self.buffer_size, 30)):
            self.smoothed_buffer.append(value)
            self.signal_buffer.append(value)
        self.recent_max = value
        self.recent_min = value
        self.prev_deriv_sign = 0
        self._prev_dir_duration = 0.0

    def reset(self):
        self.signal_buffer.clear()
        self.time_buffer.clear()
        self.smoothed_buffer.clear()
        self.last_detection_time = -self.min_interval
        self.detection_count = 0
        self.prev_deriv_sign = 0
        self.recent_max = -float("inf")
        self.recent_min = float("inf")
        self._prev_dir_duration = 0.0
        self._last_dir_change_time = 0.0
        self.action_records.clear()
        self._cycle_start_time = None

    def _try_valley(self, smoothed, timestamp):
        if self._prev_dir_duration < self._min_direction_time:
            return None
        valley = smoothed[-2]
        prominence = self.recent_max - valley
        rng = max(self.recent_max - self.recent_min, 1e-6)
        if prominence / rng < self.min_prominence:
            return None
        if prominence < self.min_abs_amplitude:
            return None
        if timestamp - self.last_detection_time < self.min_interval:
            return None
        return ActionEvent(self.detection_count, timestamp, valley, prominence)

    def _try_extrema(self, smoothed, timestamp):
        if self._prev_dir_duration < self._min_direction_time:
            return None
        ext = smoothed[-2]
        prominence = (
            self.recent_max - ext
            if self.prev_deriv_sign == -1
            else ext - self.recent_min
        )
        rng = max(self.recent_max - self.recent_min, 1e-6)
        if prominence / rng < self.min_prominence:
            return None
        if prominence < self.min_abs_amplitude:
            return None
        if timestamp - self.last_detection_time < self.min_interval:
            return None
        return ActionEvent(self.detection_count, timestamp, ext, prominence)

    def _finalize(self, event):
        event.start_time = self._cycle_start_time or event.timestamp
        if self.action_records:
            prev = self.action_records[-1]
            prev.end_time = event.timestamp
            event.start_time = prev.timestamp
        self._cycle_start_time = event.timestamp
        self.detection_count += 1
        self.last_detection_time = event.timestamp
        self.action_records.append(event)

    @staticmethod
    def _ema(data, alpha=0.3):
        out = [data[0]]
        for i in range(1, len(data)):
            out.append(alpha * data[i] + (1 - alpha) * out[-1])
        return out


# ============================================================================
# Scoring helpers
# ============================================================================

def _compute_pauses(signal_buf, time_buf, pause_threshold=0.8,
                    continuity_gap=0.25):
    """从逐帧信号中检测停顿：信号变化小于范围 5% 且持续够久。

    continuity_gap：相邻采样点时间间隔超过该值视为数据不连续
    （无效信号被跳过/手部丢失），此时结算当前停顿段并跳过，
    避免跨空洞误判为静止。
    """
    if len(signal_buf) < 2:
        return []
    sig = np.array(signal_buf)
    t = np.array(time_buf)
    rng = np.ptp(sig)
    if rng < 1e-6:
        rng = 1.0
    thr = rng * 0.05
    pauses = []
    pause_start = None
    for i in range(1, len(sig)):
        dt = t[i] - t[i - 1]
        if dt > continuity_gap or dt < 0:
            # 数据不连续：结算当前停顿段并重新开始
            if pause_start is not None:
                dur = t[i - 1] - pause_start
                if dur >= pause_threshold:
                    pauses.append(dur)
                pause_start = None
            continue
        if abs(sig[i] - sig[i - 1]) < thr:
            if pause_start is None:
                pause_start = t[i - 1]
        else:
            if pause_start is not None:
                dur = t[i - 1] - pause_start
                if dur >= pause_threshold:
                    pauses.append(dur)
                pause_start = None
    return pauses


def _compute_pause_intervals(times, pause_threshold=0.8):
    """从动作时间戳列表检测停顿：相邻两次动作间隔超过阈值。"""
    pauses = []
    for i in range(1, len(times)):
        gap = times[i] - times[i - 1]
        if gap > pause_threshold:
            pauses.append(gap)
    return pauses


def _analyze_pauses(pauses, freeze_threshold):
    total = len(pauses)
    freezes = sum(1 for p in pauses if p >= freeze_threshold)
    return {"total_pauses": total, "long_freezes": freezes}


def _analyze_speed(durations, thresholds):
    """速度变化比：首 1/3 平均速度 vs 末 1/3 平均速度。"""
    if len(durations) < 2:
        return {"slow_level": 0, "speed_ratio": 1.0}
    speeds = [1.0 / d for d in durations if d > 0]
    if len(speeds) < 2:
        return {"slow_level": 0, "speed_ratio": 1.0}
    third = max(1, len(speeds) // 3)
    first_avg = sum(speeds[:third]) / third
    last_avg = sum(speeds[-third:]) / third
    ratio = last_avg / first_avg if first_avg > 0 else 1.0
    level = 0
    for i, t in enumerate(thresholds):
        if ratio < t:
            level = i + 1
    return {"slow_level": level, "speed_ratio": ratio}


def _analyze_amplitude(amplitudes):
    """幅度衰减分级：基准取序列峰值，按前后半段平均判定。

    - 3 级：前一半平均幅度不足峰值 70%（一开始就衰减）
    - 2 级：后一半平均幅度不足峰值 70%（中后期明显衰减）
    - 1 级：后一半平均幅度不足峰值 90%（仅末期轻度衰减）
    """
    valid = [a for a in amplitudes if a is not None and a > 0]
    if not valid:
        return {"amplitude_decrease": 0}
    base = float(np.max(valid))
    if base <= 0:
        return {"amplitude_decrease": 0}
    ratios = [a / base for a in valid]
    n = len(ratios)
    decrease = 0
    if n >= 4:
        half = n // 2
        first_avg = sum(ratios[:half]) / half
        last_avg = sum(ratios[half:]) / (n - half)
        if first_avg < 0.7:
            decrease = 3
        elif last_avg < 0.7:
            decrease = 2
        elif last_avg < 0.9:
            decrease = 1
    return {"amplitude_decrease": decrease}


def _mds_updrs_score(pause_analysis, speed_analysis, amplitude_analysis):
    total_pauses = pause_analysis["total_pauses"]
    long_freezes = pause_analysis["long_freezes"]
    slow_level = speed_analysis["slow_level"]
    amp_decrease = amplitude_analysis["amplitude_decrease"]

    if total_pauses == 0:
        pause_sub = 0
    elif total_pauses <= 2:
        pause_sub = 1
    elif total_pauses <= 5 and long_freezes == 0:
        pause_sub = 2
    else:
        # >5 次停顿，或 3-5 次但存在冻结（freezing）
        pause_sub = 3

    score = math.ceil((pause_sub + slow_level + amp_decrease) / 3.0)

    reasons = []
    if score == 0:
        reasons.append("Normal: No problems detected")
    else:
        if total_pauses == 0:
            reasons.append("No pauses detected")
        elif total_pauses <= 2:
            reasons.append(f"1-2 hesitations/arrests ({total_pauses} pauses)")
        elif 3 <= total_pauses <= 5:
            reasons.append(f"3-5 arrests ({total_pauses} pauses)")
        else:
            reasons.append(f">5 arrests or freezing ({total_pauses} pauses)")

        labels = ["Normal speed", "Slight slowing", "Mild slowing",
                  "Moderate slowing", "Severe slowing"]
        reasons.append(labels[min(slow_level, 4)])

        amp_labels = [
            "Normal amplitude", "Amplitude decreases near end",
            "Amplitude decreases halfway", "Amplitude decreases from start",
        ]
        reasons.append(amp_labels[min(amp_decrease, 3)])

    return score, reasons


_INCOMPLETE_FLAG = "INCOMPLETE"


def _build_task_result(score, reasons, action_count, required, pauses,
                       speed_ratio, amp_decrease):
    complete = action_count >= required
    return {
        "status": "COMPLETE" if complete else _INCOMPLETE_FLAG,
        "detected_actions": action_count,
        "required_actions": required,
        "score": score,
        "reasons": reasons,
        "pauses": pauses,
        "speed_ratio": round(speed_ratio, 3),
        "amplitude_decrease_level": amp_decrease,
    }


def _mirror_label(handedness, idx):
    raw = handedness[idx].classification[0].label.capitalize()
    return "Right" if raw == "Left" else "Left"


def _parse_segment_manifest(path: Path) -> Tuple[List[Dict[str, Any]], Optional[tuple]]:
    """解析手部分段清单（CSV/JSON），校验格式与时间。

    与整体姿态一致：列 segment_id/label/task_type/start_s/end_s，
    时间以视频第一帧为 0 基准；要求不重叠、ID 唯一。
    JSON 顶层可携带 crop_region（[x, y, w, h]）作用于整段视频。
    返回 (按 start_s 排序的分段列表, crop_region 或 None)。
    """
    crop_region: Optional[tuple] = None
    if path.suffix.lower() == ".json":
        payload = json.loads(path.read_text(encoding="utf-8-sig"))
        if isinstance(payload, dict):
            raw_crop = payload.get("crop_region")
            if raw_crop is not None:
                if (
                    not isinstance(raw_crop, (list, tuple))
                    or len(raw_crop) != 4
                ):
                    raise ValueError("crop_region 必须是 [x, y, w, h] 数组")
                values = tuple(int(v) for v in raw_crop)
                if min(values) < 0:
                    raise ValueError("crop_region 不允许负值")
                crop_region = values
            rows = payload.get("segments", [])
        elif isinstance(payload, list):
            rows = payload
        else:
            raise ValueError("JSON 必须是分段数组或包含 segments 的对象")
        if not isinstance(rows, list):
            raise ValueError("segments 必须是数组")
    else:
        with path.open("r", newline="", encoding="utf-8-sig") as handle:
            rows = list(csv.DictReader(handle))

    required = {"segment_id", "label", "task_type", "start_s", "end_s"}
    segments: List[Dict[str, Any]] = []
    ids: set[str] = set()
    for index, raw in enumerate(rows, start=1):
        if not isinstance(raw, dict):
            raise ValueError(f"第 {index} 个分段不是对象")
        missing = required - set(raw)
        if missing:
            raise ValueError(
                f"第 {index} 个分段缺少：{', '.join(sorted(missing))}"
            )
        segment_id = str(raw["segment_id"]).strip()
        label = str(raw["label"]).strip()
        task_type = str(raw["task_type"]).strip().lower()
        if not segment_id or not label or not task_type:
            raise ValueError(f"第 {index} 个分段的 ID/label/task_type 为空")
        if segment_id in ids:
            raise ValueError(f"segment_id 重复：{segment_id}")
        ids.add(segment_id)
        try:
            start_s = float(raw["start_s"])
            end_s = float(raw["end_s"])
        except (TypeError, ValueError) as exc:
            raise ValueError(
                f"第 {index} 个分段 start_s/end_s 无效"
            ) from exc
        if (
            start_s < 0
            or end_s <= start_s
            or not math.isfinite(start_s)
            or not math.isfinite(end_s)
        ):
            raise ValueError(f"第 {index} 个分段时间范围无效")
        segments.append(
            {
                "segment_id": segment_id,
                "label": label,
                "task_type": task_type,
                "start_s": start_s,
                "end_s": end_s,
            }
        )
    if not segments:
        raise ValueError("分段清单中没有有效片段")
    segments.sort(key=lambda item: item["start_s"])
    for previous, current in zip(segments, segments[1:]):
        if current["start_s"] < previous["end_s"]:
            raise ValueError(
                f"分段 {previous['segment_id']} 与 {current['segment_id']} 时间重叠"
            )
    return segments, crop_region


# ============================================================================
# HandMotionModule
# ============================================================================

class HandMotionModule(InferenceModule):
    """Hand motion analysis: finger opposition, alternation, fist clenching.

    MediaPipe Hands runs once; all three scorers share the same landmarks.
    No OpenCV GUI, no annotated video output.
    """

    # ===== 通用任务参数 =====

    # 每只手每个动作需要检测到多少次才进行评分（不足时发出警告）
    REQUIRED_ACTIONS = 10
    # 手部检测区域 (x, y, w, h)，只处理全帧中该区域（减小误检、提速）；
    # 分段模式优先使用 segments.json 顶层的 crop_region，无则用此默认值
    CROP_REGION = (400, 100, 480, 480)

    # ===== MediaPipe Hands 检测参数 =====

    # 手部检测置信度阈值（首次检测到手的最低置信度）
    MIN_DETECTION_CONFIDENCE = 0.60
    # 手部跟踪置信度阈值（后续帧沿用已有手的最低置信度）
    MIN_TRACKING_CONFIDENCE = 0.60
    # 模型复杂度：0=轻量（快/精度低），1=完整（慢/精度高）
    MODEL_COMPLEXITY = 1

    # ===== 对指（Duizhi）参数 =====

    # 对指信号阈值：拇指指尖-食指指尖归一化距离 < 0.5 视为"接触/触碰"
    # （距离 0=完全接触，1=完全张开）
    TOUCH_SIGNAL_THRESHOLD = 0.5
    # 对指信号阈值：> 0.7 视为"张开"（与接触交替形成一次对指动作）
    OPEN_SIGNAL_THRESHOLD = 0.7
    # 食指伸展判定角度：食指伸直（关节角 > 60°）时对指信号才有效，
    # 避免握拳等其他手势干扰对指检测
    INDEX_EXTENSION_ANGLE = 60.0
    # 对指两次计数之间的最小间隔（秒），防止快速抖动/噪声重复计数
    DEBOUNCE_DUIZHI = 0.2

    # ===== 轮替（Lunti）参数 =====

    # 轮替信号阈值：小指-拇指 x 距离（相对腕-中指距离归一化）×100，
    # > +8 视为手掌朝上、< -8 视为手掌朝下（翻转一次计一次）
    LUNTI_SIGNAL_THRESHOLD = 8.0
    # 轮替信号最小原始 x 差（归一化坐标）：小指与拇指的 x 差小于此值
    # 时判定方向无意义（如握拳/手部直立），信号置 0 不参与翻转判断
    LUNTI_MIN_RAW_DX = 0.002
    # 轮替两次计数之间的最小间隔（秒）
    DEBOUNCE_LUNTI = 0.2
    # 轮替方向需连续保持该时长（秒）才确认有效，防止静止手信号
    # 抖动穿越阈值被误计为翻转（值越小越灵敏、误检越多）
    ALT_MIN_DIRECTION_TIME = 0.06

    # ===== 握拳（Woquan）检测参数 =====

    # 握拳信号缓冲区大小（帧数），用于谷值/峰值检测
    DETECT_BUFFER_SIZE = 30
    # 信号平滑窗口（帧数），对原始信号做滑动平均降噪
    DETECT_SMOOTHING = 3
    # 谷值最小突出度：信号下降幅度相对近期峰值需 ≥ 0.06 才认为是"握拳谷值"
    DETECT_MIN_PROMINENCE = 0.06
    # 谷值最小绝对幅度：信号值必须低于 1.0 - 0.10 才计入（握拳必须足够深）
    DETECT_MIN_ABS_AMPLITUDE = 0.10
    # 信号必须持续下降至少 0.10 秒才允许判定谷值（过滤瞬时抖动）
    DETECT_MIN_DIRECTION_TIME = 0.10
    # 握拳两次计数之间的最小间隔（秒）
    DEBOUNCE_WOQUAN = 0.2
    # 握拳判定角度阈值：四指弯曲角（中位数）< 160° 视为弯曲（握拳），
    # 弯曲手指数 ≥ 3 时握拳信号才有效
    FIST_ANGLE_THRESHOLD = 160.0
    # 校准帧数：前 90 帧用于估计每只手张开时的信号基线
    CALIB_FRAMES = 90
    # 信号基线默认最大值：张开手的角度值（无校准时直接除以 170 归一化）
    DEFAULT_MAX_ANGLE = 170.0
    # 归一化信号下限：信号被限制在 ≥ 0.3（防止数值异常放大）
    SIGNAL_CLAMP_MIN = 0.3
    # 归一化信号上限：信号被限制在 ≤ 1.2（防止瞬间噪声撑大基线）
    SIGNAL_CLAMP_MAX = 1.2
    # 腕部移动阈值（归一化坐标/帧）：腕点帧间位移超过 0.008 视为手在
    # 移动，此时抑制握拳检测（握拳时手不应大幅移动）
    WRIST_MOVEMENT_THRESHOLD = 0.008

    # ===== 评分（MDS-UPDRS）参数 =====

    # 停顿阈值（秒）：两次动作间隔 > 1.5s 计一次"停顿/中断"
    PAUSE_THRESHOLD = 1.5
    # 冻结阈值（秒）：停顿持续 > 3.0s 视为"冻结"（评分升级的依据）
    FREEZE_THRESHOLD = 3.0

    def descriptor(self):
        return ModelModuleDescriptor(
            id="hand-motion",
            display_name="手部运动分析",
            category="hand",
            description=(
                "基于 MediaPipe Hands 的手部三任务评分："
                "手指对指（MDS-UPDRS 3.4）、手掌轮替（3.5）、握拳（3.6）。"
            ),
            status="ready",
            status_detail=(
                "已集成三个手部动作评分器，输入 RealSense .bag 或普通视频。"
            ),
            input_kinds=["realsense_bag", "video"],
            input_slots=[
                InputSlotDescriptor(
                    key="hand_video",
                    label="手部视频输入",
                    description=(
                        "一段包含手指对指、手掌轮替和握拳动作的 RealSense "
                        ".bag 或普通视频。三个任务共享同一组关键点并行评分。"
                    ),
                    accepted_kinds=["realsense_bag", "video"],
                    required=True,
                    multiple=False,
                ),
                InputSlotDescriptor(
                    key="segment_manifest",
                    label="手部动作分段清单（可选）",
                    description=(
                        "与整体姿态一致的分段文件（segments.csv/json，"
                        "包含 segment_id、label、task_type、start_s、end_s）。"
                        "提供且格式合法时启用分段模式：每个分段独立识别与评分，"
                        "每个分段输出一段标注视频。"
                    ),
                    accepted_kinds=["tabular"],
                    required=False,
                    multiple=False,
                ),
            ],
            output_capabilities=[
                "mds_updrs_scores",
                "per_task_scores",
                "pause_analysis",
                "speed_analysis",
                "amplitude_analysis",
            ],
            model_version="1.0.0",
        )

    def validate(self, request):
        issues = []
        # 只检查 hand_video 槽的视频文件；segment_manifest 单独校验
        video_files = request.inputs.get("hand_video", ())
        if not video_files:
            issues.append("至少需要提供一个手部视频或 RealSense .bag 文件。")
            return issues

        for a in video_files:
            if not a.path.exists():
                issues.append(f"文件不存在：{a.path}")
            elif a.path.suffix.lower() not in (".bag", ".avi", ".mp4", ".mov", ".mkv"):
                issues.append(f"不支持的视频格式：{a.path.suffix}")

        try:
            import pyrealsense2  # noqa
        except ImportError:
            issues.append("缺少 pyrealsense2 库，无法播放 RealSense .bag 文件。")
        try:
            import mediapipe  # noqa
            prepare_legacy_solutions()
        except ImportError:
            issues.append("缺少 mediapipe 库，无法进行手部关键点检测。")
        except RuntimeError as error:
            issues.append(str(error))

        manifest_files = request.inputs.get("segment_manifest", ())
        if manifest_files:
            if len(manifest_files) != 1:
                issues.append("segment_manifest 必须且只能提供一个 CSV/JSON。")
            else:
                manifest_path = Path(str(manifest_files[0].path))
                if not manifest_path.is_file():
                    issues.append(f"分段清单不存在：{manifest_path}")
                elif manifest_path.suffix.lower() not in {".csv", ".json"}:
                    issues.append("segment_manifest 只支持 .csv 或 .json。")
                else:
                    try:
                        _parse_segment_manifest(manifest_path)
                    except (OSError, ValueError, json.JSONDecodeError) as error:
                        issues.append(f"分段清单无效：{error}")

        return issues

    @staticmethod
    def _output_dir(request: InferenceRequest) -> Path:
        configured = request.parameters.get("output_dir")
        if configured:
            return Path(str(configured)).resolve()
        return (
            Path(tempfile.gettempdir())
            / "medvision_hand_motion"
            / request.assessment_id
        ).resolve()

    def _update_hand_state(
        self,
        st: Dict[str, Any],
        hand_lm,
        now: float,
        task_type: Optional[str] = None,
    ) -> None:
        """用一帧的手部关键点更新单只手（属于某个分段）的状态机。

        分段模式下 task_type 指定该分段的任务，只运行对应的检测算法；
        task_type 为 None（无分段模式）时三个任务同时运行。
        包含：重检测重置、对指状态机、轮替状态机、握拳检测与校准、
        腕部移动抑制、信号缓冲。
        """
        # 本分段需要运行的任务
        run_opp = task_type is None or task_type == "finger_opposition"
        run_alt = task_type is None or task_type == "hand_alternation"
        run_fist = task_type is None or task_type == "fist_clenching"

        # ---- re-detection: reset fist detector smooth state ----
        if run_fist and st["was_lost"]:
            st["was_lost"] = False
            raw = fist_signal(hand_lm, self.FIST_ANGLE_THRESHOLD)
            init_sig = (
                raw if raw < INVALID_SIGNAL_SENTINEL
                else self.DEFAULT_MAX_ANGLE
            ) / self.DEFAULT_MAX_ANGLE
            st["fist"].reset_smooth(init_sig)

        if run_opp:
            self._update_opposition(st, hand_lm, now)
        if run_alt:
            self._update_alternation(st, hand_lm, now)
        if run_fist:
            self._update_fist(st, hand_lm, now)

    def _update_opposition(self, st: Dict[str, Any], hand_lm, now: float) -> None:
        """对指状态机 + 张开峰值幅度 + 信号缓冲。"""
        raw_opp = opposition_signal(hand_lm, self.INDEX_EXTENSION_ANGLE)
        is_fist_opp = raw_opp >= INVALID_SIGNAL_SENTINEL
        is_touch = (
            (not is_fist_opp)
            and raw_opp < self.TOUCH_SIGNAL_THRESHOLD
        )
        is_open = raw_opp > self.OPEN_SIGNAL_THRESHOLD or is_fist_opp

        os_ = st["opp"]
        debounce_ok = (
            now - os_["last_action_time"]
        ) > self.DEBOUNCE_DUIZHI

        # 张开峰值（幅度）：仅在有效信号时累计
        if not is_fist_opp and not os_["in_opposition"]:
            os_["open_peak"] = max(os_.get("open_peak", 0.0), raw_opp)

        if not os_["in_opposition"] and is_touch and debounce_ok:
            os_["in_opposition"] = True
            os_["state"] = "TOUCH"
            peak = os_.get("open_peak", 0.0)
            if peak > 0:
                st["amp_opp"].append(peak)
            os_["open_peak"] = 0.0
            os_["current_record"] = {"start_time": now}
        elif os_["in_opposition"] and is_open and debounce_ok:
            os_["in_opposition"] = False
            os_["state"] = "OPEN"
            os_["count"] += 1
            os_["last_action_time"] = now
            cr = os_.get("current_record")
            if cr:
                cr["end_time"] = now
                os_["records"].append(cr)
            os_["current_record"] = None
        elif not os_["in_opposition"]:
            os_["state"] = "OPEN" if is_open else "UNKNOWN"

        # 对指信号缓冲：仅收集有效信号（握拳手势跳过），
        # 避免哨兵常量污染停顿检测的幅度范围
        if not is_fist_opp:
            st["signal_buf"].append(raw_opp)
            st["time_buf"].append(now)

    def _update_alternation(self, st: Dict[str, Any], hand_lm, now: float) -> None:
        """轮替状态机（方向持续确认防抖）。

        手静止时 MediaPipe 关键点仍有微小抖动，信号可能在阈值
        附近来回穿越；方向需连续保持 ALT_MIN_DIRECTION_TIME 秒
        才视为有效，避免静止手被误计。
        """
        alt_sig = alternation_signal(hand_lm)
        raw_dx = abs(hand_lm.landmark[17].x - hand_lm.landmark[2].x)
        if raw_dx < self.LUNTI_MIN_RAW_DX:
            cur_sign = 0
        else:
            cur_sign = (
                1 if alt_sig > self.LUNTI_SIGNAL_THRESHOLD
                else (-1 if alt_sig < -self.LUNTI_SIGNAL_THRESHOLD else 0)
            )
        as_ = st["alt"]
        last_frame = as_.get("last_frame_time")
        dt = max(0.0, now - last_frame) if last_frame is not None else 0.0
        as_["last_frame_time"] = now
        if cur_sign != 0:
            if cur_sign == as_["cur_sign"]:
                as_["same_dir_time"] += dt
            else:
                as_["cur_sign"] = cur_sign
                as_["same_dir_time"] = 0.0
        else:
            as_["cur_sign"] = 0
            as_["same_dir_time"] = 0.0
        valid_sign = (
            as_["cur_sign"]
            if as_["same_dir_time"] >= self.ALT_MIN_DIRECTION_TIME
            else 0
        )
        if (
            valid_sign != 0
            and valid_sign != as_["prev_sign"]
            and as_["prev_sign"] != 0
        ):
            if now - as_["last_action_time"] > self.DEBOUNCE_LUNTI:
                as_["count"] += 1
                as_["last_action_time"] = now
                as_["prev_sign"] = valid_sign
                as_["records"].append({"time": now, "signal": alt_sig})
                st["amp_alt"].append(abs(alt_sig))
        elif valid_sign != 0 and as_["prev_sign"] == 0:
            as_["prev_sign"] = valid_sign

    def _update_fist(self, st: Dict[str, Any], hand_lm, now: float) -> None:
        """握拳检测与校准、腕部移动抑制。"""
        raw_fist = fist_signal(hand_lm, self.FIST_ANGLE_THRESHOLD)

        if raw_fist < INVALID_SIGNAL_SENTINEL:
            if not st["fist_posture"]:
                st["fist_posture"] = True
        else:
            bent_count = sum(
                1 for a in [
                    _joint_angle(
                        hand_lm.landmark[m], hand_lm.landmark[p],
                        hand_lm.landmark[t],
                    )
                    for m, p, t in [
                        (5, 6, 8), (9, 10, 12),
                        (13, 14, 16), (17, 18, 20),
                    ]
                ] if a < 150.0
            )
            if bent_count <= 1:
                st["fist_posture"] = False

        is_fist_p = st["fist_posture"]

        if not st["fist_calib_locked"]:
            st["fist_calib_frames"] += 1
            if is_fist_p and raw_fist < INVALID_SIGNAL_SENTINEL:
                st["fist_running_max"] = max(
                    st["fist_running_max"], raw_fist
                )
            if st["fist_calib_frames"] >= self.CALIB_FRAMES:
                st["fist_calib_max"] = max(
                    st["fist_running_max"], self.DEFAULT_MAX_ANGLE,
                )
                st["fist_calib_locked"] = True
            denom = max(st["fist_running_max"], self.DEFAULT_MAX_ANGLE)
            fist_sig_val = (
                raw_fist
                if (is_fist_p and raw_fist < INVALID_SIGNAL_SENTINEL)
                else denom
            ) / denom
        else:
            denom = st["fist_calib_max"]
            fist_sig_val = (
                raw_fist
                if (is_fist_p and raw_fist < INVALID_SIGNAL_SENTINEL)
                else denom
            ) / denom

        fist_sig_val = max(
            self.SIGNAL_CLAMP_MIN,
            min(self.SIGNAL_CLAMP_MAX, fist_sig_val),
        )
        st["last_valid_signal"] = fist_sig_val

        # ---- wrist movement suppression ----
        wrist_x = hand_lm.landmark[0].x
        wrist_y = hand_lm.landmark[0].y
        if st["last_wrist_pos"] is not None:
            dx = wrist_x - st["last_wrist_pos"][0]
            dy = wrist_y - st["last_wrist_pos"][1]
            spd = np.sqrt(dx * dx + dy * dy)
            st["wrist_moving"] = spd > self.WRIST_MOVEMENT_THRESHOLD
        st["last_wrist_pos"] = (wrist_x, wrist_y)

        event = None
        if not st["wrist_moving"]:
            event = st["fist"].update(fist_sig_val, now)
        if event is not None:
            st["amp_fist"].append(event.amplitude)

    def _score_hand_state(
        self,
        st: Dict[str, Any],
        hl: str,
        task_type: Optional[str] = None,
    ) -> Tuple[Dict[str, Any], List[str]]:
        """对单只手（属于某个分段）的状态做评分。

        分段模式下只评分 task_type 对应的任务（不产生其他任务的
        "动作不足"警告）；task_type 为 None 时三个任务都评分。
        返回 (tasks, warnings)。
        """
        tasks: Dict[str, Any] = {
            "finger_opposition": {},
            "hand_alternation": {},
            "fist_clenching": {},
        }
        warnings: List[str] = []
        run_opp = task_type is None or task_type == "finger_opposition"
        run_alt = task_type is None or task_type == "hand_alternation"
        run_fist = task_type is None or task_type == "fist_clenching"

        if run_opp:
            self._score_opposition(st, hl, tasks, warnings)
        if run_alt:
            self._score_alternation(st, hl, tasks, warnings)
        if run_fist:
            self._score_fist(st, hl, tasks, warnings)

        return tasks, warnings

    def _score_opposition(
        self,
        st: Dict[str, Any],
        hl: str,
        tasks: Dict[str, Any],
        warnings: List[str],
    ) -> None:
        opp_records = st["opp"]["records"]
        opp_count = st["opp"]["count"]
        opp_pause_list = _compute_pauses(
            st["signal_buf"], st["time_buf"], self.PAUSE_THRESHOLD,
        )
        opp_pause = _analyze_pauses(opp_pause_list, self.FREEZE_THRESHOLD)
        opp_durations = [
            opp_records[i]["end_time"] - opp_records[i - 1]["end_time"]
            for i in range(1, len(opp_records))
        ]
        opp_speed = _analyze_speed(opp_durations, SPEED_THRESHOLDS_DUIZHI)
        opp_amp = _analyze_amplitude(st["amp_opp"])
        opp_score, opp_reasons = _mds_updrs_score(
            opp_pause, opp_speed, opp_amp,
        )
        tasks["finger_opposition"][hl.lower()] = _build_task_result(
            opp_score, opp_reasons, opp_count,
            self.REQUIRED_ACTIONS, opp_pause["total_pauses"],
            opp_speed["speed_ratio"], opp_amp["amplitude_decrease"],
        )
        if opp_count < self.REQUIRED_ACTIONS:
            warnings.append(
                f"{hl} 手指对指动作不足：仅检测到 {opp_count} 次"
                f"（需 {self.REQUIRED_ACTIONS} 次）"
            )

    def _score_alternation(
        self,
        st: Dict[str, Any],
        hl: str,
        tasks: Dict[str, Any],
        warnings: List[str],
    ) -> None:
        alt_records = st["alt"]["records"]
        alt_count = st["alt"]["count"]
        alt_times = [r["time"] for r in alt_records]
        alt_pause_list = _compute_pause_intervals(
            alt_times, self.PAUSE_THRESHOLD,
        )
        alt_pause = _analyze_pauses(alt_pause_list, self.FREEZE_THRESHOLD)
        alt_durations = [
            alt_records[i]["time"] - alt_records[i - 1]["time"]
            for i in range(1, len(alt_records))
        ]
        alt_speed = _analyze_speed(alt_durations, SPEED_THRESHOLDS_LUNTI)
        alt_amp = _analyze_amplitude(st["amp_alt"])
        alt_score, alt_reasons = _mds_updrs_score(
            alt_pause, alt_speed, alt_amp,
        )
        tasks["hand_alternation"][hl.lower()] = _build_task_result(
            alt_score, alt_reasons, alt_count,
            self.REQUIRED_ACTIONS, alt_pause["total_pauses"],
            alt_speed["speed_ratio"], alt_amp["amplitude_decrease"],
        )
        if alt_count < self.REQUIRED_ACTIONS:
            warnings.append(
                f"{hl} 手掌轮替动作不足：仅检测到 {alt_count} 次"
                f"（需 {self.REQUIRED_ACTIONS} 次）"
            )

    def _score_fist(
        self,
        st: Dict[str, Any],
        hl: str,
        tasks: Dict[str, Any],
        warnings: List[str],
    ) -> None:
        fist_det = st["fist"]
        fist_count = fist_det.get_event_count()
        fist_records = fist_det.action_records
        fist_times = [r.timestamp for r in fist_records]
        fist_pause_list = _compute_pause_intervals(
            fist_times, self.PAUSE_THRESHOLD,
        )
        fist_pause = _analyze_pauses(fist_pause_list, self.FREEZE_THRESHOLD)
        fist_durations = [
            fist_records[i].timestamp - fist_records[i - 1].timestamp
            for i in range(1, len(fist_records))
        ]
        fist_speed = _analyze_speed(fist_durations, SPEED_THRESHOLDS_WOQUAN)
        fist_amp = _analyze_amplitude(st["amp_fist"])
        fist_score, fist_reasons = _mds_updrs_score(
            fist_pause, fist_speed, fist_amp,
        )
        tasks["fist_clenching"][hl.lower()] = _build_task_result(
            fist_score, fist_reasons, fist_count,
            self.REQUIRED_ACTIONS, fist_pause["total_pauses"],
            fist_speed["speed_ratio"], fist_amp["amplitude_decrease"],
        )
        if fist_count < self.REQUIRED_ACTIONS:
            warnings.append(
                f"{hl} 握拳动作不足：仅检测到 {fist_count} 次"
                f"（需 {self.REQUIRED_ACTIONS} 次）"
            )

        return tasks, warnings

    def infer(self, request, progress=None):
        import pyrealsense2 as rs
        import mediapipe as mp
        import cv2
        prepare_legacy_solutions()

        video_files = request.inputs.get("hand_video", ())
        if not video_files:
            raise ModuleUnavailableError("没有可用的输入文件。")

        bag_path = Path(str(video_files[0].path))
        if not bag_path.exists():
            raise ModuleUnavailableError(f"输入文件不存在：{bag_path}")

        suffix = bag_path.suffix.lower()
        is_bag = suffix == ".bag"

        # ---- open video source ----
        def _open_source():
            """打开视频源，返回 (read_fn, probe_fn, cleanup, nominal_fps)。

            read_fn 返回 (完整帧, depth_frame|None, 时间戳秒, is_rgb)。
            RealSense 帧为 RGB 视图（零拷贝），普通视频为 BGR；
            裁剪在调用方进行，以便标注视频保留完整画面。
            probe_fn 只取帧时间戳（不做 align/numpy），用于快速测帧率。
            """
            if is_bag:
                pipeline = rs.pipeline()
                config = rs.config()
                rs.config.enable_device_from_file(
                    config, str(bag_path), repeat_playback=False,
                )
                profile = pipeline.start(config)
                # 非实时播放：尽快送出所有帧，避免处理速度拖慢播放器
                # 导致丢帧/卡顿（wait_for_frames 超时被误判为结束）
                try:
                    profile.get_device().as_playback().set_real_time(False)
                except Exception:
                    pass
                align = rs.align(rs.stream.color)
                color_profile = profile.get_stream(rs.stream.color)
                nominal_fps = color_profile.as_video_stream_profile().fps()

                def _read_bag():
                    try:
                        frames = pipeline.wait_for_frames(timeout_ms=5000)
                    except RuntimeError:
                        return None
                    ts = frames.get_timestamp() / 1000.0
                    af = align.process(frames)
                    df = af.get_depth_frame()
                    cf = af.get_color_frame()
                    if not df or not cf:
                        return None
                    # RealSense 原生 RGB：返回视图（必要时转连续，
                    # MediaPipe 要求 c_contiguous；连续时零拷贝）
                    ci = np.ascontiguousarray(np.asanyarray(cf.get_data()))
                    return ci, df, ts, True

                def _probe_bag():
                    """只取帧时间戳，跳过 align/numpy（测帧率用）。"""
                    try:
                        frames = pipeline.wait_for_frames(timeout_ms=5000)
                    except RuntimeError:
                        return None
                    if (
                        frames.get_depth_frame() is None
                        or frames.get_color_frame() is None
                    ):
                        return None
                    return frames.get_timestamp() / 1000.0

                def _cleanup_bag():
                    pipeline.stop()

                return _read_bag, _probe_bag, _cleanup_bag, nominal_fps

            cap = cv2.VideoCapture(str(bag_path))
            nominal_fps = cap.get(cv2.CAP_PROP_FPS) or 30.0

            def _read_video():
                ok, frame = cap.read()
                if not ok:
                    return None
                return (
                    frame,
                    None,
                    cap.get(cv2.CAP_PROP_POS_MSEC) / 1000.0,
                    False,
                )

            def _probe_video():
                """只推进帧位置取时间戳，不解码图像（测帧率用）。"""
                if not cap.grab():
                    return None
                return cap.get(cv2.CAP_PROP_POS_MSEC) / 1000.0

            def _cleanup_video():
                cap.release()

            return _read_video, _probe_video, _cleanup_video, nominal_fps

        # ---- 探测实际帧率（按帧时间戳计算） ----
        # RealSense .bag 的标称 fps 与录制实际帧率可能不一致，
        # 直接按标称值写视频会导致标注视频时长严重失真（加速/减速）。
        # 探测只取时间戳（不做 align/numpy），开销远小于正式处理。
        _, probe_fn, probe_cleanup, nominal_fps = _open_source()
        first_ts: Optional[float] = None
        last_ts: Optional[float] = None
        probe_count = 0
        try:
            while True:
                ts = probe_fn()
                if ts is None:
                    break
                if first_ts is None:
                    first_ts = ts
                last_ts = ts
                probe_count += 1
        finally:
            probe_cleanup()

        fps = nominal_fps
        if (
            probe_count > 2
            and first_ts is not None
            and last_ts is not None
            and last_ts > first_ts
        ):
            measured_fps = (probe_count - 1) / (last_ts - first_ts)
            if 1.0 <= measured_fps <= 240.0:
                fps = measured_fps
        logger.info(
            "手部模块帧率探测：标称 %.2f fps，实际 %.2f fps，%d 帧",
            nominal_fps, fps, probe_count,
        )

        read_fn, _, cleanup, _ = _open_source()

        # ---- MediaPipe Hands ----
        mp_hands = mp.solutions.hands
        hands = mp_hands.Hands(
            static_image_mode=False,
            max_num_hands=2,
            min_detection_confidence=self.MIN_DETECTION_CONFIDENCE,
            min_tracking_confidence=self.MIN_TRACKING_CONFIDENCE,
            model_complexity=self.MODEL_COMPLEXITY,
        )

        # ---- annotated video output ----
        output_dir = self._output_dir(request)
        annotated_video_dir = output_dir / "videos"
        video_writers: Dict[str, Any] = {}
        annotated_video_paths: Dict[str, Path] = {}
        input_stem = Path(str(video_files[0].path)).stem

        # ---- 分段模式：可选分段清单（参考整体姿态） ----
        segments: List[Dict[str, Any]] = []
        manifest_crop_region: Optional[tuple] = None
        manifest_files = request.inputs.get("segment_manifest", ())
        if manifest_files:
            segments, manifest_crop_region = _parse_segment_manifest(
                Path(str(manifest_files[0].path))
            )
            logger.info("手部模块启用分段模式：%d 个分段", len(segments))
        max_end_s = max((s["end_s"] for s in segments), default=None)

        # 分段 ID -> 任务类型（分段模式只运行对应任务的检测算法）
        seg_task_types = {
            s["segment_id"]: s["task_type"] for s in segments
        }

        # 裁剪区域：清单携带的优先，否则用模块默认
        crop_region = manifest_crop_region or self.CROP_REGION

        # ---- per-(segment × hand) state ----
        def _new_hand_state() -> Dict[str, Any]:
            """一只手的独立状态（对指/轮替/握拳/校准/信号缓冲）。"""
            return {
                "opp": {
                    "state": "OPEN", "in_opposition": False,
                    "count": 0, "last_action_time": 0.0,
                    "records": [], "current_record": None,
                    "open_peak": 0.0,
                },
                "alt": {
                    "prev_sign": 0, "count": 0,
                    "last_action_time": 0.0, "records": [],
                    "cur_sign": 0, "same_dir_time": 0.0,
                    "last_frame_time": None,
                },
                "fist": ActionDetector(
                    mode="valley",
                    buffer_size=self.DETECT_BUFFER_SIZE,
                    min_prominence=self.DETECT_MIN_PROMINENCE,
                    min_interval=self.DEBOUNCE_WOQUAN,
                    smoothing_window=self.DETECT_SMOOTHING,
                    min_abs_amplitude=self.DETECT_MIN_ABS_AMPLITUDE,
                    min_direction_time=self.DETECT_MIN_DIRECTION_TIME,
                ),
                "fist_calib_frames": 0,
                "fist_calib_max": self.DEFAULT_MAX_ANGLE,
                "fist_calib_locked": False,
                "fist_running_max": self.DEFAULT_MAX_ANGLE,
                "fist_posture": False,
                "last_wrist_pos": None,
                "wrist_moving": False,
                "last_valid_signal": 1.0,
                "signal_buf": deque(),
                "time_buf": deque(),
                "amp_opp": [],
                "amp_alt": [],
                "amp_fist": [],
                "was_lost": False,
            }

        # seg_key -> hand_label -> state；无分段时用隐式 "__whole__"
        states: Dict[str, Dict[str, Any]] = {}

        def _ensure_state(seg_key: str) -> Dict[str, Any]:
            if seg_key not in states:
                states[seg_key] = {
                    "Left": _new_hand_state(),
                    "Right": _new_hand_state(),
                    # handedness 翻转抑制：按手索引跟踪标签稳定性，
                    # 连续 3 帧同标签才切换（握拳时手掌朝向变化会导致
                    # MediaPipe handedness 在帧间抖动，动作被拆分到两只手）
                    "label_track": {
                        0: {"label": None, "candidate": None, "count": 0},
                        1: {"label": None, "candidate": None, "count": 0},
                    },
                }
            return states[seg_key]

        try:
            frame_idx = 0
            first_frame_ts: Optional[float] = None
            while True:
                ret = read_fn()
                if ret is None:
                    break
                full_color, depth_frame, timestamp, is_rgb = ret
                frame_idx += 1
                if first_frame_ts is None:
                    first_frame_ts = timestamp

                # 分段模式：只处理落在分段内的帧
                if segments:
                    timestamp_s = timestamp - first_frame_ts
                    active_keys = [
                        s["segment_id"]
                        for s in segments
                        if s["start_s"] <= timestamp_s <= s["end_s"]
                    ]
                    if max_end_s is not None and timestamp_s > max_end_s:
                        break
                    if not active_keys:
                        continue
                else:
                    active_keys = ("__whole__",)
                for seg_key in active_keys:
                    _ensure_state(seg_key)

                # 裁剪区域仅用于检测与评分；标注视频保留完整画面
                if crop_region:
                    cx, cy, cw, ch = crop_region
                    color_image = full_color[cy:cy + ch, cx:cx + cw]
                else:
                    cx = cy = 0
                    cw, ch = full_color.shape[1], full_color.shape[0]
                    color_image = full_color

                if is_rgb:
                    rgb = (
                        color_image
                        if color_image.flags.c_contiguous
                        else np.ascontiguousarray(color_image)
                    )
                else:
                    rgb = cv2.cvtColor(color_image, cv2.COLOR_BGR2RGB)
                rgb.flags.writeable = False
                mp_result = hands.process(rgb)
                rgb.flags.writeable = True

                detected_hands = set()

                if mp_result.multi_hand_landmarks and mp_result.multi_handedness:
                    for i, hand_lm in enumerate(mp_result.multi_hand_landmarks):
                        raw_label = _mirror_label(
                            mp_result.multi_handedness, i
                        )
                        # handedness 翻转抑制：连续 3 帧同标签才切换，
                        # 防止握拳时手掌朝向变化导致标签抖动、动作被拆分
                        label_track = states[active_keys[0]]["label_track"]
                        if i not in label_track:
                            label_track[i] = {
                                "label": None, "candidate": None, "count": 0,
                            }
                        track = label_track[i]
                        if raw_label == track["candidate"]:
                            track["count"] += 1
                        else:
                            track["candidate"] = raw_label
                            track["count"] = 1
                        if track["label"] is None:
                            track["label"] = raw_label
                        elif (
                            track["count"] >= 3
                            and track["label"] != raw_label
                        ):
                            track["label"] = raw_label
                        hl = track["label"]
                        detected_hands.add(hl)
                        now = timestamp
                        # 同一帧喂给所有活动分段（不重叠时最多一个）
                        for seg_key in active_keys:
                            st = states[seg_key][hl]
                            self._update_hand_state(
                                st, hand_lm, now,
                                task_type=seg_task_types.get(seg_key),
                            )

                for seg_key in active_keys:
                    for hl in ("Left", "Right"):
                        st = states[seg_key][hl]
                        if hl not in detected_hands:
                            st["was_lost"] = True
                            seg_task = seg_task_types.get(seg_key)
                            if (
                                seg_task is None
                                or seg_task == "finger_opposition"
                            ):
                                st["opp"]["in_opposition"] = False
                                st["opp"]["state"] = "UNKNOWN"
                            if (
                                seg_task is None
                                or seg_task == "fist_clenching"
                            ):
                                held = st.get("last_valid_signal", 1.0)
                                st["fist"].update(held, timestamp)

                # ---- annotated video（每个分段独立视频；无分段时整段一个） ----
                video_seg_key = active_keys[0]
                if video_seg_key not in video_writers:
                    suffix = (
                        "" if video_seg_key == "__whole__"
                        else f"_{video_seg_key}"
                    )
                    video_writers[video_seg_key] = AnnotatedVideoWriter(
                        annotated_video_dir
                        / f"{input_stem}{suffix}_hand_motion_annotated.webm",
                        fps,
                        (full_color.shape[1], full_color.shape[0]),
                    )
                    if video_writers[video_seg_key].opened:
                        annotated_video_paths[video_seg_key] = (
                            video_writers[video_seg_key].path
                        )
                video_writer = video_writers.get(video_seg_key)
                if video_writer is not None and video_writer.opened:
                    annotated = (
                        full_color
                        if not is_rgb
                        else cv2.cvtColor(full_color, cv2.COLOR_RGB2BGR)
                    )
                    if mp_result.multi_hand_landmarks:
                        # 骨架直接在裁剪区域切片上绘制（视图写入，零拷贝）
                        roi_view = annotated[cy:cy + ch, cx:cx + cw]
                        for i, hand_lm in enumerate(
                            mp_result.multi_hand_landmarks
                        ):
                            hl = _mirror_label(mp_result.multi_handedness, i)
                            draw_hand_skeleton(roi_view, hand_lm.landmark)
                    # 裁剪区域用绿框标出（在贴回之后绘制，避免被覆盖）
                    if crop_region:
                        cv2.rectangle(
                            annotated, (cx, cy), (cx + cw, cy + ch),
                            (0, 220, 0), 2, cv2.LINE_AA,
                        )
                        cv2.putText(
                            annotated, "ROI", (cx + 6, max(cy - 8, 20)),
                            cv2.FONT_HERSHEY_SIMPLEX, 0.55,
                            (0, 220, 0), 2, cv2.LINE_AA,
                        )
                    # 每只手计数面板：常态显示（不依赖检测结果，避免闪烁）；
                    # 分段模式只显示该分段对应动作的计数
                    seg_states = states[video_seg_key]
                    seg_task = seg_task_types.get(video_seg_key)
                    for hl in ("Left", "Right"):
                        st = seg_states[hl]
                        os_ = st["opp"]
                        as_ = st["alt"]
                        fist_count = st["fist"].get_event_count()
                        panel_lines = []
                        if seg_task is None or seg_task == "finger_opposition":
                            panel_lines.append(
                                f"{hl}: opp {os_['count']}/{self.REQUIRED_ACTIONS}"
                            )
                        if seg_task is None or seg_task == "hand_alternation":
                            panel_lines.append(
                                f"alt {as_['count']}/{self.REQUIRED_ACTIONS}"
                            )
                        if seg_task is None or seg_task == "fist_clenching":
                            panel_lines.append(
                                f"fist {fist_count}/{self.REQUIRED_ACTIONS}"
                            )
                        if panel_lines:
                            put_text_block(
                                annotated,
                                panel_lines,
                                origin=(
                                    (12, 108)
                                    if hl == "Left"
                                    else (annotated.shape[1] - 280, 108)
                                ),
                                scale=0.55,
                            )
                    title = (
                        f"Hand Motion: {video_seg_key}"
                        if video_seg_key != "__whole__"
                        else "Hand Motion: opposition / alternation / fist"
                    )
                    put_text_block(
                        annotated,
                        [
                            title,
                            f"Frame: {frame_idx}  Time: {timestamp:.3f}s",
                        ],
                    )
                    video_writer.write(annotated)

                if progress and frame_idx % 30 == 0:
                    progress(0.5, f"已处理 {frame_idx} 帧...")

            # ---- scoring（每个分段独立评分；无分段时只有一个隐式分段） ----
            if progress:
                progress(0.7, "正在评分...")

            results: Dict[str, Dict[str, Any]] = {}
            warnings: List[str] = []
            for seg_key, hand_states in states.items():
                seg_tasks: Dict[str, Any] = {
                    "finger_opposition": {},
                    "hand_alternation": {},
                    "fist_clenching": {},
                }
                for hl in ("Left", "Right"):
                    st = hand_states[hl]
                    hand_tasks, hand_warnings = self._score_hand_state(
                        st, hl,
                        task_type=seg_task_types.get(seg_key),
                    )
                    for task_name in (
                        "finger_opposition",
                        "hand_alternation",
                        "fist_clenching",
                    ):
                        side_result = hand_tasks[task_name].get(hl.lower())
                        if side_result:
                            seg_tasks[task_name][hl.lower()] = side_result
                    warnings.extend(hand_warnings)
                results[seg_key] = seg_tasks

            quality = {"total_frames": frame_idx, "fps": fps}

            # ---- 汇总（分段模式取第一个分段的展示；scores/metrics 按分段组织） ----
            output_artifacts: List[str] = []
            annotated_videos: List[Dict[str, Any]] = []
            for seg_key, seg_tasks in results.items():
                video_path = annotated_video_paths.get(seg_key)
                if video_path is None or not video_path.is_file():
                    continue
                artifact_index = len(output_artifacts)
                output_artifacts.append(str(video_path.resolve()))
                if seg_key == "__whole__":
                    annotated_videos.append(
                        {
                            "segment_id": "hand_motion",
                            "label": "手部三任务标注",
                            "artifact_index": artifact_index,
                            "media_type": "video/webm",
                        }
                    )
                else:
                    meta = next(
                        (s for s in segments if s["segment_id"] == seg_key),
                        {},
                    )
                    annotated_videos.append(
                        {
                            "segment_id": seg_key,
                            "label": meta.get("label", seg_key),
                            "artifact_index": artifact_index,
                            "media_type": "video/webm",
                        }
                    )

            if segments:
                # 分段模式：result_data.segments 为每个分段的独立结果
                segment_results: List[Dict[str, Any]] = []
                for seg in segments:
                    seg_key = seg["segment_id"]
                    seg_tasks = results.get(
                        seg_key,
                        {
                            "finger_opposition": {},
                            "hand_alternation": {},
                            "fist_clenching": {},
                        },
                    )
                    segment_results.append(
                        {
                            **seg,
                            "tasks": seg_tasks,
                        }
                    )
                metrics = {}
                scores = {}
                for seg in segment_results:
                    prefix = seg["segment_id"]
                    for task_name, sides in seg["tasks"].items():
                        for side, result in sides.items():
                            p = f"{prefix}_{task_name}_{side}"
                            metrics[f"{p}_status"] = result["status"]
                            metrics[f"{p}_score"] = result["score"]
                            metrics[f"{p}_pauses"] = result["pauses"]
                            metrics[f"{p}_speed_ratio"] = result["speed_ratio"]
                            scores[f"{side}_{task_name}_{prefix}"] = result["score"]
                result_data: Dict[str, Any] = {
                    "segments": segment_results,
                    "visualization": {
                        "type": "annotated_pose_video",
                        "annotated_videos": annotated_videos,
                        "availability": (
                            "ready" if annotated_videos else "unavailable"
                        ),
                    },
                }
                summary = (
                    f"手部分段评分完成：{len(segment_results)} 个分段，"
                    f"帧数={frame_idx}。"
                )
            else:
                tasks = results["__whole__"]
                metrics = {}
                for task_name, sides in tasks.items():
                    for side, result in sides.items():
                        prefix = f"{task_name}_{side}"
                        metrics[f"{prefix}_status"] = result["status"]
                        metrics[f"{prefix}_score"] = result["score"]
                        metrics[f"{prefix}_pauses"] = result["pauses"]
                        metrics[f"{prefix}_speed_ratio"] = result["speed_ratio"]
                scores = {}
                for hl in ("left", "right"):
                    for task_name in (
                        "finger_opposition",
                        "hand_alternation",
                        "fist_clenching",
                    ):
                        r = tasks[task_name][hl]
                        scores[f"{hl}_{task_name}"] = r["score"]
                result_data = {
                    "tasks": tasks,
                    "visualization": {
                        "type": "annotated_pose_video",
                        "annotated_videos": annotated_videos,
                        "availability": (
                            "ready" if annotated_videos else "unavailable"
                        ),
                    },
                }
                summary = (
                    f"手部三任务评分完成。"
                    f"帧数={frame_idx}，"
                    f"对指 L/R={tasks['finger_opposition']['left'].get('score','?')}/"
                    f"{tasks['finger_opposition']['right'].get('score','?')}，"
                    f"轮替 L/R={tasks['hand_alternation']['left'].get('score','?')}/"
                    f"{tasks['hand_alternation']['right'].get('score','?')}，"
                    f"握拳 L/R={tasks['fist_clenching']['left'].get('score','?')}/"
                    f"{tasks['fist_clenching']['right'].get('score','?')}"
                )

            return ModuleResult(
                module_id="hand-motion",
                module_version="1.0.0",
                summary=summary,
                quality=quality,
                metrics=metrics,
                scores=scores,
                result_data=result_data,
                output_artifacts=output_artifacts,
                warnings=warnings,
            )

        finally:
            for writer in video_writers.values():
                writer.close()
            cleanup()
            hands.close()

        raise RuntimeError("unreachable")
