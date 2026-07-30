<script setup lang="ts">
import {
  Braces,
  CheckCircle2,
  ChevronRight,
  CircleAlert,
  FileInput,
  FileOutput,
  FolderOpen,
  Link2,
  Play,
  RefreshCw,
  Trash2,
  Upload,
  UserRound,
} from "@lucide/vue";
import { computed, onMounted, ref } from "vue";
import { useRoute } from "vue-router";

import EmptyState from "@/components/EmptyState.vue";
import StatusPill from "@/components/StatusPill.vue";
import { api, uploadPatientArtifact } from "@/services/api";
import { usePatientsStore } from "@/stores/patients";
import type {
  Assessment,
  InputKind,
  InputSlotDescriptor,
  ModelModuleDescriptor,
} from "@/types/domain";

interface PendingSource {
  localId: string;
  moduleId: string;
  inputSlot: string;
  name: string;
  kind: InputKind;
  size?: number;
  file?: File;
  localPath?: string;
  progress: number;
  state: "pending" | "uploading" | "ready" | "error";
  artifactId?: string;
}

interface UploadTarget {
  moduleId: string;
  slot: InputSlotDescriptor;
}

const route = useRoute();
const patients = usePatientsStore();
const modules = ref<ModelModuleDescriptor[]>([]);
const sources = ref<PendingSource[]>([]);
const fileInput = ref<HTMLInputElement | null>(null);
const uploadTarget = ref<UploadTarget | null>(null);
const running = ref(false);
const actionError = ref("");
const assessment = ref<Assessment | null>(null);
const refreshingResult = ref(false);
const isTauri = Boolean(window.__TAURI_INTERNALS__);

const selectedPatient = computed(() => patients.selectedPatient);
const selectedModuleCount = computed(
  () => new Set(sources.value.map((source) => source.moduleId)).size,
);
const canCreate = computed(
  () =>
    Boolean(selectedPatient.value) &&
    sources.value.length > 0 &&
    !running.value,
);

function sourceKind(name: string): InputKind {
  const extension = name.split(".").pop()?.toLowerCase();
  if (extension === "bag") return "realsense_bag";
  if (["mp4", "mov", "avi", "mkv", "webm"].includes(extension ?? "")) {
    return "video";
  }
  if (["csv", "xlsx", "xls", "json", "txt"].includes(extension ?? "")) {
    return "tabular";
  }
  return "unknown";
}

function readableSize(value?: number) {
  if (value === undefined) return "本地路径引用";
  if (value < 1024 * 1024) return `${(value / 1024).toFixed(1)} KB`;
  if (value < 1024 * 1024 * 1024) {
    return `${(value / 1024 / 1024).toFixed(1)} MB`;
  }
  return `${(value / 1024 / 1024 / 1024).toFixed(2)} GB`;
}

function acceptedExtensions(slot: InputSlotDescriptor) {
  const extensions = new Set<string>();
  if (slot.accepted_kinds.includes("video")) extensions.add("video/*");
  if (slot.accepted_kinds.includes("realsense_bag")) extensions.add(".bag");
  if (
    slot.accepted_kinds.includes("tabular") ||
    slot.accepted_kinds.includes("insole_timeseries")
  ) {
    [".csv", ".xlsx", ".xls", ".json", ".txt"].forEach((item) =>
      extensions.add(item),
    );
  }
  return Array.from(extensions).join(",");
}

function sourcesFor(moduleId: string, slotKey?: string) {
  return sources.value.filter(
    (source) =>
      source.moduleId === moduleId &&
      (slotKey === undefined || source.inputSlot === slotKey),
  );
}

function addFiles(
  fileList: FileList | File[],
  moduleId: string,
  slot: InputSlotDescriptor,
) {
  actionError.value = "";
  for (const file of Array.from(fileList)) {
    const kind = sourceKind(file.name);
    if (!slot.accepted_kinds.includes(kind)) {
      actionError.value = `${file.name} 的类型 ${kind} 不符合“${slot.label}”接口。`;
      continue;
    }
    if (!slot.multiple && sourcesFor(moduleId, slot.key).length > 0) {
      actionError.value = `“${slot.label}”当前只允许一个输入文件。`;
      continue;
    }
    sources.value.push({
      localId: crypto.randomUUID(),
      moduleId,
      inputSlot: slot.key,
      name: file.name,
      kind,
      size: file.size,
      file,
      progress: 0,
      state: "pending",
    });
  }
  assessment.value = null;
}

