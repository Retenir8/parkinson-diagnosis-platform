<script setup lang="ts">
import { Activity, CircleAlert } from "@lucide/vue";
import { computed } from "vue";

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

const props = defineProps<{ result: ModuleResult }>();
const sideKeys = ["left", "right"] as const;
const tasks = computed(() => {
  const value = props.result.result_data.tasks;
  return value && typeof value === "object" && !Array.isArray(value)
    ? (value as Tasks)
    : {};
});
</script>

<template>
  <div class="motion-task-result">
    <p v-if="result.summary" class="result-summary">{{ result.summary }}</p>
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
