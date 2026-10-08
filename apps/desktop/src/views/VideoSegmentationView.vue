<script setup lang="ts">
import {
  CheckCircle2,
  CircleAlert,
  Clock,
  Copy,
  FileVideo2,
  FolderOpen,
  Plus,
  RefreshCw,
  Save,
  Scissors,
  Search,
  Trash2,
  Upload,
} from "@lucide/vue";
import {
  computed,
  nextTick,
  onMounted,
  onUnmounted,
  ref,
} from "vue";

import {
  ApiError,
  api,
  segmentationPreviewUrl,
  uploadSegmentationProject,
} from "@/services/api";
import type {
  SegmentationProject,
  VideoSegment,
} from "@/types/domain";

interface TaskOption {
  value: string;
  label: string;
}

const taskOptions: TaskOption[] = [
  { value: "walk", label: "步行 · walk" },
  { value: "turn", label: "转身 · turn" },
  { value: "stand", label: "站立 · stand" },
  { value: "other", label: "其他 · other" },
  { value: "finger_opposition", label: "对指 · finger_opposition" },
  { value: "hand_alternation", label: "轮替 · hand_alternation" },
  { value: "fist_clenching", label: "握拳 · fist_clenching" },
  { value: "toe_tapping", label: "脚趾拍地 · toe_tapping" },
  { value: "leg_agility", label: "抬腿灵活性 · leg_agility" },
];

/** 手部动作任务：分段时使用裁剪区域而非步行距离 */
const HAND_TASK_TYPES = new Set([
  "finger_opposition",
  "hand_alternation",
  "fist_clenching",
]);
const LEG_TASK_TYPES = new Set(["toe_tapping", "leg_agility"]);
function isHandTask(taskType: string): boolean {
  return HAND_TASK_TYPES.has(taskType.trim());
}
function isSideSpecificTask(taskType: string): boolean {
  const normalized = taskType.trim();
  return HAND_TASK_TYPES.has(normalized) || LEG_TASK_TYPES.has(normalized);
}

function needsCropRegion(taskType: string): boolean {
  const normalized = taskType.trim();
  return (
    isHandTask(normalized) ||
    LEG_TASK_TYPES.has(normalized) ||
    normalized === "walk"
  );
}

/** 手部裁剪区域默认值与手部模块 CROP_REGION 一致 */
const DEFAULT_CROP_REGION = { x: 400, y: 100, w: 480, h: 480 };
const cropRegion = ref({ ...DEFAULT_CROP_REGION });

/** 当前任务决定步行距离和裁剪区域输入。 */
const markerIsWalkTask = computed(
  () => markerTaskChoice.value.trim() === "walk",
);
const markerNeedsCropRegion = computed(
  () => needsCropRegion(markerTaskChoice.value),
);
/** 预览视频上的裁剪框（按原始分辨率换算百分比） */
const cropOverlayStyle = computed(() => {
  const project = selectedProject.value;
  if (!project?.width || !project.height) return {};
  const { x, y, w, h } = cropRegion.value;
  return {
    left: `${(x / project.width) * 100}%`,
    top: `${(y / project.height) * 100}%`,
    width: `${(w / project.width) * 100}%`,
    height: `${(h / project.height) * 100}%`,
  };
});
/** 预览视频宽高比跟随源视频（保证裁剪框按百分比精确对齐） */
const previewAspectRatio = computed(() => {
  const project = selectedProject.value;
  return project?.width && project.height
    ? `${project.width} / ${project.height}`
    : "16 / 9";
});

const projects = ref<SegmentationProject[]>([]);
const selectedId = ref<string | null>(null);
const segments = ref<VideoSegment[]>([]);
const keyword = ref("");
const loading = ref(false);
const refreshing = ref(false);
const saving = ref(false);
const importing = ref(false);
const uploadProgress = ref(0);
const actionError = ref("");
const notice = ref("");
const dirty = ref(false);

const fileInput = ref<HTMLInputElement | null>(null);
const pendingFile = ref<File | null>(null);
const projectName = ref("");
const videoElement = ref<HTMLVideoElement | null>(null);
const currentPreviewTime = ref(0);
const loadedPreviewDuration = ref(0);

const markerTaskChoice = ref("");
const markerSide = ref<"left" | "right">("left");
const markerCustomTaskType = ref("");
const markerLabel = ref("");
const markerStart = ref(0);
const markerEnd = ref(0);
const walkDistanceM = ref("");

let pollTimer: number | undefined;

const selectedProject = computed(
  () =>
    projects.value.find((project) => project.id === selectedId.value) ?? null,
);

const previewUrl = computed(() =>
  selectedProject.value?.preview_available
    ? segmentationPreviewUrl(selectedProject.value)
    : "",
);

const sourceDuration = computed(() => {
  const value =
    selectedProject.value?.duration_s ?? loadedPreviewDuration.value ?? 0;
  return Number.isFinite(value) ? value : 0;
});

const currentSourceTime = computed(() => {
  const previewDuration =
    selectedProject.value?.preview_duration_s ??
    loadedPreviewDuration.value ??
    0;
  if (!previewDuration || !sourceDuration.value) {
    return currentPreviewTime.value;
  }
  return Math.min(
    sourceDuration.value,
    (currentPreviewTime.value / previewDuration) * sourceDuration.value,
  );
});

const sortedSegments = computed(() =>
  [...segments.value].sort((a, b) => a.start_s - b.start_s),
);

function messageFromError(error: unknown, fallback: string): string {
  if (error instanceof ApiError && error.detail) {
    const detail = error.detail as {
      detail?: string | Array<{ msg?: string }>;
    };
    if (typeof detail.detail === "string") return detail.detail;
    if (Array.isArray(detail.detail)) {
      return detail.detail.map((item) => item.msg).filter(Boolean).join("；");
    }
  }
  return error instanceof Error ? error.message : fallback;
}

function formatTime(value: number | null | undefined): string {
  const safe = Number.isFinite(value) ? Number(value) : 0;
  const minutes = Math.floor(safe / 60);
  const seconds = safe - minutes * 60;
  return `${String(minutes).padStart(2, "0")}:${seconds
    .toFixed(2)
    .padStart(5, "0")}`;
}

function formatDate(value: string): string {
  return new Intl.DateTimeFormat("zh-CN", {
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
  }).format(new Date(value));
}

function taskClass(taskType: string): string {
  return `task-${taskType.replace(/[^a-z0-9_-]/gi, "-")}`;
}

async function loadProjects() {
  loading.value = true;
  actionError.value = "";
  try {
    projects.value = await api.listSegmentationProjects(keyword.value);
    if (
      selectedId.value &&
      !projects.value.some((project) => project.id === selectedId.value)
    ) {
      selectedId.value = null;
    }
  } catch (error) {
    actionError.value = messageFromError(error, "视频分割项目读取失败。");
  } finally {
    loading.value = false;
  }
}