function openBrowserPicker(moduleId: string, slot: InputSlotDescriptor) {
  uploadTarget.value = { moduleId, slot };
  if (fileInput.value) {
    fileInput.value.accept = acceptedExtensions(slot);
    fileInput.value.multiple = slot.multiple;
    fileInput.value.click();
  }
}

function onFileInput(event: Event) {
  const target = event.target as HTMLInputElement;
  if (target.files && uploadTarget.value) {
    addFiles(
      target.files,
      uploadTarget.value.moduleId,
      uploadTarget.value.slot,
    );
  }
  target.value = "";
}

function onDrop(
  event: DragEvent,
  moduleId: string,
  slot: InputSlotDescriptor,
) {
  if (event.dataTransfer?.files) {
    addFiles(event.dataTransfer.files, moduleId, slot);
  }
}

async function chooseNativeFiles(
  moduleId: string,
  slot: InputSlotDescriptor,
) {
  if (!isTauri) return;
  const { open } = await import("@tauri-apps/plugin-dialog");
  const selected = await open({
    multiple: slot.multiple,
    directory: false,
    title: `选择${slot.label}`,
  });
  if (!selected) return;

  const paths = Array.isArray(selected) ? selected : [selected];
  actionError.value = "";
  for (const path of paths) {
    const name = path.split(/[\\/]/).pop() ?? path;
    const kind = sourceKind(name);
    if (!slot.accepted_kinds.includes(kind)) {
      actionError.value = `${name} 的类型 ${kind} 不符合“${slot.label}”接口。`;
      continue;
    }
    sources.value.push({
      localId: crypto.randomUUID(),
      moduleId,
      inputSlot: slot.key,
      name,
      kind,
      localPath: path,
      progress: 0,
      state: "pending",
    });
  }
  assessment.value = null;
}

function removeSource(localId: string) {
  sources.value = sources.value.filter(
    (source) => source.localId !== localId,
  );
  assessment.value = null;
}

function moduleName(moduleId: string) {
  return (
    modules.value.find((module) => module.id === moduleId)?.display_name ??
    moduleId
  );
}

function hasResultValues(value: Record<string, unknown>) {
  return Object.keys(value).length > 0;
}

async function createAssessment() {
  if (!canCreate.value || !selectedPatient.value) return;
  running.value = true;
  actionError.value = "";
  assessment.value = null;

  try {
    for (const source of sources.value) {
      if (source.artifactId) continue;
      source.state = "uploading";

      if (source.file) {
        const artifact = await uploadPatientArtifact(
          selectedPatient.value.id,
          source.file,
          source.kind,
          source.moduleId,
          source.inputSlot,
          (progress) => {
            source.progress = progress;
          },
        );
        source.artifactId = artifact.id;
      } else if (source.localPath) {
        const artifact = await api.registerLocalArtifact(
          selectedPatient.value.id,
          {
            path: source.localPath,
            kind: source.kind,
            module_id: source.moduleId,
            input_slot: source.inputSlot,
          },
        );
        source.artifactId = artifact.id;
      }
      source.progress = 100;
      source.state = "ready";
    }

    const moduleInputs: Record<string, Record<string, string[]>> = {};
    for (const source of sources.value) {
      if (!source.artifactId) continue;
      moduleInputs[source.moduleId] ??= {};
      moduleInputs[source.moduleId][source.inputSlot] ??= [];
      moduleInputs[source.moduleId][source.inputSlot].push(source.artifactId);
    }

    assessment.value = await api.createAssessment({
      patient_id: selectedPatient.value.id,
      module_inputs: moduleInputs,
    });
  } catch (error) {
    actionError.value =
      error instanceof Error ? error.message : "评估任务创建失败。";
    for (const source of sources.value) {
      if (source.state === "uploading") source.state = "error";
    }
  } finally {
    running.value = false;
  }
}

async function refreshResults() {
  if (!assessment.value) return;
  refreshingResult.value = true;
  actionError.value = "";
  try {
    assessment.value = await api.getAssessment(assessment.value.id);
  } catch (error) {
    actionError.value =
      error instanceof Error ? error.message : "模型输出刷新失败。";
  } finally {
    refreshingResult.value = false;
  }
}

onMounted(async () => {
  await patients.load();
  const patientFromQuery =
    typeof route.query.patient === "string" ? route.query.patient : null;
  if (
    patientFromQuery &&
    patients.items.some((patient) => patient.id === patientFromQuery)
  ) {
    patients.select(patientFromQuery);
  }

  try {
    modules.value = await api.listModules();
  } catch (error) {
    actionError.value =
      error instanceof Error ? error.message : "模型模块状态读取失败。";
  }
});
</script>

