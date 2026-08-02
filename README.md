# 多模态运动功能评估系统

Vue 3 / TypeScript / Vite 前端 + FastAPI 后端 + Tauri 桌面壳。
对帕金森患者的 MDS-UPDRS 运动任务进行视频分析评估。

## 目录

```text
System/
├─ apps/desktop/       Vue 3 + TypeScript + Vite + Tauri
├─ server/             FastAPI 本地服务和模型适配接口
│  └─ tests/           后端测试（API / E2E / 推理 / 评分指标 / 清理）
├─ data/               本地患者、资料、评估和报告（不入 Git）
└─ docs/               架构、接口和模型接入文档
```

## 模块状态

| 模块 | module_id | 状态 | 说明 |
|---|---|---|---|
| **整体姿态** | `overall-posture` | ✅ 已接入 | RealSense walk 片段 → 17 特征 → NP3GAIT 0/1/2 三分类 |
| **手部运动** | `hand-motion` | ✅ 已接入 | 手指对指 / 手掌轮替 / 握拳，三任务共享 MediaPipe Hands |
| **腿部运动** | `leg-motion` | ✅ 已接入 | 脚趾拍地 / 抬腿灵活性，各用独立视频 + MediaPipe Pose |
| 智能鞋垫 | `smart-insole` | ⏳ 待提供 | 等待硬件协议和字段定义 |

整姿态、手部和腿部模块已实现独立推理和结果 JSON。详见 [整体姿态接入文档](docs/MODEL_INTEGRATION_OVERALL.md)、[手部接入文档](docs/MODEL_INTEGRATION_HAND.md) 和 [腿部接入文档](docs/MODEL_INTEGRATION_LEG.md)。

主要能力：

- **手部/腿部可视化**：推理产物为 VP8/WebM 标注视频（骨架、计数、状态、时间轴），前端单窗口播放 + 下拉切换分段。
- **手部分段模式**：可上传 `segments.json`（含 `segment_id/label/task_type/start_s/end_s` 与可选顶层 `crop_region`），每段只运行对应动作的检测与评分。
- **MDS-UPDRS 评分**：停顿（1.5 s）/ 冻结（3.0 s）/ 速度衰减 / 幅度衰减 → 0-4 级，总评 = `ceil((停顿 + 速度 + 幅度) / 3)`。
- **存储去重与清理**：同内容文件硬链接去重（`content_index.json`）、资料/分割项目/评估/输出的 DELETE 接口。
- **页面状态保持**：采集评估页 KeepAlive 缓存，切换页面后推理进度、文件列表不丢失。

当前实现固定使用 MediaPipe `0.10.21` 的 Legacy Solutions API；请按仓库依赖文件安装，不要单独升级 MediaPipe。RealSense 运行环境和 `pyrealsense2` 仍作为部署前置条件。

## 首次设置

### Python（二选一）

**方式 A：使用虚拟环境（推荐，Python ≥ 3.10）**
```powershell
cd System\server
py -3.12 -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r requirements.txt
.\.venv\Scripts\python.exe -m pip install pyrealsense2
```

**方式 B：使用系统 Python**
```powershell
pip install -r server/requirements.txt
pip install pyrealsense2
```

> 注意：整体姿态 walk17 模型 artifact 使用 `scikit-learn==1.8.0` 生成（需要 Python ≥ 3.10）。在 Python 3.9 等旧环境（sklearn < 1.8.0）中，整体姿态契约测试会自动跳过，其余测试不受影响（见下方「验证」）。

### 前端

```powershell
cd System
npm run setup:frontend
```

### Tauri 桌面构建（Windows）

