<script setup lang="ts">
import { computed } from "vue";

import ShoeLineChart from "@/components/ShoeLineChart.vue";
import { assessmentOutputUrl } from "@/services/api";
import type { ModuleResult } from "@/types/domain";

const props = defineProps<{
  assessmentId: string;
  result: ModuleResult;
}>();

interface Step {
  foot: string;
  foot_step_count: number | null;
  reported_step_length_m: number | null;
  reported_step_frequency_spm: number | null;
  reported_step_speed_mps: number | null;
  suspicious_step: boolean;
}

interface Point { t: number | null; x: number; y: number; z: number | null }
interface ImuPoint { t: number | null; x: number | null; y: number | null; z: number | null }
interface PressurePoint { t: number | null; total: number | null; cop_y: number | null; contact: number | null }
interface SourceFile { name: string; role: string; artifact_index: number }
interface ChartPoint { x: number; y: number }
interface ChartSeries { name: string; color: string; points: ChartPoint[] }

const steps = computed<Step[]>(() =>
  Array.isArray(props.result.result_data.steps)
    ? props.result.result_data.steps as Step[]
    : [],
);
const maps = computed<Record<string, (number | null)[][]>>(() => {
  const value = props.result.result_data.pressure_maps;
  return value && typeof value === "object" && !Array.isArray(value)
    ? value as Record<string, (number | null)[][]>
    : {};
});
const traces = computed<Record<string, Point[]>>(() => {
  const value = props.result.result_data.trajectory;
  return value && typeof value === "object" && !Array.isArray(value)
    ? value as Record<string, Point[]>
    : {};
});
const files = computed<SourceFile[]>(() =>
  Array.isArray(props.result.result_data.source_files)
    ? props.result.result_data.source_files as SourceFile[]
    : [],
);
const imu = computed<Record<string, ImuPoint[]>>(() => {
  const value = props.result.result_data.imu_timeseries;
  return value && typeof value === "object" && !Array.isArray(value)
    ? value as Record<string, ImuPoint[]> : {};
});
const pressures = computed<Record<string, PressurePoint[]>>(() => {
  const value = props.result.result_data.pressure_timeseries;
  return value && typeof value === "object" && !Array.isArray(value)
    ? value as Record<string, PressurePoint[]> : {};
});
const sideColors: Record<string, string> = { left: "#c24a3d", right: "#1d7195" };
function stepSeries(field: "reported_step_length_m" | "reported_step_frequency_spm" | "reported_step_speed_mps"): ChartSeries[] {
  return ["left", "right"].map((side) => ({
    name: side === "left" ? "左脚" : "右脚",
    color: sideColors[side],
    points: steps.value.filter((item) => item.foot === side).slice(-100).flatMap((item) =>
      typeof item.foot_step_count === "number" && typeof item[field] === "number"
        ? [{ x: item.foot_step_count, y: item[field] as number }]
        : [],
    ),
  }));
}
function pressureSeries(): ChartSeries[] {
  return ["left", "right"].map((side) => ({
    name: side === "left" ? "左脚" : "右脚",
    color: sideColors[side],
    points: (pressures.value[side] ?? []).flatMap((item) =>
      typeof item.t === "number" && typeof item.total === "number"
        ? [{ x: item.t, y: item.total }] : [],
    ),
  }));
}
function imuSeries(side: string): ChartSeries[] {
  return (["x", "y", "z"] as const).map((axis, index) => ({
    name: axis.toUpperCase(),
    color: ["#c24a3d", "#1d7195", "#579552"][index],
    points: (imu.value[side] ?? []).flatMap((item) =>
      typeof item.t === "number" && typeof item[axis] === "number"
        ? [{ x: item.t, y: item[axis] }] : [],
    ),
  }));
}
function heightSeries(): ChartSeries[] {
  return ["left", "right"].map((side) => ({
    name: side === "left" ? "左脚" : "右脚",
    color: sideColors[side],
    points: (traces.value[side] ?? []).flatMap((item) =>
      typeof item.t === "number" && typeof item.z === "number"
        ? [{ x: item.t, y: item.z }] : [],
    ),
  }));
}
const mapMaximum = computed(() => {
  const values = Object.values(maps.value).flat(2).filter((value): value is number => typeof value === "number");
  return Math.max(1, ...values);
});
function pressureColor(value: number | null) {
  if (value === null) return "#e7ebf1";
  const fraction = Math.max(0, Math.min(1, value / mapMaximum.value));
  return `hsl(${48 - 44 * fraction} 94% ${96 - 48 * fraction}%)`;
}
function tracePoints(side: string) {
  const points = traces.value[side] ?? [];
  if (points.length < 2) return "";
  const xs = points.map((point) => point.x);
  const ys = points.map((point) => point.y);
  const minX = Math.min(...xs);
  const minY = Math.min(...ys);
  const dx = Math.max(0.01, Math.max(...xs) - minX);
  const dy = Math.max(0.01, Math.max(...ys) - minY);
  return points.map((point) => `${10 + (point.x - minX) / dx * 280},${110 - (point.y - minY) / dy * 100}`).join(" ");
}
function metric(key: string) {
  const value = props.result.metrics[key];
  return typeof value === "number" && Number.isFinite(value) ? value.toFixed(3) : "—";
}
</script>