function replaceProject(project: SegmentationProject) {
  const index = projects.value.findIndex((item) => item.id === project.id);
  if (index >= 0) {
    projects.value[index] = project;
  } else {
    projects.value.unshift(project);
  }
}

async function selectProject(project: SegmentationProject) {
  selectedId.value = project.id;
  segments.value = project.segments.map((item) => ({ ...item }));
  dirty.value = false;
  notice.value = "";
  actionError.value = "";
  currentPreviewTime.value = 0;
  markerStart.value = 0;
  markerEnd.value = project.duration_s ?? 0;
  walkDistanceM.value = project.walk_distance_m?.toString() ?? "";
  if (project.crop_region) {
    const [x, y, w, h] = project.crop_region;
    cropRegion.value = { x, y, w, h };
  } else {
    cropRegion.value = { ...DEFAULT_CROP_REGION };
  }
  await nextTick();
  if (videoElement.value) videoElement.value.currentTime = 0;
  configurePolling(project.status);
}

async function refreshSelected() {
  if (!selectedId.value || refreshing.value) return;
  refreshing.value = true;
  try {
    const project = await api.getSegmentationProject(selectedId.value);
    replaceProject(project);
    if (!dirty.value) {
      segments.value = project.segments.map((item) => ({ ...item }));
    }
    if (project.status === "ready") {
      markerEnd.value ||= project.duration_s ?? 0;
    }
    configurePolling(project.status);
  } catch (error) {
    actionError.value = messageFromError(error, "项目状态刷新失败。");
  } finally {
    refreshing.value = false;
  }
}

function configurePolling(status: SegmentationProject["status"]) {
  if (pollTimer !== undefined) {
    window.clearInterval(pollTimer);
    pollTimer = undefined;
  }
  if (status === "processing") {
    pollTimer = window.setInterval(refreshSelected, 2000);
  }
}

function openFilePicker() {
  fileInput.value?.click();
}

function onFilePicked(event: Event) {
  const input = event.target as HTMLInputElement;
  const file = input.files?.[0] ?? null;
  pendingFile.value = file;
  if (file && !projectName.value.trim()) {
    projectName.value = file.name.replace(/\.[^.]+$/, "");
  }
  input.value = "";
}

async function importProject() {
  if (!pendingFile.value || importing.value) return;
  importing.value = true;
  uploadProgress.value = 0;
  actionError.value = "";
  notice.value = "";
  try {
    const project = await uploadSegmentationProject(
      pendingFile.value,
      projectName.value.trim(),
      (value) => {
        uploadProgress.value = value;
      },
    );
    replaceProject(project);
    await selectProject(project);
    pendingFile.value = null;
    projectName.value = "";
    notice.value = "原始文件已归档，正在后台生成预览。";
  } catch (error) {
    actionError.value = messageFromError(error, "视频导入失败。");
  } finally {
    importing.value = false;
  }
}

function onLoadedMetadata() {
  loadedPreviewDuration.value = videoElement.value?.duration ?? 0;
}

function onTimeUpdate() {
  currentPreviewTime.value = videoElement.value?.currentTime ?? 0;
}

function seekSource(sourceTime: number) {
  const video = videoElement.value;
  if (!video) return;
  const previewDuration =
    selectedProject.value?.preview_duration_s ??
    loadedPreviewDuration.value ??
    0;
  const duration = sourceDuration.value;
  video.currentTime =
    previewDuration && duration
      ? Math.max(0, Math.min(previewDuration, (sourceTime / duration) * previewDuration))
      : Math.max(0, sourceTime);
}

function setMarkerStart() {
  markerStart.value = Number(currentSourceTime.value.toFixed(3));
  if (markerEnd.value < markerStart.value) {
    markerEnd.value = markerStart.value;
  }
}

function setMarkerEnd() {
  markerEnd.value = Number(currentSourceTime.value.toFixed(3));
}

function onTaskTypeChange() {
  const taskType =
    markerTaskChoice.value === "__custom__"
      ? markerCustomTaskType.value.trim()
      : markerTaskChoice.value;
  if (!taskType) return;
  const number =
    segments.value.filter(
      (item) => item.task_type === taskType,
    ).length + 1;
  markerLabel.value = `${taskType}_${number}`;
}

function nextSegmentId(): string {
  const numericIds = segments.value
    .map((item) => Number.parseInt(item.segment_id, 10))
    .filter(Number.isFinite);
  return String(numericIds.length ? Math.max(...numericIds) + 1 : 1);
}

function hasOverlap(candidate: VideoSegment, ignoreIndex = -1): boolean {
  return segments.value.some(
    (item, index) =>
      index !== ignoreIndex &&
      candidate.start_s < item.end_s &&
      candidate.end_s > item.start_s,
  );
}

function addSegment() {
  actionError.value = "";
  notice.value = "";
  const taskType =
    markerTaskChoice.value === "__custom__"
      ? markerCustomTaskType.value.trim()
      : markerTaskChoice.value.trim();
  const label = markerLabel.value.trim();
  if (!taskType) {
    actionError.value = "请先从选择框中指定这段视频的任务标签。";
    return;
  }
  if (!label) {
    actionError.value = "请填写 label。";
    return;
  }
  if (markerEnd.value <= markerStart.value) {
    actionError.value = "结束时间必须晚于开始时间。";
    return;
  }
  const candidate: VideoSegment = {
    segment_id: nextSegmentId(),
    label,
    task_type: taskType,
    side: isSideSpecificTask(taskType) ? markerSide.value : null,
    start_s: Number(markerStart.value.toFixed(3)),
    end_s: Number(markerEnd.value.toFixed(3)),
  };
  if (hasOverlap(candidate)) {
    actionError.value = "该时间段与已有片段重叠，请调整开始或结束时间。";
    return;
  }
  segments.value.push(candidate);
  segments.value.sort((a, b) => a.start_s - b.start_s);
  dirty.value = true;
  markerStart.value = candidate.end_s;
  markerEnd.value = sourceDuration.value;
  onTaskTypeChange();
}

function removeSegment(index: number) {
  segments.value.splice(index, 1);
  dirty.value = true;
}

function updateSegmentTime(
  index: number,
  field: "start_s" | "end_s",
  value: number,
) {
  segments.value[index][field] = Number(value);
  dirty.value = true;
}

function useCurrentTime(index: number, field: "start_s" | "end_s") {
  updateSegmentTime(index, field, Number(currentSourceTime.value.toFixed(3)));
}

