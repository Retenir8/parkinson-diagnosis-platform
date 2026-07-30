# 系统架构

## 目标结构

```text
Vue 3 / TypeScript / Vite
├─ 浏览器开发：Vite → FastAPI
└─ 桌面开发：Tauri WebView → FastAPI
                               │
                               ├─ 患者与资料文件仓库
                               ├─ 评估任务编排器（待实现）
                               ├─ 整体姿态模块适配器
                               ├─ 手部模块适配器
                               ├─ 腿部模块适配器
                               ├─ 智能鞋垫模块适配器
                               └─ 报告生成器（待确认）
```

## 当前已经实现

- Vue/Vite 浏览器模式和 Tauri 桌面壳共用同一套页面。
- 患者创建、检索、查看和本地 JSON 持久化。
- 浏览器文件流式上传；Tauri 模式可登记本地文件路径。
- 每份资料在上传时绑定 `module_id + input_slot`。
- 评估任务按模块保存输入映射和对应的独立输出记录。
- 四类模型的统一描述、输入槽、校验和结构化结果接口。
- 报告中心列表接口和空状态。

## 当前明确没有实现

- 没有执行整体姿态、手部、腿部或鞋垫模型推理。
- 没有综合评分或临床结论。
- 采集评估页没有视频预览、关键点叠加、图表或其他可视化接口。
- 没有实时摄像头/RealSense 采集。
- 没有报告 PDF/Word 生成。
- 没有数据库、云同步、用户账号、权限或加密。
- 没有把 Python 服务打包为 Tauri sidecar。

## 运行模式

### 浏览器开发

`npm run dev:web` 同时启动本地 FastAPI 和 Vite。浏览器选择的文件会复制到 `data`，并保存其所属模块和输入槽。

### Tauri 开发

`npm run dev:desktop` 同时启动本地 FastAPI 和 `tauri dev`。Tauri 文件选择器可直接登记大型 `.bag` 的绝对路径，避免复制。

### 最终桌面包

未来用 PyInstaller/Nuitka 把 Python 服务构建成 sidecar，由 Tauri 启动、健康检查和关闭。sidecar 文件名、端口令牌、资源路径和 RealSense Runtime 尚未确定，因此当前 `tauri.conf.json` 没有伪造 `externalBin` 配置。
