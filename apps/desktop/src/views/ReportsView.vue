<script setup lang="ts">
import {
  Download,
  FileClock,
  FileText,
  Filter,
  Search,
} from "@lucide/vue";
import { computed, onMounted, ref } from "vue";
import { useRoute } from "vue-router";

import EmptyState from "@/components/EmptyState.vue";
import StatusPill from "@/components/StatusPill.vue";
import { api } from "@/services/api";
import { usePatientsStore } from "@/stores/patients";
import type { ReportSummary } from "@/types/domain";

const route = useRoute();
const patients = usePatientsStore();
const reports = ref<ReportSummary[]>([]);
const selectedPatientId = ref("");
const keyword = ref("");
const loading = ref(false);
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

async function loadReports() {
  loading.value = true;
  error.value = "";
  try {
    reports.value = await api.listReports(selectedPatientId.value || undefined);
  } catch (caught) {
    error.value =
      caught instanceof Error ? caught.message : "报告列表读取失败。";
  } finally {
    loading.value = false;
  }
}

onMounted(async () => {
  await patients.load();
  const patientFromQuery =
    typeof route.query.patient === "string" ? route.query.patient : "";
  selectedPatientId.value = patientFromQuery;
  await loadReports();
});
</script>

<template>
  <div class="view-stack">
    <section class="summary-strip report-summary">
      <div class="summary-copy">
        <span class="section-kicker">Clinical Reports</span>
        <h2>多模态评估报告中心</h2>
        <p>
          报告模板将聚合姿态、手部、腿部和鞋垫模块；未确认评分规则前不生成综合分。
        </p>
      </div>
      <div class="summary-stat">
        <span>可用报告</span>
        <strong>{{ reports.filter((item) => item.status === "ready").length }}</strong>
        <small>本地归档</small>
      </div>
    </section>

    <section class="content-card">
      <header class="card-header report-toolbar">
        <div>
          <h2>报告列表</h2>
          <p>筛选患者并检索已生成报告</p>
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

      <div v-if="error" class="inline-alert error">{{ error }}</div>
      <div v-if="loading" class="table-loading">
        <span class="spinner" />
        正在读取本地报告索引…
      </div>

      <div v-else-if="filteredReports.length" class="table-wrap">
        <table class="data-table report-table">
          <thead>
            <tr>
              <th>报告</th>
              <th>患者</th>
              <th>生成时间</th>
              <th>状态</th>
              <th>操作</th>
            </tr>
          </thead>
          <tbody>
            <tr v-for="report in filteredReports" :key="report.id">
              <td>
                <div class="report-name">
                  <span><FileText :size="19" /></span>
                  <div>
                    <strong>{{ report.title }}</strong>
                    <small>{{ report.id }}</small>
                  </div>
                </div>
              </td>
              <td>{{ report.patient_name }}</td>
              <td>{{ formatDate(report.created_at) }}</td>
              <td><StatusPill :status="report.status" /></td>
              <td>
                <button
                  class="button small secondary"
                  type="button"
                  :disabled="report.status !== 'ready' || !report.file_name"
                >
                  <Download :size="15" />
                  导出
                </button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <EmptyState
        v-else
        title="暂无可显示报告"
        description="完成真实模型接入和报告字段确认后，报告将在这里按患者归档。"
      >
        <template #icon>
          <FileClock :size="25" />
        </template>
        <RouterLink class="button secondary" to="/assessment">
          前往采集评估
        </RouterLink>
      </EmptyState>
    </section>
  </div>
</template>
