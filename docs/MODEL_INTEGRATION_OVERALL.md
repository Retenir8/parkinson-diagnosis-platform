# 整体姿态 walk17 模型接入说明

## 模块信息

- 模块 ID：`overall-posture`
- 模型文件：`server/models/overall_posture/three_class_walk17_classifier.pkl`
- 姿态资源：`server/models/overall_posture/pose_landmarker_full.task`
- 提取器：`server/app/modules/overall_posture_analysis.py`
- 运行方式：MediaPipe Pose Landmarker + RealSense 深度 + scikit-learn
- 模型输出：`0=Normal`、`1=Mild`、`2=Moderate/Severe`
- 预测模式：`three_class_raw`，不使用临床 1/2 阈值

## 输入槽

| input_slot | 数据类型 | 约束 |
|---|---|---|
| `walk_source` | `realsense_bag` | 一个 RealSense `.bag` |
| `segment_manifest` | `tabular` | 一个 `segments.csv` 或 `segments.json` |

分段清单必须包含：

```text
segment_id,label,task_type,start_s,end_s
```

模块会过滤非 `walk` 片段，再写入评估输出目录下的 `walk_segments.csv`。非 walk 片段不会被误送入分类器。

`SP_U` 需要实际步行距离：

- 可在 `segments.json` 顶层添加 `"walk_distance_m": 10.0`；
- 或在 `InferenceRequest.parameters.walk_distance_m` 提供；
- 两者均没有时使用现有协议默认值 `10.0 m`，并在结果中输出警告。

## 17 特征合同

```text
SP_U, RA_AMP_U, LA_AMP_U, RA_STD_U, LA_STD_U,
SYM_U, R_JERK_U, L_JERK_U, ASA_U, ASYM_IND_U,
TRA_U, T_AMP_U, STR_T_U, STR_CV_U,
STEP_REG_U, STEP_SYM_U, JERK_T_U
```

模块加载时会检查 artifact 的特征名、顺序、类别与 `prediction_mode`。任一项不匹配都会拒绝推理。特征中的空值保留为 `NaN`，交给模型内部 `SimpleImputer`，不再静默填 0。

## 输出合同

`ModuleResult` 包含：

- `quality`：每个片段的姿态检测率、有效深度率、缺失特征数；
- `metrics`：walk 片段数、步行距离、平均姿态/深度质量；
- `scores`：患者级 `np3gait_class`、文本标签和聚合方法；
- `result_data.segments`：每段 17 特征、分类结果与 0/1/2 概率；
- `output_artifacts`：原始特征 CSV、归一化后的 walk 分段 CSV，以及每个 walk 片段的骨架标注 WebM；
- `result_data.visualization.annotated_videos`：视频对应的 `segment_id`、输出文件索引和媒体类型。

骨架视频使用 VP8/WebM，避免依赖额外的 ffmpeg/H.264 环境。视频逐帧叠加片段、帧号、时间、姿态检出状态、有效深度率和有效深度关键点数。前端不直接读取绝对路径，而是通过评估输出接口按 `artifact_index` 加载。

多个 walk 片段使用多数票生成患者级结果；平票时使用相应类别的平均概率决定。

## 验证状态与限制

- 已通过真实 RealSense walk 片段的完整链路检查，17 个特征均能产生且没有补 0。
- 训练摘要中 PPMI holdout balanced accuracy 为 `0.78125`，但类别 2 的 holdout 仅 1 例。
- 现有 MediaPipe 外部数据只有 7 名患者且没有正常对照，原始三分类外部准确率为 `0.1071`。
- 因此输出当前是研究性模型结果，不是已完成独立临床验证的诊断结论。
