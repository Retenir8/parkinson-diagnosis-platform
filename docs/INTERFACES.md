# 模型与未决接口

本文件记录当前不能合理假设的部分。接入前必须由对应负责人确认，不在框架中写入模拟评分规则。

## 统一模型接口

每个模块实现 `InferenceModule`：

```python
class InferenceModule:
    def descriptor(self) -> ModelModuleDescriptor: ...
    def validate(self, request: InferenceRequest) -> list[str]: ...
    def infer(
        self,
        request: InferenceRequest,
        progress: ProgressCallback | None = None,
    ) -> ModuleResult: ...
```

位置：

- `server/app/modules/base.py`
- `server/app/schemas/modules.py`
- `server/app/modules/registry.py`

### 输入

`InferenceRequest` 只约定：

- `assessment_id`
- `patient_id`
- `module_id`
- 按输入槽组织的 `inputs: dict[input_slot, tuple[InputArtifact, ...]]`
- 模块自有 `parameters`

每个 `InputArtifact` 同时保存自己的 `module_id` 与 `input_slot`。编排器构造请求时必须保持这两个字段与 `InferenceRequest.module_id`、`inputs` 的键一致，不能依赖文件顺序推断用途。

`InputArtifact.kind` 当前允许：

- `video`
- `realsense_bag`
- `tabular`
- `insole_timeseries`
- `unknown`

没有统一假设视频分辨率、帧率、视角、动作段、传感器采样率或字段。

每个模块在 `ModelModuleDescriptor.input_slots` 中声明自己的输入槽。上传资料必须同时携带：

- `patient_id`
- `module_id`
- `input_slot`
- `kind`

当前槽位：

| 模块 | module_id | input_slot | 当前允许类型 |
|---|---|---|---|
| 整体姿态 | `overall-posture` | `walk_source` | realsense_bag |
| 整体姿态 | `overall-posture` | `segment_manifest` | tabular (CSV / JSON) |
| 手部 | `hand-motion` | `hand_video` | video |
| 腿部 | `leg-motion` | `toe_tapping_video` | video / realsense_bag |
| 腿部 | `leg-motion` | `leg_agility_video` | video / realsense_bag |
| 智能鞋垫 | `smart-insole` | `insole_data` | insole_timeseries / tabular |

这些槽位只定义路由关系，不定义动作、视角、文件内部结构或模型预处理。负责人接入时可以增加、删除或修改自己的输入槽。

评估创建请求使用嵌套映射：

```json
{
  "patient_id": "<patient_uuid>",
  "module_inputs": {
    "hand-motion": {
      "hand_video": ["<artifact_uuid-1>", "<artifact_uuid-2>"]
    },
    "smart-insole": {
      "insole_data": ["<artifact_uuid-3>"]
    }
  }
}
```

后端会拒绝患者不一致、模块不一致、输入槽不一致或类型不允许的资料，不会把一组输入自动广播给所有模型。

### 输出

`ModuleResult` 分开保存：

- `quality`：输入质量、追踪率、缺失率等质量信息；
- `metrics`：模块产生的原始或派生指标；
- `scores`：模块负责人确认的评分；
- `result_data`：不适合放入扁平指标表的模块自有结构化输出；
- `output_artifacts`：标注视频、CSV、图片等文件路径；
- `warnings`：适用范围、质量或分布偏移警告。

不要求所有模块共享相同分数，也不默认对模块分数相加或平均。

评估中的 `module_runs[module_id].inputs[input_slot]` 只引用该模块对应输入槽的资料，并保存该模块的 `ModuleResult`。采集评估页按模块展开真实返回值：整体姿态使用专用骨架视频与 17 特征面板，手部/腿部使用任务×左右侧指标面板，未知模块降级为通用指标卡，不推测未返回的字段。

模块输出文件通过受限只读接口访问，客户端不能传入任意本地路径：