function validateAllSegments(): string {
  if (!segments.value.length) return "请至少添加一个视频片段。";
  const ids = new Set<string>();
  for (const item of segments.value) {
    if (!item.segment_id.trim() || !item.label.trim() || !item.task_type.trim()) {
      return "segment_id、label 和 task_type 均不能为空。";
    }
    if (ids.has(item.segment_id)) return "segment_id 不能重复。";
    ids.add(item.segment_id);
    if (item.start_s < 0 || item.end_s <= item.start_s) {
      return `片段 ${item.segment_id} 的时间范围无效。`;
    }
    if (
      sourceDuration.value &&
      item.end_s > sourceDuration.value + 0.05
    ) {
      return `片段 ${item.segment_id} 超过视频时长。`;
    }
  }
  const ordered = [...segments.value].sort((a, b) => a.start_s - b.start_s);
  for (let index = 1; index < ordered.length; index += 1) {
    if (ordered[index].start_s < ordered[index - 1].end_s) {
      return `片段 ${ordered[index - 1].segment_id} 与 ${ordered[index].segment_id} 重叠。`;
    }
  }
  return "";
}

async function saveSegments() {
  if (!selectedProject.value || saving.value) return;
  const validationError = validateAllSegments();
  if (validationError) {
    actionError.value = validationError;
    return;
  }
  const parsedWalkDistance = walkDistanceM.value.trim()
    ? Number(walkDistanceM.value)
    : undefined;
  if (
    parsedWalkDistance !== undefined &&
    (!Number.isFinite(parsedWalkDistance) || parsedWalkDistance <= 0)
  ) {
    actionError.value = "步行距离必须是大于 0 的米制数值。";
    return;
  }
  saving.value = true;
  actionError.value = "";
  notice.value = "";
  try {
    const normalized = sortedSegments.value.map((item) => ({
      ...item,
      segment_id: item.segment_id.trim(),
      label: item.label.trim(),
      task_type: item.task_type.trim(),
      start_s: Number(item.start_s.toFixed(3)),
      end_s: Number(item.end_s.toFixed(3)),
    }));
    // 含 walk、手部或腿部动作时保存裁剪区域（作用于整段视频）
    const hasCropSegments = normalized.some((item) =>
      needsCropRegion(item.task_type),
    );
    const parsedCrop: [number, number, number, number] | undefined =
      hasCropSegments
        ? [
            cropRegion.value.x,
            cropRegion.value.y,
            cropRegion.value.w,
            cropRegion.value.h,
          ]
        : undefined;
    const project = await api.saveVideoSegments(
      selectedProject.value.id,
      normalized,
      parsedWalkDistance,
      parsedCrop,
    );
    replaceProject(project);
    segments.value = project.segments.map((item) => ({ ...item }));
    dirty.value = false;
    notice.value = "保存完成：原始视频、CSV 和 JSON 已归档在同一文件夹。";
  } catch (error) {
    actionError.value = messageFromError(error, "分段保存失败。");
  } finally {
    saving.value = false;
  }
}

async function copyArchivePath() {
  if (!selectedProject.value) return;
  try {
    await navigator.clipboard.writeText(selectedProject.value.archive_path);
    notice.value = "归档路径已复制。";
  } catch {
    actionError.value = "无法复制路径，请手动选择路径文本。";
  }
}

const deletingProject = ref(false);
async function deleteProject(project: SegmentationProject) {
  if (deletingProject.value) return;
  const target = project;
  if (!window.confirm(`确认删除分割项目“${target.name}”？\n将同时删除归档目录中的原始文件、预览和分段文件。`)) {
    return;
  }
  deletingProject.value = true;
  actionError.value = "";
  notice.value = "";
  try {
    await api.deleteProject(target.id);
    if (selectedId.value === target.id) {
      selectedId.value = null;
    }
    projects.value = projects.value.filter((item) => item.id !== target.id);
    notice.value = `已删除项目“${target.name}”，归档目录已清理。`;
  } catch (error) {
    actionError.value = messageFromError(error, "删除分割项目失败。");
  } finally {
    deletingProject.value = false;
  }
}

onMounted(loadProjects);
onUnmounted(() => {
  if (pollTimer !== undefined) window.clearInterval(pollTimer);
});
</script>

