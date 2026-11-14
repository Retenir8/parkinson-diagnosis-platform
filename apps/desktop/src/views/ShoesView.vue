<script setup lang="ts">
import { Footprints, RefreshCw } from "@lucide/vue";
import { computed, onMounted, onUnmounted, ref } from "vue";

import AssessmentModuleResult from "@/components/AssessmentModuleResult.vue";
import ShoeLineChart from "@/components/ShoeLineChart.vue";
import { api } from "@/services/api";
import { usePatientsStore } from "@/stores/patients";
import type { Assessment, ShoesRuntimeStatus, ShoesSession } from "@/types/domain";

const patients = usePatientsStore();
const runtime = ref<ShoesRuntimeStatus | null>(null);
const sessions = ref<ShoesSession[]>([]);
const selectedStamp = ref("");
const assessment = ref<Assessment | null>(null);
const busy = ref(false);
const error = ref("");
const notice = ref("");
let pollTimer: number | undefined;

const moduleRun = computed(() => assessment.value?.module_runs?.["smart-insole"]);
const controls = [
  { command: "start_unloaded", label: "开始空鞋校准" },
  { command: "start_worn", label: "开始穿鞋站立校准" },
  { command: "start_recording", label: "开始正式记录" },
  { command: "stop_recording", label: "结束正式记录" },
] as const;

async function refresh() {
  try {
    const [current, available] = await Promise.all([
      api.shoesRuntime(), api.listShoesSessions(),
    ]);
    runtime.value = current;
    sessions.value = available;
    if (!selectedStamp.value && available.length) {
      selectedStamp.value = current.session_stamp ?? available[0].session_stamp;
    }
    if (assessment.value && ["queued", "running", "draft"].includes(assessment.value.status)) {
      assessment.value = await api.getAssessment(assessment.value.id);
    }
  } catch (reason) {
    error.value = reason instanceof Error ? reason.message : "无法读取 Shoes 状态";
  }
}

async function start() {
  busy.value = true;
  error.value = "";
  try {
    runtime.value = await api.startShoesRuntime();
    notice.value = "鞋端控制窗口已启动。请完成网关选择，然后在此页面进行校准和记录。";
    await refresh();
  } catch (reason) {
    error.value = reason instanceof Error ? reason.message : "启动失败";
  } finally {
    busy.value = false;
  }
}

async function command(value: string) {
  busy.value = true;
  error.value = "";
  try {
    await api.sendShoesCommand(value);
    notice.value = `命令已送入鞋端程序：${value}。实际执行状态以校准/采集日志为准。`;
    await refresh();
  } catch (reason) {
    error.value = reason instanceof Error ? reason.message : "控制命令失败";
  } finally {
    busy.value = false;
  }
}

async function importSelected() {
  if (!patients.selectedId || !selectedStamp.value) return;
  busy.value = true;
  error.value = "";
  try {
    const artifacts = await api.registerShoesSession(selectedStamp.value, patients.selectedId);
    const created = await api.createAssessment({
      patient_id: patients.selectedId,
      module_inputs: { "smart-insole": { insole_data: artifacts.map((item) => item.id) } },
    });
    assessment.value = await api.runAssessment(created.id);
    notice.value = `会话 ${selectedStamp.value} 已绑定当前患者，评估任务已启动。`;
  } catch (reason) {
    error.value = reason instanceof Error ? reason.message : "会话导入失败";
  } finally {
    busy.value = false;
  }
}

function matrix(side: string): (number | null)[][] | null {
  const row = runtime.value?.latest_gait_by_foot[side];
  if (!row) return null;
  const values = Array.from({ length: 48 }, (_, index) => {
    const value = Number(row[`p${String(index + 1).padStart(2, "0")}`]);
    return Number.isFinite(value) ? value : null;
  });
  return Array.from({ length: 12 }, (_, line) =>
    Array.from({ length: 4 }, (_, column) => values[column * 12 + line]),
  );
}

function points(rows: Record<string, string>[], xKey: string, yKey: string) {
  return rows.flatMap((row) => {
    if (!row[xKey] || !row[yKey]) return [];
    const x = Number(row[xKey]), y = Number(row[yKey]);
    return Number.isFinite(x) && Number.isFinite(y) ? [{ x, y }] : [];
  });
}

