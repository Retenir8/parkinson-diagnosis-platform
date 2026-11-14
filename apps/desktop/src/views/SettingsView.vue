<script setup lang="ts">
import {
  CheckCircle2,
  CircleAlert,
  Database,
  FolderCog,
  FolderOpen,
  HardDrive,
  RefreshCw,
  ServerCog,
  ShieldCheck,
} from "@lucide/vue";
import { computed, onMounted, ref } from "vue";

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
const isDesktop = Boolean(window.__TAURI_INTERNALS__);
const canConfigureStorage = isDesktop && !import.meta.env.DEV;

interface DesktopStorageSettings {
  default_data_dir: string;
  saved_data_dir: string;
  startup_warning: string | null;
}

const storageSettings = ref<DesktopStorageSettings | null>(null);
const pendingDirectory = ref("");
const pendingDefault = ref(false);
const savingStorage = ref(false);
const storageError = ref("");
const storageMessage = ref("");

function normalizedPath(path: string) {
  return path.replace(/\//g, "\\").replace(/\\+$/, "").toLowerCase();
}

const restartRequired = computed(() =>
  Boolean(
    health.value &&
      storageSettings.value &&
      normalizedPath(health.value.data_dir) !==
        normalizedPath(storageSettings.value.saved_data_dir),
  ),
);

async function loadStorageSettings() {
  if (!canConfigureStorage) return;
  try {
    const { invoke } = await import("@tauri-apps/api/core");
    storageSettings.value = await invoke<DesktopStorageSettings>("desktop_storage_settings");
  } catch (error) {
    storageError.value = error instanceof Error ? error.message : String(error);
  }
}

async function chooseDataDirectory() {
  storageError.value = "";
  storageMessage.value = "";
  try {
    const { open } = await import("@tauri-apps/plugin-dialog");
    const selected = await open({
      directory: true,
      multiple: false,
      title: "选择患者数据目录",
    });
    if (typeof selected === "string") {
      pendingDirectory.value = selected;
      pendingDefault.value = false;
    }
  } catch (error) {
    storageError.value = error instanceof Error ? error.message : String(error);
  }
}

function chooseDefaultDirectory() {
  if (!storageSettings.value) return;
  pendingDirectory.value = storageSettings.value.default_data_dir;
  pendingDefault.value = true;
  storageError.value = "";
  storageMessage.value = "";
}

async function saveDataDirectory() {
  if (!pendingDirectory.value || savingStorage.value) return;
  savingStorage.value = true;
  storageError.value = "";
  storageMessage.value = "";
  try {
    const { invoke } = await import("@tauri-apps/api/core");
    if (pendingDefault.value) {
      await invoke<string>("reset_desktop_data_directory");
    } else {
      await invoke<string>("set_desktop_data_directory", {
        directory: pendingDirectory.value,
      });
    }
    storageSettings.value = await invoke<DesktopStorageSettings>("desktop_storage_settings");
    pendingDirectory.value = "";
    pendingDefault.value = false;
    storageMessage.value = "目录设置已保存。关闭并重新打开桌面程序后生效；原目录中的患者资料不会移动。";
  } catch (error) {
    storageError.value = error instanceof Error ? error.message : String(error);
  } finally {
    savingStorage.value = false;
  }
}

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

onMounted(() => {
  void refresh();
  void loadStorageSettings();
});
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
          <span>{{ connectionError || (isDesktop ? "请重启桌面程序并查看后端日志" : "请先启动 Python 服务") }}</span>
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
      <div v-if="canConfigureStorage" class="storage-manager">
        <div class="storage-manager-heading">
          <div>
            <span>下次启动使用</span>
            <strong class="path-value">{{ storageSettings?.saved_data_dir || "读取设置中…" }}</strong>
          </div>
          <span v-if="restartRequired" class="storage-restart-badge">重启后生效</span>
        </div>
        <div v-if="pendingDirectory" class="storage-pending">
          <span>准备保存</span>
          <strong class="path-value">{{ pendingDirectory }}</strong>
        </div>
        <div class="storage-actions">
          <button class="button secondary small" type="button" :disabled="savingStorage" @click="chooseDataDirectory">
            <FolderOpen :size="15" /> 选择文件夹
          </button>
          <button class="button secondary small" type="button" :disabled="savingStorage || !storageSettings" @click="chooseDefaultDirectory">
            使用默认目录
          </button>
          <button v-if="pendingDirectory" class="button primary small" type="button" :disabled="savingStorage" @click="saveDataDirectory">
            保存设置
          </button>
        </div>
        <p class="storage-note">不会复制、移动或删除旧患者资料；切到空目录后旧记录暂不显示，切回原目录即可查看。请选择仅授权人员可访问的专用文件夹。</p>
        <div v-if="storageSettings?.startup_warning" class="inline-alert error">{{ storageSettings.startup_warning }}</div>
        <div v-if="storageError" class="inline-alert error">{{ storageError }}</div>
        <div v-if="storageMessage" class="inline-alert storage-success">{{ storageMessage }}</div>
      </div>
      <p v-else class="storage-browser-note">
        {{ isDesktop ? "桌面开发模式请通过 Python 服务的 MEDVISION_DATA_DIR 环境变量设置目录。" : "浏览器模式请通过 Python 服务的 MEDVISION_DATA_DIR 环境变量设置目录。" }}
      </p>
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
