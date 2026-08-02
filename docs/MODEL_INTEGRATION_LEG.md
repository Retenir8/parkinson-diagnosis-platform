# 腿部运动分析 — 模型接入信息

## 基本信息

- 模块名称：腿部运动分析 (leg-motion)
- module_id：`leg-motion`
- 负责人：待填写
- 模型版本：1.0.0
- 模型格式：纯 Python 代码（无独立模型文件），基于 MediaPipe Pose 关键点 + 规则阈值状态机
- Python/运行时版本：Python ≥ 3.10
- CPU/GPU/驱动要求：CPU 即可（MediaPipe Pose 支持 CPU 推理）
- 依赖锁文件位置：`server/requirements.txt`（当前代码使用 `mp.solutions`，固定 MediaPipe `0.10.21`）
- 模型文件及许可证：MediaPipe Pose (Apache 2.0)

## 输入协议

- 支持的数据类型：`realsense_bag`、`video`（常见格式如 .avi、.mp4、.mov、.mkv）
- 动作/采集任务：
  - 脚趾拍地（MDS-UPDRS 3.7）：患者坐姿，脚跟固定在地面，脚尖抬起再拍下，重复 10 次
  - 抬腿灵活性（MDS-UPDRS 3.8）：患者坐姿，整只脚从地面抬起再跺下，尽可能高、尽可能快，重复 10 次
  - **两个动作分别录制、分别输入**，各占一个独立的输入槽
- 视频视角、分辨率和帧率：
  - 视角：同整体姿态，中距离拍摄全身
  - 默认裁剪区域：无（全图处理）
  - 帧率：建议 30 fps
- 是否需要分段：不需要。每个视频仅包含一种动作。
- 数据字段、类型与单位：RealSense .bag 包含 RGB 和深度流；普通视频仅 RGB。
- 必填元数据：无
- 输入质量最低要求：
  - 患者下半身在画面内清晰可见（至少显示髋部到脚部）
  - 光照充足，无严重遮挡
  - MediaPipe Pose 检测置信度 ≥ 0.60

## 输出协议

- 指标名称、类型、单位：

| 指标 | 类型 | 说明 |
|---|---|---|
| `{task}_{side}_status` | str | `COMPLETE` 或 `INCOMPLETE` |
| `{task}_{side}_score` | int | MDS-UPDRS 0-4 分 |
| `{task}_{side}_pauses` | int | 检测到的停顿次数 |
| `{task}_{side}_speed_ratio` | float | 最后速度 / 初始速度 |
| `{task}_{side}_amplitude_decrease_level` | int | 幅度递减等级 0-3 |

task ∈ {`toe_tapping`, `leg_agility`}  
side ∈ {`left`, `right`}

- 分数名称、范围与临床含义：
  - 0：正常
  - 1：轻微（1-2 次停顿 / 轻微减速 / 末尾幅度下降）
  - 2：轻度（3-5 次停顿 / 轻度减速 / 中途幅度下降）
  - 3：中度（>5 次停顿或冻结 / 中度减速 / 起始幅度下降）
  - 4：严重（无法完成任务）
  - 综合分 = ceil( (停顿分 + 速度分 + 幅度分) / 3 )
- 关键阈值（`server/app/modules/providers/leg_motion.py`）：
  - 停顿：两次动作间隔 > `pause_threshold=1.5` s；持续 > `freeze_threshold=3.0` s 计为冻结（评分升级）
  - 速度：首末各 1/3 动作平均间隔比值，`[0.9, 0.8, 0.6, 0.4]` 分级
  - 幅度：以序列峰值 `max` 为基准，后一半 < 90% → 1 级，后一半 < 70% → 2 级，前一半 < 70% → 3 级
- 输出文件：每个任务生成 VP8/WebM 标注视频（骨架、计数、时间轴），路径只保存在 `output_artifacts`，前端通过受限输出接口读取。
- 可视化形式：前端表格展示各任务×各侧评分，标注视频单播放窗口 + 下拉切换任务。
- 警告条件：任一任务某侧检测到的动作次数 < 10 次时，状态为 `INCOMPLETE`，但仍给出评分

## 性能与测试

- 目标硬件：Intel Core i5 及以上，16 GB RAM
- 样例时长：每段 ~15-20 秒（10 次动作）
- 推理耗时：每段约 10-15 秒（含 MediaPipe Pose 检测 + 评分）
- 峰值内存/显存：~1.5 GB RAM
- 测试脚本：
  - `server/tests/test_inference.py`（推理链路）
  - `server/tests/test_scoring_metrics.py`（停顿/速度/幅度指标）
- 匿名测试样例位置：`data/samples/leg/toe_tapping.bag`、`data/samples/leg/leg_agility.bag`
- 失败/异常样例：
  - 腿部遮挡严重 → `INCOMPLETE` + 警告
  - 无深度数据 → 回退到 2D 信号
  - 缺少某个输入槽 → 对应任务 score=0 + 警告

## 融合约束

- 能否独立解释：是，每个任务×每侧独立评分
- 与其他模块的时间对齐要求：无
- 缺失输入时的行为：`INCOMPLETE` 状态 + score=0 + "No data: video input missing"
- 是否允许重算：是（纯 Python，无状态）
- 是否需要人工复核：建议，MDS-UPDRS 评分供临床参考
