<script setup lang="ts">
import {
  ClipboardPlus,
  FileText,
  Scissors,
  Settings,
  ShieldCheck,
  Users,
} from "@lucide/vue";
import { computed, onMounted, ref } from "vue";
import { useRoute } from "vue-router";

import ClinicalBrandMark from "@/components/ClinicalBrandMark.vue";
import { api } from "@/services/api";

const route = useRoute();
const backendOnline = ref(false);

const navItems = [
  {
    to: "/patients",
    label: "患者管理",
    description: "患者与评估档案",
    icon: Users,
  },
  {
    to: "/assessment",
    label: "采集评估",
    description: "多模态推理工作台",
    icon: ClipboardPlus,
  },
  {
    to: "/video-segmentation",
    label: "视频分割",
    description: "人工时间轴标注",
    icon: Scissors,
  },
  {
    to: "/reports",
    label: "报告中心",
    description: "报告生成与导出",
    icon: FileText,
  },
  {
    to: "/settings",
    label: "系统设置",
    description: "服务与模块状态",
    icon: Settings,
  },
];

const pageTitle = computed(() =>
  typeof route.meta.title === "string" ? route.meta.title : "",
);

onMounted(async () => {
  try {
    await api.health();
    backendOnline.value = true;
  } catch {
    backendOnline.value = false;
  }
});
</script>

<template>
  <div class="app-shell">
    <aside class="sidebar">
      <div class="brand">
        <ClinicalBrandMark :size="54" />
        <div class="brand-copy">
          <strong>运动功能评估</strong>
        </div>
      </div>

      <nav class="main-nav" aria-label="主导航">
        <RouterLink
          v-for="item in navItems"
          :key="item.to"
          :to="item.to"
          class="nav-item"
          :title="item.description"
        >
          <span class="nav-icon" aria-hidden="true">
            <component :is="item.icon" :size="21" :stroke-width="1.8" />
          </span>
          <span>
            <strong>{{ item.label }}</strong>
            <small>{{ item.description }}</small>
          </span>
        </RouterLink>
      </nav>

      <div class="sidebar-footer">
        <div class="service-state">
          <span
            class="service-dot"
            :class="{ online: backendOnline }"
            aria-hidden="true"
          />
          <span>
            <strong>{{ backendOnline ? "服务在线" : "服务离线" }}</strong>
          </span>
        </div>
      </div>
    </aside>

    <main class="main-area">
      <header class="topbar">
        <div class="topbar-copy">
          <h1>{{ pageTitle }}</h1>
        </div>
        <div class="topbar-meta">
          <div class="privacy-badge">
            <span class="privacy-icon"><ShieldCheck :size="18" /></span>
            <span>
              <strong>数据仅保存在本机</strong>
            </span>
          </div>
        </div>
      </header>

      <div class="page-container">
        <RouterView />
      </div>
    </main>
  </div>
</template>