<template>
  <div class="assessment-page">
    <section class="workflow-bar">
      <div class="workflow-step active">
        <span>1</span>
        <div>
          <strong>选择患者</strong>
          <small>关联患者档案</small>
        </div>
      </div>
      <ChevronRight :size="18" />
      <div class="workflow-step" :class="{ active: sources.length }">
        <span>2</span>
        <div>
          <strong>模块输入</strong>
          <small>明确资料与模型对应</small>
        </div>
      </div>
      <ChevronRight :size="18" />
      <div class="workflow-step" :class="{ active: assessment }">
        <span>3</span>
        <div>
          <strong>模型输出</strong>
          <small>仅显示真实返回结果</small>
        </div>
      </div>
    </section>

    <div v-if="actionError" class="inline-alert error">
      <CircleAlert :size="18" />
      {{ actionError }}
    </div>

    <section class="content-card setup-card">
      <header class="card-header">
        <div>
          <span class="section-kicker">01 · Patient Context</span>
          <h2>本次评估对象</h2>
        </div>
      </header>
      <div class="patient-select-row">
        <div class="patient-select-icon"><UserRound :size="22" /></div>
        <label class="field grow">
          <span>患者</span>
          <select v-model="patients.selectedId">
            <option :value="null">请选择已建档患者</option>
            <option
              v-for="patient in patients.items"
              :key="patient.id"
              :value="patient.id"
            >
              {{ patient.name }} · {{ patient.patient_code }}
            </option>
          </select>
        </label>
        <RouterLink class="button secondary" to="/patients">
          管理患者
        </RouterLink>
      </div>
    </section>

    <div class="mapping-layout">
      <div class="module-input-column">
        <section class="content-card">
          <header class="card-header">
            <div>
              <span class="section-kicker">02 · Module Input Mapping</span>
              <h2>模型输入映射</h2>
              <p>
                每份资料在上传时固定绑定模块和输入槽，不会隐式传给其他模型
              </p>
            </div>
            <span class="count-badge">
              {{ selectedModuleCount }} 模块 · {{ sources.length }} 份资料
            </span>
          </header>

          <div class="module-input-list">
            <article
              v-for="module in modules"
              :key="module.id"
              class="module-input-card"
            >
              <header>
                <div>
                  <span class="module-sequence">{{
                    String(modules.indexOf(module) + 1).padStart(2, "0")
                  }}</span>
                  <div>
                    <h3>{{ module.display_name }}</h3>
                    <p>{{ module.description }}</p>
                  </div>
                </div>
                <StatusPill :status="module.status" />
              </header>

              <div
                v-for="slot in module.input_slots"
                :key="slot.key"
                class="input-slot"
              >
                <div class="input-slot-heading">
                  <div>
                    <strong>{{ slot.label }}</strong>
                    <span class="interface-key"
                      >{{ module.id }} / {{ slot.key }}</span
                    >
                  </div>
                  <span>{{ slot.required ? "必需" : "可选" }}</span>
                </div>
                <p>{{ slot.description }}</p>

                <div
                  class="module-dropzone"
                  role="button"
                  tabindex="0"
                  @click="openBrowserPicker(module.id, slot)"
                  @keydown.enter="openBrowserPicker(module.id, slot)"
                  @dragover.prevent
                  @drop.prevent="onDrop($event, module.id, slot)"
                >
                  <Upload :size="20" />
                  <div>
                    <strong>添加{{ slot.label }}</strong>
                    <span>
                      允许：
                      {{ slot.accepted_kinds.join("、") }}
                    </span>
                  </div>
                  <button
                    class="button small secondary"
                    type="button"
                    :disabled="!isTauri"
                    @click.stop="chooseNativeFiles(module.id, slot)"
                  >
                    <FolderOpen :size="15" />
                    本地路径
                  </button>
                </div>

                <div
                  v-if="sourcesFor(module.id, slot.key).length"
                  class="mapped-source-list"
                >
                  <div
                    v-for="source in sourcesFor(module.id, slot.key)"
                    :key="source.localId"
                    class="mapped-source"
                  >
                    <FileInput :size="17" />
                    <div>
                      <strong>{{ source.name }}</strong>
                      <span>
                        {{ source.kind }} · {{ readableSize(source.size) }}
                      </span>
                      <div
                        v-if="source.state === 'uploading'"
                        class="progress-track"
                      >
                        <span :style="{ width: `${source.progress}%` }" />
                      </div>
                    </div>
                    <span v-if="source.state === 'ready'" class="source-ready">
                      <CheckCircle2 :size="16" />
                      已映射
                    </span>
                    <button
                      v-else
                      class="icon-button"
                      type="button"
                      aria-label="移除资料"
                      @click="removeSource(source.localId)"
                    >
                      <Trash2 :size="16" />
                    </button>
                  </div>
                </div>
              </div>
            </article>
          </div>
        </section>

        <div class="assessment-submit-bar">
          <div>
            <Link2 :size="20" />
            <span>
              <strong>建立输入—模型固定映射</strong>
              <small>
                只有已添加资料的模块会进入本次评估，不产生可视化或模拟分数
              </small>
            </span>
          </div>
          <button
            class="button primary prominent"
            type="button"
            :disabled="!canCreate"
            @click="createAssessment"
          >
            <Play :size="17" fill="currentColor" />
            {{ running ? "正在登记输入…" : "创建评估任务" }}
          </button>
        </div>
      </div>

      <aside class="result-column">
        <section class="content-card result-hub">
          <header class="card-header">
            <div>
              <span class="section-kicker">03 · Model Outputs</span>
              <h2>模型输出结果</h2>
              <p>只读取模块真实返回值，前端可视化接口当前关闭</p>
            </div>
            <button
              v-if="assessment"
              class="button small secondary"
              type="button"
              :disabled="refreshingResult"
              @click="refreshResults"
            >
              <RefreshCw
                :size="15"
                :class="{ spinning: refreshingResult }"
              />
              刷新结果
            </button>
            <FileOutput v-else :size="21" />
          </header>

          <EmptyState
            v-if="!assessment"
            title="等待评估任务"
            description="完成患者选择和模块输入映射后，这里将按模块展示输出。"
          >
            <template #icon>
              <Braces :size="24" />
            </template>
          </EmptyState>

          <div v-else class="result-content">
            <div class="assessment-record">
              <CheckCircle2 :size="20" />
              <div>
                <strong>输入映射已保存</strong>
                <p>{{ assessment.status_detail }}</p>
                <span>{{ assessment.id }}</span>
              </div>
            </div>

            <article
              v-for="run in assessment.module_runs"
              :key="run.module_id"
              class="module-result-card"
            >
              <header>
                <div>
                  <h3>{{ moduleName(run.module_id) }}</h3>
                  <span>
                    {{
                      Object.values(run.inputs).reduce(
                        (count, ids) => count + ids.length,
                        0,
                      )
                    }}
                    份对应输入
                  </span>
                </div>
                <StatusPill :status="run.status" />
              </header>

              <div v-if="run.result" class="result-values">
                <p v-if="run.result.summary" class="result-summary">
                  {{ run.result.summary }}
                </p>

                <div
                  v-if="hasResultValues(run.result.scores)"
                  class="result-section"
                >
                  <strong>评分输出</strong>
                  <dl>
                    <div
                      v-for="(value, key) in run.result.scores"
                      :key="key"
                    >
                      <dt>{{ key }}</dt>
                      <dd>{{ value ?? "无" }}</dd>
                    </div>
                  </dl>
                </div>

                <div
                  v-if="hasResultValues(run.result.metrics)"
                  class="result-section"
                >
                  <strong>指标输出</strong>
                  <dl>
                    <div
                      v-for="(value, key) in run.result.metrics"
                      :key="key"
                    >
                      <dt>{{ key }}</dt>
                      <dd>{{ value ?? "无" }}</dd>
                    </div>
                  </dl>
                </div>

                <div
                  v-if="hasResultValues(run.result.result_data)"
                  class="result-section"
                >
                  <strong>结构化结果</strong>
                  <pre>{{
                    JSON.stringify(run.result.result_data, null, 2)
                  }}</pre>
                </div>

                <ul v-if="run.result.warnings.length" class="result-warnings">
                  <li v-for="warning in run.result.warnings" :key="warning">
                    {{ warning }}
                  </li>
                </ul>
              </div>

              <div v-else class="result-pending">
                <Braces :size="19" />
                <div>
                  <strong>尚无模型输出</strong>
                  <p>{{ run.status_detail }}</p>
                </div>
              </div>
            </article>
          </div>
        </section>
      </aside>
    </div>

    <input
      ref="fileInput"
      class="visually-hidden"
      type="file"
      @change="onFileInput"
    />
  </div>
</template>
