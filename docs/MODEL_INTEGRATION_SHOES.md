# Shoes 智能鞋接入与等价性验收

## 当前结构

- `integrations/shoes_reference/`：供仓库发布的 MATLAB 主程序、`src/` 和测试。传感器/步态算法保持原样；同步脚本仅把连接口令等配置替换为环境变量，并将测试中的设备 ID 替换为样例。`SOURCE_MANIFEST.json` 记录发布副本的 SHA-256。原始 `Shoes/` 不修改；历史数据、诊断记录、设备手册及第三方参考源码不入仓库。
- `integrations/shoes_bridge/`：System 与原 MATLAB 程序间的控制桥。定时器将 System 排队的命令写入原程序既有的 `gait_low_latency_session_command` appdata 键，不改变传感器解码、校准、步态或轨迹算法。
- `server/tools/build_shoes_deploy.py`：从哈希校验后的发布副本生成编译用源码，仅针对部署环境调整路径初始化与日志位置，再用 MATLAB Compiler 生成独立可执行文件。
- `server/app/services/shoes_runtime.py` 和 `server/app/api/routes/shoes.py`：启动、监控、控制、列出会话并绑定患者资料。
- `server/app/modules/providers/smart_insole.py`：读取原 MATLAB 输出的会话 CSV/TXT，保留原文件字节内容，将已有结果映射为 System 模块结果，不重新推断临床分数。
- `apps/desktop/src/views/ShoesView.vue`：实时控制、预览、会话归档和评估入口；`SmartInsoleResult.vue` 展示压力、轨迹、单步指标及原始文件。
- `data/shoes_archive/`：历史 `Shoes/log`、`Shoes/data` 和诊断文件的本地副本。数据目录不入 Git；本机可用 `sync_shoes_data.py --check` 对照原始资料。

源码同步脚本只处理发布所需文件，检查时逐个核对脱敏后的内容和哈希。被排除的原始文件仍留在本机 `Shoes/`，不会删除。

## 使用

1. 启动 System 前后端，打开侧栏“智能鞋采集”。开发模式可用 `MEDVISION_MATLAB_EXECUTABLE` 指定 MATLAB；部署模式用 `MEDVISION_SHOES_EXECUTABLE` 指定编译后的 `runShoesFromSystem.exe`，目标机器需安装相同发行版的 MATLAB Runtime。两种模式都需要鞋端 MQTT 网关。启动前在本机环境中设置 `MEDVISION_SHOES_MQTT_HOST`、`MEDVISION_SHOES_MQTT_USERNAME`、`MEDVISION_SHOES_MQTT_PASSWORD`；若未保存过网关选择，还需设置 `MEDVISION_SHOES_LEFT_GATEWAY_ID` 和 `MEDVISION_SHOES_RIGHT_GATEWAY_ID`。不要将真实口令提交到 Git。
2. 点击“启动鞋端程序”。在鞋端控制窗口选择左右网关、是否启用敲击对齐并确认连接。System 页面随后可发送空鞋校准、穿鞋站立校准、开始/结束记录命令；页面轮询会话日志显示阶段与压力预览。编译模式的会话直接写入 System 数据目录的 `shoes_archive/log/`。
3. 会话结束后选择患者和采集会话，点击“归档并运行鞋垫评估”。系统将会话 CSV/TXT 登记为 `smart-insole/insole_data`，复用现有评估、报告和输出文件机制。
4. 也可以在普通“采集评估”页将同一会话的 CSV/TXT 一起上传到“智能鞋垫分析”输入槽。

## 数据契约

原始文件角色：`raw_mqtt_low_latency`、`imu_decoded`、`pressure_decoded`、`gait_state`、`step_metrics`、`trajectory_state`、`calibration`、`time_alignment`、`manual_steps_template`、`session_manifest`。至少需要 `gait_state`、`step_metrics` 或 `trajectory_state` 中一类才能运行；缺失其他文件会在结果中提示。所有输入必须来自同一会话，不允许同一角色重复。

System 原样保存鞋端的 `step_length_m`、`step_frequency_spm` 和 `stride_duration_s`。当前 Shoes 源码的后续步长是同脚相邻落地点距离，频率是同脚落地周期的倒数，`stride_duration_s` 实际记录抬脚至落地时间。因此在重新定义和验证这些指标前，界面标记为“原程序标注”，`ModuleResult.scores` 保持为空。

## 同步与测试

```powershell
python server/tools/sync_shoes_source.py --check
python server/tools/sync_shoes_data.py --check
cd server
.venv\Scripts\python.exe -m pytest tests/test_smart_insole.py tests/test_shoes_api.py
cd ..
npm run typecheck
npm run build:web
```

在装有 MATLAB Compiler 的 Windows 构建机上，可执行 `python server/tools/build_shoes_deploy.py`。此前在当前机器完成过独立程序自检；发布副本改为读取环境变量后，需要重新编译并做现场复验。Tauri 安装包已包含 System Python 后端，但**不包含** Shoes 编译程序或 MATLAB Runtime。

如原 `Shoes/` 源码或数据更新，分别执行 `python server/tools/sync_shoes_source.py` 和 `python server/tools/sync_shoes_data.py` 再运行对照测试。MATLAB 参考测试在 `integrations/shoes_reference/` 运行 `runAllTests`，标定回放运行 `replayTrajectoryCalibration`；桥接测试在 `integrations/shoes_bridge/tests/` 运行 `runtests`。

## 验收边界

标定记录回放在 System 内完成：54 个配对步的 Shoes 原算法 MAE 为 5.7 cm、RMSE 为 7.6 cm。这是历史标定数据上的原程序结果，不代替硬件现场或临床验收。

已验证发布源码副本哈希、历史数据副本哈希、原 MATLAB 回归测试、桥接命令测试、真实历史会话的字节和指标对照、System 后端测试、前端类型检查与生产构建。连接配置脱敏后的发布副本仍需在 MATLAB 环境中重新运行回归和硬件现场验收，包括 MQTT 连接、双脚时钟对齐、两阶段校准、连续步行、停止归档及患者报告。若最终交付禁止 MATLAB Runtime，需将算法和协议逐项移植至 Python，并以原会话逐帧对照后才能宣称等价。