<template>
  <div class="segmentation-page">
    <div v-if="actionError" class="inline-alert error">
      <CircleAlert :size="18" />
      {{ actionError }}
    </div>
    <div v-if="notice" class="inline-alert success">
      <CheckCircle2 :size="18" />
      {{ notice }}
    </div>

    <section class="content-card import-card">
      <header class="card-header">
        <div>
          <span class="section-kicker">01 · Import</span>
          <h2>导入待分割视频</h2>
        </div>
      </header>
      <div class="import-row">
        <label class="field project-name-field">
          <span>项目名称</span>
          <input
            v-model="projectName"
            type="text"
            placeholder="默认使用文件名，可改成便于检索的名称"
          />
        </label>
        <button class="file-picker" type="button" @click="openFilePicker">
          <FileVideo2 :size="21" />
          <span>
            <strong>{{ pendingFile?.name ?? "选择 .bag 或视频文件" }}</strong>
          </span>
          <FolderOpen :size="18" />
        </button>
        <button
          class="button primary prominent"
          type="button"
          :disabled="!pendingFile || importing"
          @click="importProject"
        >
          <Upload :size="17" />
          {{ importing ? `正在上传 ${uploadProgress}%` : "导入并归档" }}
        </button>
      </div>
      <div v-if="importing" class="upload-track">
        <span :style="{ width: `${uploadProgress}%` }" />
      </div>
      <input
        ref="fileInput"
        class="visually-hidden"
        type="file"
        accept=".bag,.mp4,.mov,.avi,.mkv,.webm,.m4v,video/*"
        @change="onFilePicked"
      />
    </section>

    <div class="segmentation-workspace">
      <aside class="content-card archive-panel">
        <header class="card-header compact-header">
          <div>
            <span class="section-kicker">Archive</span>
            <h2>分割项目</h2>
          </div>
          <button
            class="icon-button"
            type="button"
            aria-label="刷新项目"
            @click="loadProjects"
          >
            <RefreshCw :size="16" :class="{ spinning: loading }" />
          </button>
        </header>
        <div class="archive-search">
          <Search :size="16" />
          <input
            v-model="keyword"
            type="search"
            placeholder="检索名称、文件或标签"
            @keyup.enter="loadProjects"
          />
          <button type="button" @click="loadProjects">检索</button>
        </div>
        <div v-if="loading && !projects.length" class="archive-loading">
          <span class="spinner" />
          正在读取本地归档…
        </div>
        <div v-else-if="!projects.length" class="archive-empty">
          <FileVideo2 :size="27" />
          <strong>暂无分割项目</strong>
          <span>从上方导入第一段视频</span>
        </div>
        <div v-else class="archive-list">
          <button
            v-for="project in projects"
            :key="project.id"
            type="button"
            class="archive-item"
            :class="{ active: project.id === selectedId }"
            @click="selectProject(project)"
          >
            <span class="archive-icon">
              <FileVideo2 :size="18" />
            </span>
            <span class="archive-copy">
              <strong>{{ project.name }}</strong>
              <small>{{ project.original_name }}</small>
              <em>
                {{ project.segments.length }} 个片段 ·
                {{ formatDate(project.updated_at) }}
              </em>
            </span>
            <span class="project-status" :class="project.status">
              {{
                project.status === "ready"
                  ? "就绪"
                  : project.status === "processing"
                    ? "处理中"
                    : "失败"
              }}
            </span>
            <span
              class="archive-delete"
              role="button"
              aria-label="删除项目"
              title="删除项目（含归档文件）"
              @click.stop="deleteProject(project)"
            >
              <Trash2 :size="14" />
            </span>
          </button>
        </div>
      </aside>

      <main class="content-card editor-panel">
        <div v-if="!selectedProject" class="editor-empty">
          <span><Scissors :size="28" /></span>
          <h2>选择一个项目开始分割</h2>
        </div>

        <template v-else>
          <header class="editor-header">
            <div>
              <span class="section-kicker">02 · Segment Editor</span>
              <h2>{{ selectedProject.name }}</h2>
              <p>
                {{ selectedProject.original_name }} ·
                {{ selectedProject.source_kind === "realsense_bag" ? "RealSense BAG" : "视频" }}
                <template v-if="selectedProject.duration_s">
                  · {{ formatTime(selectedProject.duration_s) }}
                </template>
              </p>
            </div>
            <div class="archive-path">
              <FolderOpen :size="16" />
              <span>
                <small>归档目录</small>
                <strong>{{ selectedProject.archive_path }}</strong>
              </span>
              <button
                class="icon-button"
                type="button"
                aria-label="复制归档路径"
                @click="copyArchivePath"
              >
                <Copy :size="15" />
              </button>
            </div>
          </header>

          <div
            v-if="selectedProject.status === 'processing'"
            class="processing-state"
          >
            <span class="processing-ring"><RefreshCw :size="24" /></span>
            <div>
              <strong>正在生成浏览器预览</strong>
              <p>{{ selectedProject.status_detail }}</p>
              <small>.bag 和较长视频可能需要等待数分钟，页面会自动刷新。</small>
            </div>
          </div>

          <div
            v-else-if="selectedProject.status === 'failed'"
            class="processing-state failed"
          >
            <span class="processing-ring"><CircleAlert :size="24" /></span>
            <div>
              <strong>预览生成失败</strong>
              <p>{{ selectedProject.status_detail }}</p>
              <small>原始文件仍保留在归档目录，可检查格式后重新导入。</small>
            </div>
          </div>

          <template v-else>
            <div class="editor-body">
              <div class="video-column">
                <div class="video-stage">
                  <video
                    ref="videoElement"
                    :key="previewUrl"
                    :src="previewUrl"
                    controls
                    preload="metadata"
                    :style="{ aspectRatio: previewAspectRatio }"
                    @loadedmetadata="onLoadedMetadata"
                    @timeupdate="onTimeUpdate"
                    @seeked="onTimeUpdate"
                  />
                  <div
                    v-if="markerNeedsCropRegion"
                    class="crop-overlay"
                    :style="cropOverlayStyle"
                  />
                  <div class="time-readout">
                    <Clock :size="16" />
                    <span>当前源时间</span>
                    <strong>{{ formatTime(currentSourceTime) }}</strong>
                    <small>/ {{ formatTime(sourceDuration) }}</small>
                  </div>
                </div>

                <div class="timeline-card">
                  <div class="timeline-heading">
                    <strong>片段时间轴</strong>
                    <span>{{ segments.length }} 个片段</span>
                  </div>
                  <div class="timeline-track">
                    <button
                      v-for="segment in sortedSegments"
                      :key="`${segment.segment_id}-${segment.start_s}`"
                      type="button"
                      class="timeline-segment"
                      :class="taskClass(segment.task_type)"
                      :style="{
                        left: `${(segment.start_s / Math.max(sourceDuration, 0.001)) * 100}%`,
                        width: `${((segment.end_s - segment.start_s) / Math.max(sourceDuration, 0.001)) * 100}%`,
                      }"
                      :title="`${segment.label} · ${formatTime(segment.start_s)}–${formatTime(segment.end_s)}`"
                      @click="seekSource(segment.start_s)"
                    >
                      {{ segment.segment_id }}
                    </button>
                  </div>
                  <div class="timeline-scale">
                    <span>00:00</span>
                    <span>{{ formatTime(sourceDuration / 2) }}</span>
                    <span>{{ formatTime(sourceDuration) }}</span>
                  </div>
                </div>
              </div>

              <aside class="marker-card">
                <div class="marker-title">
                  <span><Scissors :size="20" /></span>
                  <div>
                    <strong>添加片段</strong>
                    <small>按顺序完成选择、开始、结束</small>
                  </div>
                </div>

                <label v-if="markerIsWalkTask" class="field">
                  <span>实际步行距离（米，可选）</span>
                  <input
                    v-model="walkDistanceM"
                    type="number"
                    min="0.01"
                    step="0.01"
                    placeholder="例如 10"
                    @input="dirty = true"
                  />
                </label>

                <div v-if="markerNeedsCropRegion" class="field crop-region-field">
                  <span>裁剪区域（x, y, w, h，像素）</span>
                  <div class="crop-region-inputs">
                    <label>
                      x
                      <input
                        v-model.number="cropRegion.x"
                        type="number"
                        min="0"
                        step="1"
                        @input="dirty = true"
                      />
                    </label>
                    <label>
                      y
                      <input
                        v-model.number="cropRegion.y"
                        type="number"
                        min="0"
                        step="1"
                        @input="dirty = true"
                      />
                    </label>
                    <label>
                      w
                      <input
                        v-model.number="cropRegion.w"
                        type="number"
                        min="1"
                        step="1"
                        @input="dirty = true"
                      />
                    </label>
                    <label>
                      h
                      <input
                        v-model.number="cropRegion.h"
                        type="number"
                        min="1"
                        step="1"
                        @input="dirty = true"
                      />
                    </label>
                  </div>
                  <small>预览画面中绿色方框实时预览裁剪范围</small>
                </div>

                <label class="field">
                  <span>任务</span>
                  <select
                    v-model="markerTaskChoice"
                    @change="onTaskTypeChange"
                  >
                    <option value="">请选择任务标签</option>
                    <option
                      v-for="option in taskOptions"
                      :key="option.value"
                      :value="option.value"
                    >
                      {{ option.label }}
                    </option>
                    <option value="__custom__">其他任务…</option>
                  </select>
                </label>

                <label
                  v-if="markerTaskChoice === '__custom__'"
                  class="field"
                >
                  <span>自定义任务标识</span>
                  <input
                    v-model="markerCustomTaskType"
                    type="text"
                    placeholder="例如 sit_to_stand"
                    @input="onTaskTypeChange"
                  />
                </label>

                <label class="field">
                  <span>片段名称（可选）</span>
                  <input
                    v-model="markerLabel"
                    type="text"
                    placeholder="选择任务后自动生成，也可调整"
                  />
                </label>

                <label v-if="isSideSpecificTask(markerTaskChoice)" class="field">
                  <span>当前片段执行侧</span>
                  <select v-model="markerSide">
                    <option value="left">{{ isHandTask(markerTaskChoice) ? "左手" : "左侧" }}</option>
                    <option value="right">{{ isHandTask(markerTaskChoice) ? "右手" : "右侧" }}</option>
                  </select>
                </label>

                <div class="marker-time">
                  <div>
                    <span>开始时间</span>
                    <strong>{{ formatTime(markerStart) }}</strong>
                    <button type="button" @click="setMarkerStart">
                      使用当前时间
                    </button>
                  </div>
                  <div>
                    <span>结束时间</span>
                    <strong>{{ formatTime(markerEnd) }}</strong>
                    <button type="button" @click="setMarkerEnd">
                      使用当前时间
                    </button>
                  </div>
                </div>

                <button
                  class="button primary full prominent"
                  type="button"
                  @click="addSegment"
                >
                  <Plus :size="17" />
                  添加到片段清单
                </button>
                <p class="marker-hint">
                  时间字段以原始文件第一帧为 0 秒，与整体姿态分析脚本一致。
                </p>
              </aside>
            </div>

            <section class="segment-list-section">
              <header>
                <div>
                  <span class="section-kicker">03 · Segment List</span>
                  <h3>分段清单</h3>
                </div>
                <span class="count-badge">{{ segments.length }} 条</span>
              </header>

              <div v-if="!segments.length" class="segment-empty">
                <Scissors :size="22" />
                <span>还没有片段，请在播放器右侧完成第一次标记。</span>
              </div>
              <div v-else class="segment-table-wrap">
                <table class="segment-table">
                  <thead>
                    <tr>
                      <th>编号</th>
                      <th>执行侧</th>
                      <th>任务</th>
                      <th>名称</th>
                      <th>开始（秒）</th>
                      <th>结束（秒）</th>
                      <th>时长</th>
                      <th />
                    </tr>
                  </thead>
                  <tbody>
                    <tr
                      v-for="(segment, index) in segments"
                      :key="`${index}-${segment.segment_id}`"
                    >
                      <td>
                        <input
                          v-model="segment.segment_id"
                          class="id-input"
                          @input="dirty = true"
                        />
                      </td>
                      <td>
                        <select v-if="isSideSpecificTask(segment.task_type)" v-model="segment.side" @change="dirty = true">
                          <option :value="null">未指定（旧数据双侧）</option>
                          <option value="left">{{ isHandTask(segment.task_type) ? "左手" : "左侧" }}</option>
                          <option value="right">{{ isHandTask(segment.task_type) ? "右手" : "右侧" }}</option>
                        </select>
                        <span v-else>—</span>
                      </td>
                      <td>
                        <select
                          v-model="segment.task_type"
                          @change="dirty = true"
                        >
                          <option
                            v-if="
                              !taskOptions.some(
                                (item) => item.value === segment.task_type,
                              )
                            "
                            :value="segment.task_type"
                          >
                            {{ segment.task_type }}
                          </option>
                          <option
                            v-for="option in taskOptions"
                            :key="option.value"
                            :value="option.value"
                          >
                            {{ option.label }}
                          </option>
                        </select>
                      </td>
                      <td>
                        <input
                          v-model="segment.label"
                          @input="dirty = true"
                        />
                      </td>
                      <td>
                        <div class="time-input">
                          <input
                            :value="segment.start_s"
                            type="number"
                            min="0"
                            step="0.001"
                            @input="
                              updateSegmentTime(
                                index,
                                'start_s',
                                Number(($event.target as HTMLInputElement).value),
                              )
                            "
                          />
                          <button
                            type="button"
                            title="使用播放器当前时间"
                            @click="useCurrentTime(index, 'start_s')"
                          >
                            <Clock :size="13" />
                          </button>
                        </div>
                      </td>
                      <td>
                        <div class="time-input">
                          <input
                            :value="segment.end_s"
                            type="number"
                            min="0"
                            step="0.001"
                            @input="
                              updateSegmentTime(
                                index,
                                'end_s',
                                Number(($event.target as HTMLInputElement).value),
                              )
                            "
                          />
                          <button
                            type="button"
                            title="使用播放器当前时间"
                            @click="useCurrentTime(index, 'end_s')"
                          >
                            <Clock :size="13" />
                          </button>
                        </div>
                      </td>
                      <td class="duration-cell">
                        {{ (segment.end_s - segment.start_s).toFixed(2) }}s
                      </td>
                      <td>
                        <button
                          class="icon-button danger-icon"
                          type="button"
                          aria-label="删除片段"
                          @click="removeSegment(index)"
                        >
                          <Trash2 :size="15" />
                        </button>
                      </td>
                    </tr>
                  </tbody>
                </table>
              </div>
            </section>

            <footer class="save-bar">
              <div>
                <Save :size="20" />
                <span>
                  <strong>保存分段项目</strong>
                </span>
              </div>
              <button
                class="button primary prominent"
                type="button"
                :disabled="saving || !segments.length"
                @click="saveSegments"
              >
                <Save :size="17" />
                {{ saving ? "正在保存…" : dirty ? "保存分段" : "重新保存" }}
              </button>
            </footer>
          </template>
        </template>
      </main>
    </div>
  </div>
