<script setup lang="ts">
import { Inbox } from "@lucide/vue";

withDefaults(
  defineProps<{
    title: string;
    description: string;
    compact?: boolean;
  }>(),
  {
    compact: false,
  },
);
</script>

<template>
  <div class="empty-state" :class="{ compact }">
    <div class="empty-icon">
      <slot name="icon">
        <Inbox :size="23" />
      </slot>
    </div>
    <strong>{{ title }}</strong>
    <p>{{ description }}</p>
    <slot />
  </div>
</template>