桌面开发与打包还需要 Rust（MSVC 工具链）、Microsoft C++ Build Tools
（勾选“使用 C++ 的桌面开发”）和 WebView2。安装方式以
[Tauri 2 Windows 前置要求](https://v2.tauri.app/zh-cn/start/prerequisites/)为准。

```powershell
# 先确认 Rust/Cargo 已进入 PATH
cargo --version

# 构建 NSIS 桌面安装包
cd System
npm run build:desktop
```

若提示 `failed to run cargo metadata: program not found`，说明当前终端尚未安装
Rust，或安装后尚未重启终端使 `cargo` 进入 `PATH`；这不是 Vue/Tauri 源码错误。

## 浏览器开发

**虚拟环境版本：**
```powershell
npm run dev:web
```

**系统 Python 版本：**
```powershell
npm run dev:web:system
```

- 前端：`http://127.0.0.1:5173`
- API：`http://127.0.0.1:8000/api/v1`
- API 文档：`http://127.0.0.1:8000/docs`

## 使用流程

1. **患者管理**：创建患者档案
2. **视频分割（需要分段信息时）**：
   - 导入普通视频或 RealSense `.bag`
   - 在播放器中把当前时间设为片段开始/结束
   - 整体姿态选择 `walk / turn / stand / other`；手部选择 `finger_opposition / hand_alternation / fist_clenching`，并可为该视频设置裁剪区域 `crop_region (x, y, w, h)`
   - 保存后在同一目录获得原始文件、`segments.csv` 和 `segments.json`
3. **采集评估**：
   - 选择患者 → 拖入视频文件到对应模块的输入槽
   - 整体姿态：分别提供 RealSense `.bag` 和分割页保存的 `segments.csv/json`
   - 手部：一个槽，拖入包含三个动作的 .bag 文件；如需分段模式，再拖入带 `task_type` 的 `segments.json`
   - 腿部：两个槽，分别拖入脚趾拍地和抬腿的 .bag 文件
4. 点击 **开始分析**：系统登记输入后自动启动各模块独立推理（页面切换后状态保留，推理完成后自动刷新）
5. **查看结果**：页面按已上传模块展开；整体姿态展示骨架视频、实时叠加指标、17 项特征和分类概率，手部/腿部展示各任务×左右侧指标与标注视频
6. **报告中心**：查看患者级结构化报告、各模块详细指标，以及来自整体姿态模型的研究性健康/轻度/中重度分层；删除报告即删除对应评估记录
7. **清理**：可删除患者资料、分割项目、评估输出（保留评估与评分）或整个评估；相同内容的资料会自动硬链接去重

## 验证

```powershell
# 后端测试
cd System
npm run test:server

# 前端类型检查
npm run typecheck

# Tauri 桌面打包（需先满足上面的 Windows 前置要求）
npm run build:desktop
```

> 在 Python 3.9 等旧环境（scikit-learn < 1.8.0）中，`test_overall_posture_walk17_inference_contract` 会自动跳过并注明原因（walk17 模型 artifact 需要 sklearn ≥ 1.8.0），其余测试不受影响。

测试数据统一放在 `data/samples/`，具体目录和文件名见 [本地数据目录说明](data/README.md)。样例数据不会提交到 Git。

## 测试脚本

| 脚本 | 用途 |
|---|---|
| `server/tests/test_api.py` | API 端点单元测试（患者、资料、评估、报告、分割） |
| `server/tests/test_e2e.py` | 端到端上传文件 + 创建评估（需要服务运行） |
| `server/tests/test_inference.py` | 直接调用推理模块（需要 .bag 文件，不依赖服务） |
| `server/tests/test_overall_posture.py` | 整体姿态 walk17 特征契约与推理链路 |
| `server/tests/test_scoring_metrics.py` | 停顿/速度/幅度评分指标 + 轮替防抖状态机 |
| `server/tests/test_module_interfaces.py` | 手腿视频格式、手部分段任务与裁剪参数边界 |
| `server/tests/test_cleanup.py` | 硬链接去重、DELETE 清理、本地引用预检 |

## 数据与存储

- 全部临床数据（患者、资料、评估、报告、分割项目、去重索引）位于 `data/`，已被 `.gitignore` 排除，详情见 [data/README.md](data/README.md)。
- 相同内容的文件（≥ 1 MB）自动硬链接去重，索引保存在 `data/content_index.json`。
- 推理启动前会预检所有输入资料是否在本地磁盘上仍可读取；缺失时拒绝启动并提示。

## 接入模型

- [架构说明](docs/ARCHITECTURE.md)
- [模型接口与未决问题](docs/INTERFACES.md)
- [整体姿态模型接入信息](docs/MODEL_INTEGRATION_OVERALL.md)
- [手部模型接入信息](docs/MODEL_INTEGRATION_HAND.md)
- [腿部模型接入信息](docs/MODEL_INTEGRATION_LEG.md)
- [模型接入模板](docs/MODEL_INTEGRATION_TEMPLATE.md)