<template>
  <div class="shoe-result">
    <p class="shoe-note">{{ result.summary }}</p>
    <div class="shoe-overview">
      <article v-for="side in ['left', 'right']" :key="side" class="shoe-card">
        <h4>{{ side === 'left' ? '左脚' : '右脚' }}</h4>
        <p><strong>{{ result.metrics[`${side}_step_count`] ?? '—' }}</strong> 次落地记录</p>
        <p>原程序标注长度均值：{{ metric(`${side}_mean_reported_step_length_m`) }} m</p>
        <p>原程序标注速度均值：{{ metric(`${side}_mean_reported_step_speed_mps`) }} m/s</p>
      </article>
    </div>
    <p class="shoe-note">记录时长 {{ metric('recording_duration_s') }} s；异常步 {{ result.quality.suspicious_step_count ?? '—' }}。长度、频率、周期沿用 Shoes 原字段，未在系统内改算。</p>
    <div class="shoe-charts">
      <ShoeLineChart title="压力总量" unit="传感器计数 / 网关时间" :series="pressureSeries()" />
      <ShoeLineChart title="原程序标注长度" unit="m / 同脚周期序号" :series="stepSeries('reported_step_length_m')" />
      <ShoeLineChart title="原程序标注频率" unit="每分钟同脚周期数" :series="stepSeries('reported_step_frequency_spm')" />
      <ShoeLineChart title="原程序标注速度" unit="m/s / 同脚周期序号" :series="stepSeries('reported_step_speed_mps')" />
      <ShoeLineChart title="左脚 IMU 加速度" unit="g / 网关时间" :series="imuSeries('left')" />
      <ShoeLineChart title="右脚 IMU 加速度" unit="g / 网关时间" :series="imuSeries('right')" />
      <ShoeLineChart title="足部垂直轨迹" unit="m / 网关时间" :series="heightSeries()" />
    </div>
    <div class="shoe-visuals">
      <article v-for="side in ['left', 'right']" :key="`${side}-map`" class="shoe-card">
        <h4>{{ side === 'left' ? '左脚' : '右脚' }}最新压力分布（原始计数扣零位）</h4>
        <div v-if="maps[side]" class="shoe-pressure-grid">
          <template v-for="(row, rowIndex) in maps[side]" :key="rowIndex">
            <span v-for="(value, columnIndex) in row" :key="`${rowIndex}-${columnIndex}`"
              :style="{ backgroundColor: pressureColor(value) }" :title="value === null ? '无值' : String(value)" />
          </template>
        </div>
        <p v-else>没有压力阵列数据</p>
      </article>
      <article v-for="side in ['left', 'right']" :key="`${side}-trace`" class="shoe-card">
        <h4>{{ side === 'left' ? '左脚' : '右脚' }}水平轨迹</h4>
        <svg v-if="tracePoints(side)" viewBox="0 0 300 120" class="shoe-trace" role="img" :aria-label="`${side} foot trajectory`">
          <polyline :points="tracePoints(side)" fill="none" stroke="#165a77" stroke-width="2" stroke-linejoin="round" />
        </svg>
        <p v-else>没有轨迹数据</p>
      </article>
    </div>
    <section v-if="steps.length" class="shoe-card">
      <h4>最近单脚周期记录</h4>
      <div class="shoe-table-wrap">
        <table class="shoe-table">
          <thead><tr><th>脚</th><th>序号</th><th>原标注长度 m</th><th>原标注频率 /min</th><th>原标注速度 m/s</th><th>状态</th></tr></thead>
          <tbody>
            <tr v-for="(step, index) in steps.slice(-30)" :key="index">
              <td>{{ step.foot === 'left' ? '左' : '右' }}</td>
              <td>{{ step.foot_step_count ?? '—' }}</td>
              <td>{{ step.reported_step_length_m?.toFixed(3) ?? '—' }}</td>
              <td>{{ step.reported_step_frequency_spm?.toFixed(2) ?? '—' }}</td>
              <td>{{ step.reported_step_speed_mps?.toFixed(3) ?? '—' }}</td>
              <td>{{ step.suspicious_step ? '异常' : '正常' }}</td>
            </tr>
          </tbody>
        </table>
      </div>
    </section>
    <section v-if="files.length" class="shoe-card">
      <h4>原始会话文件</h4>
      <div class="shoe-files">
        <a v-for="file in files" :key="file.artifact_index"
          :href="assessmentOutputUrl(assessmentId, 'smart-insole', file.artifact_index)" target="_blank" rel="noopener noreferrer">
          {{ file.name }}
        </a>
      </div>
    </section>
    <ul v-if="result.warnings.length" class="shoe-warnings">
      <li v-for="warning in result.warnings" :key="warning">{{ warning }}</li>
    </ul>
  </div>