</template>

<style scoped>
.segmentation-page {
  display: flex;
  flex-direction: column;
  gap: 18px;
}

.segmentation-summary {
  grid-template-columns: minmax(0, 1fr) 120px auto;
}

.summary-guide {
  display: flex;
  align-items: center;
  gap: 8px;
  color: var(--ink-500);
  font-size: 10px;
  font-weight: 650;
  white-space: nowrap;
}

.summary-guide span {
  display: grid;
  width: 25px;
  height: 25px;
  place-items: center;
  color: var(--primary-700);
  border: 1px solid #cce7e3;
  border-radius: 50%;
  background: var(--primary-100);
}

.summary-guide i {
  width: 18px;
  height: 1px;
  background: var(--line);
}

.inline-alert.success {
  color: var(--success);
  border-color: #cce8da;
  background: #f1fbf6;
}

.import-row {
  display: grid;
  grid-template-columns: minmax(260px, 0.8fr) minmax(360px, 1.3fr) auto;
  gap: 14px;
  align-items: end;
  padding: 18px 20px 20px;
}

.file-picker {
  display: grid;
  min-height: 56px;
  grid-template-columns: 24px minmax(0, 1fr) 20px;
  gap: 11px;
  align-items: center;
  padding: 9px 13px;
  cursor: pointer;
  color: var(--primary-700);
  border: 1px dashed #a9cfca;
  border-radius: 10px;
  background: #f4fbfa;
  text-align: left;
}

