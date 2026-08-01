# 本地数据目录

当前版本不连接数据库。运行服务后，数据按以下结构写入：

```text
data/
├─ content_index.json        # 去重索引：相同内容文件 → 硬链接（≥ 1 MB 参与）
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
      │     ├─ module_runs/
      │     │  ├─ hand-motion.json
      │     │  └─ leg-motion.json
      │     └─ outputs/            # 各模块推理产物
      │        ├─ hand-motion/
      │        │  ├─ *_annotated.webm
      │        │  └─ ...
      │        └─ leg-motion/
      └─ reports/
         └─ <report_uuid>/
```

注意：

- `data/` 中的真实患者信息、视频和传感器数据已在 `.gitignore` 中排除。
- “视频分割”页面的项目独立保存在 `video_segments/`。原始文件和分段 CSV/JSON 位于同一项目目录；`preview.webm` 只用于浏览器查看，不替代原始文件。
- `segments.csv` 固定使用 `segment_id,label,task_type,start_s,end_s` 表头，时间以原始文件第一帧为 0 秒。`segments.json` 同时记录项目、时间基准和可选的 `walk_distance_m`（整体姿态）与 `crop_region: [x, y, w, h]`（手部分段模式裁剪区域，默认 `[400, 100, 480, 480]`）。
- 手部模块支持分段模式：`task_type` 取 `finger_opposition / hand_alternation / fist_clenching`，每段只运行对应动作的检测与评分。
- 相同内容的文件（≥ 1 MB）在登记时自动硬链接去重，索引保存在 `content_index.json`；删除资料/评估只移除索引引用，物理空间由文件系统在最后一个引用删除后回收。
- 推理输出（标注 WebM/CSV）位于评估目录 `outputs/<module_id>/`；删除评估输出只清理文件，评估记录与评分保留。
- 手工推理与 E2E 测试统一从 `data/samples/` 读取匿名样例；文件名必须与上图一致。设置 `MEDVISION_DATA_DIR` 后，样例目录也随之迁移到该目录下。
- 每个模型先独立写入 `module_runs/<module_id>.json`，所有模型线程结束后再一次性合并到 `assessment.json`，避免并发覆盖其他模型结果。
- 不要手工修改运行中的 JSON 文件；由本地 API 负责原子写入。
- 可通过 `MEDVISION_DATA_DIR` 环境变量把数据目录迁移到其他磁盘。
- 当前未实现加密、权限分级、备份和数据迁移，正式临床使用前必须补充。
