<script setup lang="ts">
import {
  CalendarDays,
  CircleAlert,
  FileClock,
  FileText,
  Filter,
  Gauge,
  Printer,
  Search,
  ShieldCheck,
  Trash2,
  UserRound,
} from "@lucide/vue";
import { computed, onMounted, ref } from "vue";
import { useRoute } from "vue-router";

import AssessmentModuleResult from "@/components/AssessmentModuleResult.vue";
import EmptyState from "@/components/EmptyState.vue";
import StatusPill from "@/components/StatusPill.vue";
import { api } from "@/services/api";
import { usePatientsStore } from "@/stores/patients";
import type { ReportDetail, ReportSummary } from "@/types/domain";

const route = useRoute();
const patients = usePatientsStore();
const reports = ref<ReportSummary[]>([]);
const selectedReport = ref<ReportDetail | null>(null);
const selectedPatientId = ref("");
const keyword = ref("");
const loading = ref(false);
const detailLoading = ref(false);
const error = ref("");

const filteredReports = computed(() => {
  const query = keyword.value.trim().toLowerCase();
  if (!query) return reports.value;
  return reports.value.filter((report) =>
    [report.title, report.patient_name, report.id].some((value) =>
      value.toLowerCase().includes(query),
    ),
  );
});

function formatDate(value: string) {
  return new Intl.DateTimeFormat("zh-CN", {
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
  }).format(new Date(value));
}

function formatConfidence(value?: number | null) {
  return typeof value === "number" ? `${(value * 100).toFixed(1)}%` : "—";
}

const probabilityLabels: Record<string, string> = {
  "0": "健康",
  "1": "轻度",
  "2": "中重度",
};

function printReport() {
  window.print();
}

async function openReport(reportId: string) {
  detailLoading.value = true;
  error.value = "";
  try {
    selectedReport.value = await api.getReport(reportId);
  } catch (caught) {
    error.value = caught instanceof Error ? caught.message : "报告详情读取失败。";
  } finally {
    detailLoading.value = false;
  }
}

async function loadReports() {
  loading.value = true;
  error.value = "";
  selectedReport.value = null;
  try {
    reports.value = await api.listReports(selectedPatientId.value || undefined);
    if (reports.value[0]) await openReport(reports.value[0].id);
  } catch (caught) {
    error.value = caught instanceof Error ? caught.message : "报告列表读取失败。";
  } finally {
    loading.value = false;
  }
}

const deletingReport = ref(false);
async function deleteReport(report: ReportSummary) {
  if (deletingReport.value) return;
  if (
    !window.confirm(
      `确认删除报告“${report.patient_name} · ${formatDate(report.created_at)}”？\n将同时删除对应评估记录与全部推理产物，此操作不可恢复。`,
    )
  ) {
    return;
  }
  deletingReport.value = true;
  error.value = "";
  try {
    await api.deleteAssessment(report.id);
    if (selectedReport.value?.id === report.id) {
      selectedReport.value = null;
    }
    reports.value = reports.value.filter((item) => item.id !== report.id);
  } catch (caught) {
    error.value = caught instanceof Error ? caught.message : "删除报告失败。";
  } finally {
    deletingReport.value = false;
  }
}

onMounted(async () => {
  await patients.load();
  selectedPatientId.value =
    typeof route.query.patient === "string" ? route.query.patient : "";
  await loadReports();
});
</script>