| 方法 | 路径 | 用途 |
|---|---|---|
| `GET` | `/api/v1/assessments/{assessment_id}/modules/{module_id}/outputs/{artifact_index}` | 读取该模块 `output_artifacts` 中的一个已登记文件 |
| `DELETE` | `/api/v1/assessments/{assessment_id}/outputs` | 删除该评估的全部推理输出文件（保留评估记录与评分） |
| `DELETE` | `/api/v1/assessments/{assessment_id}` | 删除整个评估（含输出与报告） |
| `DELETE` | `/api/v1/patients/{patient_id}/artifacts/{artifact_id}` | 删除一份患者资料 |
| `DELETE` | `/api/v1/segmentation-projects/{project_id}` | 删除一个分割项目（含原始文件与分段清单） |

整体姿态的 `result_data.visualization.annotated_videos[]` 记录 `segment_id`、`artifact_index`、`media_type` 和视频内叠加的指标名。当前输出 VP8/WebM，视频画面包含骨架、帧号、时间、姿态检测状态和有效深度比例。

推理编排器获得模型返回值后，调用：

```python
AssessmentRepository.store_module_result(
    assessment_id="<assessment_uuid>",
    module_id="hand-motion",
    result=module_result,
    merge=False,
)
```

仓库会再次校验 `ModuleResult.module_id` 与目标模块一致，再把结果写入该评估目录下的 `module_runs/hand-motion.json`；不会写入其他模块。并行模块全部结束后，编排器只执行一次：

```python
AssessmentRepository.merge_module_runs(
    assessment_id="<assessment_uuid>",
    module_ids=["hand-motion", "leg-motion"],
)
```

该步骤读取各模块独立 JSON，并一次性更新 `assessment.json`。因此模型线程之间不共享“读取—修改—写回”过程，避免后完成的模型覆盖先完成的结果。

## 视频分割接口

视频分割是模型推理前的独立人工标注流程，不会自动判断动作类型，也不会执行模型评分。

主要接口：

| 方法 | 路径 | 用途 |
|---|---|---|
| `GET` | `/api/v1/segmentation-projects` | 列出或按名称、文件名、标签检索项目 |
| `POST` | `/api/v1/segmentation-projects/upload` | 上传 `.bag` 或普通视频并创建归档 |
| `GET` | `/api/v1/segmentation-projects/{id}` | 读取预览处理状态和已保存片段 |
| `GET` | `/api/v1/segmentation-projects/{id}/preview` | 读取浏览器使用的 WebM 预览 |
| `PUT` | `/api/v1/segmentation-projects/{id}/segments` | 校验并保存分段清单 |
| `DELETE` | `/api/v1/segmentation-projects/{id}` | 删除项目（含原始文件、预览和分段清单） |

每个片段固定包含：

```json
{
  "segment_id": "1",
  "label": "walk_1",
  "task_type": "walk",
  "start_s": 10.25,
  "end_s": 18.4
}
```

约束：

- `segment_id` 在同一项目内唯一；
- `end_s > start_s >= 0`，且不能超过视频时长；
- 当前界面拒绝时间重叠的片段；
- 时间基准是原始文件第一帧，与 `analyze_bag_segments.py` 一致；
- 页面提供整体姿态 `walk`、`turn`、`stand`、`other` 和手部 `finger_opposition`、`hand_alternation`、`fist_clenching` 以及自定义 `task_type` 选择，但只负责写入字段，不赋予或假设模型评分含义；
- `segments.json` 顶层可记录 `walk_distance_m`（供整体姿态 `SP_U` 计算）和 `crop_region: [x, y, w, h]`（供手部模块裁剪检测区域）；
- 保存时同时生成 `segments.csv` 和 `segments.json`，与原始文件、预览文件、`project.json` 放在 `data/video_segments/<项目目录>/`。

## 各模块接入状态与待确认事项

### 整体姿态

已接入 walk17 原始三分类模型：

