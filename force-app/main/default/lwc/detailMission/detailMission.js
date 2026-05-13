import { LightningElement, api } from 'lwc';
import getMissionDetails from '@salesforce/apex/MissionMedecinController.getMissionDetails';

function isValidSalesforceId(id) {
  if (id == null || typeof id !== 'string') return false;
  const s = id.trim().replace(/[^a-zA-Z0-9]/g, '');
  return /^[a-zA-Z0-9]{15}$/.test(s) || /^[a-zA-Z0-9]{18}$/.test(s);
}

function unwrapMissionIdCandidate(raw) {
  if (raw == null) return undefined;
  let v = raw;
  if (Array.isArray(v)) {
    v = v.length ? v[0] : undefined;
  }
  if (v == null || v === '') return undefined;
  if (typeof v === 'object') {
    const inner = v.recordId ?? v.id ?? v.value ?? v.missionId ?? v.c__missionId;
    if (inner != null && inner !== v) {
      return unwrapMissionIdCandidate(inner);
    }
    return undefined;
  }
  return v;
}

function normalizeMissionIdParam(raw) {
  const v = unwrapMissionIdCandidate(raw);
  if (v == null || v === '') return undefined;
  const s = String(v).trim().replace(/[^a-zA-Z0-9]/g, '');
  return isValidSalesforceId(s) ? s : undefined;
}

export default class DetailMission extends LightningElement {
  @api missionId;

  _loadSeq = 0;
  _lastRenderedId;
  fields = [];
  missionName = '';
  error;
  isLoading = true;

  get missionIdForApex() {
    return normalizeMissionIdParam(this.missionId);
  }

  connectedCallback() {
    this.scheduleLoad();
  }

  renderedCallback() {
    const id = this.missionIdForApex;
    if (id && id !== this._lastRenderedId) {
      this._lastRenderedId = id;
      this.scheduleLoad();
    }
  }

  scheduleLoad() {
    const seq = ++this._loadSeq;
    queueMicrotask(() => {
      if (seq !== this._loadSeq) {
        return;
      }
      this.loadMissionDetails();
    });
  }

  async loadMissionDetails() {
    const id = this.missionIdForApex;
    if (!id) {
      this.isLoading = false;
      return;
    }
    this.isLoading = true;
    this.error = undefined;
    try {
      const data = await getMissionDetails({ missionId: String(id) });
      this.fields = data.fields;
      this.missionName = data.missionName;
      this.error = undefined;
    } catch (error) {
      const body = error?.body;
      let raw =
        (typeof body?.message === 'string' && body.message) ||
        error?.message ||
        'Erreur chargement mission.';
      if (Array.isArray(body)) {
        raw = body.map((x) => x?.message || String(x)).join(' ') || raw;
      }
      const lower = String(raw).toLowerCase();
      this.error =
        lower.includes('apex request is invalid') || raw === 'The Apex request is invalid.'
          ? 'Identifiant mission invalide. Rouvrez depuis la liste ou rechargez la page.'
          : raw;
      this.fields = [];
    } finally {
      this.isLoading = false;
    }
  }
}
