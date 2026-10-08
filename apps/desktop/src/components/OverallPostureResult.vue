<script setup lang="ts">
import {
  Activity,
  CircleAlert,
  Footprints,
  Gauge,
  ScanLine,
  Video,
} from "@lucide/vue";
import { computed, ref, watch } from "vue";

import { assessmentOutputUrl } from "@/services/api";
import type { ModuleResult } from "@/types/domain";
import {
  formatMetric,
  formatRate,
  GAIT_FEATURES,
} from "@/utils/clinicalMetrics";

interface SegmentResult {
  segment_id?: string;
  label?: string;
  start_s?: number | null;
  end_s?: number | null;
  duration_s?: number | null;
  quality?: {
    frames_total?: number | null;
    pose_detection_rate?: number | null;
    valid_depth_rate?: number | null;
    missing_feature_count?: number | null;
  };
  features?: Record<string, number | null>;
  prediction?: {
    class?: number;
    label?: string;
    probabilities?: Record<string, number | null>;
  };
}

interface AnnotatedVideo {
  segment_id: string;
  label?: string;
  artifact_index: number;
  media_type?: string;
}

const props = defineProps<{
  assessmentId: string;
  result: ModuleResult;
}>();

const selectedSegmentId = ref("");
const segments = computed(() => {
  const value = props.result.result_data.segments;
  return Array.isArray(value) ? (value as SegmentResult[]) : [];
});
const videos = computed(() => {
  const visualization = props.result.result_data.visualization;
  if (!visualization || typeof visualization !== "object") return [];
  const value = (visualization as Record<string, unknown>).annotated_videos;
  return Array.isArray(value) ? (value as AnnotatedVideo[]) : [];
});
const selectedSegment = computed(
  () =>
    segments.value.find(
      (segment) => segment.segment_id === selectedSegmentId.value,
    ) ?? segments.value[0],
);
const selectedVideo = computed(
  () =>
    videos.value.find(
      (video) => video.segment_id === selectedSegment.value?.segment_id,
    ) ?? videos.value[0],
);
const videoUrl = computed(() =>
  selectedVideo.value
    ? assessmentOutputUrl(
        props.assessmentId,
        props.result.module_id,
        selectedVideo.value.artifact_index,
      )
    : "",
);
const probabilities = computed(() =>
  selectedSegment.value?.prediction?.probabilities ?? {},
);
const probabilityLabels: Record<string, string> = {
  "0": "健康",
  "1": "轻度",
  "2": "中重度",
};

watch(
  segments,
  (value) => {
    if (
      !value.some((segment) => segment.segment_id === selectedSegmentId.value)
    ) {
      selectedSegmentId.value = value[0]?.segment_id ?? "";
    }
  },
  { immediate: true },
);
</script>

<template>
  <div class="posture-result">
    <div class="posture-result-grid">
      <section class="pose-video-panel">
        <header class="result-panel-heading">
          <div>
            <span class="panel-icon"><Video :size="17" /></span>
            <div>
              <strong>骨架分析视频</strong>
              <small>骨架及逐帧姿态/深度质量已写入视频画面</small>
            </div>
          </div>
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
        </header>

        <div v-if="videoUrl" class="pose-video-frame">
          <video :key="videoUrl" controls preload="metadata" :src="videoUrl" />
          <span class="video-mode-badge">
            <ScanLine :size="13" /> Pose + RealSense Depth
          </span>
        </div>
        <div v-else class="visualization-unavailable">
          <Video :size="28" />
          <strong>本次结果没有骨架视频</strong>
          <p>新执行的整体姿态任务会生成；旧任务仍可查看已保存的指标。</p>
        </div>

      </section>

      <aside class="posture-score-panel">
        <section v-if="selectedSegment" class="posture-side-metrics">
          <header><Activity :size="17" /><strong>当前片段信息</strong></header>
          <dl>
            <div><dt>姿态检出率</dt><dd>{{ formatRate(selectedSegment.quality?.pose_detection_rate) }}</dd></div>
            <div><dt>有效深度率</dt><dd>{{ formatRate(selectedSegment.quality?.valid_depth_rate) }}</dd></div>
            <div><dt>片段时长</dt><dd>{{ formatMetric(selectedSegment.duration_s, 2) }} s</dd></div>
            <div><dt>缺失特征</dt><dd>{{ selectedSegment.quality?.missing_feature_count ?? "—" }}</dd></div>
          </dl>
        </section>
        <section class="probability-panel">
          <header>
            <Gauge :size="17" />
            <strong>本片段分类概率</strong>
          </header>
          <div class="probability-chart" aria-label="0、1、2 分类概率柱状图">
            <div class="chart-y-axis">
              <span v-for="tick in [100, 75, 50, 25, 0]" :key="tick">{{ tick }}%</span>
            </div>
            <div class="chart-plot">
              <i v-for="tick in [100, 75, 50, 25, 0]" :key="tick" :style="{ bottom: `${tick}%` }" />
              <div v-for="classId in ['0', '1', '2']" :key="classId" class="chart-bar-group">
                <div class="chart-bar-area">
                  <div class="chart-bar" :style="{ height: `${Math.max(0, Math.min(100, Number(probabilities[classId] ?? 0) * 100))}%` }">
                    <strong>{{ formatRate(probabilities[classId]) }}</strong>
                  </div>
                </div>
                <span><b>{{ classId }}</b>{{ probabilityLabels[classId] }}</span>
              </div>
            </div>
          </div>
        </section>

        <dl class="posture-final-metrics">
          <div>
            <dt>步行距离</dt>
            <dd>{{ formatMetric(result.metrics.walk_distance_m, 2) }} m</dd>
          </div>
          <div>
            <dt>有效片段</dt>
            <dd>{{ result.metrics.walk_segment_count ?? "—" }}</dd>
          </div>
          <div>
            <dt>患者级聚合</dt>
            <dd>片段多数投票</dd>
          </div>
        </dl>
      </aside>
    </div>

    <section v-if="selectedSegment?.features" class="gait-feature-section">
      <header class="result-panel-heading">
        <div>
          <span class="panel-icon"><Footprints :size="17" /></span>
          <div>
            <strong>17项步态特征</strong>
            <small>{{ selectedSegment.label || selectedSegment.segment_id }}</small>
          </div>
        </div>
      </header>
      <div class="gait-feature-grid">
        <article v-for="(meta, key) in GAIT_FEATURES" :key="key">
          <span>{{ meta.label }}</span>
          <strong>
            {{ formatMetric(selectedSegment.features?.[key]) }}
            <small v-if="meta.unit">{{ meta.unit }}</small>
          </strong>
          <em>{{ key }} · {{ meta.group }}</em>
        </article>
      </div>
    </section>

    <ul v-if="result.warnings.length" class="result-warnings">
      <li v-for="warning in result.warnings" :key="warning">
        <CircleAlert :size="14" />{{ warning }}
      </li>
    </ul>
  </div>
</template>
