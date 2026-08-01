<script setup lang="ts">
import { CircleAlert } from "@lucide/vue";

import MotionTaskResult from "@/components/MotionTaskResult.vue";
import OverallPostureResult from "@/components/OverallPostureResult.vue";
import type { ModuleResult } from "@/types/domain";
import { formatMetric, metricLabel } from "@/utils/clinicalMetrics";

defineProps<{
  assessmentId: string;
  moduleId: string;
  result: ModuleResult;
}>();

function hasTasks(result: ModuleResult) {
  const tasks = result.result_data.tasks;
  const segments = result.result_data.segments;
  return Boolean(
    (tasks && typeof tasks === "object" && !Array.isArray(tasks)) ||
      (Array.isArray(segments) && segments.length > 0),
  );
}
</script>

<template>
  <OverallPostureResult
    v-if="moduleId === 'overall-posture'"
    :assessment-id="assessmentId"
    :result="result"
  />
  <MotionTaskResult
    v-else-if="hasTasks(result)"
    :assessment-id="assessmentId"
    :module-id="moduleId"
    :result="result"
  />
  <div v-else class="generic-module-result">
    <div class="generic-metric-grid">
      <article v-for="(value, key) in result.scores" :key="`score-${key}`">
        <span>{{ metricLabel(key) }}</span>
        <strong>{{ formatMetric(value) }}</strong>
        <small>评分 · {{ key }}</small>
      </article>
      <article v-for="(value, key) in result.metrics" :key="`metric-${key}`">
        <span>{{ metricLabel(key) }}</span>
        <strong>{{ formatMetric(value) }}</strong>
        <small>指标 · {{ key }}</small>
      </article>
    </div>
    <div
      v-if="!Object.keys(result.scores).length && !Object.keys(result.metrics).length"
      class="visualization-unavailable"
    >
      <strong>模块尚未返回可展示指标</strong>
      <p>接口已保留，接入模型输出后会在此展开。</p>
    </div>
    <ul v-if="result.warnings.length" class="result-warnings">
      <li v-for="warning in result.warnings" :key="warning">
        <CircleAlert :size="14" />{{ warning }}
      </li>
    </ul>
  </div>
</template>
