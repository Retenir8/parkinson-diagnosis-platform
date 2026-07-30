from __future__ import annotations

from pathlib import Path

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


class OverallPostureModule(InferenceModule):
    """Readiness probe for the existing overall-posture pipeline.

    The current repository contains the trained artifact and standalone
    scripts. The service adapter intentionally remains pending until the team
    confirms segmentation, feature-source and scoring behavior for the app.
    """

    def __init__(self) -> None:
        workspace_root = Path(__file__).resolve().parents[5]
        self.model_path = (
            workspace_root / "整体姿态预测" / "np3gait_best_classifier.pkl"
        )
        self.pipeline_path = (
            workspace_root
            / "bodyInsp 2"
            / "bodyInsp"
            / "analyze_bag_segments.py"
        )

    def descriptor(self) -> ModelModuleDescriptor:
        artifacts_found = self.model_path.is_file() and self.pipeline_path.is_file()
        return ModelModuleDescriptor(
            id="overall-posture",
            display_name="整体姿态分析",
            category="posture",
            description="全身关键点、步态特征与现有 NP3GAIT 分类流程。",
            status="adapter_pending" if artifacts_found else "error",
            status_detail=(
                "已检测到现有模型和分析脚本；等待服务化适配与输入协议确认。"
                if artifacts_found
                else "未检测到预期的现有模型或分析脚本。"
            ),
            input_kinds=["video", "realsense_bag", "tabular"],
            input_slots=[
                InputSlotDescriptor(
                    key="analysis_source",
                    label="整体姿态输入",
                    description=(
                        "接收普通视频、RealSense .bag 或已提取特征表；"
                        "具体分段和距离参数仍待确认。"
                    ),
                    accepted_kinds=["video", "realsense_bag", "tabular"],
                    required=True,
                    multiple=True,
                )
            ],
            output_capabilities=[
                "quality_metrics",
                "gait_features",
                "class_probabilities",
                "annotated_video",
            ],
            model_version=None,
        )

    def validate(self, request: InferenceRequest) -> list[str]:
        issues: list[str] = []
        if not request.artifacts:
            issues.append("至少需要一个视频、RealSense 或特征数据文件。")
        if not self.model_path.is_file():
            issues.append(f"模型文件不存在：{self.model_path}")
        if not self.pipeline_path.is_file():
            issues.append(f"分析脚本不存在：{self.pipeline_path}")
        issues.append("应用内分段方式和步行距离来源尚未确认。")
        return issues

    def infer(
        self,
        request: InferenceRequest,
        progress: ProgressCallback | None = None,
    ) -> ModuleResult:
        del request, progress
        raise ModuleUnavailableError(
            "整体姿态模块尚未完成服务适配；没有执行模型推理。"
        )
