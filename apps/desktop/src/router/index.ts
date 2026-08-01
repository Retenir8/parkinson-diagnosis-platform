import { createRouter, createWebHistory } from "vue-router";

import AppShell from "@/layouts/AppShell.vue";

const router = createRouter({
  history: createWebHistory(),
  routes: [
    {
      path: "/",
      component: AppShell,
      children: [
        { path: "", redirect: "/patients" },
        {
          path: "patients",
          name: "patients",
          component: () => import("@/views/PatientsView.vue"),
          meta: {
            title: "患者管理",
            subtitle: "维护患者信息与连续评估档案",
          },
        },
        {
          path: "assessment",
          name: "assessment",
          component: () => import("@/views/AssessmentView.vue"),
          meta: {
            title: "采集评估",
            subtitle: "组织多模态数据并调度分析模块",
          },
        },
        {
          path: "video-segmentation",
          name: "video-segmentation",
          component: () => import("@/views/VideoSegmentationView.vue"),
          meta: {
            title: "视频分割",
            subtitle: "人工查看视频并标记模型任务时间段",
          },
        },
        {
          path: "reports",
          name: "reports",
          component: () => import("@/views/ReportsView.vue"),
          meta: {
            title: "报告中心",
            subtitle: "集中查看、生成与导出评估报告",
          },
        },
        {
          path: "settings",
          name: "settings",
          component: () => import("@/views/SettingsView.vue"),
          meta: {
            title: "系统设置",
            subtitle: "检查服务、存储与模型模块状态",
          },
        },
      ],
    },
  ],
});

router.afterEach((to) => {
  const title = typeof to.meta.title === "string" ? to.meta.title : "";
  document.title = title
    ? `${title} · 多模态运动功能评估系统`
    : "多模态运动功能评估系统";
});

export default router;