</template>

<style scoped>
.shoe-result { display: grid; gap: 16px; }
.shoe-note { margin: 0; color: #536272; font-size: 13px; line-height: 1.6; }
.shoe-overview, .shoe-visuals { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 12px; }
.shoe-charts { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 12px; }
.shoe-card { background: #fff; border: 1px solid #dbe3eb; border-radius: 12px; padding: 16px; min-width: 0; }
.shoe-card h4 { margin: 0 0 12px; font-size: 14px; }
.shoe-card p { margin: 5px 0; color: #536272; font-size: 13px; }
.shoe-card strong { font-size: 24px; color: #125575; }
.shoe-pressure-grid { display: grid; grid-template-columns: repeat(4, 25px); gap: 3px; }
.shoe-pressure-grid span { height: 15px; border-radius: 2px; }
.shoe-trace { width: 100%; max-width: 450px; height: 180px; background: #f5f8fa; border-radius: 6px; }
.shoe-table-wrap { overflow-x: auto; }
.shoe-table { border-collapse: collapse; width: 100%; font-size: 12px; text-align: left; }
.shoe-table td, .shoe-table th { border-bottom: 1px solid #e7edf2; padding: 8px; white-space: nowrap; }
.shoe-files { display: flex; flex-wrap: wrap; gap: 6px 14px; }
.shoe-files a { color: #126485; font-size: 12px; }
.shoe-warnings { margin: 0; color: #aa6118; font-size: 13px; }
@media (max-width: 780px) { .shoe-overview, .shoe-visuals, .shoe-charts { grid-template-columns: 1fr; } }
</style>
