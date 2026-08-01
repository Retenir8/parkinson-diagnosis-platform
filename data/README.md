# 本地数据目录

当前版本不连接数据库。运行服务后，数据按以下结构写入：

```text
data/
├─ samples/
│  ├─ overall/
│  │  ├─ walk.bag
│  │  └─ segments.json
│  ├─ hand/
│  │  └─ hand_motion.bag
│  └─ leg/
│     ├─ toe_tapping.bag
│     └─ leg_agility.bag
├─ video_segments/
│  └─ <时间_项目名_短ID>/
│     ├─ <原始视频或bag>
│     ├─ preview.webm
│     ├─ segments.csv
│     ├─ segments.json
│     └─ project.json
└─ patients/
   └─ <patient_uuid>/
      ├─ patient.json
      ├─ artifacts/
      │  └─ <artifact_uuid>/
      │     ├─ artifact.json
      │     └─ <uploaded_file>
      ├─ assessments/
      │  └─ <assessment_uuid>/
      │     ├─ assessment.json
      │     └─ module_runs/
      │        ├─ hand-motion.json
      │        └─ leg-motion.json
      └─ reports/
         └─ <report_uuid>/
```

注意：

- `data/` 中的真实患者信息、视频和传感器数据已在 `.gitignore` 中排除。
- “视频分割”页面的项目独立保存在 `video_segments/`。原始文件和分段 CSV/JSON 位于同一项目目录；`preview.webm` 只用于浏览器查看，不替代原始文件。
- `segments.csv` 固定使用 `segment_id,label,task_type,start_s,end_s` 表头，时间以原始文件第一帧为 0 秒。`segments.json` 同时记录项目、时间基准和可选的 `walk_distance_m`，便于整体姿态接口直接读取。
- 手工推理与 E2E 测试统一从 `data/samples/` 读取匿名样例；文件名必须与上图一致。设置 `MEDVISION_DATA_DIR` 后，样例目录也随之迁移到该目录下。
- 每个模型先独立写入 `module_runs/<module_id>.json`，所有模型线程结束后再一次性合并到 `assessment.json`，避免并发覆盖其他模型结果。
- 不要手工修改运行中的 JSON 文件；由本地 API 负责原子写入。
- 可通过 `MEDVISION_DATA_DIR` 环境变量把数据目录迁移到其他磁盘。
- 当前未实现加密、权限分级、备份和数据迁移，正式临床使用前必须补充。
