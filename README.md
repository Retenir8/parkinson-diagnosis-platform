# 多模态运动功能评估系统

这是 Vue/npm 与 Tauri 共存的可运行框架。当前重点是患者本地档案、按模块组织输入、模型结果对应和医学软件工作台，不包含未经确认的模型推理、评分或可视化。

## 目录

```text
System/
├─ apps/desktop/       Vue 3 + TypeScript + Vite + Tauri
├─ server/             FastAPI 本地服务和模型适配接口
├─ data/               本地患者、资料、评估和报告
└─ docs/               架构、接口和未决事项
```

## 首次设置

### Python

项目固定使用 Python 3.12。不要使用当前系统默认的 Python 3.13 创建模型环境。

```powershell
cd D:\Desktop\医创赛\System\server
py -3.12 -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r requirements-dev.txt
```

### 前端

```powershell
cd D:\Desktop\医创赛\System
npm run setup:frontend
```

## 浏览器开发

```powershell
cd D:\Desktop\医创赛\System
npm run dev:web
```

- 前端：`http://127.0.0.1:5173`
- API：`http://127.0.0.1:8000/api/v1`
- API 文档：`http://127.0.0.1:8000/docs`

## Tauri 开发

需要先安装 Rust stable MSVC 和 Microsoft C++ Build Tools。当前开发机已有 Node/npm 和 WebView2，但 `tauri info` 确认尚未安装：

- Visual Studio Build Tools 的“使用 C++ 的桌面开发”和 Windows SDK；
- rustup、Rust stable MSVC 与 Cargo。

```powershell
cd D:\Desktop\医创赛\System
npm run dev:desktop
```

## 验证

```powershell
cd D:\Desktop\医创赛\System\server
.\.venv\Scripts\python.exe -m pytest

cd D:\Desktop\医创赛\System
npm run typecheck
npm run build:web
npm run test:server
```

## 界面预览

- [患者管理](docs/previews/patients.png)
- [采集评估](docs/previews/assessment.png)

## 接入模型前必读

- [架构说明](docs/ARCHITECTURE.md)
- [模型接口与未决问题](docs/INTERFACES.md)
- [模型负责人信息模板](docs/MODEL_INTEGRATION_TEMPLATE.md)

当前四个模块都不会伪造推理：

- 整体姿态：检测到现有文件，但应用服务适配待完成；
- 手部：等待同事模型和协议；
- 腿部：等待同事模型和协议；
- 智能鞋垫：等待硬件数据协议和字段。

采集评估页的可视化接口当前关闭。资料必须先绑定到明确的模型输入槽，模型结果也按模块独立展示；待团队完成各模型接入并稳定输入输出后，再设计对应可视化。
