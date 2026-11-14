# Windows 桌面版打包与数据边界

## 运行结构

桌面版直接复用 `apps/desktop/src` 的 Vue 页面，不维护第二套界面。Tauri
在发布版启动随安装包携带的 `medvision-server` Python sidecar；浏览器开发版
仍可独立使用 Vite + FastAPI。

- 后端仅监听 `127.0.0.1` 的随机端口，Tauri 将端口与会话令牌交给当前窗口。
- API 请求携带 `X-Medvision-Token`，视频等原生媒体请求使用同名会话查询参数。
- 后端在主窗口关闭时退出，不能作为对外网络服务使用。
- Vue 页面在后端健康检查成功后才挂载；启动失败时显示错误说明。

## 构建

在 Windows x64、Rust MSVC、C++ Build Tools、Node.js 与 Python 3.12 可用的环境中：

```powershell
cd System\server
.\.venv\Scripts\python.exe -m pip install -r requirements-desktop.txt
cd ..
npm run setup:frontend
npm run build:desktop
```

`build:desktop` 先用 PyInstaller 生成 `src-tauri/binaries/medvision-server-<target>.exe`，
随后运行 Vue 生产构建和 Tauri NSIS 打包。脚本自动将 NSIS 临时目录设在工作区
同盘路径，避免 Windows 跨盘移动报错。安装包在
`apps/desktop/src-tauri/target/release/bundle/nsis/`。开发桌面端使用
`npm run dev:desktop`；该模式继续运行本地虚拟环境的 FastAPI 热重载服务。

## 数据与模型

- 打包包含 `server/models/overall_posture/` 的 walk17 分类器、模型元数据和
  Pose Landmarker 资源，以及 Python 模型依赖。
- 打包只选取智能鞋桥接/参考实现的源码文件；不收集 `data/`、患者档案、
  `.bag`、CSV 历史记录或智能鞋校准采集数据。
- 发布版患者资料默认位于 Windows `%LOCALAPPDATA%/com.medinnovation.motion-assessment/data/`；
  `logs/backend.log` 用于本地启动故障排查。卸载桌面程序不会自动删除患者资料。
- 发布版可在“系统设置 → 数据与隐私”选择已有且可写的专用文件夹并保存；关闭后重新打开
  程序才会使用新目录。选择结果保存在默认应用目录下的 `desktop-storage.json`，
  因此切换患者数据目录不会丢失这项设置。也可在同一页面恢复默认目录。
- 切换目录**不会自动复制、移动或删除**旧患者资料。若所选目录在下次启动时不可用，
  程序临时使用默认目录，并在启动时与设置页显示警告；请重新接入磁盘或选择可用目录。
  切到空目录后旧记录暂不显示，切回原目录即可查看。
- 仓库现有 `System/data/` **不会自动搬入桌面数据目录**，避免在安装时静默复制临床资料。
- 浏览器版及桌面开发模式不使用上述桌面目录偏好，可通过 `MEDVISION_DATA_DIR`
  环境变量指定 Python 服务的数据目录。
- 智能鞋实时采集仍需要原系统约定的 MATLAB 或已编译 Shoes 可执行程序；
  该外部运行环境未包含在安装包中，MQTT 连接参数需通过本机环境变量配置。
  其余患者管理、视频分割、姿态/手腿评估和报告
  不依赖 MATLAB。

## 发布前核验

构建成功仅证明程序可打包。交付前仍需在目标 Windows 电脑验证：

1. 安装后打开，确认本地 API 就绪、页面与图片/视频可以显示。
2. 用非敏感测试数据创建患者、上传文件、生成报告，并确认数据目录正确。
3. 在配置好的 RealSense 环境里实际重放 `.bag`，验证三类视频模型和处理耗时。
4. 如需启用智能鞋，另行配置 MATLAB/编译程序与硬件连接。
