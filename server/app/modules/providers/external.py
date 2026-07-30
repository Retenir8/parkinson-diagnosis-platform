from __future__ import annotations

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


class ExternalModulePlaceholder(InferenceModule):
    def __init__(self, descriptor: ModelModuleDescriptor) -> None:
        self._descriptor = descriptor

    def descriptor(self) -> ModelModuleDescriptor:
        return self._descriptor

    def validate(self, request: InferenceRequest) -> list[str]:
        del request
        return [
            "模型文件、运行环境、输入字段和输出评分协议尚未由模块负责人提供。"
        ]

    def infer(
        self,
        request: InferenceRequest,
        progress: ProgressCallback | None = None,
    ) -> ModuleResult:
        del request, progress
        raise ModuleUnavailableError(
            f"{self._descriptor.display_name}尚未接入；没有执行模型推理。"
        )


def hand_module() -> ExternalModulePlaceholder:
    return ExternalModulePlaceholder(
        ModelModuleDescriptor(
            id="hand-motion",
            display_name="手部运动分析",
            category="hand",
            description="预留手部视频、关键点、动作质量和评分输出接口。",
            status="external_pending",
            status_detail="等待手部模型负责人提供模型包与接口说明。",
            input_kinds=["video"],
            input_slots=[
                InputSlotDescriptor(
                    key="hand_video",
                    label="手部视频输入",
                    description="具体动作、左右手、视角和视频要求待负责人确认。",
                    accepted_kinds=["video"],
                    required=True,
                    multiple=True,
                )
            ],
            output_capabilities=[
                "keypoints",
                "temporal_metrics",
                "module_scores",
                "annotated_video",
            ],
        )
    )


def leg_module() -> ExternalModulePlaceholder:
    return ExternalModulePlaceholder(
        ModelModuleDescriptor(
            id="leg-motion",
            display_name="腿部运动分析",
            category="leg",
            description="预留腿部视频、运动学指标和评分输出接口。",
            status="external_pending",
            status_detail="等待腿部模型负责人提供模型包与接口说明。",
            input_kinds=["video"],
            input_slots=[
                InputSlotDescriptor(
                    key="leg_video",
                    label="腿部视频输入",
                    description="具体动作、视角、片段边界和画面要求待负责人确认。",
                    accepted_kinds=["video"],
                    required=True,
                    multiple=True,
                )
            ],
            output_capabilities=[
                "keypoints",
                "kinematic_metrics",
                "module_scores",
                "annotated_video",
            ],
        )
    )


def insole_module() -> ExternalModulePlaceholder:
    return ExternalModulePlaceholder(
        ModelModuleDescriptor(
            id="smart-insole",
            display_name="智能鞋垫分析",
            category="insole",
            description="预留压力、步态周期及其他鞋垫时序数据接口。",
            status="external_pending",
            status_detail="等待硬件协议、字段定义、采样率和评分规则确认。",
            input_kinds=["insole_timeseries", "tabular"],
            input_slots=[
                InputSlotDescriptor(
                    key="insole_data",
                    label="智能鞋垫数据输入",
                    description="文件格式、字段、单位、采样率和同步协议待负责人确认。",
                    accepted_kinds=["insole_timeseries", "tabular"],
                    required=True,
                    multiple=True,
                )
            ],
            output_capabilities=[
                "pressure_timeseries",
                "gait_cycles",
                "pressure_map",
                "module_scores",
            ],
        )
    )