function livePressureSeries() {
  return ["left", "right"].map((side) => ({
    name: side === "left" ? "左脚" : "右脚",
    color: side === "left" ? "#c24a3d" : "#1d7195",
    points: points(runtime.value?.pressure_history_by_foot[side] ?? [], "t", "total"),
  }));
}

function liveStepSeries(field: string) {
  return ["left", "right"].map((side) => ({
    name: side === "left" ? "左脚" : "右脚",
    color: side === "left" ? "#c24a3d" : "#1d7195",
    points: points((runtime.value?.step_history ?? []).filter((item) => item.foot === side), "foot_step_count", field),
  }));
}

function liveImuSeries(side: string) {
  return ["accX_g", "accY_g", "accZ_g"].map((field, index) => ({
    name: ["X", "Y", "Z"][index],
    color: ["#c24a3d", "#1d7195", "#579552"][index],
    points: points(runtime.value?.imu_history_by_foot[side] ?? [], "t", field),
  }));
}

function liveHeightSeries() {
  return ["left", "right"].map((side) => ({
    name: side === "left" ? "左脚" : "右脚",
    color: side === "left" ? "#c24a3d" : "#1d7195",
    points: points(runtime.value?.trajectory_history ?? [], "t", `${side}_pos_z`),
  }));
}

onMounted(async () => {
  await patients.load();
  await refresh();
  pollTimer = window.setInterval(() => { void refresh(); }, 1500);
});
onUnmounted(() => { if (pollTimer !== undefined) window.clearInterval(pollTimer); });
</script>

<template>
  <div class="shoes-page">
    <section class="shoes-panel">
      <div class="shoes-heading"><Footprints :size="22" /><h2>智能鞋实时采集</h2></div>
      <p>运行与原 Shoes 相同的算法和控制流程。开始后先在鞋端控制窗口选择左右网关；时间对齐完成后再执行空鞋和站立校准。</p>
      <div class="shoes-actions">
        <button type="button" :disabled="busy || runtime?.running" @click="start">启动鞋端程序</button>
        <button type="button" :disabled="busy" @click="refresh"><RefreshCw :size="15" /> 刷新</button>
      </div>
      <p class="shoes-state">{{ runtime?.running ? '程序运行中' : '程序未运行' }} · 运行方式：{{ runtime?.engine === 'compiled-matlab' ? '独立程序' : 'MATLAB' }} · 阶段：{{ runtime?.phase ?? '未知' }} · 会话：{{ runtime?.session_stamp ?? '尚未创建' }}</p>
      <div class="shoes-actions">
        <button v-for="item in controls" :key="item.command" type="button"
          :disabled="busy || !runtime?.running" @click="command(item.command)">{{ item.label }}</button>
        <button type="button" :disabled="busy || !runtime?.running" @click="command('shutdown')">关闭鞋端程序</button>
      </div>
      <p v-if="runtime?.alignment" class="shoes-state">对齐：{{ runtime.alignment.status }} · 右脚补偿 {{ runtime.alignment.right_to_left_offset_sec }} s</p>
      <p v-if="notice" class="shoes-notice">{{ notice }}</p>
      <p v-if="error" class="shoes-error">{{ error }}</p>
    </section>

    <section class="shoes-panel">
      <h2>采集预览</h2>
      <div class="shoes-foot-grid">
        <article v-for="side in ['left', 'right']" :key="side">
          <h3>{{ side === 'left' ? '左脚' : '右脚' }}</h3>
          <p>负载：{{ runtime?.latest_gait_by_foot[side]?.total ?? '—' }} · 接触：{{ runtime?.latest_gait_by_foot[side]?.contact ?? '—' }} · 步数：{{ runtime?.latest_gait_by_foot[side]?.footStepCount ?? '—' }}</p>
          <div v-if="matrix(side)" class="shoes-matrix">
            <template v-for="(row, rowIndex) in matrix(side)" :key="rowIndex">
              <span v-for="(value, columnIndex) in row" :key="`${rowIndex}-${columnIndex}`"
                :style="{ backgroundColor: value === null ? '#e8edf1' : `hsl(${48 - 44 * Math.min(1, value / 1300)} 92% ${95 - 45 * Math.min(1, value / 1300)}%)` }"
                :title="value === null ? '无值' : String(value)" />
            </template>
          </div>
          <p v-else>等待压力数据</p>
        </article>
      </div>
      <p v-if="runtime?.latest_step" class="shoes-state">最近落地：{{ runtime.latest_step.foot }} · 原标注长度 {{ runtime.latest_step.step_length_m }} m · 原标注速度 {{ runtime.latest_step.step_speed_mps }} m/s</p>
      <div class="shoes-charts">
        <ShoeLineChart title="压力总量" unit="计数 / 相对时间 s" :series="livePressureSeries()" />
        <ShoeLineChart title="原程序标注长度" unit="m / 同脚周期序号" :series="liveStepSeries('step_length_m')" />
        <ShoeLineChart title="原程序标注频率" unit="每分钟同脚周期数" :series="liveStepSeries('step_frequency_spm')" />
        <ShoeLineChart title="原程序标注速度" unit="m/s / 同脚周期序号" :series="liveStepSeries('step_speed_mps')" />
        <ShoeLineChart title="左脚 IMU 加速度" unit="g / 相对时间 s" :series="liveImuSeries('left')" />
        <ShoeLineChart title="右脚 IMU 加速度" unit="g / 相对时间 s" :series="liveImuSeries('right')" />
        <ShoeLineChart title="足部垂直轨迹" unit="m / 相对时间 s" :series="liveHeightSeries()" />
      </div>
    </section>

    <section class="shoes-panel">
      <h2>会话归档与患者评估</h2>
      <div class="shoes-actions">
        <label>患者
          <select :value="patients.selectedId ?? ''" @change="patients.select(($event.target as HTMLSelectElement).value || null)">
            <option value="">请选择患者</option>
            <option v-for="patient in patients.items" :key="patient.id" :value="patient.id">{{ patient.name }}</option>
          </select>
        </label>
        <label>采集会话
          <select v-model="selectedStamp">
            <option v-for="session in sessions" :key="session.session_stamp" :value="session.session_stamp">
              {{ session.session_stamp }} · {{ session.file_count }} 文件{{ session.active ? '（正在采集）' : '' }}
            </option>
          </select>
        </label>
        <button type="button" :disabled="busy || !patients.selectedId || !selectedStamp || sessions.find(item => item.session_stamp === selectedStamp)?.active"
          @click="importSelected">归档并运行鞋垫评估</button>
      </div>
      <p>原始会话文件会完整保存到系统数据目录，并作为该患者的智能鞋垫输入；报告保留原 MATLAB 指标及文件下载入口。</p>
      <p v-if="assessment">评估 {{ assessment.id }} · 状态 {{ moduleRun?.status ?? assessment.status }}</p>
      <AssessmentModuleResult v-if="moduleRun?.result && assessment"
        :assessment-id="assessment.id" module-id="smart-insole" :result="moduleRun.result" />
    </section>
  </div>
