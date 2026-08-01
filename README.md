# 多模态运动功能评估系统

Vue 3 / TypeScript / Vite 前端 + FastAPI 后端 + Tauri 桌面壳。
对帕金森患者的 MDS-UPDRS 运动任务进行视频分析评估。

## 目录

```text
System/
├─ apps/desktop/       Vue 3 + TypeScript + Vite + Tauri
├─ server/             FastAPI 本地服务和模型适配接口
├─ data/               本地患者、资料、评估和报告
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

当前实现固定使用 MediaPipe `0.10.21` 的 Legacy Solutions API；请按仓库依赖文件安装，不要单独升级 MediaPipe。RealSense 运行环境和 `pyrealsense2` 仍作为部署前置条件。

## 首次设置

### Python（二选一）

**方式 A：使用虚拟环境（推荐）**
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

### 前端

```powershell
cd System
npm run setup:frontend
```

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
2. **视频分割（需要整体姿态时间段时）**：
   - 导入普通视频或 RealSense `.bag`
   - 在播放器中把当前时间设为片段开始/结束
   - 选择 `walk / turn / stand / other`，确认 `label`
   - 保存后在同一目录获得原始文件、`segments.csv` 和 `segments.json`
3. **采集评估**：
   - 选择患者 → 拖入视频文件到对应模块的输入槽
   - 整体姿态：分别提供 RealSense `.bag` 和分割页保存的 `segments.csv/json`
   - 手部：一个槽，拖入包含三个动作的 .bag 文件
   - 腿部：两个槽，分别拖入脚趾拍地和抬腿的 .bag 文件
4. 点击 **开始分析**：系统登记输入后自动启动各模块独立推理
5. **查看结果**：页面按已上传模块展开；整体姿态展示骨架视频、实时叠加指标、17项特征和分类概率，手部/腿部展示各任务×左右侧指标
6. **报告中心**：查看患者级结构化报告、各模块详细指标，以及来自整体姿态模型的研究性健康/轻度/中重度分层

## 验证

```powershell
cd System\server
python -m pytest tests/ -v

cd System
npm run typecheck
```

## 测试脚本

| 脚本 | 用途 |
|---|---|
| `server/tests/test_api.py` | API 端点单元测试 |
| `server/tests/test_e2e.py` | 端到端上传文件 + 创建评估（需要服务运行） |
| `server/tests/test_inference.py` | 直接调用推理模块（需要 .bag 文件，不依赖服务） |

推理/E2E 样例统一放在 `data/samples/`，具体目录和文件名见 [本地数据目录说明](data/README.md)。样例数据不会提交到 Git。

## 接入模型

- [架构说明](docs/ARCHITECTURE.md)
- [模型接口与未决问题](docs/INTERFACES.md)
- [整体姿态模型接入信息](docs/MODEL_INTEGRATION_OVERALL.md)
- [手部模型接入信息](docs/MODEL_INTEGRATION_HAND.md)
- [腿部模型接入信息](docs/MODEL_INTEGRATION_LEG.md)
- [模型接入模板](docs/MODEL_INTEGRATION_TEMPLATE.md)
