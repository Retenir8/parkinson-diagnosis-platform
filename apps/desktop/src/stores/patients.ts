import { defineStore } from "pinia";

import { api } from "@/services/api";
import type { Patient, PatientCreate } from "@/types/domain";

interface PatientState {
  items: Patient[];
  selectedId: string | null;
  loading: boolean;
  error: string | null;
}

export const usePatientsStore = defineStore("patients", {
  state: (): PatientState => ({
    items: [],
    selectedId: null,
    loading: false,
    error: null,
  }),

  getters: {
    selectedPatient(state): Patient | null {
      return (
        state.items.find((patient) => patient.id === state.selectedId) ?? null
      );
    },
  },

  actions: {
    async load(keyword = "") {
      this.loading = true;
      this.error = null;
      try {
        this.items = await api.listPatients(keyword);
        if (
          this.selectedId &&
          !this.items.some((patient) => patient.id === this.selectedId)
        ) {
          this.selectedId = null;
        }
      } catch (error) {
        this.error =
          error instanceof Error ? error.message : "患者列表加载失败";
      } finally {
        this.loading = false;
      }
    },

    async create(payload: PatientCreate) {
      const patient = await api.createPatient(payload);
      this.items = [patient, ...this.items];
      this.selectedId = patient.id;
      return patient;
    },

    select(patientId: string | null) {
      this.selectedId = patientId;
    },
  },
});
