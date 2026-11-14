import { createPinia } from "pinia";
import { createApp } from "vue";

import App from "./App.vue";
import router from "./router";
import { configureDesktopConnection } from "./services/api";
import "./assets/main.css";

async function start() {
  const root = document.getElementById("app");
  if (window.__TAURI_INTERNALS__) {
    if (root) root.textContent = "正在启动本地分析服务…";
    try {
      const { invoke } = await import("@tauri-apps/api/core");
      const [apiBase, token] = await invoke<[string, string]>("desktop_connection");
      configureDesktopConnection(apiBase, token);
      let ready = false;
      for (let attempt = 0; attempt < 180; attempt += 1) {
        try {
          const response = await fetch(`${apiBase}/health`, {
            headers: { "X-Medvision-Token": token },
          });
          if (response.ok) {
            ready = true;
            break;
          }
        } catch {
          // The packaged Python process may still be extracting and starting.
        }
        await new Promise((resolve) => setTimeout(resolve, 500));
      }
      if (!ready) throw new Error("本地分析服务在 90 秒内未启动。请查看桌面数据目录中的 logs/backend.log。");
      if (!import.meta.env.DEV) {
        try {
          const storage = await invoke<{ startup_warning: string | null }>("desktop_storage_settings");
          if (storage.startup_warning) {
            const { message } = await import("@tauri-apps/plugin-dialog");
            await message(storage.startup_warning, { title: "数据目录提醒", kind: "warning" });
          }
        } catch {
          // Storage details remain available on the settings page.
        }
      }
    } catch (error) {
      if (root) {
        root.textContent = error instanceof Error
          ? `桌面程序启动失败：${error.message}`
          : `桌面程序启动失败：${String(error)}`;
      }
      return;
    }
  }
  createApp(App).use(createPinia()).use(router).mount("#app");
}

void start();
