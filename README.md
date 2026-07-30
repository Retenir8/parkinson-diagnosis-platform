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
| 整体姿态 | `overall-posture` | ⚠️ 待接入 | 已检测到现有模型文件，服务适配待完成 |
| **手部运动** | `hand-motion` | ✅ 已接入 | 手指对指 / 手掌轮替 / 握拳，三任务共享 MediaPipe Hands |
| **腿部运动** | `leg-motion` | ✅ 已接入 | 脚趾拍地 / 抬腿灵活性，各用独立视频 + MediaPipe Pose |
| 智能鞋垫 | `smart-insole` | ⏳ 待提供 | 等待硬件协议和字段定义 |

手部和腿部模块已完整实现推理，详见 [手部接入文档](docs/MODEL_INTEGRATION_HAND.md) 和 [腿部接入文档](docs/MODEL_INTEGRATION_LEG.md)。

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
2. **采集评估**：
   - 选择患者 → 拖入视频文件到对应模块的输入槽
   - 手部：一个槽，拖入包含三个动作的 .bag 文件
   - 腿部：两个槽，分别拖入脚趾拍地和抬腿的 .bag 文件
3. **创建评估任务** → 点击「执行推理」
4. **查看结果**：右侧面板以表格展示各任务×各侧的 MDS-UPDRS 评分

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

## 接入模型

- [架构说明](docs/ARCHITECTURE.md)
- [模型接口与未决问题](docs/INTERFACES.md)
- [手部模型接入信息](docs/MODEL_INTEGRATION_HAND.md)
- [腿部模型接入信息](docs/MODEL_INTEGRATION_LEG.md)
- [模型接入模板](docs/MODEL_INTEGRATION_TEMPLATE.md)
