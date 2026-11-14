"""System adapter for complete Shoes MATLAB recording sessions.

The adapter preserves every supplied source file byte for byte. It reads the
MATLAB outputs without re-running or silently changing any gait calculation.
"""

from __future__ import annotations

import csv
import math
import re
import shutil
from collections import deque
from pathlib import Path
from statistics import mean

from app.modules.base import InferenceModule, ProgressCallback
from app.schemas.modules import (
    InferenceRequest,
    InputSlotDescriptor,
    ModelModuleDescriptor,
    ModuleResult,
)


FILE_PREFIXES = (
    "raw_mqtt_low_latency",
    "manual_steps_template",
    "trajectory_state",
    "pressure_decoded",
    "time_alignment",
    "imu_decoded",
    "step_metrics",
    "gait_state",
    "calibration",
    "session_manifest",
)
SESSION_PATTERN = re.compile(r"_(\d{8}_\d{6}(?:_\d{3})?)\.(?:csv|txt)$", re.I)


def file_role(name: str) -> str | None:
    lower = Path(name).name.lower()
    if Path(lower).suffix not in {".csv", ".txt"}:
        return None
    for prefix in FILE_PREFIXES:
        if lower == f"{prefix}.csv" or lower == f"{prefix}.txt" or lower.startswith(prefix + "_"):
            return prefix
    return None


def number(row: dict[str, str], key: str) -> float | None:
    try:
        value = float(row.get(key, ""))
    except (TypeError, ValueError):
        return None
    return value if math.isfinite(value) else None


def rows(path: Path):
    with path.open("r", encoding="utf-8-sig", newline="") as source:
        yield from csv.DictReader(source)


def pressure_map(row: dict[str, str]) -> list[list[float | None]] | None:
    values = [number(row, f"p{index:02d}") for index in range(1, 49)]
    if all(value is None for value in values):
        return None
    # MATLAB: S(:,1)=P(1:12), ..., S(:,4)=P(37:48).
    return [[values[column * 12 + line] for column in range(4)] for line in range(12)]


