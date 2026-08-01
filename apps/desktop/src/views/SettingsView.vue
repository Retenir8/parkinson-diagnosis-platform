<script setup lang="ts">
import {
  CheckCircle2,
  CircleAlert,
  Database,
  FolderCog,
  HardDrive,
  RefreshCw,
  ServerCog,
  ShieldCheck,
} from "@lucide/vue";
import { onMounted, ref } from "vue";

import ModelModuleCard from "@/components/ModelModuleCard.vue";
import { api } from "@/services/api";
import type {
  HealthStatus,
  ModelModuleDescriptor,
} from "@/types/domain";

const health = ref<HealthStatus | null>(null);
const modules = ref<ModelModuleDescriptor[]>([]);
const checking = ref(false);
const connectionError = ref("");

async function refresh() {
  checking.value = true;
  connectionError.value = "";
  try {
    const [healthResult, moduleResult] = await Promise.all([
      api.health(),
      api.listModules(),
    ]);
    health.value = healthResult;
    modules.value = moduleResult;
  } catch (error) {
    health.value = null;
    connectionError.value =
      error instanceof Error ? error.message : "无法连接本地分析服务。";
  } finally {
    checking.value = false;
  }
}

onMounted(refresh);
</script>

<template>
  <div class="settings-layout">
    <section class="settings-section">
      <header class="settings-title">
        <div class="settings-icon"><ServerCog :size="21" /></div>
        <div>
          <h2>分析服务</h2>
        </div>
        <button
          class="button secondary small"
          type="button"
          :disabled="checking"
          @click="refresh"
        >
          <RefreshCw :size="15" :class="{ spinning: checking }" />
          重新检查
        </button>
      </header>

      <div v-if="health" class="health-panel success">
        <CheckCircle2 :size="23" />
        <div>
          <strong>本地分析服务运行正常</strong>
        </div>
      </div>
      <div v-else class="health-panel error">
        <CircleAlert :size="23" />
        <div>
          <strong>本地分析服务未连接</strong>
          <span>{{ connectionError || "请先启动 Python 服务" }}</span>
        </div>
      </div>
    </section>

    <section class="settings-section">
      <header class="settings-title">
        <div class="settings-icon"><HardDrive :size="21" /></div>
        <div>
          <h2>数据与隐私</h2>
        </div>
      </header>
      <div class="settings-cards">
        <article class="setting-card">
          <Database :size="21" />
          <div>
            <span>存储模式</span>
            <strong>本地 JSON 与原始文件</strong>
          </div>
        </article>
        <article class="setting-card wide">
          <FolderCog :size="21" />
          <div>
            <span>数据目录</span>
            <strong class="path-value">{{
              health?.data_dir || "等待服务返回"
            }}</strong>
          </div>
        </article>
        <article class="setting-card">
          <ShieldCheck :size="21" />
          <div>
            <span>外部连接</span>
            <strong>未配置</strong>
          </div>
        </article>
      </div>
    </section>

    <section class="settings-section">
      <header class="settings-title">
        <div class="settings-icon"><FolderCog :size="21" /></div>
        <div>
          <h2>模型模块状态</h2>
        </div>
      </header>
      <div class="module-grid settings-modules">
        <ModelModuleCard
          v-for="module in modules"
          :key="module.id"
          :module="module"
        />
      </div>
    </section>
  </div>
</template>
