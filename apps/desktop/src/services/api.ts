import type {
  Artifact,
  Assessment,
  HealthStatus,
  ModelModuleDescriptor,
  Patient,
  PatientCreate,
  ReportDetail,
  ReportSummary,
  SegmentationProject,
  VideoSegment,
} from "@/types/domain";

const API_BASE =
  import.meta.env.VITE_API_BASE_URL ?? "http://127.0.0.1:8000/api/v1";

export class ApiError extends Error {
  constructor(
    message: string,
    public readonly status: number,
    public readonly detail?: unknown,
  ) {
    super(message);
    this.name = "ApiError";
  }
}

async function request<T>(
  path: string,
  init: RequestInit = {},
): Promise<T> {
  const headers = new Headers(init.headers);
  if (init.body && !(init.body instanceof FormData)) {
    headers.set("Content-Type", "application/json");
  }

  const response = await fetch(`${API_BASE}${path}`, {
    ...init,
    headers,
  });

  if (!response.ok) {
    let detail: unknown;
    try {
      detail = await response.json();
    } catch {
      detail = await response.text();
    }
    throw new ApiError(
      `请求失败（${response.status}）`,
      response.status,
      detail,
    );
  }

  if (response.status === 204) {
    return undefined as T;
  }
  return response.json() as Promise<T>;
}

export const api = {
  health: () => request<HealthStatus>("/health"),

  listPatients: (keyword = "") =>
    request<Patient[]>(
      `/patients${keyword ? `?keyword=${encodeURIComponent(keyword)}` : ""}`,
    ),

  createPatient: (payload: PatientCreate) =>
    request<Patient>("/patients", {
      method: "POST",
      body: JSON.stringify(payload),
    }),

  getPatient: (patientId: string) =>
    request<Patient>(`/patients/${patientId}`),

  listModules: () => request<ModelModuleDescriptor[]>("/modules"),

  listArtifacts: (patientId: string) =>
    request<Artifact[]>(`/patients/${patientId}/artifacts`),

  registerLocalArtifact: (
    patientId: string,
    payload: {
      path: string;
      kind: string;
      module_id: string;
      input_slot: string;
    },
  ) =>
    request<Artifact>(`/patients/${patientId}/artifacts/register-local`, {
      method: "POST",
      body: JSON.stringify(payload),
    }),

  createAssessment: (payload: {
    patient_id: string;
    module_inputs: Record<string, Record<string, string[]>>;
  }) =>
    request<Assessment>("/assessments", {
      method: "POST",
      body: JSON.stringify(payload),
    }),

  listAssessments: (patientId?: string) =>
    request<Assessment[]>(
      `/assessments${patientId ? `?patient_id=${patientId}` : ""}`,
    ),

  getAssessment: (assessmentId: string) =>
    request<Assessment>(`/assessments/${assessmentId}`),

  runAssessment: (assessmentId: string) =>
    request<Assessment>(`/assessments/${assessmentId}/run`, {
      method: "POST",
    }),

  listReports: (patientId?: string) =>
    request<ReportSummary[]>(
      `/reports${patientId ? `?patient_id=${patientId}` : ""}`,
    ),

  getReport: (reportId: string) =>
    request<ReportDetail>(`/reports/${reportId}`),

  listSegmentationProjects: (keyword = "") =>
    request<SegmentationProject[]>(
      `/segmentation-projects${
        keyword ? `?keyword=${encodeURIComponent(keyword)}` : ""
      }`,
    ),

  getSegmentationProject: (projectId: string) =>
    request<SegmentationProject>(`/segmentation-projects/${projectId}`),

  saveVideoSegments: (
    projectId: string,
    segments: VideoSegment[],
    walkDistanceM?: number,
  ) =>
    request<SegmentationProject>(
      `/segmentation-projects/${projectId}/segments`,
      {
        method: "PUT",
        body: JSON.stringify({
          segments,
          walk_distance_m: walkDistanceM,
        }),
      },
    ),
};

export function assessmentOutputUrl(
  assessmentId: string,
  moduleId: string,
  artifactIndex: number,
): string {
  return `${API_BASE}/assessments/${encodeURIComponent(
    assessmentId,
  )}/modules/${encodeURIComponent(moduleId)}/outputs/${artifactIndex}`;
}

export function segmentationPreviewUrl(project: SegmentationProject): string {
  return `${API_BASE}/segmentation-projects/${project.id}/preview?v=${encodeURIComponent(
    project.updated_at,
  )}`;
}

export function uploadSegmentationProject(
  file: File,
  projectName: string,
  onProgress?: (value: number) => void,
): Promise<SegmentationProject> {
  return new Promise((resolve, reject) => {
    const body = new FormData();
    body.append("file", file);
    body.append("project_name", projectName);

    const xhr = new XMLHttpRequest();
    xhr.open("POST", `${API_BASE}/segmentation-projects/upload`);
    xhr.responseType = "json";

    xhr.upload.addEventListener("progress", (event) => {
      if (event.lengthComputable && onProgress) {
        onProgress(Math.round((event.loaded / event.total) * 100));
      }
    });
    xhr.addEventListener("load", () => {
      if (xhr.status >= 200 && xhr.status < 300) {
        resolve(xhr.response as SegmentationProject);
        return;
      }
      reject(
        new ApiError(`导入失败（${xhr.status}）`, xhr.status, xhr.response),
      );
    });
    xhr.addEventListener("error", () => {
      reject(new ApiError("无法连接分析服务", 0));
    });
    xhr.send(body);
  });
}

export function uploadPatientArtifact(
  patientId: string,
  file: File,
  kind: string,
  moduleId: string,
  inputSlot: string,
  onProgress?: (value: number) => void,
): Promise<Artifact> {
  return new Promise((resolve, reject) => {
    const body = new FormData();
    body.append("file", file);
    body.append("kind", kind);
    body.append("module_id", moduleId);
    body.append("input_slot", inputSlot);

    const xhr = new XMLHttpRequest();
    xhr.open("POST", `${API_BASE}/patients/${patientId}/artifacts/upload`);
    xhr.responseType = "json";

    xhr.upload.addEventListener("progress", (event) => {
      if (event.lengthComputable && onProgress) {
        onProgress(Math.round((event.loaded / event.total) * 100));
      }
    });

    xhr.addEventListener("load", () => {
      if (xhr.status >= 200 && xhr.status < 300) {
        resolve(xhr.response as Artifact);
        return;
      }
      reject(
        new ApiError(`上传失败（${xhr.status}）`, xhr.status, xhr.response),
      );
    });
    xhr.addEventListener("error", () => {
      reject(new ApiError("无法连接分析服务", 0));
    });
    xhr.send(body);
  });
}