def read_recording(paths: dict[str, Path]) -> tuple[dict, dict, dict, list[str]]:
    metrics: dict[str, float | int] = {}
    quality: dict[str, object] = {}
    data: dict[str, object] = {
        "steps": [],
        "pressure_maps": {},
        "pressure_timeseries": {"left": [], "right": []},
        "imu_timeseries": {"left": [], "right": []},
        "trajectory": {"left": [], "right": []},
    }
    warnings: list[str] = []

    gait_path = paths.get("gait_state")
    if gait_path:
        first_time: float | None = None
        last_time: float | None = None
        counts = {"left": 0, "right": 0}
        events = {"left": {"heel_strike": 0, "toe_off": 0}, "right": {"heel_strike": 0, "toe_off": 0}}
        pressure_maps: dict[str, list[list[float | None]]] = {}
        pressure_history: dict[str, deque[dict[str, float | int | None]]] = {
            "left": deque(maxlen=500), "right": deque(maxlen=500)
        }
        for row in rows(gait_path):
            foot = row.get("foot", "")
            if foot not in counts:
                continue
            counts[foot] += 1
            timestamp = number(row, "t")
            if timestamp is not None:
                first_time = timestamp if first_time is None else min(first_time, timestamp)
                last_time = timestamp if last_time is None else max(last_time, timestamp)
            for column, name in (("heelStrike", "heel_strike"), ("toeOff", "toe_off")):
                if number(row, column) == 1:
                    events[foot][name] += 1
            matrix = pressure_map(row)
            if matrix is not None:
                pressure_maps[foot] = matrix
            pressure_history[foot].append({
                "t": timestamp,
                "total": number(row, "total"),
                "cop_y": number(row, "COPyNorm"),
                "contact": number(row, "contact"),
            })
        data["pressure_maps"] = pressure_maps
        data["pressure_timeseries"] = {foot: list(history) for foot, history in pressure_history.items()}
        data["events"] = events
        quality["gait_rows"] = counts
        if first_time is not None and last_time is not None:
            metrics["recording_duration_s"] = max(0.0, last_time - first_time)
        if not sum(counts.values()):
            warnings.append("步态状态文件没有有效记录。")
    else:
        warnings.append("缺少 gait_state，无法展示接触事件及校正后的压力图。")

    step_path = paths.get("step_metrics")
    if step_path:
        step_records: list[dict[str, str | float | int | None]] = []
        lengths: dict[str, list[float]] = {"left": [], "right": []}
        speed: dict[str, list[float]] = {"left": [], "right": []}
        suspicious = 0
        for row in rows(step_path):
            foot = row.get("foot", "")
            if foot not in lengths:
                continue
            step_length = number(row, "step_length_m")
            step_speed = number(row, "step_speed_mps")
            if step_length is not None:
                lengths[foot].append(step_length)
            if step_speed is not None:
                speed[foot].append(step_speed)
            suspicious += int(number(row, "suspicious_step") == 1)
            step_records.append({
                "foot": foot,
                "foot_step_count": number(row, "foot_step_count"),
                "lift_time": number(row, "lift_time"),
                "land_time": number(row, "land_time"),
                "reported_step_length_m": step_length,
                "reported_step_frequency_spm": number(row, "step_frequency_spm"),
                "reported_step_speed_mps": step_speed,
                "reported_stride_duration_s": number(row, "stride_duration_s"),
                "suspicious_step": number(row, "suspicious_step") == 1,
            })
        data["steps"] = step_records[-1000:]
        for foot in ("left", "right"):
            metrics[f"{foot}_step_count"] = sum(1 for record in step_records if record["foot"] == foot)
            if lengths[foot]:
                metrics[f"{foot}_mean_reported_step_length_m"] = mean(lengths[foot])
            if speed[foot]:
                metrics[f"{foot}_mean_reported_step_speed_mps"] = mean(speed[foot])
        quality["suspicious_step_count"] = suspicious
        quality["step_rows"] = len(step_records)
        if not step_records:
            warnings.append("单步指标文件没有步数记录。")
    else:
        warnings.append("缺少 step_metrics，无法展示鞋端计算的单步指标。")

    trajectory_path = paths.get("trajectory_state")
    if trajectory_path:
        traces: dict[str, deque[dict[str, float | None]]] = {
            "left": deque(maxlen=1000), "right": deque(maxlen=1000)
        }
        trajectory_rows = 0
        for row in rows(trajectory_path):
            trajectory_rows += 1
            timestamp = number(row, "t")
            for foot in ("left", "right"):
                x = number(row, f"{foot}_pos_x")
                y = number(row, f"{foot}_pos_y")
                z = number(row, f"{foot}_pos_z")
                if x is not None and y is not None:
                    traces[foot].append({"t": timestamp, "x": x, "y": y, "z": z})
        data["trajectory"] = {foot: list(trace) for foot, trace in traces.items()}
        quality["trajectory_rows"] = trajectory_rows
    else:
        warnings.append("缺少 trajectory_state，无法展示左右脚轨迹。")

    for role in ("imu_decoded", "pressure_decoded"):
        path = paths.get(role)
        if path:
            total = 0
            rejected = 0
            imu_history: dict[str, deque[dict[str, float | None]]] = {
                "left": deque(maxlen=250), "right": deque(maxlen=250)
            }
            for row in rows(path):
                total += 1
                rejected += int(number(row, "stream_accepted") == 0)
                if role == "imu_decoded" and row.get("foot") in imu_history:
                    imu_history[row["foot"]].append({
                        "t": number(row, "t"),
                        "x": number(row, "accX_g"),
                        "y": number(row, "accY_g"),
                        "z": number(row, "accZ_g"),
                    })
            quality[f"{role}_rows"] = total
            quality[f"{role}_rejected_rows"] = rejected
            if role == "imu_decoded":
                data["imu_timeseries"] = {foot: list(history) for foot, history in imu_history.items()}
    if "time_alignment" not in paths:
        warnings.append("缺少时间对齐日志，无法核验双脚时间基准。")
    if "calibration" not in paths:
        warnings.append("缺少校准日志，无法核验采集前校准过程。")
    return metrics, quality, data, warnings


