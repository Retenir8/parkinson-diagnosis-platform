export const MODULE_NAMES: Record<string, string> = {
  "overall-posture": "整体姿态分析",
  "hand-motion": "手部运动分析",
  "leg-motion": "腿部运动分析",
  "smart-insole": "智能鞋垫分析",
};

export const TASK_NAMES: Record<string, string> = {
  finger_opposition: "手指对指（MDS-UPDRS 3.4）",
  hand_alternation: "手掌轮替（MDS-UPDRS 3.6）",
  fist_clenching: "握拳（MDS-UPDRS 3.5）",
  toe_tapping: "脚趾拍地（MDS-UPDRS 3.7）",
  leg_agility: "抬腿灵活性（MDS-UPDRS 3.8）",
};

export const GAIT_FEATURES: Record<
  string,
  { label: string; unit?: string; group: string }
> = {
  SP_U: { label: "步行速度", unit: "m/s", group: "步速与节律" },
  RA_AMP_U: { label: "右臂摆幅", unit: "°", group: "上肢摆动" },
  LA_AMP_U: { label: "左臂摆幅", unit: "°", group: "上肢摆动" },
  RA_STD_U: { label: "右臂摆幅标准差", unit: "°", group: "上肢摆动" },
  LA_STD_U: { label: "左臂摆幅标准差", unit: "°", group: "上肢摆动" },
  SYM_U: { label: "手臂摆动对称性", group: "对称性" },
  R_JERK_U: { label: "右臂运动平顺度", group: "运动平顺度" },
  L_JERK_U: { label: "左臂运动平顺度", group: "运动平顺度" },
  ASA_U: { label: "手臂摆动不对称评分", group: "对称性" },
  ASYM_IND_U: { label: "手臂摆幅不对称指数", unit: "%", group: "对称性" },
  TRA_U: { label: "躯干旋转不对称评分", group: "躯干控制" },
  T_AMP_U: { label: "躯干旋转幅度", unit: "°", group: "躯干控制" },
  STR_T_U: { label: "跨步周期", unit: "s", group: "步速与节律" },
  STR_CV_U: { label: "跨步周期变异系数", unit: "%", group: "步速与节律" },
  STEP_REG_U: { label: "步态规律性", group: "步速与节律" },
  STEP_SYM_U: { label: "步态对称性", group: "对称性" },
  JERK_T_U: { label: "躯干运动平顺度", group: "运动平顺度" },
};

const METRIC_NAMES: Record<string, string> = {
  walk_segment_count: "有效步行片段数",
  walk_distance_m: "步行距离",
  mean_pose_detection_rate: "平均姿态检出率",
  mean_valid_depth_rate: "平均有效深度率",
  pauses: "停顿次数",
  speed_ratio: "速度变化比",
  amplitude_decrease_level: "幅度递减等级",
  detected_actions: "检出动作数",
  required_actions: "要求动作数",
  score: "MDS-UPDRS 评分",
};

export function metricLabel(key: string) {
  if (GAIT_FEATURES[key]) return GAIT_FEATURES[key].label;
  if (METRIC_NAMES[key]) return METRIC_NAMES[key];
  return key
    .replace(/_/g, " ")
    .replace(/\bleft\b/gi, "左侧")
    .replace(/\bright\b/gi, "右侧");
}

export function formatMetric(value: unknown, digits = 3): string {
  if (value === null || value === undefined || value === "") return "—";
  if (typeof value === "number") {
    if (!Number.isFinite(value)) return "—";
    return Number.isInteger(value) ? String(value) : value.toFixed(digits);
  }
  return String(value);
}

export function formatRate(value: unknown): string {
  if (typeof value !== "number" || !Number.isFinite(value)) return "—";
  return `${(value * 100).toFixed(1)}%`;
}

export function severityFromClass(value: unknown) {
  const numeric = Number(value);
  return (
    {
      0: { code: "healthy", label: "帕金森健康" },
      1: { code: "mild", label: "帕金森轻度" },
      2: { code: "moderate_severe", label: "帕金森中重度" },
    } as Record<number, { code: string; label: string }>
  )[numeric] ?? { code: "unavailable", label: "暂无法分层" };
}
