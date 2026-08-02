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
  start_s?: number | null;
  end_s?: number | null;
  tasks?: Tasks;
}

interface AnnotatedVideo {
  segment_id: string;
  label?: string;
  artifact_index: number;
  media_type?: string;
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
    const matched = segments.value.find(
      (segment) => segment.task_type === taskKey,
    );
    merged[taskKey] = matched?.tasks?.[taskKey] ?? fallback[taskKey] ?? {};
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
</script>

<template>
  <div class="motion-task-result">

    <section v-if="videos.length" class="pose-video-panel motion-video-panel">
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
        <video :key="videoUrl" controls preload="metadata" :src="videoUrl" />
        <span class="video-mode-badge">
          <ScanLine :size="13" /> MediaPipe + RealSense
        </span>
      </div>
    </section>
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

    <ul v-if="result.warnings.length" class="result-warnings">
      <li v-for="warning in result.warnings" :key="warning">
        <CircleAlert :size="14" />{{ warning }}
      </li>
    </ul>
  </div>
</template>