</template>

<style scoped>
.shoes-page { display: grid; gap: 18px; }
.shoes-panel { background: #fff; border: 1px solid #dae3ea; border-radius: 16px; padding: 22px; }
.shoes-panel h2 { margin: 0 0 10px; font-size: 18px; }
.shoes-panel p { color: #526170; font-size: 13px; line-height: 1.6; }
.shoes-heading { display: flex; align-items: center; gap: 10px; color: #126485; }
.shoes-heading h2 { color: #1c3444; }
.shoes-actions { display: flex; align-items: end; flex-wrap: wrap; gap: 8px; margin: 14px 0; }
.shoes-actions button, .shoes-actions select { border: 1px solid #b9cbd6; border-radius: 8px; padding: 8px 12px; background: #f8fbfc; color: #154b66; cursor: pointer; }
.shoes-actions button:disabled { cursor: default; opacity: .45; }
.shoes-actions label { display: grid; gap: 5px; font-size: 12px; color: #536272; }
.shoes-state { font-variant-numeric: tabular-nums; }
.shoes-notice { color: #127152 !important; }
.shoes-error { color: #b63636 !important; }
.shoes-foot-grid { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 12px; }
.shoes-charts { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 12px; margin-top: 16px; }
.shoes-foot-grid article { background: #f7fafb; padding: 14px; border-radius: 12px; }
.shoes-foot-grid h3 { margin: 0; font-size: 14px; }
.shoes-matrix { display: grid; grid-template-columns: repeat(4, 25px); gap: 3px; }
.shoes-matrix span { width: 25px; height: 15px; border-radius: 2px; }
@media (max-width: 760px) { .shoes-foot-grid, .shoes-charts { grid-template-columns: 1fr; } }
</style>
