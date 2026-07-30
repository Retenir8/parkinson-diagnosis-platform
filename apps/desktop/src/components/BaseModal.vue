<script setup lang="ts">
import { X } from "@lucide/vue";

defineProps<{
  open: boolean;
  title: string;
  description?: string;
  width?: string;
}>();

const emit = defineEmits<{
  close: [];
}>();
</script>

<template>
  <Teleport to="body">
    <Transition name="modal">
      <div
        v-if="open"
        class="modal-backdrop"
        role="presentation"
        @mousedown.self="emit('close')"
      >
        <section
          class="modal-panel"
          role="dialog"
          aria-modal="true"
          :aria-label="title"
          :style="{ maxWidth: width ?? '680px' }"
        >
          <header class="modal-header">
            <div>
              <h2>{{ title }}</h2>
              <p v-if="description">{{ description }}</p>
            </div>
            <button
              class="icon-button"
              type="button"
              aria-label="关闭"
              @click="emit('close')"
            >
              <X :size="20" />
            </button>
          </header>
          <div class="modal-content">
            <slot />
          </div>
          <footer v-if="$slots.footer" class="modal-footer">
            <slot name="footer" />
          </footer>
        </section>
      </div>
    </Transition>
  </Teleport>
</template>
