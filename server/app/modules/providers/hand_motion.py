"""
手部运动分析推理模块 (MDS-UPDRS 3.4/3.5/3.6)
==============================================
集成三个手部动作评分器：
- 手指对指 (Finger Opposition) — MDS-UPDRS 3.4
- 手掌轮替 (Hand Alternation) — MDS-UPDRS 3.5
- 握拳     (Fist Clenching)  — MDS-UPDRS 3.6

MediaPipe Hands 关键点只提取一次，三个评分器共享。
无头模式：不产生 OpenCV 窗口、不写标注视频，仅返回评分。
"""

from __future__ import annotations

import os
import sys
import time
import math
import logging
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

def _compute_pauses(signal_buf, time_buf, pause_threshold=0.8):
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


def _analyze_pauses(pauses, freeze_threshold):
    total = len(pauses)
    freezes = sum(1 for p in pauses if p >= freeze_threshold)
    return {"total_pauses": total, "long_freezes": freezes}


def _analyze_speed(durations, thresholds):
    if len(durations) < 2:
        return {"slow_level": 0, "speed_ratio": 1.0}
    speeds = [1.0 / d for d in durations]
    ratio = speeds[-1] / speeds[0] if speeds[0] > 0 else 1.0
    level = 0
    for i, t in enumerate(thresholds):
        if ratio < t:
            level = i + 1
    return {"slow_level": level, "speed_ratio": ratio}


def _analyze_amplitude(amplitudes):
    if not amplitudes or amplitudes[0] == 0:
        return {"amplitude_decrease": 0}
    base = amplitudes[0]
    ratios = [a / base for a in amplitudes if a > 0]
    decrease = 0
    if len(ratios) >= 10 and ratios[-1] < 0.8:
        decrease = 1
    elif len(ratios) >= 5 and ratios[4] < 0.7:
        decrease = 2
    elif len(ratios) >= 3 and all(
        ratios[i] > ratios[i + 1] for i in range(len(ratios) - 1)
    ):
        decrease = 3
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
    elif 3 <= total_pauses <= 5:
        pause_sub = 2
    else:
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


# ============================================================================
# HandMotionModule
# ============================================================================