<template>
  <div class="view-stack report-center-page">
    <section class="summary-strip report-summary">
      <div class="summary-copy">
        <span class="section-kicker">Clinical Reports</span>
        <h2>多模态评估报告中心</h2>
      </div>
      <div class="severity-legend">
        <span class="severity-dot healthy" />健康
        <span class="severity-dot mild" />轻度
        <span class="severity-dot moderate_severe" />中重度
      </div>
      <div class="summary-stat">
        <span>可用报告</span>
        <strong>{{ reports.filter((item) => item.status === "ready").length }}</strong>
      </div>
    </section>

    <div v-if="error" class="inline-alert error">
      <CircleAlert :size="17" />{{ error }}
    </div>

    <section class="content-card report-browser">
      <header class="card-header report-toolbar">
        <div>
          <h2>报告档案</h2>
        </div>
        <div class="toolbar-actions">
          <label class="compact-select">
            <Filter :size="17" />
            <select v-model="selectedPatientId" @change="loadReports">
              <option value="">全部患者</option>
              <option
                v-for="patient in patients.items"
                :key="patient.id"
                :value="patient.id"
              >
                {{ patient.name }} · {{ patient.patient_code }}
              </option>
            </select>
          </label>
          <label class="search-box compact">
            <Search :size="17" />
            <input v-model="keyword" type="search" placeholder="检索报告" />
          </label>
        </div>
      </header>

      <div v-if="loading" class="table-loading">
        <span class="spinner" />正在读取本地评估报告…
      </div>

      <div v-else-if="filteredReports.length" class="report-browser-grid">
        <aside class="report-index-list">
          <button
            v-for="report in filteredReports"
            :key="report.id"
            type="button"
            class="report-index-item"
            :class="{ active: selectedReport?.id === report.id }"
            @click="openReport(report.id)"
          >
            <span class="report-index-icon"><FileText :size="18" /></span>
            <span class="report-index-copy">
              <strong>{{ report.patient_name }}</strong>
              <small>{{ formatDate(report.created_at) }}</small>
              <em>{{ report.completed_module_count }} 个模块已完成</em>
            </span>
            <span
              class="report-severity-mini"
              :class="`severity-${report.severity?.code ?? 'unavailable'}`"
            >
              {{ report.severity?.label ?? "暂无法分层" }}
            </span>
            <span
              class="report-index-delete"
              role="button"
              aria-label="删除报告"
              title="删除报告（含评估记录与推理产物）"
              @click.stop="deleteReport(report)"
            >
              <Trash2 :size="14" />
            </span>
          </button>
        </aside>

        <main class="report-detail-pane">
          <div v-if="detailLoading" class="table-loading">
            <span class="spinner" />正在生成结构化报告…
          </div>
          <template v-else-if="selectedReport">
            <header class="clinical-report-header">
              <div>
                <span class="section-kicker">Motor Function Assessment</span>
                <h1>多模态运动功能评估报告</h1>
                <p>报告编号 {{ selectedReport.id }}</p>
              </div>
              <button class="button secondary print-button" type="button" @click="printReport">
                <Printer :size="16" />打印 / 导出 PDF
              </button>
            </header>

            <section class="report-patient-strip">
              <div>
                <UserRound :size="18" />
                <span>患者<strong>{{ selectedReport.patient_name }}</strong></span>
              </div>
              <div>
                <ShieldCheck :size="18" />
                <span>档案编号<strong>{{ selectedReport.patient_code }}</strong></span>
              </div>
              <div>
                <CalendarDays :size="18" />
                <span>评估时间<strong>{{ formatDate(selectedReport.created_at) }}</strong></span>
              </div>
              <StatusPill :status="selectedReport.assessment_status" />
            </section>

            <section
              class="report-severity-banner"
              :class="`severity-${selectedReport.severity?.code ?? 'unavailable'}`"
            >
              <header class="report-probability-heading">
                <span><Gauge :size="18" /></span>
                <div><strong>模型诊断概率分布</strong><p>{{ selectedReport.severity?.basis }}</p></div>
              </header>
              <div class="probability-chart report-probability-chart" aria-label="0、1、2 诊断概率柱状图">
                <div class="chart-y-axis">
                  <span v-for="tick in [100, 75, 50, 25, 0]" :key="tick">{{ tick }}%</span>
                </div>
                <div class="chart-plot">
                  <i v-for="tick in [100, 75, 50, 25, 0]" :key="tick" :style="{ bottom: `${tick}%` }" />
                  <div v-for="classId in ['0', '1', '2']" :key="classId" class="chart-bar-group">
                    <div class="chart-bar-area">
                      <div class="chart-bar" :style="{ height: `${Math.max(0, Math.min(100, Number(selectedReport.severity?.probabilities?.[classId] ?? 0) * 100))}%` }">
                        <strong>{{ formatConfidence(selectedReport.severity?.probabilities?.[classId]) }}</strong>
                      </div>
                    </div>
                    <span><b>{{ classId }}</b>{{ probabilityLabels[classId] }}</span>
                  </div>
                </div>
              </div>
            </section>

            <section class="report-module-section">
              <header>
                <div>
                  <span class="section-kicker">Detailed Findings</span>
                  <h2>分模块详细指标</h2>
                </div>
                <span>{{ selectedReport.completed_module_count }} 个有效模块</span>
              </header>

              <article
                v-for="module in selectedReport.modules"
                :key="module.module_id"
                class="report-module-card"
              >
                <header>
                  <div>
                    <h3>{{ module.display_name }}</h3>
                    <p>{{ module.result?.summary ?? module.status_detail }}</p>
                  </div>
                  <StatusPill :status="module.status" />
                </header>
                <AssessmentModuleResult
                  v-if="module.result"
                  :assessment-id="selectedReport.assessment_id"
                  :module-id="module.module_id"
                  :result="module.result"
                />
                <div v-else class="module-analysis-pending">
                  <FileClock :size="20" />
                  <div><strong>本模块没有有效结果</strong><p>{{ module.status_detail }}</p></div>
                </div>
              </article>
            </section>

            <div class="report-disclaimer">
              <CircleAlert :size="17" />
              <div><strong>结果解释声明</strong><p>{{ selectedReport.disclaimer }}</p></div>
            </div>
          </template>
        </main>
      </div>

      <EmptyState
        v-else
        title="暂无可显示报告"
        description="完成分析后，报告会显示在这里。"
      >
        <template #icon><FileClock :size="25" /></template>
        <RouterLink class="button secondary" to="/assessment">前往采集评估</RouterLink>
      </EmptyState>
    </section>
  </div>
</template>
