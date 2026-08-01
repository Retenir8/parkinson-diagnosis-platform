from __future__ import annotations

import csv
import hashlib
import json
import math
import tempfile
import threading
from argparse import Namespace
from collections import Counter
from pathlib import Path
from typing import Any

from app.modules import overall_posture_analysis as analysis
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


WALK_FEATURES = [
    "SP_U",
    "RA_AMP_U",
    "LA_AMP_U",
    "RA_STD_U",
    "LA_STD_U",
    "SYM_U",
    "R_JERK_U",
    "L_JERK_U",
    "ASA_U",
    "ASYM_IND_U",
    "TRA_U",
    "T_AMP_U",
    "STR_T_U",
    "STR_CV_U",
    "STEP_REG_U",
    "STEP_SYM_U",
    "JERK_T_U",
]

CLASS_LABELS = {
    0: "Normal",
    1: "Mild",
    2: "Moderate/Severe",
}


class OverallPostureModule(InferenceModule):
    """RealSense walk extraction plus the true 0/1/2 walk17 classifier."""

    MODULE_ID = "overall-posture"
    MODULE_VERSION = "walk17-three-class"
    DEFAULT_WALK_DISTANCE_M = 10.0

    def __init__(
        self,
        *,
        model_path: Path | None = None,
        pose_model_path: Path | None = None,
    ) -> None:
        server_root = Path(__file__).resolve().parents[3]
        model_dir = server_root / "models" / "overall_posture"
        self.model_path = model_path or (
            model_dir / "three_class_walk17_classifier.pkl"
        )
        self.pose_model_path = pose_model_path or (
            model_dir / "pose_landmarker_full.task"
        )
        self.metadata_path = model_dir / "model_metadata.json"
        self._artifact: dict[str, Any] | None = None
        self._artifact_lock = threading.RLock()
        self._inference_lock = threading.Lock()

    def descriptor(self) -> ModelModuleDescriptor:
        assets_found = (
            self.model_path.is_file()
            and self.pose_model_path.is_file()
            and self.metadata_path.is_file()
        )
        return ModelModuleDescriptor(
            id=self.MODULE_ID,
            display_name="整体姿态分析",
            category="posture",
            description=(
                "从 RealSense 步行片段提取 17 项步态特征，"
                "输出 NP3GAIT 0/1/2 三分类结果。"
            ),
            status="ready" if assets_found else "error",
            status_detail=(
                "walk17 三分类模型和姿态关键点资源已就绪。"
                if assets_found
                else "缺少 walk17 分类器或 Pose Landmarker 资源。"
            ),
            input_kinds=["realsense_bag", "tabular"],
            input_slots=[
                InputSlotDescriptor(
                    key="walk_source",
                    label="整体姿态步行 .bag",
                    description=(
                        "RealSense 录制文件。只会处理分段清单中 "
                        "task_type=walk 的时间段。"
                    ),
                    accepted_kinds=["realsense_bag"],
                    required=True,
                    multiple=False,
                ),
                InputSlotDescriptor(
                    key="segment_manifest",
                    label="步行分段清单",
                    description=(
                        "视频分割页保存的 segments.csv 或 segments.json，"
                        "必须包含 segment_id、label、task_type、start_s、end_s。"
                    ),
                    accepted_kinds=["tabular"],
                    required=True,
                    multiple=False,
                ),
            ],
            output_capabilities=[
                "quality_metrics",
                "gait_features_17",
                "class_probabilities",
                "np3gait_three_class",
            ],
            model_version=self.MODULE_VERSION,
        )

    def validate(self, request: InferenceRequest) -> list[str]:
        issues: list[str] = []
        if request.module_id != self.MODULE_ID:
            issues.append("请求模块 ID 与整体姿态模块不匹配。")

        expected_slots = {"walk_source", "segment_manifest"}
        for slot in set(request.inputs) - expected_slots:
            issues.append(f"未知输入槽：{slot}")

        bag_files = request.inputs.get("walk_source", ())
        manifest_files = request.inputs.get("segment_manifest", ())
        if len(bag_files) != 1:
            issues.append("walk_source 必须且只能提供一个 .bag。")
        elif not bag_files[0].path.is_file():
            issues.append(f"步行 .bag 不存在：{bag_files[0].path}")
        elif bag_files[0].path.suffix.lower() != ".bag":
            issues.append("walk_source 当前只支持 RealSense .bag。")

        if len(manifest_files) != 1:
            issues.append("segment_manifest 必须且只能提供一个 CSV/JSON。")
        elif not manifest_files[0].path.is_file():
            issues.append(f"分段清单不存在：{manifest_files[0].path}")
        elif manifest_files[0].path.suffix.lower() not in {".csv", ".json"}:
            issues.append("segment_manifest 只支持 .csv 或 .json。")
        else:
            try:
                walk_segments, manifest_distance, _ = self._read_manifest(
                    manifest_files[0].path
                )
                if not walk_segments:
                    issues.append("分段清单中没有 task_type=walk 的片段。")
                self._resolve_walk_distance(
                    request.parameters, manifest_distance
                )
            except (OSError, ValueError, json.JSONDecodeError) as error:
                issues.append(f"分段清单无效：{error}")

        if not self.model_path.is_file():
            issues.append(f"walk17 模型文件不存在：{self.model_path}")
        if not self.pose_model_path.is_file():
            issues.append(f"Pose Landmarker 资源不存在：{self.pose_model_path}")
        if not self.metadata_path.is_file():
            issues.append(f"模型元数据不存在：{self.metadata_path}")

        if not issues:
            try:
                self._load_artifact()
            except Exception as error:
                issues.append(f"walk17 模型无法加载：{error}")
        return issues

    def infer(
        self,
        request: InferenceRequest,
        progress: ProgressCallback | None = None,
    ) -> ModuleResult:
        issues = self.validate(request)
        if issues:
            raise ModuleUnavailableError("; ".join(issues))

        bag_path = request.inputs["walk_source"][0].path
        manifest_path = request.inputs["segment_manifest"][0].path
        walk_segments, manifest_distance, ignored_count = self._read_manifest(
            manifest_path
        )
        walk_distance_m, used_default_distance = self._resolve_walk_distance(
            request.parameters, manifest_distance
        )
        output_dir = self._output_dir(request)
        output_dir.mkdir(parents=True, exist_ok=True)
        normalized_manifest = output_dir / "walk_segments.csv"
        self._write_walk_manifest(normalized_manifest, walk_segments)

        warnings: list[str] = [
            "walk17 三分类当前为研究性模型输出；"
            "外部 MediaPipe 患者样本少且没有正常对照，"
            "结果不得单独作为临床诊断结论。"
        ]
        if ignored_count:
            warnings.append(
                f"已忽略分段清单中 {ignored_count} 个非 walk 片段。"
            )
        if used_default_distance:
            warnings.append(
                "未在请求或分段 JSON 中提供 walk_distance_m；"
                "SP_U 按现有采集协议默认使用 10.0 米。"
            )

        if progress:
            progress(0.02, "正在读取 RealSense 步行片段…")
        args = Namespace(
            bag=str(bag_path),
            segments=str(normalized_manifest),
            out=str(output_dir),
            score_file=None,
            walk_distance_m=walk_distance_m,
            depth_window=int(request.parameters.get("depth_window", 5)),
            model_complexity=1,
            model_path=str(self.pose_model_path),
            min_detection_confidence=float(
                request.parameters.get("min_detection_confidence", 0.5)
            ),
            min_tracking_confidence=float(
                request.parameters.get("min_tracking_confidence", 0.5)
            ),
            # VP8/WebM is directly playable by Chromium/Tauri WebView and does
            # not require an external ffmpeg/H.264 installation.
            video_codec="VP80",
            max_frames=None,
            # The annotated segment video is a first-class module output.  It
            # contains the skeleton plus frame-level pose/depth quality and is
            # served by the assessment output endpoint for the UI.
            write_annotated_video=True,
            write_excel_report=False,
            progress_callback=progress,
        )

        with self._inference_lock:
            extraction = analysis.run_analysis(args)
        metric_rows = [
            row
            for row in extraction["metric_rows"]
            if row.get("metric_status") == "computed"
            and str(row.get("task_type", "")).lower() == "walk"
        ]
        if not metric_rows:
            raise RuntimeError("未生成可用的 walk 特征行。")

        if progress:
            progress(0.92, "17 项步态特征已生成，正在执行三分类…")
        segment_results, predictions = self._predict_rows(
            metric_rows, warnings
        )
        final_class = self._aggregate_predictions(
            segment_results, predictions
        )
        final_label = CLASS_LABELS[final_class]

        pose_rates = [
            float(row["pose_detection_rate"])
            for row in metric_rows
            if self._finite(row.get("pose_detection_rate"))
        ]
        depth_rates = [
            float(row["valid_depth_rate"])
            for row in metric_rows
            if self._finite(row.get("valid_depth_rate"))
        ]
        mean_pose_rate = sum(pose_rates) / len(pose_rates) if pose_rates else None
        mean_depth_rate = sum(depth_rates) / len(depth_rates) if depth_rates else None

        if progress:
            progress(1.0, "整体姿态 walk17 推理完成。")
        metrics_path = Path(extraction["metrics_path"])
        output_artifacts = [
            str(metrics_path.resolve()),
            str(normalized_manifest.resolve()),
        ]
        annotated_videos: list[dict[str, Any]] = []
        for quality_row in extraction.get("quality_rows", []):
            video_value = quality_row.get("annotated_video")
            if not video_value:
                continue
            video_path = Path(str(video_value)).resolve()
            if not video_path.is_file():
                continue
            artifact_index = len(output_artifacts)
            output_artifacts.append(str(video_path))
            annotated_videos.append(
                {
                    "segment_id": str(quality_row.get("segment_id", "")),
                    "label": str(quality_row.get("label", "")),
                    "artifact_index": artifact_index,
                    "media_type": (
                        "video/webm"
                        if video_path.suffix.lower() == ".webm"
                        else "video/mp4"
                    ),
                    "overlay_metrics": [
                        "frame_index",
                        "timestamp_s",
                        "pose_detected",
                        "valid_depth_rate",
                    ],
                }
            )
        return ModuleResult(
            module_id=self.MODULE_ID,
            module_version=self.MODULE_VERSION,
            summary=(
                f"整体姿态分析完成：{len(segment_results)} 个 walk 片段，"
                f"患者级 NP3GAIT={final_class} ({final_label})。"
            ),
            quality={
                "walk_segments": len(segment_results),
                "mean_pose_detection_rate": mean_pose_rate,
                "mean_valid_depth_rate": mean_depth_rate,
                "segments": [item["quality"] for item in segment_results],
            },
            metrics={
                "walk_segment_count": len(segment_results),
                "walk_distance_m": walk_distance_m,
                "mean_pose_detection_rate": mean_pose_rate,
                "mean_valid_depth_rate": mean_depth_rate,
            },
            scores={
                "np3gait_class": final_class,
                "np3gait_label": final_label,
                "aggregation": "segment_majority_vote",
            },
            result_data={
                "model": {
                    "feature_mode": "walk17",
                    "prediction_mode": "three_class_raw",
                    "classes": [0, 1, 2],
                    "features": WALK_FEATURES,
                },
                "segments": segment_results,
                "visualization": {
                    "type": "annotated_pose_video",
                    "annotated_videos": annotated_videos,
                    "availability": (
                        "ready" if annotated_videos else "unavailable"
                    ),
                },
            },
            output_artifacts=output_artifacts,
            warnings=warnings,
        )

    def _load_artifact(self) -> dict[str, Any]:
        with self._artifact_lock:
            if self._artifact is None:
                try:
                    import joblib
                    import sklearn
                except ImportError as error:
                    raise ModuleUnavailableError(
                        "缺少 joblib/scikit-learn 模型运行依赖。"
                    ) from error
                metadata = json.loads(
                    self.metadata_path.read_text(encoding="utf-8")
                )
                expected_version = str(
                    metadata.get("trained_with_scikit_learn", "")
                )
                if sklearn.__version__ != expected_version:
                    raise ValueError(
                        "scikit-learn 版本与模型不一致："
                        f"需要 {expected_version}，当前 {sklearn.__version__}"
                    )
                expected_model_hash = str(metadata.get("model_sha256", ""))
                if self._sha256(self.model_path) != expected_model_hash:
                    raise ValueError("walk17 模型 SHA-256 校验失败")
                expected_pose_hash = str(
                    metadata.get("pose_model_sha256", "")
                )
                if self._sha256(self.pose_model_path) != expected_pose_hash:
                    raise ValueError("Pose Landmarker SHA-256 校验失败")
                artifact = joblib.load(self.model_path)
                features = list(artifact.get("features", []))
                classes = [int(value) for value in artifact.get("classes", [])]
                if features != WALK_FEATURES:
                    raise ValueError(
                        "模型特征顺序与 walk17 提取器不一致"
                    )
                if classes != [0, 1, 2]:
                    raise ValueError("模型必须是 0/1/2 三分类")
                if artifact.get("prediction_mode") != "three_class_raw":
                    raise ValueError("模型不是 three_class_raw 输出模式")
                if "pipeline" not in artifact:
                    raise ValueError("模型 artifact 缺少 pipeline")
                self._artifact = artifact
            return self._artifact

    def _predict_rows(
        self,
        rows: list[dict[str, object]],
        warnings: list[str],
    ) -> tuple[list[dict[str, Any]], list[int]]:
        try:
            import numpy as np
            import pandas as pd
        except ImportError as error:
            raise ModuleUnavailableError(
                "缺少 pandas/numpy 特征整理依赖。"
            ) from error

        artifact = self._load_artifact()
        pipeline = artifact["pipeline"]
        frame = pd.DataFrame(rows)
        missing_columns = [name for name in WALK_FEATURES if name not in frame]
        if missing_columns:
            raise ValueError(
                f"特征提取结果缺少列：{', '.join(missing_columns)}"
            )
        features = frame[WALK_FEATURES].apply(
            pd.to_numeric, errors="coerce"
        )
        missing_by_row = features.isna().sum(axis=1).tolist()
        predictions = [int(value) for value in pipeline.predict(features)]

        probabilities = None
        pipeline_classes = [
            int(value) for value in getattr(pipeline, "classes_", [])
        ]
        if hasattr(pipeline, "predict_proba"):
            probabilities = np.asarray(pipeline.predict_proba(features))

        results: list[dict[str, Any]] = []
        for index, row in enumerate(rows):
            missing_count = int(missing_by_row[index])
            if missing_count:
                warnings.append(
                    f"片段 {row.get('segment_id')} 有 {missing_count} 个缺失特征；"
                    "已由模型内置 imputer 处理，未补 0。"
                )
            probability_map = {
                str(class_id): (
                    float(probabilities[index, pipeline_classes.index(class_id)])
                    if probabilities is not None and class_id in pipeline_classes
                    else None
                )
                for class_id in (0, 1, 2)
            }
            feature_values = {
                name: (
                    None
                    if pd.isna(features.iloc[index][name])
                    else float(features.iloc[index][name])
                )
                for name in WALK_FEATURES
            }
            predicted_class = predictions[index]
            results.append(
                {
                    "segment_id": str(row.get("segment_id", "")),
                    "label": str(row.get("label", "")),
                    "task_type": "walk",
                    "start_s": self._optional_float(row.get("start_s")),
                    "end_s": self._optional_float(row.get("end_s")),
                    "duration_s": self._optional_float(row.get("duration_s")),
                    "quality": {
                        "segment_id": str(row.get("segment_id", "")),
                        "frames_total": self._optional_int(row.get("frames_total")),
                        "pose_detection_rate": self._optional_float(
                            row.get("pose_detection_rate")
                        ),
                        "valid_depth_rate": self._optional_float(
                            row.get("valid_depth_rate")
                        ),
                        "missing_feature_count": missing_count,
                    },
                    "features": feature_values,
                    "prediction": {
                        "class": predicted_class,
                        "label": CLASS_LABELS[predicted_class],
                        "probabilities": probability_map,
                    },
                }
            )
        return results, predictions

    @staticmethod
    def _aggregate_predictions(
        segment_results: list[dict[str, Any]], predictions: list[int]
    ) -> int:
        counts = Counter(predictions)
        best_count = max(counts.values())
        tied = [class_id for class_id, count in counts.items() if count == best_count]
        if len(tied) == 1:
            return tied[0]
        mean_probability = {
            class_id: sum(
                float(item["prediction"]["probabilities"][str(class_id)] or 0.0)
                for item in segment_results
            )
            / len(segment_results)
            for class_id in tied
        }
        return max(tied, key=lambda class_id: mean_probability[class_id])

    @classmethod
    def _resolve_walk_distance(
        cls,
        parameters: dict[str, Any],
        manifest_distance: float | None,
    ) -> tuple[float, bool]:
        raw_value = parameters.get("walk_distance_m", manifest_distance)
        used_default = raw_value is None
        value = cls.DEFAULT_WALK_DISTANCE_M if used_default else float(raw_value)
        if not math.isfinite(value) or value <= 0:
            raise ValueError("walk_distance_m 必须是大于 0 的米制数值")
        return value, used_default

    @staticmethod
    def _read_manifest(
        path: Path,
    ) -> tuple[list[dict[str, object]], float | None, int]:
        manifest_distance: float | None = None
        if path.suffix.lower() == ".json":
            payload = json.loads(path.read_text(encoding="utf-8-sig"))
            if isinstance(payload, dict):
                rows = payload.get("segments", [])
                raw_distance = payload.get("walk_distance_m")
                if raw_distance is not None:
                    manifest_distance = float(raw_distance)
            elif isinstance(payload, list):
                rows = payload
            else:
                raise ValueError("JSON 必须是分段数组或包含 segments 的对象")
        else:
            with path.open("r", newline="", encoding="utf-8-sig") as handle:
                rows = list(csv.DictReader(handle))

        if not isinstance(rows, list):
            raise ValueError("segments 必须是数组")
        required = {"segment_id", "label", "task_type", "start_s", "end_s"}
        normalized: list[dict[str, object]] = []
        ignored_count = 0
        ids: set[str] = set()
        distances: set[float] = set()
        for index, raw in enumerate(rows, start=1):
            if not isinstance(raw, dict):
                raise ValueError(f"第 {index} 个分段不是对象")
            missing = required - set(raw)
            if missing:
                raise ValueError(
                    f"第 {index} 个分段缺少：{', '.join(sorted(missing))}"
                )
            task_type = str(raw["task_type"]).strip().lower()
            if task_type != "walk":
                ignored_count += 1
                continue
            segment_id = str(raw["segment_id"]).strip()
            label = str(raw["label"]).strip()
            if not segment_id or not label:
                raise ValueError(f"第 {index} 个 walk 分段的 ID/label 为空")
            if segment_id in ids:
                raise ValueError(f"segment_id 重复：{segment_id}")
            ids.add(segment_id)
            start_s = float(raw["start_s"])
            end_s = float(raw["end_s"])
            if not all(math.isfinite(value) for value in (start_s, end_s)):
                raise ValueError(f"片段 {segment_id} 时间不是有限数")
            if start_s < 0 or end_s <= start_s:
                raise ValueError(f"片段 {segment_id} 时间范围无效")
            if raw.get("walk_distance_m") not in (None, ""):
                distances.add(float(raw["walk_distance_m"]))
            normalized.append(
                {
                    "segment_id": segment_id,
                    "label": label,
                    "task_type": "walk",
                    "start_s": start_s,
                    "end_s": end_s,
                }
            )

        normalized.sort(key=lambda item: float(item["start_s"]))
        for previous, current in zip(normalized, normalized[1:]):
            if float(current["start_s"]) < float(previous["end_s"]):
                raise ValueError(
                    f"片段 {previous['segment_id']} 与 {current['segment_id']} 时间重叠"
                )
        if len(distances) > 1:
            raise ValueError("同一次推理的 walk_distance_m 必须一致")
        if distances:
            row_distance = next(iter(distances))
            if manifest_distance is not None and not math.isclose(
                manifest_distance, row_distance
            ):
                raise ValueError("JSON 顶层与分段内 walk_distance_m 不一致")
            manifest_distance = row_distance
        return normalized, manifest_distance, ignored_count

    @staticmethod
    def _write_walk_manifest(
        path: Path, rows: list[dict[str, object]]
    ) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        temp_path = path.with_suffix(".csv.tmp")
        with temp_path.open("w", newline="", encoding="utf-8-sig") as handle:
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
            writer.writerows(rows)
        temp_path.replace(path)

    @staticmethod
    def _output_dir(request: InferenceRequest) -> Path:
        configured = request.parameters.get("output_dir")
        if configured:
            return Path(str(configured)).resolve()
        return (
            Path(tempfile.gettempdir())
            / "medvision_overall_posture"
            / request.assessment_id
        ).resolve()

    @staticmethod
    def _finite(value: object) -> bool:
        try:
            return math.isfinite(float(value))
        except (TypeError, ValueError):
            return False

    @staticmethod
    def _sha256(path: Path) -> str:
        digest = hashlib.sha256()
        with path.open("rb") as handle:
            while chunk := handle.read(1024 * 1024):
                digest.update(chunk)
        return digest.hexdigest().upper()

    @classmethod
    def _optional_float(cls, value: object) -> float | None:
        return float(value) if cls._finite(value) else None

    @classmethod
    def _optional_int(cls, value: object) -> int | None:
        return int(float(value)) if cls._finite(value) else None
