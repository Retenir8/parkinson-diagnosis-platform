"""
腿部运动分析推理模块 (MDS-UPDRS 3.7 / 3.8)
==========================================
集成两个腿部动作评分器——每个动作独立一个视频、独立检测、独立评分：
- 脚趾拍地 (Toe Tapping)  — MDS-UPDRS 3.7 → slot: toe_tapping_video
- 腿部灵活性 (Leg Agility) — MDS-UPDRS 3.8 → slot: leg_agility_video

无头模式：不产生 OpenCV 窗口、不写标注视频，仅返回评分。
"""

from __future__ import annotations

import math
import logging
from collections import deque
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

import numpy as np

from app.modules.base import (
    InferenceModule,
    ModuleUnavailableError,
    ProgressCallback,
)
from app.schemas.modules import (
    InputSlotDescriptor,
    InferenceRequest,
    ModelModuleDescriptor,
    ModuleResult,
)

logger = logging.getLogger(__name__)

SPEED_THRESHOLDS = [0.9, 0.8, 0.6, 0.4]
_INCOMPLETE_FLAG = "INCOMPLETE"

# MediaPipe Pose landmark indices
NOSE = 0
LEFT_FOOT_INDEX = 31
RIGHT_FOOT_INDEX = 32
LEFT_ANKLE = 27
RIGHT_ANKLE = 28


def _side_indices(side: str) -> dict:
    if side == "Left":
        return {"foot_index": LEFT_FOOT_INDEX, "ankle": LEFT_ANKLE}
    return {"foot_index": RIGHT_FOOT_INDEX, "ankle": RIGHT_ANKLE}


# ============================================================================
# Shared scoring helpers
# ============================================================================

def _analyze_pauses(records: List[Dict], pause_threshold: float,
                    freeze_threshold: float) -> Dict:
    pauses: List[float] = []
    for i in range(1, len(records)):
        gap = records[i].get("time", 0.0) - records[i - 1].get("time", 0.0)
        if gap > pause_threshold:
            pauses.append(gap)
    total = len(pauses)
    freezes = sum(1 for p in pauses if p >= freeze_threshold)
    return {"total_pauses": total, "long_freezes": freezes}


def _analyze_speed(records: List[Dict]) -> Dict:
    if len(records) < 2:
        return {"slow_level": 0, "speed_ratio": 1.0}
    speeds: List[float] = []
    for i in range(1, len(records)):
        dur = records[i]["time"] - records[i - 1]["time"]
        if dur > 0:
            speeds.append(1.0 / dur)
    if len(speeds) < 2:
        return {"slow_level": 0, "speed_ratio": 1.0}
    ratio = speeds[-1] / speeds[0] if speeds[0] > 0 else 1.0
    level = 0
    for i, t in enumerate(SPEED_THRESHOLDS):
        if ratio < t:
            level = i + 1
    return {"slow_level": level, "speed_ratio": ratio}


def _analyze_amplitude(amplitudes: List[float], base: Optional[float]) -> Dict:
    if not amplitudes or base is None or base == 0:
        return {"amplitude_decrease": 0}
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


def _mds_updrs_score(pause_analysis: Dict, speed_analysis: Dict,
                     amplitude_analysis: Dict) -> Tuple[int, List[str]]:
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

    reasons: List[str] = []
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


def _build_task_result(score, reasons, action_count, required,
                       pauses, speed_ratio, amp_decrease) -> Dict:
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


# ============================================================================
# Per-task processing (single video → per-side scores)
# ============================================================================

