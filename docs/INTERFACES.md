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
| 整体姿态 | `overall-posture` | `analysis_source` | video / realsense_bag / tabular |
| 手部 | `hand-motion` | `hand_video` | video |
| 腿部 | `leg-motion` | `leg_video` | video |
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

评估中的 `module_runs[module_id].inputs[input_slot]` 只引用该模块对应输入槽的资料，并保存该模块的 `ModuleResult`。采集评估页当前只展示这些真实返回字段，不读取或生成任何可视化配置。详细可视化协议将在模型输入输出稳定后另行设计并版本化。

推理编排器获得模型返回值后，调用：

```python
AssessmentRepository.store_module_result(
    assessment_id="<assessment_uuid>",
    module_id="hand-motion",
    result=module_result,
)
```

仓库会再次校验 `ModuleResult.module_id` 与目标模块一致，再把结果写入对应 `module_runs`；不会写入其他模块。

## 各模块待确认事项

### 整体姿态

已检测到现有 `np3gait_best_classifier.pkl` 和 RealSense/视频分析脚本，但应用适配仍需确认：

1. 首版使用 `.bag`、普通视频、已提取 CSV，还是全部支持；
2. 动作分段来自人工时间轴、外部 CSV 还是自动识别；
3. `SP_U` 所需步行距离由谁输入；
4. 单目视频和 RealSense 是否允许进入同一个分类器；
5. 临床阈值与原始三分类结果在报告中如何呈现；
6. 现有模型训练环境的精确依赖版本。

### 手部视频

等待负责人提供：

1. 模型格式、Python 版本和依赖文件；
2. 输入动作、相机视角、帧率、裁剪方式；
3. 是否需要左右手分别推理；
4. 输出字段、单位、分数含义和置信度；
5. CPU/GPU 要求和单段视频基准时间；
6. 可供自动测试的匿名样例和期望输出。

### 腿部视频

等待负责人提供：

1. 与整体姿态是否共享解码帧或关键点；
2. 输入动作、视角、片段边界；
3. 模型格式、运行依赖和硬件要求；
4. 输出指标、评分范围、质量门控；
5. 可视化需要关键点、角度曲线还是标注视频。

### 智能鞋垫

等待硬件和算法负责人提供：

1. 文件格式或实时通信协议；
2. 字段名、单位、时间戳、采样率和传感器布局；
3. 左右脚同步方式、设备校准和零点处理；
4. 丢包/缺失数据定义；
5. 压力图坐标映射；
6. 评分、指标及与视频时间轴对齐方式。

## 融合与报告待确认

以下内容没有实现：

- 四类模块输出是独立子项、MDS-UPDRS 项目还是同一目标的多模型证据；
- 综合评分公式、缺失模块处理、权重和阈值；
- 患者多次评估的可比性规则；
- 报告必需字段、签字/审核流程、模板和导出格式；
- 结果是研究辅助、临床辅助还是竞赛展示。

确认前，前端只展示各模块真实返回的指标与状态，不生成综合分。

## 基础设施待确认

- 正式数据目录、是否加密、备份和保留周期；
- 本地路径登记接口的启动令牌与访问控制；
- Python sidecar 的构建工具和目录结构；
- RealSense SDK/驱动是前置安装还是随安装器分发；
- 是否只支持 Windows x64；
- 实时的定义：实时采集、边采集边显示，还是采集完成后尽快分析。