class HandMotionModule(InferenceModule):
    """Hand motion analysis: finger opposition, alternation, fist clenching.

    MediaPipe Hands runs once; all three scorers share the same landmarks.
    No OpenCV GUI, no annotated video output.
    """

    REQUIRED_ACTIONS = 10
    CROP_REGION = (400, 100, 480, 480)

    MIN_DETECTION_CONFIDENCE = 0.60
    MIN_TRACKING_CONFIDENCE = 0.60
    MODEL_COMPLEXITY = 1

    TOUCH_SIGNAL_THRESHOLD = 0.5
    OPEN_SIGNAL_THRESHOLD = 0.7
    INDEX_EXTENSION_ANGLE = 60.0
    DEBOUNCE_DUIZHI = 0.3

    LUNTI_SIGNAL_THRESHOLD = 8.0
    LUNTI_MIN_RAW_DX = 0.010
    DEBOUNCE_LUNTI = 0.3

    DETECT_BUFFER_SIZE = 30
    DETECT_SMOOTHING = 3
    DETECT_MIN_PROMINENCE = 0.12
    DETECT_MIN_ABS_AMPLITUDE = 0.10
    DETECT_MIN_DIRECTION_TIME = 0.10
    DEBOUNCE_WOQUAN = 0.3
    FIST_ANGLE_THRESHOLD = 140.0
    CALIB_FRAMES = 90
    DEFAULT_MAX_ANGLE = 170.0
    SIGNAL_CLAMP_MIN = 0.3
    SIGNAL_CLAMP_MAX = 1.2
    WRIST_MOVEMENT_THRESHOLD = 0.008

    PAUSE_THRESHOLD = 0.8
    FREEZE_THRESHOLD = 1.8

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
        if not request.artifacts:
            issues.append("至少需要提供一个手部视频或 RealSense .bag 文件。")
            return issues

        for a in request.artifacts:
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

        return issues

    def infer(self, request, progress=None):
        import pyrealsense2 as rs
        import mediapipe as mp
        import cv2
        prepare_legacy_solutions()

        artifacts = request.artifacts
        if not artifacts:
            raise ModuleUnavailableError("没有可用的输入文件。")

        bag_path = Path(str(artifacts[0].path))
        if not bag_path.exists():
            raise ModuleUnavailableError(f"输入文件不存在：{bag_path}")

        suffix = bag_path.suffix.lower()
        is_bag = suffix == ".bag"

        # ---- open video source ----
        if is_bag:
            pipeline = rs.pipeline()
            config = rs.config()
            rs.config.enable_device_from_file(
                config, str(bag_path), repeat_playback=False,
            )
            profile = pipeline.start(config)
            align = rs.align(rs.stream.color)
            color_profile = profile.get_stream(rs.stream.color)
            fps = color_profile.as_video_stream_profile().fps()

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
                ci = np.asanyarray(cf.get_data())
                if ci.shape[-1] == 3:
                    ci = cv2.cvtColor(ci, cv2.COLOR_RGB2BGR)
                if self.CROP_REGION:
                    x, y, w, h = self.CROP_REGION
                    ci = ci[y:y + h, x:x + w]
                return ci, df, ts

            read_fn = _read_bag

            def cleanup():
                pipeline.stop()
        else:
            cap = cv2.VideoCapture(str(bag_path))
            fps = cap.get(cv2.CAP_PROP_FPS) or 30.0

            def _read_video():
                ok, frame = cap.read()
                if not ok:
                    return None
                if self.CROP_REGION:
                    x, y, w, h = self.CROP_REGION
                    frame = frame[y:y + h, x:x + w]
                return frame, None, cap.get(cv2.CAP_PROP_POS_MSEC) / 1000.0

            read_fn = _read_video

            def cleanup():
                cap.release()

        # ---- MediaPipe Hands ----
        mp_hands = mp.solutions.hands
        hands = mp_hands.Hands(
            static_image_mode=False,
            max_num_hands=2,
            min_detection_confidence=self.MIN_DETECTION_CONFIDENCE,
            min_tracking_confidence=self.MIN_TRACKING_CONFIDENCE,
            model_complexity=self.MODEL_COMPLEXITY,
        )

        # ---- per-hand state ----

        def _init_opposition():
            return {
                "state": "OPEN", "in_opposition": False,
                "count": 0, "last_action_time": 0.0,
                "records": [], "current_record": None,
            }

        opp_state = {hl: _init_opposition() for hl in ("Left", "Right")}

        def _init_alternation():
            return {
                "prev_sign": 0, "count": 0,
                "last_action_time": 0.0, "records": [],
            }

        alt_state = {hl: _init_alternation() for hl in ("Left", "Right")}

        fist_detectors = {
            hl: ActionDetector(
                mode="valley",
                buffer_size=self.DETECT_BUFFER_SIZE,
                min_prominence=self.DETECT_MIN_PROMINENCE,
                min_interval=self.DEBOUNCE_WOQUAN,
                smoothing_window=self.DETECT_SMOOTHING,
                min_abs_amplitude=self.DETECT_MIN_ABS_AMPLITUDE,
                min_direction_time=self.DETECT_MIN_DIRECTION_TIME,
            )
            for hl in ("Left", "Right")
        }

        fist_calib_frames = {"Left": 0, "Right": 0}
        fist_calib_max = {"Left": self.DEFAULT_MAX_ANGLE, "Right": self.DEFAULT_MAX_ANGLE}
        fist_calib_locked = {"Left": False, "Right": False}
        fist_running_max = {"Left": self.DEFAULT_MAX_ANGLE, "Right": self.DEFAULT_MAX_ANGLE}
        fist_posture = {"Left": False, "Right": False}
        last_wrist_pos = {"Left": None, "Right": None}
        wrist_moving = {"Left": False, "Right": False}
        last_valid_signal = {"Left": 1.0, "Right": 1.0}

        signal_buf = {"Left": deque(maxlen=300), "Right": deque(maxlen=300)}
        time_buf = {"Left": deque(maxlen=300), "Right": deque(maxlen=300)}

        amp_opp = {"Left": [], "Right": []}
        amp_alt = {"Left": [], "Right": []}
        amp_fist = {"Left": [], "Right": []}

        was_lost = {"Left": False, "Right": False}

        try:
            frame_idx = 0
            while True:
                ret = read_fn()
                if ret is None:
                    break
                color_image, depth_frame, timestamp = ret
                frame_idx += 1

                rgb = cv2.cvtColor(color_image, cv2.COLOR_BGR2RGB)
                rgb.flags.writeable = False
                mp_result = hands.process(rgb)
                rgb.flags.writeable = True

                detected_hands = set()

                if mp_result.multi_hand_landmarks and mp_result.multi_handedness:
                    for i, hand_lm in enumerate(mp_result.multi_hand_landmarks):
                        hl = _mirror_label(mp_result.multi_handedness, i)
                        detected_hands.add(hl)

                        if was_lost.get(hl, False):
                            was_lost[hl] = False

                        now = timestamp

                        # ---- finger opposition ----
                        raw_opp = opposition_signal(hand_lm, self.INDEX_EXTENSION_ANGLE)
                        is_fist_opp = raw_opp >= INVALID_SIGNAL_SENTINEL
                        is_touch = (not is_fist_opp) and raw_opp < self.TOUCH_SIGNAL_THRESHOLD
                        is_open = raw_opp > self.OPEN_SIGNAL_THRESHOLD or is_fist_opp
                        opp_sig = raw_opp if raw_opp < INVALID_SIGNAL_SENTINEL else 3.0

                        os_ = opp_state[hl]
                        debounce_ok = (now - os_["last_action_time"]) > self.DEBOUNCE_DUIZHI

                        if not os_["in_opposition"] and is_touch and debounce_ok:
                            os_["in_opposition"] = True
                            os_["state"] = "TOUCH"
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
                                amp_opp[hl].append(abs(opp_sig))
                            os_["current_record"] = None
                        elif not os_["in_opposition"]:
                            os_["state"] = "OPEN" if is_open else "UNKNOWN"

                        # ---- hand alternation ----
                        alt_sig = alternation_signal(hand_lm)
                        raw_dx = abs(hand_lm.landmark[17].x - hand_lm.landmark[2].x)
                        if raw_dx < self.LUNTI_MIN_RAW_DX:
                            cur_sign = 0
                        else:
                            cur_sign = (
                                1 if alt_sig > self.LUNTI_SIGNAL_THRESHOLD
                                else (-1 if alt_sig < -self.LUNTI_SIGNAL_THRESHOLD else 0)
                            )
                        as_ = alt_state[hl]
                        if (cur_sign != 0
                                and cur_sign != as_["prev_sign"]
                                and as_["prev_sign"] != 0):
                            if now - as_["last_action_time"] > self.DEBOUNCE_LUNTI:
                                as_["count"] += 1
                                as_["last_action_time"] = now
                                as_["prev_sign"] = cur_sign
                                as_["records"].append({"time": now, "signal": alt_sig})
                                amp_alt[hl].append(abs(alt_sig))
                        elif cur_sign != 0 and as_["prev_sign"] == 0:
                            as_["prev_sign"] = cur_sign

                        # ---- fist clenching ----
                        raw_fist = fist_signal(hand_lm, self.FIST_ANGLE_THRESHOLD)

                        if raw_fist < INVALID_SIGNAL_SENTINEL:
                            if not fist_posture[hl]:
                                fist_posture[hl] = True
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
                                fist_posture[hl] = False

                        is_fist_p = fist_posture[hl]

                        if not fist_calib_locked[hl]:
                            fist_calib_frames[hl] += 1
                            if is_fist_p and raw_fist < INVALID_SIGNAL_SENTINEL:
                                fist_running_max[hl] = max(fist_running_max[hl], raw_fist)
                            if fist_calib_frames[hl] >= self.CALIB_FRAMES:
                                fist_calib_max[hl] = max(
                                    fist_running_max[hl], self.DEFAULT_MAX_ANGLE,
                                )
                                fist_calib_locked[hl] = True
                            denom = max(fist_running_max[hl], self.DEFAULT_MAX_ANGLE)
                            fist_sig_val = (
                                raw_fist if (is_fist_p and raw_fist < INVALID_SIGNAL_SENTINEL)
                                else denom
                            ) / denom
                        else:
                            denom = fist_calib_max[hl]
                            fist_sig_val = (
                                raw_fist if (is_fist_p and raw_fist < INVALID_SIGNAL_SENTINEL)
                                else denom
                            ) / denom

                        fist_sig_val = max(self.SIGNAL_CLAMP_MIN,
                                           min(self.SIGNAL_CLAMP_MAX, fist_sig_val))
                        last_valid_signal[hl] = fist_sig_val

                        wrist_x = hand_lm.landmark[0].x
                        wrist_y = hand_lm.landmark[0].y
                        if last_wrist_pos[hl] is not None:
                            dx = wrist_x - last_wrist_pos[hl][0]
                            dy = wrist_y - last_wrist_pos[hl][1]
                            spd = np.sqrt(dx * dx + dy * dy)
                            wrist_moving[hl] = spd > self.WRIST_MOVEMENT_THRESHOLD
                        last_wrist_pos[hl] = (wrist_x, wrist_y)

                        event = None
                        if not wrist_moving[hl]:
                            event = fist_detectors[hl].update(fist_sig_val, now)
                        if event is not None:
                            amp_fist[hl].append(event.amplitude)

                        signal_buf[hl].append(opp_sig)
                        time_buf[hl].append(now)

                for hl in ("Left", "Right"):
                    if hl not in detected_hands:
                        was_lost[hl] = True
                        opp_state[hl]["in_opposition"] = False
                        opp_state[hl]["state"] = "UNKNOWN"
                        held = last_valid_signal.get(hl, 1.0)
                        fist_detectors[hl].update(held, timestamp)

                if progress and frame_idx % 30 == 0:
                    progress(0.5, f"已处理 {frame_idx} 帧...")

            # ---- scoring ----
            if progress:
                progress(0.7, "正在评分...")

            tasks = {
                "finger_opposition": {},
                "hand_alternation": {},
                "fist_clenching": {},
            }
            warnings = []

            for hl in ("Left", "Right"):
                # opposition
                opp_records = opp_state[hl]["records"]
                opp_count = opp_state[hl]["count"]
                opp_pause_list = _compute_pauses(
                    signal_buf[hl], time_buf[hl], self.PAUSE_THRESHOLD,
                )
                opp_pause = _analyze_pauses(opp_pause_list, self.FREEZE_THRESHOLD)
                opp_durations = [
                    opp_records[i]["end_time"] - opp_records[i - 1]["end_time"]
                    for i in range(1, len(opp_records))
                ]
                opp_speed = _analyze_speed(opp_durations, SPEED_THRESHOLDS_DUIZHI)
                opp_amp = _analyze_amplitude(amp_opp.get(hl, []))
                opp_score, opp_reasons = _mds_updrs_score(opp_pause, opp_speed, opp_amp)
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

                # alternation
                alt_records = alt_state[hl]["records"]
                alt_count = alt_state[hl]["count"]
                alt_sig_buf = deque(
                    [r["signal"] for r in alt_records], maxlen=300,
                )
                alt_time_buf = deque(
                    [r["time"] for r in alt_records], maxlen=300,
                )
                alt_pause_list = _compute_pauses(
                    alt_sig_buf, alt_time_buf, self.PAUSE_THRESHOLD,
                )
                alt_pause = _analyze_pauses(alt_pause_list, self.FREEZE_THRESHOLD)
                alt_durations = [
                    alt_records[i]["time"] - alt_records[i - 1]["time"]
                    for i in range(1, len(alt_records))
                ]
                alt_speed = _analyze_speed(alt_durations, SPEED_THRESHOLDS_LUNTI)
                alt_amp = _analyze_amplitude(amp_alt.get(hl, []))
                alt_score, alt_reasons = _mds_updrs_score(alt_pause, alt_speed, alt_amp)
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

                # fist
                fist_det = fist_detectors[hl]
                fist_count = fist_det.get_event_count()
                fist_records = fist_det.action_records
                fist_sig_buf = deque(
                    [r.signal_value for r in fist_records], maxlen=300,
                )
                fist_time_buf = deque(
                    [r.timestamp for r in fist_records], maxlen=300,
                )
                fist_pause_list = _compute_pauses(
                    fist_sig_buf, fist_time_buf, self.PAUSE_THRESHOLD,
                )
                fist_pause = _analyze_pauses(fist_pause_list, self.FREEZE_THRESHOLD)
                fist_durations = [
                    fist_records[i].timestamp - fist_records[i - 1].timestamp
                    for i in range(1, len(fist_records))
                ]
                fist_speed_result = _analyze_speed(fist_durations, SPEED_THRESHOLDS_WOQUAN)
                fist_amp_result = _analyze_amplitude(amp_fist.get(hl, []))
                fist_score, fist_reasons = _mds_updrs_score(
                    fist_pause, fist_speed_result, fist_amp_result,
                )
                tasks["fist_clenching"][hl.lower()] = _build_task_result(
                    fist_score, fist_reasons, fist_count,
                    self.REQUIRED_ACTIONS, fist_pause["total_pauses"],
                    fist_speed_result["speed_ratio"], fist_amp_result["amplitude_decrease"],
                )
                if fist_count < self.REQUIRED_ACTIONS:
                    warnings.append(
                        f"{hl} 握拳动作不足：仅检测到 {fist_count} 次"
                        f"（需 {self.REQUIRED_ACTIONS} 次）"
                    )

            quality = {"total_frames": frame_idx, "fps": fps}

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
                for task_name in ("finger_opposition", "hand_alternation", "fist_clenching"):
                    r = tasks[task_name][hl]
                    scores[f"{hl}_{task_name}"] = r["score"]

            return ModuleResult(
                module_id="hand-motion",
                module_version="1.0.0",
                summary=(
                    f"手部三任务评分完成。"
                    f"帧数={frame_idx}，"
                    f"对指 L/R={tasks['finger_opposition']['left'].get('score','?')}/"
                    f"{tasks['finger_opposition']['right'].get('score','?')}，"
                    f"轮替 L/R={tasks['hand_alternation']['left'].get('score','?')}/"
                    f"{tasks['hand_alternation']['right'].get('score','?')}，"
                    f"握拳 L/R={tasks['fist_clenching']['left'].get('score','?')}/"
                    f"{tasks['fist_clenching']['right'].get('score','?')}"
                ),
                quality=quality,
                metrics=metrics,
                scores=scores,
                result_data={"tasks": tasks},
                output_artifacts=[],
                warnings=warnings,
            )

        finally:
            cleanup()
            hands.close()

        raise RuntimeError("unreachable")
