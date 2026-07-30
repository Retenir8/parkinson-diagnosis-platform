<script setup lang="ts">
import {
  ClipboardPlus,
  FileText,
  HeartPulse,
  Settings,
  Users,
} from "@lucide/vue";
import { computed, onMounted, ref } from "vue";
import { useRoute } from "vue-router";

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
const pageSubtitle = computed(() =>
  typeof route.meta.subtitle === "string" ? route.meta.subtitle : "",
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
        <div class="brand-mark" aria-hidden="true">
          <HeartPulse :size="24" :stroke-width="2.2" />
        </div>
        <div>
          <strong>运动功能评估</strong>
          <span>Multimodal Clinical Lab</span>
        </div>
      </div>

      <nav class="main-nav" aria-label="主导航">
        <RouterLink
          v-for="item in navItems"
          :key="item.to"
          :to="item.to"
          class="nav-item"
        >
          <component :is="item.icon" :size="20" />
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
            <strong>{{ backendOnline ? "分析服务已连接" : "分析服务未连接" }}</strong>
            <small>本地服务 · 127.0.0.1</small>
          </span>
        </div>
        <div class="version-label">FRAMEWORK · v0.1.0</div>
      </div>
    </aside>

    <main class="main-area">
      <header class="topbar">
        <div>
          <p class="eyebrow">多模态临床评估工作台</p>
          <h1>{{ pageTitle }}</h1>
          <p>{{ pageSubtitle }}</p>
        </div>
        <div class="topbar-meta">
          <div class="privacy-badge">
            <span class="privacy-icon">本地</span>
            <span>
              <strong>数据保存在本机</strong>
              <small>当前未连接外部数据库</small>
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
