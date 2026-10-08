<script setup lang="ts">
import { Activity, CircleAlert, ScanLine, Video } from "@lucide/vue";
import { computed, ref, watch } from "vue";

import { assessmentOutputUrl } from "@/services/api";
import type { ModuleResult } from "@/types/domain";
import { formatMetric, TASK_NAMES } from "@/utils/clinicalMetrics";

interface SideResult {
  status?: string;
  score?: number | string | null;
  detected_actions?: number;
  required_actions?: number;
  pauses?: number;
  speed_ratio?: number;
  amplitude_decrease_level?: number;
  reasons?: string[];
}

type Tasks = Record<string, Partial<Record<"left" | "right", SideResult>>>;

interface SegmentResult {
  segment_id: string;
  label?: string;
  task_type?: string;
  side?: "left" | "right" | null;
  start_s?: number | null;
  end_s?: number | null;
  tasks?: Tasks;
}

interface AnnotatedVideo {
  segment_id: string;
  task_type?: string;
  side?: "left" | "right" | null;
  label?: string;
  artifact_index: number;
  media_type?: string;
  telemetry?: TelemetryFrame[];
}

interface TelemetryFrame {
  frame_index?: number;
  time_s: number;
  hands?: Record<string, Record<string, { count?: number; state?: string } | boolean>>;
  sides?: Record<string, { count?: number; lift?: number; state?: string }>;
}

const props = defineProps<{
  assessmentId: string;
  moduleId: string;
  result: ModuleResult;
}>();
const sideKeys = ["left", "right"] as const;
const segments = computed(() => {
  const value = props.result.result_data.segments;
  return Array.isArray(value) ? (value as SegmentResult[]) : [];
});
/** 分段模式：每个任务取 task_type 匹配分段的结果（无匹配回退当前分段），
    使评分区与不分段模式一致（三任务卡片完整显示）。 */
const tasks = computed(() => {
  if (!segments.value.length) {
    const value = props.result.result_data.tasks;
    return value && typeof value === "object" && !Array.isArray(value)
      ? (value as Tasks)
      : {};
  }
  const fallback = selectedSegment.value?.tasks ?? {};
  const merged: Tasks = {};
  for (const taskKey of [
    "finger_opposition",
    "hand_alternation",
    "fist_clenching",
  ]) {
    const matchedSides: Partial<Record<"left" | "right", SideResult>> = {};
    for (const segment of segments.value) {
      if (segment.task_type === taskKey) {
        Object.assign(matchedSides, segment.tasks?.[taskKey] ?? {});
      }
    }
    merged[taskKey] = Object.keys(matchedSides).length
      ? matchedSides
      : fallback[taskKey] ?? {};
  }
  return merged;
});
const videos = computed(() => {
  const visualization = props.result.result_data.visualization;
  if (!visualization || typeof visualization !== "object") return [];
  const value = (visualization as Record<string, unknown>).annotated_videos;
  return Array.isArray(value) ? (value as AnnotatedVideo[]) : [];
});
const selectedSegmentId = ref("");
const selectedSegment = computed(
  () =>
    segments.value.find((s) => s.segment_id === selectedSegmentId.value) ??
    segments.value[0],
);
watch(
  segments,
  (value) => {
    if (
      !value.some((s) => s.segment_id === selectedSegmentId.value)
    ) {
      selectedSegmentId.value = value[0]?.segment_id ?? "";
    }
  },
  { immediate: true },
);
/** 分段模式下按 segment_id 匹配视频；无分段时取第一个（或多视频下拉） */
const selectedVideoIndex = ref(0);
const selectedVideo = computed(() => {
  if (segments.value.length) {
    return (
      videos.value.find(
        (v) => v.segment_id === selectedSegment.value?.segment_id,
      ) ?? videos.value[0]
    );
  }
  return videos.value[selectedVideoIndex.value] ?? videos.value[0];
});
watch(
  videos,
  (value) => {
    if (selectedVideoIndex.value >= value.length) {
      selectedVideoIndex.value = 0;
    }
  },
  { immediate: true },
);
const videoUrl = computed(() =>
  selectedVideo.value
    ? assessmentOutputUrl(
        props.assessmentId,
        props.moduleId,
        selectedVideo.value.artifact_index,
      )
    : "",
);
const activeTaskKey = computed(() => {
  const segmentTask = selectedSegment.value?.task_type;
  if (segmentTask && tasks.value[segmentTask]) return segmentTask;
  const videoTask = selectedVideo.value?.segment_id;
  const explicitVideoTask = selectedVideo.value?.task_type;
  if (explicitVideoTask && tasks.value[explicitVideoTask]) return explicitVideoTask;
  if (videoTask && tasks.value[videoTask]) return videoTask;
  return Object.keys(tasks.value)[0] ?? "";
});
const activeTask = computed(() =>
  selectedSegment.value?.tasks?.[activeTaskKey.value]
  ?? tasks.value[activeTaskKey.value]
  ?? {},
);
const displayedSideKeys = computed(() =>
  selectedSegment.value?.side || selectedVideo.value?.side
    ? [selectedSegment.value?.side ?? selectedVideo.value?.side!]
    : [...sideKeys],
);
const currentTime = ref(0);
const finalScoreVisible = ref(false);
const currentTelemetry = computed(() => {
  const frames = selectedVideo.value?.telemetry ?? [];
  if (!frames.length) return undefined;
  let low = 0;
  let high = frames.length - 1;
  while (low < high) {
    const middle = Math.ceil((low + high) / 2);
    if (frames[middle].time_s <= currentTime.value) low = middle;
    else high = middle - 1;
  }
  return frames[low];
});
function liveSide(side: "left" | "right"): { count?: number; lift?: number; state?: string } | undefined {
  const frame = currentTelemetry.value;
  if (!frame) return undefined;
  if (frame.sides) return frame.sides[side];
  const hand = frame.hands?.[side];
  const task = hand?.[activeTaskKey.value];
  return task && typeof task === "object" ? task : undefined;
}
function finalMetricValues(
  key: "pauses" | "speed_ratio" | "amplitude_decrease_level",
  formatted = false,
) {
  return displayedSideKeys.value
    .map((side) => {
      const value = activeTask.value[side]?.[key];
      return formatted ? formatMetric(value) : (value ?? "—");
    })
    .join(" / ");
}
function updateVideoTime(event: Event) {
  currentTime.value = (event.currentTarget as HTMLVideoElement).currentTime;
}
function startVideo() {
  finalScoreVisible.value = false;
}
function finishVideo(event: Event) {
  updateVideoTime(event);
  finalScoreVisible.value = true;
}
watch(videoUrl, () => {
  currentTime.value = 0;
  finalScoreVisible.value = false;
});
</script>

