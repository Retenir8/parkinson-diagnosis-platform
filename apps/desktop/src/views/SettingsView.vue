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
          <p>浏览器和 Tauri 共用同一套本地 API</p>
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
          <span>{{ health.service }} · {{ health.version }}</span>
        </div>
        <span class="health-state">CONNECTED</span>
      </div>
      <div v-else class="health-panel error">
        <CircleAlert :size="23" />
        <div>
          <strong>本地分析服务未连接</strong>
          <span>{{ connectionError || "请先启动 Python 服务" }}</span>
        </div>
        <span class="health-state">OFFLINE</span>
      </div>
    </section>

    <section class="settings-section">
      <header class="settings-title">
        <div class="settings-icon"><HardDrive :size="21" /></div>
        <div>
          <h2>数据与隐私</h2>
          <p>首版使用本地文件，不连接数据库</p>
        </div>
      </header>
      <div class="settings-cards">
        <article class="setting-card">
          <Database :size="21" />
          <div>
            <span>存储模式</span>
            <strong>本地 JSON 与原始文件</strong>
            <small>患者之间采用独立目录隔离</small>
          </div>
        </article>
        <article class="setting-card wide">
          <FolderCog :size="21" />
          <div>
            <span>数据目录</span>
            <strong class="path-value">{{
              health?.data_dir || "等待服务返回"
            }}</strong>
            <small>可通过 MEDVISION_DATA_DIR 环境变量覆盖</small>
          </div>
        </article>
        <article class="setting-card">
          <ShieldCheck :size="21" />
          <div>
            <span>外部连接</span>
            <strong>未配置</strong>
            <small>未接入数据库或云端服务</small>
          </div>
        </article>
      </div>
    </section>

    <section class="settings-section">
      <header class="settings-title">
        <div class="settings-icon"><FolderCog :size="21" /></div>
        <div>
          <h2>模型模块状态</h2>
          <p>状态来自后端模块注册表，不代表临床有效性</p>
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
