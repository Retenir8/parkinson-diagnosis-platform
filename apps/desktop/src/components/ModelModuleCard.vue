<script setup lang="ts">
import {
  Activity,
  Footprints,
  Hand,
  ScanLine,
  SlidersHorizontal,
} from "@lucide/vue";
import { computed } from "vue";

import StatusPill from "@/components/StatusPill.vue";
import type { ModelModuleDescriptor } from "@/types/domain";

const props = defineProps<{
  module: ModelModuleDescriptor;
  selected?: boolean;
  selectable?: boolean;
}>();

const emit = defineEmits<{
  toggle: [moduleId: string];
}>();

const icon = computed(() => {
  return {
    posture: ScanLine,
    hand: Hand,
    leg: Footprints,
    insole: Activity,
  }[props.module.category];
});

const canSelect = computed(
  () =>
    props.selectable &&
    props.module.status !== "disabled" &&
    props.module.status !== "error",
);
</script>

<template>
  <article
    class="module-card"
    :class="{ selected, selectable: canSelect }"
    @click="canSelect && emit('toggle', module.id)"
  >
    <div class="module-card-top">
      <div class="module-icon" :class="`module-${module.category}`">
        <component :is="icon" :size="21" />
      </div>
      <StatusPill :status="module.status" />
    </div>
    <div class="module-card-body">
      <h3>{{ module.display_name }}</h3>
      <p>{{ module.description }}</p>
    </div>
    <div class="module-card-footer">
      <span>
        <SlidersHorizontal :size="15" />
        {{ module.output_capabilities.length }} 类输出接口
      </span>
      <label v-if="selectable" class="module-check" @click.stop>
        <input
          type="checkbox"
          :checked="selected"
          :disabled="!canSelect"
          @change="emit('toggle', module.id)"
        />
        纳入评估
      </label>
    </div>
  </article>
</template>