class _TaskConfig:
    """Config for one leg task."""

    def __init__(
        self,
        task_id: str,
        slot_key: str,
        task_display: str,
        mds_item: str,
        target_landmark: str,  # "foot_index" or "ankle"
        up_th_2d: float,
        down_th_2d: float,
        up_th_3d: float,
        down_th_3d: float,
        debounce: float,
        pause_threshold: float,
        freeze_threshold: float,
        calibration_frames: int,
        crop_region=None,
    ):
        self.task_id = task_id
        self.slot_key = slot_key
        self.task_display = task_display
        self.mds_item = mds_item
        self.target_landmark = target_landmark
        self.up_th_2d = up_th_2d
        self.down_th_2d = down_th_2d
        self.up_th_3d = up_th_3d
        self.down_th_3d = down_th_3d
        self.debounce = debounce
        self.pause_threshold = pause_threshold
        self.freeze_threshold = freeze_threshold
        self.calibration_frames = calibration_frames
        self.crop_region = crop_region


def _process_one_task(
    cfg: _TaskConfig,
    video_path: Path,
    required_actions: int,
    pose_conf: Tuple[float, float, int],
    progress: ProgressCallback | None = None,
) -> Tuple[Dict, List[str], Dict]:
    """Process one video for one task, return (per_side_results, warnings, quality)."""

    import pyrealsense2 as rs
    import mediapipe as mp
    import cv2

    if not video_path.exists():
        raise ModuleUnavailableError(f"输入文件不存在：{video_path}")

    suffix = video_path.suffix.lower()
    is_bag = suffix == ".bag"
    min_det, min_trk, model_cx = pose_conf

    # ---- open video source ----
    depth_intrinsics = None

    if is_bag:
        pipeline = rs.pipeline()
        config = rs.config()
        rs.config.enable_device_from_file(
            config, str(video_path), repeat_playback=False,
        )
        profile = pipeline.start(config)
        align = rs.align(rs.stream.color)
        depth_profile = profile.get_stream(rs.stream.depth)
        depth_intrinsics = (
            depth_profile.as_video_stream_profile().get_intrinsics()
        )
        color_profile = profile.get_stream(rs.stream.color)
        fps = color_profile.as_video_stream_profile().fps()
        try:
            ff = pipeline.wait_for_frames(timeout_ms=5000)
            af = align.process(ff)
            ad = af.get_depth_frame()
            if ad:
                depth_intrinsics = (
                    ad.get_profile().as_video_stream_profile().get_intrinsics()
                )
        except Exception:
            pass

        def _read():
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
            if cfg.crop_region:
                x, y, w, h = cfg.crop_region
                ci = ci[y:y + h, x:x + w]
            return ci, df, ts

        read_fn = _read

        def cleanup():
            pipeline.stop()
    else:
        cap = cv2.VideoCapture(str(video_path))
        fps = cap.get(cv2.CAP_PROP_FPS) or 30.0

        def _read():
            ok, frame = cap.read()
            if not ok:
                return None
            if cfg.crop_region:
                x, y, w, h = cfg.crop_region
                frame = frame[y:y + h, x:x + w]
            return frame, None, cap.get(cv2.CAP_PROP_POS_MSEC) / 1000.0

        read_fn = _read

        def cleanup():
            cap.release()

    def _get_3d(x_norm, y_norm, depth_frame):
        if depth_intrinsics is None or depth_frame is None:
            return None
        if cfg.crop_region:
            ox, oy, cw, ch = cfg.crop_region
            px = int(x_norm * cw) + ox
            py = int(y_norm * ch) + oy
        else:
            px = int(x_norm * depth_intrinsics.width)
            py = int(y_norm * depth_intrinsics.height)
        if 0 <= px < depth_intrinsics.width and 0 <= py < depth_intrinsics.height:
            try:
                d = depth_frame.get_distance(px, py)
                if 0.1 < d < 3.0:
                    return rs.rs2_deproject_pixel_to_point(
                        depth_intrinsics, [px, py], d,
                    )
            except Exception:
                pass
        return None

    # ---- MediaPipe Pose ----
    mp_pose = mp.solutions.pose
    pose = mp_pose.Pose(
        static_image_mode=False,
        min_detection_confidence=min_det,
        min_tracking_confidence=min_trk,
        model_complexity=model_cx,
    )

    # ---- per-side state ----
    baseline: Dict[str, Optional[float]] = {"Left": None, "Right": None}
    baseline_samples: Dict[str, deque] = {
        "Left": deque(maxlen=50), "Right": deque(maxlen=50),
    }
    records: Dict[str, List[Dict]] = {"Left": [], "Right": []}
    count: Dict[str, int] = {"Left": 0, "Right": 0}
    ready: Dict[str, bool] = {"Left": True, "Right": True}
    last_count_time: Dict[str, float] = {"Left": 0.0, "Right": 0.0}
    amplitudes: Dict[str, List[float]] = {"Left": [], "Right": []}

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
            pose_result = pose.process(rgb)
            rgb.flags.writeable = True

            if pose_result.pose_landmarks:
                p_lm = pose_result.pose_landmarks

                for side in ("Left", "Right"):
                    si = _side_indices(side)
                    nose_lm = p_lm.landmark[NOSE]
                    target_lm = p_lm.landmark[si[cfg.target_landmark]]

                    nose_3d = _get_3d(nose_lm.x, nose_lm.y, depth_frame)
                    target_3d = _get_3d(target_lm.x, target_lm.y, depth_frame)

                    if nose_3d and target_3d:
                        raw = target_3d[1] - nose_3d[1]
                    else:
                        raw = (1.0 - target_lm.y) - (1.0 - nose_lm.y)
                    # 始终使用 2D 阈值（与原程序保持一致）
                    up_th = cfg.up_th_2d
                    down_th = cfg.down_th_2d

                    # dynamic baseline calibration
                    if frame_idx <= cfg.calibration_frames:
                        baseline_samples[side].append(raw)
                        if len(baseline_samples[side]) >= 10:
                            s = sorted(baseline_samples[side])
                            baseline[side] = s[len(s) // 2]
                        elif baseline[side] is None:
                            baseline[side] = raw
                    else:
                        baseline[side] = (baseline[side] or raw) * 0.95 + raw * 0.05

                    base = baseline[side] or raw
                    lift = raw - base

                    if lift > up_th and ready[side]:
                        if timestamp - last_count_time[side] > cfg.debounce:
                            count[side] += 1
                            last_count_time[side] = timestamp
                            ready[side] = False
                            records[side].append({
                                "time": timestamp,
                                "amplitude": abs(lift),
                            })
                            amplitudes[side].append(abs(lift))
                    if lift < down_th:
                        ready[side] = True

            if progress and frame_idx % 30 == 0:
                progress(0.5, f"[{cfg.task_display}] 已处理 {frame_idx} 帧...")

        # ---- scoring ----
        warnings: List[str] = []
        per_side: Dict[str, Dict] = {}

        for side in ("Left", "Right"):
            sl = side.lower()
            pa = _analyze_pauses(records[side], cfg.pause_threshold, cfg.freeze_threshold)
            sp = _analyze_speed(records[side])
            am = _analyze_amplitude(
                amplitudes.get(side, []),
                amplitudes[side][0] if amplitudes[side] else None,
            )
            score, reasons = _mds_updrs_score(pa, sp, am)
            per_side[sl] = _build_task_result(
                score, reasons, count[side], required_actions,
                pa["total_pauses"], sp["speed_ratio"], am["amplitude_decrease"],
            )
            if count[side] < required_actions:
                warnings.append(
                    f"{side} {cfg.task_display}动作不足：仅检测到 {count[side]} 次"
                    f"（需 {required_actions} 次）"
                )

        quality = {"total_frames": frame_idx, "fps": fps}

        return per_side, warnings, quality

    finally:
        cleanup()
        pose.close()


# ============================================================================
# InferenceModule
# ============================================================================

class LegMotionModule(InferenceModule):
    """Leg motion analysis — one video per task, two independent slots."""

    REQUIRED_ACTIONS = 10

    MIN_DETECTION_CONFIDENCE = 0.60
    MIN_TRACKING_CONFIDENCE = 0.60
    MODEL_COMPLEXITY = 1

    CROP_REGION = None

    # ---- per-task configs ----

    TOE_TAPPING = "toe_tapping"
    LEG_AGILITY = "leg_agility"

    TASK_CONFIGS = {
        TOE_TAPPING: dict(
            task_display="脚趾拍地",
            mds_item="3.7",
            target_landmark="foot_index",
            up_th_2d=0.005,
            down_th_2d=0.005,
            up_th_3d=0.02,
            down_th_3d=0.005,
            debounce=0.1,
            pause_threshold=0.6,
            freeze_threshold=1.5,
            calibration_frames=30,
        ),
        LEG_AGILITY: dict(
            task_display="抬腿灵活性",
            mds_item="3.8",
            target_landmark="ankle",
            up_th_2d=0.013,
            down_th_2d=0.013,
            up_th_3d=0.05,
            down_th_3d=0.01,
            debounce=0.1,
            pause_threshold=0.6,
            freeze_threshold=1.5,
            calibration_frames=30,
        ),
    }

    # ------------------------------------------------------------------

    def descriptor(self) -> ModelModuleDescriptor:
        return ModelModuleDescriptor(
            id="leg-motion",
            display_name="腿部运动分析",
            category="leg",
            description=(
                "基于 MediaPipe Pose 的腿部双任务评分："
                "脚趾拍地（MDS-UPDRS 3.7）和抬腿灵活性（3.8），各需独立视频。"
            ),
            status="ready",
            status_detail=(
                "已集成两个腿部动作评分器。"
                "两个任务分别使用独立视频，各有独立输入槽。"
            ),
            input_kinds=["realsense_bag", "video"],
            input_slots=[
                InputSlotDescriptor(
                    key="toe_tapping_video",
                    label="脚趾拍地视频 (MDS-UPDRS 3.7)",
                    description=(
                        "脚趾拍地动作的视频输入（RealSense .bag 或普通视频）。"
                        "患者坐姿，脚跟固定在地面，脚尖抬起再拍下，重复10次。"
                    ),
                    accepted_kinds=["realsense_bag", "video"],
                    required=True,
                    multiple=False,
                ),
                InputSlotDescriptor(
                    key="leg_agility_video",
                    label="抬腿灵活性视频 (MDS-UPDRS 3.8)",
                    description=(
                        "抬腿动作的视频输入（RealSense .bag 或普通视频）。"
                        "患者坐姿，整只脚从地面抬起再跺下，尽可能高、尽可能快，重复10次。"
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

    def validate(self, request: InferenceRequest) -> list[str]:
        issues: list[str] = []

        # check both slots present
        for slot_key in ("toe_tapping_video", "leg_agility_video"):
            if slot_key not in request.inputs or not request.inputs[slot_key]:
                issues.append(f"缺少必需输入槽：{slot_key}")

        for slot_key, artifacts in request.inputs.items():
            if slot_key not in ("toe_tapping_video", "leg_agility_video"):
                issues.append(f"未知输入槽：{slot_key}")
                continue
            if len(artifacts) > 1:
                issues.append(f"{slot_key} 只允许一个文件，收到 {len(artifacts)} 个")
            for a in artifacts:
                if not a.path.exists():
                    issues.append(f"文件不存在：{a.path}")
                elif a.path.suffix.lower() not in (".bag", ".avi", ".mp4", ".mov", ".mkv"):
                    issues.append(f"不支持的视频格式：{a.path.suffix}")

        try:
            import pyrealsense2  # noqa: F401
        except ImportError:
            issues.append("缺少 pyrealsense2 库。")
        try:
            import mediapipe  # noqa: F401
        except ImportError:
            issues.append("缺少 mediapipe 库。")

        return issues

    def infer(
        self,
        request: InferenceRequest,
        progress: ProgressCallback | None = None,
    ) -> ModuleResult:
        if not request.inputs:
            raise ModuleUnavailableError("没有可用的输入槽。")

        pose_conf = (
            self.MIN_DETECTION_CONFIDENCE,
            self.MIN_TRACKING_CONFIDENCE,
            self.MODEL_COMPLEXITY,
        )

        all_tasks: Dict[str, Dict] = {
            self.TOE_TAPPING: {},
            self.LEG_AGILITY: {},
        }
        all_warnings: List[str] = []
        all_quality: Dict[str, Dict] = {}

        # ---- process each slot independently ----
        for task_id, task_kwargs in self.TASK_CONFIGS.items():
            slot_key = f"{task_id}_video"
            if slot_key not in request.inputs or not request.inputs[slot_key]:
                all_warnings.append(f"缺少 {task_id} 的视频输入，跳过该任务。")
                # mark as incomplete for both sides
                for side in ("left", "right"):
                    all_tasks[task_id][side] = {
                        "status": _INCOMPLETE_FLAG,
                        "detected_actions": 0,
                        "required_actions": self.REQUIRED_ACTIONS,
                        "score": 0,
                        "reasons": ["No data: video input missing"],
                        "pauses": 0,
                        "speed_ratio": 1.0,
                        "amplitude_decrease_level": 0,
                    }
                continue

            artifact = request.inputs[slot_key][0]
            video_path = Path(str(artifact.path))

            cfg = _TaskConfig(
                task_id=task_id,
                slot_key=slot_key,
                task_display=task_kwargs["task_display"],
                mds_item=task_kwargs["mds_item"],
                target_landmark=task_kwargs["target_landmark"],
                up_th_2d=task_kwargs["up_th_2d"],
                down_th_2d=task_kwargs["down_th_2d"],
                up_th_3d=task_kwargs["up_th_3d"],
                down_th_3d=task_kwargs["down_th_3d"],
                debounce=task_kwargs["debounce"],
                pause_threshold=task_kwargs["pause_threshold"],
                freeze_threshold=task_kwargs["freeze_threshold"],
                calibration_frames=task_kwargs["calibration_frames"],
                crop_region=self.CROP_REGION,
            )

            logger.info(
                "腿部模块 [%s] 开始处理: %s", task_kwargs["task_display"], video_path,
            )
            per_side, warnings, quality = _process_one_task(
                cfg, video_path, self.REQUIRED_ACTIONS, pose_conf,
                progress=progress,
            )
            all_tasks[task_id] = per_side
            all_warnings.extend(warnings)
            all_quality[task_id] = quality
            logger.info(
                "腿部模块 [%s] 处理完成", task_kwargs["task_display"],
            )

        # ---- flatten metrics ----
        metrics: Dict[str, Any] = {}
        for task_id, sides in all_tasks.items():
            for side, result in sides.items():
                prefix = f"{task_id}_{side}"
                metrics[f"{prefix}_status"] = result["status"]
                metrics[f"{prefix}_score"] = result["score"]
                metrics[f"{prefix}_pauses"] = result["pauses"]
                metrics[f"{prefix}_speed_ratio"] = result["speed_ratio"]

        scores: Dict[str, Any] = {}
        for side in ("left", "right"):
            for task_id in (self.TOE_TAPPING, self.LEG_AGILITY):
                r = all_tasks[task_id][side]
                scores[f"{side}_{task_id}"] = r["score"]

        # summary
        tt_l = all_tasks[self.TOE_TAPPING]["left"].get("score", "?")
        tt_r = all_tasks[self.TOE_TAPPING]["right"].get("score", "?")
        la_l = all_tasks[self.LEG_AGILITY]["left"].get("score", "?")
        la_r = all_tasks[self.LEG_AGILITY]["right"].get("score", "?")

        return ModuleResult(
            module_id="leg-motion",
            module_version="1.0.0",
            summary=(
                f"腿部双任务评分完成。"
                f"脚趾拍地 L/R={tt_l}/{tt_r}，"
                f"抬腿 L/R={la_l}/{la_r}"
            ),
            quality=all_quality,
            metrics=metrics,
            scores=scores,
            result_data={"tasks": all_tasks},
            output_artifacts=[],
            warnings=all_warnings,
        )
