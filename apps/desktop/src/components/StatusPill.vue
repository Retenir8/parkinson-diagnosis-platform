<script setup lang="ts">
import { computed } from "vue";

const props = defineProps<{
  status: string;
  label?: string;
}>();

const text = computed(() => {
  if (props.label) return props.label;
  return (
    {
      ready: "可用",
      adapter_pending: "待接入",
      external_pending: "待提供",
      disabled: "未启用",
      error: "异常",
      awaiting_adapter: "等待接入",
      draft: "待分析",
      queued: "排队中",
      running: "分析中",
      completed: "已完成",
      failed: "失败",
      cancelled: "已取消",
    }[props.status] ?? props.status
  );
});
</script>

<template>
  <span class="status-pill" :class="`status-${status}`">
    <span class="status-dot" aria-hidden="true" />
    {{ text }}
  </span>
</template>
