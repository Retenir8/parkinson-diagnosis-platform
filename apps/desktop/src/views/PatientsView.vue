<script setup lang="ts">
import {
  ArrowRight,
  CalendarDays,
  ClipboardList,
  FileText,
  Plus,
  Search,
  UserRound,
} from "@lucide/vue";
import { computed, onMounted, reactive, ref } from "vue";

import BaseModal from "@/components/BaseModal.vue";
import EmptyState from "@/components/EmptyState.vue";
import { usePatientsStore } from "@/stores/patients";
import type { PatientCreate, PatientGender } from "@/types/domain";

const patients = usePatientsStore();
const searchKeyword = ref("");
const createOpen = ref(false);
const saving = ref(false);
const createError = ref("");

const form = reactive<PatientCreate>({
  patient_code: "",
  name: "",
  gender: "unknown",
  birth_date: "",
  phone: "",
  diagnosis: "",
  notes: "",
});

const selected = computed(() => patients.selectedPatient);

function formatDate(value: string) {
  return new Intl.DateTimeFormat("zh-CN", {
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).format(new Date(value));
}

function genderLabel(value: PatientGender) {
  return (
    {
      male: "男",
      female: "女",
      other: "其他",
      unknown: "未填写",
    }[value] ?? "未填写"
  );
}

function resetForm() {
  Object.assign(form, {
    patient_code: "",
    name: "",
    gender: "unknown",
    birth_date: "",
    phone: "",
    diagnosis: "",
    notes: "",
  });
  createError.value = "";
}

async function submitPatient() {
  if (!form.patient_code.trim() || !form.name.trim()) {
    createError.value = "患者编号和姓名不能为空。";
    return;
  }

  saving.value = true;
  createError.value = "";
  try {
    await patients.create({
      ...form,
      patient_code: form.patient_code.trim(),
      name: form.name.trim(),
    });
    createOpen.value = false;
    resetForm();
  } catch (error) {
    createError.value =
      error instanceof Error ? error.message : "患者档案创建失败。";
  } finally {
    saving.value = false;
  }
}

async function runSearch() {
  await patients.load(searchKeyword.value.trim());
}

onMounted(() => patients.load());
</script>

<template>
  <div class="view-stack">
    <section class="summary-strip">
      <div class="summary-copy">
        <span class="section-kicker">Patient Registry</span>
        <h2>患者档案与连续评估记录</h2>
      </div>
      <div class="summary-stat">
        <span>本地患者</span>
        <strong>{{ patients.items.length }}</strong>
        <small>当前检索结果</small>
      </div>
      <button class="button primary" type="button" @click="createOpen = true">
        <Plus :size="18" />
        新建患者
      </button>
    </section>

    <section class="content-card patient-card">
      <header class="card-header">
        <div>
          <h2>患者列表</h2>
        </div>
        <form class="search-box" @submit.prevent="runSearch">
          <Search :size="18" />
          <input
            v-model="searchKeyword"
            type="search"
            placeholder="输入患者信息检索"
            aria-label="检索患者"
          />
          <button type="submit">检索</button>
        </form>
      </header>

      <div v-if="patients.error" class="inline-alert error">
        {{ patients.error }}
      </div>

      <div v-if="patients.loading" class="table-loading">
        <span class="spinner" />
        正在读取本地患者档案…
      </div>

      <div v-else-if="patients.items.length" class="patient-layout">
        <div class="table-wrap">
          <table class="data-table">
            <thead>
              <tr>
                <th>患者</th>
                <th>患者编号</th>
                <th>性别</th>
                <th>临床信息</th>
                <th>最近更新</th>
                <th aria-label="操作" />
              </tr>
            </thead>
            <tbody>
              <tr
                v-for="patient in patients.items"
                :key="patient.id"
                :class="{ active: patients.selectedId === patient.id }"
                @click="patients.select(patient.id)"
              >
                <td>
                  <div class="patient-cell">
                    <span class="avatar">{{ patient.name.slice(0, 1) }}</span>
                    <span>
                      <strong>{{ patient.name }}</strong>
                      <small>{{ patient.phone || "未填写联系电话" }}</small>
                    </span>
                  </div>
                </td>
                <td>
                  <span class="mono-label">{{ patient.patient_code }}</span>
                </td>
                <td>{{ genderLabel(patient.gender) }}</td>
                <td>
                  <span
                    v-if="patient.diagnosis"
                    class="diagnosis-label"
                    >{{ patient.diagnosis }}</span
                  >
                  <span v-else class="muted">未填写</span>
                </td>
                <td>{{ formatDate(patient.updated_at) }}</td>
                <td>
                  <ArrowRight :size="17" class="row-arrow" />
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <aside v-if="selected" class="patient-detail">
          <div class="detail-identity">
            <span class="avatar large">{{ selected.name.slice(0, 1) }}</span>
            <div>
              <span class="section-kicker">当前患者</span>
              <h3>{{ selected.name }}</h3>
              <p>{{ selected.patient_code }}</p>
            </div>
          </div>

          <dl class="detail-list">
            <div>
              <dt>出生日期</dt>
              <dd>{{ selected.birth_date || "未填写" }}</dd>
            </div>
            <div>
              <dt>性别</dt>
              <dd>{{ genderLabel(selected.gender) }}</dd>
            </div>
            <div>
              <dt>临床信息</dt>
              <dd>{{ selected.diagnosis || "未填写" }}</dd>
            </div>
            <div>
              <dt>备注</dt>
              <dd>{{ selected.notes || "暂无备注" }}</dd>
            </div>
          </dl>

          <div class="detail-actions">
            <RouterLink
              class="button primary full"
              :to="{ path: '/assessment', query: { patient: selected.id } }"
            >
              <ClipboardList :size="17" />
              进入采集评估
            </RouterLink>
            <RouterLink
              class="button secondary full"
              :to="{ path: '/reports', query: { patient: selected.id } }"
            >
              <FileText :size="17" />
              查看患者报告
            </RouterLink>
          </div>
        </aside>
      </div>

      <EmptyState
        v-else
        title="暂无患者档案"
        description="创建患者后即可开始评估。"
      >
        <template #icon>
          <UserRound :size="24" />
        </template>
        <button class="button secondary" type="button" @click="createOpen = true">
          <Plus :size="17" />
          创建患者
        </button>
      </EmptyState>
    </section>
  </div>

  <BaseModal
    :open="createOpen"
    title="新建患者档案"
    description="患者编号和姓名必填。"
    @close="createOpen = false"
  >
    <form id="patient-form" class="form-grid" @submit.prevent="submitPatient">
      <label class="field">
        <span>患者编号 <em>*</em></span>
        <input
          v-model="form.patient_code"
          autocomplete="off"
          placeholder="院内编号或研究编号"
        />
      </label>
      <label class="field">
        <span>姓名 <em>*</em></span>
        <input v-model="form.name" autocomplete="off" placeholder="患者姓名" />
      </label>
      <label class="field">
        <span>性别</span>
        <select v-model="form.gender">
          <option value="unknown">未填写</option>
          <option value="male">男</option>
          <option value="female">女</option>
          <option value="other">其他</option>
        </select>
      </label>
      <label class="field">
        <span>出生日期</span>
        <div class="input-with-icon">
          <CalendarDays :size="17" />
          <input v-model="form.birth_date" type="date" />
        </div>
      </label>
      <label class="field">
        <span>联系电话</span>
        <input v-model="form.phone" autocomplete="off" placeholder="选填" />
      </label>
      <label class="field">
        <span>临床信息</span>
        <input
          v-model="form.diagnosis"
          autocomplete="off"
          placeholder="诊断或研究分组，选填"
        />
      </label>
      <label class="field full-span">
        <span>备注</span>
        <textarea
          v-model="form.notes"
          rows="3"
          placeholder="仅记录评估所需信息"
        />
      </label>
      <p v-if="createError" class="form-error full-span">
        {{ createError }}
      </p>
    </form>

    <template #footer>
      <button class="button ghost" type="button" @click="createOpen = false">
        取消
      </button>
      <button
        class="button primary"
        type="submit"
        form="patient-form"
        :disabled="saving"
      >
        {{ saving ? "正在保存…" : "保存患者档案" }}
      </button>
    </template>
  </BaseModal>
</template>
