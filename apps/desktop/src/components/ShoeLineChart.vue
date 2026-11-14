<script setup lang="ts">
import { computed } from "vue";

interface Point { x: number; y: number }
interface Series { name: string; color: string; points: Point[] }

const props = defineProps<{
  title: string;
  unit: string;
  series: Series[];
}>();

const validSeries = computed(() => props.series.map((item) => ({
  ...item,
  points: item.points.filter((point) => Number.isFinite(point.x) && Number.isFinite(point.y)),
})).filter((item) => item.points.length > 0));
const bounds = computed(() => {
  const points = validSeries.value.flatMap((item) => item.points);
  if (!points.length) return { minX: 0, maxX: 1, minY: 0, maxY: 1 };
  const xs = points.map((item) => item.x);
  const ys = points.map((item) => item.y);
  const minX = Math.min(...xs), maxX = Math.max(...xs);
  const minY = Math.min(...ys), maxY = Math.max(...ys);
  return { minX, maxX: maxX > minX ? maxX : minX + 1, minY, maxY: maxY > minY ? maxY : minY + 1 };
});
const minXLabel = computed(() => bounds.value.minX > 1_000_000 ? "0.0" : bounds.value.minX.toFixed(1));
const maxXLabel = computed(() => bounds.value.minX > 1_000_000
  ? (bounds.value.maxX - bounds.value.minX).toFixed(1)
  : bounds.value.maxX.toFixed(1));
function path(points: Point[]) {
  const { minX, maxX, minY, maxY } = bounds.value;
  return points.map((point, index) => {
    const x = 44 + ((point.x - minX) / (maxX - minX)) * 310;
    const y = 136 - ((point.y - minY) / (maxY - minY)) * 112;
    return `${index === 0 ? 'M' : 'L'}${x.toFixed(1)},${y.toFixed(1)}`;
  }).join(" ");
}
</script>

<template>
  <section class="chart-card">
    <div class="chart-title"><strong>{{ title }}</strong><small>{{ unit }}</small></div>
    <svg v-if="validSeries.length" viewBox="0 0 380 160" role="img" :aria-label="title">
      <line x1="44" y1="24" x2="44" y2="136" stroke="#aab8c4" />
      <line x1="44" y1="136" x2="354" y2="136" stroke="#aab8c4" />
      <text x="3" y="28">{{ bounds.maxY.toFixed(2) }}</text>
      <text x="3" y="136">{{ bounds.minY.toFixed(2) }}</text>
      <text x="44" y="153">{{ minXLabel }}</text>
      <text x="330" y="153">{{ maxXLabel }}</text>
      <path v-for="item in validSeries" :key="item.name" :d="path(item.points)" fill="none" :stroke="item.color" stroke-width="2" stroke-linejoin="round" />
    </svg>
    <p v-else>没有可绘制数据</p>
    <div class="chart-legend"><span v-for="item in validSeries" :key="item.name"><i :style="{ background: item.color }" />{{ item.name }}</span></div>
  </section>
</template>

<style scoped>
.chart-card { border: 1px solid #dbe3eb; background: #fff; border-radius: 12px; padding: 12px; min-width: 0; }
.chart-title { display: flex; align-items: baseline; justify-content: space-between; gap: 8px; font-size: 13px; }
.chart-title small { color: #6a7987; }
svg { width: 100%; height: auto; margin-top: 8px; }
svg text { fill: #70808b; font-size: 9px; }
p { color: #73818c; font-size: 12px; }
.chart-legend { display: flex; flex-wrap: wrap; gap: 12px; font-size: 11px; color: #526170; }
.chart-legend span { display: flex; align-items: center; gap: 5px; }
.chart-legend i { width: 10px; height: 3px; border-radius: 3px; }
</style>
