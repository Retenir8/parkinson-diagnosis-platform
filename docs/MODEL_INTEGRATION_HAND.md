# 手部运动分析 — 模型接入信息

## 基本信息

- 模块名称：手部运动分析 (hand-motion)
- module_id：`hand-motion`
- 负责人：待填写
- 模型版本：1.0.0
- 模型格式：纯 Python 代码（无独立模型文件），基于 MediaPipe Hands 关键点 + 规则阈值状态机
- Python/运行时版本：Python ≥ 3.10
- CPU/GPU/驱动要求：CPU 即可（MediaPipe Hands 支持 CPU 推理）
- 依赖锁文件位置：`server/requirements.txt`（当前代码使用 `mp.solutions`，固定 MediaPipe `0.10.21`）
- 模型文件及许可证：MediaPipe Hands (Apache 2.0)

## 输入协议

- 支持的数据类型：`realsense_bag`、`video`（常见格式如 .avi、.mp4、.mov、.mkv）
- 输入槽：
  - `hand_video`（必需）：单段视频包含三个手部动作——手指对指（MDS-UPDRS 3.4）、手掌轮替（3.5）、握拳（3.6）。患者面朝相机，双手在胸前依次完成各任务。
  - `segment_manifest`（可选）：`segments.csv` 或 `segments.json`，启用分段模式。
- 分段模式：
  - 清单格式固定为 `segment_id,label,task_type,start_s,end_s`，时间以原始文件第一帧为 0 秒，片段不允许重叠；
  - `task_type` ∈ {`finger_opposition`, `hand_alternation`, `fist_clenching`}，**每段只运行对应动作的检测与评分**，其他任务不产生警告；
  - `segments.json` 顶层可携带 `crop_region: [x, y, w, h]` 覆盖默认裁剪区域；CSV 无法携带，使用默认值；
  - 每个分段独立维护检测状态并生成独立标注视频。
- 视频视角、分辨率和帧率：
  - 视角：正面拍摄双手，相机放置在患者前方约 1m 处
  - 默认裁剪区域：(400, 100, 480, 480)（可配置，分段模式可用 `crop_region` 覆盖）
  - 帧率：建议 30 fps
- 数据字段、类型与单位：RealSense .bag 包含 RGB 和深度流；普通视频仅 RGB。
- 必填元数据：无
- 输入质量最低要求：
  - 双手在画面内清晰可见
  - 光照充足，无严重遮挡
  - MediaPipe 检测置信度 ≥ 0.60

## 输出协议

- 指标名称、类型、单位：

| 指标 | 类型 | 说明 |
|---|---|---|
| `{task}_{side}_status` | str | `COMPLETE` 或 `INCOMPLETE` |
| `{task}_{side}_score` | int | MDS-UPDRS 0-4 分 |
| `{task}_{side}_pauses` | int | 检测到的停顿次数 |
| `{task}_{side}_speed_ratio` | float | 最后速度 / 初始速度 |
| `{task}_{side}_amplitude_decrease_level` | int | 幅度递减等级 0-3 |

task ∈ {`finger_opposition`, `hand_alternation`, `fist_clenching`}  
side ∈ {`left`, `right`}

- 分数名称、范围与临床含义：
  - 0：正常
  - 1：轻微（1-2 次停顿 / 轻微减速 / 末尾幅度下降）
  - 2：轻度（3-5 次停顿 / 轻度减速 / 中途幅度下降）
  - 3：中度（>5 次停顿或冻结 / 中度减速 / 起始幅度下降）
  - 4：严重（无法完成任务）
  - 综合分 = ceil( (停顿分 + 速度分 + 幅度分) / 3 )
- 关键阈值（`server/app/modules/providers/hand_motion.py` 类常量，均有中文注释）：
  - 停顿：两次动作间隔 > `PAUSE_THRESHOLD=1.5` s；持续 > `FREEZE_THRESHOLD=3.0` s 计为冻结（评分升级）
  - 速度：首末各 1/3 动作平均间隔比值，`[0.9, 0.8, 0.6, 0.4]` 分级（轮替用 `[0.9, 0.65, 0.5, 0.3]`）
  - 幅度：以序列峰值 `max` 为基准，后一半 < 90% → 1 级，后一半 < 70% → 2 级，前一半 < 70% → 3 级
  - 抗误检：轮替方向需连续保持 `ALT_MIN_DIRECTION_TIME` 秒才确认；握拳 handedness 连续 3 帧稳定才切换标签
- 输出文件：
  - 每段（不分段时为整段）生成 VP8/WebM 标注视频：骨架（2px 线 + 2px 节点）、任务计数面板、ROI 裁剪区域绿框、时间轴；
  - 文件名 `<输入名>_<分段id>_hand_motion_annotated.webm`，路径只保存在 `output_artifacts`，前端通过受限输出接口读取。
- `result_data` 结构：
  - 不分段：`{"tasks": {"finger_opposition": {left/right: {...}}, ...}}`
  - 分段模式：`{"segments": [{"segment_id", "label", "task_type", "start_s", "end_s", "tasks": {...}}], "visualization": {"type": "annotated_pose_video", "annotated_videos": [{"segment_id", "label", "artifact_index", "media_type"}]}}`
- 可视化形式：前端每个任务卡片展示左右侧评分与计数，标注视频单播放窗口 + 右上角下拉切换分段。
- 警告条件：任一任务某侧检测到的动作次数 < 10 次时，状态为 `INCOMPLETE`，但仍给出评分（分段模式下只对分段对应任务发出警告）。

## 性能与测试

- 目标硬件：Intel Core i5 及以上，16 GB RAM
- 样例时长：~30 秒视频（10 次 × 3 个动作）
- 推理耗时：约 15-30 秒（含 MediaPipe 检测 + 三任务评分 + WebM 编码）
- 峰值内存/显存：~2 GB RAM
- 测试脚本：
  - `server/tests/test_inference.py`（推理链路）
  - `server/tests/test_scoring_metrics.py`（停顿/速度/幅度指标 + 轮替防抖状态机）
- 匿名测试样例位置：`data/samples/hand/hand_motion.bag`
- 失败/异常样例：
  - 手部遮挡严重 → `INCOMPLETE` + 警告
  - 无深度数据 → 回退到 2D 信号（对指和轮替纯 2D，握拳使用关节角度）
  - 画面中非手物体（脚/膝盖等）被误检 → 依靠信号防抖与 handedness 稳定性过滤

## 融合约束

- 能否独立解释：是，每个任务×每侧独立评分
- 与其他模块的时间对齐要求：无
- 缺失输入时的行为：`INCOMPLETE` 状态 + score=0 + 警告信息
- 是否允许重算：是（纯 Python，无状态）
- 是否需要人工复核：建议，MDS-UPDRS 评分供临床参考
