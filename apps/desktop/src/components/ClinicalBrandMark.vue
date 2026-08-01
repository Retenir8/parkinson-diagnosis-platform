<script setup lang="ts">
withDefaults(
  defineProps<{
    size?: number;
  }>(),
  { size: 52 },
);
</script>

<template>
  <svg
    class="clinical-brand-mark"
    :width="size"
    :height="size"
    viewBox="0 0 56 56"
    fill="none"
    xmlns="http://www.w3.org/2000/svg"
    role="img"
    aria-label="运动功能评估标志"
  >
    <defs>
      <linearGradient id="clinical-blue" x1="8" y1="6" x2="48" y2="50" gradientUnits="userSpaceOnUse">
        <stop stop-color="#2388FF" />
        <stop offset="1" stop-color="#075FE4" />
      </linearGradient>
      <linearGradient id="clinical-pink" x1="36" y1="12" x2="48" y2="26" gradientUnits="userSpaceOnUse">
        <stop stop-color="#FF5B93" />
        <stop offset="1" stop-color="#ED2E70" />
      </linearGradient>
      <filter id="clinical-shadow" x="-8" y="-6" width="72" height="74" filterUnits="userSpaceOnUse">
        <feDropShadow dx="0" dy="7" stdDeviation="5" flood-color="#126DEB" flood-opacity="0.24" />
      </filter>
    </defs>
    <g filter="url(#clinical-shadow)">
      <rect x="4" y="4" width="48" height="48" rx="16" fill="url(#clinical-blue)" />
      <path
        d="M14 29H20L23.4 21L28 36L32.1 25L35 29H42"
        stroke="white"
        stroke-width="3"
        stroke-linecap="round"
        stroke-linejoin="round"
      />
      <circle cx="42" cy="16" r="6" fill="url(#clinical-pink)" stroke="white" stroke-width="2" />
      <path d="M42 13.5V18.5M39.5 16H44.5" stroke="white" stroke-width="1.8" stroke-linecap="round" />
    </g>
  </svg>
</template>
