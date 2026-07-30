# 本地数据目录

当前版本不连接数据库。运行服务后，数据按以下结构写入：

```text
data/
└─ patients/
   └─ <patient_uuid>/
      ├─ patient.json
      ├─ artifacts/
      │  └─ <artifact_uuid>/
      │     ├─ artifact.json
      │     └─ <uploaded_file>
      ├─ assessments/
      │  └─ <assessment_uuid>/assessment.json
      └─ reports/
         └─ <report_uuid>/
```

注意：

- `data/` 中的真实患者信息、视频和传感器数据已在 `.gitignore` 中排除。
- 不要手工修改运行中的 JSON 文件；由本地 API 负责原子写入。
- 可通过 `MEDVISION_DATA_DIR` 环境变量把数据目录迁移到其他磁盘。
- 当前未实现加密、权限分级、备份和数据迁移，正式临床使用前必须补充。