1. `walk_source` 当前仅接受 RealSense `.bag`；
2. `segment_manifest` 接受视频分割页保存的 CSV/JSON，只处理 `task_type=walk`；
3. 提取器和分类器必须精确匹配 17 个特征及其顺序，缺失值交给模型 imputer，不补 0；
4. 默认为原始 `0/1/2` 输出，不使用先前的临床 1/2 阈值；
5. `walk_distance_m` 可由 JSON 顶层或模块参数提供；缺省时按现有协议使用 10.0 m 并输出警告；
6. 多个 walk 片段按多数票得到患者级结果，平票时用平均概率决定。
7. 每个 walk 片段生成浏览器/Tauri 可播放的骨架 WebM；路径仅保存在 `output_artifacts`，前端通过受限输出接口读取。

### 手部视频

已接入（`hand-motion`），见 [MODEL_INTEGRATION_HAND.md](MODEL_INTEGRATION_HAND.md)：

1. 纯规则状态机（无独立模型文件），基于 MediaPipe Hands 关键点；
2. 输入 `hand_video`（realsense_bag / video），默认裁剪区域 `(400, 100, 480, 480)`；
3. 支持可选分段模式：`segment_manifest` 槽传入带 `task_type` 的 `segments.json`（顶层 `crop_region` 可覆盖默认裁剪），每段只运行对应动作的检测与评分；
4. 输出三任务×左右侧 MDS-UPDRS 0-4 评分，`result_data` 为 `{segments: [...]}`（分段模式）或 `{tasks: {...}}`（不分段）；
5. 每段生成 VP8/WebM 标注视频（骨架 + 计数 + 时间轴），通过 `output_artifacts` 受限接口访问。

### 腿部视频

已接入（`leg-motion`），见 [MODEL_INTEGRATION_LEG.md](MODEL_INTEGRATION_LEG.md)：

1. 纯规则状态机，基于 MediaPipe Pose 关键点；
2. 两个独立输入槽 `toe_tapping_video` / `leg_agility_video`，各对应一个任务；
3. 输出两任务×左右侧 MDS-UPDRS 0-4 评分；
4. 每个任务生成 VP8/WebM 标注视频，通过 `output_artifacts` 受限接口访问。

### 智能鞋垫

等待硬件和算法负责人提供：

1. 文件格式或实时通信协议；
2. 字段名、单位、时间戳、采样率和传感器布局；
3. 左右脚同步方式、设备校准和零点处理；
4. 丢包/缺失数据定义；
5. 压力图坐标映射；
6. 评分、指标及与视频时间轴对齐方式。

## 报告接口与分层边界

| 方法 | 路径 | 用途 |
|---|---|---|
| `GET` | `/api/v1/reports` | 从已有评估结果生成报告索引，可按患者筛选 |
| `GET` | `/api/v1/reports/{assessment_id}` | 读取患者信息、分层结果和所有模块详细指标 |

当前报告中的“帕金森健康 / 轻度 / 中重度”只做以下可追溯映射：

```text
overall-posture.scores.np3gait_class
0 → 帕金森健康
1 → 帕金森轻度
2 → 帕金森中重度
```

置信度取该患者最终类别在各 walk 片段中的平均概率。该字段标记为 `research_only=true`，页面和报告都显示研究性声明。没有整体姿态结果时返回 `unavailable`，不会使用手部或腿部数据猜测分层。

## 融合待确认

以下内容没有实现：

- 四类模块输出是独立子项、MDS-UPDRS 项目还是同一目标的多模型证据；
- 综合评分公式、缺失模块处理、权重和阈值；
- 患者多次评估的可比性规则；
- 报告签字/审核流程和正式 PDF/Word 模板；
- 结果是研究辅助、临床辅助还是竞赛展示。

确认前，前端只展示各模块真实返回的指标与状态，不生成跨模块综合分。浏览器打印可临时导出 PDF，但不等同于正式审核报告。

## 基础设施待确认

- 正式数据目录、是否加密、备份和保留周期；
- 本地路径登记接口的启动令牌与访问控制；
- Python sidecar 的构建工具和目录结构；
- RealSense SDK/驱动是前置安装还是随安装器分发；
- 是否只支持 Windows x64；
- 实时的定义：实时采集、边采集边显示，还是采集完成后尽快分析。