<template>
  <div class="motion-task-result">

    <div v-if="videos.length" class="motion-result-focus">
    <section class="pose-video-panel motion-video-panel">
      <header class="result-panel-heading">
        <div>
          <span class="panel-icon"><Video :size="17" /></span>
          <div>
            <strong>动作标注视频</strong>
            <small>
              {{
                segments.length
                  ? "每个分段独立识别，视频按分段输出"
                  : "关键点骨架与逐帧任务状态已写入画面"
              }}
            </small>
          </div>
        </div>
        <!-- 分段模式：按分段切换 -->
        <select
          v-if="segments.length > 1"
          v-model="selectedSegmentId"
          class="segment-select"
        >
          <option
            v-for="segment in segments"
            :key="segment.segment_id"
            :value="segment.segment_id"
          >
            {{ segment.label || segment.segment_id }}
          </option>
        </select>
        <!-- 非分段多视频（腿部多任务）：按视频切换 -->
        <select
          v-else-if="videos.length > 1"
          v-model="selectedVideoIndex"
          class="segment-select"
        >
          <option
            v-for="(video, index) in videos"
            :key="video.segment_id"
            :value="index"
          >
            {{ video.label || video.segment_id }}
          </option>
        </select>
      </header>
      <div v-if="videoUrl" class="pose-video-frame">
        <video
          :key="videoUrl"
          controls
          preload="metadata"
          :src="videoUrl"
          @play="startVideo"
          @timeupdate="updateVideoTime"
          @seeked="updateVideoTime"
          @ended="finishVideo"
        />
        <span class="video-mode-badge">
          <ScanLine :size="13" /> MediaPipe + RealSense
        </span>
      </div>
    </section>
    <aside class="motion-live-score-panel">
      <header>
        <span><Activity :size="17" /></span>
        <div>
          <small>{{ finalScoreVisible ? "动作结束 · 评分已即时生成" : "动作进行中 · 实时识别" }}</small>
          <strong>
            {{ (selectedSegment?.side ?? selectedVideo?.side) === "left" ? (moduleId === "leg-motion" ? "左侧 · " : "左手 · ") : (selectedSegment?.side ?? selectedVideo?.side) === "right" ? (moduleId === "leg-motion" ? "右侧 · " : "右手 · ") : "" }}{{ TASK_NAMES[activeTaskKey] ?? activeTaskKey }}
          </strong>
        </div>
      </header>
      <div v-if="finalScoreVisible" class="score-reveal-banner">
        <span class="live-dot" />本动作评分已生成
      </div>
      <div v-if="finalScoreVisible" class="motion-live-score-sides score-reveal" :class="{ 'single-side': displayedSideKeys.length === 1 }">
        <section v-for="side in displayedSideKeys" :key="side">
          <span>{{ side === "left" ? "左侧" : "右侧" }}</span>
          <strong>{{ activeTask[side]?.score ?? "—" }}<small>/ 4</small></strong>
          <em :class="activeTask[side]?.status === 'COMPLETE' ? 'complete' : 'incomplete'">
            {{ liveSide(side)?.count ?? activeTask[side]?.detected_actions ?? 0 }} 次动作
          </em>
        </section>
      </div>
      <section v-else class="motion-live-telemetry" :class="{ unavailable: !currentTelemetry }">
        <header><span class="live-dot" />视频同步信息<strong>Frame {{ currentTelemetry?.frame_index ?? "—" }} · {{ formatMetric(currentTime, 1) }} s</strong></header>
        <div v-for="side in displayedSideKeys" :key="side">
          <span>{{ side === "left" ? "左侧" : "右侧" }}</span>
          <strong>{{ liveSide(side)?.state ?? "暂无逐帧数据" }}</strong>
          <small>
            动作 {{ liveSide(side)?.count ?? 0 }} 次
            <template v-if="liveSide(side)?.lift !== undefined"> · lift {{ formatMetric(liveSide(side)?.lift, 3) }}</template>
          </small>
        </div>
      </section>
      <dl v-if="finalScoreVisible" class="motion-current-metrics score-reveal">
        <div><dt>停顿次数</dt><dd>{{ finalMetricValues("pauses") }}</dd></div>
        <div><dt>速度变化比</dt><dd>{{ finalMetricValues("speed_ratio", true) }}</dd></div>
        <div><dt>幅度递减等级</dt><dd>{{ finalMetricValues("amplitude_decrease_level") }}</dd></div>
      </dl>
      <p>{{ finalScoreVisible ? "当前动作录像与评分可作为一个完整片段保留或裁剪。" : "评分将在本动作视频播放结束后立即显示。" }}</p>
    </aside>
    </div>
    <div
      v-else-if="result.result_data.visualization"
      class="visualization-unavailable"
    >
      <Video :size="28" />
      <strong>本次结果没有标注视频</strong>
      <p>新执行的评估会生成；旧任务仍可查看已保存的评分指标。</p>
    </div>

    <!-- 分段模式：当前分段信息条 -->
    <div v-if="selectedSegment" class="segment-info-bar">
      <span>{{ selectedSegment.label || selectedSegment.segment_id }}</span>
      <small>
        {{ selectedSegment.task_type || "手部动作" }} ·
        {{ formatMetric(selectedSegment.start_s, 2) }}–{{ formatMetric(selectedSegment.end_s, 2) }} s
      </small>
    </div>

    <details class="all-score-details">
      <summary>查看全部动作评分明细</summary>
    <div class="motion-task-grid">
      <article v-for="(sides, taskKey) in tasks" :key="taskKey">
        <header>
          <span><Activity :size="16" /></span>
          <div>
            <strong>{{ TASK_NAMES[taskKey] ?? taskKey }}</strong>
            <small>左右侧独立评分</small>
          </div>
        </header>
        <div class="side-comparison">
          <section v-for="side in sideKeys" :key="side">
            <div class="side-score-heading">
              <span>{{ side === "left" ? "左侧" : "右侧" }}</span>
              <strong>{{ sides[side]?.score ?? "—" }}<small>/ 4</small></strong>
            </div>
            <dl>
              <div>
                <dt>动作完成</dt>
                <dd>
                  {{ sides[side]?.detected_actions ?? 0 }} /
                  {{ sides[side]?.required_actions ?? "—" }} 次
                </dd>
              </div>
              <div><dt>停顿次数</dt><dd>{{ sides[side]?.pauses ?? "—" }}</dd></div>
              <div><dt>速度变化比</dt><dd>{{ formatMetric(sides[side]?.speed_ratio) }}</dd></div>
              <div><dt>幅度递减等级</dt><dd>{{ sides[side]?.amplitude_decrease_level ?? "—" }}</dd></div>
            </dl>
            <span
              class="completion-state"
              :class="sides[side]?.status === 'COMPLETE' ? 'complete' : 'incomplete'"
            >
              {{ sides[side]?.status === "COMPLETE" ? "采集完整" : "采集不完整" }}
            </span>
          </section>
        </div>
      </article>
    </div>
    </details>

    <ul v-if="result.warnings.length" class="result-warnings">
      <li v-for="warning in result.warnings" :key="warning">
        <CircleAlert :size="14" />{{ warning }}
      </li>
    </ul>
  </div>
</template>