class SmartInsoleModule(InferenceModule):
    MODULE_ID = "smart-insole"
    MODULE_VERSION = "shoes-matlab-session-v1"

    def descriptor(self) -> ModelModuleDescriptor:
        return ModelModuleDescriptor(
            id=self.MODULE_ID,
            display_name="智能鞋垫分析",
            category="insole",
            description="导入 Shoes 原始会话文件，保留原始算法输出并展示压力、事件、轨迹与单步指标。",
            status="ready",
            status_detail="支持 Shoes 会话 CSV/TXT 的无改算导入；实时硬件会话由独立采集入口启动。",
            input_kinds=["insole_timeseries", "tabular"],
            input_slots=[InputSlotDescriptor(
                key="insole_data",
                label="Shoes 会话文件",
                description="上传同一采集会话的 CSV/TXT 文件；建议包含所有十类日志文件。",
                accepted_kinds=["insole_timeseries", "tabular"],
                required=True,
                multiple=True,
            )],
            output_capabilities=["pressure_timeseries", "gait_events", "foot_trajectory", "step_metrics", "source_files"],
            model_version=self.MODULE_VERSION,
        )

    def validate(self, request: InferenceRequest) -> list[str]:
        issues: list[str] = []
        if request.module_id != self.MODULE_ID:
            issues.append("请求模块 ID 与智能鞋垫模块不匹配。")
        if set(request.inputs) - {"insole_data"}:
            issues.append("智能鞋垫只接受 insole_data 输入槽。")
        artifacts = request.inputs.get("insole_data", ())
        if not artifacts:
            issues.append("至少提供一份 Shoes 会话 CSV/TXT 文件。")
        names: set[str] = set()
        stamps: set[str] = set()
        roles: set[str] = set()
        for artifact in artifacts:
            name = Path(str(artifact.metadata.get("original_name", artifact.path.name))).name
            if artifact.module_id != self.MODULE_ID or artifact.input_slot != "insole_data":
                issues.append(f"{name} 的模块或输入槽绑定不正确。")
            if artifact.kind not in {"tabular", "insole_timeseries"}:
                issues.append(f"{name} 的输入类型不支持。")
            if not artifact.path.is_file():
                issues.append(f"输入文件不存在：{name}")
            if name.lower() in names:
                issues.append(f"重复的会话文件名：{name}")
            names.add(name.lower())
            role = file_role(name)
            if role is None:
                issues.append(f"无法识别 Shoes 会话文件：{name}")
            else:
                if role in roles:
                    issues.append(f"同一会话中重复提供了 {role}。")
                roles.add(role)
            match = SESSION_PATTERN.search(name)
            if match:
                stamps.add(match.group(1))
        if len(stamps) > 1:
            issues.append("输入文件来自不同 Shoes 采集会话。")
        if roles and not ({"gait_state", "step_metrics", "trajectory_state"} & roles):
            issues.append("至少提供 gait_state、step_metrics 或 trajectory_state 中的一项。")
        return issues

    def infer(self, request: InferenceRequest, progress: ProgressCallback | None = None) -> ModuleResult:
        issues = self.validate(request)
        if issues:
            raise ValueError("；".join(issues))
        if progress:
            progress(0.1, "正在读取 Shoes 会话")
        artifacts = request.inputs["insole_data"]
        paths = {
            file_role(Path(str(item.metadata.get("original_name", item.path.name))).name): item.path
            for item in artifacts
        }
        metrics, quality, data, warnings = read_recording(paths)
        output_dir = Path(str(request.parameters["output_dir"]))
        output_dir.mkdir(parents=True, exist_ok=True)
        outputs: list[str] = []
        files: list[dict[str, str | int]] = []
        for artifact in artifacts:
            name = Path(str(artifact.metadata.get("original_name", artifact.path.name))).name
            destination = output_dir / name
            if artifact.path.resolve() != destination.resolve():
                shutil.copyfile(artifact.path, destination)
            files.append({"name": name, "role": file_role(name) or "", "artifact_index": len(outputs)})
            outputs.append(str(destination))
        data["source_files"] = files
        quality["supplied_file_roles"] = sorted(paths)
        quality["missing_file_roles"] = sorted(set(FILE_PREFIXES) - set(paths))
        stamps = [SESSION_PATTERN.search(item["name"]) for item in files]
        data["session_stamp"] = next((match.group(1) for match in stamps if match), None)
        if progress:
            progress(1.0, "Shoes 会话导入完成")
        return ModuleResult(
            module_id=self.MODULE_ID,
            module_version=self.MODULE_VERSION,
            summary="Shoes 会话已按原始 MATLAB 输出导入；展示值未重新计算步态算法。",
            quality=quality,
            metrics=metrics,
            scores={},
            result_data=data,
            output_artifacts=outputs,
            warnings=warnings,
        )