.file-picker strong,
.file-picker small {
  display: block;
}

.file-picker strong {
  overflow: hidden;
  color: var(--ink-700);
  font-size: 11px;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.file-picker small {
  margin-top: 4px;
  color: var(--ink-400);
  font-size: 9px;
}

.upload-track {
  height: 3px;
  overflow: hidden;
  background: var(--line-soft);
}

.upload-track span {
  display: block;
  height: 100%;
  background: var(--primary-500);
  transition: width 150ms ease;
}

.segmentation-workspace {
  display: grid;
  grid-template-columns: 315px minmax(0, 1fr);
  gap: 18px;
  align-items: start;
}

.archive-panel,
.editor-panel {
  min-height: 680px;
}

.compact-header {
  min-height: 68px;
}

.archive-search {
  display: flex;
  align-items: center;
  gap: 8px;
  margin: 14px;
  padding-left: 11px;
  color: var(--ink-400);
  border: 1px solid var(--line);
  border-radius: 9px;
  background: var(--surface-soft);
}

.archive-search input {
  width: 100%;
  min-width: 0;
  height: 36px;
  border: 0;
  outline: 0;
  background: transparent;
  font-size: 10px;
}

.archive-search button {
  align-self: stretch;
  padding: 0 11px;
  cursor: pointer;
  color: var(--primary-700);
  border: 0;
  border-left: 1px solid var(--line);
  background: transparent;
  font-size: 10px;
  font-weight: 650;
}

.archive-list {
  display: flex;
  max-height: 670px;
  flex-direction: column;
  gap: 6px;
  overflow: auto;
  padding: 0 10px 12px;
}

.archive-item {
  display: grid;
  width: 100%;
  grid-template-columns: 34px minmax(0, 1fr) auto;
  gap: 9px;
  align-items: center;
  padding: 11px 10px;
  cursor: pointer;
  color: var(--ink-500);
  border: 1px solid transparent;
  border-radius: 10px;
  background: transparent;
  text-align: left;
}

.archive-item:hover,
.archive-item.active {
  border-color: #d5e8e5;
  background: #f2f9f8;
}

.archive-item.active {
  box-shadow: inset 3px 0 var(--primary-600);
}

.archive-icon {
  display: grid;
  width: 34px;
  height: 34px;
  place-items: center;
  color: var(--primary-700);
  border-radius: 9px;
  background: var(--primary-100);
}

.archive-copy {
  min-width: 0;
}

.archive-copy strong,
.archive-copy small,
.archive-copy em {
  display: block;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.archive-copy strong {
  color: var(--ink-900);
  font-size: 11px;
}

.archive-copy small {
  margin-top: 3px;
  color: var(--ink-500);
  font-size: 9px;
}

.archive-copy em {
  margin-top: 5px;
  color: var(--ink-400);
  font-size: 8px;
  font-style: normal;
}

.project-status {
  padding: 4px 6px;
  border-radius: 5px;
  font-size: 8px;
  font-weight: 700;
}

.project-status.ready {
  color: var(--success);
  background: #e9f7f0;
}

.project-status.processing {
  color: var(--warning);
  background: #fff6e5;
}

.project-status.failed {
  color: var(--danger);
  background: #fff0f0;
}

.archive-delete {
  display: flex;
  align-items: center;
  justify-content: center;
  flex: 0 0 auto;
  width: 24px;
  height: 24px;
  color: var(--ink-300);
  border-radius: 6px;
  opacity: 0;
  transition:
    opacity 0.15s ease,
    color 0.15s ease,
    background 0.15s ease;
}

.archive-item:hover .archive-delete,
.archive-item.active .archive-delete {
  opacity: 1;
}

.archive-delete:hover {
  color: var(--danger);
  background: #fff0f0;
}

.archive-loading,
.archive-empty {
  display: flex;
  min-height: 240px;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  gap: 8px;
  color: var(--ink-400);
  font-size: 10px;
}

.archive-loading {
  flex-direction: row;
}

.archive-empty strong {
  color: var(--ink-700);
  font-size: 11px;
}

.editor-panel {
  overflow: hidden;
}

.editor-empty {
  display: flex;
  min-height: 680px;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  color: var(--ink-400);
  text-align: center;
}

.editor-empty > span {
  display: grid;
  width: 62px;
  height: 62px;
  margin-bottom: 15px;
  place-items: center;
  color: var(--primary-700);
  border: 1px solid #d4ebe8;
  border-radius: 17px;
  background: #eff9f8;
}

.editor-empty h2 {
  color: var(--ink-700);
  font-size: 16px;
}

.editor-empty p {
  max-width: 420px;
  margin-top: 8px;
  font-size: 10px;
  line-height: 1.7;
}

.editor-header {
  display: flex;
  min-height: 85px;
  align-items: center;
  justify-content: space-between;
  gap: 20px;
  padding: 16px 20px;
  border-bottom: 1px solid var(--line-soft);
}

.editor-header h2 {
  margin-top: 5px;
  color: var(--ink-900);
  font-size: 17px;
}

.editor-header p {
  margin-top: 5px;
  color: var(--ink-500);
  font-size: 9px;
}

.archive-path {
  display: grid;
  max-width: 480px;
  grid-template-columns: 18px minmax(0, 1fr) 34px;
  gap: 9px;
  align-items: center;
  padding: 8px 9px 8px 11px;
  color: var(--ink-400);
  border: 1px solid var(--line);
  border-radius: 9px;
  background: var(--surface-soft);
}

.archive-path small,
.archive-path strong {
  display: block;
}

.archive-path small {
  font-size: 8px;
}

.archive-path strong {
  margin-top: 3px;
  overflow: hidden;
  color: var(--ink-600, var(--ink-700));
  font-family: "Cascadia Code", Consolas, monospace;
  font-size: 8px;
  font-weight: 500;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.processing-state {
  display: flex;
  min-height: 590px;
  align-items: center;
  justify-content: center;
  gap: 18px;
  color: var(--ink-500);
}

.processing-state strong {
  color: var(--ink-900);
  font-size: 15px;
}

.processing-state p {
  margin-top: 7px;
  font-size: 11px;
}

.processing-state small {
  display: block;
  margin-top: 6px;
  color: var(--ink-400);
  font-size: 9px;
}

.processing-ring {
  display: grid;
  width: 52px;
  height: 52px;
  place-items: center;
  color: var(--primary-600);
  border-radius: 50%;
  background: var(--primary-100);
}

.processing-state:not(.failed) .processing-ring svg {
  animation: spin 1s linear infinite;
}

.processing-state.failed .processing-ring {
  color: var(--danger);
  background: #fff0f0;
}

.editor-body {
  display: grid;
  grid-template-columns: minmax(520px, 1.4fr) minmax(290px, 0.6fr);
  gap: 18px;
  padding: 18px;
  background: #f8fafb;
}

.video-column {
  min-width: 0;
}

.video-stage {
  position: relative;
  overflow: hidden;
  border: 1px solid #263b4d;
  border-radius: 12px;
  background: #071522;
  box-shadow: 0 14px 30px rgba(5, 23, 38, 0.14);
}

.crop-overlay {
  position: absolute;
  z-index: 2;
  pointer-events: none;
  border: 2px solid rgba(0, 220, 0, 0.9);
  border-radius: 3px;
  box-shadow: 0 0 0 9999px rgba(3, 12, 20, 0.35);
}

.video-stage video {
  display: block;
  width: 100%;
  max-height: 430px;
  aspect-ratio: 16 / 9;
  background: #06101a;
  object-fit: contain;
}

.time-readout {
  display: flex;
  height: 42px;
  align-items: center;
  gap: 8px;
  padding: 0 13px;
  color: #85a1b5;
  background: #0c1e2d;
  font-size: 9px;
}

.time-readout strong {
  margin-left: auto;
  color: #e8f2f6;
  font-family: "Cascadia Code", Consolas, monospace;
  font-size: 14px;
}

.time-readout small {
  color: #648096;
}

.timeline-card {
  margin-top: 12px;
  padding: 12px 13px 10px;
  border: 1px solid var(--line);
  border-radius: 10px;
  background: #ffffff;
}

.timeline-heading {
  display: flex;
  justify-content: space-between;
  margin-bottom: 9px;
  color: var(--ink-500);
  font-size: 9px;
}

.timeline-heading strong {
  color: var(--ink-700);
}

.timeline-track {
  position: relative;
  height: 30px;
  overflow: hidden;
  border-radius: 6px;
  background:
    repeating-linear-gradient(
      90deg,
      transparent,
      transparent calc(10% - 1px),
      #e5ecef calc(10% - 1px),
      #e5ecef 10%
    ),
    #f1f5f6;
}

.timeline-segment {
  position: absolute;
  top: 4px;
  min-width: 4px;
  height: 22px;
  overflow: hidden;
  cursor: pointer;
  color: #ffffff;
  border: 0;
  border-radius: 4px;
  background: var(--primary-600);
  font-size: 8px;
  font-weight: 700;
  text-overflow: ellipsis;
}

.timeline-segment.task-turn {
  background: #4778cc;
}

.timeline-segment.task-stand {
  background: #9c6eb6;
}

.timeline-segment.task-other {
  background: #788b99;
}

.timeline-scale {
  display: flex;
  justify-content: space-between;
  margin-top: 5px;
  color: var(--ink-400);
  font-family: "Cascadia Code", Consolas, monospace;
  font-size: 7px;
}

.marker-card {
  align-self: stretch;
  padding: 17px;
  border: 1px solid var(--line);
  border-radius: 12px;
  background: #ffffff;
  box-shadow: var(--shadow-sm);
}

.marker-title {
  display: flex;
  gap: 10px;
  align-items: center;
  margin-bottom: 17px;
  padding-bottom: 14px;
  border-bottom: 1px solid var(--line-soft);
}

.marker-title > span {
  display: grid;
  width: 38px;
  height: 38px;
  place-items: center;
  color: var(--primary-700);
  border-radius: 10px;
  background: var(--primary-100);
}

.marker-title strong,
.marker-title small {
  display: block;
}

.marker-title strong {
  color: var(--ink-900);
  font-size: 12px;
}

.marker-title small {
  margin-top: 4px;
  color: var(--ink-400);
  font-size: 8px;
}

.marker-card .field + .field {
  margin-top: 12px;
}

.crop-region-field small {
  display: block;
  margin-top: 4px;
  color: var(--ink-400);
  font-size: 9px;
}

.crop-region-inputs {
  display: grid;
  grid-template-columns: repeat(4, minmax(0, 1fr));
  gap: 6px;
}

.crop-region-inputs label {
  display: flex;
  flex-direction: column;
  gap: 3px;
  color: var(--ink-400);
  font-size: 9px;
}

.crop-region-inputs input {
  width: 100%;
  padding: 6px;
  color: var(--ink-800);
  border: 1px solid var(--line);
  border-radius: 6px;
  outline: none;
  background: #ffffff;
  font-size: 10px;
}

.marker-time {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 8px;
  margin: 15px 0;
}

.marker-time > div {
  padding: 11px;
  border: 1px solid var(--line);
  border-radius: 9px;
  background: var(--surface-soft);
}

.marker-time span,
.marker-time strong {
  display: block;
}

.marker-time span {
  color: var(--ink-500);
  font-size: 8px;
}

.marker-time strong {
  margin: 6px 0 8px;
  color: var(--ink-900);
  font-family: "Cascadia Code", Consolas, monospace;
  font-size: 13px;
}

.marker-time button {
  padding: 0;
  cursor: pointer;
  color: var(--primary-700);
  border: 0;
  background: transparent;
  font-size: 8px;
  font-weight: 650;
}

.marker-hint {
  margin-top: 11px;
  color: var(--ink-400);
  font-size: 8px;
  line-height: 1.6;
}

.segment-list-section {
  border-top: 1px solid var(--line);
}

.segment-list-section > header {
  display: flex;
  min-height: 66px;
  align-items: center;
  justify-content: space-between;
  padding: 13px 18px;
  border-bottom: 1px solid var(--line-soft);
}

.segment-list-section h3 {
  margin-top: 4px;
  color: var(--ink-900);
  font-size: 14px;
}

.segment-empty {
  display: flex;
  min-height: 100px;
  align-items: center;
  justify-content: center;
  gap: 9px;
  color: var(--ink-400);
  font-size: 10px;
}

.segment-table-wrap {
  overflow-x: auto;
}

.segment-table {
  width: 100%;
  border-collapse: collapse;
}

.segment-table th {
  padding: 9px 10px;
  color: var(--ink-500);
  border-bottom: 1px solid var(--line);
  background: #f8fafb;
  font-size: 8px;
  text-align: left;
}

.segment-table td {
  padding: 8px 7px;
  border-bottom: 1px solid var(--line-soft);
}

.segment-table input,
.segment-table select {
  width: 100%;
  min-width: 90px;
  height: 33px;
  padding: 0 8px;
  color: var(--ink-700);
  border: 1px solid var(--line);
  border-radius: 7px;
  background: #ffffff;
  font-size: 9px;
}

.segment-table .id-input {
  min-width: 60px;
  max-width: 80px;
  font-family: "Cascadia Code", Consolas, monospace;
}

.time-input {
  display: flex;
}

.time-input input {
  min-width: 86px;
  border-radius: 7px 0 0 7px;
}

.time-input button {
  display: grid;
  width: 30px;
  cursor: pointer;
  place-items: center;
  color: var(--primary-700);
  border: 1px solid var(--line);
  border-left: 0;
  border-radius: 0 7px 7px 0;
  background: #f7fafb;
}

.duration-cell {
  color: var(--ink-500);
  font-family: "Cascadia Code", Consolas, monospace;
  font-size: 9px;
  white-space: nowrap;
}

.danger-icon {
  color: var(--danger);
}

.save-bar {
  display: flex;
  min-height: 78px;
  align-items: center;
  justify-content: space-between;
  gap: 20px;
  padding: 14px 18px;
  border-top: 1px solid var(--line);
  background: #f8fbfb;
}

.save-bar > div {
  display: flex;
  align-items: center;
  gap: 10px;
  color: var(--primary-700);
}

.save-bar strong,
.save-bar small {
  display: block;
}

.save-bar strong {
  color: var(--ink-900);
  font-size: 11px;
}

.save-bar small {
  margin-top: 4px;
  color: var(--ink-400);
  font-size: 8px;
}

/* Clinical visual refresh: keep the video editor visually continuous. */
.segmentation-workspace {
  grid-template-columns: 300px minmax(0, 1fr);
  gap: 14px;
}

.archive-panel,
.editor-panel {
  border: 0;
  border-radius: 20px;
  background: rgba(255, 255, 255, 0.86);
  box-shadow: 0 22px 54px -42px rgba(24, 42, 70, 0.78);
  backdrop-filter: blur(15px);
}

.archive-panel .card-header,
.editor-header {
  border-bottom-color: rgba(225, 230, 238, 0.64);
}

.archive-search {
  border-color: rgba(211, 219, 229, 0.72);
  border-radius: 12px;
  background: #f8f9fc;
}

.archive-item {
  border-radius: 13px;
}

.archive-item:hover,
.archive-item.active {
  border-color: rgba(11, 111, 244, 0.16);
  background: #f3f7ff;
}

.archive-item.active {
  box-shadow: inset 3px 0 var(--primary-600);
}

.archive-icon,
.editor-empty > span,
.marker-title > span {
  color: var(--primary-600);
  border: 0;
  background: var(--primary-100);
}

.editor-empty {
  background:
    radial-gradient(circle at 52% 46%, rgba(11, 111, 244, 0.045), transparent 22%),
    rgba(255, 255, 255, 0.5);
}

.editor-body {
  gap: 14px;
  padding: 14px;
  background: #f4f6fa;
}

.video-stage {
  border: 0;
  border-radius: 18px;
  background: #050f1e;
  box-shadow: 0 22px 42px -25px rgba(2, 14, 31, 0.92);
}

.video-stage video {
  background:
    radial-gradient(circle at 50% 45%, rgba(35, 78, 130, 0.3), transparent 50%),
    #050f1e;
}

.time-readout {
  color: #8295af;
  background: #0b192c;
}

.timeline-card,
.marker-card {
  border: 0;
  border-radius: 15px;
  background: rgba(255, 255, 255, 0.9);
  box-shadow: 0 14px 34px -29px rgba(24, 42, 70, 0.82);
}

.timeline-segment {
  background: linear-gradient(90deg, #0b6ff4, #4092ff);
}

.timeline-segment.task-turn {
  background: linear-gradient(90deg, #724ee8, #9877f2);
}

.timeline-segment.task-stand {
  background: linear-gradient(90deg, #ef3b78, #ff6e9f);
}

.marker-title {
  border-bottom-color: rgba(225, 230, 238, 0.64);
}

.marker-time > div {
  border-color: rgba(213, 221, 231, 0.68);
  border-radius: 12px;
  background: #f7f9fc;
}

.segment-list-section {
  border-top-color: rgba(219, 225, 233, 0.62);
}

.segment-list-section > header,
.segment-table th,
.segment-table td {
  border-bottom-color: rgba(225, 230, 238, 0.62);
}

.save-bar {
  border-top-color: rgba(218, 225, 234, 0.62);
  background: linear-gradient(96deg, #edf4ff, rgba(255, 255, 255, 0.96) 64%);
}

@media (max-width: 1250px) {
  .segmentation-workspace {
    grid-template-columns: 260px minmax(0, 1fr);
  }

  .editor-body {
    grid-template-columns: 1fr;
  }
}

/* Legibility pass: remove technical microcopy and keep operating text readable. */
.file-picker strong,
.archive-copy strong,
.save-bar strong {
  font-size: 14px;
}

.file-picker small,
.archive-copy small,
.save-bar small {
  font-size: 10px;
}

.archive-copy em,
.archive-path small,
.marker-title small,
.marker-hint {
  display: none;
}

.project-status,
.count-badge {
  font-size: 10px;
}

.archive-search input,
.archive-search button {
  font-size: 13px;
}

.archive-loading,
.archive-empty,
.editor-empty p {
  font-size: 13px;
}

.archive-empty strong,
.editor-empty h2 {
  font-size: 18px;
}

.editor-header h2 {
  font-size: 22px;
}

.editor-header p,
.processing-state p {
  font-size: 13px;
}

.archive-path strong {
  font-size: 11px;
}

.processing-state strong {
  font-size: 18px;
}

.processing-state small {
  display: none;
}

.time-readout {
  font-size: 12px;
}

.time-readout strong {
  font-size: 18px;
}

.timeline-heading,
.timeline-scale {
  font-size: 11px;
}

.timeline-segment {
  font-size: 10px;
}

.marker-title strong {
  font-size: 17px;
}

.marker-time span,
.marker-time button {
  font-size: 12px;
}

.marker-time strong {
  font-size: 18px;
}

.segment-list-section h3 {
  font-size: 19px;
}

.segment-empty {
  font-size: 13px;
}

.segment-table th,
.segment-table input,
.segment-table select,
.duration-cell {
  font-size: 12px;
}
</style>
