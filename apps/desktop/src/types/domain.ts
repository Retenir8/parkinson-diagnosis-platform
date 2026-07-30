export type PatientGender = "male" | "female" | "other" | "unknown";

export interface Patient {
  id: string;
  patient_code: string;
  name: string;
  gender: PatientGender;
  birth_date?: string | null;
  phone?: string | null;
  diagnosis?: string | null;
  notes?: string | null;
  extra_fields: Record<string, unknown>;
  created_at: string;
  updated_at: string;
}

export interface PatientCreate {
  patient_code: string;
  name: string;
  gender: PatientGender;
  birth_date?: string;
  phone?: string;
  diagnosis?: string;
  notes?: string;
  extra_fields?: Record<string, unknown>;
}

export type ModuleStatus =
  | "ready"
  | "adapter_pending"
  | "external_pending"
  | "disabled"
  | "error";

export type InputKind =
  | "video"
  | "realsense_bag"
  | "tabular"
  | "insole_timeseries"
  | "unknown";

export interface ModelModuleDescriptor {
  id: string;
  display_name: string;
  category: "posture" | "hand" | "leg" | "insole";
  description: string;
  status: ModuleStatus;
  status_detail: string;
  input_kinds: InputKind[];
  input_slots: InputSlotDescriptor[];
  output_capabilities: string[];
  model_version?: string | null;
}

export interface InputSlotDescriptor {
  key: string;
  label: string;
  description: string;
  accepted_kinds: InputKind[];
  required: boolean;
  multiple: boolean;
}

export interface Artifact {
  id: string;
  patient_id: string;
  module_id: string;
  input_slot: string;
  original_name: string;
  kind: InputKind;
  source_type: "uploaded" | "local_reference";
  stored_path: string;
  size_bytes?: number | null;
  created_at: string;
}

export interface Assessment {
  id: string;
  patient_id: string;
  module_inputs: Record<string, Record<string, string[]>>;
  status:
    | "draft"
    | "queued"
    | "running"
    | "completed"
    | "failed"
    | "cancelled";
  status_detail: string;
  module_runs: Record<string, ModuleRunRecord>;
  created_at: string;
  updated_at: string;
}

export interface ModuleResult {
  module_id: string;
  module_version?: string | null;
  summary?: string | null;
  quality: Record<string, unknown>;
  metrics: Record<string, number | string | null>;
  scores: Record<string, number | string | null>;
  result_data: Record<string, unknown>;
  output_artifacts: string[];
  warnings: string[];
}

export interface ModuleRunRecord {
  module_id: string;
  status:
    | "awaiting_adapter"
    | "queued"
    | "running"
    | "completed"
    | "failed"
    | "cancelled";
  status_detail: string;
  inputs: Record<string, string[]>;
  result?: ModuleResult | null;
  updated_at: string;
}

export interface ReportSummary {
  id: string;
  patient_id: string;
  patient_name: string;
  assessment_id: string;
  title: string;
  status: "draft" | "ready" | "failed";
  created_at: string;
  file_name?: string | null;
}

export interface HealthStatus {
  status: string;
  service: string;
  version: string;
  data_dir: string;
}
